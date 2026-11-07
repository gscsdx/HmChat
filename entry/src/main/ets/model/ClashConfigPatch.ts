/**
 * Clash `RawConfig` 白名单修补：保证规则键为 `rule`、注入最小 DNS/TUN、限制本地暴露面。
 *
 * 任务：T-S1-10（docs/integration/clash-proxy-tasks.md）。
 * 证据：
 * - docs/integration/clash-proxy-design.md §10.4（patch 表与最小 DNS 注入）。
 * - docs/integration/flclash-core-lib-baseline.md §2.6（`rule` 才是 mihomo 的规则键）、
 *   §3.3（上游 `patchRawConfig` 的字段处理顺序）。
 *
 * 约束：
 * - 纯 TypeScript：只依赖 `./ClashModels` 的 `RawConfig` 类型，不引用 Kit、不读写文件、
 *   不读时钟、不发请求。
 * - 输入是 `getConfig` 返回的已解析开放对象；本模块直接在原对象上修改白名单键并返回
 *   同一对象，不重新构造配置。白名单之外的键（`proxies`、`proxy-groups`、
 *   `proxy-providers`、`rule-providers`、`hosts`、`sniffer` 等）保持不变。
 * - 仅使用具名可选字段描述会触碰的键，避免索引签名、宽泛顶层类型与枚举。
 * - 告警只写入固定码，不含配置内容、节点名、订阅地址或凭据。
 */

import { RawConfig } from './ClashModels';

/**
 * 回环直连规则：放在规则数组最前，避免本机回环流量被代理或再次进入 TUN。
 * 与 mihomo 规则语法一致；`no-resolve` 防止对 IP 规则做域名解析。
 */
export const LOOPBACK_DIRECT_RULE: string = 'IP-CIDR,127.0.0.0/8,DIRECT,no-resolve';

/**
 * 告警码：`rule` 与遗留 `rules` 同时存在。
 * 调用方把该码写入诊断记录；不要记录任何配置内容。
 */
export const WARN_RULE_KEY_CONFLICT: string = 'rule_key_conflict';

/** 与 ClashError.ProxyErrorCode 保持一致的固定错误码，不拼接原始配置内容。 */
const ERROR_CONFIG_INVALID: string = 'config_invalid';

/** 设计 §10.4：发布默认日志级别；不默认输出详细请求。 */
const DEFAULT_LOG_LEVEL: string = 'warning';
/** 即使误开端口也只监听回环。 */
const LOOPBACK_BIND_ADDRESS: string = '127.0.0.1';
/** 设计 §10.4：移动端使用 gVisor；core 仍会无条件覆盖为该栈。 */
const TUN_STACK: string = 'gvisor';
/** 与 core/tun 的夹紧值一致。 */
const TUN_MTU: number = 1420;
/** 劫持 TUN 内所有 53 端口 DNS；VpnConfig 的 DNS 地址由扩展单独提供。 */
const TUN_DNS_HIJACK: string = 'any:53';
/** 与上游默认一致。 */
const KEEP_ALIVE_INTERVAL: number = 30;
/** 最小 DNS 的 fake-ip 网段；不内置第三方 DoH。 */
const FAKE_IP_RANGE: string = '198.18.0.1/16';
/** 使用系统解析器；真机需确认 TUN 下无环路（设计 §10.4【待确认】）。 */
const SYSTEM_NAMESERVER: string = 'system';

/** `profile` 段中本模块会写入的键；其余字段原样保留。 */
interface ProfileSection {
  'store-selected'?: boolean;
}

/** `tun` 段中本模块会写入的键；其余字段（device、route-address 等）原样保留。 */
interface TunSection {
  enable?: boolean;
  stack?: string;
  mtu?: number;
  'dns-hijack'?: string[];
  'auto-route'?: boolean;
  'auto-detect-interface'?: boolean;
}

/** `dns` 段中最小注入使用的键；已有值一律不覆盖。 */
interface DnsSection {
  enable?: boolean;
  'enhanced-mode'?: string;
  'fake-ip-range'?: string;
  nameserver?: string[];
  fallback?: string[];
}

/**
 * 修补视图：只声明白名单键，且全部为可选。
 * 这是对开放对象的局部类型描述，不是索引签名；未声明的键不会因此丢失。
 */
interface RawConfigPatchView {
  mode?: string;
  'log-level'?: string;
  'allow-lan'?: boolean;
  'bind-address'?: string;
  'mixed-port'?: number;
  port?: number;
  'socks-port'?: number;
  'redir-port'?: number;
  'tproxy-port'?: number;
  'external-controller'?: string;
  'external-ui'?: string;
  secret?: string;
  'find-process-mode'?: string;
  'geodata-loader'?: string;
  'unified-delay'?: boolean;
  'tcp-concurrent'?: boolean;
  'keep-alive-interval'?: number;
  profile?: object | null;
  tun?: object | null;
  dns?: object | null;
  rule?: string[] | null;
  rules?: string[] | null;
}

