/**
 * T-S1-15 配置 patch 单元测试（设计 §10.4）。
 *
 * 覆盖任务卡：未知字段保留、`rules` → `rule`、双键告警、已有 `dns` 不被覆盖、
 * 回环规则只插一次、`tun` 各字段值。
 *
 * 夹具全部为虚构内容：example.invalid 主机与 node-a 节点名。
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const {
  patch,
  patchWithDiagnostics,
  LOOPBACK_DIRECT_RULE,
  WARN_RULE_KEY_CONFLICT,
} = require('../../artifacts/tests/js/model/ClashConfigPatch.js');

/** 含全部未知字段的最小 RawConfig 夹具。 */
function fixtureConfig() {
  return {
    proxies: [{ name: 'node-a', type: 'ss', server: 'node-a.example.invalid', port: 8388 }],
    'proxy-groups': [{ name: 'Proxy', type: 'select', proxies: ['node-a'] }],
    'proxy-providers': { provider: { url: 'https://example.invalid/sub' } },
    'rule-providers': { ruleset: { type: 'http' } },
    hosts: { 'example.invalid': '127.0.0.1' },
    sniffer: { enable: true },
    ipv6: true,
    rule: ['DOMAIN,example.invalid,DIRECT', 'MATCH,Proxy'],
  };
}

test('patch 返回同一对象并保留所有未知顶层字段', () => {
  const config = fixtureConfig();
  const patched = patch(config);
  assert.equal(patched, config);
  assert.deepEqual(patched.proxies, fixtureConfig().proxies);
  assert.deepEqual(patched['proxy-groups'], fixtureConfig()['proxy-groups']);
  assert.deepEqual(patched['proxy-providers'], fixtureConfig()['proxy-providers']);
  assert.deepEqual(patched['rule-providers'], fixtureConfig()['rule-providers']);
  assert.deepEqual(patched.hosts, { 'example.invalid': '127.0.0.1' });
  assert.deepEqual(patched.sniffer, { enable: true });
  assert.equal(patched.ipv6, true);
});

test('唯 rules 键迁移为 rule，并删除遗留键', () => {
  const warnings = [];
  const config = { rules: ['MATCH,DIRECT'] };
  const patched = patch(config, warnings);
  assert.deepEqual(patched.rule, [LOOPBACK_DIRECT_RULE, 'MATCH,DIRECT']);
  assert.equal(Object.prototype.hasOwnProperty.call(patched, 'rules'), false);
  assert.deepEqual(warnings, []);
});

test('rule 与 rules 双键以 rule 为准、记录固定告警码并删除 rules', () => {
  const { config, warnings } = patchWithDiagnostics({
    rule: ['MATCH,Proxy'],
    rules: ['MATCH,DIRECT'],
  });
  assert.deepEqual(config.rule, [LOOPBACK_DIRECT_RULE, 'MATCH,Proxy']);
  assert.equal(Object.prototype.hasOwnProperty.call(config, 'rules'), false);
  assert.deepEqual(warnings, [WARN_RULE_KEY_CONFLICT]);
});

test('仅有 rule 时不产生告警，非数组 rules 只删除不迁移', () => {
  const { config, warnings } = patchWithDiagnostics({ rule: ['MATCH,DIRECT'] });
  assert.deepEqual(config.rule, [LOOPBACK_DIRECT_RULE, 'MATCH,DIRECT']);
  assert.deepEqual(warnings, []);

  const nullLegacy = patch({ rules: null });
  assert.equal(Object.prototype.hasOwnProperty.call(nullLegacy, 'rules'), false);
  assert.equal(Object.prototype.hasOwnProperty.call(nullLegacy, 'rule'), false);
});

test('回环规则只插一次且始终位于规则数组首位', () => {
  const config = {
    rule: [LOOPBACK_DIRECT_RULE, 'DOMAIN,example.invalid,DIRECT', LOOPBACK_DIRECT_RULE, 'MATCH,Proxy'],
  };
  patch(config);
  const occurrences = config.rule.filter((rule) => rule === LOOPBACK_DIRECT_RULE);
  assert.equal(occurrences.length, 1);
  assert.equal(config.rule[0], LOOPBACK_DIRECT_RULE);
  // 其他规则顺序不变，不去重、不排序。
  assert.deepEqual(config.rule.slice(1), ['DOMAIN,example.invalid,DIRECT', 'MATCH,Proxy']);
});

