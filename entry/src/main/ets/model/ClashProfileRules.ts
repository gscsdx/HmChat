/**
 * Clash Profile 纯规则：profile id 校验、显示名清洗、`selectedMap` 合并、
 * 内容 hash 等价判定与文件名构造（任务 T-S1-04，设计 §8.2-§8.4）。
 *
 * 约束：
 * - 纯 TypeScript：不引用任何 Kit 或系统模块，不读文件、不发请求、不读时钟。
 * - 只依赖 `./ClashModels` 的 `PROFILE_ID_PATTERN`，让 id 规则单点定义。
 * - hash 计算不在这里做，调用方传入 hash；本模块只判断「内容是否相同」。
 * - 失败路径不回显用户输入：文件名构造的错误消息固定为 `invalid_profile_id`。
 */

import { PROFILE_ID_PATTERN } from './ClashModels';

/** 设计 §8.2：profile id 白名单字符与长度上限。 */
const PROFILE_ID_REGEX: RegExp = new RegExp(PROFILE_ID_PATTERN);
const MAX_PROFILE_ID_LENGTH: number = 64;
const MAX_DISPLAY_NAME_LENGTH: number = 64;

/** 空显示名回退文案；与设计 §11 的中文界面一致。 */
const FALLBACK_DISPLAY_NAME: string = '未命名配置';
/** 空 seed 派生的兜底 id，本身满足 PROFILE_ID_PATTERN。 */
const FALLBACK_PROFILE_ID: string = 'profile';
/** 文件名构造失败的固定错误码，不拼接原始 id。 */
const INVALID_PROFILE_ID: string = 'invalid_profile_id';

const PROFILE_FILE_SUFFIX: string = '.yaml';
const PREV_FILE_SUFFIX: string = '.prev.yaml';

/** 重名序号上限；超出后返回最后一个候选名，避免无界循环。 */
const MAX_DUPLICATE_INDEX: number = 999;

/**
 * C0/C1 控制字符、零宽字符与双向控制符：不可见，且可能污染日志或改变展示顺序。
 * 匹配后替换为一个空格，再交给空白压缩，避免把相邻单词粘连。
 */
const CONTROL_CHARACTER_PATTERN: RegExp =
  /[\u0000-\u001F\u007F-\u009F\u200B-\u200F\u202A-\u202E\u2066-\u2069\uFEFF]/g;
/** 连续空白（含全角空格、换行）压缩为一个半角空格。 */
const WHITESPACE_RUN_PATTERN: RegExp = /\s+/g;
const WHITESPACE_PATTERN: RegExp = /\s/;

/** URL 编码字符一律拒绝，覆盖 `%2e%2e`、`%2f`、`%5c` 等绕过写法。 */
const URL_ENCODING_MARKER: string = '%';
const PATH_SEPARATOR_FORWARD: string = '/';
const PATH_SEPARATOR_BACKWARD: string = '\\';
const NUL_CHARACTER: string = '\u0000';

/** 派生 id 时把非法字符段压缩为单个连字符。 */
const DISALLOWED_ID_CHARACTER_PATTERN: RegExp = /[^A-Za-z0-9_-]+/g;
const REPEATED_DASH_PATTERN: RegExp = /-{2,}/g;

/** 高代理项区间；截断时不能留下半个代理对（否则显示为乱码）。 */
const HIGH_SURROGATE_MIN: number = 0xD800;
const HIGH_SURROGATE_MAX: number = 0xDBFF;

/**
 * 判断 profile id 是否可以安全地用于文件路径与 RPC 参数。
 *
 * 规则（设计 §8.2）：精确匹配 `^[A-Za-z0-9_-]{1,64}$`。因此以下输入全部拒绝：
 * - 空串、`.`、`..`（路径穿越）
 * - 含 `/`、`\`、NUL、空白（绝对路径与多段路径）
 * - 含 `%`（URL 编码绕过，如 `%2e%2e`、`%2f`）
 *
 * 以 `-` 开头的 id 按 `PROFILE_ID_PATTERN` 允许，本函数不额外收紧，
 * 以免与存储层、RPC 层对同一常量的判断不一致；本工程不把 id 交给 shell。
 */