/** 规整后的 tun 段：沿用已有对象（保留未知键），不是对象时新建。 */
function ensureTunSection(view: RawConfigPatchView): TunSection {
  const existing: object | undefined = readSection(view.tun);
  if (existing === undefined) {
    const created: TunSection = {};
    view.tun = created;
    return created;
  }
  return existing as TunSection;
}

/** 规整后的 profile 段：沿用已有对象（保留未知键），不是对象时新建。 */
function ensureProfileSection(view: RawConfigPatchView): ProfileSection {
  const existing: object | undefined = readSection(view.profile);
  if (existing === undefined) {
    const created: ProfileSection = {};
    view.profile = created;
    return created;
  }
  return existing as ProfileSection;
}

/** 规整后的 dns 段：沿用已有对象（保留未知键），不是对象时新建。 */
function ensureDnsSection(view: RawConfigPatchView): DnsSection {
  const existing: object | undefined = readSection(view.dns);
  if (existing === undefined) {
    const created: DnsSection = {};
    view.dns = created;
    return created;
  }
  return existing as DnsSection;
}

/**
 * 只接受真正的对象：`null`、数组、字符串/数字等一律视为“缺失”。
 * 配置文件来自 JSON，正常路径是对象；这里防的是畸形或被篡改的输入。
 */
function readSection(value: object | null | undefined): object | undefined {
  if (value === null || value === undefined) {
    return undefined;
  }
  if (Array.isArray(value)) {
    return undefined;
  }
  if (typeof value !== 'object') {
    return undefined;
  }
  return value;
}

/**
 * 把遗留 `rules` 键规整为 mihomo 认识的 `rule`。
 *
 * - 只有 `rules`：迁移为 `rule`，并删除遗留键（mihomo 会忽略 `rules`，留着只会误导读配置的人）。
 * - 两者都有：以 `rule` 为准，删除遗留键并记录 `rule_key_conflict` 告警（不记录内容）。
 * - 只有 `rule` / 都没有：不做改动。
 *
 * 返回补丁前是否存在“实际规则数组”，供补丁后断言使用。
 */
function normalizeRuleKey(view: RawConfigPatchView, warnings: string[] | undefined): boolean {
  const ruleValue: string[] | null | undefined = view.rule;
  const legacyValue: string[] | null | undefined = view.rules;
  const hasRuleKey: boolean = ruleValue !== undefined;
  const hasLegacyKey: boolean = legacyValue !== undefined;
  const hadRuleArray: boolean = Array.isArray(ruleValue) || Array.isArray(legacyValue);

  if (hasLegacyKey && !hasRuleKey) {
    // 只有数组才是有效规则；非数组（含 null）不迁移，只删除非法遗留键。
    if (Array.isArray(legacyValue)) {
      view.rule = legacyValue;
    }
    delete view.rules;
  } else if (hasLegacyKey && hasRuleKey) {
    if (warnings !== undefined) {
      warnings.push(WARN_RULE_KEY_CONFLICT);
    }
    delete view.rules;
  }

  return hadRuleArray;
}

/**
 * 在规则数组最前放入回环直连规则，并确保只出现一次。
 *
 * 只去重这一条固定规则，不改动 profile 中其他规则的顺序或重复项：规则是首匹配生效，
 * 全局去重可能改变原有语义。
 */
function prependLoopbackRule(rules: string[]): string[] {
  const result: string[] = [LOOPBACK_DIRECT_RULE];
  for (let index: number = 0; index < rules.length; index++) {
    if (rules[index] !== LOOPBACK_DIRECT_RULE) {
      result.push(rules[index]);
    }
  }
  return result;
}

/**
 * 规则键补丁：迁移 → 回环直连 → 断言。
 *
 * 断言只在原配置确实存在规则数组时执行：补丁后 `rule` 必须仍是数组，
 * 防止 `rule` 被写成 `rules` 或畸形值导致内核规则全丢（设计 §15 风险项）。
 * 失败抛 `config_invalid`，不把配置内容放进错误消息。
 */
function patchRuleKey(view: RawConfigPatchView, warnings: string[] | undefined): void {
  const hadRules: boolean = normalizeRuleKey(view, warnings);
  const ruleValue: string[] | null | undefined = view.rule;
  if (Array.isArray(ruleValue) && ruleValue.length > 0) {
    view.rule = prependLoopbackRule(ruleValue);
  }
  if (hadRules && !Array.isArray(view.rule)) {
    throw new Error(ERROR_CONFIG_INVALID);
  }
}

