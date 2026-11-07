import test from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const {
  hashName,
  redactAndTruncateUrl,
  redactHost,
  redactUrl,
  safeError,
  truncate,
} = require('../../artifacts/tests/js/model/ClashRedaction.js');

// 虚构夹具：example.invalid 域名、node-a 节点、全零 UUID；不含真实订阅或账号。
const ZERO_UUID = '00000000-0000-0000-0000-000000000000';
const SECRET_TOKEN = 'SECRET_TOKEN_VALUE';
const SECRET_PASSWORD = 'SECRET_PASSWORD_VALUE';

// ---------------------------------------------------------------------------
// redactUrl：userinfo / query / fragment / 超长 path
// ---------------------------------------------------------------------------

test('redactUrl 丢弃 userinfo 与订阅 token，只保留 scheme、域名摘要和端口', () => {
  const output = redactUrl('https://node-a:' + SECRET_PASSWORD + '@sub.example.invalid:8443/api/v1?token=' + SECRET_TOKEN + '#frag');
  assert.equal(output, 'https://example.invalid:8443');
});

test('redactUrl 丢弃 query，不保留 token 键与值', () => {
  const output = redactUrl('https://sub.example.invalid/api?token=' + SECRET_TOKEN + '&uuid=' + ZERO_UUID);
  assert.equal(output, 'https://example.invalid');
  assert.equal(output.includes('token'), false);
  assert.equal(output.includes(ZERO_UUID), false);
});

test('redactUrl 丢弃 fragment', () => {
  assert.equal(redactUrl('https://example.invalid/path#token=' + SECRET_TOKEN), 'https://example.invalid');
  assert.equal(redactUrl('https://example.invalid#/node-a'), 'https://example.invalid');
});

test('redactUrl 丢弃超长 path，且超长输入整体判为 invalid-url', () => {
  const longPath = 'a'.repeat(4000);
  const output = redactUrl('https://example.invalid/' + longPath + '?token=' + SECRET_TOKEN);
  assert.equal(output, 'https://example.invalid');
  assert.equal(output.includes('a'.repeat(100)), false);
  assert.equal(redactUrl('https://example.invalid/' + 'a'.repeat(9000)), 'invalid-url');
  assert.equal(redactUrl('https://example.invalid?a=' + 'b'.repeat(9000)), 'invalid-url');
});

test('redactUrl 保留合法端口，丢弃非法端口但不回显输入', () => {
  assert.equal(redactUrl('https://example.invalid:8443/x'), 'https://example.invalid:8443');
  assert.equal(redactUrl('https://example.invalid:443/x'), 'https://example.invalid:443');
  assert.equal(redactUrl('https://example.invalid:0/x'), 'https://example.invalid');
  assert.equal(redactUrl('https://example.invalid:65536/x'), 'https://example.invalid');
  assert.equal(redactUrl('https://example.invalid:abc/x'), 'https://example.invalid');
});

test('redactUrl 对 IPv4/IPv6 只保留非标识前缀', () => {
  assert.equal(redactUrl('https://192.0.2.10:8080/' + SECRET_TOKEN), 'https://192.0.*.*:8080');
  assert.equal(redactUrl('https://[2001:db8:85a3::8a2e]:8443/x'), 'https://[2001:db8:*]:8443');
});

test('redactUrl 拒绝畸形输入并统一返回 invalid-url', () => {
  const invalid = [
    '',
    '   ',
    'example.invalid',
    'https:/example.invalid',
    'https:example.invalid',
    'https://',
    'https:///path',
    'https://user@',
    'https://user:pass@',
    'https://a:b:80/x',
    'https://exa mple.invalid/x',
    'https://example.invalid/x\ny',
    'https://example.invalid/x\u0000',
    'https://exa\tmple.invalid/x',
    'https://unterminated[::1/x',
    '1https://example.invalid',
    'a'.repeat(9000),
  ];
  for (const value of invalid) {
    assert.equal(redactUrl(value), 'invalid-url', JSON.stringify(value).slice(0, 40));
  }
  for (const value of [undefined, null, 42, {}, []]) {
    assert.equal(redactUrl(value), 'invalid-url', String(value));
  }
});

