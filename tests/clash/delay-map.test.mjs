/**
 * T-S1-16 延迟结果单元测试（设计 §8.2）。
 *
 * 覆盖任务卡：乱序丢弃、并发夹紧 4/8、取消保留已得值；
 * 另外校验不可变快照、批量计划去重与按节点清除。
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const {
  applyDelay,
  planBatch,
  cancel,
  clearProfile,
  clearAll,
  isSuccess,
  DELAY_VALUE_FAILED,
  DELAY_VALUE_PENDING,
  MIN_BATCH_CONCURRENCY,
  MAX_BATCH_CONCURRENCY,
  DEFAULT_BATCH_CONCURRENCY,
} = require('../../artifacts/tests/js/model/ClashDelayMap.js');

const URL = 'http://example.invalid/';

/** 构造一条已完成结果，减少重复。 */
function okEntry(value, at) {
  return { value, at, state: 'ok' };
}

test('延迟值语义：正数为成功、0 为加载中、非正/非有限为失败', () => {
  const base = {};
  assert.deepEqual(applyDelay(base, 'node-a', URL, 120, 1000)[URL]['node-a'], {
    value: 120,
    at: 1000,
    state: 'ok',
  });
  assert.deepEqual(applyDelay(base, 'node-a', URL, 0, 1000)[URL]['node-a'], {
    value: DELAY_VALUE_PENDING,
    at: 1000,
    state: 'loading',
  });
  for (const value of [-1, -50, NaN, Infinity]) {
    const entry = applyDelay(base, 'node-a', URL, value, 1000)[URL]['node-a'];
    assert.equal(entry.state, 'failed', String(value));
    assert.equal(entry.value, DELAY_VALUE_FAILED, String(value));
  }
  // 0 绝不代表成功。
  assert.equal(isSuccess({ value: 0, at: 1, state: 'loading' }), false);
  assert.equal(isSuccess({ value: 0, at: 1, state: 'ok' }), false);
  assert.equal(isSuccess({ value: 120, at: 1, state: 'ok' }), true);
  assert.equal(isSuccess({ value: -1, at: 1, state: 'failed' }), false);
  assert.equal(isSuccess(undefined), false);
});

test('乱序到达的旧值被丢弃，同刻重放也不覆盖', () => {
  let map = applyDelay({}, 'node-a', URL, 120, 2000);
  map = applyDelay(map, 'node-a', URL, 999, 1000);
  assert.equal(map[URL]['node-a'].value, 120);
  assert.equal(map[URL]['node-a'].at, 2000);
  // at 相等视为旧事件，不覆盖。
  map = applyDelay(map, 'node-a', URL, 500, 2000);
  assert.equal(map[URL]['node-a'].value, 120);
  // 更新的值正常覆盖。
  map = applyDelay(map, 'node-a', URL, 80, 3000);
  assert.equal(map[URL]['node-a'].value, 80);
  assert.equal(map[URL]['node-a'].at, 3000);
});

test('不同 url 与不同节点互不影响；空名/空 url/非法 at 不写入', () => {
  let map = applyDelay({}, 'node-a', URL, 120, 1000);
  map = applyDelay(map, 'node-b', URL, 90, 1000);
  map = applyDelay(map, 'node-a', 'http://example.invalid/alt', 60, 1000);
  assert.equal(map[URL]['node-a'].value, 120);
  assert.equal(map[URL]['node-b'].value, 90);
  assert.equal(map['http://example.invalid/alt']['node-a'].value, 60);

  const before = JSON.stringify(map);
  const unchanged = [
    applyDelay(map, '', URL, 10, 2000),
    applyDelay(map, 'node-a', '', 10, 2000),
    applyDelay(map, 'node-a', URL, 10, NaN),
  ];
  for (const next of unchanged) {
    assert.equal(JSON.stringify(next), before);
    assert.notEqual(next, map);
  }
});

test('applyDelay 不修改入参，未受影响的 bucket 按引用共享', () => {
  const other = { 'node-b': okEntry(90, 1000) };
  const map = { [URL]: { 'node-a': okEntry(100, 1000) }, 'http://example.invalid/other': other };
  const next = applyDelay(map, 'node-a', URL, 120, 2000);

  assert.notEqual(next, map);
  assert.equal(map[URL]['node-a'].value, 100);
  assert.equal(next[URL]['node-a'].value, 120);
  // 只替换被修改的 url bucket，其他 bucket 不复制。
  assert.equal(next['http://example.invalid/other'], other);
  assert.notEqual(next[URL], map[URL]);
});