/**
 * 最小 DNS 注入：仅当 `dns` 缺失或 `dns.enable !== true`。
 *
 * 已有 `dns` 对象中的字段一律不覆盖，只补缺失的最小键并打开 enable：
 * 这样既能保证 fake-ip 可用，也不会抹掉订阅方自己的 nameserver/策略。
 * 若 `dns` 已启用（`enable === true`），整段保持原样。
 */
function patchDns(view: RawConfigPatchView): void {
  const existing: object | undefined = readSection(view.dns);
  if (existing !== undefined) {
    const enabled: DnsSection = existing as DnsSection;
    if (enabled.enable === true) {
      return;
    }
  }

  const dns: DnsSection = ensureDnsSection(view);
  if (dns.enable !== true) {
    dns.enable = true;
  }
  if (dns['enhanced-mode'] === undefined) {
    dns['enhanced-mode'] = 'fake-ip';
  }
  if (dns['fake-ip-range'] === undefined) {
    dns['fake-ip-range'] = FAKE_IP_RANGE;
  }
  if (dns.nameserver === undefined) {
    dns.nameserver = [SYSTEM_NAMESERVER];
  }
  if (dns.fallback === undefined) {
    dns.fallback = [];
  }
}

/** 白名单标量字段；顺序与设计 §10.4 表一致。 */
function patchScalarKeys(view: RawConfigPatchView): void {
  view.mode = 'rule';
  view['log-level'] = DEFAULT_LOG_LEVEL;
  view['allow-lan'] = false;
  // 设计 §10.4：bind-address 只在 profile 自带该键时改回回环，不凭空新增。
  if (view['bind-address'] !== undefined) {
    view['bind-address'] = LOOPBACK_BIND_ADDRESS;
  }
  view['mixed-port'] = 0;
  view.port = 0;
  view['socks-port'] = 0;
  view['redir-port'] = 0;
  view['tproxy-port'] = 0;
  view['external-controller'] = '';
  view['external-ui'] = '';
  view.secret = '';
  view['find-process-mode'] = 'off';
  view['geodata-loader'] = 'memconservative';
  view['unified-delay'] = true;
  view['tcp-concurrent'] = true;
  view['keep-alive-interval'] = KEEP_ALIVE_INTERVAL;
}

/** `profile.store-selected` 交给 Harlgram 的 selectedMap 管理，禁止内核双写。 */
function patchProfile(view: RawConfigPatchView): void {
  const profile: ProfileSection = ensureProfileSection(view);
  profile['store-selected'] = false;
}

/** TUN 白名单字段；已有 tun 段的其余键（device、route-address 等）保持原样。 */
function patchTun(view: RawConfigPatchView): void {
  const tun: TunSection = ensureTunSection(view);
  tun.enable = true;
  tun.stack = TUN_STACK;
  tun.mtu = TUN_MTU;
  tun['dns-hijack'] = [TUN_DNS_HIJACK];
  tun['auto-route'] = false;
  tun['auto-detect-interface'] = false;
}

/**
 * 对 `getConfig` 返回的开放配置做白名单修补，并返回同一个对象。
 *
 * 调用方传入 `warnings` 数组时，双规则键等诊断码会追加到该数组；不传则不记录。
 * 这些码可直接写入诊断，不包含配置内容。需要结果对象时可用 `patchWithDiagnostics`。
 *
 * 抛错：
 * - 入参不是 JSON 对象 → `config_invalid`；
 * - 原配置有规则数组、补丁后 `rule` 却不存在或不是数组 → `config_invalid`。
 */
export function patch(config: RawConfig, warnings?: string[]): RawConfig {
  if (config === null || typeof config !== 'object' || Array.isArray(config)) {
    throw new Error(ERROR_CONFIG_INVALID);
  }

  const view: RawConfigPatchView = config as RawConfigPatchView;
  patchRuleKey(view, warnings);
  patchScalarKeys(view);
  patchProfile(view);
  patchTun(view);
  patchDns(view);
  return config;
}

/** 补丁结果：`config` 与输入是同一个对象，`warnings` 只含固定诊断码。 */
export interface ClashConfigPatchResult {
  config: RawConfig;
  warnings: string[];
}

/** 需要读取告警时的入口；行为与 `patch` 完全一致。 */
export function patchWithDiagnostics(config: RawConfig): ClashConfigPatchResult {
  const warnings: string[] = [];
  const patched: RawConfig = patch(config, warnings);
  return { config: patched, warnings: warnings };
}