test('redactHost 只保留域名末两段与 IP 前缀，畸形输入不回显', () => {
  assert.equal(redactHost('sub.example.invalid'), 'example.invalid');
  assert.equal(redactHost('node-a.example.invalid'), 'example.invalid');
  assert.equal(redactHost('Example.INVALID.'), 'example.invalid');
  assert.equal(redactHost('localhost'), 'localhost');
  assert.equal(redactHost('192.0.2.10'), '192.0.*.*');
  assert.equal(redactHost('2001:db8:85a3::8a2e'), '2001:db8:*');
  assert.equal(redactHost('[2001:db8::1]'), '2001:db8:*');
  for (const value of ['', '   ', 'exa mple.invalid', 'example.invalid:80', '192.0.2', '999.1.1.1', 'a_b.example.invalid', 'x'.repeat(254)]) {
    assert.equal(redactHost(value), 'invalid-host', JSON.stringify(value).slice(0, 40));
  }
});

test('脱敏输出中不出现原始 token、密码或全零 UUID', () => {
  const fixtures = [
    'https://node-a:' + SECRET_PASSWORD + '@sub.example.invalid:8443/api/v1?token=' + SECRET_TOKEN + '#' + ZERO_UUID,
    'https://example.invalid/subscribe/' + ZERO_UUID + '?password=' + SECRET_PASSWORD,
    'https://example.invalid/' + ZERO_UUID + '/' + 'x'.repeat(2000) + '?token=' + SECRET_TOKEN,
    'https://192.0.2.10:8080/' + ZERO_UUID + '?token=' + SECRET_TOKEN,
    'https://node-a.example.invalid/?uuid=' + ZERO_UUID + '&password=' + SECRET_PASSWORD,
  ];
  for (const fixture of fixtures) {
    const output = redactUrl(fixture);
    assert.notEqual(output, 'invalid-url', fixture);
    assert.equal(output.includes(SECRET_TOKEN), false);
    assert.equal(output.includes(SECRET_PASSWORD), false);
    assert.equal(output.includes(ZERO_UUID), false);
    assert.equal(output.includes('node-a'), false);
    assert.equal(output.includes('password'), false);
    assert.equal(output.includes('token'), false);
    assert.equal(output.includes('user'), false);
  }
});

// ---------------------------------------------------------------------------
// hashName：稳定性与格式
// ---------------------------------------------------------------------------

test('hashName 同输入两次一致，不同输入不同', () => {
  const first = hashName('node-a');
  const second = hashName('node-a');
  assert.equal(first, second);
  assert.match(first, /^n-[0-9a-f]{8}$/);
  assert.notEqual(hashName('node-a'), hashName('node-b'));
  assert.notEqual(hashName('node-a'), hashName('node-a.example.invalid'));
});

test('hashName trim 后等价，空输入返回 n-empty', () => {
  assert.equal(hashName('  node-a  '), hashName('node-a'));
  for (const value of ['', '   ', undefined, null, 42]) {
    assert.equal(hashName(value), 'n-empty', String(value));
  }
});

test('hashName 输出不含原始节点名', () => {
  const output = hashName('node-a');
  assert.equal(output.includes('node-a'), false);
  assert.match(hashName('我的节点'), /^n-[0-9a-f]{8}$/);
});

// ---------------------------------------------------------------------------
// truncate / redactAndTruncateUrl
// ---------------------------------------------------------------------------

test('truncate 不切开代理对与 emoji 组合', () => {
  assert.equal(truncate('😀😀', 2), '😀');
  assert.equal(truncate('😀😀', 3), '😀');
  assert.equal(truncate('ab😀', 2), 'ab');
  assert.equal(truncate('ab😀', 3), 'ab');
  assert.equal(truncate('🇨🇳', 2), '');
  assert.equal(truncate('abcdef', 4), 'abcd');
  assert.equal(truncate('abcdef', 0), '');
  assert.equal(truncate('abcdef', -1), '');
  assert.equal(truncate('abcdef', Number.NaN), '');
  assert.equal(truncate('', 10), '');
});

