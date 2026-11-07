/**
 * T-S1-16 订阅边界单元测试（设计 §10.2-§10.3）。
 *
 * 覆盖任务卡：8 MiB 三档、BOM/NUL/非法 UTF-8、userinfo 拒绝、
 * content-disposition、subscription-userinfo 非法值、base64 提示、显示名回退。
 *
 * 8 MiB 夹具在测试内动态生成，不写入 Git；全部主机使用 example.invalid。
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const {
  validateUrl,
  parseResponseHeaders,
  checkBody,
  deriveDisplayName,
  looksLikeBase64Subscription,
  MAX_SUBSCRIPTION_URL_LENGTH,
  MAX_SUBSCRIPTION_BODY_BYTES,
} = require('../../artifacts/tests/js/model/ClashSubscriptionParser.js');

/** 生成确定性的 ASCII 字节夹具（不落盘）。 */
function asciiBytes(length, fill = 0x61) {
  const bytes = new Uint8Array(length);
  bytes.fill(fill);
  return bytes;
}

test('订阅 URL：仅 http/https，http 提示明文，https 不提示', () => {
  const https = validateUrl('https://example.invalid/sub?token=fixture');
  assert.equal(https.ok, true);
  assert.equal(https.code, '');
  assert.equal(https.plaintextWarning, false);

  const http = validateUrl('http://example.invalid/sub');
  assert.equal(http.ok, true);
  assert.equal(http.plaintextWarning, true);

  // scheme 大小写不敏感；端口合法。
  assert.equal(validateUrl('HTTPS://Example.Invalid:8443/sub').ok, true);
  assert.equal(validateUrl('https://192.0.2.10/sub').ok, true);
  assert.equal(validateUrl('ftp://example.invalid/sub').detailCode, 'invalid_scheme');
  assert.equal(validateUrl('ftp://example.invalid/sub').code, 'unsupported');
});

test('订阅 URL 拒绝 userinfo 且提示不回显账号或口令', () => {
  const result = validateUrl('https://user:pass@example.invalid/sub');
  assert.equal(result.ok, false);
  assert.equal(result.code, 'config_invalid');
  assert.equal(result.detailCode, 'userinfo');
  assert.equal(typeof result.hint, 'string');
  assert.equal(result.hint.includes('账号'), true);
  assert.equal(result.hint.includes('user'), false);
  assert.equal(result.hint.includes('pass'), false);

  assert.equal(validateUrl('https://user@example.invalid/sub').detailCode, 'userinfo');
});

test('订阅 URL 拒绝空串、超长、空白/控制字符与畸形 authority', () => {
  assert.equal(validateUrl('').detailCode, 'empty');
  assert.equal(validateUrl(null).detailCode, 'empty');
  assert.equal(validateUrl('   ').detailCode, 'invalid_characters');
  assert.equal(validateUrl('https://example.invalid/a b').detailCode, 'invalid_characters');
  assert.equal(validateUrl('https://example.invalid/\u0000').detailCode, 'invalid_characters');
  assert.equal(validateUrl('https://example.invalid\\sub').detailCode, 'invalid_url');
  assert.equal(validateUrl('example.invalid/sub').detailCode, 'invalid_url');
  assert.equal(validateUrl('https://').detailCode, 'invalid_url');

  const tooLong = 'https://example.invalid/' + 'a'.repeat(MAX_SUBSCRIPTION_URL_LENGTH);
  assert.equal(tooLong.length > MAX_SUBSCRIPTION_URL_LENGTH, true);
  assert.equal(validateUrl(tooLong).detailCode, 'too_long');
  // 恰好等于上限仍接受。
  const prefix = 'https://example.invalid/';
  const exact = prefix + 'a'.repeat(MAX_SUBSCRIPTION_URL_LENGTH - prefix.length);
  assert.equal(exact.length, MAX_SUBSCRIPTION_URL_LENGTH);
  assert.equal(validateUrl(exact).ok, true);
});

test('订阅 URL 端口必须是 1..65535 的十进制整数', () => {
  for (const authority of [
    'example.invalid:0',
    'example.invalid:70000',
    'example.invalid:',
    'example.invalid:8a',
    'example.invalid:1:2',
  ]) {
    assert.equal(validateUrl('https://' + authority + '/sub').detailCode, 'invalid_url', authority);
  }
  assert.equal(validateUrl('https://example.invalid:1/sub').ok, true);
  assert.equal(validateUrl('https://example.invalid:65535/sub').ok, true);
});

