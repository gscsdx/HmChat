/**
 * `VpnOptions` → `VpnConfigPlan` 的纯构造与校验。
 *
 * 任务：T-S4-01 / S4-01（docs/integration/clash-proxy-tasks.md）。
 * 证据：
 * - docs/integration/clash-proxy-design.md §7.3（字段表与校验规则）、§3.3（失败码）。
 * - docs/integration/flclash-core-lib-baseline.md §2.7（`AndroidVpnOptions` 字段与默认值）。
 * - docs/integration/flclash-baseline.md §4.3（上游 OHOS `buildVpnConfig` 的真实映射与缺陷）。
 * - entry/src/main/ets/model/ClashModels.ts（`VpnOptions`、`AccessControlOptions`、`ProxyScope`）。
 *
 * 约束：
 * - 纯 TypeScript：只依赖 `./ClashModels`，不引用任何 HarmonyOS Kit，不读时钟、不读写文件。
 * - 只使用具名接口与字符串联合；不使用 `any`/`unknown`/枚举/索引签名。
 * - `VpnOptions` 缺字段、空串或非法地址时仍返回结构完整的计划（不把 `undefined` 传给
 *   下游），同时由 `validateVpnOptions` 给出固定诊断码决定是否允许调用 `VpnConnection.create`。
 *
 * 与上游 Android/OHOS 实现的关键差异：
 * - `mtu` 固定 `1420`。上游 OHOS 写死 `1500`，但内核 `core/tun` 的夹紧值是 1420，
 *   TUN 与内核不一致会导致分片/黑洞；SDK 允许区间为 [576, 1500]。
 * - `trustedApplications`/`blockedApplications` 互斥是硬约束：本模块结构上让二者不可能
 *   同时非空。`blockedApplications` 在目标设备上表现为「黑洞断网」，因此恒为 `[]`。
 * - 「仅 Harlgram」只下发 `[ownBundle]` 白名单，绝不用 `blockedApplications` 表达范围。
 * - `port`、`bypassDomain`、`accessControl` 的下发部分在 OHOS 无用途（设计 §7.3），
 *   只在上游语义冲突诊断中读取 `accessControl`/`includePackage`/`excludePackage`。
 */

import { AccessControlOptions, ProxyScope, VpnOptions } from './ClashModels';

// ---------------------------------------------------------------------------
// 诊断码（固定字符串，可直接写入诊断；不含地址、包名或选项内容）
// ---------------------------------------------------------------------------

/** 缺字段/空串/缺省前缀/名单冲突：已使用设计默认值，调用方仍可继续。 */
export const VPN_CODE_OPTIONS_FALLBACK: string = 'options_fallback';

/** 地址/路由/DNS/名单结构非法：调用方不得调用 `create`。 */
export const VPN_CODE_TUN_CONFIG_INVALID: string = 'tun_config_invalid';

// ---------------------------------------------------------------------------
// 设计默认值（设计 §7.3、基线 §2.7）
// ---------------------------------------------------------------------------

/** `state.DefaultIpv4Address`。 */
const DEFAULT_IPV4_ADDRESS: string = '172.19.0.1';
const DEFAULT_IPV4_PREFIX: number = 30;
/** `state.GetIpv6Address()` 在 `VpnProps.Ipv6=true` 时的值。 */
const DEFAULT_IPV6_ADDRESS: string = 'fdfe:dcba:9876::1';
const DEFAULT_IPV6_PREFIX: number = 126;
/** `state.GetDnsServerAddress()`，与内核 `dns-hijack 172.19.0.2:53` 一致。 */
const DEFAULT_DNS_ADDRESS: string = '172.19.0.2';
/** 空 `routeAddress` 的全局路由。 */
const DEFAULT_IPV4_ROUTE: string = '0.0.0.0';
/** IPv6 开启时追加的全局路由。 */
const DEFAULT_IPV6_ROUTE: string = '::';
/**
 * 与内核 `core/tun` 夹紧值一致；不是上游 OHOS 的 1500。
 * 常量本身落在 SDK 允许的 [576, 1500] 内。
 */
const TUN_MTU: number = 1420;

/** IP 族别；用字面量联合而不是枚举。 */
type IpFamily = 4 | 6;

