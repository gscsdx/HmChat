import test from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const {
  PREPARING_TIMEOUT_MS,
  RECONNECT_MAX_ATTEMPTS,
  RECONNECT_BACKOFF_MS,
  defaultFailureCode,
  isEvidenceComplete,
  isPreparingExpired,
  reconnectDelayMs,
  resolvePreparingReason,
  transition,
} = require('../../artifacts/tests/js/model/ClashStateMachine.js');

// 全部夹具为虚构值：example.invalid、node-a、无真实订阅/账号/节点。
const ALL_READY = { coreReady: true, tunReady: true, routeReady: true };
const NO_EVIDENCE = { coreReady: false, tunReady: false, routeReady: false };

/**
 * 构造一份状态机输入；facts 的 epoch 默认与顶层 epoch 一致，避免无意触发 stale 守卫。
 * `spec.facts` 可覆盖 evidence / hasValidProfile / epoch / reason / errorCode。
 */
function run(spec) {
  const epoch = spec.epoch === undefined ? 1 : spec.epoch;
  const facts = { evidence: ALL_READY, hasValidProfile: true, epoch: epoch, ...spec.facts };
  const input = { state: spec.state, epoch: epoch, event: spec.event, facts: facts };
  const passthrough = ['nowMs', 'preparingStartedAtMs', 'stateReason', 'illegalTransitions', 'staleEpochEvents', 'reconnectAttempts'];
  for (const key of passthrough) {
    if (spec[key] !== undefined) {
      input[key] = spec[key];
    }
  }
  return transition(input);
}

// ---------------------------------------------------------------------------
// 常量：锁定设计 §3.3 / §5.5 的预算数值
// ---------------------------------------------------------------------------

test('预算常量：preparing 60 s、重连 5 次、退避 1/2/4/8/16 s', () => {
  assert.equal(PREPARING_TIMEOUT_MS, 60000);
  assert.equal(RECONNECT_MAX_ATTEMPTS, 5);
  assert.deepEqual(RECONNECT_BACKOFF_MS, [1000, 2000, 4000, 8000, 16000]);
  assert.equal(reconnectDelayMs(0), 1000);
  assert.equal(reconnectDelayMs(1), 1000);
  assert.equal(reconnectDelayMs(3), 4000);
  assert.equal(reconnectDelayMs(5), 16000);
  assert.equal(reconnectDelayMs(6), 16000);
  assert.equal(reconnectDelayMs(Number.NaN), 1000);
});

// ---------------------------------------------------------------------------
// 迁移表 13 行（设计 §3.3）
// ---------------------------------------------------------------------------

test('迁移 1：unconfigured + 导入成功 → stopped 且 epoch+1', () => {
  const out = run({ state: 'unconfigured', event: 'importSucceeded' });
  assert.equal(out.rejected, undefined);
  assert.equal(out.state, 'stopped');
  assert.equal(out.epoch, 2);
  assert.equal(out.changed, true);
  assert.equal(out.record.from, 'unconfigured');
  assert.equal(out.record.to, 'stopped');
  assert.equal(out.record.epoch, 2);
  assert.equal(out.reconnectAttempts, 0);
  assert.equal(out.illegalTransitions, 0);
});

test('迁移 1 守卫：无有效配置时导入被 no_valid_profile 拒绝且不计非法迁移', () => {
  const out = run({ state: 'unconfigured', event: 'importSucceeded', facts: { hasValidProfile: false } });
  assert.equal(out.state, 'unconfigured');
  assert.equal(out.rejected.code, 'no_valid_profile');
  assert.equal(out.rejected.detail, 'import_without_valid_profile');
  assert.equal(out.illegalTransitions, 0);
  assert.equal(out.changed, false);
});

test('迁移 2：unconfigured + 请求开启 → 保持 unconfigured 并拒绝', () => {
  const out = run({ state: 'unconfigured', event: 'enableRequested' });
  assert.equal(out.state, 'unconfigured');
  assert.equal(out.epoch, 1);
  assert.equal(out.rejected.code, 'no_valid_profile');
  assert.equal(out.rejected.detail, 'enable_without_profile');
  assert.equal(out.illegalTransitions, 0);
  assert.equal(out.changed, false);
});

