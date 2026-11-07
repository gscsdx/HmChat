/**
 * Clash 内核 NAPI 门面（任务 T-S2-04，设计 §6.2、§6.3、§6.8）。
 *
 * 定位：VPN 扩展进程内唯一直接访问 `libclash_bridge.so` 的位置。UI 进程不 import
 * 本文件，也不链接内核；扩展层通过本门面获得统一的超时、稳定错误码、Action 关联
 * 与事件分发。
 *
 * 约束（逐条对应任务与设计）：
 * - 初始化与启动只走 `initCoreAsync` / `quickStartAsync`，禁止同步启动入口；
 * - 事件 sink 只注册一次，所有回调共用同一条通道并按 `id` 关联 Action；
 * - 错误只保留稳定码与细分码，不拼接路径、不读取文件、不打印原始 JSON；
 * - 内核返回的 `errorCode` 仅在白名单内透传，其余按 `core_init_failed` 收敛；
 * - 任何等待都有上限，避免 Promise 永久悬挂。
 */

import clashBridge from 'libclash_bridge.so';
import {
  ActionResultEnvelope,
  ActionEnvelope,
  CoreState,
  InitParams,
  JsonPayload,
  SetupParams
} from '../../model/ClashModels';

/** 接口初始化默认上限（设计 §6.5：异步初始化，超时由 ArkTS 兜底）。 */
const INIT_TIMEOUT_MS: number = 30000;

/** 启动默认上限（任务 T-S2-04）。 */
const QUICK_START_TIMEOUT_MS: number = 120000;

/** 单个 Action 的默认上限；调用方应按方法覆盖。 */
const ACTION_TIMEOUT_MS: number = 30000;

/** 定时器上限，防止异常入参产生超长等待。 */
const MAX_TIMEOUT_MS: number = 600000;

/** 在途 Action 上限（任务 T-S2-04；与原生侧在途表同值）。 */
const MAX_PENDING_ACTIONS: number = 256;

/** 内核初始化版本号（设计 §9.3：关闭 per-app UID 解析）。 */
const INIT_VERSION: number = 29;

/**
 * 本门面产生的稳定错误码。
 *
 * 前四项来自 `Index.d.ts` 与设计 §6.8；`config_invalid`、`timeout`、`internal`
 * 来自设计 §7.9 的共用码表。`core_symbol_missing` 是原生桥的结构化码，UI 侧
 * 需要把它归入内核缺失类文案。
 */
export type ClashBridgeErrorCode =
  | 'core_load_failed'
  | 'core_init_failed'
  | 'core_symbol_missing'
  | 'config_invalid'
  | 'timeout'
  | 'internal';

/**
 * 结构化桥接错误：`message` 只等于稳定码，调用方只能依赖 `code` / `detailCode`。
 * 原始响应、异常文本、路径、URL 与配置正文一律不进入错误对象。
 */
export class ClashBridgeError extends Error {
  readonly code: ClashBridgeErrorCode;
  readonly detailCode: string;

  constructor(code: ClashBridgeErrorCode, detailCode: string = '') {
    super(code);
    this.name = 'ClashBridgeError';
    this.code = code;
    this.detailCode = detailCode;
  }
}

/**
 * `initCoreAsync` 的结果镜像，字段与 `Index.d.ts` 的 `CoreInitResult` 一致。
 * 失败时 `initialized=false` 且给出稳定 `errorCode`，版本号保持原生值或空串。
 */
export interface CoreInitResult {
  initialized: boolean;
  isInit: boolean;
  version: string;
  errorCode?: string;
}

/** 内核事件：`type` 为内核 Message 类型（loaded/delay/traffic/log 等）。 */
export interface ClashCoreEvent {
  type: string;
  data: JsonPayload;
}

/** 事件与 Action 通道的丢弃计数，仅用于诊断，不含内容。 */
export interface ClashBridgeCounters {
  pendingActions: number;
  unrecognizedPayloads: number;
  malformedPayloads: number;
  lateResults: number;
  handlerFailures: number;
}

/** 原生 sink 载荷的外层信封；`type` 区分三类通道。 */
interface SinkPayload {
  type?: string;
  data?: JsonPayload;
  id?: string;
  method?: string;
  code?: number;
}

