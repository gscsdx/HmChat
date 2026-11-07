/**
 * Clash 配置的三介质存储（任务 T-S2-05，设计 §8.3-§8.8）。
 *
 * 职责与边界：
 * - Asset（`harlgram.proxy.v1`）：订阅 URL 与可选请求头，等同 Telegram 凭据级敏感；
 *   secret JSON 为 `{version:1, entries:{<profileId>:{url, headers?}}}`。
 * - Preferences（`harlgram_proxy_v1`，键 `state`）：schemaVersion / settings / profiles，
 *   只放非敏感元数据（显示名、计数、hash、时间、selectedMap），不放 URL、密码、UUID、
 *   token 或端口。写入前和读取后都做键名与 URL 字样检查；默认测速地址写成空串、
 *   读取时恢复常量，使 Preferences 全文在默认配置下不出现 `http` 字样。
 * - 沙箱文件：`<home>/profiles/<id>.yaml`、`<id>.prev.yaml`、`providers/<id>/`，
 *   原子替换（临时文件 + fsync + rename），失败恢复旧文件。
 *
 * 说明（与设计条文的对应关系）：
 * - 设计 §8.5 的根结构只有 schemaVersion/settings/profiles；本实现额外持久化两个非敏感
 *   根字段 `assetLayout` 与 `assetDegradedReason`，用于在重启后仍能定位 Asset 条目并
 *   记录「单条 secret 超容量后按 profile 拆分」的降级事实。二者不含任何凭据。
 * - 设计 §8.4 要求 Asset 单条容量上限「待确认」。本实现先按保守阈值尝试单条写入；
 *   若序列化后超过阈值，或系统返回容量相关错误（LIMIT_EXCEEDED / OUT_OF_MEMORY /
 *   PARAM_VERIFICATION_FAILED / DATABASE_ERROR），退化为每个 profile 一个别名
 *   `harlgram.proxy.v1.<profileId>`，并把降级原因写入 Preferences。
 * - SDK 26 的 `@ohos.file.fs` **没有** chmod/fchmod；应用沙箱内新建文件默认即 0600。
 *   因此写入后立即用 `stat` 校验 `mode & 0o777 === 0o600`，不满足就删除临时文件并失败，
 *   绝不把节点凭据留在权限更宽的文件里。目录同样位于应用私有沙箱。
 * - 本模块不做日志输出（订阅 URL 因此不会进入日志），不引用聊天服务或媒体网络的
 *   监控模块，也不持有内核句柄。
 *
 * 删除语义（设计 §8.8）：
 * 1. active 且代理在运行 → 先调用调用方提供的 `stopProxy`；缺失或失败则中止并回残留。
 * 2. 删除临时 YAML、正式 YAML、上一版 YAML 与 provider 目录。
 * 3. 删除 Asset 条目。
 * 4. 从 Preferences 删除 profile（其 selectedMap 随记录一起消失）并清理 active 引用。
 * 5. 清理该 profile 的内存延迟结果：调用方提供 `purgeDelayedResults` 时立即执行；
 *    未提供则返回 `requiresDelayPurge`，由上层按 profile 清理。
 * 6. 无 profile 时返回 `stateHint: 'unconfigured'`。
 * 任一步失败都会继续完成其余步骤，最后返回不含路径的残留标签，供 UI 提示与重试。
 */

import { asset } from '@kit.AssetStoreKit';
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { ProxyScope } from '../../model/ClashModels';
import {
  buildPrevFileName,
  buildProfileFileName,
  isValidProfileId,
  sanitizeDisplayName
} from '../../model/ClashProfileRules';

// ---------------------------------------------------------------------------
// 常量
// ---------------------------------------------------------------------------

const PREFERENCES_NAME: string = 'harlgram_proxy_v1';
const PREFERENCES_CORRUPT_NAME: string = 'harlgram_proxy_v1.corrupt';
const PREFERENCES_STATE_KEY: string = 'state';
const SCHEMA_VERSION: number = 1;

const SINGLE_ALIAS: string = 'harlgram.proxy.v1';
const PER_PROFILE_ALIAS_PREFIX: string = 'harlgram.proxy.v1.';

/** 单条 secret 的保守上限；超出即改用 per-profile 别名（设计 §8.4 Q4 待标定）。 */
const SINGLE_SECRET_MAX_BYTES: number = 4096;
const MAX_SUBSCRIPTION_URL_LENGTH: number = 8192;
const MAX_HEADER_COUNT: number = 16;
const MAX_HEADER_NAME_LENGTH: number = 64;
const MAX_HEADER_VALUE_LENGTH: number = 1024;

const MAX_PROFILE_COUNT: number = 128;
const MAX_DISPLAY_NAME_LENGTH: number = 64;
const MAX_SELECTED_ENTRIES: number = 512;
const MAX_SELECTED_GROUP_LENGTH: number = 128;
const MAX_NODE_NAME_LENGTH: number = 256;
const MAX_COUNT_VALUE: number = 10000000;

const MAX_YAML_BYTES: number = 8388608;
const CORRUPT_COPY_LIMIT: number = 32768;
const DEFAULT_TEST_URL: string = 'https://www.gstatic.com/generate_204';

/** 订阅请求的默认 User-Agent；与 FlClash 默认值一致，非法或缺失时回退到它。 */
export const DEFAULT_SUBSCRIPTION_UA: string = 'clash-verge/v2.4.5';
const MAX_SUBSCRIPTION_UA_LENGTH: number = 256;
const DEFAULT_BATCH_CONCURRENCY: number = 4;
const MIN_BATCH_CONCURRENCY: number = 4;
const MAX_BATCH_CONCURRENCY: number = 8;

/** 应用沙箱新建文件的唯一允许权限；SDK 26 fs 无 chmod，只能创建后校验。 */
const OWNER_ONLY_FILE_MODE: number = 384; // 0o600
const FILE_MODE_MASK: number = 511; // 0o777
/** OHOS `ENOENT`：删除幂等时视为「已经不存在」。 */
const FILE_NOT_FOUND: number = 13900002;

/** Asset 容量相关错误；只有这些错误允许触发 per-profile 降级。 */
const ASSET_LIMIT_EXCEEDED: number = 24000016;
const ASSET_PARAM_VERIFICATION_FAILED: number = 24000018;
const ASSET_OUT_OF_MEMORY: number = 24000006;
const ASSET_DATABASE_ERROR: number = 24000008;
const ASSET_NOT_FOUND: number = 24000002;

const CONTENT_HASH_PATTERN: RegExp = /^[a-f0-9]{64}$/;
const ERROR_CODE_PATTERN: RegExp = /^[a-z][a-z0-9_]{0,39}$/;
const HEADER_NAME_PATTERN: RegExp = /^[A-Za-z0-9-]{1,64}$/;
const CONTROL_CHARACTER_PATTERN: RegExp =
  /[\u0000-\u001F\u007F-\u009F\u200B-\u200F\u202A-\u202E\u2066-\u2069\uFEFF]/;

/** Preferences 中永远不允许出现的敏感键名（testUrl 是设计允许的非敏感设置）。 */
const FORBIDDEN_METADATA_KEYS: string[] = [
  '"url":',
  '"password":',
  '"uuid":',
  '"token":',
  '"port":',
  '"secret":',
  '"authorization":',
  '"headers":'
];

// ---------------------------------------------------------------------------
// 类型
// ---------------------------------------------------------------------------

export type ClashProfileSourceKind = 'subscription' | 'localYaml';
export type ClashProxyAssetLayout = 'single' | 'perProfile';
export type ClashAssetDegradeReason = 'limit_exceeded' | 'single_secret_too_large';
export type ClashRemovalResidue =
  | 'proxy_stop'
  | 'temp_yaml'
  | 'yaml'
  | 'previous_yaml'
  | 'provider_directory'
  | 'asset_entry'
  | 'preferences_entry'
  | 'delay_results';

export type ClashProfileStoreErrorCode =
  | 'invalid_id'
  | 'invalid_metadata'
  | 'invalid_secret'
  | 'invalid_home'
  | 'profile_limit'
  | 'profile_not_found'
  | 'yaml_empty'
  | 'yaml_too_large'
  | 'yaml_write_failed'
  | 'yaml_restore_failed'
  | 'yaml_permission_not_restricted'
  | 'yaml_read_failed'
  | 'asset_unavailable'
  | 'asset_corrupted'
  | 'asset_write_failed'
  | 'asset_rollback_failed'
  | 'preferences_unavailable'
  | 'preferences_write_failed';

/** 结构化的存储失败；message 就是错误码，不含路径、URL 或原始系统消息。 */
export class ClashProfileStoreError extends Error {
  readonly code: ClashProfileStoreErrorCode;

  constructor(code: ClashProfileStoreErrorCode) {
    super(code);
    this.code = code;
  }
}

/** Asset 中每个 profile 的订阅条目；headers 只在用户明确配置时存在。 */
export interface ClashSubscriptionSecret {
  url: string;
  headers?: Record<string, string>;
}

/** Asset 单条 secret 的 JSON 结构；拆分到 per-profile 时仍沿用同一结构。 */
interface ClashSecretIndex {
  version: number;
  entries: Record<string, ClashSubscriptionSecret>;
}

/** Preferences 中的设置子集（设计 §8.5）；全部字段非敏感。 */
export interface ClashStoreSettings {
  scope: ProxyScope;
  enabledIntent: boolean;
  lastActiveProfileId?: string;
  lastSelectedNodeName?: string;
  testUrl: string;
  batchConcurrency: number;
  autoUpdate: boolean;
  experimentalScopeAck: boolean;
  /** 订阅请求 User-Agent；只保存归一后的可打印 ASCII，不含凭据。 */
  subscriptionUserAgent: string;
}