test('迁移 3：stopped + 请求开启且配置有效 → preparing(start) 并给出 60 s 截止', () => {
  const out = run({ state: 'stopped', event: 'enableRequested', nowMs: 1000 });
  assert.equal(out.state, 'preparing');
  assert.equal(out.epoch, 2);
  assert.equal(out.record.reason, 'start');
  assert.equal(out.preparingDeadlineMs, 61000);
  assert.equal(out.reconnectAttempts, 0);
  assert.equal(isPreparingExpired({
    state: 'preparing',
    epoch: 2,
    event: 'evidenceReady',
    facts: { evidence: ALL_READY, hasValidProfile: true, epoch: 2 },
    nowMs: 61000,
    preparingStartedAtMs: 1000,
  }), true);
});

test('迁移 3：preparing 原因只接受 apply/scope，reconnect 只能由 linkLost 产生', () => {
  for (const [reason, expected] of [['apply', 'apply'], ['scope', 'scope'], ['start', 'start'], ['reconnect', 'start'], [undefined, 'start']]) {
    const out = run({ state: 'stopped', event: 'enableRequested', facts: { reason: reason } });
    assert.equal(out.record.reason, expected);
  }
});

test('迁移 3 守卫：stopped + 请求开启但无有效配置 → 拒绝', () => {
  const out = run({ state: 'stopped', event: 'enableRequested', facts: { hasValidProfile: false } });
  assert.equal(out.state, 'stopped');
  assert.equal(out.rejected.code, 'no_valid_profile');
  assert.equal(out.rejected.detail, 'enable_without_valid_profile');
});

test('迁移 4：preparing + E1/E2/E3 → connected，并保持同一 epoch', () => {
  const out = run({ state: 'preparing', event: 'evidenceReady', epoch: 5 });
  assert.equal(out.rejected, undefined);
  assert.equal(out.state, 'connected');
  assert.equal(out.epoch, 5);
  assert.equal(out.changed, true);
  assert.equal(out.record.from, 'preparing');
  assert.equal(out.record.to, 'connected');
  assert.equal(out.reconnectAttempts, 0);
});

test('迁移 4 守卫：三重证据缺一即不迁移，单个 init/port 成功不算证据', () => {
  const partial = [
    { coreReady: true, tunReady: false, routeReady: false },
    { coreReady: true, tunReady: true, routeReady: false },
    { coreReady: false, tunReady: true, routeReady: true },
    NO_EVIDENCE,
  ];
  for (const evidence of partial) {
    assert.equal(isEvidenceComplete(evidence), false);
    const out = run({ state: 'preparing', event: 'evidenceReady', facts: { evidence: evidence } });
    assert.equal(out.state, 'preparing');
    assert.equal(out.rejected.code, 'illegal_transition');
    assert.equal(out.rejected.detail, 'evidence_incomplete');
  }
  assert.equal(isEvidenceComplete(ALL_READY), true);
});

test('迁移 5：preparing + 授权被拒 → unauthorized 并记录授权码', () => {
  const out = run({ state: 'preparing', event: 'authDenied' });
  assert.equal(out.state, 'unauthorized');
  assert.equal(out.epoch, 2);
  assert.equal(out.record.errorCode, 'tun_create_denied');
  assert.equal(out.reconnectAttempts, 0);
  const custom = run({ state: 'preparing', event: 'authDenied', facts: { errorCode: 'unsupported' } });
  assert.equal(custom.record.errorCode, 'unsupported');
});

test('迁移 5 补充：connected + 系统撤销授权 → unauthorized', () => {
  const out = run({ state: 'connected', event: 'authDenied', epoch: 9 });
  assert.equal(out.state, 'unauthorized');
  assert.equal(out.epoch, 10);
  assert.equal(out.record.errorCode, 'tun_create_denied');
});

test('迁移 6：preparing + 证据失败 → failed 携带分类码（默认按缺失证据推导）', () => {
  const core = run({ state: 'preparing', event: 'evidenceFailed', facts: { evidence: { coreReady: false, tunReady: true, routeReady: true } } });
  assert.equal(core.state, 'failed');
  assert.equal(core.record.errorCode, 'core_init_failed');
  const tun = run({ state: 'preparing', event: 'evidenceFailed', facts: { evidence: { coreReady: true, tunReady: false, routeReady: true } } });
  assert.equal(tun.record.errorCode, 'tun_start_failed');
  const route = run({ state: 'preparing', event: 'evidenceFailed', facts: { evidence: { coreReady: true, tunReady: true, routeReady: false } } });
  assert.equal(route.record.errorCode, 'tun_route_failed');
  const explicit = run({ state: 'preparing', event: 'evidenceFailed', facts: { errorCode: 'config_invalid' } });
  assert.equal(explicit.record.errorCode, 'config_invalid');
  assert.equal(run({ state: 'preparing', event: 'evidenceFailed' }).record.errorCode, 'internal');
  assert.equal(defaultFailureCode(ALL_READY), 'internal');
});

