/**
 * T-S1-15 Action 信封单元测试。
 *
 * 覆盖任务卡：24 项白名单、id 形态、超时表、changeProxy 空节点名、
 * code 与 data 双重判据（`code=0` 且 `data=''` 的 getProxies 必须失败）、
 * 字符串类方法的空串成功/非空失败、message 事件解包。
 *
 * 夹具全部为虚构内容：example.invalid 主机、node-a 节点名、全零 UUID。
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const {
  METHOD_WHITELIST,
  isActionMethod,
  makeActionId,
  buildAction,
  buildChangeProxy,
  buildAsyncTestDelay,
  buildSetupConfig,
  buildGetConfig,
  buildHealthCheck,
  decodeActionResult,
  decodeMessageEvent,
  resolveTimeoutMs,
  DEFAULT_ACTION_TIMEOUT_MS,
  DEFAULT_TEST_TIMEOUT_MS,
  ASYNC_TEST_DELAY_MARGIN_MS,
  TIMEOUT_MS,
  ACTION_METHOD_NOT_ALLOWED,
  ACTION_INVALID_ID,
  ACTION_EMPTY_PROXY,
} = require('../../artifacts/tests/js/model/ClashActionFactory.js');

/** 设计 §5.4 的 24 项白名单，逐项硬编码，避免与实现互相抄写。 */
const EXPECTED_WHITELIST = [
  'getProxies',
  'changeProxy',
  'asyncTestDelay',
  'healthCheck',
  'getConfig',
  'validateConfig',
  'setupConfig',
  'updateConfig',
  'getConnections',
  'closeConnections',
  'getCoreVersion',
  'getTraffic',
  'getTotalTraffic',
  'resetTraffic',
  'getRunTime',
  'getCurrentProfileName',
  'getAndroidVpnOptions',
  'getIsInit',
  'setState',
  'shutdown',
  'startLog',
  'stopLog',
  'getMemory',
  'forceGc',
];

test('白名单恰好 24 项且逐项可用，白名单外方法一律拒绝', () => {
  assert.equal(METHOD_WHITELIST.length, 24);
  assert.deepEqual(METHOD_WHITELIST, EXPECTED_WHITELIST);
  for (const method of EXPECTED_WHITELIST) {
    assert.equal(isActionMethod(method), true, method);
  }
  // 同步测速、大小写变体、带空白、空串与协议外方法都不能通过。
  for (const method of ['testDelay', 'getProxies ', 'GetProxies', '', 'message', 'auth', 'core.init', 'getGeo']) {
    assert.equal(isActionMethod(method), false, method);
  }
});

test('Action id 必须匹配 <method>#<epoch>-<seq> 且与 method 一致', () => {
  assert.equal(makeActionId('getProxies', 7, 3), 'getProxies#7-3');
  assert.throws(() => makeActionId('getProxies', -1, 0), { message: ACTION_INVALID_ID });
  assert.throws(() => makeActionId('getProxies', 1.5, 0), { message: ACTION_INVALID_ID });
  assert.throws(() => makeActionId('getProxies', 0, NaN), { message: ACTION_INVALID_ID });
  assert.throws(() => makeActionId('bogus', 0, 0), { message: ACTION_METHOD_NOT_ALLOWED });

  assert.deepEqual(buildAction('changeProxy#2-9', 'changeProxy', '{}'), {
    id: 'changeProxy#2-9',
    method: 'changeProxy',
    data: '{}',
  });
  // 无参数方法不写 data 键，避免内核把空串当作参数。
  assert.equal(Object.prototype.hasOwnProperty.call(buildAction('getRunTime#0-1', 'getRunTime'), 'data'), false);

  assert.throws(() => buildAction('getProxies#1-1', 'changeProxy', '{}'), { message: ACTION_INVALID_ID });
  assert.throws(() => buildAction('getProxies#1', 'getProxies'), { message: ACTION_INVALID_ID });
  assert.throws(() => buildAction('getProxies#a-1', 'getProxies'), { message: ACTION_INVALID_ID });
  assert.throws(() => buildAction('getProxies#1-2-3', 'getProxies'), { message: ACTION_INVALID_ID });
  assert.throws(() => buildAction('getProxies#1-1', 'bogus'), { message: ACTION_METHOD_NOT_ALLOWED });
  // 对象必须序列化成字符串后传入；直接传对象是调用方错误。
  assert.throws(() => buildAction('changeProxy#1-1', 'changeProxy', {}), { message: 'invalid_action_data' });
});

