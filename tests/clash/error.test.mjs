import test from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const {
  categoryOf,
  classify,
  describe,
  isRetryable,
} = require('../../artifacts/tests/js/model/ClashError.js');

/**
 * 设计 §8.2 / §7.9 / §11.5 的 18 个错误码。
 * 文案以 §7.9 为主，§11.5 对同一情形有更新时采用 §11.5（见模块头注释）。
 */
const CODES = [
  { code: 'core_missing', title: '此安装包不包含代理内核', category: 'core', retryable: false },
  { code: 'core_load_failed', title: '代理内核加载失败', category: 'core', retryable: false },
  { code: 'core_init_failed', title: '代理服务初始化失败', category: 'core', retryable: true },
  { code: 'config_missing', title: '尚未导入配置', category: 'config', retryable: false },
  { code: 'config_invalid', title: '配置无法使用', category: 'config', retryable: false },
  { code: 'tun_config_invalid', title: '网络参数无效', category: 'tun', retryable: true },
  { code: 'tun_create_denied', title: '未获得 VPN 授权', category: 'auth', retryable: true },
  { code: 'tun_create_failed', title: '无法建立 VPN 连接', category: 'tun', retryable: true },
  { code: 'tun_start_failed', title: '代理启动失败', category: 'tun', retryable: true },
  { code: 'tun_route_failed', title: '网络路由配置失败', category: 'tun', retryable: true },
  { code: 'rpc_unavailable', title: '内部服务连接失败', category: 'rpc', retryable: true },
  { code: 'rpc_auth_failed', title: '内部服务校验失败', category: 'rpc', retryable: false },
  { code: 'path_rejected', title: '配置路径无效', category: 'profile', retryable: false },
  { code: 'protect_degraded', title: '网络保护异常，已停止代理', category: 'protect', retryable: true },
  { code: 'extension_crashed', title: '代理服务异常退出', category: 'system', retryable: true },
  { code: 'timeout', title: '启动超时', category: 'system', retryable: true },
  { code: 'unsupported', title: '当前系统不支持该功能', category: 'system', retryable: false },
  { code: 'internal', title: '操作失败', category: 'system', retryable: true },
];

const CATEGORIES = ['config', 'core', 'tun', 'rpc', 'protect', 'system', 'auth', 'profile'];

/** 文案中禁止出现的技术细节（§11.5）：内部状态名、Action 名、SDK/ABI、二进制名、绝对路径、URL。 */
const FORBIDDEN_TERMS = [
  'preparing',
  'abi',
  'dlopen',
  'mihomo',
  'clash',
  'setupconfig',
  'changeproxy',
  'getproxies',
  'quickstart',
  'napi',
  '.so',
  '://',
  'http',
  '/',
  '\\',
  'uuid',
  'token',
  'password',
  'node-a',
];

function textOf(description) {
  return description.title + ' ' + description.detail + ' ' + description.nextAction;
}

test('错误码集合严格等于设计 §7.9 的 18 项且无重复', () => {
  assert.equal(CODES.length, 18);
  const unique = new Set(CODES.map(item => item.code));
  assert.equal(unique.size, 18);
  for (const item of CODES) {
    assert.ok(CATEGORIES.includes(item.category), item.code);
    assert.equal(typeof item.retryable, 'boolean', item.code);
  }
});

test('18 个错误码的 describe.title 与设计文案逐字一致', () => {
  for (const item of CODES) {
    const description = describe(item.code);
    assert.equal(description.title, item.title, item.code);
  }
});

test('18 个错误码的 classify/categoryOf 与分类表一致', () => {
  for (const item of CODES) {
    assert.equal(classify(item.code), item.category, item.code);
    assert.equal(categoryOf(item.code), item.category, item.code);
  }
});

test('18 个错误码的 retryable 与 isRetryable 一致', () => {
  for (const item of CODES) {
    assert.equal(isRetryable(item.code), item.retryable, item.code);
  }
});

test('不可重试集合恰为需要更换安装包/重新导入/重启或升级系统的 7 项', () => {
  const notRetryable = CODES.filter(item => !describe(item.code).retryable).map(item => item.code).sort();
  assert.deepEqual(notRetryable, [
    'config_invalid',
    'config_missing',
    'core_load_failed',
    'core_missing',
    'path_rejected',
    'rpc_auth_failed',
    'unsupported',
  ]);
  assert.equal(CODES.length - notRetryable.length, 11);
});

test('每个描述都有非空主文案、副文案与可执行建议', () => {
  for (const item of CODES) {
    const description = describe(item.code);
    for (const field of ['title', 'detail', 'nextAction']) {
      assert.equal(typeof description[field], 'string', item.code + '.' + field);
      assert.ok(description[field].trim().length > 0, item.code + '.' + field);
    }
    assert.ok(!/[。；]\s*$/.test(description.nextAction), item.code + ' 建议不应以句号结尾');
  }
});

test('文案不含 preparing、Action 名、SDK/ABI、二进制名、绝对路径或 URL', () => {
  for (const item of CODES) {
    const text = textOf(describe(item.code)).toLowerCase();
    for (const term of FORBIDDEN_TERMS) {
      assert.equal(text.includes(term), false, item.code + ' 不应包含 ' + term);
    }
  }
});

test('配置问题不显示「未授权」，授权问题不显示「配置无效」', () => {
  assert.notEqual(describe('config_invalid').title, describe('tun_create_denied').title);
  assert.equal(describe('config_invalid').category, 'config');
  assert.equal(describe('config_missing').category, 'config');
  assert.equal(describe('tun_create_denied').category, 'auth');
  assert.notEqual(describe('tun_create_denied').category, 'config');
  assert.equal(describe('core_missing').category, 'core');
  assert.equal(describe('core_missing').retryable, false);
});

test('未知码、空串与非字符串统一回退 internal，绝不抛异常', () => {
  const expected = {
    title: '操作失败',
    detail: '发生了未分类的错误，操作没有完成。',
    nextAction: '重试；反馈诊断',
    retryable: true,
    category: 'system',
  };
  for (const value of ['', 'unknown', 'bogus_code', 'CORE_MISSING', 'core-missing', ' core_missing', 'core_missing ', '__proto__', 'constructor']) {
    assert.deepEqual(describe(value), expected, String(value));
  }
  for (const value of [undefined, null, 0, 42, true, {}]) {
    assert.deepEqual(describe(value), expected, String(value));
  }
  assert.deepEqual(describe('internal'), expected);
});

test('describe 只按码查表，不回显无法识别的输入内容', () => {
  const secretUrl = 'https://node-a:SECRET@example.invalid/api?token=SECRET_TOKEN';
  const description = describe(secretUrl);
  assert.equal(description.title, '操作失败');
  const text = textOf(description);
  assert.equal(text.includes('SECRET'), false);
  assert.equal(text.includes('node-a'), false);
  assert.equal(text.includes('example.invalid'), false);
  for (const code of ['00000000-0000-0000-0000-000000000000', 'SECRET_TOKEN']) {
    assert.equal(textOf(describe(code)).includes(code), false);
  }
});

test('describe 返回独立对象，调用方修改不会污染后续结果', () => {
  const first = describe('timeout');
  first.title = '被修改';
  first.retryable = false;
  const second = describe('timeout');
  assert.equal(second.title, '启动超时');
  assert.equal(second.retryable, true);
  assert.notEqual(first, second);
});

test('18 项错误码覆盖全部 8 个分类分组', () => {
  const used = new Set(CODES.map(item => classify(item.code)));
  assert.deepEqual([...used].sort(), [...CATEGORIES].sort());
});