test('迁移 6 补充：preparing + 60 s 超时事件 → failed(timeout)', () => {
  const out = run({ state: 'preparing', event: 'prepareTimeout', epoch: 4 });
  assert.equal(out.state, 'failed');
  assert.equal(out.epoch, 5);
  assert.equal(out.record.errorCode, 'timeout');
  assert.equal(out.changed, true);
  assert.equal(out.reconnectAttempts, 0);
});

test('迁移 7：preparing + 用户取消 → stopped', () => {
  const out = run({ state: 'preparing', event: 'cancelled' });
  assert.equal(out.state, 'stopped');
  assert.equal(out.epoch, 2);
  assert.equal(out.rejected, undefined);
});

test('迁移 8：connected + 用户关闭 → stopped', () => {
  const out = run({ state: 'connected', event: 'stopRequested' });
  assert.equal(out.state, 'stopped');
  assert.equal(out.epoch, 2);
  assert.equal(out.rejected, undefined);
});

test('迁移 9：connected + 断线 → preparing(reconnect)，第 1 次退避 1 s', () => {
  const out = run({ state: 'connected', event: 'linkLost', epoch: 3, nowMs: 2000 });
  assert.equal(out.state, 'preparing');
  assert.equal(out.epoch, 4);
  assert.equal(out.record.reason, 'reconnect');
  assert.equal(out.reconnectAttempts, 1);
  assert.equal(out.nextRetryDelayMs, 1000);
  assert.equal(out.preparingDeadlineMs, 62000);
});

test('迁移 10：unauthorized + 重试并授权 → preparing（重新走完整流程）', () => {
  const out = run({ state: 'unauthorized', event: 'retryRequested' });
  assert.equal(out.state, 'preparing');
  assert.equal(out.epoch, 2);
  assert.equal(out.record.reason, 'start');
  assert.equal(out.reconnectAttempts, 0);
});

test('迁移 11：failed + 手动重试 → preparing 并重置重连计数', () => {
  const out = run({ state: 'failed', event: 'retryRequested', reconnectAttempts: 5, stateReason: 'reconnect' });
  assert.equal(out.state, 'preparing');
  assert.equal(out.epoch, 2);
  assert.equal(out.reconnectAttempts, 0);
  assert.equal(out.rejected, undefined);
});

test('迁移 11 守卫：无有效配置时 failed + 重试被拒绝', () => {
  const out = run({ state: 'failed', event: 'retryRequested', facts: { hasValidProfile: false } });
  assert.equal(out.state, 'failed');
  assert.equal(out.rejected.code, 'no_valid_profile');
  assert.equal(out.rejected.detail, 'retry_without_valid_profile');
});

test('迁移 12：任意状态 + 应用重启 → stopped（有配置）或 unconfigured，禁止恢复 connected', () => {
  const withProfile = run({ state: 'connected', event: 'appRestarted', epoch: 7 });
  assert.equal(withProfile.state, 'stopped');
  assert.equal(withProfile.epoch, 8);
  assert.equal(withProfile.changed, true);
  const withoutProfile = run({ state: 'connected', event: 'appRestarted', epoch: 7, facts: { hasValidProfile: false } });
  assert.equal(withoutProfile.state, 'unconfigured');
  assert.equal(withoutProfile.epoch, 8);
});

test('迁移 13：profileRemoved 从任何非 unconfigured 状态回到 unconfigured', () => {
  for (const state of ['stopped', 'preparing', 'connected', 'failed', 'unauthorized']) {
    const out = run({ state: state, event: 'profileRemoved' });
    assert.equal(out.state, 'unconfigured');
    assert.equal(out.epoch, 2);
    assert.equal(out.rejected, undefined);
  }
  const absent = run({ state: 'unconfigured', event: 'profileRemoved' });
  assert.equal(absent.state, 'unconfigured');
  assert.equal(absent.rejected.code, 'illegal_transition');
  assert.equal(absent.rejected.detail, 'profile_already_absent');
});

// ---------------------------------------------------------------------------
// 非法迁移：6 条以上全部 rejected，状态与 epoch 不变
// ---------------------------------------------------------------------------