test('redactAndTruncateUrl 先脱敏后截断，invalid-url 保持原样', () => {
  assert.equal(redactAndTruncateUrl('https://example.invalid/aaa?token=' + SECRET_TOKEN, 10), 'https://ex');
  assert.equal(redactAndTruncateUrl('https://example.invalid/x', 100), 'https://example.invalid');
  assert.equal(redactAndTruncateUrl('not a url', 10), 'invalid-url');
});

// ---------------------------------------------------------------------------
// safeError：只暴露 code/detailCode
// ---------------------------------------------------------------------------

test('safeError 不复制 message/stack/URL，只保留分类码', () => {
  const error = new Error('https://node-a:' + SECRET_PASSWORD + '@example.invalid/?token=' + SECRET_TOKEN);
  error.code = 'config_invalid';
  error.detailCode = 'ParseError';
  const safe = safeError(error);
  assert.deepEqual(safe, { code: 'config_invalid', detailCode: 'parseerror' });
  assert.equal(JSON.stringify(safe).includes('SECRET'), false);
  assert.equal(JSON.stringify(safe).includes('example.invalid'), false);
  assert.equal(safe.message, undefined);
  assert.equal(safe.stack, undefined);
});

test('safeError 对字符串码归一化，凭据形态与路径一律拒绝', () => {
  assert.deepEqual(safeError('CONFIG_INVALID'), { code: 'config_invalid' });
  assert.deepEqual(safeError(' timeout '), { code: 'timeout' });
  assert.deepEqual(safeError(ZERO_UUID), { code: 'unknown' });
  assert.deepEqual(safeError('0123456789abcdef'), { code: 'unknown' });
  assert.deepEqual(safeError('/data/app/clash/profile-1.yaml'), { code: 'unknown' });
  assert.deepEqual(safeError('x'.repeat(33)), { code: 'unknown' });
  assert.deepEqual(safeError(''), { code: 'unknown' });
});

test('safeError 支持数字码与 HTTP 状态码，越界值归 unknown', () => {
  assert.deepEqual(safeError({ code: 502 }), { code: 'http_502' });
  assert.deepEqual(safeError({ code: 100 }), { code: 'http_100' });
  assert.deepEqual(safeError({ code: 700 }), { code: 'code_700' });
  assert.deepEqual(safeError({ status: 404 }), { code: 'http_404' });
  assert.deepEqual(safeError({ statusCode: 503 }), { code: 'http_503' });
  assert.deepEqual(safeError({ code: '', status: 500 }), { code: 'http_500' });
  assert.deepEqual(safeError({ code: 1000000 }), { code: 'unknown' });
  assert.deepEqual(safeError({ status: 99 }), { code: 'unknown' });
  assert.deepEqual(safeError({ code: Number.NaN }), { code: 'unknown' });
});

test('safeError 只暴露标准错误类名，任意 name 被丢弃', () => {
  assert.deepEqual(safeError({ name: 'TypeError' }), { code: 'typeerror' });
  assert.deepEqual(safeError({ name: 'RangeError' }), { code: 'rangeerror' });
  assert.deepEqual(safeError({ name: 'CustomError', message: 'SECRET' }), { code: 'unknown' });
  assert.deepEqual(safeError({ name: 'Error' }), { code: 'unknown' });
});

test('safeError 的 detailCode 与 code 相同则省略，缺失或为 null 时归 unknown', () => {
  assert.deepEqual(safeError({ code: 'timeout', detailCode: 'timeout' }), { code: 'timeout' });
  assert.deepEqual(safeError({ code: 'timeout', errorCode: 'proxy_timeout' }), { code: 'timeout', detailCode: 'proxy_timeout' });
  assert.deepEqual(safeError({ code: 'timeout', detailCode: 'Timeout' }), { code: 'timeout' });
  assert.deepEqual(safeError({ code: 'timeout', detailCode: 'Proxy-Timeout' }), { code: 'timeout', detailCode: 'proxy-timeout' });
  assert.deepEqual(safeError(null), { code: 'unknown' });
  assert.deepEqual(safeError(undefined), { code: 'unknown' });
  assert.deepEqual(safeError({}), { code: 'unknown' });
});