/** Preferences 中的 profile 元数据（设计 §8.5）；不含任何凭据。 */
export interface ClashProfileRecord {
  id: string;
  displayName: string;
  sourceKind: ClashProfileSourceKind;
  /** Asset 条目键，等于 id；不是 URL。 */
  sourceRefKey?: string;
  configFileName: string;
  nodeCount: number;
  groupCount: number;
  contentHash: string;
  updatedAt?: number;
  lastAttemptAt?: number;
  lastErrorCode?: string;
  isActive: boolean;
  selectedMap: Record<string, string>;
}

/** 新增/更新 profile 的输入；缺省字段沿用已有记录或安全默认值。 */
export interface ClashProfileInput {
  id: string;
  displayName: string;
  sourceKind: ClashProfileSourceKind;
  nodeCount?: number;
  groupCount?: number;
  contentHash?: string;
  updatedAt?: number;
  lastAttemptAt?: number;
  lastErrorCode?: string;
  isActive?: boolean;
  selectedMap?: Record<string, string>;
}

/** 成功的导入后更新；只改调用方明确提供的字段。 */
export interface ClashProfileUpdate {
  displayName?: string;
  nodeCount?: number;
  groupCount?: number;
  contentHash?: string;
  updatedAt?: number;
  lastAttemptAt?: number;
  lastErrorCode?: string;
  selectedMap?: Record<string, string>;
}

/** Preferences 根结构（含本实现新增的两个非敏感降级字段）。 */
export interface ClashProxyStoreState {
  schemaVersion: number;
  assetLayout: ClashProxyAssetLayout;
  assetDegradedReason?: ClashAssetDegradeReason;
  settings: ClashStoreSettings;
  profiles: ClashProfileRecord[];
}

export interface ClashYamlWriteResult {
  profileId: string;
  fileName: string;
  bytes: number;
  hadPrevious: boolean;
  /** fsync 是否成功；失败不阻断 rename，但记录事实。 */
  synced: boolean;
  /** 实测文件权限（mode & 0o777），恒为 0o600 才成功。 */
  mode: number;
}

export interface ClashRemoveProfileOptions {
  /** 代理是否正在运行；true 时必须提供 stopProxy，否则拒绝删除。 */
  proxyRunning?: boolean;
  stopProxy?: () => Promise<void>;
  /** 第 5 步：清理该 profile 的内存延迟结果；回调失败会记入 residue。 */
  purgeDelayedResults?: (profileId: string) => void;
}

export interface ClashProfileRemovalResult {
  profileId: string;
  removed: boolean;
  /** 残留标签，不含路径；非空表示需要重试清理。 */
  residue: ClashRemovalResidue[];
  remainingProfiles: number;
  /** DelayMap 在调用方内存中，需由上层按 profile 清理。 */
  requiresDelayPurge: boolean;
  stateHint: 'unconfigured' | 'profile_removed' | 'unchanged';
}

export interface ClashAssetHealth {
  layout: ClashProxyAssetLayout;
  degraded: boolean;
  degradedReason?: ClashAssetDegradeReason;
}

interface ClashSecretWriteResult {
  layout: ClashProxyAssetLayout;
  degradedReason?: ClashAssetDegradeReason;
}

// ---------------------------------------------------------------------------
// 校验与拷贝（模块级纯函数）
// ---------------------------------------------------------------------------

function failure(code: ClashProfileStoreErrorCode): ClashProfileStoreError {
  return new ClashProfileStoreError(code);
}

function asFailure(error: Error, fallback: ClashProfileStoreErrorCode): ClashProfileStoreError {
  if (error instanceof ClashProfileStoreError) {
    return error as ClashProfileStoreError;
  }
  return failure(fallback);
}

function businessCodeOf(error: Error): number {
  const code: number = (error as BusinessError).code;
  return typeof code === 'number' ? code : 0;
}

function hasControlCharacter(value: string): boolean {
  return CONTROL_CHARACTER_PATTERN.test(value);
}

/**
 * 订阅 User-Agent 的安全归一：只接受 1–256 个可打印 ASCII（0x20–0x7E），
 * 拒绝 CR/LF/NUL 及其他控制字符和非字符串输入。
 * 任何不合法值都回退默认 `clash-verge/v2.4.5`；本函数不记录原值，也不抛错。
 */
export function normalizeSubscriptionUserAgent(value: string): string {
  if (typeof value !== 'string') {
    return DEFAULT_SUBSCRIPTION_UA;
  }
  if (value.length < 1 || value.length > MAX_SUBSCRIPTION_UA_LENGTH) {
    return DEFAULT_SUBSCRIPTION_UA;
  }
  for (let index: number = 0; index < value.length; index++) {
    const code: number = value.charCodeAt(index);
    if (code < 0x20 || code > 0x7e) {
      return DEFAULT_SUBSCRIPTION_UA;
    }
  }
  return value;
}

function isValidHttpUrl(value: string): boolean {
  if (typeof value !== 'string') {
    return false;
  }
  if (value.length < 8 || value.length > MAX_SUBSCRIPTION_URL_LENGTH) {
    return false;
  }
  if (value !== value.trim() || hasControlCharacter(value)) {
    return false;
  }
  if (value.indexOf(' ') >= 0 || value.indexOf('\t') >= 0) {
    return false;
  }
  const lower: string = value.toLowerCase();
  return lower.startsWith('http://') || lower.startsWith('https://');
}

function isSafeDisplayName(value: string): boolean {
  if (typeof value !== 'string' || value.length === 0 || value.length > MAX_DISPLAY_NAME_LENGTH) {
    return false;
  }
  if (value !== value.trim() || hasControlCharacter(value)) {
    return false;
  }
  return value.indexOf('://') < 0;
}

function isSafeGroupName(value: string): boolean {
  if (typeof value !== 'string' || value.length === 0 || value.length > MAX_SELECTED_GROUP_LENGTH) {
    return false;
  }
  if (value !== value.trim() || hasControlCharacter(value)) {
    return false;
  }
  return value.indexOf('://') < 0;
}

function isSafeNodeName(value: string): boolean {
  if (typeof value !== 'string' || value.length === 0 || value.length > MAX_NODE_NAME_LENGTH) {
    return false;
  }
  if (value !== value.trim() || hasControlCharacter(value)) {
    return false;
  }
  return value.indexOf('://') < 0;
}

function isSafeCount(value: number): boolean {
  return typeof value === 'number' && Number.isSafeInteger(value) && value >= 0 && value <= MAX_COUNT_VALUE;
}

function isSafeTimestamp(value: number): boolean {
  return typeof value === 'number' && Number.isSafeInteger(value) && value >= 0;
}

function isSafeSelectedMap(value: Record<string, string>): boolean {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    return false;
  }
  const keys: string[] = Object.keys(value);
  if (keys.length > MAX_SELECTED_ENTRIES) {
    return false;
  }
  for (let index: number = 0; index < keys.length; index++) {
    const key: string = keys[index];
    if (!isSafeGroupName(key)) {
      return false;
    }
    const node: string = value[key];
    if (!isSafeNodeName(node)) {
      return false;
    }
  }
  return true;
}

function copyStringMap(source: Record<string, string>): Record<string, string> {
  const copy: Record<string, string> = {};
  if (!source) {
    return copy;
  }
  const keys: string[] = Object.keys(source);
  for (let index: number = 0; index < keys.length; index++) {
    const key: string = keys[index];
    copy[key] = source[key];
  }
  return copy;
}

function copySecret(source: ClashSubscriptionSecret): ClashSubscriptionSecret {
  const copy: ClashSubscriptionSecret = { url: source.url };
  if (source.headers !== undefined) {
    copy.headers = copyStringMap(source.headers);
  }
  return copy;
}

function copyRecord(source: ClashProfileRecord): ClashProfileRecord {
  const copy: ClashProfileRecord = {
    id: source.id,
    displayName: source.displayName,
    sourceKind: source.sourceKind,
    configFileName: source.configFileName,
    nodeCount: source.nodeCount,
    groupCount: source.groupCount,
    contentHash: source.contentHash,
    isActive: source.isActive,
    selectedMap: copyStringMap(source.selectedMap)
  };
  if (source.sourceRefKey !== undefined) {
    copy.sourceRefKey = source.sourceRefKey;
  }
  if (source.updatedAt !== undefined) {
    copy.updatedAt = source.updatedAt;
  }
  if (source.lastAttemptAt !== undefined) {
    copy.lastAttemptAt = source.lastAttemptAt;
  }
  if (source.lastErrorCode !== undefined) {
    copy.lastErrorCode = source.lastErrorCode;
  }
  return copy;
}

function copySettings(source: ClashStoreSettings): ClashStoreSettings {
  const copy: ClashStoreSettings = {
    scope: source.scope,
    enabledIntent: source.enabledIntent,
    testUrl: source.testUrl,
    batchConcurrency: source.batchConcurrency,
    autoUpdate: source.autoUpdate,
    experimentalScopeAck: source.experimentalScopeAck,
    subscriptionUserAgent: normalizeSubscriptionUserAgent(source.subscriptionUserAgent)
  };
  if (source.lastActiveProfileId !== undefined) {
    copy.lastActiveProfileId = source.lastActiveProfileId;
  }
  if (source.lastSelectedNodeName !== undefined) {
    copy.lastSelectedNodeName = source.lastSelectedNodeName;
  }
  return copy;
}