/** 计划中的地址项，对应 `VpnConfig.addresses` 的 `LinkAddress`。 */
export interface VpnAddressPlan {
  address: string;
  prefixLength: number;
}

/** 计划中的路由项，对应 `VpnConfig.routes` 的目标前缀。 */
export interface VpnRoutePlan {
  address: string;
  prefixLength: number;
  isDefaultRoute: boolean;
}

/**
 * 可直接映射到 `@ohos.net.vpnExtension.VpnConfig` 的纯计划。
 * 字段名与设计 §7.3 表格一致；`dns` 是数组以匹配 `dnsAddresses`。
 */
export interface VpnConfigPlan {
  addresses: VpnAddressPlan[];
  routes: VpnRoutePlan[];
  mtu: number;
  dns: string[];
  isIPv4Accepted: boolean;
  isIPv6Accepted: boolean;
  trustedApplications: string[];
  blockedApplications: string[];
}

/** 应用名单意图：由选项按上游语义解析，供互斥诊断与构造使用。 */
interface ApplicationIntent {
  trusted: string[];
  blocked: string[];
}

/** 解析后的 CIDR。 */
interface ParsedCidr {
  address: string;
  prefixLength: number;
}

// ---------------------------------------------------------------------------
// 基础读取与解析
// ---------------------------------------------------------------------------

/** 读取字符串并去掉首尾空白；`undefined`/`null`/非字符串统一视为空串。 */
function readText(value: string | undefined): string {
  if (value === undefined || value === null) {
    return '';
  }
  if (typeof value !== 'string') {
    return '';
  }
  return value.trim();
}

/**
 * 规整包名/应用名列表：丢弃空项、去重、保持原始顺序。
 * 只做展示与下发前的清洗，不猜测缺失的 bundleName 或 abilityName。
 */
function normalizeNames(values: string[] | undefined): string[] {
  const result: string[] = [];
  if (!Array.isArray(values)) {
    return result;
  }
  for (let index: number = 0; index < values.length; index++) {
    const text: string = readText(values[index]);
    if (text.length === 0) {
      continue;
    }
    if (result.indexOf(text) < 0) {
      result.push(text);
    }
  }
  return result;
}

/** 解析十进制前缀长度；非法返回 -1（调用方不得把它当作 0）。 */
function parsePrefixLength(text: string, max: number): number {
  if (text.length === 0 || text.length > 3) {
    return -1;
  }
  let value: number = 0;
  for (let index: number = 0; index < text.length; index++) {
    const code: number = text.charCodeAt(index);
    if (code < 48 || code > 57) {
      return -1;
    }
    value = value * 10 + (code - 48);
  }
  if (value > max) {
    return -1;
  }
  return value;
}

/** 严格 IPv4 点分十进制：4 段、每段 0–255、不允许前导零。 */
function isIpv4Literal(text: string): boolean {
  const parts: string[] = text.split('.');
  if (parts.length !== 4) {
    return false;
  }
  for (let index: number = 0; index < parts.length; index++) {
    const part: string = parts[index];
    if (part.length === 0 || part.length > 3) {
      return false;
    }
    if (part.length > 1 && part.charCodeAt(0) === 48) {
      return false;
    }
    let value: number = 0;
    for (let digit: number = 0; digit < part.length; digit++) {
      const code: number = part.charCodeAt(digit);
      if (code < 48 || code > 57) {
        return false;
      }
      value = value * 10 + (code - 48);
    }
    if (value > 255) {
      return false;
    }
  }
  return true;
}

/** 单个 IPv6 十六进制组：1–4 位十六进制。 */
function isIpv6Group(text: string): boolean {
  if (text.length === 0 || text.length > 4) {
    return false;
  }
  for (let index: number = 0; index < text.length; index++) {
    const code: number = text.charCodeAt(index);
    const isDigit: boolean = code >= 48 && code <= 57;
    const isLowerHex: boolean = code >= 97 && code <= 102;
    const isUpperHex: boolean = code >= 65 && code <= 70;
    if (!isDigit && !isLowerHex && !isUpperHex) {
      return false;
    }
  }
  return true;
}

/**
 * 统计 IPv6 半段占用的 16 位组数；末段允许内嵌 IPv4（占 2 组）。
 * 非法返回 -1。
 */
