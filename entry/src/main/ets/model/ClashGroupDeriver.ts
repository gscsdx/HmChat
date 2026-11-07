/**
 * Clash 节点/代理组派生（任务 T-S1-08）。
 *
 * 证据：
 * - docs/integration/clash-proxy-tasks.md T-S1-08（组派生、叶子解析、可用性）。
 * - docs/integration/clash-proxy-design.md §9.4（组派生算法与 `group/name` 列表键）。
 * - docs/integration/flclash-core-lib-baseline.md §3.5（`getProxies` 字段、
 *   `core.dart` L100-L147 的派生顺序、`common.dart` L281-L307 的深度 16 叶子解析）。
 *
 * 约束：
 * - 纯 TypeScript：只依赖 `./ClashModels` 的类型，不引用任何 HarmonyOS Kit，
 *   不读写文件、不发请求、不读时钟。
 * - 只消费 `getProxies` 返回的开放 JSON 对象；不负责 RPC/Action 解码。
 * - 不保存也不回显服务器地址：`server` 只参与「必要字段是否齐全」的布尔判断，
 *   `serverDescription` 完全不读取。`unavailableReason` 只用固定中文文案。
 * - 不使用来源未知的 `now` 覆盖节点展示名：`ProxyNode.name` 始终是组成员名，
 *   `ProxyGroup.now` 只保存解析后的叶子；解析被截断时由 `nowTruncated` 标记。
 * - 组内成员保持 `getProxies` 的原始顺序，不在派生阶段排序。
 */

import { ProxyAvailability, ProxyGroup, ProxyGroupType, ProxyNode } from './ClashModels';

/** 叶子解析深度上限；与 Dart `GroupsExt.resolveToLeafProxy` 的 16 一致。 */
export const MAX_LEAF_DEPTH: number = 16;

/** 根组固定名；只有 `getProxies` 确实返回它时才派生。 */
export const GLOBAL_GROUP_NAME: string = 'GLOBAL';

/** 组类型白名单；顺序与 `ProxyGroupType` 定义一致。 */
export const PROXY_GROUP_TYPES: string[] = ['Selector', 'URLTest', 'Fallback', 'LoadBalance', 'Relay'];

/** 内置出站名；它们没有 server/port，但仍可选择。 */
const BUILTIN_DIRECT: string = 'DIRECT';
const BUILTIN_REJECT: string = 'REJECT';

/** 端口合法范围；只用于必要字段判断，不保存端口值。 */
const MIN_PORT: number = 1;
const MAX_PORT: number = 65535;

/** 固定、脱敏、面向用户的不可用原因；不得拼接任何节点或服务器信息。 */
const REASON_TYPE_MISSING: string = '该节点类型暂不支持';
const REASON_ENDPOINT_MISSING: string = '节点缺少必要连接信息';
const REASON_NODE_DEAD: string = '节点当前不可用';

/**
 * `getProxies` map 中的一个已解析条目。
 *
 * 只保留派生需要的字段；`server`/`serverDescription`/`port` 不进入本结构，
 * 因此后续 UI 状态、日志或快照都不会携带服务器地址。
 */
export interface ParsedProxyEntry {
  /** map 键，即节点或组名。 */
  name: string;
  /** 内核 type；缺失或非字符串时为空串（不伪造）。 */
  type: string;
  /** 组成员名，保持原始顺序；叶节点为空数组。 */
  all: string[];
  /** 组当前出口；缺失或空串时省略。 */
  now?: string;
  /** 仅严格 `true` 视为隐藏组。 */
  hidden: boolean;
  /** 内核 alive；缺失或非布尔时省略。 */
  alive?: boolean;
  /** 组测速地址；缺失时省略。 */
  testUrl?: string;
  /** 组图标；缺失时省略。 */
  icon?: string;
  /** 非组节点是否具备 server 与非空端口；组恒为 false。 */
  hasEndpoint: boolean;
}

/** 沿 `now` 解析到叶子的结果；截断时 `name` 为组名而不是叶子名。 */
export interface LeafResolution {
  /** 解析结果；未截断时为叶子名，截断时为当前组名。 */
  name: string;
  /** 因深度超限或环而无法继续解析。 */
  truncated: boolean;
  /** 是否检测到组引用环。 */
  cycle: boolean;
}

/**
 * 派生后的组。额外字段只描述 `now` 解析质量，不改变 `ProxyGroup` 的语义：
 * `nowTruncated` 为 true 时 UI 必须标注「嵌套过深」而不是把组名当真实出口。
 */
export interface DerivedProxyGroup extends ProxyGroup {
  nowTruncated: boolean;
  nowCycle: boolean;
}

