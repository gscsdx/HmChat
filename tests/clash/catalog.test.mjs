/**
 * T-S1-16 组派生单元测试（设计 §9.4、baseline §3.5）。
 *
 * 覆盖任务卡：3 层嵌套、循环、hidden、跨组同名、叶子超深、可用性分类。
 * 夹具全部为虚构内容：example.invalid 主机与 node-a/node-b 节点名。
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const {
  parseProxies,
  deriveGroups,
  resolveToLeaf,
  isGroupType,
  isGroupEntry,
  MAX_LEAF_DEPTH,
  GLOBAL_GROUP_NAME,
  PROXY_GROUP_TYPES,
} = require('../../artifacts/tests/js/model/ClashGroupDeriver.js');

function parse(json) {
  return parseProxies(json);
}

/** 构造一段 3 层嵌套：GLOBAL → Proxy(Selector) → Auto(URLTest) → node-a。 */
function nestedFixture() {
  return {
    GLOBAL: { type: 'Selector', all: ['Proxy'], now: 'Proxy' },
    Proxy: { type: 'Selector', all: ['Auto', 'node-a'], now: 'Auto' },
    Auto: { type: 'URLTest', all: ['node-a'], now: 'node-a', testUrl: 'http://example.invalid/', icon: 'auto' },
    'node-a': { type: 'Shadowsocks', server: 'node-a.example.invalid', port: 8388, alive: true },
  };
}

test('parseProxies 跳过畸形条目并保留成员原始顺序', () => {
  const parsed = parse({
    Proxy: { type: 'Selector', all: ['node-b', '', 42, 'node-a', 'node-b'], hidden: 'true', now: ' node-a ' },
    'node-a': { type: ' ss ', server: 'node-a.example.invalid', port: 8388, alive: false, icon: ' a.png ' },
    'node-b': { type: 'Vmess', server: 'node-b.example.invalid', port: 0, testUrl: ' http://example.invalid/ ' },
    'node-c': { server: '' },
    broken: null,
    list: [],
    scalar: 'node',
  });
  assert.deepEqual(Object.keys(parsed), ['Proxy', 'node-a', 'node-b', 'node-c']);
  // hidden 只认严格 true；字符串 'true' 不算。
  assert.equal(parsed.Proxy.hidden, false);
  assert.equal(parsed.Proxy.now, 'node-a');
  assert.deepEqual(parsed.Proxy.all, ['node-b', 'node-a', 'node-b']);
  assert.equal(parsed['node-a'].type, 'ss');
  assert.equal(parsed['node-a'].alive, false);
  assert.equal(parsed['node-a'].icon, 'a.png');
  assert.equal(parsed['node-a'].hasEndpoint, true);
  // port 0 不构成完整 endpoint；缺失 type 保留空串。
  assert.equal(parsed['node-b'].hasEndpoint, false);
  assert.equal(parsed['node-b'].type, 'Vmess');
  assert.equal(parsed['node-c'].type, '');
  assert.equal(parsed['node-c'].hasEndpoint, false);
  assert.deepEqual(parse(null), {});
  assert.deepEqual(parse([]), {});
});

test('组类型白名单严格匹配内核大小写', () => {
  assert.deepEqual(PROXY_GROUP_TYPES, ['Selector', 'URLTest', 'Fallback', 'LoadBalance', 'Relay']);
  for (const type of PROXY_GROUP_TYPES) {
    assert.equal(isGroupType(type), true, type);
  }
  for (const type of ['selector', 'url-test', 'Direct', 'Reject', '', null]) {
    assert.equal(isGroupType(type), false, String(type));
  }
  assert.equal(isGroupEntry(undefined), false);
  assert.equal(isGroupEntry({ type: 'Selector' }), true);
  assert.equal(isGroupEntry({ type: 'Shadowsocks' }), false);
});

test('GLOBAL → Proxy → Auto 三层嵌套的 now 解析到叶子', () => {
  const groups = deriveGroups(parse(nestedFixture()), ['Proxy', 'Auto']);
  assert.deepEqual(groups.map((group) => group.name), ['GLOBAL', 'Proxy', 'Auto']);
  assert.equal(groups[0].now, 'node-a');
  assert.equal(groups[0].nowTruncated, false);
  assert.equal(groups[0].nowCycle, false);
  assert.equal(groups[1].now, 'node-a');
  assert.equal(groups[2].now, 'node-a');
  // 成员名永远是组成员名，辅助 now 不覆盖 name。
  const autoInProxy = groups[1].all.find((node) => node.name === 'Auto');
  assert.equal(autoInProxy.now, 'node-a');
  assert.equal(autoInProxy.id, 'Proxy/Auto');
  assert.equal(autoInProxy.availability, 'available');
  assert.equal(groups[2].isAuto, true);
  assert.equal(groups[1].isAuto, false);
  assert.equal(groups[2].testUrl, 'http://example.invalid/');
  assert.equal(groups[2].icon, 'auto');
});

