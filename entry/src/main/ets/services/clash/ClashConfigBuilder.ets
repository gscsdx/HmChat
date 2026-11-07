/**
 * Clash 配置构建与内存回滚（任务 T-S2-08，设计 §9.3、§10.4、§10.5）。
 *
 * 职责：
 * - `getConfig`：按设计 §9.3 用 `core.action` 读取配置；`data` 是**已解析的文件路径**，
 *   本模块不认识 profileId→path 规则，也不拼接路径（由 `ClashProfileStore` 提供）。
 * - `build`：`JSON.parse` → `ClashConfigPatch.patch` → `SetupParams{config,selected-map,test-url}`。
 *   `patch` 之前解析失败按 `config_invalid` 处理，不写任何文件。
 * - `rollback`：用内存快照重新 patch 并回放旧 `SetupParams`；快照只存在本实例内存中，
 *   不落盘、不写 Preferences、不进入日志。
 *
 * 安全边界：
 * - 配置正文（`RawConfig`）、节点名、路径都不写日志；错误对象只带稳定码与细分码。
 * - 诊断只暴露计数与 patch 的固定告警码，不暴露配置内容。
 * - 不引用 `ClashProfileStore`、Telegram、媒体网络或文件/网络 Kit；本模块只依赖
 *   Action 通道、配置 patch 与领域类型。
 *
 * 快照语义（设计 §10.5）：
 * - 每次 `build` 成功都把本次输入记为“当前快照”，并把上一份当前快照保留为一次性
 *   “回退目标”。
 * - `rollback()` 优先回放回退目标（应用新配置失败时恢复旧配置）；没有回退目标时回放
 *   当前快照，保证重复调用结果稳定。
 * - 快照字段固定为 `{rawConfigJson, selectedMap, testUrl, scope, profileId}`；`rawConfigJson`
 *   是 patch 前的原文，回放时重新解析并 patch，因此不会把节点凭据之外的派生状态带出去。
 */

import {
  ActionResultEnvelope,
  JsonPayload,
  ProxyScope,
  RawConfig,
  SetupParams
} from '../../model/ClashModels';
import { ProxyErrorCode } from '../../model/ClashError';
import {
  ClashConfigPatchResult,
  patchWithDiagnostics
} from '../../model/ClashConfigPatch';
import { isValidProfileId } from '../../model/ClashProfileRules';
import { ClashBridgeError, clashCoreBridge } from './ClashCoreBridge';

// ---------------------------------------------------------------------------
// 常量（超时与设计 §5.4 / ClashActionFactory.TIMEOUT_MS.getConfig 一致）
// ---------------------------------------------------------------------------

/** `getConfig` 的客户端上限：20 s（任务 T-S2-08）。 */
export const GET_CONFIG_TIMEOUT_MS: number = 20000;

/** 设计 §10.4：用户未提供或提供非法测速地址时的默认值（非敏感常量）。 */
export const DEFAULT_TEST_URL: string = 'https://www.gstatic.com/generate_204';

/** 沙箱内绝对路径上限；只做防御，不做路径归一化。 */
const MAX_PROFILE_PATH_LENGTH: number = 4096;
const MAX_TEST_URL_LENGTH: number = 2048;
const MAX_SELECTED_ENTRIES: number = 512;
const MAX_GROUP_NAME_LENGTH: number = 128;
const MAX_NODE_NAME_LENGTH: number = 256;

/** 与 ClashProfileStore 相同的控制字符集合（含 NUL）。 */
const CONTROL_CHARACTER_PATTERN: RegExp =
  /[\u0000-\u001F\u007F-\u009F\u200B-\u200F\u202A-\u202E\u2066-\u2069\uFEFF]/;

// ---------------------------------------------------------------------------
// 类型
// ---------------------------------------------------------------------------

/** 本模块对外的稳定错误码，全部取自 ClashError 的权威码表。 */
export type ClashConfigBuilderErrorCode =
  | 'config_invalid'
  | 'path_rejected'
  | 'timeout'
  | 'core_missing'
  | 'core_load_failed'
  | 'core_init_failed'
  | 'internal';

/**
 * 结构化构建错误：`message` 只等于稳定码，调用方只能依赖 `code` / `detailCode`。
 * 配置正文、路径、节点名与底层错误文本一律不进入错误对象。
 */