/** `getProxies` 条目的局部视图；未声明的键（含 serverDescription）不会被读取。 */
interface ProxyEntryView {
  type?: string;
  all?: string[];
  now?: string;
  hidden?: boolean;
  alive?: boolean;
  testUrl?: string;
  icon?: string;
  server?: string;
  port?: number;
}

/** 可用性判定结果；reason 只在 unavailable 时出现。 */
interface AvailabilityDecision {
  availability: ProxyAvailability;
  reason?: string;
}

// ---------------------------------------------------------------------------
// 基础读取
// ---------------------------------------------------------------------------

/** 只接受真正的对象：`null`、数组与标量都按缺失处理。 */
function isPlainObjectValue(value: object | null | undefined): boolean {
  if (value === null || value === undefined) {
    return false;
  }
  if (Array.isArray(value)) {
    return false;
  }
  return typeof value === 'object';
}

/** 从开放 map 中读取一个对象型条目；缺失或畸形时返回 undefined。 */
function readEntry(
  proxies: Record<string, ParsedProxyEntry>,
  name: string,
): ParsedProxyEntry | undefined {
  if (proxies === null || proxies === undefined || typeof proxies !== 'object') {
    return undefined;
  }
  const entry: ParsedProxyEntry | undefined = proxies[name];
  if (!isPlainObjectValue(entry)) {
    return undefined;
  }
  return entry;
}

/** 组类型收窄；不使用枚举或索引签名。 */
function toGroupType(type: string): ProxyGroupType | undefined {
  if (type === 'Selector') {
    return 'Selector';
  }
  if (type === 'URLTest') {
    return 'URLTest';
  }
  if (type === 'Fallback') {
    return 'Fallback';
  }
  if (type === 'LoadBalance') {
    return 'LoadBalance';
  }
  if (type === 'Relay') {
    return 'Relay';
  }
  return undefined;
}

/** 判断 type 是否为组类型；缺失/未知类型返回 false。 */
export function isGroupType(type: string): boolean {
  if (typeof type !== 'string' || type.length === 0) {
    return false;
  }
  return toGroupType(type) !== undefined;
}

/** 判断已解析条目是否为组。 */
export function isGroupEntry(entry: ParsedProxyEntry | undefined): boolean {
  if (entry === undefined || entry === null) {
    return false;
  }
  return isGroupType(entry.type);
}

// ---------------------------------------------------------------------------
// 解析
// ---------------------------------------------------------------------------

/** 读取 `all` 中的字符串成员，丢弃空串与非字符串，保持原顺序。 */
function readGroupMembers(value: object): string[] {
  const result: string[] = [];
  const view: ProxyEntryView = value as ProxyEntryView;
  const rawAll: string[] | undefined = view.all;
  if (rawAll === undefined || !Array.isArray(rawAll)) {
    return result;
  }
  for (let index: number = 0; index < rawAll.length; index++) {
    const member: string = rawAll[index];
    if (typeof member === 'string' && member.length > 0) {
      result.push(member);
    }
  }
  return result;
}

/** 非组节点是否具备必要连接字段（server + 合法端口）；只返回布尔，不保存值。 */
function hasEndpointFields(view: ProxyEntryView): boolean {
  let hasServer: boolean = false;
  if (typeof view.server === 'string' && view.server.trim().length > 0) {
    hasServer = true;
  }
  let hasPort: boolean = false;
  if (typeof view.port === 'number' &&
    Number.isInteger(view.port) &&
    view.port >= MIN_PORT &&
    view.port <= MAX_PORT) {
    hasPort = true;
  }
  return hasServer && hasPort;
}

/**
 * 解析 `getProxies` 返回的开放 JSON map。
 *
 * - 空对象、`null`、缺字段、非对象条目都只跳过，不抛错、不伪造节点；
 * - `type` 缺失或为空串时保留条目但 `type=''`，后续按不可用处理；
 * - `all` 只接受字符串数组，顺序原样保留；
 * - `hidden` 只在严格等于 `true` 时为 true；
 * - 返回的键顺序与 `Object.keys(json)` 一致，供 UI 保持组顺序。
 */