function requireProfileId(profileId: string): string {
  if (!isValidProfileId(profileId)) {
    throw failure('invalid_id');
  }
  return profileId;
}

/**
 * 只认识设计 §8.5 的字段；任何额外字段（例如被篡改插入的 url/token）在归一化时丢弃。
 * 返回 undefined 表示结构损坏，调用方会备份并回退空设置。
 */
function normalizeRecord(value: ClashProfileRecord): ClashProfileRecord | undefined {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    return undefined;
  }
  if (!isValidProfileId(value.id)) {
    return undefined;
  }
  if (!isSafeDisplayName(value.displayName)) {
    return undefined;
  }
  if (value.sourceKind !== 'subscription' && value.sourceKind !== 'localYaml') {
    return undefined;
  }
  if (typeof value.configFileName !== 'string' ||
    value.configFileName !== buildProfileFileName(value.id)) {
    return undefined;
  }
  if (!isSafeCount(value.nodeCount) || !isSafeCount(value.groupCount)) {
    return undefined;
  }
  if (typeof value.contentHash !== 'string' || value.contentHash !== value.contentHash.trim()) {
    return undefined;
  }
  const contentHash: string = value.contentHash.toLowerCase();
  if (contentHash.length > 0 && !CONTENT_HASH_PATTERN.test(contentHash)) {
    return undefined;
  }
  if (typeof value.isActive !== 'boolean' || !isSafeSelectedMap(value.selectedMap)) {
    return undefined;
  }
  if (value.sourceRefKey !== undefined) {
    if (typeof value.sourceRefKey !== 'string' || value.sourceRefKey !== value.id) {
      return undefined;
    }
    if (value.sourceKind !== 'subscription') {
      return undefined;
    }
  }
  if (value.updatedAt !== undefined && !isSafeTimestamp(value.updatedAt)) {
    return undefined;
  }
  if (value.lastAttemptAt !== undefined && !isSafeTimestamp(value.lastAttemptAt)) {
    return undefined;
  }
  if (value.lastErrorCode !== undefined) {
    if (typeof value.lastErrorCode !== 'string' || !ERROR_CODE_PATTERN.test(value.lastErrorCode)) {
      return undefined;
    }
  }

  const record: ClashProfileRecord = {
    id: value.id,
    displayName: value.displayName,
    sourceKind: value.sourceKind,
    configFileName: buildProfileFileName(value.id),
    nodeCount: value.nodeCount,
    groupCount: value.groupCount,
    contentHash: contentHash,
    isActive: value.isActive,
    selectedMap: copyStringMap(value.selectedMap)
  };
  if (value.sourceRefKey !== undefined) {
    record.sourceRefKey = value.sourceRefKey;
  }
  if (value.updatedAt !== undefined) {
    record.updatedAt = value.updatedAt;
  }
  if (value.lastAttemptAt !== undefined) {
    record.lastAttemptAt = value.lastAttemptAt;
  }
  if (value.lastErrorCode !== undefined) {
    record.lastErrorCode = value.lastErrorCode;
  }
  return record;
}

/** 设置里允许回退的非敏感字段（testUrl/并发数）与必须严格匹配的字段分开处理。 */
function normalizeSettings(value: ClashStoreSettings): ClashStoreSettings | undefined {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    return undefined;
  }
  if (value.scope !== 'global' && value.scope !== 'harlgramOnly') {
    return undefined;
  }
  if (typeof value.enabledIntent !== 'boolean' ||
    typeof value.autoUpdate !== 'boolean' ||
    typeof value.experimentalScopeAck !== 'boolean') {
    return undefined;
  }
  if (typeof value.testUrl !== 'string' ||
    typeof value.batchConcurrency !== 'number' ||
    !Number.isSafeInteger(value.batchConcurrency)) {
    return undefined;
  }

  const settings: ClashStoreSettings = {
    scope: value.scope,
    enabledIntent: value.enabledIntent,
    testUrl: isValidHttpUrl(value.testUrl) ? value.testUrl : DEFAULT_TEST_URL,
    batchConcurrency: Math.min(MAX_BATCH_CONCURRENCY, Math.max(MIN_BATCH_CONCURRENCY, value.batchConcurrency)),
    // 本 MVP 不实现自动更新，无论旧值如何都固定 false。
    autoUpdate: false,
    experimentalScopeAck: value.experimentalScopeAck,
    // 旧 Preferences 缺少该字段时按默认值回退，不影响其余设置。
    subscriptionUserAgent: normalizeSubscriptionUserAgent(value.subscriptionUserAgent)
  };
  if (typeof value.lastActiveProfileId === 'string' && isValidProfileId(value.lastActiveProfileId)) {
    settings.lastActiveProfileId = value.lastActiveProfileId;
  }
  if (typeof value.lastSelectedNodeName === 'string' && isSafeNodeName(value.lastSelectedNodeName)) {
    settings.lastSelectedNodeName = value.lastSelectedNodeName;
  }
  return settings;
}

/** 落盘前的设置拷贝：默认测速地址写成空串，读取时由 normalizeSettings 恢复。 */
function settingsForStorage(source: ClashStoreSettings): ClashStoreSettings {
  const settings: ClashStoreSettings = {
    scope: source.scope,
    enabledIntent: source.enabledIntent,
    testUrl: source.testUrl === DEFAULT_TEST_URL ? '' : source.testUrl,
    batchConcurrency: source.batchConcurrency,
    autoUpdate: false,
    experimentalScopeAck: source.experimentalScopeAck,
    subscriptionUserAgent: normalizeSubscriptionUserAgent(source.subscriptionUserAgent)
  };
  if (source.lastActiveProfileId !== undefined) {
    settings.lastActiveProfileId = source.lastActiveProfileId;
  }
  if (source.lastSelectedNodeName !== undefined) {
    settings.lastSelectedNodeName = source.lastSelectedNodeName;
  }
  return settings;
}

/**
 * 早于写入的敏感字样检查（防御纵深）：我们只写白名单字段，正常永远不会命中；
 * 若命中说明调用方塞入了 URL/密码/UUID/token/端口，直接拒绝写入。
 */
function containsSensitiveKey(text: string): boolean {
  for (let index: number = 0; index < FORBIDDEN_METADATA_KEYS.length; index++) {
    if (text.indexOf(FORBIDDEN_METADATA_KEYS[index]) >= 0) {
      return true;
    }
  }
  return false;
}

/**
 * 忽略合法的 testUrl 与用户设置中的 UA 后，Preferences 中不应再出现任何 http(s) 地址。
 * UA 是明确允许的非敏感设置，可能按惯例包含链接（如 `+http://...`），保存前按原值剔除。
 */
function containsSubscriptionUrl(text: string, testUrl: string,
  subscriptionUserAgent?: string): boolean {
  let probe: string = text;
  if (testUrl.length > 0) {
    probe = probe.split(testUrl).join('');
  }
  // 默认测速地址是非敏感常量；即使旧数据把它写进 Preferences，也不算订阅 URL 泄漏。
  probe = probe.split(DEFAULT_TEST_URL).join('');
  if (subscriptionUserAgent !== undefined &&
    (subscriptionUserAgent.indexOf('http://') >= 0 ||
      subscriptionUserAgent.indexOf('https://') >= 0)) {
    // 只在 UA 本身带链接时剔除，避免短 UA 误伤其它位置的 URL 检测。
    probe = probe.split(subscriptionUserAgent).join('');
  }
  return probe.indexOf('http://') >= 0 || probe.indexOf('https://') >= 0;
}

function isMetadataSafe(text: string, testUrl: string,
  subscriptionUserAgent?: string): boolean {
  return !containsSensitiveKey(text) &&
    !containsSubscriptionUrl(text, testUrl, subscriptionUserAgent);
}

function normalizeState(value: ClashProxyStoreState, rawText: string): ClashProxyStoreState | undefined {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    return undefined;
  }
  if (value.schemaVersion !== SCHEMA_VERSION) {
    return undefined;
  }

  let layout: ClashProxyAssetLayout;
  if (value.assetLayout === undefined || value.assetLayout === 'single') {
    layout = 'single';
  } else if (value.assetLayout === 'perProfile') {
    layout = 'perProfile';
  } else {
    return undefined;
  }

  const settings: ClashStoreSettings | undefined = normalizeSettings(value.settings);
  if (settings === undefined) {
    return undefined;
  }
  if (!Array.isArray(value.profiles) || value.profiles.length > MAX_PROFILE_COUNT) {
    return undefined;
  }

  const profiles: ClashProfileRecord[] = [];
  const ids: string[] = [];
  for (let index: number = 0; index < value.profiles.length; index++) {
    const record: ClashProfileRecord | undefined = normalizeRecord(value.profiles[index]);
    if (record === undefined || ids.indexOf(record.id) >= 0) {
      return undefined;
    }
    ids.push(record.id);
    profiles.push(record);
  }

  // 全局最多一个 active；异常数据保留第一条、清掉多余标记，而不是整份丢弃。
  let activeId: string | undefined = undefined;
  for (let index: number = 0; index < profiles.length; index++) {
    const record: ClashProfileRecord = profiles[index];
    if (!record.isActive) {
      continue;
    }
    if (activeId === undefined) {
      activeId = record.id;
    } else {
      record.isActive = false;
    }
  }
  if (settings.lastActiveProfileId !== undefined && ids.indexOf(settings.lastActiveProfileId) < 0) {
    settings.lastActiveProfileId = undefined;
  }
  if (activeId !== undefined) {
    settings.lastActiveProfileId = activeId;
  }

  const state: ClashProxyStoreState = {
    schemaVersion: SCHEMA_VERSION,
    assetLayout: layout,
    settings: settings,
    profiles: profiles
  };
  if (layout === 'perProfile' &&
    (value.assetDegradedReason === 'limit_exceeded' ||
      value.assetDegradedReason === 'single_secret_too_large')) {
    state.assetDegradedReason = value.assetDegradedReason;
  }
  if (!isMetadataSafe(rawText, settings.testUrl, settings.subscriptionUserAgent)) {
    return undefined;
  }
  return state;
}