export class ClashConfigBuilderError extends Error {
  readonly code: ClashConfigBuilderErrorCode;
  readonly detailCode: string;

  constructor(code: ClashConfigBuilderErrorCode, detailCode: string = '') {
    super(code);
    this.name = 'ClashConfigBuilderError';
    this.code = code;
    this.detailCode = detailCode;
  }
}

/**
 * 只读 Action 通道；默认实现是扩展进程的 `ClashCoreBridge`。
 * 抽出接口是为了让宿主侧测试可以注入假通道，而不改变生产路径。
 */
export interface ClashActionChannel {
  action(method: string, data?: string, timeoutMs?: number): Promise<ActionResultEnvelope>;
}

/** 最近一次成功构建的输入快照；仅内存，字段与设计 §10.5 一致。 */
export interface ClashConfigSnapshot {
  /** `getConfig` 返回的 patch 前原文；只在内存中，不写盘、不输出。 */
  rawConfigJson: string;
  selectedMap: Record<string, string>;
  testUrl: string;
  scope: ProxyScope;
  profileId: string;
}

/** 诊断计数：只含次数，不含任何配置内容或路径。 */
export interface ClashConfigBuilderCounters {
  getConfigRequests: number;
  getConfigFailures: number;
  buildRequests: number;
  buildFailures: number;
  configInvalid: number;
  pathRejected: number;
  timeouts: number;
  coreFailures: number;
  rollbacks: number;
  rollbackFallbacks: number;
  rollbackMisses: number;
  testUrlFallbacks: number;
}

// ---------------------------------------------------------------------------
// 纯函数：路径、测速地址与 selectedMap 校验
// ---------------------------------------------------------------------------

/**
 * 只接受 `ClashProfileStore` 已解析的沙箱绝对路径。
 * 拒绝空串、控制字符、相对路径与 `..` 段；不拼接、不 normalize。
 */
function isValidProfilePath(path: string): boolean {
  if (typeof path !== 'string') {
    return false;
  }
  if (path.length === 0 || path.length > MAX_PROFILE_PATH_LENGTH) {
    return false;
  }
  if (path !== path.trim() || CONTROL_CHARACTER_PATTERN.test(path)) {
    return false;
  }
  if (!path.startsWith('/')) {
    return false;
  }
  const segments: string[] = path.split('/');
  for (let index: number = 0; index < segments.length; index++) {
    if (segments[index] === '..') {
      return false;
    }
  }
  return true;
}

/**
 * 测速地址只接受完整 `http(s)://` 文本；非法值回退默认（设计 §10.4）。
 * 不抛错：测速地址是用户可改的非敏感设置，非法值不应阻断配置应用。
 */