export function parseProxies(json: object): Record<string, ParsedProxyEntry> {
  const result: Record<string, ParsedProxyEntry> = {};
  if (!isPlainObjectValue(json)) {
    return result;
  }
  const map: Record<string, object> = json as Record<string, object>;
  const names: string[] = Object.keys(map);
  for (let index: number = 0; index < names.length; index++) {
    const name: string = names[index];
    if (typeof name !== 'string' || name.length === 0) {
      continue;
    }
    const rawValue: object | undefined = map[name];
    if (!isPlainObjectValue(rawValue)) {
      continue;
    }
    const value: object = rawValue as object;
    const view: ProxyEntryView = value as ProxyEntryView;

    let type: string = '';
    if (typeof view.type === 'string' && view.type.trim().length > 0) {
      type = view.type.trim();
    }

    const entry: ParsedProxyEntry = {
      name: name,
      type: type,
      all: readGroupMembers(value),
      hidden: view.hidden === true,
      hasEndpoint: hasEndpointFields(view),
    };

    if (typeof view.now === 'string' && view.now.trim().length > 0) {
      entry.now = view.now.trim();
    }
    if (typeof view.alive === 'boolean') {
      entry.alive = view.alive;
    }
    if (typeof view.testUrl === 'string' && view.testUrl.trim().length > 0) {
      entry.testUrl = view.testUrl.trim();
    }
    if (typeof view.icon === 'string' && view.icon.trim().length > 0) {
      entry.icon = view.icon.trim();
    }

    result[name] = entry;
  }
  return result;
}

// ---------------------------------------------------------------------------
// 可用性
// ---------------------------------------------------------------------------

/** DIRECT/REJECT 没有 server/port，但仍可作为有效出口。 */
function isBuiltinOutbound(name: string, type: string): boolean {
  const upperType: string = type.toUpperCase();
  return name === BUILTIN_DIRECT ||
    name === BUILTIN_REJECT ||
    upperType === BUILTIN_DIRECT ||
    upperType === BUILTIN_REJECT;
}

/**
 * 判定一个成员节点的可用性。
 *
 * 顺序：type 缺失 → 组 → 内置出站 → alive=false → 必要字段缺失 → alive=true
 * → 其余为未知可用态（内核未给出 alive，UI 中性展示）。原因文案固定，不含地址。
 */
function classifyAvailability(name: string, entry: ParsedProxyEntry): AvailabilityDecision {
  if (entry.type.length === 0) {
    return { availability: 'unavailable', reason: REASON_TYPE_MISSING };
  }
  if (isGroupEntry(entry)) {
    // 组本身可以作为成员被选中；其内部叶子健康度由延迟/健康检查单独展示。
    return { availability: 'available' };
  }
  if (isBuiltinOutbound(name, entry.type)) {
    return { availability: 'available' };
  }
  if (entry.alive === false) {
    return { availability: 'unavailable', reason: REASON_NODE_DEAD };
  }
  if (!entry.hasEndpoint) {
    return { availability: 'unavailable', reason: REASON_ENDPOINT_MISSING };
  }
  if (entry.alive === true) {
    return { availability: 'available' };
  }
  return { availability: 'unknown' };
}

/** 构造成员节点；id 使用 `groupName + '/' + name`，同名节点跨组互不冲突。 */
function createProxyNode(groupName: string, memberName: string, entry: ParsedProxyEntry): ProxyNode {
  const decision: AvailabilityDecision = classifyAvailability(memberName, entry);
  const node: ProxyNode = {
    id: groupName + '/' + memberName,
    name: memberName,
    type: entry.type,
    protocolLabel: entry.type.toUpperCase(),
    availability: decision.availability,
    groupName: groupName,
  };
  if (entry.now !== undefined) {
    // 保留内核给出的 now 作为辅助信息；绝不把它当成 name 展示。
    node.now = entry.now;
  }
  if (decision.reason !== undefined) {
    node.unavailableReason = decision.reason;
  }
  return node;
}

/** 按 `all` 原顺序构造成员列表；缺失条目丢弃，同名重复只保留首次出现。 */
function createMemberNodes(
  proxies: Record<string, ParsedProxyEntry>,
  groupName: string,
  memberNames: string[],
): ProxyNode[] {
  const nodes: ProxyNode[] = [];
  const seen: Set<string> = new Set<string>();
  for (let index: number = 0; index < memberNames.length; index++) {
    const memberName: string = memberNames[index];
    if (seen.has(memberName)) {
      continue;
    }
    const entry: ParsedProxyEntry | undefined = readEntry(proxies, memberName);
    if (entry === undefined) {
      continue;
    }
    seen.add(memberName);
    nodes.push(createProxyNode(groupName, memberName, entry));
  }
  return nodes;
}

// ---------------------------------------------------------------------------
// 叶子解析
// ---------------------------------------------------------------------------

/** 递归实现；`visited` 只在本次解析内使用，不修改入参。 */
function resolveWithVisited(
  proxies: Record<string, ParsedProxyEntry>,
  name: string,
  depth: number,
  visited: Set<string>,
): LeafResolution {
  if (depth > MAX_LEAF_DEPTH) {
    return { name: name, truncated: true, cycle: false };
  }
  const entry: ParsedProxyEntry | undefined = readEntry(proxies, name);
  if (entry === undefined || !isGroupEntry(entry)) {
    // 不是组（或内核已不返回该条目）即视为叶子；不再猜测其他节点。
    return { name: name, truncated: false, cycle: false };
  }
  const now: string | undefined = entry.now;
  if (now === undefined || now.length === 0) {
    // 组没有当前出口时只能展示组名，但这不是深度/环截断。
    return { name: name, truncated: false, cycle: false };
  }
  if (now === BUILTIN_DIRECT || now === BUILTIN_REJECT) {
    return { name: now, truncated: false, cycle: false };
  }
  if (visited.has(now)) {
    // 返回当前组名并显式标记，避免把循环中的 now 当作真实叶子。
    return { name: name, truncated: true, cycle: true };
  }
  visited.add(name);
  return resolveWithVisited(proxies, now, depth + 1, visited);
}