test('超时表：配置类单列超时、asyncTestDelay 叠加 2 s、非法 timeout 拒绝', () => {
  assert.equal(DEFAULT_ACTION_TIMEOUT_MS, 15000);
  assert.equal(DEFAULT_TEST_TIMEOUT_MS, 5000);
  assert.equal(ASYNC_TEST_DELAY_MARGIN_MS, 2000);
  assert.equal(TIMEOUT_MS.getConfig, 20000);
  assert.equal(TIMEOUT_MS.validateConfig, 30000);
  assert.equal(TIMEOUT_MS.setupConfig, 60000);

  assert.equal(resolveTimeoutMs('asyncTestDelay'), 7000);
  assert.equal(resolveTimeoutMs('asyncTestDelay', 3000), 5000);
  assert.equal(resolveTimeoutMs('getConfig'), 20000);
  assert.equal(resolveTimeoutMs('shutdown'), DEFAULT_ACTION_TIMEOUT_MS);

  for (const bad of [0, -1, 1.5, NaN, Infinity]) {
    assert.throws(() => resolveTimeoutMs('asyncTestDelay', bad), { message: 'invalid_timeout' });
  }
  assert.throws(() => resolveTimeoutMs('bogus'), { message: ACTION_METHOD_NOT_ALLOWED });
});

test('changeProxy 拒绝空节点名与空组名，合法载荷保持协议字段名', () => {
  // 内核会对空 proxy-name 执行 ForceSet("")，必须在构造阶段拦截。
  for (const blank of ['', '   ', '\t']) {
    assert.throws(() => buildChangeProxy('Proxy', blank), { message: ACTION_EMPTY_PROXY });
  }
  for (const blank of ['', '  ']) {
    assert.throws(() => buildChangeProxy(blank, 'node-a'), { message: 'empty_group_name' });
  }
  const payload = JSON.parse(buildChangeProxy('Proxy', 'node-a'));
  assert.deepEqual(payload, { 'group-name': 'Proxy', 'proxy-name': 'node-a' });
});

test('asyncTestDelay 允许空测速地址且 timeout 必为正整数', () => {
  const payload = JSON.parse(buildAsyncTestDelay('node-a', '', 5000));
  assert.deepEqual(payload, { 'proxy-name': 'node-a', 'test-url': '', timeout: 5000 });
  assert.equal(JSON.parse(buildAsyncTestDelay('node-a', 'http://example.invalid/', undefined)).timeout, 5000);
  assert.throws(() => buildAsyncTestDelay('', '', 5000), { message: ACTION_EMPTY_PROXY });
  assert.throws(() => buildAsyncTestDelay('node-a', '', 0), { message: 'invalid_timeout' });
  assert.throws(() => buildAsyncTestDelay('node-a', '', -5), { message: 'invalid_timeout' });
});

test('setupConfig 拦截 rules 误用、校验 selected-map 并保留 config 原样', () => {
  const config = { proxies: [], rule: ['MATCH,DIRECT'] };
  const encoded = JSON.parse(buildSetupConfig(config, { Proxy: 'node-a' }, 'http://example.invalid/'));
  assert.deepEqual(encoded.config, config);
  assert.deepEqual(encoded['selected-map'], { Proxy: 'node-a' });
  assert.equal(encoded['test-url'], 'http://example.invalid/');

  // 只有 rules 没有 rule：mihomo 不认，构造阶段直接失败。
  assert.throws(() => buildSetupConfig({ rules: ['MATCH,DIRECT'] }, {}, ''), { message: 'rules_key_mismatch' });
  // 正确键名（rule）的配置原样通过，载荷中不出现遗留 rules。
  const migrated = JSON.parse(buildSetupConfig({ rule: ['MATCH,DIRECT'] }, {}, ''));
  assert.deepEqual(migrated.config, { rule: ['MATCH,DIRECT'] });

  assert.throws(() => buildSetupConfig(null, {}, ''), { message: 'invalid_setup_config' });
  assert.throws(() => buildSetupConfig([], {}, ''), { message: 'invalid_setup_config' });
  assert.throws(() => buildSetupConfig(config, { Proxy: '  ' }, ''), { message: ACTION_EMPTY_PROXY });
  assert.throws(() => buildSetupConfig(config, { '': 'node-a' }, ''), { message: 'empty_group_name' });
  assert.throws(() => buildSetupConfig(config, [], ''), { message: 'invalid_setup_config' });
});

test('getConfig 拒绝空路径与 NUL；healthCheck 空组名表示全部组', () => {
  assert.equal(buildGetConfig('profile-1'), 'profile-1');
  assert.throws(() => buildGetConfig(''), { message: 'invalid_path' });
  assert.throws(() => buildGetConfig('a\u0000b'), { message: 'invalid_path' });
  assert.equal(buildHealthCheck(), '');
  assert.equal(buildHealthCheck('   '), '');
  assert.equal(buildHealthCheck('Proxy'), 'Proxy');
});