function countIpv6Groups(part: string): number {
  if (part.length === 0) {
    return 0;
  }
  const groups: string[] = part.split(':');
  let count: number = 0;
  for (let index: number = 0; index < groups.length; index++) {
    const group: string = groups[index];
    const isLast: boolean = index === groups.length - 1;
    if (isLast && group.indexOf('.') >= 0) {
      if (!isIpv4Literal(group)) {
        return -1;
      }
      count += 2;
    } else {
      if (!isIpv6Group(group)) {
        return -1;
      }
      count += 1;
    }
  }
  return count;
}

/** 严格 IPv6 字面量：最多一个 `::`、组数合法、拒绝 zone index（`%`）。 */
function isIpv6Literal(text: string): boolean {
  if (text.length === 0 || text.indexOf('%') >= 0) {
    return false;
  }
  const parts: string[] = text.split('::');
  if (parts.length > 2) {
    return false;
  }
  if (parts.length === 2) {
    const head: number = countIpv6Groups(parts[0]);
    const tail: number = countIpv6Groups(parts[1]);
    if (head < 0 || tail < 0) {
      return false;
    }
    // `::` 至少压缩掉 1 组，故显式组总数不得超过 7。
    return head + tail <= 7;
  }
  return countIpv6Groups(parts[0]) === 8;
}

/** 不带前缀的 IP 字面量（DNS 只接受这种形式）。 */
function isIpLiteral(text: string): boolean {
  if (text.indexOf(':') >= 0) {
    return isIpv6Literal(text);
  }
  return isIpv4Literal(text);
}

/** 是否显式写了 `/前缀`；用于区分「缺省前缀」与「非法前缀」。 */
function hasExplicitPrefix(text: string): boolean {
  return text.indexOf('/') >= 0;
}

/**
 * 解析 CIDR。缺少 `/` 时使用调用方给的默认前缀（地址 30/126，路由 32/128）。
 * 前缀超界、地址非法、出现多个 `/` 均返回 `undefined`。
 */
function parseCidr(text: string, family: IpFamily, defaultPrefix: number): ParsedCidr | undefined {
  const slashIndex: number = text.indexOf('/');
  let addressText: string = text;
  let prefixLength: number = defaultPrefix;
  if (slashIndex >= 0) {
    if (slashIndex === 0 || slashIndex !== text.lastIndexOf('/')) {
      return undefined;
    }
    addressText = text.substring(0, slashIndex);
    prefixLength = parsePrefixLength(text.substring(slashIndex + 1), family === 4 ? 32 : 128);
    if (prefixLength < 0) {
      return undefined;
    }
  }
  const validAddress: boolean = family === 4 ? isIpv4Literal(addressText) : isIpv6Literal(addressText);
  if (!validAddress) {
    return undefined;
  }
  return { address: addressText, prefixLength: prefixLength };
}

/** 把解析结果写入路由表，按 `address/prefixLength` 去重。 */
function pushRoute(routes: VpnRoutePlan[], address: string, prefixLength: number): void {
  for (let index: number = 0; index < routes.length; index++) {
    const existing: VpnRoutePlan = routes[index];
    if (existing.address === address && existing.prefixLength === prefixLength) {
      return;
    }
  }
  routes.push({
    address: address,
    prefixLength: prefixLength,
    isDefaultRoute: prefixLength === 0,
  });
}

// ---------------------------------------------------------------------------
// 选项语义：上游 `buildVpnConfig` 的名单解析
// ---------------------------------------------------------------------------

/** 运行时防御：只接受真正的对象，`null`/数组/标量都视为缺失。 */
function readAccessControl(options: VpnOptions): AccessControlOptions | undefined {
  const value: AccessControlOptions | undefined = options.accessControl;
  if (value === undefined || value === null) {
    return undefined;
  }
  if (typeof value !== 'object' || Array.isArray(value)) {
    return undefined;
  }
  return value;
}

/**
 * 按上游真实语义解析分应用名单意图：
 * - `accessControl.enable=true` 且 `mode==='accept'` → `acceptList` 是白名单；
 * - 其余 mode（含空串/未知值）→ `rejectList` 是黑名单（上游行为）；
 * - `accessControl` 缺失或未启用 → `includePackage` 白名单、`excludePackage` 黑名单。
 *
 * 本 MVP 不下发分应用名单（设计 §7.3 校验规则第 4 条），此意图只用于：
 * 1) 识别「同时要求白名单与黑名单」的冲突并给 `options_fallback`；
 * 2) 构造时保证最终名单仍满足 scope 与互斥约束。
 */