test('非法迁移：6 条越界事件全部 rejected 并累计 illegalTransitions', () => {
  const cases = [
    { state: 'stopped', event: 'evidenceReady', detail: 'evidence_requires_preparing' },
    { state: 'connected', event: 'enableRequested', detail: 'enable_requires_stopped' },
    { state: 'unconfigured', event: 'profileRemoved', detail: 'profile_already_absent' },
    { state: 'preparing', event: 'stopRequested', detail: 'stop_requires_connected' },
    { state: 'connected', event: 'retryRequested', detail: 'retry_requires_unauthorized_or_failed' },
    { state: 'stopped', event: 'prepareTimeout', detail: 'timeout_requires_preparing' },
    { state: 'connected', event: 'evidenceFailed', detail: 'evidence_failed_requires_preparing' },
    { state: 'preparing', event: 'importSucceeded', detail: 'import_requires_unconfigured' },
    { state: 'stopped', event: 'authDenied', detail: 'auth_denied_requires_active_session' },
    { state: 'failed', event: 'linkLost', detail: 'link_lost_outside_session' },
  ];
  let expectedCount = 0;
  for (const item of cases) {
    const out = run({ state: item.state, event: item.event, epoch: 6, illegalTransitions: expectedCount });
    expectedCount++;
    assert.equal(out.rejected.code, 'illegal_transition', item.state + '/' + item.event);
    assert.equal(out.rejected.detail, item.detail);
    assert.equal(out.state, item.state);
    assert.equal(out.epoch, 6);
    assert.equal(out.changed, false);
    assert.equal(out.record.from, item.state);
    assert.equal(out.record.to, item.state);
    assert.equal(out.illegalTransitions, expectedCount);
    assert.equal(out.staleEpochEvents, 0);
  }
  assert.ok(expectedCount >= 6);
});

test('非法迁移不改变重连计数，也不影响 stale 计数', () => {
  const out = run({
    state: 'preparing',
    event: 'stopRequested',
    epoch: 6,
    reconnectAttempts: 3,
    stateReason: 'reconnect',
    illegalTransitions: 4,
    staleEpochEvents: 2,
  });
  assert.equal(out.rejected.code, 'illegal_transition');
  assert.equal(out.reconnectAttempts, 3);
  assert.equal(out.illegalTransitions, 5);
  assert.equal(out.staleEpochEvents, 2);
  assert.equal(out.state, 'preparing');
  assert.equal(out.epoch, 6);
});

// ---------------------------------------------------------------------------
// stale_epoch 丢弃
// ---------------------------------------------------------------------------

test('旧 epoch 事件按 stale_epoch 丢弃，不改状态与当前 epoch', () => {
  const out = run({
    state: 'connected',
    event: 'linkLost',
    epoch: 7,
    facts: { epoch: 6 },
    reconnectAttempts: 2,
    staleEpochEvents: 4,
  });
  assert.equal(out.rejected.code, 'stale_epoch');
  assert.equal(out.rejected.detail, 'event_epoch_mismatch');
  assert.equal(out.state, 'connected');
  assert.equal(out.epoch, 7);
  assert.equal(out.changed, false);
  assert.equal(out.staleEpochEvents, 5);
  assert.equal(out.illegalTransitions, 0);
  assert.equal(out.reconnectAttempts, 2);
  assert.equal(out.record.from, 'connected');
  assert.equal(out.record.to, 'connected');
});

test('旧 epoch 的 preparing 证据不会被当作 connected 证据', () => {
  const out = run({ state: 'preparing', event: 'evidenceReady', epoch: 8, facts: { epoch: 7 } });
  assert.equal(out.state, 'preparing');
  assert.equal(out.rejected.code, 'stale_epoch');
  assert.equal(out.staleEpochEvents, 1);
  // 反向验证：同一 epoch 才允许进入 connected。
  const fresh = run({ state: 'preparing', event: 'evidenceReady', epoch: 8, facts: { epoch: 8 } });
  assert.equal(fresh.state, 'connected');
});

test('appRestarted 是本地重建事件，不受 epoch 守卫限制', () => {
  const out = run({ state: 'connected', event: 'appRestarted', epoch: 3, facts: { epoch: 99 } });
  assert.equal(out.rejected, undefined);
  assert.equal(out.state, 'stopped');
  assert.equal(out.epoch, 4);
  assert.equal(out.staleEpochEvents, 0);
});