/** 内核 `Message{type,data}` 的最小结构。 */
interface SinkMessage {
  type?: string;
  data?: JsonPayload;
}

/** 在途 Action：保留结算函数与超时句柄，结果到达后立即移除。 */
interface PendingAction {
  resolve: (result: ActionResultEnvelope) => void;
  reject: (error: ClashBridgeError) => void;
  timer: number;
}

/** 把调用方传入的上限收敛到可接受区间，非法值回退默认。 */
function effectiveTimeout(value: number, fallback: number): number {
  if (!Number.isFinite(value) || value <= 0) {
    return fallback;
  }
  return Math.min(Math.floor(value), MAX_TIMEOUT_MS);
}

/** 构造失败结果，避免在错误路径上泄露原生细节。 */
function initFailure(code: ClashBridgeErrorCode): CoreInitResult {
  const failure: CoreInitResult = {
    initialized: false,
    isInit: false,
    version: '',
    errorCode: code
  };
  return failure;
}

/** 原生初始化错误码白名单；其余值统一收敛到 `core_init_failed`。 */
function normalizeInitCode(raw: string): ClashBridgeErrorCode {
  switch (raw) {
    case 'core_load_failed':
      return 'core_load_failed';
    case 'core_symbol_missing':
      return 'core_symbol_missing';
    case 'core_init_failed':
      return 'core_init_failed';
    default:
      return 'core_init_failed';
  }
}

/**
 * 归一化原生初始化结果。
 * `initialized` 与内核自报的 `isInit` 必须同时为真才视为成功，避免伪造就绪。
 */
function normalizeInitResult(result: CoreInitResult): CoreInitResult {
  const version: string = typeof result.version === 'string' ? result.version : '';
  const initialized: boolean = result.initialized === true && result.isInit === true;
  if (initialized) {
    const ready: CoreInitResult = { initialized: true, isInit: true, version: version };
    return ready;
  }
  const nativeCode: string = typeof result.errorCode === 'string' ? result.errorCode : '';
  const code: ClashBridgeErrorCode = nativeCode.length > 0
    ? normalizeInitCode(nativeCode)
    : 'core_init_failed';
  const failure: CoreInitResult = {
    initialized: false,
    isInit: false,
    version: version,
    errorCode: code
  };
  return failure;
}

/**
 * 扩展侧内核门面。
 *
 * 单例由本文件末尾导出；扩展进程只应持有一份，否则会出现重复的 pending 表与
 * 事件处理器。事件 sink 在首次需要原生调用时注册一次，`shutdown()` 后重置，
 * 使下一次会话可以重新注册。
 */
export class ClashCoreBridge {
  /** 事件处理器，可在任意时刻替换；传 null 表示只计数不分发。 */
  eventHandler: ((event: ClashCoreEvent) => void) | null = null;

  private sinkInstalled: boolean = false;
  private readonly pending: Map<string, PendingAction> = new Map<string, PendingAction>();
  private readonly epoch: number = Date.now() % 1000000;
  private sequence: number = 0;
  private homeDir: string = '';
  private resultsLate: number = 0;
  private payloadsUnrecognized: number = 0;
  private payloadsMalformed: number = 0;
  private handlerFailures: number = 0;

  /**
   * 异步初始化内核。
   *
   * 与 `Index.d.ts` 一致：失败不 reject，而是返回 `initialized=false` 加稳定
   * `errorCode`。超时按 `core_init_failed` 处理，原生调用抛错按
   * `core_load_failed` 处理，原生给出的三个白名单码原样透传。
   */
  initCore(homeDir: string, timeoutMs: number = INIT_TIMEOUT_MS): Promise<CoreInitResult> {
    if (homeDir.length === 0) {
      return Promise.resolve(initFailure('core_init_failed'));
    }
    if (!this.ensureSink()) {
      return Promise.resolve(initFailure('core_load_failed'));
    }
    let work: Promise<CoreInitResult>;
    try {
      work = clashBridge.initCoreAsync(homeDir);
    } catch (_) {
      return Promise.resolve(initFailure('core_load_failed'));
    }
    const limit: number = effectiveTimeout(timeoutMs, INIT_TIMEOUT_MS);
    return new Promise<CoreInitResult>((resolve: (value: CoreInitResult) => void): void => {
      const timer: number = setTimeout((): void => {
        resolve(initFailure('core_init_failed'));
      }, limit);
      work.then((result: CoreInitResult): void => {
        clearTimeout(timer);
        const normalized: CoreInitResult = normalizeInitResult(result);
        if (normalized.initialized) {
          this.homeDir = homeDir;
        }
        resolve(normalized);
      }).catch((): void => {
        clearTimeout(timer);
        resolve(initFailure('core_load_failed'));
      });
    });
  }