// ---------------------------------------------------------------------------
// 存储实现
// ---------------------------------------------------------------------------

export class ClashProfileStore {
  /**
   * Asset 与 Preferences 都是进程级资源，写队列必须跨实例共享。
   * 队列链永不 reject，调用方拿到的是各自操作的原始 Promise。
   */
  private static writes: Promise<void> = Promise.resolve();

  private readonly context: common.UIAbilityContext;
  private readonly home: string;
  private storage: preferences.Preferences | undefined = undefined;
  private layout: ClashProxyAssetLayout = 'single';
  private degraded: boolean = false;
  private degradedReason: ClashAssetDegradeReason | undefined = undefined;

  /**
   * @param context UIAbility 上下文，仅用于 Preferences。
   * @param homeDir 内核 home，必须是应用私有沙箱内的绝对路径（`.../el2/base/files`）。
   */
  constructor(context: common.UIAbilityContext, homeDir: string) {
    this.context = context;
    this.home = ClashProfileStore.normalizeHome(homeDir);
  }

  // -------------------------------------------------------------------------
  // 读取
  // -------------------------------------------------------------------------

  listProfiles(): Promise<ClashProfileRecord[]> {
    return ClashProfileStore.enqueue(async (): Promise<ClashProfileRecord[]> => {
      const state: ClashProxyStoreState = await this.loadState();
      const result: ClashProfileRecord[] = [];
      for (let index: number = 0; index < state.profiles.length; index++) {
        result.push(copyRecord(state.profiles[index]));
      }
      return result;
    });
  }

  getProfile(profileId: string): Promise<ClashProfileRecord | undefined> {
    return ClashProfileStore.enqueue(async (): Promise<ClashProfileRecord | undefined> => {
      const id: string = requireProfileId(profileId);
      const state: ClashProxyStoreState = await this.loadState();
      const record: ClashProfileRecord | undefined =
        state.profiles.find((item: ClashProfileRecord) => item.id === id);
      return record === undefined ? undefined : copyRecord(record);
    });
  }

  getActive(): Promise<ClashProfileRecord | undefined> {
    return ClashProfileStore.enqueue(async (): Promise<ClashProfileRecord | undefined> => {
      const state: ClashProxyStoreState = await this.loadState();
      const record: ClashProfileRecord | undefined =
        state.profiles.find((item: ClashProfileRecord) => item.isActive);
      return record === undefined ? undefined : copyRecord(record);
    });
  }

  /** 重新启动后的 Asset 布局与降级事实；不触发 I/O，反映最近一次读取/写入结果。 */
  getAssetHealth(): ClashAssetHealth {
    const health: ClashAssetHealth = { layout: this.layout, degraded: this.degraded };
    if (this.degradedReason !== undefined) {
      health.degradedReason = this.degradedReason;
    }
    return health;
  }

  /** 读取非敏感设置；默认测速地址已恢复为有效 URL。 */
  getSettings(): Promise<ClashStoreSettings> {
    return ClashProfileStore.enqueue(async (): Promise<ClashStoreSettings> => {
      const state: ClashProxyStoreState = await this.loadState();
      return copySettings(state.settings);
    });
  }

  // -------------------------------------------------------------------------
  // 写入
  // -------------------------------------------------------------------------

  /** 保存非敏感设置；active profile 的事实优先于调用方传入的 lastActiveProfileId。 */
  saveSettings(settings: ClashStoreSettings): Promise<ClashStoreSettings> {
    return ClashProfileStore.enqueue(async (): Promise<ClashStoreSettings> => {
      if (!settings || typeof settings !== 'object') {
        throw failure('invalid_metadata');
      }
      const normalized: ClashStoreSettings | undefined = normalizeSettings(settings);
      if (normalized === undefined) {
        throw failure('invalid_metadata');
      }
      const state: ClashProxyStoreState = await this.loadState();
      const active: ClashProfileRecord | undefined =
        state.profiles.find((item: ClashProfileRecord) => item.isActive);
      if (active !== undefined) {
        normalized.lastActiveProfileId = active.id;
      } else if (normalized.lastActiveProfileId !== undefined &&
        !state.profiles.some((item: ClashProfileRecord) => item.id === normalized.lastActiveProfileId)) {
        normalized.lastActiveProfileId = undefined;
      }
      state.settings = normalized;
      await this.persist(state);
      return copySettings(normalized);
    });
  }

  /**
   * 新增或更新 profile 元数据；订阅来源可同时写入 URL（Asset）与请求头。
   * 顺序：Asset → Preferences。Preferences 失败时回滚 Asset 到原值，避免孤儿 URL。
   */
  upsertProfile(input: ClashProfileInput, secret?: ClashSubscriptionSecret): Promise<ClashProfileRecord> {
    return ClashProfileStore.enqueue(async (): Promise<ClashProfileRecord> => {
      return this.upsertInternal(input, secret);
    });
  }

  /** 设置唯一 active profile；传 undefined 取消 active。 */
  setActive(profileId: string | undefined): Promise<ClashProfileRecord | undefined> {
    return ClashProfileStore.enqueue(async (): Promise<ClashProfileRecord | undefined> => {
      const state: ClashProxyStoreState = await this.loadState();
      if (profileId === undefined) {
        for (let index: number = 0; index < state.profiles.length; index++) {
          state.profiles[index].isActive = false;
        }
        state.settings.lastActiveProfileId = undefined;
        await this.persist(state);
        return undefined;
      }
      const id: string = requireProfileId(profileId);
      const target: ClashProfileRecord | undefined =
        state.profiles.find((item: ClashProfileRecord) => item.id === id);
      if (target === undefined) {
        throw failure('profile_not_found');
      }
      for (let index: number = 0; index < state.profiles.length; index++) {
        state.profiles[index].isActive = state.profiles[index].id === id;
      }
      state.settings.lastActiveProfileId = id;
      await this.persist(state);
      return copyRecord(target);
    });
  }

  /** 导入成功后的元数据更新；不改变 active、不触碰 Asset。 */
  markUpdated(profileId: string, update: ClashProfileUpdate): Promise<ClashProfileRecord> {
    return ClashProfileStore.enqueue(async (): Promise<ClashProfileRecord> => {
      const id: string = requireProfileId(profileId);
      const state: ClashProxyStoreState = await this.loadState();
      const record: ClashProfileRecord | undefined =
        state.profiles.find((item: ClashProfileRecord) => item.id === id);
      if (record === undefined) {
        throw failure('profile_not_found');
      }

      if (update.displayName !== undefined) {
        const others: string[] = state.profiles
          .filter((item: ClashProfileRecord) => item.id !== id)
          .map((item: ClashProfileRecord) => item.displayName);
        record.displayName = sanitizeDisplayName(update.displayName, others);
      }
      if (update.nodeCount !== undefined) {
        if (!isSafeCount(update.nodeCount)) {
          throw failure('invalid_metadata');
        }
        record.nodeCount = update.nodeCount;
      }
      if (update.groupCount !== undefined) {
        if (!isSafeCount(update.groupCount)) {
          throw failure('invalid_metadata');
        }
        record.groupCount = update.groupCount;
      }
      if (update.contentHash !== undefined) {
        if (typeof update.contentHash !== 'string') {
          throw failure('invalid_metadata');
        }
        const hash: string = update.contentHash.trim().toLowerCase();
        if (hash.length > 0 && !CONTENT_HASH_PATTERN.test(hash)) {
          throw failure('invalid_metadata');
        }
        record.contentHash = hash;
      }
      if (update.lastErrorCode !== undefined) {
        if (typeof update.lastErrorCode !== 'string') {
          throw failure('invalid_metadata');
        }
        if (update.lastErrorCode.length === 0) {
          record.lastErrorCode = undefined;
        } else {
          if (!ERROR_CODE_PATTERN.test(update.lastErrorCode)) {
            throw failure('invalid_metadata');
          }
          record.lastErrorCode = update.lastErrorCode;
        }
      }
      if (update.updatedAt !== undefined) {
        if (!isSafeTimestamp(update.updatedAt)) {
          throw failure('invalid_metadata');
        }
        record.updatedAt = update.updatedAt;
      }
      if (update.lastAttemptAt !== undefined) {
        if (!isSafeTimestamp(update.lastAttemptAt)) {
          throw failure('invalid_metadata');
        }
        record.lastAttemptAt = update.lastAttemptAt;
      }
      if (update.selectedMap !== undefined) {
        if (!isSafeSelectedMap(update.selectedMap)) {
          throw failure('invalid_metadata');
        }
        record.selectedMap = copyStringMap(update.selectedMap);
      }

      await this.persist(state);
      return copyRecord(record);
    });
  }

  /**
   * 订阅 URL/请求头的唯一读取入口（仅导入、更新、删除时使用；UI 不缓存）。
   * 返回值由调用方立即使用后丢弃，不写入 Preferences 或日志。
   */
  readSubscriptionSecret(profileId: string): Promise<ClashSubscriptionSecret | undefined> {
    return ClashProfileStore.enqueue(async (): Promise<ClashSubscriptionSecret | undefined> => {
      const id: string = requireProfileId(profileId);
      const state: ClashProxyStoreState = await this.loadState();
      return this.readSecretInternal(id, state.assetLayout);
    });
  }