test('content-disposition：引号、filename*、目录剥离与大小写不敏感', () => {
  assert.equal(
    parseResponseHeaders({ 'content-disposition': 'attachment; filename="sub.yaml"' }).disposition,
    'sub.yaml',
  );
  assert.equal(
    parseResponseHeaders({ 'Content-Disposition': 'inline; filename=fixture.yaml' }).disposition,
    'fixture.yaml',
  );
  assert.equal(
    parseResponseHeaders({ 'CONTENT-DISPOSITION': 'attachment; filename="/etc/sub.yaml"' }).disposition,
    'sub.yaml',
  );
  assert.equal(
    parseResponseHeaders({ 'content-disposition': 'attachment; filename="../../sub.yaml"' }).disposition,
    'sub.yaml',
  );
  // filename* 优先，且解码 UTF-8 百分号编码。
  assert.equal(
    parseResponseHeaders({
      'content-disposition': "attachment; filename=plain.yaml; filename*=UTF-8''%E8%AE%A2%E9%98%85.yaml",
    }).disposition,
    '订阅.yaml',
  );
  // 缺失或不含 filename 时不产生 disposition 键。
  assert.equal(Object.prototype.hasOwnProperty.call(parseResponseHeaders({}), 'disposition'), false);
  assert.equal(
    Object.prototype.hasOwnProperty.call(parseResponseHeaders({ 'content-disposition': 'attachment' }), 'disposition'),
    false,
  );
});

test('subscription-userinfo 逐项解析，非法项单独忽略', () => {
  assert.deepEqual(
    parseResponseHeaders({ 'subscription-userinfo': 'upload=1024; download=2048; total=4096; expire=1700000000' })
      .subscriptionInfo,
    { upload: 1024, download: 2048, total: 4096, expire: 1700000000 },
  );
  // 负数、小数、非数字、超出安全整数的值全部跳过。
  assert.deepEqual(
    parseResponseHeaders({ 'subscription-userinfo': 'upload=10; download=-1; total=1.5; expire=99999999999999999999' })
      .subscriptionInfo,
    { upload: 10 },
  );
  assert.equal(
    Object.prototype.hasOwnProperty.call(
      parseResponseHeaders({ 'subscription-userinfo': 'upload=x; download=; total=NaN' }),
      'subscriptionInfo',
    ),
    false,
  );
  // 未知键不进入模型。
  assert.deepEqual(parseResponseHeaders({ 'subscription-userinfo': 'upload=1; bogus=2' }).subscriptionInfo, {
    upload: 1,
  });
});

test('profile-update-interval 只接受正整数小时，其他头一律忽略', () => {
  assert.equal(parseResponseHeaders({ 'profile-update-interval': '24' }).updateIntervalHours, 24);
  for (const value of ['0', '-1', '1.5', 'abc', '']) {
    assert.equal(
      Object.prototype.hasOwnProperty.call(parseResponseHeaders({ 'profile-update-interval': value }), 'updateIntervalHours'),
      false,
      value,
    );
  }
  const ignored = parseResponseHeaders({
    'flclashx-device': 'secret',
    'x-hwid': 'fixture',
    'content-type': 'text/plain',
  });
  assert.deepEqual(ignored, {});
  assert.deepEqual(parseResponseHeaders(null), {});
});

test('正文 8 MiB 三档边界：limit-1 与 limit 通过，limit+1 拒绝', () => {
  assert.equal(MAX_SUBSCRIPTION_BODY_BYTES, 8388608);

  const below = checkBody(asciiBytes(MAX_SUBSCRIPTION_BODY_BYTES - 1));
  assert.equal(below.ok, true);
  assert.equal(below.text.length, MAX_SUBSCRIPTION_BODY_BYTES - 1);

  const exact = checkBody(asciiBytes(MAX_SUBSCRIPTION_BODY_BYTES));
  assert.equal(exact.ok, true);
  assert.equal(exact.text.length, MAX_SUBSCRIPTION_BODY_BYTES);

  const above = checkBody(asciiBytes(MAX_SUBSCRIPTION_BODY_BYTES + 1));
  assert.equal(above.ok, false);
  assert.equal(above.code, 'config_invalid');
  assert.equal(above.detailCode, 'too_large');

  // BOM 也计入上限：3 字节 BOM + limit 字节正文超限。
  const bomOver = asciiBytes(MAX_SUBSCRIPTION_BODY_BYTES + 1);
  bomOver[0] = 0xef;
  bomOver[1] = 0xbb;
  bomOver[2] = 0xbf;
  assert.equal(checkBody(bomOver).detailCode, 'too_large');
});

