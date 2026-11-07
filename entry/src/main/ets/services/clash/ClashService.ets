/**
 * Clash 代理 UI 侧唯一门面（任务 T-S2-16 + T-S2-17）。
 *
 * 证据来源：
 * - docs/integration/clash-proxy-tasks.md T-S2-16（状态接线、启停单飞、60 s 预算、
 *   linkLost 退避）、T-S2-17（导入/更新/应用/选节点/测速/删除/范围）。
 * - docs/integration/clash-proxy-design.md §3.2（关键时序）、§3.3（六态与三重证据）、
 *   §5.1-§5.8（会话、鉴权、方法表、断线与推送）、§7.1/§7.9、§9（Action 协议）、
 *   §10（订阅与配置流程）、§11（UI 语义）。
 *
 * 职责边界：
 * 1. 本类持有 `ClashStateMachine` 的唯一真值。外部只能读 `snapshot()`、订阅回调、
 *    调用命令方法；没有任何公开的 setState/写入接口。
 * 2. 所有扩展交互只走 `ClashRpcClient`（NDJSON + 首帧鉴权）。不 import
 *    `ClashCoreBridge` / `ClashConfigBuilder`：前者静态导入 `libclash_bridge.so`，
 *    后者把该桥接器作为默认通道，UI 进程 import 任一模块都会把内核库带进 UI 进程，
 *    违反「UI 侧仅 RPC」。`getConfig → patch → setupConfig` 由本类用纯模型
 *    `patchWithDiagnostics` 与 RPC Action 等价实现。
 * 3. 不 import TelegramService / MediaNetworkMonitor / TelephonyKit；代理与聊天网络
 *    状态互不推断。
 * 4. 不打印 URL、配置正文、节点凭据、token、nonce、路径或端口；日志只出现状态名与
 *    稳定错误码。错误对象只携带 `ProxyErrorCode` 与细分码。
 * 5. 启动链严格按「写 req → 拉起扩展 → ack → auth+hello → core.init → 配置 →
 *    vpn.options → tun.start → 三重证据」执行；`hello.coreLoaded=false` 直接
 *    `failed(core_missing)`，不调用 `tun.start`，因此不会弹 VPN 授权。
 *
 * 已知设计缺口（如实记录，不做伪状态）：
 * - `ClashStateMachine` 没有「connected → preparing(apply/scope)」事件，只有
 *   stopped/failed → preparing 的入口。因此已连接时的应用配置与范围切换保持
 *   `connected`，另以 snapshot 的 `operation`（apply/scope）表达进行中文案；
 *   失败时用 `linkLost → evidenceFailed` 收敛，避免把 TUN 已停的设备显示成已连接。
 * - 扩展侧 `getConfig` 仍是 T-S3-11 的占位实现（可能返回 `path_rejected`），在它落地前
 *   启动与切换会如实失败为 `path_rejected` / `config_invalid`，不会伪造 connected。
 */

import { common, Want } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { vpnExtension } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import {
  ActionEnvelope,
  ClashState,
  CoreState,
  DelayEntry,
  DelayMap,
  JsonPayload,
  PreparingReason,
  ProxyGroup,
  ProxyNode,
  ProxyScope,
  RawConfig,
  RPC_MAX_FRAME_BYTES,
  RpcPushChannel,
  SetupParams,
  StateEvent,
  StateEvidence,
  StateFacts,
  StateTransitionRecord,
  VpnOptions,
  VpnPropsState
} from '../../model/ClashModels';
import { ProxyErrorCode } from '../../model/ClashError';
import {
  buildAction,
  buildAsyncTestDelay,
  buildChangeProxy,
  buildGetConfig,
  buildSetupConfig,
  decodeActionResult,
  DecodedActionResult,
  makeActionId
} from '../../model/ClashActionFactory';
import { patchWithDiagnostics, ClashConfigPatchResult } from '../../model/ClashConfigPatch';
import {
  DerivedProxyGroup,
  ParsedProxyEntry,
  deriveGroups,
  isGroupEntry,
  parseProxies
} from '../../model/ClashGroupDeriver';
import {
  MAX_BATCH_CONCURRENCY,
  applyDelay,
  cancel,
  clearAll,
  clearProfile,
  planBatch
} from '../../model/ClashDelayMap';
import {
  deriveProfileId,
  isValidProfileId,
  mergeSelectedMap
} from '../../model/ClashProfileRules';
import {
  MAX_SUBSCRIPTION_BODY_BYTES,
  BodyCheckResult,
  checkBody,
  deriveDisplayName,
  looksLikeBase64Subscription,
  validateUrl,
  UrlValidationResult
} from '../../model/ClashSubscriptionParser';
import { redactUrl } from '../../model/ClashRedaction';
import {
  validateVpnOptions,
  VPN_CODE_TUN_CONFIG_INVALID
} from '../../model/ClashVpnConfig';
import {
  ClashProfileInput,
  ClashProfileRecord,
  ClashProfileRemovalResult,
  ClashProfileStore,
  ClashProfileStoreError,
  ClashProfileUpdate,
  ClashRemoveProfileOptions,
  ClashStoreSettings,
  ClashSubscriptionSecret,
  DEFAULT_SUBSCRIPTION_UA,
  normalizeSubscriptionUserAgent
} from './ClashProfileStore';
import {
  ClashSessionFiles,
  SESSION_PROTO_VERSION,
  SESSION_REQUEST_TTL_MS,
  SessionRequest,
  SessionWriteResult
} from './ClashSessionFiles';
import {
  ClashRpcClient,
  RpcClientError,
  RpcClientHandlers,
  RpcDisconnectReason,
  RpcFault,
  RpcHello,
  RpcLinkState
} from './ClashRpcClient';
import { ClashEventDecoder, DecodedEvent } from './ClashEventDecoder';
import { fetchToFile, FetchErrorCode, FetchResult } from './ClashSubscriptionFetcher';
import { ClashKeepAlive } from './ClashKeepAlive';
import { ClashDiagnostics, DiagnosticsTransitionInput } from './ClashDiagnostics';
import {
  PREPARING_TIMEOUT_MS,
  StateMachineInput,
  StateMachineOutput,
  transition as applyStateTransition
} from '../../model/ClashStateMachine';

// ---------------------------------------------------------------------------
// 常量
// ---------------------------------------------------------------------------

/** 与 module.json5 的 VPN 扩展声明一致；未声明时启动会以 rpc_unavailable 失败。 */
const EXTENSION_ABILITY_NAME: string = 'ClashVpnExtensionAbility';
/** Want 参数名，逐字对应设计 §5.1 第 2 条。 */
const WANT_PARAM_NONCE: string = 'clashSessionNonce';
const WANT_PARAM_FILE: string = 'clashSessionFile';

const CORE_INIT_TIMEOUT_MS: number = 30000;
const VPN_OPTIONS_TIMEOUT_MS: number = 10000;
const TUN_START_TIMEOUT_MS: number = 120000;
const TUN_STOP_TIMEOUT_MS: number = 30000;
const GET_CONFIG_TIMEOUT_MS: number = 20000;
const VALIDATE_CONFIG_TIMEOUT_MS: number = 30000;
const SETUP_CONFIG_TIMEOUT_MS: number = 60000;
const PROXIES_TIMEOUT_MS: number = 15000;
const CHANGE_PROXY_TIMEOUT_MS: number = 15000;
const RUNTIME_TIMEOUT_MS: number = 10000;
/** asyncTestDelay 的 timeout + 2 s 余量（设计 §5.4）。 */
const TEST_DELAY_TIMEOUT_MS: number = 7000;
const TEST_DELAY_PARAM_MS: number = 5000;
const DEFAULT_BATCH_CONCURRENCY: number = 4;
/** 与设计 §10.4 一致的非敏感默认测速地址。 */
const DEFAULT_TEST_URL: string = 'https://www.gstatic.com/generate_204';
const MAX_TEST_URL_LENGTH: number = 2048;

const MAX_LOCAL_YAML_BYTES: number = MAX_SUBSCRIPTION_BODY_BYTES;
const MAX_PROFILE_ID_ATTEMPTS: number = 64;

const PROFILES_DIR_NAME: string = 'profiles';
const HOME_MARKER: string = '/haps/';
const HOME_SUFFIX: string = '/files';

const LOG_DOMAIN: number = 0x0000;
const LOG_TAG: string = 'HarlgramClashService';

/** 内置虚拟节点，不计入节点数，也不参与测速。 */
const BUILTIN_PROXY_NAMES: string[] = [
  'DIRECT',
  'REJECT',
  'REJECT-DROP',
  'PASS',
  'COMPATIBLE',
  'GLOBAL'
];

// ---------------------------------------------------------------------------
// 对外类型
// ---------------------------------------------------------------------------

/** 命令结果：只含稳定错误码，不含原始响应文本。 */
export interface ClashOperationResult {
  ok: boolean;
  code?: ProxyErrorCode;
  detailCode?: string;
  /** 合流标记：重复点击被合并到正在进行的操作。 */
  merged?: boolean;
  /** 仅更新订阅时：内容与上次相同，未改变配置。 */
  unchanged?: boolean;
}

/** 已连接时进行中的非迁移动作；用于 UI 展示「正在应用配置/范围」。 */
export type ClashOperationKind = 'apply' | 'scope';

/**
 * 只读快照。所有字段都是新对象/新数组，调用方修改不会影响服务内部状态。
 * `state` 只来自 reducer；`operation` 只是已连接时的忙碌标记，不冒充状态。
 */
export interface ClashServiceSnapshot {
  state: ClashState;
  epoch: number;
  preparingReason?: PreparingReason;
  operation?: ClashOperationKind;
  errorCode?: string;
  errorDetailCode?: string;
  coreVersion?: string;
  currentProfileId?: string;
  currentNode?: string;
  connectedAt?: number;
  appliedProfileId?: string;
  /** 生效配置与当前 profile 内容不一致：UI 显示「有新版本，点击应用」。 */
  pendingApply: boolean;
  /** 停止时资源未完全释放：状态仍为 stopped，但需提示未释放资源。 */
  stopWarning: boolean;
  hasValidProfile: boolean;
  startInFlight: boolean;
  stopInFlight: boolean;
  importInFlight: boolean;
  updateInFlight: boolean;
  applyInFlight: boolean;
  scopeInFlight: boolean;
  probeAllInFlight: boolean;
  /** 正在测速的节点名（行内 spinner），只读副本。 */
  loadingDelayNames: string[];
  profiles: ClashProfileRecord[];
  groups: ProxyGroup[];
  delays: DelayMap;
  settings?: ClashStoreSettings;
}

export type ClashServiceListener = (snapshot: ClashServiceSnapshot) => void;

/** 本服务抛出的结构化错误；`message` 就是稳定码。 */
export class ClashServiceError extends Error {
  readonly code: ProxyErrorCode;
  readonly detailCode: string;

  constructor(code: ProxyErrorCode, detailCode: string = '') {
    super(code);
    this.name = 'ClashServiceError';
    this.code = code;
    this.detailCode = detailCode;
  }
}

// ---------------------------------------------------------------------------
// 内部类型
// ---------------------------------------------------------------------------

interface ActionOutcome {
  ok: boolean;
  data?: JsonPayload;
  code?: ProxyErrorCode;
  detailCode?: string;
}

interface RpcActionParams {
  action: ActionEnvelope;
}

interface CoreInitPayload {
  initialized?: boolean;
  isInit?: boolean;
  version?: string;
}

/** `core.init` 的请求体；扩展只接受 `homeDirKind='files'`。 */
interface CoreInitParams {
  homeDirKind: string;
}

interface TunEvidencePayload {
  coreReady?: boolean;
  tunReady?: boolean;
  routeReady?: boolean;
}

interface TunStartPayload {
  fd?: number;
  startedAt?: number;
  evidence?: object;
}

/** `tun.start` 的请求体，字段与扩展侧 `TunStartView` 对齐。 */
interface TunStartParams {
  scope: ProxyScope;
  state: CoreState;
}

interface TunStopReleased {
  tun?: boolean;
  rpc?: boolean;
}

interface TunStopPayload {
  stopped?: boolean;
  released?: object;
  warnings?: string[];
}

interface DelayPayload {
  name?: string;
  url?: string;
  value?: number;
}

interface TunStartOutcome {
  evidence: StateEvidence;
}

interface ProxyStatistics {
  nodeCount: number;
  groupCount: number;
  groups: DerivedProxyGroup[];
  proxies: Record<string, ParsedProxyEntry>;
}

/** 配置文件的节点/组/provider 统计。 */
interface ProfileCounts {
  nodeCount: number;
  groupCount: number;
  /** `proxy-providers` 的 provider 个数；provider 型订阅没有 inline proxies 时靠它判定非空。 */
  providerCount: number;
}

// ---------------------------------------------------------------------------
// 纯辅助函数（不读系统时钟以外的外部状态）
// ---------------------------------------------------------------------------

function success(merged: boolean = false): ClashOperationResult {
  const result: ClashOperationResult = { ok: true };
  if (merged) {
    result.merged = true;
  }
  return result;
}

function failure(code: ProxyErrorCode, detailCode: string = ''): ClashOperationResult {
  const result: ClashOperationResult = { ok: false, code: code };
  if (detailCode.length > 0) {
    result.detailCode = detailCode;
  }
  return result;
}

function emptyEvidence(): StateEvidence {
  return { coreReady: false, tunReady: false, routeReady: false };
}

function fullEvidence(): StateEvidence {
  return { coreReady: true, tunReady: true, routeReady: true };
}

/** RPC 客户端码、扩展错误码与 Action 码的统一收窄；未知值一律 `internal`。 */
function normalizeProxyCode(raw: string): ProxyErrorCode {
  switch (raw) {
    case 'core_missing':
      return 'core_missing';
    case 'core_load_failed':
      return 'core_load_failed';
    case 'core_init_failed':
      return 'core_init_failed';
    case 'config_missing':
      return 'config_missing';
    case 'config_invalid':
      return 'config_invalid';
    case 'tun_config_invalid':
      return 'tun_config_invalid';
    case 'tun_create_denied':
      return 'tun_create_denied';
    case 'tun_create_failed':
      return 'tun_create_failed';
    case 'tun_start_failed':
      return 'tun_start_failed';
    case 'tun_route_failed':
      return 'tun_route_failed';
    case 'rpc_unavailable':
      return 'rpc_unavailable';
    case 'rpc_auth_failed':
      return 'rpc_auth_failed';
    case 'path_rejected':
      return 'path_rejected';
    case 'protect_degraded':
      return 'protect_degraded';
    case 'extension_crashed':
      return 'extension_crashed';
    case 'timeout':
      return 'timeout';
    case 'unsupported':
      return 'unsupported';
    default:
      return 'internal';
  }
}

function asServiceError(error: Error): ClashServiceError {
  if (error instanceof ClashServiceError) {
    return error as ClashServiceError;
  }
  if (error instanceof RpcClientError) {
    const rpc: RpcClientError = error as RpcClientError;
    return new ClashServiceError(normalizeProxyCode(rpc.code),
      rpc.detailCode.length > 0 ? rpc.detailCode : rpc.code);
  }
  if (error instanceof ClashProfileStoreError) {
    return new ClashServiceError('internal', (error as ClashProfileStoreError).code);
  }
  return new ClashServiceError('internal', 'unexpected');
}

/** 只接受普通对象；数组、null 与标量返回 undefined。 */
function asObject(value: JsonPayload | undefined): object | undefined {
  if (value === undefined || value === null || typeof value !== 'object' || Array.isArray(value)) {
    return undefined;
  }
  return value as object;
}

/** JSON 字符串或对象统一成对象；不能解析时返回 undefined。 */
function parseObjectPayload(value: JsonPayload | undefined): object | undefined {
  if (typeof value === 'string') {
    if (value.length === 0) {
      return undefined;
    }
    let parsed: JsonPayload = null;
    try {
      parsed = JSON.parse(value) as JsonPayload;
    } catch (_) {
      return undefined;
    }
    return asObject(parsed);
  }
  return asObject(value);
}