function resolveApplicationIntent(options: VpnOptions): ApplicationIntent {
  const accessControl: AccessControlOptions | undefined = readAccessControl(options);
  if (accessControl !== undefined && accessControl.enable === true) {
    if (accessControl.mode === 'accept') {
      return { trusted: normalizeNames(accessControl.acceptList), blocked: [] };
    }
    return { trusted: [], blocked: normalizeNames(accessControl.rejectList) };
  }
  return {
    trusted: normalizeNames(options.includePackage),
    blocked: normalizeNames(options.excludePackage),
  };
}

/**
 * 最终下发名单只由 `scope` 决定（设计 §7.3 字段表）：
 * - `global`：两项都不下发，避免把设备级代理收窄成应用级；
 * - `harlgramOnly`：只下发 `[ownBundle]`，绝不使用 `blockedApplications`
 *   （目标设备上 blocked 表现为黑洞断网）。
 * 结构上保证 `trustedApplications` 与 `blockedApplications` 不会同时非空。
 */
function resolveScopeApplications(scope: ProxyScope, ownBundle: string): ApplicationIntent {
  if (scope !== 'harlgramOnly') {
    return { trusted: [], blocked: [] };
  }
  return { trusted: normalizeNames([ownBundle]), blocked: [] };
}

/** 构造后断言：互斥约束被违反时按 `tun_config_invalid` 拒绝，不把错误配置交给系统。 */
function assertApplicationLists(plan: VpnConfigPlan): void {
  if (plan.trustedApplications.length > 0 && plan.blockedApplications.length > 0) {
    throw new Error(VPN_CODE_TUN_CONFIG_INVALID);
  }
}

// ---------------------------------------------------------------------------
// 各字段解析
// ---------------------------------------------------------------------------

/** IPv4 地址：有效则保留用户前缀；缺失/非法一律回退设计默认值。 */
function resolveIpv4Address(raw: string | undefined): VpnAddressPlan {
  const text: string = readText(raw);
  if (text.length > 0) {
    const parsed: ParsedCidr | undefined = parseCidr(text, 4, DEFAULT_IPV4_PREFIX);
    if (parsed !== undefined) {
      return parsed;
    }
  }
  return { address: DEFAULT_IPV4_ADDRESS, prefixLength: DEFAULT_IPV4_PREFIX };
}

/**
 * IPv6 地址：只有非空且有效才启用。
 * 非法非空值不启用默认 IPv6——避免用户写错地址时反而扩大路由面；
 * 该输入已被 `validateVpnOptions` 标为 `tun_config_invalid`，调用方不会 `create`。
 */
function resolveIpv6Address(raw: string | undefined): VpnAddressPlan | undefined {
  const text: string = readText(raw);
  if (text.length === 0) {
    return undefined;
  }
  return parseCidr(text, 6, DEFAULT_IPV6_PREFIX);
}

/**
 * 路由：沿用 `routeAddress`（跳过非法项），为空时 `0.0.0.0/0`；
 * IPv6 启用时追加 `::/0`（去重）。路由缺少前缀按主机路由处理。
 */
function resolveRoutes(rawRoutes: string[] | undefined, ipv6Enabled: boolean): VpnRoutePlan[] {
  const routes: VpnRoutePlan[] = [];
  if (Array.isArray(rawRoutes)) {
    for (let index: number = 0; index < rawRoutes.length; index++) {
      const text: string = readText(rawRoutes[index]);
      if (text.length === 0) {
        continue;
      }
      const family: IpFamily = text.indexOf(':') >= 0 ? 6 : 4;
      const parsed: ParsedCidr | undefined = parseCidr(text, family, family === 4 ? 32 : 128);
      if (parsed !== undefined) {
        pushRoute(routes, parsed.address, parsed.prefixLength);
      }
    }
  }
  if (routes.length === 0) {
    pushRoute(routes, DEFAULT_IPV4_ROUTE, 0);
  }
  if (ipv6Enabled) {
    pushRoute(routes, DEFAULT_IPV6_ROUTE, 0);
  }
  return routes;
}