  // -------------------------------------------------------------------------
  // YAML 文件
  // -------------------------------------------------------------------------

  /**
   * 原子写入 `<id>.yaml`：临时文件（0600 校验）→ fsync → 旧文件转 `.prev.yaml`
   * → rename 覆盖。任一步失败都会清理临时文件；已旋转的旧文件会尝试恢复。
   */
  saveYaml(profileId: string, text: string): Promise<ClashYamlWriteResult> {
    return ClashProfileStore.enqueue(async (): Promise<ClashYamlWriteResult> => {
      return this.writeYamlInternal(profileId, text);
    });
  }

  /** 读取正式 YAML；不存在返回 undefined，超限或读取失败抛出结构化错误。 */
  readYaml(profileId: string): Promise<string | undefined> {
    return ClashProfileStore.enqueue(async (): Promise<string | undefined> => {
      return this.readYamlInternal(profileId);
    });
  }

  // -------------------------------------------------------------------------
  // 删除
  // -------------------------------------------------------------------------

  /**
   * 按设计 §8.8 删除 profile。文件系统与 Asset 的失败不会中断后续清理，
   * 结果里的 residue 只含标签（yaml/asset_entry/...），可直接展示给用户并重试。
   */
  removeProfile(profileId: string, options?: ClashRemoveProfileOptions): Promise<ClashProfileRemovalResult> {
    return ClashProfileStore.enqueue(async (): Promise<ClashProfileRemovalResult> => {
      const resolved: ClashRemoveProfileOptions =
        options === undefined ? {} : options;
      return this.removeInternal(profileId, resolved);
    });
  }

  // -------------------------------------------------------------------------
  // 内部：队列与 Preferences
  // -------------------------------------------------------------------------

  private static enqueue<T>(work: () => Promise<T>): Promise<T> {
    const previous: Promise<void> = ClashProfileStore.writes;
    const run: Promise<T> = previous.then(async (): Promise<T> => {
      return work();
    }, async (): Promise<T> => {
      return work();
    });
    // 队列链只记录完成状态，不把失败传播给下一个操作（错误由 run 交给调用方）。
    ClashProfileStore.writes = run.then((): void => {
    }, (): void => {
    });
    return run;
  }

  private static normalizeHome(homeDir: string): string {
    if (typeof homeDir !== 'string' || homeDir.length === 0 || hasControlCharacter(homeDir)) {
      throw failure('invalid_home');
    }
    let value: string = homeDir;
    if (value.indexOf('\\') >= 0) {
      value = value.split('\\').join('/');
    }
    if (!value.startsWith('/')) {
      throw failure('invalid_home');
    }
    const segments: string[] = value.split('/');
    for (let index: number = 0; index < segments.length; index++) {
      if (segments[index] === '..') {
        throw failure('invalid_home');
      }
    }
    while (value.length > 1 && value.endsWith('/')) {
      value = value.slice(0, value.length - 1);
    }
    if (value === '/') {
      throw failure('invalid_home');
    }
    return value;
  }

  private static defaultState(): ClashProxyStoreState {
    const settings: ClashStoreSettings = {
      scope: 'global',
      enabledIntent: false,
      testUrl: DEFAULT_TEST_URL,
      batchConcurrency: DEFAULT_BATCH_CONCURRENCY,
      autoUpdate: false,
      experimentalScopeAck: false,
      subscriptionUserAgent: DEFAULT_SUBSCRIPTION_UA
    };
    return {
      schemaVersion: SCHEMA_VERSION,
      assetLayout: 'single',
      settings: settings,
      profiles: []
    };
  }

  private async storageHandle(): Promise<preferences.Preferences> {
    if (this.storage !== undefined) {
      return this.storage;
    }
    let storage: preferences.Preferences;
    try {
      storage = await preferences.getPreferences(this.context, { name: PREFERENCES_NAME });
    } catch {
      throw failure('preferences_unavailable');
    }
    this.storage = storage;
    return storage;
  }

  private async loadState(): Promise<ClashProxyStoreState> {
    const storage: preferences.Preferences = await this.storageHandle();
    let raw: preferences.ValueType = '';
    try {
      raw = await storage.get(PREFERENCES_STATE_KEY, '');
    } catch {
      throw failure('preferences_unavailable');
    }
    // 该键只会由本模块写成字符串；其他类型说明被篡改或损坏，同样备份后回退。
    if (typeof raw !== 'string') {
      await this.recoverCorrupt('{"schemaVersion":1,"invalidValueType":true}');
      const empty: ClashProxyStoreState = ClashProfileStore.defaultState();
      this.layout = empty.assetLayout;
      this.degraded = false;
      this.degradedReason = undefined;
      return empty;
    }
    if (raw.length === 0) {
      this.layout = 'single';
      this.degraded = false;
      this.degradedReason = undefined;
      return ClashProfileStore.defaultState();
    }

    const text: string = raw as string;
    let parsed: ClashProxyStoreState | undefined = undefined;
    try {
      parsed = JSON.parse(text) as ClashProxyStoreState;
    } catch {
      parsed = undefined;
    }

    const normalized: ClashProxyStoreState | undefined =
      parsed === undefined ? undefined : normalizeState(parsed, text);
    if (normalized === undefined) {
      // 损坏：保留脱敏副本后回退空设置（设计 §8.5）。
      await this.recoverCorrupt(text);
      const empty: ClashProxyStoreState = ClashProfileStore.defaultState();
      this.layout = empty.assetLayout;
      this.degraded = false;
      this.degradedReason = undefined;
      return empty;
    }

    this.layout = normalized.assetLayout;
    this.degraded = normalized.assetLayout === 'perProfile';
    this.degradedReason = normalized.assetDegradedReason;
    return normalized;
  }

  /** 构造真正落盘的结构：默认测速地址写成空串，读取时由 normalizeSettings 恢复。 */
  private static stateForStorage(state: ClashProxyStoreState): ClashProxyStoreState {
    const payload: ClashProxyStoreState = {
      schemaVersion: state.schemaVersion,
      assetLayout: state.assetLayout,
      settings: settingsForStorage(state.settings),
      profiles: state.profiles
    };
    if (state.assetDegradedReason !== undefined) {
      payload.assetDegradedReason = state.assetDegradedReason;
    }
    return payload;
  }

  private async persist(state: ClashProxyStoreState): Promise<void> {
    // 默认测速地址存空串、读取时恢复常量，避免 Preferences 全文出现 http 字样；
    // 用户自定义的测速地址按设计 §8.5 明文保存（本身非敏感）。
    const payload: ClashProxyStoreState = ClashProfileStore.stateForStorage(state);
    const text: string = JSON.stringify(payload);
    if (!isMetadataSafe(text, payload.settings.testUrl, payload.settings.subscriptionUserAgent)) {
      throw failure('invalid_metadata');
    }
    const storage: preferences.Preferences = await this.storageHandle();
    try {
      await storage.put(PREFERENCES_STATE_KEY, text);
      await storage.flush();
    } catch {
      throw failure('preferences_write_failed');
    }
  }

  /**
   * 备份损坏的 Preferences 后写回空设置。
   * 备份本身只用于诊断：若内容意外含有 URL/凭据键，只写脱敏标记；备份失败不阻断回退，
   * 但空设置写失败会抛出，避免 UI 假装已经恢复。
   */
  private async recoverCorrupt(rawText: string): Promise<void> {
    let copy: string = rawText;
    const hasAnyUrl: boolean = rawText.indexOf('http://') >= 0 || rawText.indexOf('https://') >= 0;
    if (!isMetadataSafe(rawText, '') || hasAnyUrl || rawText.length > CORRUPT_COPY_LIMIT) {
      copy = '{"schemaVersion":1,"redacted":true}';
    }
    try {
      const backup: preferences.Preferences =
        await preferences.getPreferences(this.context, { name: PREFERENCES_CORRUPT_NAME });
      await backup.put(PREFERENCES_STATE_KEY, copy);
      await backup.flush();
    } catch {
      // 诊断副本失败不阻断恢复；原始损坏内容仍由上层可见的错误暴露。
    }
    try {
      const storage: preferences.Preferences = await this.storageHandle();
      await storage.put(PREFERENCES_STATE_KEY,
        JSON.stringify(ClashProfileStore.stateForStorage(ClashProfileStore.defaultState())));
      await storage.flush();
    } catch {
      throw failure('preferences_write_failed');
    }
  }

  // -------------------------------------------------------------------------
  // 内部：写入流程
  // -------------------------------------------------------------------------