/**
 * 沿组 `now` 解析到叶子，深度上限 16。
 *
 * - 非组名、缺失条目、`DIRECT`/`REJECT` 直接返回；
 * - 超深或检测到环时返回当前组名，并置 `truncated=true`（环同时置 `cycle=true`）；
 * - 组没有 `now` 时返回组名但 `truncated=false`，因为这是「未选择」而非解析失败。
 */
export function resolveToLeaf(
  proxies: Record<string, ParsedProxyEntry>,
  name: string,
  depth: number = 0,
): LeafResolution {
  if (typeof name !== 'string' || name.length === 0) {
    return { name: '', truncated: false, cycle: false };
  }
  return resolveWithVisited(proxies, name, depth, new Set<string>());
}

// ---------------------------------------------------------------------------
// 组派生
// ---------------------------------------------------------------------------

/** 构造一个组；`now` 只保存解析结果，截断/环状态放在扩展字段。 */
function createGroup(
  proxies: Record<string, ParsedProxyEntry>,
  name: string,
  entry: ParsedProxyEntry,
  type: ProxyGroupType,
): DerivedProxyGroup {
  const group: DerivedProxyGroup = {
    name: name,
    type: type,
    isAuto: type !== 'Selector',
    hidden: entry.hidden,
    all: createMemberNodes(proxies, name, entry.all),
    nowTruncated: false,
    nowCycle: false,
  };
  if (entry.now !== undefined) {
    const resolution: LeafResolution = resolveToLeaf(proxies, entry.now);
    group.now = resolution.name;
    group.nowTruncated = resolution.truncated;
    group.nowCycle = resolution.cycle;
  }
  if (entry.testUrl !== undefined) {
    group.testUrl = entry.testUrl;
  }
  if (entry.icon !== undefined) {
    group.icon = entry.icon;
  }
  return group;
}

/** 追加一个组；已出现、非组、隐藏或缺失的组一律跳过。 */
function appendGroup(
  proxies: Record<string, ParsedProxyEntry>,
  name: string,
  groups: DerivedProxyGroup[],
  seen: Set<string>,
): void {
  if (seen.has(name)) {
    return;
  }
  const entry: ParsedProxyEntry | undefined = readEntry(proxies, name);
  if (entry === undefined || entry.hidden) {
    return;
  }
  const type: ProxyGroupType | undefined = toGroupType(entry.type);
  if (type === undefined) {
    return;
  }
  seen.add(name);
  groups.push(createGroup(proxies, name, entry, type));
}

/**
 * 从已解析的 `getProxies` 派生组列表。
 *
 * 顺序（与上游 `getClashProxiesGroups` 一致）：
 * 1. GLOBAL（存在且为组类型时）；
 * 2. GLOBAL.all 中按原顺序出现的组；
 * 3. `declaredGroupOrder` 中尚未出现的组（profile 声明顺序，作为补充来源）。
 *
 * `hidden === true` 的组默认跳过；成员保持组内原顺序，不排序。
 * 若 GLOBAL 缺失，则只派生 `declaredGroupOrder` 中真实存在的组，不伪造空 GLOBAL。
 */
export function deriveGroups(
  proxies: Record<string, ParsedProxyEntry>,
  declaredGroupOrder?: string[],
): DerivedProxyGroup[] {
  const groups: DerivedProxyGroup[] = [];
  const seen: Set<string> = new Set<string>();
  const globalEntry: ParsedProxyEntry | undefined = readEntry(proxies, GLOBAL_GROUP_NAME);

  if (globalEntry !== undefined) {
    appendGroup(proxies, GLOBAL_GROUP_NAME, groups, seen);
    for (let index: number = 0; index < globalEntry.all.length; index++) {
      appendGroup(proxies, globalEntry.all[index], groups, seen);
    }
  }

  if (Array.isArray(declaredGroupOrder)) {
    for (let index: number = 0; index < declaredGroupOrder.length; index++) {
      const name: string = declaredGroupOrder[index];
      if (typeof name !== 'string' || name.length === 0) {
        continue;
      }
      appendGroup(proxies, name, groups, seen);
    }
  }

  return groups;
}