/** DNS：只接受不带前缀的 IP 字面量；缺失/非法回退 `172.19.0.2`。 */
function resolveDnsAddress(raw: string | undefined): string {
  const text: string = readText(raw);
  if (text.length > 0 && text.indexOf('/') < 0 && isIpLiteral(text)) {
    return text;
  }
  return DEFAULT_DNS_ADDRESS;
}

// ---------------------------------------------------------------------------
// 构造入口
// ---------------------------------------------------------------------------

/**
 * 由 `VpnOptions + scope + ownBundle` 构造可测的 VPN 配置计划。
 *
 * 保证：
 * - `mtu` 恒为 1420；
 * - `addresses[0]` 恒为 IPv4（默认 `172.19.0.1/30`）；
 * - `routes` 永不为空；
 * - `isIPv4Accepted` 恒为 `true`，`isIPv6Accepted` 只由有效 IPv6 地址决定；
 * - `global` 不发任何应用名单；`harlgramOnly` 只发 `[ownBundle]`；
 * - `trustedApplications` 与 `blockedApplications` 不同时非空（否则抛
 *   `tun_config_invalid`，不返回半成品）。
 */
export function buildVpnConfig(options: VpnOptions, scope: ProxyScope, ownBundle: string): VpnConfigPlan {
  const ipv4: VpnAddressPlan = resolveIpv4Address(options.ipv4Address);
  const ipv6: VpnAddressPlan | undefined = resolveIpv6Address(options.ipv6Address);

  const addresses: VpnAddressPlan[] = [ipv4];
  if (ipv6 !== undefined) {
    addresses.push(ipv6);
  }

  const applications: ApplicationIntent = resolveScopeApplications(scope, ownBundle);
  const plan: VpnConfigPlan = {
    addresses: addresses,
    routes: resolveRoutes(options.routeAddress, ipv6 !== undefined),
    mtu: TUN_MTU,
    dns: [resolveDnsAddress(options.dnsServerAddress)],
    isIPv4Accepted: true,
    isIPv6Accepted: ipv6 !== undefined,
    trustedApplications: applications.trusted,
    blockedApplications: applications.blocked,
  };
  assertApplicationLists(plan);
  return plan;
}

// ---------------------------------------------------------------------------
// 校验入口
// ---------------------------------------------------------------------------

/** 去重追加诊断码，保持首次出现顺序，便于稳定断言。 */
function addCode(codes: string[], code: string): void {
  if (codes.indexOf(code) < 0) {
    codes.push(code);
  }
}

/** 校验一个字符串数组字段：非数组/非字符串项非法，空串项按回退处理。 */
function validateStringList(value: string[] | undefined, codes: string[]): void {
  if (value === undefined || value === null) {
    return;
  }
  if (typeof value !== 'object' || !Array.isArray(value)) {
    addCode(codes, VPN_CODE_TUN_CONFIG_INVALID);
    return;
  }
  for (let index: number = 0; index < value.length; index++) {
    const item: string = value[index];
    if (typeof item !== 'string') {
      addCode(codes, VPN_CODE_TUN_CONFIG_INVALID);
    } else if (item.trim().length === 0) {
      addCode(codes, VPN_CODE_OPTIONS_FALLBACK);
    }
  }
}

/** 校验 `accessControl` 的结构；语义（accept/reject）交给意图解析。 */
function validateAccessControl(options: VpnOptions, codes: string[]): void {
  const value: AccessControlOptions | undefined = options.accessControl;
  if (value === undefined || value === null) {
    return;
  }
  if (typeof value !== 'object' || Array.isArray(value)) {
    addCode(codes, VPN_CODE_TUN_CONFIG_INVALID);
    return;
  }
  if (typeof value.enable !== 'boolean') {
    addCode(codes, VPN_CODE_TUN_CONFIG_INVALID);
  }
  if (typeof value.mode !== 'string') {
    addCode(codes, VPN_CODE_TUN_CONFIG_INVALID);
  }
  validateStringList(value.acceptList, codes);
  validateStringList(value.rejectList, codes);
}