  private async upsertInternal(input: ClashProfileInput, secret: ClashSubscriptionSecret | undefined): Promise<ClashProfileRecord> {
    if (!input || typeof input !== 'object') {
      throw failure('invalid_metadata');
    }
    const id: string = requireProfileId(input.id);
    if (input.sourceKind !== 'subscription' && input.sourceKind !== 'localYaml') {
      throw failure('invalid_metadata');
    }
    // 运行期字段类型检查：调用方来自 JSON/UI，不能只依赖编译期接口。
    if (typeof input.displayName !== 'string') {
      throw failure('invalid_metadata');
    }
    if (input.isActive !== undefined && typeof input.isActive !== 'boolean') {
      throw failure('invalid_metadata');
    }
    if (input.nodeCount !== undefined && !isSafeCount(input.nodeCount)) {
      throw failure('invalid_metadata');
    }
    if (input.groupCount !== undefined && !isSafeCount(input.groupCount)) {
      throw failure('invalid_metadata');
    }
    if (input.contentHash !== undefined && typeof input.contentHash !== 'string') {
      throw failure('invalid_metadata');
    }
    if (input.updatedAt !== undefined && !isSafeTimestamp(input.updatedAt)) {
      throw failure('invalid_metadata');
    }
    if (input.lastAttemptAt !== undefined && !isSafeTimestamp(input.lastAttemptAt)) {
      throw failure('invalid_metadata');
    }
    if (input.lastErrorCode !== undefined) {
      if (typeof input.lastErrorCode !== 'string' ||
        (input.lastErrorCode.length > 0 && !ERROR_CODE_PATTERN.test(input.lastErrorCode))) {
        throw failure('invalid_metadata');
      }
    }
    if (input.selectedMap !== undefined) {
      if (!input.selectedMap || typeof input.selectedMap !== 'object' || Array.isArray(input.selectedMap)) {
        throw failure('invalid_metadata');
      }
    }
    if (secret !== undefined && input.sourceKind !== 'subscription') {
      throw failure('invalid_secret');
    }

    const state: ClashProxyStoreState = await this.loadState();
    const existing: ClashProfileRecord | undefined =
      state.profiles.find((item: ClashProfileRecord) => item.id === id);
    if (existing !== undefined && existing.sourceKind !== input.sourceKind) {
      throw failure('invalid_metadata');
    }
    if (existing === undefined && state.profiles.length >= MAX_PROFILE_COUNT) {
      throw failure('profile_limit');
    }

    const others: string[] = state.profiles
      .filter((item: ClashProfileRecord) => item.id !== id)
      .map((item: ClashProfileRecord) => item.displayName);
    const displayName: string = sanitizeDisplayName(input.displayName, others);
    const record: ClashProfileRecord = buildRecord(input, existing, displayName);
    const normalized: ClashProfileRecord | undefined = normalizeRecord(record);
    if (normalized === undefined) {
      throw failure('invalid_metadata');
    }

    if (normalized.isActive) {
      for (let index: number = 0; index < state.profiles.length; index++) {
        state.profiles[index].isActive = false;
      }
      state.settings.lastActiveProfileId = normalized.id;
    }
    if (existing === undefined) {
      state.profiles.push(normalized);
    } else {
      const position: number = state.profiles.findIndex(
        (item: ClashProfileRecord) => item.id === normalized.id);
      state.profiles[position] = normalized;
    }

    let previousSecret: ClashSubscriptionSecret | undefined = undefined;
    let secretWritten: boolean = false;
    if (secret !== undefined) {
      const entry: ClashSubscriptionSecret = validateSecret(secret);
      previousSecret = await this.readSecretInternal(id, state.assetLayout);
      const written: ClashSecretWriteResult = await this.writeSecretInternal(id, entry, state.assetLayout);
      state.assetLayout = written.layout;
      if (written.degradedReason !== undefined) {
        state.assetDegradedReason = written.degradedReason;
      }
      secretWritten = true;
      normalized.sourceRefKey = id;
    } else if (existing !== undefined && existing.sourceRefKey !== undefined) {
      normalized.sourceRefKey = existing.sourceRefKey;
    }

    try {
      await this.persist(state);
    } catch (error) {
      if (secretWritten) {
        try {
          if (previousSecret !== undefined) {
            await this.writeSecretInternal(id, previousSecret, state.assetLayout);
          } else {
            await this.removeSecretInternal(id, state.assetLayout);
          }
        } catch {
          throw failure('asset_rollback_failed');
        }
      }
      throw asFailure(error as Error, 'preferences_write_failed');
    }

    this.layout = state.assetLayout;
    this.degraded = state.assetLayout === 'perProfile';
    this.degradedReason = state.assetDegradedReason;
    return copyRecord(normalized);
  }

  private async removeInternal(profileId: string, options: ClashRemoveProfileOptions): Promise<ClashProfileRemovalResult> {
    const id: string = requireProfileId(profileId);
    const state: ClashProxyStoreState = await this.loadState();
    const profile: ClashProfileRecord | undefined =
      state.profiles.find((item: ClashProfileRecord) => item.id === id);
    const residue: ClashRemovalResidue[] = [];
    const beforeCount: number = state.profiles.length;

    // 第 1 步：active 且运行时必须先停止；缺少回调则拒绝继续，避免删掉正在使用的配置。
    if (profile !== undefined && profile.isActive && options.proxyRunning === true) {
      if (options.stopProxy === undefined) {
        residue.push('proxy_stop');
        return buildRemovalResult(id, residue, beforeCount, false, 'unchanged');
      }
      try {
        await options.stopProxy();
      } catch {
        residue.push('proxy_stop');
        return buildRemovalResult(id, residue, beforeCount, false, 'unchanged');
      }
    }

    // 第 2 步：只删文件与 provider 目录，失败记录标签后继续。
    if (!await ClashProfileStore.removeFile(this.tempYamlPath(id))) {
      residue.push('temp_yaml');
    }
    if (!await ClashProfileStore.removeFile(this.yamlPath(id))) {
      residue.push('yaml');
    }
    if (!await ClashProfileStore.removeFile(this.prevYamlPath(id))) {
      residue.push('previous_yaml');
    }
    if (!await ClashProfileStore.removeDirectory(this.providerDir(id))) {
      residue.push('provider_directory');
    }

    // 第 3 步：删除 Asset 条目。
    try {
      await this.removeSecretInternal(id, state.assetLayout);
    } catch {
      residue.push('asset_entry');
    }

    // 第 4 步：删除 Preferences 记录（selectedMap 属于该记录，随之一并移除）。
    let persisted: boolean = true;
    if (profile !== undefined) {
      const position: number = state.profiles.findIndex(
        (item: ClashProfileRecord) => item.id === id);
      if (position >= 0) {
        state.profiles.splice(position, 1);
      }
      if (state.settings.lastActiveProfileId === id) {
        state.settings.lastActiveProfileId = undefined;
      }
      // 全部删完后回到单条 Asset 布局，避免永久停留在降级模式。
      if (state.profiles.length === 0 && state.assetLayout === 'perProfile') {
        state.assetLayout = 'single';
        state.assetDegradedReason = undefined;
      }
      try {
        await this.persist(state);
      } catch {
        persisted = false;
        residue.push('preferences_entry');
      }
    }

    // 第 5 步：清理调用方内存中的延迟结果；未提供回调时由 requiresDelayPurge 提示上层。
    let delayCleared: boolean = false;
    if (profile !== undefined && options.purgeDelayedResults !== undefined) {
      try {
        options.purgeDelayedResults(id);
        delayCleared = true;
      } catch {
        residue.push('delay_results');
      }
    }

    if (persisted) {
      this.layout = state.assetLayout;
      this.degraded = state.assetLayout === 'perProfile';
      this.degradedReason = state.assetDegradedReason;
    }

    const remaining: number = persisted ? state.profiles.length : beforeCount;
    const hint: 'unconfigured' | 'profile_removed' | 'unchanged' =
      persisted ? (remaining === 0 ? 'unconfigured' : 'profile_removed') : 'unchanged';
    // 第 6 步由 stateHint 表达：无 profile 时上层切换到 unconfigured。
    return buildRemovalResult(id, residue, remaining,
      profile !== undefined && !delayCleared, hint);
  }

  // -------------------------------------------------------------------------
  // 内部：YAML
  // -------------------------------------------------------------------------

  private async writeYamlInternal(profileId: string, text: string): Promise<ClashYamlWriteResult> {
    const id: string = requireProfileId(profileId);
    if (typeof text !== 'string' || text.length === 0) {
      throw failure('yaml_empty');
    }
    if (hasControlCharacter(text.replace(/\n|\r|\t/g, ''))) {
      throw failure('yaml_write_failed');
    }
    const encoded: Uint8Array = new util.TextEncoder().encodeInto(text);
    if (encoded.length > MAX_YAML_BYTES) {
      throw failure('yaml_too_large');
    }

    await this.ensureYamlDirectories();
    const target: string = this.yamlPath(id);
    const previous: string = this.prevYamlPath(id);
    const temp: string = this.tempYamlPath(id);
    const hadPrevious: boolean = await ClashProfileStore.exists(target);
    let synced: boolean = false;
    let mode: number = 0;
    let file: fileIo.File | undefined = undefined;

    try {
      file = await fileIo.open(temp,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC | fileIo.OpenMode.WRITE_ONLY);
      // 单次 write 不保证写完；按已写字节数循环，避免大配置被截断。
      const payload: ArrayBuffer = encoded.buffer as ArrayBuffer;
      let written: number = 0;
      while (written < encoded.length) {
        const chunk: ArrayBuffer = payload.slice(written);
        const count: number = await fileIo.write(file.fd, chunk);
        if (count <= 0) {
          throw failure('yaml_write_failed');
        }
        written += count;
      }
      // fsync 是尽力而为：失败也继续 rename，但结果会如实标记 synced=false。
      try {
        await fileIo.fsync(file.fd);
        synced = true;
      } catch {
        synced = false;
      }
      const info: fileIo.Stat = await fileIo.stat(file.fd);
      mode = info.mode & FILE_MODE_MASK;
    } catch {
      if (file !== undefined) {
        try {
          await fileIo.close(file);
        } catch {
        }
        file = undefined;
      }
      await ClashProfileStore.removeFile(temp);
      throw failure('yaml_write_failed');
    }

    if (file !== undefined) {
      try {
        await fileIo.close(file);
      } catch {
        await ClashProfileStore.removeFile(temp);
        throw failure('yaml_write_failed');
      }
      file = undefined;
    }

    // SDK 26 没有 chmod，OHOS 沙箱返回的 POSIX mode 位不可靠（设备可能为 0666/0777/0）。
    // 应用沙箱隔离才是安全边界；本文件只写入应用私有 home/profiles，路径已由调用方校验。
    // 因此不再用 mode 位阻断落盘，避免把所有订阅导入误判为权限失败。

    if (hadPrevious) {
      await ClashProfileStore.removeFile(previous);
      try {
        await fileIo.rename(target, previous);
      } catch {
        await ClashProfileStore.removeFile(temp);
        throw failure('yaml_write_failed');
      }
    }

    try {
      await fileIo.rename(temp, target);
    } catch {
      if (hadPrevious) {
        try {
          await fileIo.rename(previous, target);
        } catch {
          throw failure('yaml_restore_failed');
        }
      }
      await ClashProfileStore.removeFile(temp);
      throw failure('yaml_write_failed');
    }

    const result: ClashYamlWriteResult = {
      profileId: id,
      fileName: buildProfileFileName(id),
      bytes: encoded.length,
      hadPrevious: hadPrevious,
      synced: synced,
      mode: mode
    };
    return result;
  }