function readString(value: JsonPayload | undefined): string {
  return typeof value === 'string' ? value : '';
}

function readStringArray(value: JsonPayload | undefined): string[] {
  const result: string[] = [];
  if (!Array.isArray(value)) {
    return result;
  }
  const items: JsonPayload[] = value as JsonPayload[];
  for (let index: number = 0; index < items.length; index++) {
    const item: JsonPayload = items[index];
    if (typeof item === 'string' && item.length > 0) {
      result.push(item);
    }
  }
  return result;
}

/** 统计数组中的普通对象个数；用于 RawConfig 的 proxies / proxy-groups。 */
function countArrayObjects(value: JsonPayload | undefined): number {
  if (!Array.isArray(value)) {
    return 0;
  }
  const items: JsonPayload[] = value as JsonPayload[];
  let count: number = 0;
  for (let index: number = 0; index < items.length; index++) {
    const item: JsonPayload = items[index];
    if (item !== null && typeof item === 'object' && !Array.isArray(item)) {
      count += 1;
    }
  }
  return count;
}

/** 统计普通对象的自身可枚举键数；数组、null 与标量返回 0。用于 RawConfig 的 proxy-providers。 */
function countObjectEntries(value: JsonPayload | undefined): number {
  const body: object | undefined = asObject(value);
  if (body === undefined) {
    return 0;
  }
  const entries: Record<string, JsonPayload> = body as Record<string, JsonPayload>;
  const keys: string[] = Object.keys(entries);
  return keys.length;
}

/** `getConfig` 结果的原文提取：字符串直接使用，对象序列化；其它按缺失处理。 */
function readConfigJson(data: JsonPayload | undefined): string {
  if (typeof data === 'string') {
    return data;
  }
  const body: object | undefined = asObject(data);
  if (body === undefined) {
    return '';
  }
  try {
    const text: string | undefined = JSON.stringify(body);
    return text !== undefined ? text : '';
  } catch (_) {
    return '';
  }
}