/** 地址字段校验：空/缺省前缀 → 回退；写了但非法 → 不得 `create`。 */
function validateAddressField(raw: string | undefined, family: IpFamily, codes: string[]): void {
  const text: string = readText(raw);
  if (text.length === 0) {
    addCode(codes, VPN_CODE_OPTIONS_FALLBACK);
    return;
  }
  const parsed: ParsedCidr | undefined = parseCidr(text, family, family === 4 ? DEFAULT_IPV4_PREFIX
    : DEFAULT_IPV6_PREFIX);
  if (parsed === undefined) {
    addCode(codes, VPN_CODE_TUN_CONFIG_INVALID);
    return;
  }
  if (!hasExplicitPrefix(text)) {
    addCode(codes, VPN_CODE_OPTIONS_FALLBACK);
  }
}

/** 路由字段校验：缺失/空数组表示全局路由，合法；非法项不得 `create`。 */
function validateRouteField(rawRoutes: string[] | undefined, codes: string[]): void {
  if (rawRoutes === undefined || rawRoutes === null) {
    return;
  }
  if (typeof rawRoutes !== 'object' || !Array.isArray(rawRoutes)) {
    addCode(codes, VPN_CODE_TUN_CONFIG_INVALID);
    return;
  }
  for (let index: number = 0; index < rawRoutes.length; index++) {
    const text: string = readText(rawRoutes[index]);
    if (text.length === 0) {
      addCode(codes, VPN_CODE_TUN_CONFIG_INVALID);
      continue;
    }
    const family: IpFamily = text.indexOf(':') >= 0 ? 6 : 4;
    const parsed: ParsedCidr | undefined = parseCidr(text, family, family === 4 ? 32 : 128);
    if (parsed === undefined) {
      addCode(codes, VPN_CODE_TUN_CONFIG_INVALID);
      continue;
    }
    if (!hasExplicitPrefix(text)) {
      addCode(codes, VPN_CODE_OPTIONS_FALLBACK);
    }
  }
}

/**
 * 校验 `VpnOptions` 并返回固定诊断码（去重、稳定顺序）。
 *
 * - 返回空数组：选项可用于 `VpnConnection.create`；
 * - 含 `options_fallback`：已使用设计默认值，可继续；
 * - 含 `tun_config_invalid`：调用方不得 `create`，应进入 `failed(tun_config_invalid)`。
 *
 * 空 `ipv6Address` 是合法状态（IPv6 关闭），不产生任何码。
 * 本函数不校验 `scope`/`ownBundle`（签名不含二者），由调用方在构造前自行保证。
 */
export function validateVpnOptions(options: VpnOptions): string[] {
  const codes: string[] = [];

  validateAddressField(options.ipv4Address, 4, codes);

  // IPv6 为空表示关闭，不告警；非空才需要合法。
  const ipv6Text: string = readText(options.ipv6Address);
  if (ipv6Text.length > 0) {
    const parsed: ParsedCidr | undefined = parseCidr(ipv6Text, 6, DEFAULT_IPV6_PREFIX);
    if (parsed === undefined) {
      addCode(codes, VPN_CODE_TUN_CONFIG_INVALID);
    } else if (!hasExplicitPrefix(ipv6Text)) {
      addCode(codes, VPN_CODE_OPTIONS_FALLBACK);
    }
  }

  const dnsText: string = readText(options.dnsServerAddress);
  if (dnsText.length === 0) {
    addCode(codes, VPN_CODE_OPTIONS_FALLBACK);
  } else if (dnsText.indexOf('/') >= 0 || !isIpLiteral(dnsText)) {
    addCode(codes, VPN_CODE_TUN_CONFIG_INVALID);
  }

  validateRouteField(options.routeAddress, codes);
  validateStringList(options.includePackage, codes);
  validateStringList(options.excludePackage, codes);
  validateAccessControl(options, codes);

  // 上游语义下「白名单 + 黑名单」可能同时非空（include 与 exclude 并存）。
  // 本模块只保留 scope 决定的名单并丢弃黑名单，记录回退码，绝不把两者一起下发。
  const intent: ApplicationIntent = resolveApplicationIntent(options);
  if (intent.trusted.length > 0 && intent.blocked.length > 0) {
    addCode(codes, VPN_CODE_OPTIONS_FALLBACK);
  }

  return codes;
}