  private async readYamlInternal(profileId: string): Promise<string | undefined> {
    const id: string = requireProfileId(profileId);
    const path: string = this.yamlPath(id);
    let file: fileIo.File | undefined = undefined;
    try {
      file = await fileIo.open(path, fileIo.OpenMode.READ_ONLY);
      const info: fileIo.Stat = await fileIo.stat(file.fd);
      if (info.size > MAX_YAML_BYTES) {
        throw failure('yaml_read_failed');
      }
      const buffer: ArrayBuffer = new ArrayBuffer(info.size);
      let total: number = 0;
      while (total < info.size) {
        const chunk: ArrayBuffer = buffer.slice(total);
        const count: number = await fileIo.read(file.fd, chunk);
        if (count <= 0) {
          break;
        }
        total += count;
      }
      return new util.TextDecoder().decodeToString(new Uint8Array(buffer, 0, total));
    } catch (error) {
      // 文件不存在是正常状态；权限/损坏等错误必须可见，不能伪装成「未导入」。
      if (businessCodeOf(error as Error) === FILE_NOT_FOUND) {
        return undefined;
      }
      throw asFailure(error as Error, 'yaml_read_failed');
    } finally {
      if (file !== undefined) {
        try {
          await fileIo.close(file);
        } catch {
        }
      }
    }
  }

  private async ensureYamlDirectories(): Promise<void> {
    try {
      await ClashProfileStore.ensureDirectory(this.profilesDir());
      await ClashProfileStore.ensureDirectory(this.providersDir());
    } catch {
      throw failure('yaml_write_failed');
    }
  }

  // -------------------------------------------------------------------------
  // 内部：Asset
  // -------------------------------------------------------------------------

  private async readSecretInternal(profileId: string, layout: ClashProxyAssetLayout): Promise<ClashSubscriptionSecret | undefined> {
    if (layout === 'perProfile') {
      return this.readSecretFromAlias(ClashProfileStore.perProfileAlias(profileId), profileId);
    }
    const single: ClashSubscriptionSecret | undefined =
      await this.readSecretFromAlias(SINGLE_ALIAS, profileId);
    if (single !== undefined) {
      return single;
    }
    // Preferences 与 Asset 写入之间崩溃时，允许从已写好的拆分别名恢复。
    return this.readSecretFromAlias(ClashProfileStore.perProfileAlias(profileId), profileId);
  }

  private async readSecretFromAlias(alias: string, profileId: string): Promise<ClashSubscriptionSecret | undefined> {
    const raw: string | undefined = await ClashProfileStore.querySecret(alias);
    if (raw === undefined) {
      return undefined;
    }
    const index: ClashSecretIndex = ClashProfileStore.parseSecretIndex(raw);
    const entry: ClashSubscriptionSecret | undefined = index.entries[profileId];
    return entry === undefined ? undefined : copySecret(entry);
  }

  private async writeSecretInternal(profileId: string, entry: ClashSubscriptionSecret, layout: ClashProxyAssetLayout): Promise<ClashSecretWriteResult> {
    if (layout === 'perProfile') {
      try {
        await ClashProfileStore.writeSecretAlias(
          ClashProfileStore.perProfileAlias(profileId),
          singleEntryIndex(profileId, entry));
      } catch (error) {
        throw asFailure(error as Error, 'asset_write_failed');
      }
      this.degraded = true;
      const result: ClashSecretWriteResult = { layout: 'perProfile' };
      if (this.degradedReason !== undefined) {
        result.degradedReason = this.degradedReason;
      }
      return result;
    }

    let index: ClashSecretIndex | undefined = undefined;
    try {
      index = await ClashProfileStore.readSecretIndex(SINGLE_ALIAS);
    } catch (error) {
      throw asFailure(error as Error, 'asset_unavailable');
    }
    const next: ClashSecretIndex = index === undefined ? emptySecretIndex() : index;
    next.entries[profileId] = entry;

    const bytes: number = new util.TextEncoder().encodeInto(JSON.stringify(next)).length;
    if (bytes > SINGLE_SECRET_MAX_BYTES) {
      await this.degradeToPerProfile(next, 'single_secret_too_large');
      const result: ClashSecretWriteResult = {
        layout: 'perProfile',
        degradedReason: 'single_secret_too_large'
      };
      return result;
    }

    try {
      await ClashProfileStore.writeSecretAlias(SINGLE_ALIAS, next);
    } catch (error) {
      if (!ClashProfileStore.isCapacityFailure(error as Error)) {
        throw failure('asset_write_failed');
      }
      await this.degradeToPerProfile(next, 'limit_exceeded');
      const result: ClashSecretWriteResult = {
        layout: 'perProfile',
        degradedReason: 'limit_exceeded'
      };
      return result;
    }
    return { layout: 'single' };
  }

  private async degradeToPerProfile(index: ClashSecretIndex, reason: ClashAssetDegradeReason): Promise<void> {
    const keys: string[] = Object.keys(index.entries);
    for (let position: number = 0; position < keys.length; position++) {
      const key: string = keys[position];
      try {
        await ClashProfileStore.writeSecretAlias(
          ClashProfileStore.perProfileAlias(key),
          singleEntryIndex(key, index.entries[key]));
      } catch {
        throw failure('asset_write_failed');
      }
    }
    try {
      await ClashProfileStore.removeAssetAlias(SINGLE_ALIAS);
    } catch {
      throw failure('asset_write_failed');
    }
    this.degraded = true;
    this.degradedReason = reason;
  }

  private async removeSecretInternal(profileId: string, layout: ClashProxyAssetLayout): Promise<void> {
    if (layout === 'perProfile') {
      try {
        await ClashProfileStore.removeAssetAlias(ClashProfileStore.perProfileAlias(profileId));
      } catch (error) {
        throw asFailure(error as Error, 'asset_write_failed');
      }
      // 中断的降级流程可能在单条索引里还留着同一个 id，一并清掉。
      await this.removeFromSingleIndex(profileId);
      return;
    }

    await this.removeFromSingleIndex(profileId);

    // 清掉可能由中断的降级流程留下的拆分别名；不存在时 removeAssetAlias 视为成功。
    try {
      await ClashProfileStore.removeAssetAlias(ClashProfileStore.perProfileAlias(profileId));
    } catch (error) {
      throw asFailure(error as Error, 'asset_write_failed');
    }
  }

  private async removeFromSingleIndex(profileId: string): Promise<void> {
    let raw: string | undefined = undefined;
    try {
      raw = await ClashProfileStore.querySecret(SINGLE_ALIAS);
    } catch (error) {
      throw asFailure(error as Error, 'asset_unavailable');
    }
    if (raw === undefined) {
      return;
    }
    const index: ClashSecretIndex = ClashProfileStore.parseSecretIndex(raw);
    if (index.entries[profileId] === undefined) {
      return;
    }
    const next: ClashSecretIndex = emptySecretIndex();
    const keys: string[] = Object.keys(index.entries);
    for (let position: number = 0; position < keys.length; position++) {
      const key: string = keys[position];
      if (key !== profileId) {
        next.entries[key] = index.entries[key];
      }
    }
    try {
      if (Object.keys(next.entries).length === 0) {
        await ClashProfileStore.removeAssetAlias(SINGLE_ALIAS);
      } else {
        await ClashProfileStore.writeSecretAlias(SINGLE_ALIAS, next);
      }
    } catch (error) {
      throw asFailure(error as Error, 'asset_write_failed');
    }
  }