export function isValidProfileId(id: string): boolean {
  if (typeof id !== 'string') {
    return false;
  }
  if (id.length < 1 || id.length > MAX_PROFILE_ID_LENGTH) {
    return false;
  }
  if (id === '.' || id === '..') {
    return false;
  }
  if (id.indexOf(PATH_SEPARATOR_FORWARD) >= 0 || id.indexOf(PATH_SEPARATOR_BACKWARD) >= 0) {
    return false;
  }
  if (id.indexOf(NUL_CHARACTER) >= 0) {
    return false;
  }
  if (id.indexOf(URL_ENCODING_MARKER) >= 0) {
    return false;
  }
  if (WHITESPACE_PATTERN.test(id)) {
    return false;
  }
  return PROFILE_ID_REGEX.test(id);
}

/** 以 UTF-16 单元截断，但绝不切开代理对；结果长度不超过 `limit`。 */
function truncateDisplayName(text: string, limit: number): string {
  if (limit <= 0) {
    return '';
  }
  if (text.length <= limit) {
    return text;
  }
  let cut: string = text.slice(0, limit);
  const lastUnit: number = cut.charCodeAt(cut.length - 1);
  if (lastUnit >= HIGH_SURROGATE_MIN && lastUnit <= HIGH_SURROGATE_MAX) {
    cut = cut.slice(0, cut.length - 1);
  }
  return cut;
}

/** 去控制字符、压缩空白并截断；空结果由调用方决定是否回退。 */
function normalizeDisplayName(raw: string): string {
  if (typeof raw !== 'string') {
    return '';
  }
  let text: string = raw.replace(CONTROL_CHARACTER_PATTERN, ' ');
  text = text.replace(WHITESPACE_RUN_PATTERN, ' ').trim();
  return truncateDisplayName(text, MAX_DISPLAY_NAME_LENGTH);
}

/** 精确比较已有显示名；不比较大小写，避免静默改写用户输入。 */
function containsName(names: string[], candidate: string): boolean {
  for (let index: number = 0; index < names.length; index++) {
    if (typeof names[index] === 'string' && names[index] === candidate) {
      return true;
    }
  }
  return false;
}

/**
 * 清洗用户可见的配置显示名。
 *
 * - 去掉控制字符/零宽字符，压缩连续空白并 trim；
 * - 按 UTF-16 单元截断到 64，且不切开代理对；
 * - 空结果回退为「未命名配置」；
 * - 与 `existing` 重名时追加 ` (2)`、` (3)`…；追加序号后仍不超过 64。
 *
 * 本函数不读写存储、不去重持久化，只返回可直接保存的名称。
 */
export function sanitizeDisplayName(raw: string, existing?: string[]): string {
  const normalized: string = normalizeDisplayName(raw);
  const name: string = normalized.length > 0 ? normalized : FALLBACK_DISPLAY_NAME;
  const taken: string[] = Array.isArray(existing) ? existing : [];
  if (!containsName(taken, name)) {
    return name;
  }
  // 序号后缀会占用长度，先按剩余宽度截断基名，保证候选名仍不超过 64。
  let candidate: string = name;
  for (let index: number = 2; index <= MAX_DUPLICATE_INDEX; index++) {
    const suffix: string = ' (' + String(index) + ')';
    const head: string = truncateDisplayName(name, MAX_DISPLAY_NAME_LENGTH - suffix.length).trim();
    candidate = (head.length > 0 ? head : FALLBACK_DISPLAY_NAME) + suffix;
    if (!containsName(taken, candidate)) {
      return candidate;
    }
  }
  // 极端重名（999 个同前缀）下返回最后一个候选，保持确定性且不返回原始重名。
  return candidate;
}

/** 读取一个组的节点名；缺失、非字符串或空白一律视为空。 */
function readNodeName(source: Record<string, string>, group: string): string {
  if (!source) {
    return '';
  }
  const value: string | undefined = source[group];
  if (typeof value !== 'string') {
    return '';
  }
  return value.trim();
}