test('已有 dns 段启用时整段保持原样，不注入 fake-ip', () => {
  const dns = { enable: true, nameserver: ['https://dns.example.invalid/dns-query'], 'fake-ip-filter': ['*.lan'] };
  const config = { dns: dns };
  patch(config);
  assert.equal(config.dns, dns);
  assert.deepEqual(config.dns.nameserver, ['https://dns.example.invalid/dns-query']);
  assert.equal(Object.prototype.hasOwnProperty.call(config.dns, 'enhanced-mode'), false);
  assert.equal(Object.prototype.hasOwnProperty.call(config.dns, 'fake-ip-range'), false);
});

test('dns 未启用时只补缺失的最小键，已有值不被覆盖', () => {
  const config = {
    dns: {
      enable: false,
      nameserver: ['https://dns.example.invalid/dns-query'],
      'fake-ip-filter': ['*.lan'],
    },
  };
  patch(config);
  assert.equal(config.dns.enable, true);
  assert.equal(config.dns['enhanced-mode'], 'fake-ip');
  assert.equal(config.dns['fake-ip-range'], '198.18.0.1/16');
  assert.deepEqual(config.dns.nameserver, ['https://dns.example.invalid/dns-query']);
  assert.deepEqual(config.dns['fake-ip-filter'], ['*.lan']);
  assert.deepEqual(config.dns.fallback, []);

  // 缺失 dns 时新建完整最小段。
  const created = patch({});
  assert.deepEqual(created.dns, {
    enable: true,
    'enhanced-mode': 'fake-ip',
    'fake-ip-range': '198.18.0.1/16',
    nameserver: ['system'],
    fallback: [],
  });
});

test('tun 字段写入固定值且保留已有未知键', () => {
  const config = { tun: { device: 'vpn-tun', 'route-address': '198.18.0.0/16' } };
  patch(config);
  assert.equal(config.tun.enable, true);
  assert.equal(config.tun.stack, 'gvisor');
  assert.equal(config.tun.mtu, 1420);
  assert.deepEqual(config.tun['dns-hijack'], ['any:53']);
  assert.equal(config.tun['auto-route'], false);
  assert.equal(config.tun['auto-detect-interface'], false);
  assert.equal(config.tun.device, 'vpn-tun');
  assert.equal(config.tun['route-address'], '198.18.0.0/16');

  // 缺失 tun 时新建。
  const created = patch({});
  assert.deepEqual(created.tun, {
    enable: true,
    stack: 'gvisor',
    mtu: 1420,
    'dns-hijack': ['any:53'],
    'auto-route': false,
    'auto-detect-interface': false,
  });
});

test('白名单标量字段与 profile.store-selected 按设计写入', () => {
  const config = { profile: { tracing: true }, 'bind-address': '0.0.0.0', mode: 'global' };
  patch(config);
  assert.equal(config.mode, 'rule');
  assert.equal(config['log-level'], 'warning');
  assert.equal(config['allow-lan'], false);
  assert.equal(config['bind-address'], '127.0.0.1');
  for (const key of ['mixed-port', 'port', 'socks-port', 'redir-port', 'tproxy-port']) {
    assert.equal(config[key], 0, key);
  }
  assert.equal(config['external-controller'], '');
  assert.equal(config['external-ui'], '');
  assert.equal(config.secret, '');
  assert.equal(config['find-process-mode'], 'off');
  assert.equal(config['geodata-loader'], 'memconservative');
  assert.equal(config['unified-delay'], true);
  assert.equal(config['tcp-concurrent'], true);
  assert.equal(config['keep-alive-interval'], 30);
  assert.equal(config.profile['store-selected'], false);
  assert.equal(config.profile.tracing, true);
});

test('bind-address 只在配置自带该键时才改回回环', () => {
  const config = {};
  patch(config);
  assert.equal(Object.prototype.hasOwnProperty.call(config, 'bind-address'), false);
});

test('非法输入抛固定 config_invalid，不含配置内容', () => {
  assert.throws(() => patch(null), { message: 'config_invalid' });
  assert.throws(() => patch([]), { message: 'config_invalid' });
  assert.throws(() => patch('config'), { message: 'config_invalid' });
});