export function normalizeTestUrl(value: string): string {
  if (typeof value !== 'string') {
    return DEFAULT_TEST_URL;
  }
  if (value.length === 0 || value.length > MAX_TEST_URL_LENGTH) {
    return DEFAULT_TEST_URL;
  }
  if (value !== value.trim() || CONTROL_CHARACTER_PATTERN.test(value)) {
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

/** 组名/节点名的基本安全校验；与 ClashProfileStore 的规则保持一致。 */
function isSafeLabel(value: string, maxLength: number): boolean {
  if (typeof value !== 'string' || value.length === 0 || value.length > maxLength) {
    return false;
  }
  if (value !== value.trim() || CONTROL_CHARACTER_PATTERN.test(value)) {
    return false;
  }
  return value.indexOf('://') < 0;
}

/**
 * 校验并复制 selectedMap；任何非法项返回 null，由调用方收敛到 `config_invalid`。
 * 空对象合法（用户尚未选择节点，内核会按配置默认出口运行）。
 */
function copySelectedMap(source: Record<string, string>): Record<string, string> | null {
  if (source === null || source === undefined || typeof source !== 'object' || Array.isArray(source)) {
    return null;
  }
  const groups: string[] = Object.keys(source);
  if (groups.length > MAX_SELECTED_ENTRIES) {
    return null;
  }
  const copy: Record<string, string> = {};
  for (let index: number = 0; index < groups.length; index++) {
    const group: string = groups[index];
    const node: string = source[group];
    if (!isSafeLabel(group, MAX_GROUP_NAME_LENGTH) || !isSafeLabel(node, MAX_NODE_NAME_LENGTH)) {
      return null;
    }
    copy[group] = node;
  }
  return copy;
}

/** 浅拷贝字符串映射；用于让快照与返回给调用方的 SetupParams 互不共享引用。 */
function cloneStringMap(source: Record<string, string>): Record<string, string> {
  const copy: Record<string, string> = {};
  const keys: string[] = Object.keys(source);
  for (let index: number = 0; index < keys.length; index++) {
    copy[keys[index]] = source[keys[index]];
  }
  return copy;
}

/**
 * 把握手结果里的 `data` 统一成配置 JSON 原文。
 * - 字符串：非空即原文（`getConfig` 的真实返回通常是对象，两种都兼容）；
 * - 对象：序列化为 JSON 文本，供 `build` 统一走 `JSON.parse` 路径；
 * - 其它标量/数组/空值：返回 null，按缺失结果处理。
 */
function readConfigJson(data: JsonPayload): string | null {
  if (typeof data === 'string') {
    return data.length > 0 ? data : null;
  }
  if (data === null || typeof data !== 'object' || Array.isArray(data)) {
    return null;
  }
  try {
    const encoded: string = JSON.stringify(data);
    return encoded.length > 0 ? encoded : null;
  } catch {
    return null;
  }
}

// ---------------------------------------------------------------------------
// 构建器
// ---------------------------------------------------------------------------

export class ClashConfigBuilder {
  private readonly channel: ClashActionChannel;
  /** 最近一次成功 build 的输入；rollback 的主体。 */
  private current: ClashConfigSnapshot | null = null;
  /** 上一条当前快照；只在应用新配置失败时使用一次。 */
  private fallback: ClashConfigSnapshot | null = null;
  private lastWarnings: string[] = [];
  private lastErrorCode: ProxyErrorCode | null = null;
  private counters: ClashConfigBuilderCounters = {
    getConfigRequests: 0,
    getConfigFailures: 0,
    buildRequests: 0,
    buildFailures: 0,
    configInvalid: 0,
    pathRejected: 0,
    timeouts: 0,
    coreFailures: 0,
    rollbacks: 0,
    rollbackFallbacks: 0,
    rollbackMisses: 0,
    testUrlFallbacks: 0
  };

  constructor(channel: ClashActionChannel = clashCoreBridge) {
    this.channel = channel;
  }

  /**
   * 读取配置文件并返回 `RawConfig` 的 JSON 原文。
   *
   * @param profilePath `ClashProfileStore` 已解析的沙箱绝对路径；本模块不拼接路径。
   * @throws ClashConfigBuilderError 稳定码：`path_rejected` / `config_invalid` /
   *   `timeout` / `core_missing` / `core_load_failed` / `core_init_failed` / `internal`。
   */
  async getConfig(profilePath: string): Promise<string> {
    this.counters.getConfigRequests += 1;
    try {
      if (!isValidProfilePath(profilePath)) {
        throw this.fail('path_rejected', 'invalid_path');
      }

      // 设计 §9.3：data 是文件路径字符串；20 s 由本模块显式给出。
      const result: ActionResultEnvelope = await this.invokeGetConfig(profilePath);

      if (result.code !== 0) {
        throw this.fail('config_invalid', 'code_nonzero');
      }
      const rawConfigJson: string | null = readConfigJson(result.data);
      if (rawConfigJson === null) {
        throw this.fail('config_invalid', 'missing_result');
      }
      this.lastErrorCode = null;
      return rawConfigJson;
    } catch (error) {
      this.counters.getConfigFailures += 1;
      throw error as Error;
    }
  }

  /**
   * 读取 → 解析 → 白名单 patch → 组装 `SetupParams`，并把本次输入记为当前内存快照。
   *
   * @param profileId 快照身份（用于诊断与回放归属），必须满足 `PROFILE_ID_PATTERN`。
   * @param profilePath 已解析的沙箱绝对路径，原样交给 `getConfig`。
   * @param selectedMap 组名 → 节点名；空对象合法，空名称非法。
   * @param testUrl 测速地址；非法值回退 `DEFAULT_TEST_URL`，不抛错。
   * @param scope 代理范围，原样记入快照（不参与 SetupParams）。
   * @throws ClashConfigBuilderError 稳定码；`JSON.parse` 或 patch 失败均为 `config_invalid`，
   *   且不会写任何文件。
   */
  async build(
    profileId: string,
    profilePath: string,
    selectedMap: Record<string, string>,
    testUrl: string,
    scope: ProxyScope
  ): Promise<SetupParams> {
    this.counters.buildRequests += 1;
    try {
      if (!isValidProfileId(profileId)) {
        throw this.fail('config_invalid', 'invalid_profile_id');
      }
      if (scope !== 'global' && scope !== 'harlgramOnly') {
        throw this.fail('internal', 'invalid_scope');
      }
      const map: Record<string, string> | null = copySelectedMap(selectedMap);
      if (map === null) {
        throw this.fail('config_invalid', 'invalid_selected_map');
      }
      const effectiveTestUrl: string = normalizeTestUrl(testUrl);
      if (effectiveTestUrl !== testUrl) {
        this.counters.testUrlFallbacks += 1;
      }

      const rawConfigJson: string = await this.getConfig(profilePath);

      // 设计 §10.4：先解析为开放对象；解析失败不产生任何文件写入。
      let parsed: RawConfig | null = null;
      try {
        parsed = JSON.parse(rawConfigJson) as RawConfig;
      } catch {
        parsed = null;
      }
      if (parsed === null) {
        throw this.fail('config_invalid', 'parse_failed');
      }

      let patched: RawConfig = {};
      let warnings: string[] = [];
      try {
        const result: ClashConfigPatchResult = patchWithDiagnostics(parsed);
        patched = result.config;
        warnings = result.warnings;
      } catch {
        throw this.fail('config_invalid', 'patch_failed');
      }

      const params: SetupParams = {
        config: patched,
        'selected-map': map,
        'test-url': effectiveTestUrl
      };
      const snapshot: ClashConfigSnapshot = {
        rawConfigJson: rawConfigJson,
        selectedMap: cloneStringMap(map),
        testUrl: effectiveTestUrl,
        scope: scope,
        profileId: profileId
      };
      // 只保留最近两份：当前用于重复回放，上一份用于应用失败时恢复旧配置。
      this.fallback = this.current;
      this.current = snapshot;
      this.lastWarnings = warnings;
      this.lastErrorCode = null;
      return params;
    } catch (error) {
      this.counters.buildFailures += 1;
      throw error as Error;
    }
  }

  /**
   * 回放内存中的旧 `SetupParams`。
   *
   * 优先使用上一份快照（应用新配置失败时恢复旧配置），没有上一份时回放当前快照。
   * 回放不读取文件、不写盘，也不保留任何配置正文的副本到返回值之外。
   *
   * @returns 回放得到的 `SetupParams`；没有任何快照时返回 null（计数 `rollbackMisses`）。
   * @throws ClashConfigBuilderError `config_invalid`（快照原文无法再解析/patch）。
   */
  rollback(): SetupParams | null {
    const useFallback: boolean = this.fallback !== null;
    const target: ClashConfigSnapshot | null = useFallback ? this.fallback : this.current;
    if (target === null) {
      this.counters.rollbackMisses += 1;
      return null;
    }

    let parsed: RawConfig | null = null;
    try {
      parsed = JSON.parse(target.rawConfigJson) as RawConfig;
    } catch {
      parsed = null;
    }
    if (parsed === null) {
      throw this.fail('config_invalid', 'rollback_parse_failed');
    }

    let patched: RawConfig = {};
    let warnings: string[] = [];
    try {
      const result: ClashConfigPatchResult = patchWithDiagnostics(parsed);
      patched = result.config;
      warnings = result.warnings;
    } catch {
      throw this.fail('config_invalid', 'rollback_patch_failed');
    }

    const params: SetupParams = {
      config: patched,
      'selected-map': cloneStringMap(target.selectedMap),
      'test-url': target.testUrl
    };
    if (useFallback) {
      this.current = target;
      this.fallback = null;
      this.counters.rollbackFallbacks += 1;
    }
    this.counters.rollbacks += 1;
    this.lastWarnings = warnings;
    this.lastErrorCode = null;
    return params;
  }

  /** 丢弃内存快照；用于停止代理、切换账号或删除 profile 后清空凭据派生数据。 */
  clearSnapshot(): void {
    this.current = null;
    this.fallback = null;
    this.lastWarnings = [];
    this.lastErrorCode = null;
  }

  /** 当前是否持有可回放快照；不暴露快照内容。 */
  hasSnapshot(): boolean {
    return this.current !== null || this.fallback !== null;
  }

  /** 计数快照（新对象，调用方不能借此修改内部计数）。 */
  getCounters(): ClashConfigBuilderCounters {
    return {
      getConfigRequests: this.counters.getConfigRequests,
      getConfigFailures: this.counters.getConfigFailures,
      buildRequests: this.counters.buildRequests,
      buildFailures: this.counters.buildFailures,
      configInvalid: this.counters.configInvalid,
      pathRejected: this.counters.pathRejected,
      timeouts: this.counters.timeouts,
      coreFailures: this.counters.coreFailures,
      rollbacks: this.counters.rollbacks,
      rollbackFallbacks: this.counters.rollbackFallbacks,
      rollbackMisses: this.counters.rollbackMisses,
      testUrlFallbacks: this.counters.testUrlFallbacks
    };
  }

  /** 最近一次失败码；成功或无失败时为 null（只含稳定码）。 */
  getLastErrorCode(): ProxyErrorCode | null {
    return this.lastErrorCode;
  }

  /** 最近一次 patch 的固定告警码副本（如 `rule_key_conflict`），不含配置内容。 */
  getLastWarnings(): string[] {
    const copy: string[] = [];
    for (let index: number = 0; index < this.lastWarnings.length; index++) {
      copy.push(this.lastWarnings[index]);
    }
    return copy;
  }

  /** 单次 `getConfig` 调用；桥接异常统一映射，成功时原样返回信封。 */
  private async invokeGetConfig(profilePath: string): Promise<ActionResultEnvelope> {
    try {
      return await this.channel.action('getConfig', profilePath, GET_CONFIG_TIMEOUT_MS);
    } catch (error) {
      throw this.translateBridgeError(error as Error);
    }
  }

  /** 记录失败码与分类计数，并返回带稳定码的错误对象。 */
  private fail(code: ClashConfigBuilderErrorCode, detailCode: string): ClashConfigBuilderError {
    this.lastErrorCode = code;
    switch (code) {
      case 'config_invalid':
        this.counters.configInvalid += 1;
        break;
      case 'path_rejected':
        this.counters.pathRejected += 1;
        break;
      case 'timeout':
        this.counters.timeouts += 1;
        break;
      case 'core_missing':
      case 'core_load_failed':
      case 'core_init_failed':
        this.counters.coreFailures += 1;
        break;
      default:
        break;
    }
    return new ClashConfigBuilderError(code, detailCode);
  }

  /**
   * 把 ClashCoreBridge 的错误收敛到本模块的稳定码。
   * 未知异常统一 `internal`，不保留原始 message（可能含路径或底层细节）。
   */
  private translateBridgeError(error: Error): ClashConfigBuilderError {
    if (error instanceof ClashBridgeError) {
      const bridge: ClashBridgeError = error as ClashBridgeError;
      const detail: string = bridge.detailCode.length > 0 ? bridge.detailCode : 'bridge_error';
      switch (bridge.code) {
        case 'config_invalid':
          return this.fail('config_invalid', detail);
        case 'timeout':
          return this.fail('timeout', detail);
        case 'core_symbol_missing':
          return this.fail('core_missing', detail);
        case 'core_load_failed':
          return this.fail('core_load_failed', detail);
        case 'core_init_failed':
          return this.fail('core_init_failed', detail);
        default:
          return this.fail('internal', detail);
      }
    }
    if (error instanceof ClashConfigBuilderError) {
      return error as ClashConfigBuilderError;
    }
    return this.fail('internal', 'bridge_error');
  }
}

/** 构建器单例；与内核通道同生命周期，由 ClashService 持有与清理。 */
export const clashConfigBuilder: ClashConfigBuilder = new ClashConfigBuilder();