/**
 * 合并两份「组名 → 节点名」选择表。
 *
 * - 结果只包含 `availableGroups` 中真实存在的组，未知组一律丢弃；
 * - 节点名 trim 后为空则丢弃，绝不产生空串（禁止 `changeProxy` 收到空 `proxy-name`）；
 * - `next` 中非空值优先，`next` 缺失或为空时回退 `current`，两者都空则不写入；
 * - 不修改 `current` / `next`，始终返回新对象。
 */
export function mergeSelectedMap(
  current: Record<string, string>,
  next: Record<string, string>,
  availableGroups: string[],
): Record<string, string> {
  const merged: Record<string, string> = {};
  if (!Array.isArray(availableGroups)) {
    return merged;
  }
  for (let index: number = 0; index < availableGroups.length; index++) {
    const group: string = availableGroups[index];
    if (typeof group !== 'string' || group.length === 0) {
      continue;
    }
    const fromNext: string = readNodeName(next, group);
    if (fromNext.length > 0) {
      merged[group] = fromNext;
      continue;
    }
    const fromCurrent: string = readNodeName(current, group);
    if (fromCurrent.length > 0) {
      merged[group] = fromCurrent;
    }
  }
  return merged;
}

/** hash 归一化：trim + 小写；非字符串或空白返回空串。 */
function normalizeHash(value: string): string {
  if (typeof value !== 'string') {
    return '';
  }
  return value.trim().toLowerCase();
}

/**
 * 判断两次配置内容是否相同，用于「无变化」提示。
 *
 * 比较前 trim 并转小写；任一侧为空则返回 `false`（未知不代表相同，
 * 避免把「还没算 hash」误判为无变化）。hash 计算不属于本模块。
 */
export function isSameContent(prevHash: string, nextHash: string): boolean {
  const previous: string = normalizeHash(prevHash);
  if (previous.length === 0) {
    return false;
  }
  const next: string = normalizeHash(nextHash);
  if (next.length === 0) {
    return false;
  }
  return previous === next;
}

/** 校验失败即抛出固定错误码，不把原始 id 写入消息或日志。 */
function requireValidProfileId(id: string): string {
  if (!isValidProfileId(id)) {
    throw new Error(INVALID_PROFILE_ID);
  }
  return id;
}

/** 内核加载的正式配置文件名：`<id>.yaml`；非法 id 抛 `invalid_profile_id`。 */
export function buildProfileFileName(id: string): string {
  return requireValidProfileId(id) + PROFILE_FILE_SUFFIX;
}

/** 备份配置文件名：`<id>.prev.yaml`；非法 id 抛 `invalid_profile_id`。 */
export function buildPrevFileName(id: string): string {
  return requireValidProfileId(id) + PREV_FILE_SUFFIX;
}

/** 去掉首尾连字符：派生 id 不使用 `-` 开头/结尾，避免像命令行选项。 */
function stripEdgeDashes(text: string): string {
  let result: string = text;
  while (result.startsWith('-')) {
    result = result.slice(1);
  }
  while (result.endsWith('-')) {
    result = result.slice(0, result.length - 1);
  }
  return result;
}

/**
 * 从域名、URL 或时间戳等 seed 派生安全 profile id。
 *
 * - 只保留 `[A-Za-z0-9_-]`：其余字符段（`:`、`?`、`/`、`.`、`%`、空白、CJK 等）
 *   压缩为单个 `-`；
 * - 折叠连续 `-`，去掉首尾 `-`，截断到 64；
 * - 空 seed、或清洗后为空的 seed 返回 `profile`。
 *
 * 本函数不读时钟：需要时间戳的调用方把值放进 `seed`。大小写按输入保留，
 * 调用方若要按域名去重，应先自行做小写归一化。
 */
export function deriveProfileId(seed: string): string {
  if (typeof seed !== 'string') {
    return FALLBACK_PROFILE_ID;
  }
  let derived: string = seed.replace(DISALLOWED_ID_CHARACTER_PATTERN, '-');
  derived = derived.replace(REPEATED_DASH_PATTERN, '-');
  derived = stripEdgeDashes(derived);
  if (derived.length > MAX_PROFILE_ID_LENGTH) {
    derived = stripEdgeDashes(derived.slice(0, MAX_PROFILE_ID_LENGTH));
  }
  if (derived.length === 0) {
    return FALLBACK_PROFILE_ID;
  }
  return derived;
}