test('正文去除 UTF-8 BOM，正文为空也视为合法文本', () => {
  const withBom = new Uint8Array([0xef, 0xbb, 0xbf, ...new TextEncoder().encode('mode: rule\n')]);
  const result = checkBody(withBom);
  assert.equal(result.ok, true);
  assert.equal(result.text, 'mode: rule\n');

  const onlyBom = checkBody(new Uint8Array([0xef, 0xbb, 0xbf]));
  assert.equal(onlyBom.ok, true);
  assert.equal(onlyBom.text, '');
});

test('正文拒绝 NUL、控制字节与常见二进制魔数', () => {
  const nul = checkBody(new Uint8Array([0x6d, 0x6f, 0x00, 0x64, 0x65]));
  assert.equal(nul.detailCode, 'binary_rejected');
  for (const control of [0x01, 0x0b, 0x1b, 0x1f, 0x7f]) {
    assert.equal(checkBody(new Uint8Array([0x61, control, 0x62])).detailCode, 'binary_rejected', String(control));
  }
  const gzip = checkBody(new Uint8Array([0x1f, 0x8b, 0x08, 0x00]));
  assert.equal(gzip.detailCode, 'binary_rejected');
  const png = checkBody(new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]));
  assert.equal(png.detailCode, 'binary_rejected');
  // TAB/LF/FF/CR 是配置文件里的正常字符。
  assert.equal(checkBody(new Uint8Array([0x61, 0x09, 0x62, 0x0a, 0x63, 0x0c, 0x64, 0x0d, 0x65])).ok, true);
});

test('正文严格 UTF-8：截断、过长编码、代理项与游离续字节都拒绝', () => {
  for (const bytes of [
    [0xc3, 0x28],
    [0xe4, 0xb8],
    [0xf0, 0x9f, 0x98],
    [0xed, 0xa0, 0x80],
    [0x80],
    [0xc0, 0xaf],
    [0xf5, 0x80, 0x80, 0x80],
  ]) {
    const result = checkBody(new Uint8Array(bytes));
    assert.equal(result.ok, false, bytes.join(','));
    assert.equal(result.code, 'config_invalid', bytes.join(','));
    assert.equal(result.detailCode, 'encoding_rejected', bytes.join(','));
    assert.equal(result.text, '', bytes.join(','));
  }
  // 合法 2/3/4 字节序列正常解码（含 emoji 代理对）。
  const valid = checkBody(new TextEncoder().encode('节点-a 😀\n'));
  assert.equal(valid.ok, true);
  assert.equal(valid.text, '节点-a 😀\n');
  assert.equal(checkBody(null).detailCode, 'encoding_rejected');
  assert.equal(checkBody(undefined).detailCode, 'encoding_rejected');
});

test('base64 订阅只提示不支持，不把长标识误判为订阅', () => {
  const base64 = 'AB12'.repeat(22);
  assert.equal(base64.length, 88);
  assert.equal(looksLikeBase64Subscription(base64), true);
  // 允许内部空白。
  assert.equal(looksLikeBase64Subscription('AB12\n'.repeat(22)), true);
  // 带合法填充。
  assert.equal(looksLikeBase64Subscription('AB12'.repeat(20) + 'AB=='), true);

  assert.equal(looksLikeBase64Subscription('AB12'.repeat(4)), false);
  assert.equal(looksLikeBase64Subscription('ABCD'.repeat(16)), false);
  assert.equal(looksLikeBase64Subscription('AB12'.repeat(30) + '==='), false);
  assert.equal(looksLikeBase64Subscription('AB12'.repeat(20) + 'AB==x'), false);
  assert.equal(looksLikeBase64Subscription('mode: rule\n'), false);
  assert.equal(looksLikeBase64Subscription(''), false);
  assert.equal(looksLikeBase64Subscription(null), false);
});

test('显示名按 disposition → YAML 提示 → 域名回退，清空时给出固定名称', () => {
  assert.equal(deriveDisplayName('attachment; filename="sub.yaml"', 'Proxy', 'example.invalid'), 'sub.yaml');
  assert.equal(deriveDisplayName('', 'Proxy', 'example.invalid'), 'Proxy');
  assert.equal(deriveDisplayName('', '', 'example.invalid'), 'example.invalid');
  assert.equal(deriveDisplayName('', '', ''), '未命名配置');
  // 控制字符被清洗，名称不参与路径构造。
  assert.equal(deriveDisplayName('', 'a\u0000b', ''), 'a b');
  assert.equal(deriveDisplayName('attachment; filename="../../sub.yaml"', '', ''), 'sub.yaml');
});