test('非法 epoch 输入按非法迁移拒绝而不是静默通过', () => {
  for (const epoch of [-1, Number.NaN, Number.POSITIVE_INFINITY]) {
    const out = run({ state: 'stopped', event: 'enableRequested', epoch: epoch, facts: { epoch: epoch } });
    assert.equal(out.rejected.code, 'illegal_transition');
    assert.equal(out.rejected.detail, 'invalid_epoch');
    assert.equal(out.state, 'stopped');
    assert.equal(out.illegalTransitions, 1);
  }
});

// ---------------------------------------------------------------------------
// 60 s 超时
// ---------------------------------------------------------------------------

test('60 s 预算：59999 ms 不超时，60000/60001 ms 超时', () => {
  const base = { state: 'preparing', epoch: 2, event: 'evidenceReady', facts: { evidence: ALL_READY, hasValidProfile: true, epoch: 2 }, preparingStartedAtMs: 1000 };
  assert.equal(isPreparingExpired({ ...base, nowMs: 1000 + 59999 }), false);
  assert.equal(isPreparingExpired({ ...base, nowMs: 1000 + 60000 }), true);
  assert.equal(isPreparingExpired({ ...base, nowMs: 1000 + 60001 }), true);
});

test('60 s 预算只在 preparing 且两个时间点都合法时生效', () => {
  const input = { state: 'connected', epoch: 1, event: 'evidenceReady', facts: { evidence: ALL_READY, hasValidProfile: true, epoch: 1 }, nowMs: 100000, preparingStartedAtMs: 0 };
  assert.equal(isPreparingExpired(input), false);
  assert.equal(isPreparingExpired({ ...input, state: 'preparing', nowMs: undefined }), false);
  assert.equal(isPreparingExpired({ ...input, state: 'preparing', preparingStartedAtMs: undefined }), false);
  assert.equal(isPreparingExpired({ ...input, state: 'preparing', nowMs: Number.NaN }), false);
});

test('超时后迟到的证据与失败事件都落 failed(timeout)，不进入 connected', () => {
  for (const event of ['evidenceReady', 'evidenceFailed']) {
    const out = run({
      state: 'preparing',
      event: event,
      epoch: 2,
      nowMs: 60000,
      preparingStartedAtMs: 0,
      facts: { epoch: 2, evidence: ALL_READY },
    });
    assert.equal(out.state, 'failed', event);
    assert.equal(out.epoch, 3);
    assert.equal(out.record.errorCode, 'timeout');
    assert.equal(out.changed, true);
  }
});

test('未注入时间时不伪造超时，evidenceReady 正常进入 connected', () => {
  const out = run({ state: 'preparing', event: 'evidenceReady', preparingStartedAtMs: 0 });
  assert.equal(out.state, 'connected');
  assert.equal(out.preparingDeadlineMs, undefined);
});

// ---------------------------------------------------------------------------
// 重连预算
// ---------------------------------------------------------------------------

test('重连预算：5 次退避 1/2/4/8/16 s 后第 6 次 failed(extension_crashed)', () => {
  let state = 'connected';
  let epoch = 10;
  let attempts = 0;
  let stateReason = undefined;
  let nowMs = 1000;
  const delays = RECONNECT_BACKOFF_MS;
  for (let attempt = 1; attempt <= RECONNECT_MAX_ATTEMPTS; attempt++) {
    const out = transition({
      state: state,
      epoch: epoch,
      event: 'linkLost',
      stateReason: stateReason,
      reconnectAttempts: attempts,
      nowMs: nowMs,
      preparingStartedAtMs: nowMs,
      facts: { evidence: ALL_READY, hasValidProfile: true, epoch: epoch },
    });
    assert.equal(out.rejected, undefined, 'attempt ' + attempt);
    assert.equal(out.state, 'preparing');
    assert.equal(out.record.reason, 'reconnect');
    assert.equal(out.reconnectAttempts, attempt);
    assert.equal(out.nextRetryDelayMs, delays[attempt - 1]);
    assert.equal(out.epoch, epoch + 1);
    state = out.state;
    epoch = out.epoch;
    attempts = out.reconnectAttempts;
    stateReason = 'reconnect';
    nowMs += delays[attempt - 1];
  }
  const exhausted = transition({
    state: state,
    epoch: epoch,
    event: 'linkLost',
    stateReason: stateReason,
    reconnectAttempts: attempts,
    nowMs: nowMs,
    preparingStartedAtMs: nowMs,
    facts: { evidence: ALL_READY, hasValidProfile: true, epoch: epoch },
  });
  assert.equal(exhausted.state, 'failed');
  assert.equal(exhausted.record.errorCode, 'extension_crashed');
  assert.equal(exhausted.reconnectAttempts, RECONNECT_MAX_ATTEMPTS);
  assert.equal(exhausted.nextRetryDelayMs, undefined);
  assert.equal(exhausted.epoch, epoch + 1);
});