  /**
   * 异步启动内核：`init`、`params`、`state` 三段 JSON 一次投递。
   *
   * 空串表示成功；非空错误文本统一映射为 `config_invalid`，不保留原文。
   * 超时按 `timeout`，原生抛错按 `core_load_failed`。
   */
  quickStart(setup: SetupParams, state: CoreState,
    timeoutMs: number = QUICK_START_TIMEOUT_MS): Promise<void> {
    if (this.homeDir.length === 0) {
      return Promise.reject(new ClashBridgeError('core_init_failed', 'not_initialized'));
    }
    if (!this.ensureSink()) {
      return Promise.reject(new ClashBridgeError('core_load_failed', 'sink_unavailable'));
    }
    const initParams: InitParams = { 'home-dir': this.homeDir, version: INIT_VERSION };
    let initJson: string = '';
    let paramsJson: string = '';
    let stateJson: string = '';
    try {
      initJson = JSON.stringify(initParams);
      paramsJson = JSON.stringify(setup);
      stateJson = JSON.stringify(state);
    } catch (_) {
      return Promise.reject(new ClashBridgeError('config_invalid', 'serialize_failed'));
    }
    let work: Promise<string>;
    try {
      work = clashBridge.quickStartAsync(initJson, paramsJson, stateJson);
    } catch (_) {
      return Promise.reject(new ClashBridgeError('core_load_failed', 'invoke_failed'));
    }
    const limit: number = effectiveTimeout(timeoutMs, QUICK_START_TIMEOUT_MS);
    return new Promise<void>((resolve: () => void, reject: (error: ClashBridgeError) => void): void => {
      const timer: number = setTimeout((): void => {
        reject(new ClashBridgeError('timeout', 'quick_start'));
      }, limit);
      work.then((message: string): void => {
        clearTimeout(timer);
        if (typeof message === 'string' && message.length === 0) {
          resolve();
          return;
        }
        reject(new ClashBridgeError('config_invalid', 'quick_start'));
      }).catch((): void => {
        clearTimeout(timer);
        reject(new ClashBridgeError('core_load_failed', 'native_error'));
      });
    });
  }

  /**
   * 下发一个 Action 并等待同 `id` 的结果。
   *
   * - 结果由事件通道回投，按 `id` 关联；超时后移除登记，迟到结果只计数丢弃；
   * - 在途数量达到上限时立即拒绝，不再向内核投递；
   * - 返回原始 `code`，成功判定由调用方按方法语义完成（设计 §9.1）。
   */
  action(method: string, data: string = '',
    timeoutMs: number = ACTION_TIMEOUT_MS): Promise<ActionResultEnvelope> {
    if (method.length === 0) {
      return Promise.reject(new ClashBridgeError('internal', 'empty_method'));
    }
    if (this.pending.size >= MAX_PENDING_ACTIONS) {
      return Promise.reject(new ClashBridgeError('internal', 'pending_limit'));
    }
    if (!this.ensureSink()) {
      return Promise.reject(new ClashBridgeError('core_load_failed', 'sink_unavailable'));
    }
    const id: string = this.nextActionId(method);
    const envelope: ActionEnvelope = data.length > 0
      ? { id: id, method: method, data: data }
      : { id: id, method: method };
    let json: string = '';
    try {
      json = JSON.stringify(envelope);
    } catch (_) {
      return Promise.reject(new ClashBridgeError('internal', 'serialize_failed'));
    }
    const limit: number = effectiveTimeout(timeoutMs, ACTION_TIMEOUT_MS);
    return new Promise<ActionResultEnvelope>(
      (resolve: (result: ActionResultEnvelope) => void,
        reject: (error: ClashBridgeError) => void): void => {
        const timer: number = setTimeout((): void => {
          if (this.pending.delete(id)) {
            reject(new ClashBridgeError('timeout', 'action'));
          }
        }, limit);
        const entry: PendingAction = { resolve: resolve, reject: reject, timer: timer };
        this.pending.set(id, entry);
        try {
          clashBridge.invokeAction(json);
        } catch (_) {
          this.pending.delete(id);
          clearTimeout(timer);
          reject(new ClashBridgeError('core_load_failed', 'invoke_failed'));
        }
      });
  }

