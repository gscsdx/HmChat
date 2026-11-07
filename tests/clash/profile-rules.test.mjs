import test from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const {
  buildPrevFileName,
  buildProfileFileName,
  deriveProfileId,
  isSameContent,
  isValidProfileId,
  mergeSelectedMap,
  sanitizeDisplayName,
} = require('../../artifacts/tests/js/model/ClashProfileRules.js');

// 虚构夹具：example.invalid 域名、node-a 节点；不含真实订阅、账号或节点凭据。
const FALLBACK_NAME = '未命名配置';

// ---------------------------------------------------------------------------
// profile id：12 类非法输入 + 合法边界
// ---------------------------------------------------------------------------

test('12 类非法 profileId 全部拒绝（点、点点、斜杠、反斜杠、NUL、超长、空、中文、URL 编码、绝对路径、冒号、问号）', () => {
  const invalid = [
    '.',
    '..',
    'a/b',
    'a\\b',
    'a\u0000b',
    'a'.repeat(65),
    '',
    '中文配置',
    '%2e%2e',
    '/data/app/clash/profile-1',
    'profile:1',
    'profile?token=node-a',
  ];
  assert.equal(invalid.length, 12);
  for (const id of invalid) {
    assert.equal(isValidProfileId(id), false, JSON.stringify(id));
  }
});

test('额外拒绝空白、长度 0/65、编码绕过与换行', () => {
  const invalid = [
    ' profile',
    'profile ',
    'pro file',
    'pro\tfile',
    'pro\nfile',
    'pro\u00A0file',
    'pro\u3000file',
    '%2f',
    'a%5cb',
    'a'.repeat(65),
    'a'.repeat(66),
    'a\na',
  ];
  for (const id of invalid) {
    assert.equal(isValidProfileId(id), false, JSON.stringify(id));
  }
});

test('合法 profileId 边界：1 与 64 字符、字母数字连字符下划线', () => {
  const valid = ['a', 'A', '0', '_', '-', 'a-b', 'a_b', 'A1_b-2', 'profile', 'x'.repeat(64)];
  for (const id of valid) {
    assert.equal(isValidProfileId(id), true, JSON.stringify(id));
  }
  assert.equal(isValidProfileId('x'.repeat(64)), true);
  assert.equal(isValidProfileId('x'.repeat(65)), false);
});

test('非字符串 profileId 一律拒绝', () => {
  for (const value of [undefined, null, 0, 1, true, {}, []]) {
    assert.equal(isValidProfileId(value), false, String(value));
  }
});

test('配置文件名构造使用固定后缀，非法 id 抛固定错误码且不回显输入', () => {
  assert.equal(buildProfileFileName('profile-1'), 'profile-1.yaml');
  assert.equal(buildPrevFileName('profile-1'), 'profile-1.prev.yaml');
  const secrets = ['../node-a', 'a/b', 'C:\\profile', '中文配置', 'x'.repeat(65)];
  for (const id of secrets) {
    for (const build of [buildProfileFileName, buildPrevFileName]) {
      assert.throws(
        () => build(id),
        (error) => {
          assert.equal(error.message, 'invalid_profile_id');
          assert.equal(error.message.includes(id), false);
          assert.equal(error.message.includes('node-a'), false);
          return true;
        },
        String(id),
      );
    }
  }
});

// ---------------------------------------------------------------------------
// deriveProfileId
// ---------------------------------------------------------------------------

test('deriveProfileId 把 URL 与非法字符压缩为安全 id', () => {
  assert.equal(
    deriveProfileId('https://sub.example.invalid/api?token=node-a'),
    'https-sub-example-invalid-api-token-node-a',
  );
  assert.equal(deriveProfileId('a.b'), 'a-b');
  assert.equal(deriveProfileId('a::b'), 'a-b');
  assert.equal(deriveProfileId('--a--'), 'a');
  assert.equal(deriveProfileId('node_a'), 'node_a');
});

test('deriveProfileId 空或仅非法字符时回退 profile，并截断到 64', () => {
  for (const seed of ['', '   ', '...', '中文', '///', undefined, null, 42]) {
    assert.equal(deriveProfileId(seed), 'profile', String(seed));
  }
  const long = deriveProfileId('a'.repeat(100));
  assert.equal(long.length, 64);
  assert.equal(long, 'a'.repeat(64));
  const dashed = deriveProfileId('a'.repeat(100) + '-');
  assert.equal(dashed.length, 64);
  assert.equal(dashed.endsWith('-'), false);
});

test('deriveProfileId 的结果始终满足 profileId 白名单', () => {
  const seeds = [
    'https://sub.example.invalid/a/b?c=d#e',
    '2001:db8::1',
    'user:pass@host',
    'a b c',
    '中文.example.invalid',
    'x'.repeat(200),
  ];
  for (const seed of seeds) {
    const id = deriveProfileId(seed);
    assert.equal(isValidProfileId(id), true, seed + ' -> ' + id);
    assert.equal(id.length <= 64, true);
  }
});

// ---------------------------------------------------------------------------
// sanitizeDisplayName
// ---------------------------------------------------------------------------

test('sanitizeDisplayName 去控制字符、零宽字符与双向控制符，压缩空白', () => {
  assert.equal(sanitizeDisplayName('  我的 配置  '), '我的 配置');
  assert.equal(sanitizeDisplayName('a\u0000b\u007Fc'), 'a b c');
  assert.equal(sanitizeDisplayName('a\u200Bb\u202Ec'), 'a b c');
  assert.equal(sanitizeDisplayName('a\u0085b'), 'a b');
  assert.equal(sanitizeDisplayName('node-a\tnode-b'), 'node-a node-b');
});