test('重连预算：首启 preparing 的断线不累加重连次数而是被拒绝', () => {
  const out = run({ state: 'preparing', event: 'linkLost', stateReason: 'start', reconnectAttempts: 0 });
  assert.equal(out.state, 'preparing');
  assert.equal(out.rejected.code, 'illegal_transition');
  assert.equal(out.rejected.detail, 'link_lost_outside_session');
  assert.equal(out.illegalTransitions, 1);
});

test('reconnectExhausted 只在重连中的 preparing 生效', () => {
  const ok = run({ state: 'preparing', event: 'reconnectExhausted', stateReason: 'reconnect', reconnectAttempts: 4 });
  assert.equal(ok.state, 'failed');
  assert.equal(ok.record.errorCode, 'extension_crashed');
  assert.equal(ok.reconnectAttempts, RECONNECT_MAX_ATTEMPTS);
  const wrongReason = run({ state: 'preparing', event: 'reconnectExhausted', stateReason: 'apply' });
  assert.equal(wrongReason.state, 'preparing');
  assert.equal(wrongReason.rejected.code, 'illegal_transition');
  assert.equal(wrongReason.rejected.detail, 'exhausted_requires_reconnect');
  const wrongState = run({ state: 'connected', event: 'reconnectExhausted', stateReason: 'reconnect' });
  assert.equal(wrongState.state, 'connected');
  assert.equal(wrongState.rejected.code, 'illegal_transition');
});

// ---------------------------------------------------------------------------
// 兜底、纯度与辅助函数
// ---------------------------------------------------------------------------

test('未知事件按 illegal_transition 兜底，不抛异常', () => {
  const out = run({ state: 'stopped', event: 'bogusEvent' });
  assert.equal(out.rejected.code, 'illegal_transition');
  assert.equal(out.rejected.detail, 'unsupported_event');
  assert.equal(out.state, 'stopped');
  assert.equal(out.illegalTransitions, 1);
});

test('transition 是纯函数：不修改输入，重复调用结果一致', () => {
  const input = {
    state: 'preparing',
    epoch: 3,
    event: 'evidenceReady',
    facts: { evidence: ALL_READY, hasValidProfile: true, epoch: 3 },
    illegalTransitions: 1,
    staleEpochEvents: 2,
  };
  const snapshot = JSON.stringify(input);
  const first = transition(input);
  const second = transition(input);
  assert.equal(JSON.stringify(input), snapshot);
  assert.deepEqual(first, second);
  assert.notEqual(first, input);
  assert.notEqual(first.record, input.facts);
});

test('resolvePreparingReason 依据当前状态与事实给出可展示原因', () => {
  assert.equal(resolvePreparingReason({ state: 'preparing', epoch: 1, event: 'evidenceReady', facts: { evidence: ALL_READY, hasValidProfile: true, epoch: 1 }, stateReason: 'scope' }), 'scope');
  assert.equal(resolvePreparingReason({ state: 'preparing', epoch: 1, event: 'evidenceReady', facts: { evidence: ALL_READY, hasValidProfile: true, epoch: 1 } }), 'start');
  assert.equal(resolvePreparingReason({ state: 'stopped', epoch: 1, event: 'enableRequested', facts: { evidence: ALL_READY, hasValidProfile: true, epoch: 1, reason: 'apply' } }), 'apply');
  assert.equal(resolvePreparingReason({ state: 'stopped', epoch: 1, event: 'enableRequested', facts: { evidence: ALL_READY, hasValidProfile: true, epoch: 1 } }), 'start');
});

test('计数输入容错：负数/非有限值不污染诊断', () => {
  const out = run({
    state: 'stopped',
    event: 'stopRequested',
    illegalTransitions: -5,
    staleEpochEvents: Number.NaN,
    reconnectAttempts: -2,
  });
  assert.equal(out.illegalTransitions, 1);
  assert.equal(out.staleEpochEvents, 0);
  assert.equal(out.reconnectAttempts, 0);
});