  /** 内核启动时间戳（epoch ms）；0 表示未启动。 */
  getRunTime(): number {
    const value: number = clashBridge.getRunTime();
    if (!Number.isFinite(value) || value < 0) {
      return 0;
    }
    return value;
  }

  /**
   * 把 TUN fd 交给内核；成功后 fd 所有权转移，失败路径由调用方销毁连接，
   * 不得再次 close(fd)。异常收敛为 false，不向调用方抛出原生文本。
   */
  startTun(fd: number): boolean {
    if (!Number.isFinite(fd) || fd <= 0) {
      return false;
    }
    try {
      return clashBridge.startTun(fd) === true;
    } catch (_) {
      return false;
    }
  }

  /** 只停止 TUN；原生短调用失败由调用方按固定码记录。 */
  stopTun(): void {
    try {
      clashBridge.stopTun();
    } catch (_) {
      // 原生释放失败由会话层统一计数，不在这里输出异常文本。
    }
  }

  /** 当前生效配置名（用户可见名称）；不可用时返回空串。 */
  getCurrentProfileName(): string {
    try {
      const value: string = clashBridge.getCurrentProfileName();
      return typeof value === 'string' ? value : '';
    } catch (_) {
      return '';
    }
  }

  /** 内核建议的 TUN 参数 JSON；空串表示不可得，由调用方按缺失处理。 */
  getAndroidVpnOptions(): string {
    const value: string = clashBridge.getAndroidVpnOptions();
    return typeof value === 'string' ? value : '';
  }

  /** 上报当前 CoreState（原生短调用）。 */
  setState(state: CoreState): void {
    const json: string = JSON.stringify(state);
    clashBridge.setState(json);
  }

  /** 通知 Go dialer 握手结束；调用方负责异常计数与降级判定。 */
  notifyProtected(fd: number): void {
    clashBridge.notifyProtected(fd);
  }

  /** protect 统计 JSON；仅用于诊断，内容由原生白名单保证。 */
  getProtectStats(): string {
    const value: string = clashBridge.getProtectStats();
    return typeof value === 'string' ? value : '';
  }

  /**
   * 关闭内核并清空在途请求。
   *
   * 原生约定失败只返回 false、不抛异常；这里同样吞掉异常并返回 false。
   * 关闭后重置 sink 标记，使下一次会话能重新注册事件通道。
   */
  shutdown(): boolean {
    let stopped: boolean = false;
    try {
      stopped = clashBridge.shutdownCore() === true;
    } catch (_) {
      stopped = false;
    }
    this.rejectPending('shutdown');
    this.sinkInstalled = false;
    return stopped;
  }

  /** 当前丢弃与在途计数快照；新对象，调用方不能借此修改内部状态。 */
  getCounters(): ClashBridgeCounters {
    const counters: ClashBridgeCounters = {
      pendingActions: this.pending.size,
      unrecognizedPayloads: this.payloadsUnrecognized,
      malformedPayloads: this.payloadsMalformed,
      lateResults: this.resultsLate,
      handlerFailures: this.handlerFailures
    };
    return counters;
  }

  /** 注册事件 sink；成功返回 true，库不可用时返回 false 且不伪造就绪。 */
  private ensureSink(): boolean {
    if (this.sinkInstalled) {
      return true;
    }
    try {
      clashBridge.setEventSink((payload: string): void => {
        this.handlePayload(payload);
      });
      this.sinkInstalled = true;
      return true;
    } catch (_) {
      this.sinkInstalled = false;
      return false;
    }
  }

  /** 生成本次会话唯一的 Action id：`<method>#<epoch>-<seq>`。 */
  private nextActionId(method: string): string {
    this.sequence += 1;
    return `${method}#${this.epoch}-${this.sequence}`;
  }