test('批量计划并发夹紧 4-8，默认 4，去重并丢弃空名', () => {
  assert.equal(MIN_BATCH_CONCURRENCY, 4);
  assert.equal(MAX_BATCH_CONCURRENCY, 8);
  assert.equal(DEFAULT_BATCH_CONCURRENCY, 4);

  const names = ['node-0', 'node-1', 'node-2', 'node-3', 'node-4', 'node-5', 'node-6', 'node-7', 'node-8', 'node-9'];
  assert.deepEqual(planBatch(names).map((batch) => batch.length), [4, 4, 2]);
  assert.deepEqual(planBatch(names, 8).map((batch) => batch.length), [8, 2]);
  assert.deepEqual(planBatch(names, 100).map((batch) => batch.length), [8, 2]);
  assert.deepEqual(planBatch(names, 1).map((batch) => batch.length), [4, 4, 2]);
  // 小数向下取整后再夹紧：3.9 → 3 → 4。
  assert.deepEqual(planBatch(names, 3.9).map((batch) => batch.length), [4, 4, 2]);
  assert.deepEqual(planBatch(names, NaN).map((batch) => batch.length), [4, 4, 2]);

  assert.deepEqual(planBatch(['node-a', 'node-a', '', 'node-b']), [['node-a', 'node-b']]);
  assert.deepEqual(planBatch(['node-a'], 8), [['node-a']]);
  assert.deepEqual(planBatch([]), []);
  assert.deepEqual(planBatch(null), []);
});

test('取消把未完成项置 idle，已完成值原样保留', () => {
  const map = {
    [URL]: {
      'node-a': okEntry(120, 1000),
      'node-b': { value: 0, at: 1001, state: 'loading' },
      'node-c': { value: -1, at: 1002, state: 'failed' },
      'node-d': { value: 0, at: 1003, state: 'idle' },
    },
  };
  const cancelled = cancel(map);
  assert.deepEqual(cancelled[URL]['node-b'], { value: 0, at: 1001, state: 'idle' });
  // 已得结果按引用保留，不清除历史。
  assert.equal(cancelled[URL]['node-a'], map[URL]['node-a']);
  assert.equal(cancelled[URL]['node-c'], map[URL]['node-c']);
  assert.equal(cancelled[URL]['node-d'], map[URL]['node-d']);
  // 入参保持 loading。
  assert.equal(map[URL]['node-b'].state, 'loading');
  assert.deepEqual(cancel({}), {});
});

test('未发生变化的 bucket 在取消后按引用共享', () => {
  const settled = { 'node-a': okEntry(40, 1000) };
  const map = {
    'http://example.invalid/settled': settled,
    [URL]: { 'node-b': { value: 0, at: 1001, state: 'loading' } },
  };
  const cancelled = cancel(map);
  assert.equal(cancelled['http://example.invalid/settled'], settled);
  assert.notEqual(cancelled[URL], map[URL]);
});

test('按节点名跨 url 清除结果，空 bucket 一并移除', () => {
  const map = {
    [URL]: { 'node-a': okEntry(120, 1000), 'node-b': okEntry(90, 1000) },
    'http://example.invalid/only-a': { 'node-a': okEntry(60, 1000) },
    'http://example.invalid/untouched': { 'node-b': okEntry(70, 1000) },
  };
  const cleared = clearProfile(map, ['node-a']);
  assert.deepEqual(Object.keys(cleared[URL]), ['node-b']);
  assert.equal(Object.prototype.hasOwnProperty.call(cleared, 'http://example.invalid/only-a'), false);
  assert.equal(cleared['http://example.invalid/untouched'], map['http://example.invalid/untouched']);
  // 入参不变。
  assert.equal(map[URL]['node-a'].value, 120);

  // 空名单只复制外层，不删除任何结果。
  const untouched = clearProfile(map, []);
  assert.notEqual(untouched, map);
  assert.equal(untouched[URL], map[URL]);
  assert.deepEqual(clearAll(), {});
});