test('GLOBAL 缺失时不伪造根组，仅派生声明的真实组', () => {
  const proxies = parse({
    Proxy: { type: 'Selector', all: ['node-a'], now: 'node-a' },
    'node-a': { type: 'Shadowsocks', server: 'node-a.example.invalid', port: 8388 },
    nodeOnly: { type: 'Shadowsocks', server: 'node-a.example.invalid', port: 8388 },
  });
  const groups = deriveGroups(proxies, ['Proxy', 'nodeOnly', 'ghost', 'Proxy']);
  assert.deepEqual(groups.map((group) => group.name), ['Proxy']);
  assert.equal(groups.some((group) => group.name === GLOBAL_GROUP_NAME), false);
  assert.deepEqual(deriveGroups(proxies), []);
});

test('hidden 组跳过，非组与未知组名跳过', () => {
  const proxies = parse({
    GLOBAL: { type: 'Selector', all: ['Hidden', 'Visible', 'node-a', 'ghost'], now: 'Visible' },
    Hidden: { type: 'Selector', all: ['node-a'], now: 'node-a', hidden: true },
    Visible: { type: 'URLTest', all: ['node-a'], now: 'node-a' },
    'node-a': { type: 'Shadowsocks', server: 'node-a.example.invalid', port: 8388 },
  });
  const groups = deriveGroups(proxies, ['Hidden', 'node-a']);
  assert.deepEqual(groups.map((group) => group.name), ['GLOBAL', 'Visible']);
  assert.equal(groups[0].hidden, false);
});

test('跨组同名节点使用 group/name 作为 id，互不冲突', () => {
  const proxies = parse({
    G1: { type: 'Selector', all: ['node-a'], now: 'node-a' },
    G2: { type: 'Selector', all: ['node-a'], now: 'node-a' },
    'node-a': { type: 'Shadowsocks', server: 'node-a.example.invalid', port: 8388, alive: true },
  });
  const groups = deriveGroups(proxies, ['G1', 'G2']);
  assert.equal(groups.length, 2);
  assert.equal(groups[0].all[0].id, 'G1/node-a');
  assert.equal(groups[1].all[0].id, 'G2/node-a');
  assert.equal(groups[0].all[0].name, 'node-a');
  assert.equal(groups[1].all[0].name, 'node-a');
  // 成员去重：同一组内重复出现的名字只保留首次。
  assert.equal(groups[0].all.length, 1);
});

test('组引用环被显式标记，不把循环中的组名当真实出口', () => {
  const proxies = parse({
    A: { type: 'Selector', all: ['B'], now: 'B' },
    B: { type: 'Selector', all: ['A'], now: 'A' },
  });
  const groups = deriveGroups(proxies, ['A', 'B']);
  assert.equal(groups[0].now, 'A');
  assert.equal(groups[0].nowTruncated, true);
  assert.equal(groups[0].nowCycle, true);
  // 自环同样被截断。
  const self = deriveGroups(parse({ S: { type: 'Selector', all: ['S'], now: 'S' } }), ['S']);
  assert.equal(self[0].nowTruncated, true);
  assert.equal(self[0].nowCycle, true);
});

test('叶子解析深度上限 16 层，超深返回当前组名并标记截断', () => {
  assert.equal(MAX_LEAF_DEPTH, 16);
  const levels = 20;
  const json = { 'node-a': { type: 'Shadowsocks', server: 'node-a.example.invalid', port: 8388 } };
  for (let index = 0; index < levels; index += 1) {
    const next = index === levels - 1 ? 'node-a' : 'chain-' + (index + 1);
    json['chain-' + index] = { type: 'Selector', all: [next], now: next };
  }
  const proxies = parse(json);
  const groups = deriveGroups(proxies, ['chain-0']);
  assert.equal(groups[0].now, 'chain-18');
  assert.equal(groups[0].nowTruncated, true);
  assert.equal(groups[0].nowCycle, false);
  // 直接以 depth=17 调用同样截断。
  const deep = resolveToLeaf(proxies, 'chain-0', 17);
  assert.deepEqual(deep, { name: 'chain-0', truncated: true, cycle: false });
});