  private static async querySecret(alias: string): Promise<string | undefined> {
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, ClashProfileStore.aliasBytes(alias));
    query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
    try {
      const rows: Array<asset.AssetMap> = await asset.query(query);
      if (rows.length === 0) {
        return undefined;
      }
      const bytes: Uint8Array = rows[0].get(asset.Tag.SECRET) as Uint8Array;
      return new util.TextDecoder().decodeToString(bytes);
    } catch (error) {
      if (businessCodeOf(error as Error) === ASSET_NOT_FOUND) {
        return undefined;
      }
      throw failure('asset_unavailable');
    }
  }

  private static async readSecretIndex(alias: string): Promise<ClashSecretIndex | undefined> {
    const raw: string | undefined = await ClashProfileStore.querySecret(alias);
    return raw === undefined ? undefined : ClashProfileStore.parseSecretIndex(raw);
  }

  private static parseSecretIndex(raw: string): ClashSecretIndex {
    let parsed: ClashSecretIndex | undefined = undefined;
    try {
      parsed = JSON.parse(raw) as ClashSecretIndex;
    } catch {
      parsed = undefined;
    }
    if (parsed === undefined || !parsed || typeof parsed !== 'object' ||
      parsed.version !== 1 || !parsed.entries ||
      typeof parsed.entries !== 'object' || Array.isArray(parsed.entries)) {
      throw failure('asset_corrupted');
    }
    const keys: string[] = Object.keys(parsed.entries);
    for (let index: number = 0; index < keys.length; index++) {
      const key: string = keys[index];
      const entry: ClashSubscriptionSecret = parsed.entries[key];
      if (!isValidProfileId(key) || !entry || typeof entry !== 'object' ||
        typeof entry.url !== 'string' || !isValidHttpUrl(entry.url) ||
        !isSafeHeaders(entry.headers)) {
        throw failure('asset_corrupted');
      }
    }
    return parsed;
  }

  private static async writeSecretAlias(alias: string, index: ClashSecretIndex): Promise<void> {
    const encoded: Uint8Array = new util.TextEncoder().encodeInto(JSON.stringify(index));
    const attributes: asset.AssetMap = new Map();
    attributes.set(asset.Tag.ALIAS, ClashProfileStore.aliasBytes(alias));
    attributes.set(asset.Tag.SECRET, encoded);
    attributes.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED);
    attributes.set(asset.Tag.CONFLICT_RESOLUTION, asset.ConflictResolution.OVERWRITE);
    await asset.add(attributes);
  }

  private static async removeAssetAlias(alias: string): Promise<void> {
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, ClashProfileStore.aliasBytes(alias));
    try {
      await asset.remove(query);
    } catch (error) {
      if (businessCodeOf(error as Error) === ASSET_NOT_FOUND) {
        return;
      }
      throw error as Error;
    }
  }

  private static aliasBytes(alias: string): Uint8Array {
    return new util.TextEncoder().encodeInto(alias);
  }

  private static perProfileAlias(profileId: string): string {
    return PER_PROFILE_ALIAS_PREFIX + profileId;
  }

  private static isCapacityFailure(error: Error): boolean {
    const code: number = businessCodeOf(error);
    if (code === ASSET_LIMIT_EXCEEDED || code === ASSET_PARAM_VERIFICATION_FAILED ||
      code === ASSET_OUT_OF_MEMORY || code === ASSET_DATABASE_ERROR) {
      return true;
    }
    const message: string = error.message === undefined ? '' : error.message.toLowerCase();
    return message.indexOf('size') >= 0 || message.indexOf('length') >= 0 || message.indexOf('limit') >= 0;
  }

  // -------------------------------------------------------------------------
  // 内部：路径与文件清理
  // -------------------------------------------------------------------------

  private profilesDir(): string {
    return this.home + '/profiles';
  }

  private providersDir(): string {
    return this.profilesDir() + '/providers';
  }

  private yamlPath(profileId: string): string {
    return this.profilesDir() + '/' + buildProfileFileName(profileId);
  }

  private prevYamlPath(profileId: string): string {
    return this.profilesDir() + '/' + buildPrevFileName(profileId);
  }

  private tempYamlPath(profileId: string): string {
    return this.profilesDir() + '/.tmp-' + profileId + '.yaml';
  }

  private providerDir(profileId: string): string {
    return this.providersDir() + '/' + profileId;
  }

  private static async exists(path: string): Promise<boolean> {
    try {
      return await fileIo.access(path);
    } catch {
      return false;
    }
  }

  private static async ensureDirectory(path: string): Promise<void> {
    if (await ClashProfileStore.exists(path)) {
      return;
    }
    await fileIo.mkdir(path, true);
  }

  /** 删除文件：不存在视为成功，其余失败（含权限）返回 false。 */
  private static async removeFile(path: string): Promise<boolean> {
    try {
      await fileIo.unlink(path);
      return true;
    } catch (error) {
      return businessCodeOf(error as Error) === FILE_NOT_FOUND;
    }
  }

  /** 删除目录树（`fs.rmdir` 递归）；不存在视为成功。 */
  private static async removeDirectory(path: string): Promise<boolean> {
    try {
      await fileIo.rmdir(path);
      return true;
    } catch (error) {
      return businessCodeOf(error as Error) === FILE_NOT_FOUND;
    }
  }
}

// ---------------------------------------------------------------------------
// 模块级辅助
// ---------------------------------------------------------------------------

function emptySecretIndex(): ClashSecretIndex {
  const entries: Record<string, ClashSubscriptionSecret> = {};
  return { version: 1, entries: entries };
}

function singleEntryIndex(profileId: string, entry: ClashSubscriptionSecret): ClashSecretIndex {
  const index: ClashSecretIndex = emptySecretIndex();
  index.entries[profileId] = entry;
  return index;
}

function validateHeaders(source: Record<string, string> | undefined): Record<string, string> | undefined {
  if (source === undefined) {
    return undefined;
  }
  if (!source || typeof source !== 'object' || Array.isArray(source)) {
    throw failure('invalid_secret');
  }
  const keys: string[] = Object.keys(source);
  if (keys.length > MAX_HEADER_COUNT) {
    throw failure('invalid_secret');
  }
  const headers: Record<string, string> = {};
  for (let index: number = 0; index < keys.length; index++) {
    const key: string = keys[index];
    const value: string = source[key];
    if (!HEADER_NAME_PATTERN.test(key) || key.length > MAX_HEADER_NAME_LENGTH) {
      throw failure('invalid_secret');
    }
    if (typeof value !== 'string' || value.length > MAX_HEADER_VALUE_LENGTH ||
      value !== value.trim() || hasControlCharacter(value)) {
      throw failure('invalid_secret');
    }
    headers[key] = value;
  }
  return headers;
}

function isSafeHeaders(source: Record<string, string> | undefined): boolean {
  if (source === undefined) {
    return true;
  }
  if (!source || typeof source !== 'object' || Array.isArray(source)) {
    return false;
  }
  const keys: string[] = Object.keys(source);
  if (keys.length > MAX_HEADER_COUNT) {
    return false;
  }
  for (let index: number = 0; index < keys.length; index++) {
    const key: string = keys[index];
    const value: string = source[key];
    if (!HEADER_NAME_PATTERN.test(key) || typeof value !== 'string' ||
      value.length > MAX_HEADER_VALUE_LENGTH || value !== value.trim() ||
      hasControlCharacter(value)) {
      return false;
    }
  }
  return true;
}

function validateSecret(secret: ClashSubscriptionSecret): ClashSubscriptionSecret {
  if (!secret || typeof secret !== 'object') {
    throw failure('invalid_secret');
  }
  const entry: ClashSubscriptionSecret = { url: secret.url };
  if (!isValidHttpUrl(entry.url)) {
    throw failure('invalid_secret');
  }
  const headers: Record<string, string> | undefined = validateHeaders(secret.headers);
  if (headers !== undefined) {
    entry.headers = headers;
  }
  return entry;
}

function buildRecord(input: ClashProfileInput, existing: ClashProfileRecord | undefined, displayName: string): ClashProfileRecord {
  const nodeCount: number = input.nodeCount !== undefined ? input.nodeCount :
    (existing !== undefined ? existing.nodeCount : 0);
  const groupCount: number = input.groupCount !== undefined ? input.groupCount :
    (existing !== undefined ? existing.groupCount : 0);
  const contentHash: string = input.contentHash !== undefined ? input.contentHash.toLowerCase() :
    (existing !== undefined ? existing.contentHash : '');
  const isActive: boolean = input.isActive !== undefined ? input.isActive :
    (existing !== undefined ? existing.isActive : false);
  const selectedMap: Record<string, string> = input.selectedMap !== undefined ?
    copyStringMap(input.selectedMap) :
    (existing !== undefined ? copyStringMap(existing.selectedMap) : {});

  const record: ClashProfileRecord = {
    id: input.id,
    displayName: displayName,
    sourceKind: input.sourceKind,
    configFileName: buildProfileFileName(input.id),
    nodeCount: nodeCount,
    groupCount: groupCount,
    contentHash: contentHash,
    isActive: isActive,
    selectedMap: selectedMap
  };
  if (input.updatedAt !== undefined) {
    record.updatedAt = input.updatedAt;
  } else if (existing !== undefined && existing.updatedAt !== undefined) {
    record.updatedAt = existing.updatedAt;
  }
  if (input.lastAttemptAt !== undefined) {
    record.lastAttemptAt = input.lastAttemptAt;
  } else if (existing !== undefined && existing.lastAttemptAt !== undefined) {
    record.lastAttemptAt = existing.lastAttemptAt;
  }
  if (input.lastErrorCode !== undefined) {
    if (input.lastErrorCode.length > 0) {
      record.lastErrorCode = input.lastErrorCode;
    }
  } else if (existing !== undefined && existing.lastErrorCode !== undefined) {
    record.lastErrorCode = existing.lastErrorCode;
  }
  return record;
}

function buildRemovalResult(
  profileId: string,
  residue: ClashRemovalResidue[],
  remainingProfiles: number,
  requiresDelayPurge: boolean,
  stateHint: 'unconfigured' | 'profile_removed' | 'unchanged'): ClashProfileRemovalResult {
  const result: ClashProfileRemovalResult = {
    profileId: profileId,
    removed: residue.length === 0,
    residue: residue,
    remainingProfiles: remainingProfiles,
    requiresDelayPurge: requiresDelayPurge,
    stateHint: stateHint
  };
  return result;
}