  /**
   * 解析一条 sink 载荷。
   *
   * 支持的形态：
   * - `{type:"actionResult", data:ActionResult}`；
   * - `{type:"event"|"message", data:Message}`；
   * - 原生原样回投的 `ActionResult`（`method:"message"` 为事件，其余为 Action 结果）。
   * 其余形态只计数丢弃，绝不打印载荷内容。
   */
  private handlePayload(payload: string): void {
    if (payload.length === 0) {
      this.payloadsMalformed += 1;
      return;
    }
    let envelope: SinkPayload;
    try {
      envelope = JSON.parse(payload) as SinkPayload;
    } catch (_) {
      this.payloadsMalformed += 1;
      return;
    }
    const kind: string = typeof envelope.type === 'string' ? envelope.type : '';
    if (kind === 'actionResult') {
      this.consumeActionResult(envelope.data);
      return;
    }
    if (kind === 'event' || kind === 'message') {
      this.consumeEvent(envelope.data);
      return;
    }
    if (kind === 'protect') {
      // 原生 TrampProtect 投递的同步握手信封：必须原样交给扩展的 protect 分支，
      // 否则 fd 未受保护就放行，会形成自身 TUN 环路。
      const handler: ((event: ClashCoreEvent) => void) | null = this.eventHandler;
      if (handler === null) {
        this.payloadsUnrecognized += 1;
        return;
      }
      const protectEvent: ClashCoreEvent = {
        type: 'protect',
        data: envelope.data === undefined ? null : envelope.data
      };
      try {
        handler(protectEvent);
      } catch (_) {
        this.handlerFailures += 1;
      }
      return;
    }
    if (kind.length === 0) {
      if (envelope.method === 'message') {
        this.consumeEvent(envelope.data === undefined ? envelope : envelope.data);
        return;
      }
      if (typeof envelope.id === 'string' && typeof envelope.method === 'string') {
        this.consumeActionResult(envelope);
        return;
      }
    }
    this.payloadsUnrecognized += 1;
  }

  /** 分发内核事件；处理器异常被隔离并计数，不影响后续投递。 */
  private consumeEvent(raw: JsonPayload | undefined): void {
    if (raw === undefined || raw === null || typeof raw !== 'object') {
      this.payloadsMalformed += 1;
      return;
    }
    const message: SinkMessage = raw as SinkMessage;
    if (typeof message.type !== 'string' || message.type.length === 0) {
      this.payloadsUnrecognized += 1;
      return;
    }
    const event: ClashCoreEvent = {
      type: message.type,
      data: message.data === undefined ? null : message.data
    };
    const handler: ((event: ClashCoreEvent) => void) | null = this.eventHandler;
    if (handler === null) {
      return;
    }
    try {
      handler(event);
    } catch (_) {
      this.handlerFailures += 1;
    }
  }

  /** 结算同 `id` 的 Action；没有登记视为迟到结果。 */
  private consumeActionResult(raw: JsonPayload | undefined): void {
    if (raw === undefined || raw === null || typeof raw !== 'object') {
      this.payloadsMalformed += 1;
      return;
    }
    const result: ActionResultEnvelope = raw as ActionResultEnvelope;
    if (typeof result.id !== 'string' || result.id.length === 0) {
      this.payloadsMalformed += 1;
      return;
    }
    const entry: PendingAction | undefined = this.pending.get(result.id);
    if (entry === undefined) {
      this.resultsLate += 1;
      return;
    }
    this.pending.delete(result.id);
    clearTimeout(entry.timer);
    if (typeof result.method !== 'string' || typeof result.code !== 'number') {
      entry.reject(new ClashBridgeError('internal', 'malformed_result'));
      return;
    }
    const normalized: ActionResultEnvelope = {
      id: result.id,
      method: result.method,
      data: result.data === undefined ? '' : result.data,
      code: result.code
    };
    entry.resolve(normalized);
  }

  /** 关闭或销毁时统一拒绝在途请求，保证没有悬挂 Promise。 */
  private rejectPending(detailCode: string): void {
    this.pending.forEach((entry: PendingAction): void => {
      clearTimeout(entry.timer);
      entry.reject(new ClashBridgeError('internal', detailCode));
    });
    this.pending.clear();
  }
}

/** 扩展进程共享实例；UI 进程不引用本模块。 */
export const clashCoreBridge: ClashCoreBridge = new ClashCoreBridge();