test('sanitizeDisplayName 空结果回退「未命名配置」', () => {
  for (const raw of ['', '   ', '\u0000\u0001', '\u200B\u202E', '\uFEFF']) {
    assert.equal(sanitizeDisplayName(raw), FALLBACK_NAME, JSON.stringify(raw));
  }
  assert.equal(sanitizeDisplayName(undefined), FALLBACK_NAME);
  assert.equal(sanitizeDisplayName(42), FALLBACK_NAME);
});

test('sanitizeDisplayName 64 字符边界且不切开代理对', () => {
  const exactly = 'x'.repeat(64);
  assert.equal(sanitizeDisplayName(exactly), exactly);
  assert.equal(sanitizeDisplayName('x'.repeat(63) + 'y' + 'z'), 'x'.repeat(63) + 'y');
  const emojiAtEdge = sanitizeDisplayName('x'.repeat(63) + '😀');
  assert.equal(emojiAtEdge, 'x'.repeat(63));
  assert.equal(emojiAtEdge.length, 63);
  assert.equal(sanitizeDisplayName('x'.repeat(70)).length, 64);
});

test('sanitizeDisplayName 与已有名重名时追加序号', () => {
  assert.equal(sanitizeDisplayName('我的配置', ['我的配置']), '我的配置 (2)');
  assert.equal(sanitizeDisplayName('我的配置', ['我的配置', '我的配置 (2)']), '我的配置 (3)');
  assert.equal(sanitizeDisplayName('我的配置', ['node-a']), '我的配置');
  assert.equal(sanitizeDisplayName('我的配置', undefined), '我的配置');
  assert.equal(sanitizeDisplayName('我的配置', 'not-an-array'), '我的配置');
});

test('sanitizeDisplayName 追加序号后仍不超过 64 字符', () => {
  const base = 'n'.repeat(64);
  const renamed = sanitizeDisplayName(base, [base]);
  assert.equal(renamed.length, 64);
  assert.equal(renamed.endsWith(' (2)'), true);
  assert.equal(renamed.startsWith('n'.repeat(60)), true);
  const third = sanitizeDisplayName(base, [base, renamed]);
  assert.equal(third.length, 64);
  assert.equal(third.endsWith(' (3)'), true);
});

// ---------------------------------------------------------------------------
// selectedMap 合并
// ---------------------------------------------------------------------------

test('mergeSelectedMap 中 next 的非空值优先', () => {
  assert.deepEqual(mergeSelectedMap({ g1: 'node-a' }, { g1: 'node-b' }, ['g1']), { g1: 'node-b' });
  assert.deepEqual(mergeSelectedMap({}, { g1: 'node-b' }, ['g1']), { g1: 'node-b' });
  assert.deepEqual(mergeSelectedMap({ g1: '  node-b  ' }, {}, ['g1']), { g1: 'node-b' });
});

test('mergeSelectedMap 丢弃空值并回退到 current，绝不产生空串', () => {
  assert.deepEqual(mergeSelectedMap({ g1: 'node-a' }, { g1: '   ' }, ['g1']), { g1: 'node-a' });
  assert.deepEqual(mergeSelectedMap({ g1: 'node-a' }, {}, ['g1']), { g1: 'node-a' });
  assert.deepEqual(mergeSelectedMap({ g1: 'node-a' }, { g1: '' }, ['g1']), { g1: 'node-a' });
  assert.deepEqual(mergeSelectedMap({ g1: '' }, { g1: '  ' }, ['g1']), {});
  assert.deepEqual(mergeSelectedMap({ g1: null }, { g1: 42 }, ['g1']), {});
});

test('mergeSelectedMap 剔除不存在的组与非法组名', () => {
  assert.deepEqual(mergeSelectedMap({ gone: 'node-a' }, { gone: 'node-b' }, ['g1']), {});
  assert.deepEqual(mergeSelectedMap({}, { unknown: 'node-b' }, ['g1']), {});
  assert.deepEqual(mergeSelectedMap({ g1: 'node-a' }, { g1: 'node-b' }, []), {});
  assert.deepEqual(mergeSelectedMap({ g1: 'node-a' }, { g1: 'node-b' }, 'g1'), {});
  assert.deepEqual(mergeSelectedMap({ g1: 'node-a' }, { g1: 'node-b' }, ['g1', '', 42]), { g1: 'node-b' });
});

test('mergeSelectedMap 不修改入参且返回新对象', () => {
  const current = { g1: 'node-a', gone: 'node-x' };
  const next = { g1: 'node-b', extra: 'node-y' };
  const currentSnapshot = JSON.stringify(current);
  const nextSnapshot = JSON.stringify(next);
  const merged = mergeSelectedMap(current, next, ['g1']);
  assert.deepEqual(merged, { g1: 'node-b' });
  assert.equal(JSON.stringify(current), currentSnapshot);
  assert.equal(JSON.stringify(next), nextSnapshot);
  assert.notEqual(merged, current);
  assert.notEqual(merged, next);
});

// ---------------------------------------------------------------------------
// 内容 hash 等价
// ---------------------------------------------------------------------------

test('isSameContent 忽略大小写与首尾空白，但空值不代表相同', () => {
  assert.equal(isSameContent('ABC', 'abc'), true);
  assert.equal(isSameContent(' abc ', 'ABC'), true);
  assert.equal(isSameContent('abc', 'abc'), true);
  assert.equal(isSameContent('abc', 'abd'), false);
  assert.equal(isSameContent('', 'abc'), false);
  assert.equal(isSameContent('abc', ''), false);
  assert.equal(isSameContent('', ''), false);
  assert.equal(isSameContent('   ', 'abc'), false);
  assert.equal(isSameContent(undefined, 'abc'), false);
  assert.equal(isSameContent('abc', null), false);
});