test('组无 now 时不伪造出口，DIRECT/REJECT 直接作为叶子', () => {
  const proxies = parse({
    Empty: { type: 'Selector', all: ['node-a'] },
    Direct: { type: 'Selector', all: ['DIRECT'], now: 'DIRECT' },
    Reject: { type: 'URLTest', all: ['REJECT'], now: 'REJECT' },
    'node-a': { type: 'Shadowsocks', server: 'node-a.example.invalid', port: 8388 },
  });
  const groups = deriveGroups(proxies, ['Empty', 'Direct', 'Reject']);
  assert.equal(Object.prototype.hasOwnProperty.call(groups[0], 'now'), false);
  assert.equal(groups[0].nowTruncated, false);
  assert.equal(groups[1].now, 'DIRECT');
  assert.equal(groups[2].now, 'REJECT');
  assert.equal(groups[1].nowTruncated, false);
});

test('成员可用性分类：类型缺失、内置出站、alive、endpoint 与未知态', () => {
  const proxies = parse({
    Proxy: {
      type: 'Selector',
      all: ['no-type', 'DIRECT', 'REJECT', 'dead', 'missing-endpoint', 'bad-port', 'unknown', 'live', 'child'],
    },
    'no-type': { server: 'fixture.example.invalid', port: 443 },
    DIRECT: { type: 'Direct' },
    REJECT: { type: 'Reject' },
    dead: { type: 'Vmess', server: 'dead.example.invalid', port: 443, alive: false },
    'missing-endpoint': { type: 'Vmess' },
    'bad-port': { type: 'Vmess', server: 'bad.example.invalid', port: 70000 },
    'unknown': { type: 'Vmess', server: 'unknown.example.invalid', port: 443 },
    'live': { type: 'Vmess', server: 'live.example.invalid', port: 443, alive: true },
    child: { type: 'URLTest', all: ['live'], now: 'live' },
  });
  const nodes = deriveGroups(proxies, ['Proxy'])[0].all;
  const byName = new Map(nodes.map((node) => [node.name, node]));
  assert.equal(byName.get('no-type').availability, 'unavailable');
  assert.equal(byName.get('no-type').unavailableReason, '该节点类型暂不支持');
  assert.equal(byName.get('DIRECT').availability, 'available');
  assert.equal(byName.get('REJECT').availability, 'available');
  assert.equal(byName.get('dead').availability, 'unavailable');
  assert.equal(byName.get('dead').unavailableReason, '节点当前不可用');
  assert.equal(byName.get('missing-endpoint').availability, 'unavailable');
  assert.equal(byName.get('missing-endpoint').unavailableReason, '节点缺少必要连接信息');
  assert.equal(byName.get('bad-port').unavailableReason, '节点缺少必要连接信息');
  assert.equal(byName.get('unknown').availability, 'unknown');
  assert.equal(byName.get('live').availability, 'available');
  // 组作为成员时可被选中，且不改写成员名。
  assert.equal(byName.get('child').availability, 'available');
  assert.equal(byName.get('child').name, 'child');
  // 不可用原因只含固定文案，不含服务器地址。
  for (const node of nodes) {
    if (node.unavailableReason !== undefined) {
      assert.equal(node.unavailableReason.includes('example.invalid'), false);
    }
  }
});

test('缺失成员丢弃、非字符串成员丢弃，成员顺序原样保留', () => {
  const proxies = parse({
    Proxy: { type: 'Selector', all: ['node-b', 'ghost', '', 'node-a'], now: 'node-a' },
    'node-a': { type: 'Shadowsocks', server: 'node-a.example.invalid', port: 8388 },
    'node-b': { type: 'Shadowsocks', server: 'node-b.example.invalid', port: 8388 },
  });
  const group = deriveGroups(proxies, ['Proxy'])[0];
  assert.deepEqual(group.all.map((node) => node.name), ['node-b', 'node-a']);
});

test('resolveToLeaf 对空名、叶子与缺失条目返回确定结果', () => {
  const proxies = parse(nestedFixture());
  assert.deepEqual(resolveToLeaf(proxies, ''), { name: '', truncated: false, cycle: false });
  assert.deepEqual(resolveToLeaf(proxies, 'node-a'), { name: 'node-a', truncated: false, cycle: false });
  assert.deepEqual(resolveToLeaf(proxies, 'ghost'), { name: 'ghost', truncated: false, cycle: false });
  assert.deepEqual(resolveToLeaf(proxies, 'Auto'), { name: 'node-a', truncated: false, cycle: false });
});