function copyStringMap(source: Record<string, string>): Record<string, string> {
  const copy: Record<string, string> = {};
  const keys: string[] = Object.keys(source);
  for (let index: number = 0; index < keys.length; index++) {
    copy[keys[index]] = source[keys[index]];
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

function copyProfile(record: ClashProfileRecord): ClashProfileRecord {
  const copy: ClashProfileRecord = {
    id: record.id,
    displayName: record.displayName,
    sourceKind: record.sourceKind,
    configFileName: record.configFileName,
    nodeCount: record.nodeCount,
    groupCount: record.groupCount,
    contentHash: record.contentHash,
    isActive: record.isActive,
    selectedMap: copyStringMap(record.selectedMap)
  };
  if (record.sourceRefKey !== undefined) {
    copy.sourceRefKey = record.sourceRefKey;
  }
  if (record.updatedAt !== undefined) {
    copy.updatedAt = record.updatedAt;
  }
  if (record.lastAttemptAt !== undefined) {
    copy.lastAttemptAt = record.lastAttemptAt;
  }
  if (record.lastErrorCode !== undefined) {
    copy.lastErrorCode = record.lastErrorCode;
  }
  return copy;
}

function copyProfiles(records: ClashProfileRecord[]): ClashProfileRecord[] {
  const result: ClashProfileRecord[] = [];
  for (let index: number = 0; index < records.length; index++) {
    result.push(copyProfile(records[index]));
  }
  return result;
}

function copyNode(source: ProxyNode): ProxyNode {
  const copy: ProxyNode = {
    id: source.id,
    name: source.name,
    type: source.type,
    protocolLabel: source.protocolLabel,
    availability: source.availability,
    groupName: source.groupName
  };
  if (source.unavailableReason !== undefined) {
    copy.unavailableReason = source.unavailableReason;
  }
  if (source.now !== undefined) {
    copy.now = source.now;
  }
  return copy;
}

function copyGroups(source: ProxyGroup[]): ProxyGroup[] {
  const result: ProxyGroup[] = [];
  for (let index: number = 0; index < source.length; index++) {
    const group: ProxyGroup = source[index];
    const nodes: ProxyNode[] = [];
    for (let nodeIndex: number = 0; nodeIndex < group.all.length; nodeIndex++) {
      nodes.push(copyNode(group.all[nodeIndex]));
    }
    const copy: ProxyGroup = {
      name: group.name,
      type: group.type,
      isAuto: group.isAuto,
      hidden: group.hidden,
      all: nodes
    };
    if (group.now !== undefined) {
      copy.now = group.now;
    }
    if (group.testUrl !== undefined) {
      copy.testUrl = group.testUrl;
    }
    if (group.icon !== undefined) {
      copy.icon = group.icon;
    }
    result.push(copy);
  }
  return result;
}

function copyDelays(source: DelayMap): DelayMap {
  const result: DelayMap = {};
  const urls: string[] = Object.keys(source);
  for (let urlIndex: number = 0; urlIndex < urls.length; urlIndex++) {
    const url: string = urls[urlIndex];
    const sourceBucket: Record<string, DelayEntry> = source[url];
    const bucket: Record<string, DelayEntry> = {};
    const names: string[] = Object.keys(sourceBucket);
    for (let nameIndex: number = 0; nameIndex < names.length; nameIndex++) {
      const entry: DelayEntry = sourceBucket[names[nameIndex]];
      const entryCopy: DelayEntry = { value: entry.value, at: entry.at, state: entry.state };
      bucket[names[nameIndex]] = entryCopy;
    }
    result[url] = bucket;
  }
  return result;
}

/** 与设计 §10.4 一致的测速地址归一化；非法值回退默认，不阻断配置应用。 */
function normalizeTestUrlLocal(value: string): string {
  if (typeof value !== 'string' || value.length === 0 || value.length > MAX_TEST_URL_LENGTH) {
    return DEFAULT_TEST_URL;
  }
  if (value !== value.trim()) {
    return DEFAULT_TEST_URL;
  }
  if (value.indexOf(' ') >= 0 || value.indexOf('\t') >= 0) {
    return DEFAULT_TEST_URL;
  }
  const lower: string = value.toLowerCase();
  if (!lower.startsWith('http://') && !lower.startsWith('https://')) {
    return DEFAULT_TEST_URL;
  }
  return value;
}

/** YAML/SetupParams 必须能放进单条 RPC 帧（设计 §5.2 上限 1 MiB）。 */
function assertFitsRpcFrame(text: string, detailCode: string): void {
  let bytes: number = 0;
  try {
    bytes = new util.TextEncoder().encodeInto(text).length;
  } catch (_) {
    throw new ClashServiceError('config_invalid', detailCode + '_encode_failed');
  }
  if (bytes > RPC_MAX_FRAME_BYTES - 4096) {
    throw new ClashServiceError('config_invalid', detailCode + '_too_large');
  }
}

function sha256Hex(text: string): string {
  try {
    const bytes: Uint8Array = new util.TextEncoder().encodeInto(text);
    const md: cryptoFramework.Md = cryptoFramework.createMd('SHA256');
    const blob: cryptoFramework.DataBlob = { data: bytes };
    md.updateSync(blob);
    const digest: Uint8Array = md.digestSync().data;
    let hex: string = '';
    for (let index: number = 0; index < digest.length; index++) {
      hex += digest[index].toString(16).padStart(2, '0');
    }
    return hex;
  } catch (_) {
    // hash 只用于「内容是否变化」展示；不可得时返回空串，不阻断导入。
    return '';
  }
}

function randomHex(byteCount: number): string {
  const bytes: Uint8Array = cryptoFramework.createRandom().generateRandomSync(byteCount).data;
  let hex: string = '';
  for (let index: number = 0; index < bytes.length; index++) {
    hex += bytes[index].toString(16).padStart(2, '0');
  }
  return hex;
}

/** UI 与扩展必须使用同一 home：`.../el2/base/files`（设计 §7.1）。 */
function resolveHomeDir(filesDir: string): string {
  let dir: string = filesDir;
  if (dir.indexOf('\\') >= 0) {
    dir = dir.split('\\').join('/');
  }
  const markerIndex: number = dir.indexOf(HOME_MARKER);
  if (markerIndex > 0) {
    dir = dir.substring(0, markerIndex) + HOME_SUFFIX;
  }
  while (dir.length > 1 && dir.endsWith('/')) {
    dir = dir.substring(0, dir.length - 1);
  }
  return dir;
}

function isBuiltinProxyName(name: string): boolean {
  return BUILTIN_PROXY_NAMES.indexOf(name) >= 0;
}

function statisticsFromProxies(proxies: Record<string, ParsedProxyEntry>,
  declaredGroups?: string[]): ProxyStatistics {
  const names: string[] = Object.keys(proxies);
  let nodeCount: number = 0;
  for (let index: number = 0; index < names.length; index++) {
    const name: string = names[index];
    const entry: ParsedProxyEntry = proxies[name];
    if (isBuiltinProxyName(name) || isGroupEntry(entry)) {
      continue;
    }
    if (entry.hasEndpoint) {
      nodeCount += 1;
    }
  }
  const groups: DerivedProxyGroup[] = deriveGroups(proxies, declaredGroups);
  const stats: ProxyStatistics = {
    nodeCount: nodeCount,
    groupCount: groups.length,
    groups: groups,
    proxies: proxies
  };
  return stats;
}

function leafNodeNames(proxies: Record<string, ParsedProxyEntry>): string[] {
  const names: string[] = Object.keys(proxies);
  const result: string[] = [];
  for (let index: number = 0; index < names.length; index++) {
    const name: string = names[index];
    const entry: ParsedProxyEntry = proxies[name];
    if (isBuiltinProxyName(name) || isGroupEntry(entry) || !entry.hasEndpoint) {
      continue;
    }
    result.push(name);
  }
  return result;
}

function currentNodeOf(groups: ProxyGroup[]): string {
  for (let index: number = 0; index < groups.length; index++) {
    const group: ProxyGroup = groups[index];
    if (group.name === 'GLOBAL' && group.now !== undefined && group.now.length > 0) {
      return group.now;
    }
  }
  for (let index: number = 0; index < groups.length; index++) {
    const group: ProxyGroup = groups[index];
    if (!group.isAuto && group.now !== undefined && group.now.length > 0) {
      return group.now;
    }
  }
  return '';
}

function logInfo(code: string): void {
  hilog.info(LOG_DOMAIN, LOG_TAG, 'clash service: %{public}s', code);
}

function logWarn(code: string): void {
  hilog.warn(LOG_DOMAIN, LOG_TAG, 'clash service: %{public}s', code);
}

// ---------------------------------------------------------------------------
// 服务
// ---------------------------------------------------------------------------

export class ClashService {
  private static instance: ClashService | null = null;

  static get(): ClashService {
    if (ClashService.instance === null) {
      ClashService.instance = new ClashService();
    }
    return ClashService.instance;
  }

  // ---- 生命周期与依赖 ----
  private context: common.UIAbilityContext | undefined = undefined;
  private store: ClashProfileStore | undefined = undefined;
  private sessionFiles: ClashSessionFiles | undefined = undefined;
  private client: ClashRpcClient | undefined = undefined;
  private readonly keepAlive: ClashKeepAlive = ClashKeepAlive.get();
  private readonly decoder: ClashEventDecoder = new ClashEventDecoder();
  private homeDir: string = '';
  private initialized: boolean = false;
  private initWork: Promise<void> | undefined = undefined;

  // ---- 状态机真值 ----
  private state: ClashState = 'unconfigured';
  private epoch: number = 0;
  private stateReason: PreparingReason | undefined = undefined;
  private reconnectAttempts: number = 0;
  private illegalTransitions: number = 0;
  private staleEpochEvents: number = 0;
  private preparingStartedAtMs: number = 0;
  private preparingTimer: number = -1;
  private actionSeq: number = 0;

  // ---- 运行事实 ----
  private lastErrorCode: ProxyErrorCode | undefined = undefined;
  private lastDetailCode: string = '';
  private coreVersion: string = '';
  private coreInitialized: boolean = false;
  private currentProfileId: string = '';
  private currentNode: string = '';
  private connectedAt: number = 0;
  private stopWarning: boolean = false;

  // ---- 配置应用快照（仅内存，不写盘） ----
  private appliedProfileId: string = '';
  private appliedContentHash: string = '';
  private lastAppliedSetup: SetupParams | undefined = undefined;

  // ---- 单飞与最后意图 ----
  private desiredRunning: boolean | undefined = undefined;
  private startInFlight: boolean = false;
  private stopInFlight: boolean = false;
  private importInFlight: boolean = false;
  private updateInFlight: boolean = false;
  private applyInFlight: boolean = false;
  private scopeInFlight: boolean = false;
  private probeAllInFlight: boolean = false;
  private probeAllToken: number = 0;
  private operation: ClashOperationKind | undefined = undefined;
  private sessionRebuildInFlight: boolean = false;
  private sessionRebuildTimer: number = -1;

  // ---- 数据 ----
  private profiles: ClashProfileRecord[] = [];
  private settings: ClashStoreSettings | undefined = undefined;
  private groups: ProxyGroup[] = [];
  private proxies: Record<string, ParsedProxyEntry> = {};
  private delays: DelayMap = {};
  private loadingDelayNames: Set<string> = new Set<string>();

  private listeners: ClashServiceListener[] = [];
  private notifyTimer: number = -1;

  // -------------------------------------------------------------------------
  // 初始化与只读快照
  // -------------------------------------------------------------------------

  /**
   * 绑定 UIAbilityContext 并恢复非敏感配置。重复调用幂等。
   * 本方法不启动扩展、不创建 TUN、不请求授权。
   */
  init(context: common.UIAbilityContext): Promise<void> {
    if (this.initialized) {
      return Promise.resolve();
    }
    if (this.initWork !== undefined) {
      return this.initWork;
    }
    this.initWork = this.initialize(context);
    return this.initWork;
  }

  /** 是否已完成本地元数据初始化；未完成时命令返回 internal。 */
  isInitialized(): boolean {
    return this.initialized;
  }

  /** 返回只读快照；每次调用都构造新对象与新数组。 */
  snapshot(): ClashServiceSnapshot {
    const snapshot: ClashServiceSnapshot = {
      state: this.state,
      epoch: this.epoch,
      pendingApply: this.isPendingApply(),
      stopWarning: this.stopWarning,
      hasValidProfile: this.hasValidProfile(),
      startInFlight: this.startInFlight,
      stopInFlight: this.stopInFlight,
      importInFlight: this.importInFlight,
      updateInFlight: this.updateInFlight,
      applyInFlight: this.applyInFlight,
      scopeInFlight: this.scopeInFlight,
      probeAllInFlight: this.probeAllInFlight,
      loadingDelayNames: this.copyLoadingNames(),
      profiles: copyProfiles(this.profiles),
      groups: copyGroups(this.groups),
      delays: copyDelays(this.delays)
    };
    if (this.stateReason !== undefined) {
      snapshot.preparingReason = this.stateReason;
    }
    if (this.operation !== undefined) {
      snapshot.operation = this.operation;
    }
    if (this.lastErrorCode !== undefined) {
      snapshot.errorCode = this.lastErrorCode;
    }
    if (this.lastDetailCode.length > 0) {
      snapshot.errorDetailCode = this.lastDetailCode;
    }
    if (this.coreVersion.length > 0) {
      snapshot.coreVersion = this.coreVersion;
    }
    if (this.currentProfileId.length > 0) {
      snapshot.currentProfileId = this.currentProfileId;
    }
    if (this.currentNode.length > 0) {
      snapshot.currentNode = this.currentNode;
    }
    if (this.connectedAt > 0) {
      snapshot.connectedAt = this.connectedAt;
    }
    if (this.appliedProfileId.length > 0) {
      snapshot.appliedProfileId = this.appliedProfileId;
    }
    if (this.settings !== undefined) {
      snapshot.settings = copySettings(this.settings);
    }
    return snapshot;
  }

  /** 订阅快照变化；重复订阅同一函数会去重。 */
  subscribe(listener: ClashServiceListener): void {
    if (this.listeners.indexOf(listener) >= 0) {
      return;
    }
    this.listeners.push(listener);
  }

  /** 取消订阅；不传参数时清空全部订阅。 */
  unsubscribe(listener?: ClashServiceListener): void {
    if (listener === undefined) {
      this.listeners = [];
      return;
    }
    const index: number = this.listeners.indexOf(listener);
    if (index >= 0) {
      this.listeners.splice(index, 1);
    }
  }

  // -------------------------------------------------------------------------
  // 状态机接线
  // -------------------------------------------------------------------------

  /**
   * 唯一状态写入点：把当前状态、epoch 与计数注入纯 reducer，采纳其结果。
   * 外部无法绕过本方法改状态。
   */
  private dispatch(event: StateEvent, reason: PreparingReason | undefined,
    evidence: StateEvidence, errorCode: ProxyErrorCode | undefined): StateMachineOutput {
    const facts: StateFacts = {
      evidence: evidence,
      hasValidProfile: this.hasValidProfile(),
      epoch: this.epoch
    };
    const input: StateMachineInput = {
      state: this.state,
      epoch: this.epoch,
      event: event,
      facts: facts,
      nowMs: Date.now(),
      preparingStartedAtMs: this.preparingStartedAtMs,
      illegalTransitions: this.illegalTransitions,
      staleEpochEvents: this.staleEpochEvents,
      reconnectAttempts: this.reconnectAttempts
    };
    if (reason !== undefined) {
      input.facts.reason = reason;
    }
    // 始终带上当前 preparing 原因：linkLost 的重连预算依赖 stateReason=reconnect。
    input.stateReason = this.stateReason;
    if (errorCode !== undefined) {
      input.facts.errorCode = errorCode;
    }
    const output: StateMachineOutput = applyStateTransition(input);
    this.illegalTransitions = output.illegalTransitions;
    this.staleEpochEvents = output.staleEpochEvents;
    this.reconnectAttempts = output.reconnectAttempts;
    if (output.rejected !== undefined && output.rejected.code === 'illegal_transition') {
      ClashDiagnostics.get().increment('illegalTransitions');
    }
    if (output.changed) {
      const previousState: ClashState = this.state;
      this.state = output.state;
      if (output.epoch !== this.epoch) {
        this.epoch = output.epoch;
        this.actionSeq = 0;
      }
      this.applyStateBookkeeping(previousState, output);
    }
    return output;
  }

  /** 迁移后的附属事实：文案原因、计时器、时间戳与诊断环形缓冲。 */
  private applyStateBookkeeping(previousState: ClashState, output: StateMachineOutput): void {
    const record: StateTransitionRecord = output.record;
    const errorCode: string = record.errorCode !== undefined ? record.errorCode : '';
    const transition: DiagnosticsTransitionInput = {
      at: Date.now(),
      from: record.from,
      to: record.to,
      event: record.event,
      epoch: record.epoch,
      errorCode: errorCode
    };
    ClashDiagnostics.get().recordTransition(transition);
    if (output.state === 'preparing') {
      this.stateReason = record.reason !== undefined ? record.reason : 'start';
      this.preparingStartedAtMs = Date.now();
      this.armPreparingBudget(output.epoch, output.preparingDeadlineMs);
      this.connectedAt = 0;
    } else {
      this.stateReason = undefined;
      this.clearPreparingBudget();
    }
    if (output.state === 'connected') {
      if (this.connectedAt === 0) {
        this.connectedAt = Date.now();
      }
      // 连接成功即清空上一次失败与停止告警，避免旧错误长期留在状态卡。
      this.lastErrorCode = undefined;
      this.lastDetailCode = '';
      this.stopWarning = false;
    } else {
      this.connectedAt = 0;
    }
    if (record.errorCode !== undefined) {
      this.lastErrorCode = normalizeProxyCode(record.errorCode);
      this.lastDetailCode = record.event;
    }
    if (output.state === 'failed' || output.state === 'unauthorized') {
      this.operation = undefined;
    }
    logInfo('state_' + previousState + '_to_' + output.state);
    this.publish();
  }

  private armPreparingBudget(epoch: number, deadlineMs: number | undefined): void {
    this.clearPreparingBudget();
    const now: number = Date.now();
    const deadline: number = deadlineMs !== undefined
      ? deadlineMs
      : now + PREPARING_TIMEOUT_MS;
    const remaining: number = deadline - now;
    const delay: number = remaining > 0 ? remaining : 0;
    this.preparingTimer = setTimeout((): void => {
      this.preparingTimer = -1;
      this.onPreparingTimeout(epoch, deadline);
    }, delay);
  }

  private clearPreparingBudget(): void {
    if (this.preparingTimer >= 0) {
      clearTimeout(this.preparingTimer);
      this.preparingTimer = -1;
    }
  }

  private onPreparingTimeout(epoch: number, deadline: number): void {
    if (this.state !== 'preparing' || this.epoch !== epoch) {
      return;
    }
    const remaining: number = deadline - Date.now();
    if (remaining > 0) {
      this.preparingTimer = setTimeout((): void => {
        this.preparingTimer = -1;
        this.onPreparingTimeout(epoch, deadline);
      }, remaining);
      return;
    }
    this.lastErrorCode = 'timeout';
    this.lastDetailCode = 'prepare_timeout';
    this.desiredRunning = false;
    this.dispatch('prepareTimeout', undefined, emptyEvidence(), 'timeout');
    this.releasePreparingResources();
    logWarn('prepare_timeout');
    this.publish();
  }

  /** 超时/失败后的资源收敛：不阻塞状态呈现，失败只记日志。 */
  private releasePreparingResources(): void {
    this.keepAlive.disable();
    this.disposeClient();
    this.coreInitialized = false;
    const files: ClashSessionFiles | undefined = this.sessionFiles;
    if (files !== undefined) {
      files.cleanup().catch((): void => {
        logWarn('session_cleanup_failed');
      });
    }
  }

  // -------------------------------------------------------------------------
  // 初始化实现
  // -------------------------------------------------------------------------

  private async initialize(context: common.UIAbilityContext): Promise<void> {
    this.context = context;
    try {
      this.homeDir = resolveHomeDir(context.filesDir);
      this.store = new ClashProfileStore(context, this.homeDir);
      // 会话文件必须使用与扩展相同的 context.filesDir；homeDir 是内核 home，
      // 少了 `haps/<module>` 层级，不能用于 req/ack 交换。
      this.sessionFiles = new ClashSessionFiles(context.filesDir);
      this.keepAlive.onRevoked((): void => {
        this.onKeepAliveRevoked();
      });
      await this.reloadProfilesAndSettings();
      this.currentProfileId = this.activeProfileId();
      this.dispatch('appRestarted', undefined, emptyEvidence(), undefined);
      this.initialized = true;
      logInfo('initialized');
    } catch (error) {
      const err: ClashServiceError = asServiceError(error as Error);
      this.lastErrorCode = err.code;
      this.lastDetailCode = err.detailCode;
      // 初始化失败不锁定门面：清掉半初始化依赖，下一次 init 可重试。
      this.initialized = false;
      this.store = undefined;
      this.sessionFiles = undefined;
      // 状态仍由 reducer 决定；初始化失败只通过 errorCode 呈现，不直接改 state。
      logWarn('init_' + err.code);
    }
    this.initWork = undefined;
    this.publish();
  }

  private async reloadProfilesAndSettings(): Promise<void> {
    const store: ClashProfileStore | undefined = this.store;
    if (store === undefined) {
      return;
    }
    const records: ClashProfileRecord[] = await store.listProfiles();
    this.profiles = records;
    const settings: ClashStoreSettings = await store.getSettings();
    this.settings = settings;
  }

  private activeProfileId(): string {
    for (let index: number = 0; index < this.profiles.length; index++) {
      if (this.profiles[index].isActive) {
        return this.profiles[index].id;
      }
    }
    return '';
  }

  private activeProfile(): ClashProfileRecord | undefined {
    for (let index: number = 0; index < this.profiles.length; index++) {
      if (this.profiles[index].isActive) {
        return this.profiles[index];
      }
    }
    return undefined;
  }

  private findProfile(profileId: string): ClashProfileRecord | undefined {
    for (let index: number = 0; index < this.profiles.length; index++) {
      if (this.profiles[index].id === profileId) {
        return this.profiles[index];
      }
    }
    return undefined;
  }

  private hasValidProfile(): boolean {
    const active: ClashProfileRecord | undefined = this.activeProfile();
    return active !== undefined && active.nodeCount > 0;
  }

  private isPendingApply(): boolean {
    if (this.appliedProfileId.length === 0) {
      return false;
    }
    const active: ClashProfileRecord | undefined = this.activeProfile();
    if (active === undefined) {
      return false;
    }
    if (active.id !== this.appliedProfileId) {
      return true;
    }
    const record: ClashProfileRecord | undefined = this.findProfile(this.appliedProfileId);
    if (record === undefined) {
      return false;
    }
    if (record.contentHash.length === 0) {
      return false;
    }
    return record.contentHash !== this.appliedContentHash;
  }

  private copyLoadingNames(): string[] {
    const result: string[] = [];
    this.loadingDelayNames.forEach((name: string): void => {
      result.push(name);
    });
    return result;
  }

  private effectiveScope(): ProxyScope {
    if (this.settings !== undefined && (this.settings.scope === 'global' ||
      this.settings.scope === 'harlgramOnly')) {
      return this.settings.scope;
    }
    return 'global';
  }

  private effectiveTestUrl(): string {
    if (this.settings === undefined) {
      return normalizeTestUrlLocal('');
    }
    return normalizeTestUrlLocal(this.settings.testUrl);
  }

  // -------------------------------------------------------------------------
  // 快照通知
  // -------------------------------------------------------------------------

  /** 合并同一事件循环内的多次变更，避免批量测速时重复深拷贝。 */
  private publish(): void {
    if (this.notifyTimer >= 0) {
      return;
    }
    this.notifyTimer = setTimeout((): void => {
      this.notifyTimer = -1;
      const snapshot: ClashServiceSnapshot = this.snapshot();
      const listeners: ClashServiceListener[] = this.listeners.slice(0, this.listeners.length);
      for (let index: number = 0; index < listeners.length; index++) {
        try {
          listeners[index](snapshot);
        } catch (_) {
          logWarn('listener_failed');
        }
      }
    }, 0);
  }

  // -------------------------------------------------------------------------
  // RPC 与 Action 通道
  // -------------------------------------------------------------------------

  /** 一条 Action 的完整往返：id 生成、信封构造、RPC 发送、结果解码。 */
  private async runAction(method: string, data: string | undefined,
    timeoutMs: number): Promise<ActionOutcome> {
    const client: ClashRpcClient | undefined = this.client;
    if (client === undefined || client.state() !== 'ready') {
      return { ok: false, code: 'rpc_unavailable', detailCode: 'not_connected' };
    }
    this.actionSeq += 1;
    let envelope: ActionEnvelope;
    try {
      const id: string = makeActionId(method, this.epoch, this.actionSeq);
      envelope = buildAction(id, method, data);
    } catch (error) {
      const err: ClashServiceError = asServiceError(error as Error);
      return { ok: false, code: 'internal', detailCode: err.detailCode };
    }
    const params: RpcActionParams = { action: envelope };
    try {
      const raw: JsonPayload = await client.request('core.action', params, timeoutMs);
      const decoded: DecodedActionResult | null = decodeActionResult(raw);
      if (decoded === null) {
        return { ok: false, code: 'internal', detailCode: 'invalid_action_result' };
      }
      if (!decoded.ok) {
        const rawCode: string = decoded.error !== undefined ? decoded.error.code : 'internal';
        const detail: string = decoded.error !== undefined && decoded.error.detailCode !== undefined
          ? decoded.error.detailCode
          : '';
        return {
          ok: false,
          code: normalizeProxyCode(rawCode),
          detailCode: detail.length > 0 ? detail : 'action_failed'
        };
      }
      const outcome: ActionOutcome = { ok: true };
      if (decoded.data !== undefined) {
        outcome.data = decoded.data;
      }
      return outcome;
    } catch (error) {
      const err: ClashServiceError = asServiceError(error as Error);
      return { ok: false, code: err.code, detailCode: err.detailCode };
    }
  }

  /** 读取 `getProxies` 并派生组；失败返回 undefined，不伪造空组。 */
  private async readProxyStatistics(): Promise<ProxyStatistics | undefined> {
    const outcome: ActionOutcome = await this.runAction('getProxies', undefined, PROXIES_TIMEOUT_MS);
    if (!outcome.ok) {
      return undefined;
    }
    const body: object | undefined = parseObjectPayload(outcome.data);
    if (body === undefined) {
      return undefined;
    }
    const proxies: Record<string, ParsedProxyEntry> = parseProxies(body);
    return statisticsFromProxies(proxies);
  }

  /**
   * 统计某个 profile 文件自己的节点/组/provider 数。
   *
   * `getProxies` 只反映内核当前已应用的配置，无法统计「尚未 apply」的新文件；
   * 设计 §10.3 第 5 步因此用 `getConfig` 读取该文件。扩展接受 profileId 或
   * 应用私有 `profiles/*.yaml` 绝对路径，这里直接传 `profilePath`，getConfig
   * 不可用时返回 undefined，由调用方如实报
   * config_invalid，不写半成品元数据。provider 型订阅的节点要 apply 后才展开，
   * 所以 `proxy-providers` 的键数与 inline proxies 一起作为非空判据。
   */
  private async readProfileStatistics(profileId: string): Promise<ProfileCounts | undefined> {
    // 诊断：先确认该 profile 的 YAML 是否落盘，只记录存在性，不记录文件内容。
    const yaml: string | undefined = this.store !== undefined ? await this.store.readYaml(profileId) : undefined;
    logInfo('profile_stats_file_' + (yaml === undefined ? 'missing' : 'present'));
    const outcome: ActionOutcome = await this.runAction('getConfig',
      buildGetConfig(this.profilePath(profileId)), GET_CONFIG_TIMEOUT_MS);
    if (!outcome.ok) {
      // 固定 code/detail 标签，不含配置正文、订阅 URL 或节点名称。
      const codeLabel: string = outcome.code !== undefined ? outcome.code : 'unknown';
      const detailLabel: string = outcome.detailCode !== undefined ? outcome.detailCode : 'no_detail';
      logWarn('profile_stats_unavailable_' + codeLabel + '_' + detailLabel);
      return undefined;
    }
    const rawJson: string = readConfigJson(outcome.data);
    let parsed: RawConfig | null = null;
    try {
      parsed = JSON.parse(rawJson) as RawConfig;
    } catch (_) {
      parsed = null;
    }
    if (parsed !== null && typeof parsed === 'object' && !Array.isArray(parsed)) {
      const view: Record<string, JsonPayload> = parsed as Record<string, JsonPayload>;
      const nodeCount: number = countArrayObjects(view['proxies']);
      const groupCount: number = countArrayObjects(view['proxy-groups']);
      const providerCount: number = countObjectEntries(view['proxy-providers']);
      // 只记录数量，不含配置正文、订阅 URL 或节点/组/provider 名称。
      logInfo('profile_stats_' + nodeCount + '_' + groupCount + '_' + providerCount);
      // provider 型订阅的节点在 apply 后才会展开，不能因 inline proxies 为空就判失败。
      if (nodeCount > 0 || providerCount > 0) {
        const counts: ProfileCounts = {
          nodeCount: nodeCount,
          groupCount: groupCount,
          providerCount: providerCount
        };
        return counts;
      }
      // 解析成功但没有任何节点/provider：固定标签，不含配置内容。
      logWarn('profile_stats_parse_failed_empty');
    } else {
      logWarn('profile_stats_parse_failed_json');
    }
    // getConfig 不可靠时不猜测：用旧运行配置统计会得到错误节点数。
    return undefined;
  }

  private async refreshProxies(): Promise<void> {
    const stats: ProxyStatistics | undefined = await this.readProxyStatistics();
    if (stats === undefined) {
      return;
    }
    this.proxies = stats.proxies;
    this.groups = stats.groups;
    const node: string = currentNodeOf(stats.groups);
    if (node.length > 0) {
      this.currentNode = node;
    }
    this.publish();
  }

  // -------------------------------------------------------------------------
  // 会话建立（不建 TUN、不请求授权）
  // -------------------------------------------------------------------------

  /**
   * 确保存在已鉴权、已完成 core.init 的扩展会话。
   *
   * @param rotate true 表示允许关闭旧客户端并让扩展轮换会话（启动/重建）；
   *   false 表示已有会话不可用时直接失败，避免在 connected 状态下意外断线。
   */
  private async ensureSession(rotate: boolean): Promise<void> {
    const context: common.UIAbilityContext | undefined = this.context;
    const files: ClashSessionFiles | undefined = this.sessionFiles;
    if (context === undefined || files === undefined) {
      throw new ClashServiceError('internal', 'not_initialized');
    }
    const existing: ClashRpcClient | undefined = this.client;
    if (existing !== undefined && existing.state() === 'ready' && this.coreInitialized) {
      return;
    }
    if (!rotate) {
      // connected 状态不允许为了导入而轮换会话：那会打断正在运行的代理。
      throw new ClashServiceError('rpc_unavailable', 'session_not_ready');
    }

    // 新会话必须换 nonce/token；旧客户端先正常关闭，避免收到 session_rotated。
    this.disposeClient();
    this.coreInitialized = false;
    const nonce: string = randomHex(16);
    const token: string = randomHex(32);
    const request: SessionRequest = {
      proto: SESSION_PROTO_VERSION,
      token: token,
      nonce: nonce,
      issuedAt: Date.now(),
      ttlMs: SESSION_REQUEST_TTL_MS
    };
    const written: SessionWriteResult = await files.writeRequest(nonce, request);
    if (!written.ok) {
      throw new ClashServiceError('rpc_unavailable', 'session_write_failed');
    }
    const parameters: Record<string, Object> = {};
    parameters[WANT_PARAM_NONCE] = nonce;
    parameters[WANT_PARAM_FILE] = 'req-' + nonce + '.json';
    const want: Want = {
      bundleName: context.abilityInfo.bundleName,
      abilityName: EXTENSION_ABILITY_NAME,
      parameters: parameters
    };
    try {
      await vpnExtension.startVpnExtensionAbility(want);
    } catch (error) {
      const business: BusinessError = error as BusinessError;
      logWarn('extension_start_' + String(business.code));
      throw new ClashServiceError('rpc_unavailable', 'extension_start_failed');
    }

    const handlers: RpcClientHandlers = {
      onPush: (kind: RpcPushChannel, data: object): void => {
        this.onRpcPush(kind, data);
      },
      onState: (state: RpcLinkState): void => {
        this.onRpcState(state);
      },
      onFault: (fault: RpcFault): void => {
        this.onRpcFault(fault);
      },
      onDisconnected: (reason: RpcDisconnectReason): void => {
        this.onRpcDisconnected(reason);
      }
    };
    const client: ClashRpcClient = new ClashRpcClient(files, handlers);
    this.client = client;
    let hello: RpcHello;
    try {
      // port=0：客户端内部按 250 ms × 40 轮询 ack，再建连并发送 auth/hello。
      hello = await client.connect(0, token, nonce);
    } catch (error) {
      this.disposeClient();
      throw asServiceError(error as Error);
    }
    if (!hello.coreLoaded) {
      // 硬失败：不调用 tun.start，因此不会请求 VPN 授权。
      this.coreVersion = hello.coreVersion;
      this.disposeClient();
      throw new ClashServiceError('core_missing', 'hello_core_loaded_false');
    }

    let initData: JsonPayload = null;
    try {
      const initParams: CoreInitParams = { homeDirKind: 'files' };
      initData = await client.request('core.init', initParams, CORE_INIT_TIMEOUT_MS);
    } catch (error) {
      this.disposeClient();
      throw asServiceError(error as Error);
    }
    const initBody: object | undefined = parseObjectPayload(initData);
    if (initBody === undefined) {
      this.disposeClient();
      throw new ClashServiceError('core_init_failed', 'invalid_init_result');
    }
    const init: CoreInitPayload = initBody as CoreInitPayload;
    if (init.initialized !== true || init.isInit !== true) {
      this.disposeClient();
      throw new ClashServiceError('core_init_failed', 'init_not_ready');
    }
    const version: string = readString(init.version);
    this.coreVersion = version.length > 0 ? version : hello.coreVersion;
    this.coreInitialized = true;
  }

  private disposeClient(): void {
    const client: ClashRpcClient | undefined = this.client;
    this.client = undefined;
    if (client !== undefined) {
      client.close();
    }
  }

  /**
   * `tun.stop` 会让扩展在应答后关闭 RPC 监听；需要再次 `tun.start` 时必须先
   * 用新 nonce 重建会话，不能复用已终止的客户端。
   */
  private async rebuildSessionForTun(epoch: number): Promise<void> {
    this.disposeClient();
    this.coreInitialized = false;
    await this.ensureSession(true);
    this.ensureSameEpoch(epoch);
  }

  private async profileFileExists(profileId: string): Promise<boolean> {
    if (!isValidProfileId(profileId)) {
      return false;
    }
    const path: string = this.profilePath(profileId);
    try {
      return await fileIo.access(path);
    } catch (_) {
      return false;
    }
  }

  private profilePath(profileId: string): string {
    return this.homeDir + '/' + PROFILES_DIR_NAME + '/' + profileId + '.yaml';
  }

  private profilesDir(): string {
    return this.homeDir + '/' + PROFILES_DIR_NAME;
  }

  // -------------------------------------------------------------------------
  // 启动与停止
  // -------------------------------------------------------------------------

  /**
   * 启动代理。配置缺失或节点数为 0 时保持当前状态（unconfigured/stopped），
   * 不拉起扩展、不请求授权。
   */
  async start(): Promise<ClashOperationResult> {
    this.desiredRunning = true;
    if (!this.initialized) {
      return failure('internal', 'not_initialized');
    }
    if (this.startInFlight) {
      this.publish();
      return success(true);
    }
    if (this.stopInFlight) {
      // 停止完成后会按最后意图重新启动。
      return success(true);
    }
    if (this.importInFlight || this.updateInFlight || this.applyInFlight || this.scopeInFlight) {
      return failure('internal', 'operation_in_flight');
    }
    if (this.state === 'connected' || this.state === 'preparing') {
      return success();
    }
    const active: ClashProfileRecord | undefined = this.activeProfile();
    if (active === undefined) {
      if (this.profiles.length === 0 && this.state !== 'unconfigured') {
        // 生效配置已被外部删除：按设计 §10.7 回到 unconfigured。
        this.dispatch('profileRemoved', undefined, emptyEvidence(), undefined);
      }
      this.lastErrorCode = 'config_missing';
      this.lastDetailCode = 'no_active_profile';
      this.publish();
      return failure('config_missing', 'no_active_profile');
    }
    if (active.nodeCount <= 0) {
      this.lastErrorCode = 'config_invalid';
      this.lastDetailCode = 'no_nodes';
      this.publish();
      return failure('config_invalid', 'no_nodes');
    }
    const exists: boolean = await this.profileFileExists(active.id);
    if (!exists) {
      this.lastErrorCode = 'config_missing';
      this.lastDetailCode = 'profile_file_missing';
      this.publish();
      return failure('config_missing', 'profile_file_missing');
    }

    if (this.state === 'unconfigured') {
      // 已有有效 profile 但状态仍停在 unconfigured（例如从未连接的应用重启后
      // 先应用了配置）：先按导入成功回到 stopped，再走正常启动入口。
      this.dispatch('importSucceeded', undefined, emptyEvidence(), undefined);
    }
    const event: StateEvent = (this.state === 'failed' || this.state === 'unauthorized')
      ? 'retryRequested'
      : 'enableRequested';
    const output: StateMachineOutput = this.dispatch(event, 'start', emptyEvidence(), undefined);
    if (output.rejected !== undefined || !this.isState('preparing')) {
      const rejection: string = output.rejected !== undefined ? output.rejected.code : 'state_not_preparing';
      const code: ProxyErrorCode = rejection === 'no_valid_profile' ? 'config_missing' : 'internal';
      this.lastErrorCode = code;
      this.lastDetailCode = rejection;
      this.publish();
      return failure(code, rejection);
    }

    this.startInFlight = true;
    this.stopWarning = false;
    this.lastErrorCode = undefined;
    this.lastDetailCode = '';
    this.operation = undefined;
    const epoch: number = this.epoch;
    this.publish();

    let result: ClashOperationResult = success();
    try {
      await this.runStartChain(epoch, active);
      result = success();
    } catch (error) {
      result = await this.handleStartFailure(epoch, error as Error);
    } finally {
      this.startInFlight = false;
      this.publish();
    }
    if (this.shouldStopAfterStart()) {
      await this.stop();
      if (result.ok) {
        result = success(true);
      }
    }
    return result;
  }

  private shouldStopAfterStart(): boolean {
    return this.desiredRunning === false;
  }

  private shouldStartAfterStop(): boolean {
    return this.desiredRunning === true;
  }

  /** 通过方法读取状态，避免 TS 对属性做跨 await 的错误收窄。 */
  private isState(value: ClashState): boolean {
    return this.state === value;
  }

  private async runStartChain(epoch: number, profile: ClashProfileRecord): Promise<void> {
    this.ensureEpoch(epoch);
    await this.ensureSession(true);
    this.ensureEpoch(epoch);

    // 配置必须先于 TUN：否则 startTun 会在没有配置的内核上运行。
    await this.applyProfileToCore(epoch, profile);
    this.ensureEpoch(epoch);

    await this.readVpnOptions(epoch);
    this.ensureEpoch(epoch);

    const tun: TunStartOutcome = await this.startTun(epoch);
    this.ensureEpoch(epoch);
    this.ensureTunEvidence(tun);

    this.currentNode = this.resolveActiveNode(profile);
    const output: StateMachineOutput = this.dispatch('evidenceReady', undefined, tun.evidence, undefined);
    if (this.state !== 'connected') {
      const detail: string = output.rejected !== undefined ? output.rejected.code : 'evidence_rejected';
      throw new ClashServiceError('internal', detail);
    }
    this.appliedProfileId = profile.id;
    this.appliedContentHash = profile.contentHash;
    this.currentProfileId = profile.id;
    this.connectedAt = this.connectedAt > 0 ? this.connectedAt : Date.now();
    this.lastErrorCode = undefined;
    this.lastDetailCode = '';
    this.stopWarning = false;
    const context: common.UIAbilityContext | undefined = this.context;
    if (context !== undefined) {
      // 只在 connected 后申请长时任务；失败只计数，不改变代理状态。
      await this.keepAlive.enable(context);
    }
    await this.refreshProxies();
    logInfo('connected');
    this.publish();
  }

  private resolveActiveNode(profile: ClashProfileRecord): string {
    const map: Record<string, string> = profile.selectedMap;
    const names: string[] = Object.keys(map);
    for (let index: number = 0; index < names.length; index++) {
      const value: string = map[names[index]];
      if (typeof value === 'string' && value.length > 0) {
        return value;
      }
    }
    return '';
  }

  /** `vpn.options` + ArkTS 侧字段校验；失败不得继续 tun.start。 */
  private async readVpnOptions(epoch: number): Promise<VpnOptions> {
    this.ensureSameEpoch(epoch);
    const client: ClashRpcClient | undefined = this.client;
    if (client === undefined) {
      throw new ClashServiceError('rpc_unavailable', 'not_connected');
    }
    let raw: JsonPayload = null;
    try {
      raw = await client.request('vpn.options', undefined, VPN_OPTIONS_TIMEOUT_MS);
    } catch (error) {
      throw asServiceError(error as Error);
    }
    const body: object | undefined = parseObjectPayload(raw);
    if (body === undefined) {
      throw new ClashServiceError('tun_config_invalid', 'invalid_vpn_options');
    }
    const options: VpnOptions = body as VpnOptions;
    const codes: string[] = validateVpnOptions(options);
    for (let index: number = 0; index < codes.length; index++) {
      if (codes[index] === VPN_CODE_TUN_CONFIG_INVALID) {
        throw new ClashServiceError('tun_config_invalid', 'options_invalid');
      }
    }
    if (typeof options.ipv4Address !== 'string' || options.ipv4Address.length === 0) {
      throw new ClashServiceError('tun_config_invalid', 'options_missing_address');
    }
    return options;
  }

  /** 构造 CoreState；`bypass-domain` 为空，分应用名单由扩展按 scope 生成。 */
  private buildCoreState(profile: ClashProfileRecord): CoreState {
    const props: VpnPropsState = {
      enable: true,
      systemProxy: false,
      ipv6: true,
      allowBypass: true
    };
    const state: CoreState = {
      'vpn-props': props,
      'current-profile-name': profile.displayName,
      'bypass-domain': []
    };
    return state;
  }

  private async startTun(epoch: number): Promise<TunStartOutcome> {
    this.ensureSameEpoch(epoch);
    const active: ClashProfileRecord | undefined = this.activeProfile();
    if (active === undefined) {
      throw new ClashServiceError('config_missing', 'no_active_profile');
    }
    const client: ClashRpcClient | undefined = this.client;
    if (client === undefined) {
      throw new ClashServiceError('rpc_unavailable', 'not_connected');
    }
    const params: TunStartParams = {
      scope: this.effectiveScope(),
      state: this.buildCoreState(active)
    };
    let raw: JsonPayload = null;
    try {
      raw = await client.request('tun.start', params, TUN_START_TIMEOUT_MS);
    } catch (error) {
      throw asServiceError(error as Error);
    }
    const body: object | undefined = parseObjectPayload(raw);
    if (body === undefined) {
      throw new ClashServiceError('tun_start_failed', 'invalid_tun_result');
    }
    const payload: TunStartPayload = body as TunStartPayload;
    const evidence: StateEvidence = emptyEvidence();
    const evidenceBody: object | undefined = asObject(payload.evidence);
    if (evidenceBody !== undefined) {
      const view: TunEvidencePayload = evidenceBody as TunEvidencePayload;
      evidence.coreReady = view.coreReady === true;
      evidence.tunReady = view.tunReady === true;
      evidence.routeReady = view.routeReady === true;
    }
    if (payload.fd === undefined || typeof payload.fd !== 'number' || payload.fd <= 0) {
      throw new ClashServiceError('tun_create_failed', 'fd_missing');
    }
    const outcome: TunStartOutcome = { evidence: evidence };
    return outcome;
  }

  /** 三重证据必须全真；任一缺失都不得对外宣称 connected。 */
  private ensureTunEvidence(tun: TunStartOutcome): void {
    const evidence: StateEvidence = tun.evidence;
    if (!evidence.coreReady || !evidence.tunReady || !evidence.routeReady) {
      throw new ClashServiceError('tun_route_failed', 'evidence_incomplete');
    }
  }

  private async handleStartFailure(epoch: number, error: Error): Promise<ClashOperationResult> {
    const err: ClashServiceError = asServiceError(error);
    if (this.epoch !== epoch || this.state !== 'preparing') {
      // 已被取消/超时/新意图覆盖：不再改状态，只回报结果。
      return failure(err.code, err.detailCode);
    }
    this.lastErrorCode = err.code;
    this.lastDetailCode = err.detailCode;
    if (err.code === 'core_missing' || err.code === 'core_load_failed') {
      // 未进入 tun.start，不会有系统授权弹窗。
      this.releasePreparingResources();
      this.dispatch('evidenceFailed', undefined, emptyEvidence(), err.code);
      logWarn('start_failed_' + err.code);
      this.publish();
      return failure(err.code, err.detailCode);
    }
    if (err.code === 'tun_create_denied') {
      await this.bestEffortStopTun();
      this.releasePreparingResources();
      this.dispatch('authDenied', undefined, emptyEvidence(), 'tun_create_denied');
      logWarn('start_denied');
      this.publish();
      return failure(err.code, err.detailCode);
    }
    await this.bestEffortStopTun();
    this.releasePreparingResources();
    const evidence: StateEvidence = emptyEvidence();
    if (err.code !== 'core_init_failed' && err.code !== 'tun_start_failed' &&
      err.code !== 'tun_config_invalid') {
      evidence.coreReady = true;
    }
    if (err.code === 'timeout') {
      this.dispatch('prepareTimeout', undefined, evidence, 'timeout');
    } else {
      this.dispatch('evidenceFailed', undefined, evidence, err.code);
    }
    logWarn('start_failed_' + err.code);
    this.publish();
    return failure(err.code, err.detailCode);
  }

  private async bestEffortStopTun(): Promise<void> {
    const client: ClashRpcClient | undefined = this.client;
    if (client === undefined || client.state() !== 'ready') {
      return;
    }
    try {
      await client.request('tun.stop', undefined, TUN_STOP_TIMEOUT_MS);
    } catch (_) {
      logWarn('tun_stop_failed');
    }
  }

  /**
   * 停止代理：tun.stop → 校验 released → KeepAlive.disable → stopped。
   * 任一释放失败保留 stopped 状态并置 `stopWarning`，文案由 UI 使用
   * 「已停止，但存在未释放资源」。
   */
  async stop(): Promise<ClashOperationResult> {
    if (!this.initialized) {
      return failure('internal', 'not_initialized');
    }
    if (this.importInFlight || this.updateInFlight || this.applyInFlight || this.scopeInFlight) {
      return failure('internal', 'operation_in_flight');
    }
    this.desiredRunning = false;
    if (this.stopInFlight) {
      return success(true);
    }
    if (this.startInFlight) {
      // 启动链在 finally 后按最后意图执行停止。
      return success(true);
    }
    if (this.state !== 'connected' && this.state !== 'preparing') {
      this.keepAlive.disable();
      return success();
    }

    this.stopInFlight = true;
    this.lastErrorCode = undefined;
    this.lastDetailCode = '';
    this.publish();
    let warning: boolean = false;
    let stopped: boolean = false;
    let releasedTun: boolean = false;
    let releasedRpc: boolean = false;

    const client: ClashRpcClient | undefined = this.client;
    if (client !== undefined && client.state() === 'ready') {
      try {
        const raw: JsonPayload = await client.request('tun.stop', undefined, TUN_STOP_TIMEOUT_MS);
        const body: object | undefined = parseObjectPayload(raw);
        if (body === undefined) {
          warning = true;
        } else {
          const payload: TunStopPayload = body as TunStopPayload;
          stopped = payload.stopped === true;
          const releasedBody: object | undefined = asObject(payload.released);
          if (releasedBody !== undefined) {
            const released: TunStopReleased = releasedBody as TunStopReleased;
            releasedTun = released.tun === true;
            releasedRpc = released.rpc === true;
          }
          const warnings: string[] = readStringArray(payload.warnings);
          if (!stopped || !releasedTun || !releasedRpc || warnings.length > 0) {
            warning = true;
          }
        }
      } catch (error) {
        const err: ClashServiceError = asServiceError(error as Error);
        this.lastErrorCode = err.code;
        this.lastDetailCode = err.detailCode;
        warning = true;
        logWarn('stop_rpc_' + err.code);
      }
    } else {
      // 扩展已不在：无法确认 TUN 释放，如实标记未释放。
      warning = true;
    }

    this.keepAlive.disable();
    this.disposeClient();
    this.coreInitialized = false;
    const files: ClashSessionFiles | undefined = this.sessionFiles;
    if (files !== undefined) {
      try {
        await files.cleanup();
      } catch (_) {
        warning = true;
      }
    }
    this.groups = [];
    this.proxies = {};
    this.delays = clearAll();
    this.loadingDelayNames.clear();
    this.currentNode = '';
    this.connectedAt = 0;
    this.operation = undefined;
    this.stopWarning = warning;

    if (this.state === 'connected') {
      this.dispatch('stopRequested', undefined, emptyEvidence(), undefined);
    } else if (this.state === 'preparing') {
      this.dispatch('cancelled', undefined, emptyEvidence(), undefined);
    }
    if (warning) {
      // 只标记未释放资源；不伪造错误码，UI 以 stopWarning 呈现。
      this.lastDetailCode = 'stopped_with_warning';
      logWarn('stopped_with_warning');
    } else {
      this.lastErrorCode = undefined;
      this.lastDetailCode = '';
      logInfo('stopped');
    }
    this.stopInFlight = false;
    this.publish();

    if (this.shouldStartAfterStop()) {
      await this.start();
      return success(true);
    }
    if (warning) {
      const warned: ClashOperationResult = success();
      warned.detailCode = 'stopped_with_warning';
      return warned;
    }
    return success();
  }

  private ensureEpoch(epoch: number): void {
    if (this.epoch !== epoch || this.state !== 'preparing') {
      throw new ClashServiceError('timeout', 'aborted');
    }
  }

  /** 已连接时的热操作只要求同一 epoch；preparing 或 connected 都允许。 */
  private ensureSameEpoch(epoch: number): void {
    if (this.epoch !== epoch ||
      (this.state !== 'preparing' && this.state !== 'connected')) {
      throw new ClashServiceError('timeout', 'aborted');
    }
  }

  // -------------------------------------------------------------------------
  // 断线、推送与保活回调
  // -------------------------------------------------------------------------

  private onRpcState(state: RpcLinkState): void {
    if (state === 'reconnecting') {
      this.onClientReconnecting();
      return;
    }
    if (state === 'ready') {
      this.onClientReady().catch((): void => {
        logWarn('ready_handler_failed');
      });
    }
  }

  /** 客户端每次退避重试都会进入 reconnecting；用它推进状态机的 5 次预算。 */
  private onClientReconnecting(): void {
    if (this.scopeInFlight || this.stopInFlight) {
      // 范围切换/停止会主动关闭 RPC；由各自流程处理，不计入重连预算。
      return;
    }
    if (this.state === 'connected') {
      const output: StateMachineOutput = this.dispatch('linkLost', undefined, emptyEvidence(), undefined);
      if (output.nextRetryDelayMs !== undefined) {
        logInfo('reconnect_scheduled');
      }
      this.operation = undefined;
      this.lastErrorCode = undefined;
      this.lastDetailCode = '';
      this.publish();
      return;
    }
    if (this.state === 'preparing' && this.stateReason === 'reconnect') {
      this.dispatch('linkLost', undefined, emptyEvidence(), undefined);
      if (this.isState('failed')) {
        this.onReconnectExhausted();
      }
      this.publish();
    }
  }

  private async onClientReady(): Promise<void> {
    if (this.startInFlight || this.sessionRebuildInFlight) {
      // 启动链/会话重建自己会完成证据校验，避免 ready 回调重复 tun.start。
      return;
    }
    if (this.state !== 'preparing' || this.stateReason !== 'reconnect') {
      return;
    }
    const epoch: number = this.epoch;
    try {
      const runtime: number = await this.readRunTime();
      if (this.epoch !== epoch || this.state !== 'preparing') {
        return;
      }
      let evidence: StateEvidence = fullEvidence();
      if (runtime <= 0) {
        // TUN 随进程一起消失：重新走 vpn.options + tun.start（可能再次请求授权）。
        await this.readVpnOptions(epoch);
        const tun: TunStartOutcome = await this.startTun(epoch);
        this.ensureTunEvidence(tun);
        evidence = tun.evidence;
      }
      this.ensureEpoch(epoch);
      this.dispatch('evidenceReady', undefined, evidence, undefined);
      if (this.isState('connected')) {
        this.connectedAt = Date.now();
        const context: common.UIAbilityContext | undefined = this.context;
        if (context !== undefined) {
          await this.keepAlive.enable(context);
        }
        await this.refreshProxies();
        logInfo('reconnected');
        this.publish();
      }
    } catch (error) {
      const err: ClashServiceError = asServiceError(error as Error);
      this.lastErrorCode = err.code;
      this.lastDetailCode = err.detailCode;
      // 保持 preparing；客户端下一次 reconnecting 会继续消耗预算，60 s 后超时。
      this.publish();
    }
  }

  /** 会话被轮换且客户端已终止：用新 nonce 重建整条会话。 */
  private onRpcDisconnected(reason: RpcDisconnectReason): void {
    if (this.stopInFlight || this.scopeInFlight) {
      // 停止/范围切换会主动断开；状态由命令流程收敛，避免被断线事件覆盖。
      return;
    }
    if (reason === 'closed') {
      return;
    }
    if (reason === 'link_lost') {
      // 客户端已自行排入 1/2/4/8/16 s 重试；状态由 reconnecting 回调推进，
      // 这里不重复计一次预算。
      return;
    }
    if (reason === 'extension_crashed') {
      if (this.state === 'connected') {
        this.dispatch('linkLost', undefined, emptyEvidence(), undefined);
        this.dispatch('reconnectExhausted', undefined, emptyEvidence(), 'extension_crashed');
        if (this.isState('failed')) {
          this.onReconnectExhausted();
        }
      } else if (this.state === 'preparing' && this.stateReason === 'reconnect') {
        const output: StateMachineOutput =
          this.dispatch('linkLost', undefined, emptyEvidence(), undefined);
        if (this.isState('failed')) {
          this.onReconnectExhausted();
        } else {
          const nextDelay: number = output.nextRetryDelayMs !== undefined
            ? output.nextRetryDelayMs
            : 16000;
          this.scheduleSessionRebuild(nextDelay);
        }
      }
      this.publish();
      return;
    }
    // session_rotated：旧客户端终止，必须用新 ack 重建。
    if (this.state !== 'connected' && this.state !== 'preparing') {
      return;
    }
    if (this.state === 'connected') {
      this.dispatch('linkLost', undefined, emptyEvidence(), undefined);
    }
    this.scheduleSessionRebuild(1000);
    this.publish();
  }

  private onReconnectExhausted(): void {
    this.lastErrorCode = 'extension_crashed';
    this.lastDetailCode = 'reconnect_exhausted';
    this.desiredRunning = false;
    this.operation = undefined;
    this.keepAlive.disable();
    this.disposeClient();
    this.coreInitialized = false;
    const files: ClashSessionFiles | undefined = this.sessionFiles;
    if (files !== undefined) {
      files.cleanup().catch((): void => {
        logWarn('session_cleanup_failed');
      });
    }
    logWarn('reconnect_exhausted');
    this.publish();
  }

  private scheduleSessionRebuild(delayMs: number): void {
    if (this.sessionRebuildTimer >= 0) {
      return;
    }
    const delay: number = Number.isFinite(delayMs) && delayMs > 0 ? delayMs : 1000;
    const epoch: number = this.epoch;
    this.sessionRebuildTimer = setTimeout((): void => {
      this.sessionRebuildTimer = -1;
      this.runSessionRebuild(epoch).catch((): void => {
        logWarn('session_rebuild_failed');
      });
    }, delay);
  }

  private async runSessionRebuild(epoch: number): Promise<void> {
    if (this.sessionRebuildInFlight || this.state !== 'preparing' ||
      this.stateReason !== 'reconnect' || this.epoch !== epoch) {
      return;
    }
    this.sessionRebuildInFlight = true;
    try {
      await this.ensureSession(true);
      this.ensureEpoch(epoch);
      const runtime: number = await this.readRunTime();
      let evidence: StateEvidence = fullEvidence();
      if (runtime <= 0) {
        await this.readVpnOptions(epoch);
        const tun: TunStartOutcome = await this.startTun(epoch);
        this.ensureTunEvidence(tun);
        evidence = tun.evidence;
      }
      this.ensureEpoch(epoch);
      this.dispatch('evidenceReady', undefined, evidence, undefined);
      if (this.isState('connected')) {
        this.connectedAt = Date.now();
        const context: common.UIAbilityContext | undefined = this.context;
        if (context !== undefined) {
          await this.keepAlive.enable(context);
        }
        await this.refreshProxies();
        logInfo('session_rebuilt');
      }
    } catch (error) {
      const err: ClashServiceError = asServiceError(error as Error);
      if (this.epoch === epoch && this.state === 'preparing' && this.stateReason === 'reconnect') {
        this.lastErrorCode = err.code;
        this.lastDetailCode = err.detailCode;
        const output: StateMachineOutput = this.dispatch('linkLost', undefined, emptyEvidence(), undefined);
        if (this.isState('failed')) {
          this.onReconnectExhausted();
        } else {
          const nextDelay: number = output.nextRetryDelayMs !== undefined
            ? output.nextRetryDelayMs
            : 16000;
          this.scheduleSessionRebuild(nextDelay);
        }
      }
    } finally {
      this.sessionRebuildInFlight = false;
      this.publish();
    }
  }

  private async readRunTime(): Promise<number> {
    const outcome: ActionOutcome = await this.runAction('getRunTime', undefined, RUNTIME_TIMEOUT_MS);
    if (!outcome.ok) {
      return 0;
    }
    if (typeof outcome.data === 'number') {
      return outcome.data;
    }
    if (typeof outcome.data === 'string') {
      const parsed: number = Number(outcome.data);
      return Number.isFinite(parsed) ? parsed : 0;
    }
    return 0;
  }

  private onRpcPush(kind: RpcPushChannel, data: object): void {
    if (kind === 'fault') {
      return;
    }
    if (kind === 'state') {
      // UI 持有状态机真值：扩展推送只用于诊断，不直接改状态。
      return;
    }
    let payload: string = '';
    try {
      payload = JSON.stringify(data);
    } catch (_) {
      logWarn('event_encode_failed');
      return;
    }
    const event: DecodedEvent | null = this.decoder.decode(payload);
    if (event === null) {
      return;
    }
    if (event.type === 'delay') {
      this.applyDecodedDelay(event);
      return;
    }
    if (event.type === 'loaded') {
      this.refreshProxies().catch((): void => {
        logWarn('refresh_after_loaded_failed');
      });
      return;
    }
    // traffic / log 只进入解码器计数；本阶段 UI 不展示，不写入任何持久化。
  }

  private applyDecodedDelay(event: DecodedEvent): void {
    const name: string = event.name !== undefined ? event.name : '';
    const url: string = event.url !== undefined ? event.url : '';
    const value: number = event.value !== undefined ? event.value : -1;
    const at: number = event.at !== undefined ? event.at : Date.now();
    if (name.length === 0 || url.length === 0) {
      return;
    }
    this.delays = applyDelay(this.delays, name, url, value, at);
    this.loadingDelayNames.delete(name);
    this.publish();
  }

  private onRpcFault(fault: RpcFault): void {
    // 结构化计数；不展示原始 message。
    if (fault.code === 'extension_crashed') {
      logWarn('fault_extension_crashed');
    } else if (fault.code === 'session_rotated') {
      logWarn('fault_session_rotated');
    } else {
      logWarn('fault_' + normalizeProxyCode(fault.code));
    }
  }

  private onKeepAliveRevoked(): void {
    if (this.state !== 'connected') {
      return;
    }
    const epoch: number = this.epoch;
    this.dispatch('linkLost', undefined, emptyEvidence(), undefined);
    this.publish();
    // 系统回收长时任务不必然断开 RPC；重连后按证据恢复或重新 tun.start。
    setTimeout((): void => {
      this.verifyAfterRevocation(epoch).catch((): void => {
        logWarn('revocation_verify_failed');
      });
    }, 1000);
  }

  private async verifyAfterRevocation(epoch: number): Promise<void> {
    if (this.epoch !== epoch || this.state !== 'preparing' ||
      this.stateReason !== 'reconnect') {
      return;
    }
    const client: ClashRpcClient | undefined = this.client;
    if (client === undefined || client.state() !== 'ready') {
      // 客户端仍在重连时，由 reconnecting/ready 回调继续推进。
      return;
    }
    await this.onClientReady();
  }

  // -------------------------------------------------------------------------
  // 配置应用（getConfig → patch → setupConfig）
  // -------------------------------------------------------------------------

  /**
   * 读取配置文件并组装 SetupParams。`getConfig` 与 `setupConfig` 都走 RPC。
   * 该方法不写文件、不改变状态，失败抛稳定码。
   */
  private async buildSetupParams(epoch: number, profile: ClashProfileRecord): Promise<SetupParams> {
    this.ensureSameEpoch(epoch);
    const outcome: ActionOutcome = await this.runAction('getConfig',
      buildGetConfig(profile.id), GET_CONFIG_TIMEOUT_MS);
    if (!outcome.ok) {
      const code: ProxyErrorCode = outcome.code !== undefined ? outcome.code : 'config_invalid';
      throw new ClashServiceError(code, outcome.detailCode !== undefined ? outcome.detailCode : 'get_config_failed');
    }
    const rawJson: string = readConfigJson(outcome.data);
    if (rawJson.length === 0) {
      throw new ClashServiceError('config_invalid', 'missing_config');
    }
    let parsed: RawConfig | null = null;
    try {
      parsed = JSON.parse(rawJson) as RawConfig;
    } catch (_) {
      parsed = null;
    }
    if (parsed === null) {
      throw new ClashServiceError('config_invalid', 'parse_failed');
    }
    let patched: RawConfig = parsed;
    try {
      const result: ClashConfigPatchResult = patchWithDiagnostics(parsed);
      patched = result.config;
    } catch (_) {
      throw new ClashServiceError('config_invalid', 'patch_failed');
    }
    const setup: SetupParams = {
      config: patched,
      'selected-map': copyStringMap(profile.selectedMap),
      'test-url': this.effectiveTestUrl()
    };
    return setup;
  }

  private async sendSetupConfig(epoch: number, setup: SetupParams): Promise<void> {
    this.ensureSameEpoch(epoch);
    let data: string = '';
    try {
      data = buildSetupConfig(setup.config, setup['selected-map'], setup['test-url']);
    } catch (_) {
      throw new ClashServiceError('config_invalid', 'setup_encode_failed');
    }
    assertFitsRpcFrame(data, 'setup');
    const outcome: ActionOutcome = await this.runAction('setupConfig', data, SETUP_CONFIG_TIMEOUT_MS);
    if (!outcome.ok) {
      const code: ProxyErrorCode = outcome.code !== undefined ? outcome.code : 'config_invalid';
      throw new ClashServiceError(code, outcome.detailCode !== undefined ? outcome.detailCode : 'setup_failed');
    }
  }

  /** 首次启动/重试：把当前生效配置写入内核。 */
  private async applyProfileToCore(epoch: number, profile: ClashProfileRecord): Promise<void> {
    const setup: SetupParams = await this.buildSetupParams(epoch, profile);
    await this.sendSetupConfig(epoch, setup);
    this.lastAppliedSetup = setup;
    this.appliedProfileId = profile.id;
    this.appliedContentHash = profile.contentHash;
  }

  /** 失败时重放上一份成功快照；没有快照或重放失败返回 false。 */
  private async replayLastSetup(epoch: number): Promise<boolean> {
    const setup: SetupParams | undefined = this.lastAppliedSetup;
    if (setup === undefined) {
      return false;
    }
    try {
      await this.sendSetupConfig(epoch, setup);
      return true;
    } catch (_) {
      return false;
    }
  }

  /**
   * 已连接时把「配置已无法恢复」的失败收敛到 failed。
   * 用 linkLost（connected→preparing）→ evidenceFailed 两步，保持与 reducer 一致；
   * 不安排自动重连。
   */
  private failFromConnected(code: ProxyErrorCode, detail: string): void {
    if (this.state === 'connected') {
      this.dispatch('linkLost', undefined, emptyEvidence(), undefined);
    }
    if (this.state === 'preparing') {
      this.dispatch('evidenceFailed', undefined, emptyEvidence(), code);
    }
    this.lastErrorCode = code;
    this.lastDetailCode = detail;
    this.releasePreparingResources();
    this.publish();
  }

  // -------------------------------------------------------------------------
  // T-S2-17：订阅、YAML、应用、节点、测速、删除、范围
  // -------------------------------------------------------------------------

  /**
   * 导入订阅：本地校验 → 拉取（≤8 MiB）→ UTF-8/结构校验 → validateConfig →
   * 原子写 + Asset + 元数据 → getProxies 统计 → unconfigured→stopped。
   * 不建 TUN、不请求 VPN 授权、不自动 apply。
   */
  async importSubscription(url: string): Promise<ClashOperationResult> {
    if (!this.initialized) {
      return failure('internal', 'not_initialized');
    }
    if (this.importInFlight) {
      return failure('internal', 'import_in_flight');
    }
    if (this.state === 'preparing' || this.startInFlight || this.stopInFlight ||
      this.applyInFlight || this.scopeInFlight) {
      return failure('internal', 'operation_in_flight');
    }
    const validation: UrlValidationResult = validateUrl(url);
    if (!validation.ok) {
      const code: ProxyErrorCode = validation.code === 'unsupported' ? 'unsupported' : 'config_invalid';
      this.lastErrorCode = code;
      this.lastDetailCode = validation.detailCode !== undefined ? validation.detailCode : 'invalid_url';
      this.publish();
      return failure(code, this.lastDetailCode);
    }
    const store: ClashProfileStore | undefined = this.store;
    if (store === undefined) {
      return failure('internal', 'not_initialized');
    }

    this.importInFlight = true;
    this.lastErrorCode = undefined;
    this.lastDetailCode = '';
    this.publish();
    let tempPath: string = '';
    let writtenProfileId: string = '';
    try {
      const profileId: string = await this.allocateProfileId(url);
      const displayName: string = deriveDisplayName('', '', displayNameHintFromUrl(url));
      tempPath = this.profilesDir() + '/.fetch-' + profileId + '.yaml';
      await this.ensureDirectory(this.profilesDir());

      const fetched: FetchResult =
        await fetchToFileForProfile(url, profileId, tempPath, this.subscriptionUserAgent());
      if (!fetched.ok) {
        const fetchCode: string = fetched.errorCode !== undefined ? fetched.errorCode : 'unknown';
        throw new ClashServiceError(mapFetchCode(fetched.errorCode), 'fetch_' + fetchCode);
      }
      const bytes: Uint8Array = await this.readFileBytes(tempPath);
      const body: BodyCheckResult = checkBody(bytes);
      if (!body.ok) {
        throw new ClashServiceError('config_invalid',
          body.detailCode !== undefined ? body.detailCode : 'body_rejected');
      }
      if (looksLikeBase64Subscription(body.text)) {
        throw new ClashServiceError('unsupported', 'base64_subscription');
      }
      assertFitsRpcFrame(body.text, 'yaml');

      await this.ensureSession(this.state !== 'connected');
      const validated: ActionOutcome =
        await this.runAction('validateConfig', body.text, VALIDATE_CONFIG_TIMEOUT_MS);
      if (!validated.ok) {
        throw new ClashServiceError('config_invalid',
          validated.detailCode !== undefined ? validated.detailCode : 'validate_failed');
      }

      await store.saveYaml(profileId, body.text);
      writtenProfileId = profileId;

      const counts: ProfileCounts | undefined = await this.readProfileStatistics(profileId);
      if (counts === undefined || (counts.nodeCount <= 0 && counts.providerCount <= 0)) {
        throw new ClashServiceError('config_invalid', 'no_nodes');
      }
      const contentHash: string = sha256Hex(body.text);
      const now: number = Date.now();
      const hasActive: boolean = this.hasValidProfile();
      const input: ClashProfileInput = {
        id: profileId,
        displayName: displayName,
        sourceKind: 'subscription',
        // provider 数量是近似值：apply 后会以 getProxies 刷新真实节点数，
        // 这里先并入计数以便 provider 型配置能被 hasValidProfile() 识别。
        nodeCount: counts.nodeCount + counts.providerCount,
        groupCount: counts.groupCount,
        contentHash: contentHash,
        updatedAt: now,
        lastAttemptAt: now,
        isActive: !hasActive
      };
      const secret: ClashSubscriptionSecret = { url: url };
      await store.upsertProfile(input, secret);
      writtenProfileId = '';
      await this.reloadProfilesAndSettings();
      this.currentProfileId = this.activeProfileId();
      if (this.state === 'unconfigured' && this.hasValidProfile()) {
        this.dispatch('importSucceeded', undefined, emptyEvidence(), undefined);
      }
      await this.removeTempFile(tempPath);
      tempPath = '';
      logInfo('import_subscription_ok');
      this.publish();
      return success();
    } catch (error) {
      const err: ClashServiceError = asServiceError(error as Error);
      this.lastErrorCode = err.code;
      this.lastDetailCode = err.detailCode;
      if (tempPath.length > 0) {
        await this.removeTempFile(tempPath);
      }
      if (writtenProfileId.length > 0) {
        await this.removeQuietly(writtenProfileId);
      }
      // 只记录稳定 code/detailCode，便于定位 internal 分支；不含 URL、路径或配置正文。
      logWarn('import_subscription_' + err.code + '_' + (err.detailCode.length > 0 ? err.detailCode : 'no_detail'));
      this.publish();
      return failure(err.code, err.detailCode);
    } finally {
      this.importInFlight = false;
      this.publish();
    }
  }

  /**
   * 导入本地 YAML：系统选择器 uri 只读一次（≤8 MiB），后续与订阅导入一致。
   * 命名冲突由存储层追加序号，不静默覆盖。
   */
  async importLocalYaml(uri: string): Promise<ClashOperationResult> {
    if (!this.initialized) {
      return failure('internal', 'not_initialized');
    }
    if (this.importInFlight) {
      return failure('internal', 'import_in_flight');
    }
    if (this.state === 'preparing' || this.startInFlight || this.stopInFlight ||
      this.applyInFlight || this.scopeInFlight) {
      return failure('internal', 'operation_in_flight');
    }
    const store: ClashProfileStore | undefined = this.store;
    if (store === undefined) {
      return failure('internal', 'not_initialized');
    }
    if (typeof uri !== 'string' || uri.length === 0) {
      return failure('path_rejected', 'invalid_uri');
    }

    this.importInFlight = true;
    this.lastErrorCode = undefined;
    this.lastDetailCode = '';
    this.publish();
    let writtenProfileId: string = '';
    try {
      // 系统选择器授予的 uri 只在本次调用内读取一次；不保留句柄。
      const bytes: Uint8Array = await this.readFileBytes(uri);
      const body: BodyCheckResult = checkBody(bytes);
      if (!body.ok) {
        throw new ClashServiceError('config_invalid',
          body.detailCode !== undefined ? body.detailCode : 'body_rejected');
      }
      if (looksLikeBase64Subscription(body.text)) {
        throw new ClashServiceError('unsupported', 'base64_subscription');
      }
      assertFitsRpcFrame(body.text, 'yaml');
      const profileId: string = await this.allocateProfileId(uri);
      const displayName: string = deriveDisplayName('', fileNameOf(uri), '');

      await this.ensureSession(this.state !== 'connected');
      const validated: ActionOutcome =
        await this.runAction('validateConfig', body.text, VALIDATE_CONFIG_TIMEOUT_MS);
      if (!validated.ok) {
        throw new ClashServiceError('config_invalid',
          validated.detailCode !== undefined ? validated.detailCode : 'validate_failed');
      }

      await store.saveYaml(profileId, body.text);
      writtenProfileId = profileId;
      const counts: ProfileCounts | undefined = await this.readProfileStatistics(profileId);
      if (counts === undefined || (counts.nodeCount <= 0 && counts.providerCount <= 0)) {
        throw new ClashServiceError('config_invalid', 'no_nodes');
      }
      const now: number = Date.now();
      const hasActive: boolean = this.hasValidProfile();
      const input: ClashProfileInput = {
        id: profileId,
        displayName: displayName,
        sourceKind: 'localYaml',
        // provider 数量是近似值：apply 后会以 getProxies 刷新真实节点数，
        // 这里先并入计数以便 provider 型配置能被 hasValidProfile() 识别。
        nodeCount: counts.nodeCount + counts.providerCount,
        groupCount: counts.groupCount,
        contentHash: sha256Hex(body.text),
        updatedAt: now,
        lastAttemptAt: now,
        isActive: !hasActive
      };
      await store.upsertProfile(input);
      writtenProfileId = '';
      await this.reloadProfilesAndSettings();
      this.currentProfileId = this.activeProfileId();
      if (this.state === 'unconfigured' && this.hasValidProfile()) {
        this.dispatch('importSucceeded', undefined, emptyEvidence(), undefined);
      }
      logInfo('import_local_ok');
      this.publish();
      return success();
    } catch (error) {
      const err: ClashServiceError = asServiceError(error as Error);
      this.lastErrorCode = err.code;
      this.lastDetailCode = err.detailCode;
      if (writtenProfileId.length > 0) {
        await this.removeQuietly(writtenProfileId);
      }
      logWarn('import_local_' + err.code);
      this.publish();
      return failure(err.code, err.detailCode);
    } finally {
      this.importInFlight = false;
      this.publish();
    }
  }

  /**
   * 更新订阅：保留 `.prev`，失败保留旧配置与最后成功时间；成功只标记「有新版本」，
   * 不自动 apply。内容与上次相同时标记 unchanged。
   */
  async updateProfile(profileId: string): Promise<ClashOperationResult> {
    if (!this.initialized) {
      return failure('internal', 'not_initialized');
    }
    if (this.updateInFlight) {
      return failure('internal', 'update_in_flight');
    }
    if (this.state === 'preparing' || this.startInFlight || this.stopInFlight ||
      this.applyInFlight || this.scopeInFlight) {
      return failure('internal', 'operation_in_flight');
    }
    const store: ClashProfileStore | undefined = this.store;
    if (store === undefined) {
      return failure('internal', 'not_initialized');
    }
    const record: ClashProfileRecord | undefined = this.findProfile(profileId);
    if (record === undefined) {
      return failure('config_missing', 'profile_not_found');
    }
    if (record.sourceKind !== 'subscription') {
      return failure('config_invalid', 'not_subscription');
    }
    const secret: ClashSubscriptionSecret | undefined = await store.readSubscriptionSecret(profileId);
    if (secret === undefined || secret.url.length === 0) {
      return failure('config_missing', 'subscription_missing');
    }

    this.updateInFlight = true;
    this.lastErrorCode = undefined;
    this.lastDetailCode = '';
    this.publish();
    let tempPath: string = this.profilesDir() + '/.fetch-' + profileId + '.yaml';
    let previousYaml: string | undefined = undefined;
    let fileReplaced: boolean = false;
    try {
      // 旧版本先留在内存，仅在「新文件已写但后续步骤失败」时用于恢复。
      previousYaml = await store.readYaml(profileId);
      await this.ensureDirectory(this.profilesDir());
      const fetched: FetchResult =
        await fetchToFileForProfile(secret.url, profileId, tempPath, this.subscriptionUserAgent());
      if (!fetched.ok) {
        throw new ClashServiceError(mapFetchCode(fetched.errorCode), 'fetch_failed');
      }
      const bytes: Uint8Array = await this.readFileBytes(tempPath);
      const body: BodyCheckResult = checkBody(bytes);
      if (!body.ok) {
        throw new ClashServiceError('config_invalid',
          body.detailCode !== undefined ? body.detailCode : 'body_rejected');
      }
      if (looksLikeBase64Subscription(body.text)) {
        throw new ClashServiceError('unsupported', 'base64_subscription');
      }
      assertFitsRpcFrame(body.text, 'yaml');

      await this.ensureSession(this.state !== 'connected');
      const validated: ActionOutcome =
        await this.runAction('validateConfig', body.text, VALIDATE_CONFIG_TIMEOUT_MS);
      if (!validated.ok) {
        throw new ClashServiceError('config_invalid',
          validated.detailCode !== undefined ? validated.detailCode : 'validate_failed');
      }
      // saveYaml 会把旧文件轮换为 .prev.yaml；失败时新文件不会覆盖旧文件。
      await store.saveYaml(profileId, body.text);
      fileReplaced = true;
      await this.removeTempFile(tempPath);
      tempPath = '';
      const counts: ProfileCounts | undefined = await this.readProfileStatistics(profileId);
      if (counts === undefined || (counts.nodeCount <= 0 && counts.providerCount <= 0)) {
        throw new ClashServiceError('config_invalid', 'no_nodes');
      }
      const contentHash: string = sha256Hex(body.text);
      const unchanged: boolean = record.contentHash.length > 0 &&
        record.contentHash === contentHash;
      const now: number = Date.now();
      const update: ClashProfileUpdate = {
        // provider 数量是近似值：apply 后会以 getProxies 刷新真实节点数，
        // 这里先并入计数以便 provider 型配置能被 hasValidProfile() 识别。
        nodeCount: counts.nodeCount + counts.providerCount,
        groupCount: counts.groupCount,
        contentHash: contentHash,
        updatedAt: now,
        lastAttemptAt: now,
        lastErrorCode: ''
      };
      await store.markUpdated(profileId, update);
      await this.reloadProfilesAndSettings();
      if (record.isActive) {
        this.delays = clearProfile(this.delays, this.nodeNames());
      }
      const result: ClashOperationResult = success();
      if (unchanged) {
        result.unchanged = true;
      }
      logInfo('update_profile_ok');
      this.publish();
      return result;
    } catch (error) {
      const err: ClashServiceError = asServiceError(error as Error);
      this.lastErrorCode = err.code;
      this.lastDetailCode = err.detailCode;
      if (tempPath.length > 0) {
        await this.removeTempFile(tempPath);
      }
      if (fileReplaced && previousYaml !== undefined) {
        try {
          await store.saveYaml(profileId, previousYaml);
          logWarn('update_restored_previous');
        } catch (_) {
          logWarn('update_restore_failed');
        }
      }
      try {
        const failedUpdate: ClashProfileUpdate = {
          lastAttemptAt: Date.now(),
          lastErrorCode: err.code
        };
        await store.markUpdated(profileId, failedUpdate);
        await this.reloadProfilesAndSettings();
      } catch (_) {
        logWarn('update_metadata_failed');
      }
      logWarn('update_profile_' + err.code);
      this.publish();
      return failure(err.code, err.detailCode);
    } finally {
      this.updateInFlight = false;
      this.publish();
    }
  }

  /**
   * 应用配置。已连接时热切换：getConfig→patch→setupConfig；失败重放上一份
   * 成功快照并恢复原 active。未连接时只切换 active，不拉起 TUN、不请求授权。
   */
  async applyProfile(profileId: string): Promise<ClashOperationResult> {
    if (!this.initialized) {
      return failure('internal', 'not_initialized');
    }
    const store: ClashProfileStore | undefined = this.store;
    if (store === undefined) {
      return failure('internal', 'not_initialized');
    }
    const record: ClashProfileRecord | undefined = this.findProfile(profileId);
    if (record === undefined) {
      return failure('config_missing', 'profile_not_found');
    }
    if (record.nodeCount <= 0) {
      return failure('config_invalid', 'no_nodes');
    }
    if (this.state === 'preparing') {
      return failure('internal', 'operation_in_flight');
    }
    if (this.state !== 'connected') {
      try {
        await store.setActive(profileId);
        await this.reloadProfilesAndSettings();
        this.currentProfileId = profileId;
        if (this.state === 'unconfigured' && this.hasValidProfile()) {
          this.dispatch('importSucceeded', undefined, emptyEvidence(), undefined);
        }
        this.publish();
        return success();
      } catch (error) {
        const err: ClashServiceError = asServiceError(error as Error);
        return failure(err.code, err.detailCode);
      }
    }
    if (this.applyInFlight) {
      return failure('internal', 'apply_in_flight');
    }
    if (this.importInFlight || this.updateInFlight) {
      return failure('internal', 'operation_in_flight');
    }

    const epoch: number = this.epoch;
    const previousActive: string = this.activeProfileId();
    let setupSent: boolean = false;
    this.applyInFlight = true;
    this.operation = 'apply';
    this.lastErrorCode = undefined;
    this.lastDetailCode = '';
    this.publish();
    try {
      const setup: SetupParams = await this.buildSetupParams(epoch, record);
      await store.setActive(profileId);
      await this.reloadProfilesAndSettings();
      await this.sendSetupConfig(epoch, setup);
      setupSent = true;
      this.lastAppliedSetup = setup;
      this.appliedProfileId = profileId;
      this.appliedContentHash = record.contentHash;
      this.currentProfileId = profileId;
      this.currentNode = this.resolveActiveNode(record);
      await this.refreshProxies();
      logInfo('apply_profile_ok');
      return success();
    } catch (error) {
      const err: ClashServiceError = asServiceError(error as Error);
      if (this.epoch !== epoch || this.state !== 'connected') {
        // 期间发生断线/重连：状态机接管，避免把重连预算覆盖成 failed。
        if (previousActive.length > 0) {
          try {
            await store.setActive(previousActive);
            await this.reloadProfilesAndSettings();
            this.currentProfileId = previousActive;
          } catch (_) {
            logWarn('apply_restore_active_failed');
          }
        }
        this.publish();
        return failure(err.code, err.detailCode);
      }
      this.lastErrorCode = err.code;
      this.lastDetailCode = err.detailCode;
      if (previousActive.length > 0) {
        try {
          await store.setActive(previousActive);
          await this.reloadProfilesAndSettings();
          this.currentProfileId = previousActive;
        } catch (_) {
          logWarn('apply_restore_active_failed');
        }
      }
      if (!setupSent) {
        // 配置尚未下发：旧配置仍在内核中运行，不能因此停止或标记 failed。
        this.publish();
        return failure(err.code, err.detailCode);
      }
      const replayed: boolean = await this.replayLastSetup(this.epoch);
      if (!replayed) {
        this.failFromConnected(err.code, err.detailCode);
      }
      logWarn('apply_profile_' + err.code);
      this.publish();
      return failure(err.code, err.detailCode);
    } finally {
      this.applyInFlight = false;
      this.operation = undefined;
      this.publish();
    }
  }

  /**
   * 切换节点：只对 Selector 组生效；成功才写 selectedMap，失败不移动标记。
   * 运行中不默认 closeConnections，由自然重连迁移旧连接。
   */
  async selectNode(group: string, node: string): Promise<ClashOperationResult> {
    if (this.state !== 'connected') {
      return failure('rpc_unavailable', 'not_connected');
    }
    const store: ClashProfileStore | undefined = this.store;
    if (store === undefined) {
      return failure('internal', 'not_initialized');
    }
    if (this.applyInFlight || this.scopeInFlight || this.stopInFlight) {
      return failure('internal', 'operation_in_flight');
    }
    if (group.trim().length === 0 || node.trim().length === 0) {
      return failure('internal', 'empty_group_or_node');
    }
    const target: ProxyGroup | undefined = this.findGroup(group);
    if (target === undefined) {
      return failure('internal', 'group_not_found');
    }
    if (target.isAuto) {
      return failure('internal', 'group_not_selectable');
    }
    let memberExists: boolean = false;
    for (let index: number = 0; index < target.all.length; index++) {
      if (target.all[index].name === node) {
        memberExists = true;
        break;
      }
    }
    if (!memberExists) {
      return failure('internal', 'node_not_in_group');
    }

    const outcome: ActionOutcome = await this.runAction('changeProxy',
      buildChangeProxy(group, node), CHANGE_PROXY_TIMEOUT_MS);
    if (!outcome.ok) {
      const code: ProxyErrorCode = outcome.code !== undefined ? outcome.code : 'internal';
      this.lastErrorCode = code;
      this.lastDetailCode = outcome.detailCode !== undefined ? outcome.detailCode : 'change_proxy_failed';
      this.publish();
      return failure(code, this.lastDetailCode);
    }
    const active: ClashProfileRecord | undefined = this.activeProfile();
    if (active !== undefined) {
      try {
        const next: Record<string, string> = {};
        next[group] = node;
        const merged: Record<string, string> = mergeSelectedMap(active.selectedMap, next,
          this.groupNames());
        const selection: ClashProfileUpdate = { selectedMap: merged };
        await store.markUpdated(active.id, selection);
        await this.reloadProfilesAndSettings();
      } catch (error) {
        const err: ClashServiceError = asServiceError(error as Error);
        // changeProxy 已成功但标记未持久化：以内核事实刷新为准，并如实报错。
        this.lastErrorCode = err.code;
        this.lastDetailCode = 'selection_persist_failed';
        await this.refreshProxies();
        this.publish();
        return failure(err.code, this.lastDetailCode);
      }
    }
    this.currentNode = node;
    await this.refreshProxies();
    logInfo('select_node_ok');
    this.publish();
    return success();
  }

  private findGroup(name: string): ProxyGroup | undefined {
    for (let index: number = 0; index < this.groups.length; index++) {
      if (this.groups[index].name === name) {
        return this.groups[index];
      }
    }
    return undefined;
  }

  private groupNames(): string[] {
    const names: string[] = [];
    for (let index: number = 0; index < this.groups.length; index++) {
      names.push(this.groups[index].name);
    }
    return names;
  }

  private nodeNames(): string[] {
    return leafNodeNames(this.proxies);
  }

  /**
   * 单节点测速：先写入 loading 占位，结果 -1 记为失败、>0 记为成功。
   * 结果只进入内存 DelayMap，不落盘。
   */
  async probeDelay(name: string): Promise<ClashOperationResult> {
    if (this.state !== 'connected') {
      return failure('rpc_unavailable', 'not_connected');
    }
    if (this.applyInFlight || this.scopeInFlight || this.stopInFlight) {
      return failure('internal', 'operation_in_flight');
    }
    if (name.trim().length === 0) {
      return failure('internal', 'empty_proxy');
    }
    const url: string = this.effectiveTestUrl();
    const urlKey: string = redactUrl(url);
    if (urlKey === 'invalid-url') {
      return failure('config_invalid', 'invalid_test_url');
    }
    const startedAt: number = Date.now();
    this.delays = applyDelay(this.delays, name, urlKey, 0, startedAt);
    this.loadingDelayNames.add(name);
    this.publish();
    let outcome: ActionOutcome = { ok: false, code: 'internal', detailCode: 'not_run' };
    try {
      outcome = await this.runAction('asyncTestDelay',
        buildAsyncTestDelay(name, url, TEST_DELAY_PARAM_MS), TEST_DELAY_TIMEOUT_MS);
    } finally {
      this.loadingDelayNames.delete(name);
    }
    if (!outcome.ok) {
      const code: ProxyErrorCode = outcome.code !== undefined ? outcome.code : 'internal';
      this.delays = applyDelay(this.delays, name, urlKey, -1, Date.now());
      this.lastErrorCode = code;
      this.lastDetailCode = outcome.detailCode !== undefined ? outcome.detailCode : 'delay_failed';
      this.publish();
      return failure(code, this.lastDetailCode);
    }
    const delay: DelayPayload | undefined = parseDelayPayload(outcome.data);
    if (delay === undefined || delay.value === undefined) {
      this.delays = applyDelay(this.delays, name, urlKey, -1, Date.now());
      return failure('internal', 'invalid_delay_result');
    }
    const value: number = delay.value;
    if (value === 0) {
      // 内核仍在加载：保留 loading 占位，最终值由 delay 事件补全。
      this.delays = applyDelay(this.delays, name, urlKey, 0, Date.now());
      this.publish();
      return success();
    }
    this.delays = applyDelay(this.delays, name, urlKey, value > 0 ? value : -1, Date.now());
    this.publish();
    if (value > 0) {
      return success();
    }
    return failure('timeout', 'delay_failed');
  }

  /**
   * 批量测速：并发 4、逐批派发、可取消；已得结果保留，未完成回到未测。
   */
  async probeAll(): Promise<ClashOperationResult> {
    if (this.state !== 'connected') {
      return failure('rpc_unavailable', 'not_connected');
    }
    if (this.applyInFlight || this.scopeInFlight || this.stopInFlight) {
      return failure('internal', 'operation_in_flight');
    }
    if (this.probeAllInFlight) {
      return success(true);
    }
    const names: string[] = this.nodeNames();
    if (names.length === 0) {
      return failure('internal', 'no_nodes');
    }
    this.probeAllToken += 1;
    const token: number = this.probeAllToken;
    this.probeAllInFlight = true;
    this.publish();
    try {
      const concurrency: number = this.settings !== undefined
        ? Math.min(MAX_BATCH_CONCURRENCY, Math.max(DEFAULT_BATCH_CONCURRENCY,
          this.settings.batchConcurrency))
        : DEFAULT_BATCH_CONCURRENCY;
      const batches: string[][] = planBatch(names, concurrency);
      for (let batchIndex: number = 0; batchIndex < batches.length; batchIndex++) {
        if (token !== this.probeAllToken || this.state !== 'connected') {
          break;
        }
        const batch: string[] = batches[batchIndex];
        const tasks: Promise<void>[] = [];
        for (let index: number = 0; index < batch.length; index++) {
          tasks.push(this.probeOne(batch[index], token));
        }
        await Promise.all(tasks);
      }
      if (token === this.probeAllToken && this.state === 'connected') {
        logInfo('probe_all_done');
      }
    } finally {
      if (token === this.probeAllToken) {
        this.delays = cancel(this.delays);
      }
      this.probeAllInFlight = false;
      this.publish();
    }
    return success();
  }

  private async probeOne(name: string, token: number): Promise<void> {
    if (token !== this.probeAllToken || this.state !== 'connected') {
      return;
    }
    const url: string = this.effectiveTestUrl();
    const urlKey: string = redactUrl(url);
    if (urlKey === 'invalid-url') {
      return;
    }
    this.delays = applyDelay(this.delays, name, urlKey, 0, Date.now());
    this.loadingDelayNames.add(name);
    this.publish();
    try {
      const outcome: ActionOutcome = await this.runAction('asyncTestDelay',
        buildAsyncTestDelay(name, url, TEST_DELAY_PARAM_MS), TEST_DELAY_TIMEOUT_MS);
      if (token !== this.probeAllToken) {
        return;
      }
      if (!outcome.ok) {
        this.delays = applyDelay(this.delays, name, urlKey, -1, Date.now());
        return;
      }
      const delay: DelayPayload | undefined = parseDelayPayload(outcome.data);
      const value: number = delay !== undefined && delay.value !== undefined ? delay.value : -1;
      this.delays = applyDelay(this.delays, name, urlKey, value >= 0 ? value : -1, Date.now());
    } finally {
      this.loadingDelayNames.delete(name);
      this.publish();
    }
  }

  /** 取消批量测速：未完成项回到 idle，已完成结果保留。 */
  cancelProbeAll(): void {
    this.probeAllToken += 1;
    this.delays = cancel(this.delays);
    this.loadingDelayNames.clear();
    this.probeAllInFlight = false;
    this.publish();
  }

  /** 清空全部延迟结果。 */
  clearDelays(): void {
    // 使在途测速结果失效，避免清空后又被旧响应写回。
    this.probeAllToken += 1;
    this.probeAllInFlight = false;
    this.delays = clearAll();
    this.loadingDelayNames.clear();
    this.publish();
  }

  /**
   * 删除 profile：active 且在运行先停止；清 DelayMap；全部删完回到 unconfigured。
   * 残留只以标签返回，不拼接路径。
   */
  async removeProfile(profileId: string): Promise<ClashOperationResult> {
    if (!this.initialized) {
      return failure('internal', 'not_initialized');
    }
    if (this.startInFlight || this.stopInFlight || this.state === 'preparing' ||
      this.importInFlight || this.updateInFlight || this.applyInFlight || this.scopeInFlight) {
      return failure('internal', 'operation_in_flight');
    }
    const store: ClashProfileStore | undefined = this.store;
    if (store === undefined) {
      return failure('internal', 'not_initialized');
    }
    const record: ClashProfileRecord | undefined = this.findProfile(profileId);
    if (record === undefined) {
      return failure('config_missing', 'profile_not_found');
    }
    const wasActive: boolean = record.isActive;
    if (wasActive && (this.state === 'connected' || this.isState('preparing'))) {
      const stopped: ClashOperationResult = await this.stop();
      if (stopped.detailCode === 'stopped_with_warning') {
        // 停止有残留时仍继续删除；删除结果会单独报告残留标签。
        logWarn('delete_after_stop_warning');
      }
    }
    const knownNames: string[] = this.nodeNames();
    let removal: ClashProfileRemovalResult | undefined = undefined;
    try {
      const options: ClashRemoveProfileOptions = {
        proxyRunning: false,
        purgeDelayedResults: (_profileId: string): void => {
          this.delays = clearProfile(this.delays, knownNames);
        }
      };
      removal = await store.removeProfile(profileId, options);
    } catch (error) {
      const err: ClashServiceError = asServiceError(error as Error);
      this.lastErrorCode = err.code;
      this.lastDetailCode = err.detailCode;
      this.publish();
      return failure(err.code, err.detailCode);
    }
    if (removal === undefined || !removal.removed) {
      const residue: string = removal !== undefined && removal.residue.length > 0
        ? removal.residue[0]
        : 'remove_failed';
      this.lastErrorCode = 'internal';
      this.lastDetailCode = residue;
      this.publish();
      return failure('internal', residue);
    }
    await this.reloadProfilesAndSettings();
    if (this.currentProfileId === profileId) {
      this.currentProfileId = this.activeProfileId();
    }
    if (this.appliedProfileId === profileId) {
      this.appliedProfileId = '';
      this.appliedContentHash = '';
      this.lastAppliedSetup = undefined;
    }
    if (this.profiles.length === 0) {
      this.groups = [];
      this.proxies = {};
      this.currentNode = '';
      if (this.state !== 'unconfigured') {
        this.dispatch('profileRemoved', undefined, emptyEvidence(), undefined);
      }
    } else if (this.state === 'unconfigured' && this.hasValidProfile()) {
      // 从「无 profile」恢复为「有配置但未启动」。
      this.dispatch('importSucceeded', undefined, emptyEvidence(), undefined);
    }
    logInfo('remove_profile_ok');
    this.publish();
    return success();
  }

  /**
   * 当前生效的订阅 User-Agent；未初始化或旧设置缺字段时返回默认值。
   * 返回值已归一，不含控制字符，可直接放入请求头。
   */
  subscriptionUserAgent(): string {
    if (this.settings === undefined) {
      return DEFAULT_SUBSCRIPTION_UA;
    }
    return normalizeSubscriptionUserAgent(this.settings.subscriptionUserAgent);
  }

  /**
   * 保存订阅 User-Agent。归一失败不报错（回退默认值），只有 Preferences 写入失败
   * 才返回稳定错误码；成功与失败都不记录原始值或 URL。
   */
  async setSubscriptionUserAgent(value: string): Promise<ClashOperationResult> {
    const store: ClashProfileStore | undefined = this.store;
    if (store === undefined || this.settings === undefined) {
      return failure('internal', 'not_initialized');
    }
    const normalized: string = normalizeSubscriptionUserAgent(value);
    try {
      const next: ClashStoreSettings = copySettings(this.settings);
      next.subscriptionUserAgent = normalized;
      this.settings = await store.saveSettings(next);
      this.publish();
      return success();
    } catch (error) {
      const err: ClashServiceError = asServiceError(error as Error);
      return failure(err.code, err.detailCode);
    }
  }

  /**
   * 切换代理范围。已连接时必须重建 VpnConnection：tun.stop → tun.start；
   * 新范围失败则回滚旧 scope 并尝试恢复；两次都失败收敛为 failed(tun_start_failed)。
   * 未连接时只保存偏好，不重建 TUN。
   */
  async setScope(scope: ProxyScope): Promise<ClashOperationResult> {
    if (scope !== 'global' && scope !== 'harlgramOnly') {
      return failure('internal', 'invalid_scope');
    }
    const store: ClashProfileStore | undefined = this.store;
    if (store === undefined || this.settings === undefined) {
      return failure('internal', 'not_initialized');
    }
    if (this.scopeInFlight || this.applyInFlight || this.startInFlight || this.stopInFlight ||
      this.importInFlight || this.updateInFlight) {
      return failure('internal', 'operation_in_flight');
    }
    if (this.state === 'preparing') {
      return failure('internal', 'operation_in_flight');
    }
    const previousScope: ProxyScope = this.effectiveScope();
    if (previousScope === scope) {
      return success();
    }
    if (this.state !== 'connected') {
      try {
        const next: ClashStoreSettings = copySettings(this.settings);
        next.scope = scope;
        this.settings = await store.saveSettings(next);
        this.publish();
        return success();
      } catch (error) {
        const err: ClashServiceError = asServiceError(error as Error);
        return failure(err.code, err.detailCode);
      }
    }

    const epoch: number = this.epoch;
    this.scopeInFlight = true;
    this.operation = 'scope';
    this.lastErrorCode = undefined;
    this.lastDetailCode = '';
    this.publish();
    try {
      const client: ClashRpcClient | undefined = this.client;
      if (client === undefined) {
        throw new ClashServiceError('rpc_unavailable', 'not_connected');
      }
      const raw: JsonPayload = await client.request('tun.stop', undefined, TUN_STOP_TIMEOUT_MS);
      const body: object | undefined = parseObjectPayload(raw);
      if (body === undefined) {
        throw new ClashServiceError('tun_start_failed', 'invalid_stop_result');
      }
      const payload: TunStopPayload = body as TunStopPayload;
      if (payload.stopped !== true) {
        throw new ClashServiceError('tun_start_failed', 'stop_not_confirmed');
      }
      const releasedBody: object | undefined = asObject(payload.released);
      if (releasedBody === undefined) {
        throw new ClashServiceError('tun_start_failed', 'stop_release_unknown');
      }
      const released: TunStopReleased = releasedBody as TunStopReleased;
      if (released.tun !== true) {
        throw new ClashServiceError('tun_start_failed', 'tun_not_released');
      }
    } catch (error) {
      const err: ClashServiceError = asServiceError(error as Error);
      this.lastErrorCode = err.code;
      this.lastDetailCode = err.detailCode;
      this.operation = undefined;
      this.scopeInFlight = false;
      this.publish();
      return failure(err.code, err.detailCode);
    }

    try {
      // 新 scope 先写内存，再交给 tun.start；持久化放在成功后。
      const candidate: ClashStoreSettings = copySettings(this.settings);
      candidate.scope = scope;
      this.settings = candidate;
      await this.rebuildSessionForTun(epoch);
      const tun: TunStartOutcome = await this.startTun(epoch);
      this.ensureTunEvidence(tun);
      const persisted: ClashStoreSettings = await store.saveSettings(candidate);
      this.settings = persisted;
      this.operation = undefined;
      logInfo('scope_applied');
      this.publish();
      return success();
    } catch (error) {
      const err: ClashServiceError = asServiceError(error as Error);
      if (this.epoch !== epoch || this.state !== 'connected') {
        // 期间断线/重连：状态机接管，不覆盖重连预算；内存 scope 回退到旧值。
        const revert: ClashStoreSettings = copySettings(this.settings);
        revert.scope = previousScope;
        this.settings = revert;
        this.publish();
        return failure(err.code, err.detailCode);
      }
      this.lastErrorCode = err.code;
      this.lastDetailCode = err.detailCode;
      // 回滚旧 scope 并重建 TUN；TUN 已停时不能让状态继续假装 connected。
      const rollback: ClashStoreSettings = copySettings(this.settings);
      rollback.scope = previousScope;
      this.settings = rollback;
      let restored: boolean = false;
      try {
        await this.rebuildSessionForTun(epoch);
        const restoredTun: TunStartOutcome = await this.startTun(epoch);
        this.ensureTunEvidence(restoredTun);
        restored = true;
      } catch (_) {
        restored = false;
      }
      if (restored) {
        try {
          this.settings = await store.saveSettings(rollback);
        } catch (_) {
          logWarn('scope_persist_rollback_failed');
        }
        logWarn('scope_rollback_ok');
      } else {
        this.failFromConnected('tun_start_failed', 'scope_rollback_failed');
      }
      this.publish();
      return failure(err.code, err.detailCode);
    } finally {
      this.scopeInFlight = false;
      this.operation = undefined;
      this.publish();
    }
  }

  // -------------------------------------------------------------------------
  // 文件与 profile id 辅助
  // -------------------------------------------------------------------------

  private async allocateProfileId(seed: string): Promise<string> {
    const base: string = deriveProfileId(redactUrlSafe(seed) + '-' + String(Date.now()));
    let candidate: string = base;
    for (let attempt: number = 0; attempt < MAX_PROFILE_ID_ATTEMPTS; attempt++) {
      const taken: boolean = this.findProfile(candidate) !== undefined ||
        await this.profileFileExists(candidate);
      if (!taken) {
        return candidate;
      }
      const suffix: string = '-' + String(attempt + 2);
      const head: string = base.length + suffix.length > 64
        ? base.substring(0, 64 - suffix.length)
        : base;
      candidate = head + suffix;
    }
    return base;
  }

  private async ensureDirectory(path: string): Promise<void> {
    try {
      if (await fileIo.access(path)) {
        return;
      }
      await fileIo.mkdir(path, true);
    } catch (_) {
      // 并发创建视为成功；仍不可用则由后续写入给出 write_failed。
      try {
        if (await fileIo.access(path)) {
          return;
        }
      } catch (_) {
        throw new ClashServiceError('internal', 'directory_unavailable');
      }
      throw new ClashServiceError('internal', 'directory_unavailable');
    }
  }

  /**
   * 读取选择器 uri 或沙箱路径；只读一次，超过 8 MiB 直接拒绝。
   * 句柄只在本次调用内存在。
   */
  private async readFileBytes(path: string): Promise<Uint8Array> {
    let file: fileIo.File | undefined = undefined;
    try {
      file = await fileIo.open(path, fileIo.OpenMode.READ_ONLY);
      const info: fileIo.Stat = await fileIo.stat(file.fd);
      if (info.size <= 0) {
        throw new ClashServiceError('config_invalid', 'empty_file');
      }
      if (info.size > MAX_LOCAL_YAML_BYTES) {
        throw new ClashServiceError('config_invalid', 'too_large');
      }
      const buffer: ArrayBuffer = new ArrayBuffer(info.size);
      const bytes: Uint8Array = new Uint8Array(buffer);
      let offset: number = 0;
      // 单次 read 不保证填满整个缓冲区；按剩余长度循环到 EOF。
      while (offset < info.size) {
        const chunk: ArrayBuffer = new ArrayBuffer(info.size - offset);
        const count: number = await fileIo.read(file.fd, chunk);
        if (count <= 0) {
          break;
        }
        bytes.set(new Uint8Array(chunk, 0, count), offset);
        offset += count;
      }
      if (offset <= 0) {
        throw new ClashServiceError('config_invalid', 'empty_file');
      }
      return offset === info.size ? bytes : bytes.subarray(0, offset);
    } catch (error) {
      if (error instanceof ClashServiceError) {
        throw error as ClashServiceError;
      }
      throw new ClashServiceError('path_rejected', 'read_failed');
    } finally {
      if (file !== undefined) {
        try {
          await fileIo.close(file);
        } catch (_) {
          logWarn('file_close_failed');
        }
      }
    }
  }

  private async removeTempFile(path: string): Promise<void> {
    if (path.length === 0) {
      return;
    }
    try {
      await fileIo.unlink(path);
    } catch (_) {
      logWarn('temp_remove_failed');
    }
  }

  private async removeQuietly(profileId: string): Promise<void> {
    const store: ClashProfileStore | undefined = this.store;
    if (store === undefined) {
      return;
    }
    try {
      await store.removeProfile(profileId);
      await this.reloadProfilesAndSettings();
    } catch (_) {
      logWarn('profile_cleanup_failed');
    }
  }

  // -------------------------------------------------------------------------
  // 释放
  // -------------------------------------------------------------------------

  /** 应用退出时释放客户会话与长时任务；可重复调用。 */
  async dispose(): Promise<void> {
    this.desiredRunning = false;
    this.clearPreparingBudget();
    if (this.sessionRebuildTimer >= 0) {
      clearTimeout(this.sessionRebuildTimer);
      this.sessionRebuildTimer = -1;
    }
    this.keepAlive.disable();
    this.disposeClient();
    this.coreInitialized = false;
    const files: ClashSessionFiles | undefined = this.sessionFiles;
    if (files !== undefined) {
      try {
        await files.cleanup();
      } catch (_) {
        logWarn('dispose_cleanup_failed');
      }
    }
    this.listeners = [];
    this.initialized = false;
    this.initWork = undefined;
  }
}

// ---------------------------------------------------------------------------
// 模块级单例与薄包装
// ---------------------------------------------------------------------------

/** 由 Index 持有并传入 ProxyPage；避免页面重建导致会话重建。 */
export const clashService: ClashService = ClashService.get();

/** 订阅拉取的薄包装；失败码只暴露稳定字符串，不含 URL。 */
function fetchToFileForProfile(url: string, profileId: string,
  targetPath: string, userAgentValue: string): Promise<FetchResult> {
  return fetchToFile(url, profileId, targetPath, undefined, userAgentValue);
}

function mapFetchCode(code: FetchErrorCode | undefined): ProxyErrorCode {
  switch (code) {
    case 'unsupported':
      return 'unsupported';
    case 'timeout':
      return 'timeout';
    case 'too_large':
    case 'http_status':
    case 'network':
    case 'redirect_limit':
    case 'invalid_url':
      return 'config_invalid';
    case 'invalid_profile':
    case 'invalid_target':
    case 'busy':
    case 'write_failed':
    case 'internal':
    default:
      return 'internal';
  }
}

function parseDelayPayload(data: JsonPayload | undefined): DelayPayload | undefined {
  const body: object | undefined = parseObjectPayload(data);
  if (body === undefined) {
    return undefined;
  }
  const payload: DelayPayload = body as DelayPayload;
  return payload;
}

function fileNameOf(uri: string): string {
  let text: string = uri;
  const queryIndex: number = text.indexOf('?');
  if (queryIndex >= 0) {
    text = text.substring(0, queryIndex);
  }
  const fragmentIndex: number = text.indexOf('#');
  if (fragmentIndex >= 0) {
    text = text.substring(0, fragmentIndex);
  }
  const slashIndex: number = text.lastIndexOf('/');
  const name: string = slashIndex >= 0 ? text.substring(slashIndex + 1) : text;
  try {
    return decodeURIComponent(name);
  } catch (_) {
    return name;
  }
}

/** `redactUrl` 对非 URL 种子返回 invalid-url；派生 id 时回退固定串。 */
function redactUrlSafe(seed: string): string {
  const redacted: string = redactUrl(seed);
  return redacted === 'invalid-url' ? 'profile' : redacted;
}

/**
 * 订阅显示名只取脱敏后的主机名：不带 scheme、userinfo、路径、查询或端口。
 * `redactUrl` 已保证输出安全；这里再去掉展示层不需要的 scheme/端口。
 */
function displayNameHintFromUrl(url: string): string {
  const redacted: string = redactUrl(url);
  if (redacted === 'invalid-url') {
    return '';
  }
  const schemeIndex: number = redacted.indexOf('://');
  const hostPort: string = schemeIndex >= 0 ? redacted.substring(schemeIndex + 3) : redacted;
  if (hostPort.startsWith('[')) {
    const closeIndex: number = hostPort.indexOf(']');
    return closeIndex > 1 ? hostPort.substring(1, closeIndex) : hostPort;
  }
  const colonIndex: number = hostPort.indexOf(':');
  return colonIndex > 0 ? hostPort.substring(0, colonIndex) : hostPort;
}