test('ActionResult：code=0 但 data 为空串的 getProxies 必须失败', () => {
  const emptyProxies = decodeActionResult({ id: 'getProxies#1-1', method: 'getProxies', code: 0, data: '' });
  assert.equal(emptyProxies.ok, false);
  assert.equal(emptyProxies.kind, 'result');
  assert.equal(emptyProxies.error.detailCode, 'empty_result');
  assert.equal(emptyProxies.error.code, 'internal');

  const missingProxies = decodeActionResult({ id: 'getProxies#1-2', method: 'getProxies', code: 0 });
  assert.equal(missingProxies.ok, false);
  assert.equal(missingProxies.error.detailCode, 'missing_result');

  const proxies = decodeActionResult({
    id: 'getProxies#1-3',
    method: 'getProxies',
    code: 0,
    data: { 'node-a': { type: 'Shadowsocks' } },
  });
  assert.equal(proxies.ok, true);
  assert.deepEqual(proxies.data, { 'node-a': { type: 'Shadowsocks' } });

  // getConfig / asyncTestDelay 同样要求非空结果。
  assert.equal(decodeActionResult({ method: 'getConfig', code: 0, data: '' }).ok, false);
  assert.equal(decodeActionResult({ method: 'asyncTestDelay', code: 0 }).ok, false);
});

test('ActionResult：字符串类方法空串成功、非空串失败，code 非 0 优先失败', () => {
  for (const method of ['changeProxy', 'validateConfig', 'setupConfig', 'updateConfig', 'healthCheck']) {
    const ok = decodeActionResult({ method, code: 0, data: '' });
    assert.equal(ok.ok, true, method);
    const failed = decodeActionResult({ method, code: 0, data: 'boom' });
    assert.equal(failed.ok, false, method);
    assert.equal(failed.error.detailCode, 'error_string', method);
    assert.equal(failed.method, method);
  }
  // 配置类错误映射 config_invalid，其余映射 internal；都不回显原始错误串。
  assert.equal(decodeActionResult({ method: 'setupConfig', code: 0, data: 'boom' }).error.code, 'config_invalid');
  assert.equal(decodeActionResult({ method: 'changeProxy', code: 0, data: 'boom' }).error.code, 'internal');

  const nonzero = decodeActionResult({ method: 'changeProxy', code: -1, data: '' });
  assert.equal(nonzero.ok, false);
  assert.equal(nonzero.error.detailCode, 'code_nonzero');

  // data 缺失对字符串类方法是结构错误，不是隐式成功。
  assert.equal(decodeActionResult({ method: 'changeProxy', code: 0 }).error.detailCode, 'invalid_error_string');
  assert.equal(decodeActionResult({ method: 'validateConfig', code: 0, data: 0 }).ok, false);
});

test('ActionResult：非法信封、未知方法、缺失 code 都返回结构化失败', () => {
  assert.equal(decodeActionResult('not json').ok, false);
  assert.equal(decodeActionResult('not json').error.detailCode, 'invalid_envelope');
  assert.equal(decodeActionResult('[]').error.detailCode, 'invalid_envelope');
  assert.equal(decodeActionResult({ method: 'bogus', code: 0 }).error.detailCode, 'method_not_allowed');
  assert.equal(decodeActionResult({ method: 'getProxies' }).error.detailCode, 'invalid_code');
  assert.equal(decodeActionResult({ method: 'getProxies', code: '0' }).error.detailCode, 'invalid_code');
  // JSON 字符串与对象等价。
  assert.equal(decodeActionResult(JSON.stringify({ method: 'getRunTime', code: 0, data: 12 })).data, 12);
});

test('message 事件包装解包为 {type,data}，未知类型与畸形帧丢弃', () => {
  const decoded = decodeActionResult({
    method: 'message',
    code: 0,
    data: { type: 'delay', data: { name: 'node-a', url: 'http://example.invalid/', value: 120 } },
  });
  assert.equal(decoded.kind, 'message');
  assert.equal(decoded.eventType, 'delay');
  assert.equal(decoded.ok, true);
  assert.deepEqual(decoded.data, { name: 'node-a', url: 'http://example.invalid/', value: 120 });

  // 未知事件类型、code 非 0、data 非对象都返回 null，由上层计数丢弃。
  assert.equal(decodeActionResult({ method: 'message', code: 0, data: { type: 'bogus' } }), null);
  assert.equal(decodeActionResult({ method: 'message', code: 1, data: { type: 'delay' } }), null);
  assert.equal(decodeActionResult({ method: 'message', code: 0, data: 'delay' }), null);

  assert.equal(decodeMessageEvent({ method: 'message', code: 0, data: { type: 'traffic' } }).type, 'traffic');
  assert.equal(decodeMessageEvent({ method: 'getProxies', code: 0, data: { type: 'delay' } }), null);
  assert.equal(decodeMessageEvent('not json'), null);
});