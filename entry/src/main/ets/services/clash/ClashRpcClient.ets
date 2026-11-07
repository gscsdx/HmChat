/**
 * UI 侧唯一 Clash RPC 客户端（设计 §5.1-§5.5，任务 T-S2-14）。
 *
 * 证据来源：
 * - docs/integration/clash-proxy-design.md §5.1（会话与凭据交接、ack 轮询）、
 *   §5.2（NDJSON 帧与 256 待响应上限）、§5.3（auth 首帧、5 s 预算、身份字段）、
 *   §5.5（超时、断线、1/2/4/8/16 s 重连预算、60 s 稳定清零）。
 * - docs/integration/clash-proxy-tasks.md T-S2-14。
 * - `ClashSessionFiles.ets`（ack 文件读取与校验）、`ClashRpcProtocolBridge.ets`（NDJSON 分帧）。
 *
 * 职责边界：
 * 1. 只负责一条本机回环 TCP 连接：`127.0.0.1:<port>` → `auth` → `hello`。
 * 2. ack 轮询（250 ms × 40 = 10 s）只在本类内完成；读不到就返回 `rpc_unavailable`，
 *    不做无限等待，也不伪造 Ready。
 * 3. 请求按 `id` 关联；超时立即 reject 并从表里移除，迟到响应找不到 id 只计数丢弃。
 * 4. 断线后按 1/2/4/8/16 s 退避，最多 5 次；稳定 60 s 后预算清零。
 *    `fault{session_rotated}` 是终止信号，绝不自动重连，由上层用新 ack/新 token 重建。
 * 5. 事件只上报固定通道与结构化码，不打印 token、nonce、sessionId、请求正文或响应正文。
 *
 * 凭据生命周期：token/nonce 只存在本实例的私有字段中，供同一次会话内的有界重连使用；
 * 进入终止态（正常关闭、`session_rotated`、预算耗尽）立即清空引用。它们不会被导出到
 * 任何全局单例、Preferences、日志或回调参数中。
 *
 * 本文件不引用 TelegramService、MediaNetworkMonitor、TelephonyKit，也不直接实现分帧；
 * 字节编解码统一走 `ClashRpcProtocolBridge`。
 */

import { BusinessError } from '@kit.BasicServicesKit';
import { socket } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { JsonPayload, RpcPushChannel, RpcRequest, RPC_PROTO } from '../../model/ClashModels';
import {
  ClashSessionFiles,
  SessionAck,
  SessionAckResult,
  SESSION_LEGACY_PORT
} from './ClashSessionFiles';
import {
  encodeRequest,
  RpcDecodeResult,
  RpcFrameError,
  RpcFrameException,
  RpcFramer
} from './ClashRpcProtocolBridge';

// ---------------------------------------------------------------------------
// 常量（设计 §5.1-§5.5）
// ---------------------------------------------------------------------------

/** 回环地址；服务端只监听本机，客户端不得连接其他地址。 */
const LOOPBACK_ADDRESS: string = '127.0.0.1';

/** TCP 建连预算，与 auth 的 5 s 预算分开计算。 */
const CONNECT_TIMEOUT_MS: number = 5000;
/** auth 首帧预算；超时按不可用处理并断开。 */
const AUTH_TIMEOUT_MS: number = 5000;
/** hello 只读探测预算。 */
const HELLO_TIMEOUT_MS: number = 5000;
/** 未在方法表声明的方法使用 10 s；调用方可显式传入更精确的值。 */
const DEFAULT_REQUEST_TIMEOUT_MS: number = 10000;
/** 超时参数硬上限，避免调用方传入无限等待。 */
const MAX_REQUEST_TIMEOUT_MS: number = 180000;

/** ack 轮询：250 ms × 40 = 10 s。 */
const ACK_POLL_INTERVAL_MS: number = 250;
const ACK_POLL_COUNT: number = 40;

/** 每客户端待响应上限；达到后拒绝新请求，不排队。 */
const MAX_PENDING_REQUESTS: number = 256;

/** 重连预算：最多 5 次，退避序列固定。 */
const MAX_RECONNECT_ATTEMPTS: number = 5;
const RECONNECT_BACKOFF_MS: number[] = [1000, 2000, 4000, 8000, 16000];
/** 连接稳定 60 s 后重连预算清零。 */
const STABLE_RESET_MS: number = 60000;

const MIN_PORT: number = 1024;
const MAX_PORT: number = 65535;

const TOKEN_PATTERN: RegExp = /^[a-f0-9]{64}$/;
const NONCE_PATTERN: RegExp = /^[a-f0-9]{32}$/;
const SESSION_ID_PATTERN: RegExp = /^[a-f0-9]{16}$/;
const BOOT_ID_PATTERN: RegExp = /^[a-f0-9]{16}$/;
/** 服务端错误码形状；不合规的码统一收敛为 `internal`，不进入 UI 映射。 */
const ERROR_CODE_PATTERN: RegExp = /^[a-z][a-z0-9_.-]{0,47}$/;
/** 方法名形状；只允许既有 `core.init` / `core.quickStart` 这类标识。 */
const METHOD_PATTERN: RegExp = /^[a-z][A-Za-z0-9.]{0,63}$/;

/** 本类产生的稳定错误码（服务端码按原样透传，形状不合规时收敛为 `internal`）。 */
export const RPC_ERROR_UNAVAILABLE: string = 'rpc_unavailable';
export const RPC_ERROR_AUTH_FAILED: string = 'rpc_auth_failed';
export const RPC_ERROR_PENDING_OVERFLOW: string = 'pending_overflow';
export const RPC_ERROR_TIMEOUT: string = 'timeout';
export const RPC_ERROR_LINK_LOST: string = 'link_lost';
export const RPC_ERROR_CLOSED: string = 'closed';
export const RPC_ERROR_INVALID_ARGUMENT: string = 'invalid_argument';
export const RPC_ERROR_FRAME_TOO_LARGE: string = 'frame_too_large';
export const RPC_ERROR_MALFORMED_FRAME: string = 'malformed_frame';

const LOG_DOMAIN: number = 0x0000;
const LOG_TAG: string = 'HarlgramClashRpc';

// ---------------------------------------------------------------------------
// 对外类型
// ---------------------------------------------------------------------------

/** 链路状态；只描述 TCP/RPC 链路，不替代 ClashStateMachine 的代理六态。 */
export type RpcLinkState = 'idle' | 'connecting' | 'ready' | 'reconnecting' | 'closed';

/**
 * 断线原因：
 * - `link_lost`：已建立的连接断开，客户端按预算自动重连；
 * - `extension_crashed`：5 次重连全部失败，停止自动重连；
 * - `session_rotated`：扩展轮换了会话，旧客户端必须停止并等待新 ack；
 * - `closed`：调用方主动关闭。
 */
export type RpcDisconnectReason = 'link_lost' | 'extension_crashed' | 'session_rotated' | 'closed';

/** `hello` 最小结果；`coreLoaded=false` 由上层判定为 `core_missing`。 */
export interface RpcHello {
  coreLoaded: boolean;
  coreVersion: string;
}

/** 推送 `fault` 的结构；字段与设计 §5.7 一致，不含堆栈与参数。 */
export interface RpcFault {
  code: string;
  detailCode?: string;
  count: number;
}

/**
 * 事件回调。全部为可选，缺省时不产生任何副作用。
 * 回调只收到结构化数据，不接收 socket、token、nonce 或原始帧。
 */
export interface RpcClientHandlers {
  onPush?: (kind: RpcPushChannel, data: object) => void;
  onState?: (state: RpcLinkState) => void;
  onFault?: (fault: RpcFault) => void;
  onDisconnected?: (reason: RpcDisconnectReason) => void;
}

/** 只读计数，用于诊断入口；不含任何内容字段。 */
export interface RpcClientStats {
  frames: number;
  pushes: number;
  malformedFrames: number;
  frameErrors: number;
  lateResponses: number;
  timeouts: number;
  authFailures: number;
  connectFailures: number;
  reconnectTries: number;
  reconnectFailures: number;
  reconnectExhausted: number;
  ackReadErrors: number;
}

/**
 * 结构化客户端错误。`message` 固定等于 `code`，UI 只能依赖 `code` / `detailCode`；
 * 服务端 error.message 不进入本对象，避免把诊断文本当作可展示文案。
 */
export class RpcClientError extends Error {
  readonly code: string;
  readonly detailCode: string;

  constructor(code: string, detailCode: string = '') {
    super(code);
    this.name = 'RpcClientError';
    this.code = code;
    this.detailCode = detailCode;
  }
}

// ---------------------------------------------------------------------------
// 内部类型
// ---------------------------------------------------------------------------

/** 在途请求：结算函数与超时句柄成对保存，超时/断线时一并清理。 */
interface PendingRequest {
  resolve: (result: JsonPayload) => void;
  reject: (error: RpcClientError) => void;
  timer: number;
  method: string;
}

/** ack 声明的扩展身份；auth 必须返回同一 pid/bootId。 */
interface SessionIdentity {
  pid: number;
  bootId: string;
}

/** 同一次会话的有界重连材料；终止时整体丢弃。 */
interface RpcSession {
  port: number;
  token: string;
  nonce: string;
  pid: number;
  bootId: string;
  session8: string;
}

/** auth 应答中本模块使用的字段。 */
interface RpcAuthView {
  proto?: JsonPayload;
  sessionId?: JsonPayload;
  pid?: JsonPayload;
  bootId?: JsonPayload;
}

/** hello 应答中本模块使用的字段。 */
interface RpcHelloView {
  coreLoaded?: JsonPayload;
  coreVersion?: JsonPayload;
}

/** fault 推送结构，逐字段防守读取。 */
interface RpcFaultView {
  code?: JsonPayload;
  detailCode?: JsonPayload;
  count?: JsonPayload;
}

/** 响应 error 体。 */
interface RpcErrorView {
  code?: JsonPayload;
  message?: JsonPayload;
}

/** 帧信封的结构视图；字段均为可选，使用前逐项判断。 */
interface FrameView {
  id?: JsonPayload;
  method?: JsonPayload;
  params?: JsonPayload;
  result?: JsonPayload;
  error?: JsonPayload;
  push?: JsonPayload;
  data?: JsonPayload;
}

/** auth 请求参数；`proto` 必须与 req/ack 文件一致。 */
interface RpcAuthParams {
  token: string;
  nonce: string;
  proto: number;
}

/** auth 校验通过后的最小身份信息。 */
interface ResolvedAuth {
  pid: number;
  bootId: string;
  session8: string;
}

// ---------------------------------------------------------------------------
// 客户端
// ---------------------------------------------------------------------------

/**
 * 一个实例只持有最多一条 RPC 连接。`connect` 与 `close` 是单飞入口：
 * 连接期间重复调用 `connect` 会被直接拒绝，避免端口与 pending 表被并发改写。
 */
export class ClashRpcClient {
  private readonly sessions: ClashSessionFiles;
  private readonly handlers: RpcClientHandlers;

  /** 当前 socket；所有事件处理都先做身份比较，旧 socket 的迟到事件直接丢弃。 */
  private socketRef: socket.TCPSocket | undefined = undefined;
  /** 每次连接独立分帧器，避免旧连接的半行字节污染新连接。 */
  private framer: RpcFramer | undefined = undefined;
  /** 本次会话的重连材料；`undefined` 表示没有可续连的会话。 */
  private session: RpcSession | undefined = undefined;

  private pending: Map<string, PendingRequest> = new Map<string, PendingRequest>();

  private linkState: RpcLinkState = 'idle';
  /** 请求序号；每次新建连接归零。 */
  private seq: number = 0;
  /** 当前请求 id 的会话前缀；auth 前用随机值，auth 后换成服务端 sessionId 前 8 位。 */
  private sessionPrefix: string = '';

  /** 关闭/轮换会递增 epoch，异步流程用它判断自己是否已经过期。 */
  private epoch: number = 0;
  private connecting: boolean = false;
  private reconnectInFlight: boolean = false;
  private terminal: boolean = false;

  /** 已消耗的重连次数（0..5）。 */
  private reconnectAttempts: number = 0;
  private reconnectTimer: number = -1;
  private stableTimer: number = -1;
  private sleepTimer: number = -1;
  private sleepWake: (() => void) | undefined = undefined;

  private counters: RpcClientStats = {
    frames: 0,
    pushes: 0,
    malformedFrames: 0,
    frameErrors: 0,
    lateResponses: 0,
    timeouts: 0,
    authFailures: 0,
    connectFailures: 0,
    reconnectTries: 0,
    reconnectFailures: 0,
    reconnectExhausted: 0,
    ackReadErrors: 0
  };

  constructor(sessions: ClashSessionFiles, handlers: RpcClientHandlers) {
    this.sessions = sessions;
    this.handlers = handlers;
  }

  /**
   * 建立会话并完成 `auth` + `hello`。
   *
   * `port === 0` 表示端口尚未知：按设计 §5.1 轮询 ack（250 ms × 40），读到 ready 的
   * ack 后使用其中的端口与 pid/bootId。`port > 0` 时只读一次 ack 做身份校验；
   * ack 已被扩展删除（鉴权成功后删除是允许的）则跳过身份比对，仍以服务端 auth
   * 返回的 pid/bootId 作为本次会话身份。
   *
   * 失败一律抛出 `RpcClientError`，不会留下半开 socket、pending 或 token。
   */
  async connect(port: number, token: string, nonce: string): Promise<RpcHello> {
    if (!TOKEN_PATTERN.test(token)) {
      throw new RpcClientError(RPC_ERROR_AUTH_FAILED, 'token_shape');
    }
    if (!NONCE_PATTERN.test(nonce)) {
      throw new RpcClientError(RPC_ERROR_UNAVAILABLE, 'nonce_shape');
    }
    if (!Number.isSafeInteger(port) || (port !== 0 && !isValidAckPort(port))) {
      throw new RpcClientError(RPC_ERROR_UNAVAILABLE, 'port_invalid');
    }
    if (this.connecting) {
      throw new RpcClientError(RPC_ERROR_INVALID_ARGUMENT, 'connect_in_flight');
    }
    if (this.linkState === 'ready') {
      throw new RpcClientError(RPC_ERROR_INVALID_ARGUMENT, 'already_connected');
    }

    this.connecting = true;
    this.terminal = false;
    this.epoch += 1;
    const epoch: number = this.epoch;
    this.cancelReconnect();
    this.cancelStableTimer();
    this.wakeSleep();
    this.rejectAllPending(RPC_ERROR_LINK_LOST, 'replaced');
    this.dropSession();
    this.resetBudget();
    this.setState('connecting');

    let targetPort: number = port;
    let identity: SessionIdentity | undefined = undefined;
    try {
      if (port === 0) {
        const ack: SessionAck = await this.awaitReadyAck(nonce, epoch);
        targetPort = ack.port;
        identity = toIdentity(ack);
      } else {
        identity = await this.readAckIdentity(nonce, port);
      }
      const hello: RpcHello = await this.openAndHandshake(targetPort, token, nonce, identity, epoch);
      return hello;
    } catch (error) {
      this.counters.connectFailures += 1;
      this.closeSocketReference();
      this.dropSession();
      if (this.linkState !== 'closed') {
        this.setState('idle');
      }
      if (error instanceof RpcClientError) {
        throw error as RpcClientError;
      }
      throw new RpcClientError(RPC_ERROR_UNAVAILABLE, 'connect_failed');
    } finally {
      this.connecting = false;
    }
  }

  /**
   * 发送普通 RPC 请求并等待对应 `id` 的响应。
   *
   * 未连接立即 reject；pending 达到 256 后拒绝新请求；超时 reject 并移除，
   * 之后到达的同 id 响应只计 `lateResponses`，不会被任何新请求接收。
   */
  async request(method: string, params?: object, timeoutMs: number = 0): Promise<JsonPayload> {
    if (!METHOD_PATTERN.test(method)) {
      throw new RpcClientError(RPC_ERROR_INVALID_ARGUMENT, 'method_name');
    }
    if (this.terminal) {
      throw new RpcClientError(RPC_ERROR_CLOSED, 'not_connected');
    }
    if (this.linkState !== 'ready' || this.socketRef === undefined) {
      throw new RpcClientError(RPC_ERROR_UNAVAILABLE, 'not_connected');
    }
    let timeout: number = defaultTimeoutFor(method);
    if (Number.isSafeInteger(timeoutMs) && timeoutMs > 0) {
      timeout = Math.min(Math.floor(timeoutMs), MAX_REQUEST_TIMEOUT_MS);
    }
    return this.sendAndWait(method, params, timeout, this.epoch);
  }

  /** 主动关闭：停止重连、拒绝全部 pending、清空 token 并上报 `closed`。 */
  close(): void {
    this.finishTerminal('closed');
  }

  /** 当前链路状态快照。 */
  state(): RpcLinkState {
    return this.linkState;
  }

  /** 当前待响应数量，供诊断只读展示。 */
  pendingCount(): number {
    return this.pending.size;
  }

  /** 计数快照；返回副本，调用方无法改写内部状态。 */
  stats(): RpcClientStats {
    const snapshot: RpcClientStats = {
      frames: this.counters.frames,
      pushes: this.counters.pushes,
      malformedFrames: this.counters.malformedFrames,
      frameErrors: this.counters.frameErrors,
      lateResponses: this.counters.lateResponses,
      timeouts: this.counters.timeouts,
      authFailures: this.counters.authFailures,
      connectFailures: this.counters.connectFailures,
      reconnectTries: this.counters.reconnectTries,
      reconnectFailures: this.counters.reconnectFailures,
      reconnectExhausted: this.counters.reconnectExhausted,
      ackReadErrors: this.counters.ackReadErrors
    };
    return snapshot;
  }

  // -------------------------------------------------------------------------
  // 连接与握手
  // -------------------------------------------------------------------------

  /** ack 轮询；只有 ready 且端口合法才返回。 */
  private async awaitReadyAck(nonce: string, epoch: number): Promise<SessionAck> {
    for (let attempt: number = 0; attempt < ACK_POLL_COUNT; attempt++) {
      if (this.epoch !== epoch || this.terminal) {
        throw new RpcClientError(RPC_ERROR_CLOSED, 'connect_aborted');
      }
      const result: SessionAckResult = await this.sessions.readAck(nonce);
      const ack: SessionAck | undefined = result.ack;
      if (ack !== undefined) {
        if (ack.ready) {
          if (!isValidAckPort(ack.port)) {
            throw new RpcClientError(RPC_ERROR_UNAVAILABLE, 'ack_port_invalid');
          }
          return ack;
        }
        let detail: string = 'rpc_bind_failed';
        if (ack.errorCode !== undefined && ack.errorCode.length > 0) {
          detail = ack.errorCode;
        }
        throw new RpcClientError(RPC_ERROR_UNAVAILABLE, detail);
      }
      const errorCode: string | undefined = result.errorCode;
      if (errorCode === 'path_rejected' || errorCode === 'rpc_auth_failed' ||
        errorCode === 'token_invalid') {
        throw new RpcClientError(RPC_ERROR_UNAVAILABLE, errorCode);
      }
      if (errorCode !== undefined && errorCode !== 'session_missing') {
        // 文件尚未生成是正常等待；其余读取异常只计数，继续轮询到预算结束。
        this.counters.ackReadErrors += 1;
      }
      if (attempt + 1 < ACK_POLL_COUNT) {
        await this.sleep(ACK_POLL_INTERVAL_MS);
        if (this.epoch !== epoch) {
          throw new RpcClientError(RPC_ERROR_CLOSED, 'connect_aborted');
        }
      }
    }
    throw new RpcClientError(RPC_ERROR_UNAVAILABLE, 'ack_timeout');
  }

  /**
   * 端口已知时的单次 ack 校验。
   * 返回 `undefined` 表示 ack 已被删除（例如同会话重连），不是失败。
   */
  private async readAckIdentity(nonce: string, port: number): Promise<SessionIdentity | undefined> {
    const result: SessionAckResult = await this.sessions.readAck(nonce);
    const ack: SessionAck | undefined = result.ack;
    if (ack === undefined || !ack.ready) {
      return undefined;
    }
    if (!isValidAckPort(ack.port)) {
      throw new RpcClientError(RPC_ERROR_UNAVAILABLE, 'ack_port_invalid');
    }
    if (ack.port !== port) {
      throw new RpcClientError(RPC_ERROR_UNAVAILABLE, 'ack_port_mismatch');
    }
    return toIdentity(ack);
  }

  /**
   * 建 socket、注册事件、`auth`、`hello`。
   * 任何失败都在本方法内关闭自己创建的 socket，不把半成品留给上层。
   */
  private async openAndHandshake(port: number, token: string, nonce: string,
    identity: SessionIdentity | undefined, epoch: number): Promise<RpcHello> {
    if (!isValidAckPort(port)) {
      throw new RpcClientError(RPC_ERROR_UNAVAILABLE, 'port_invalid');
    }
    const tcp: socket.TCPSocket = socket.constructTCPSocketInstance();
    this.socketRef = tcp;
    this.framer = new RpcFramer();
    this.seq = 0;
    this.sessionPrefix = randomHex8();
    this.attachSocket(tcp);
    try {
      await tcp.connect({
        address: { address: LOOPBACK_ADDRESS, port: port, family: 1 },
        timeout: CONNECT_TIMEOUT_MS
      });
      if (this.epoch !== epoch || this.socketRef !== tcp) {
        throw new RpcClientError(RPC_ERROR_CLOSED, 'connect_aborted');
      }
      const authParams: RpcAuthParams = { token: token, nonce: nonce, proto: RPC_PROTO };
      const authPayload: JsonPayload = await this.sendAndWait('auth', authParams, AUTH_TIMEOUT_MS, epoch);
      const auth: ResolvedAuth = this.acceptAuth(authPayload, identity);
      this.sessionPrefix = auth.session8;
      const helloPayload: JsonPayload = await this.sendAndWait('hello', undefined, HELLO_TIMEOUT_MS, epoch);
      const hello: RpcHello = acceptHello(helloPayload);
      this.session = {
        port: port,
        token: token,
        nonce: nonce,
        pid: auth.pid,
        bootId: auth.bootId,
        session8: auth.session8
      };
      this.setState('ready');
      this.armStableTimer();
      logInfo('ready', this.reconnectAttempts);
      return hello;
    } catch (error) {
      if (this.socketRef === tcp) {
        this.socketRef = undefined;
        this.framer = undefined;
      }
      this.closeSocket(tcp);
      if (error instanceof RpcClientError) {
        const clientError: RpcClientError = error as RpcClientError;
        // 握手期断开或超时统一归入不可用；鉴权/关闭等稳定码保持原样。
        if (clientError.code === RPC_ERROR_LINK_LOST) {
          throw new RpcClientError(RPC_ERROR_UNAVAILABLE, 'link_lost_during_handshake');
        }
        if (clientError.code === RPC_ERROR_TIMEOUT) {
          throw new RpcClientError(RPC_ERROR_UNAVAILABLE, clientError.detailCode + '_timeout');
        }
        throw clientError;
      }
      throw new RpcClientError(RPC_ERROR_UNAVAILABLE, 'handshake_failed');
    }
  }

  /** 校验 auth 应答：协议版本、sessionId 形状、pid/bootId 与 ack 一致。 */
  private acceptAuth(payload: JsonPayload, identity: SessionIdentity | undefined): ResolvedAuth {
    const body: object | undefined = asPlainObject(payload);
    if (body === undefined) {
      throw this.authFailure('auth_malformed');
    }
    const view: RpcAuthView = body as RpcAuthView;
    if (typeof view.proto !== 'number' || view.proto !== RPC_PROTO) {
      throw this.authFailure('auth_proto');
    }
    if (typeof view.sessionId !== 'string' || !SESSION_ID_PATTERN.test(view.sessionId)) {
      throw this.authFailure('auth_session');
    }
    if (typeof view.pid !== 'number' || !Number.isSafeInteger(view.pid) || view.pid <= 0) {
      throw this.authFailure('auth_pid');
    }
    if (typeof view.bootId !== 'string' || !BOOT_ID_PATTERN.test(view.bootId)) {
      throw this.authFailure('auth_boot');
    }
    if (identity !== undefined && (view.pid !== identity.pid || view.bootId !== identity.bootId)) {
      throw this.authFailure('auth_identity');
    }
    const resolved: ResolvedAuth = {
      pid: view.pid,
      bootId: view.bootId,
      session8: view.sessionId.substring(0, 8)
    };
    return resolved;
  }

  private authFailure(detail: string): RpcClientError {
    this.counters.authFailures += 1;
    return new RpcClientError(RPC_ERROR_AUTH_FAILED, detail);
  }

  // -------------------------------------------------------------------------
  // 发送与请求表
  // -------------------------------------------------------------------------

  /**
   * 编码并发送一帧，返回该 `id` 的响应 Promise。
   *
   * 先登记 pending 再 `send`，保证极快的响应不会在表里找不到 id；`send` 失败时
   * 立即移除本次 pending 并按断线处理，避免 Promise 永久悬挂。
   */
  private sendAndWait(method: string, params: object | undefined, timeoutMs: number,
    epoch: number): Promise<JsonPayload> {
    const tcp: socket.TCPSocket | undefined = this.socketRef;
    if (tcp === undefined || this.epoch !== epoch || this.terminal) {
      return Promise.reject(new RpcClientError(RPC_ERROR_UNAVAILABLE, 'not_connected'));
    }
    if (this.pending.size >= MAX_PENDING_REQUESTS) {
      return Promise.reject(new RpcClientError(RPC_ERROR_PENDING_OVERFLOW, method));
    }
    const id: string = this.nextRequestId();
    const request: RpcRequest = { id: id, method: method };
    if (params !== undefined) {
      request.params = params;
    }
    let frame: Uint8Array = new Uint8Array(0);
    try {
      frame = encodeRequest(request);
    } catch (error) {
      return Promise.reject(mapEncodeFailure(error as Error));
    }

    const promise: Promise<JsonPayload> = new Promise<JsonPayload>(
      (resolve: (result: JsonPayload) => void, reject: (error: RpcClientError) => void) => {
        const timer: number = setTimeout(() => {
          this.pending.delete(id);
          this.counters.timeouts += 1;
          reject(new RpcClientError(RPC_ERROR_TIMEOUT, method));
        }, timeoutMs);
        const pending: PendingRequest = {
          resolve: resolve,
          reject: reject,
          timer: timer,
          method: method
        };
        this.pending.set(id, pending);
      });

    const data: ArrayBuffer = toSendBuffer(frame);
    tcp.send({ data: data }).catch((error: BusinessError) => {
      this.abortPending(id, RPC_ERROR_UNAVAILABLE, 'send_failed');
      this.onLinkLost(tcp, 'send_failed');
    });
    return promise;
  }

  private nextRequestId(): string {
    this.seq += 1;
    return 'u-' + this.sessionPrefix + '-' + this.seq;
  }

  private abortPending(id: string, code: string, detail: string): void {
    const pending: PendingRequest | undefined = this.pending.get(id);
    if (pending === undefined) {
      return;
    }
    clearTimeout(pending.timer);
    this.pending.delete(id);
    pending.reject(new RpcClientError(code, detail));
  }

  private rejectAllPending(code: string, detail: string): void {
    if (this.pending.size === 0) {
      return;
    }
    this.pending.forEach((pending: PendingRequest, id: string) => {
      clearTimeout(pending.timer);
      pending.reject(new RpcClientError(code, detail));
    });
    this.pending.clear();
  }

  // -------------------------------------------------------------------------
  // 接收与帧分发
  // -------------------------------------------------------------------------

  private attachSocket(tcp: socket.TCPSocket): void {
    tcp.on('message', (info: socket.SocketMessageInfo) => this.onMessage(tcp, info));
    tcp.on('close', () => this.onLinkLost(tcp, 'socket_close'));
    tcp.on('error', (error: BusinessError) => {
      logWarn('socket_error', error.code);
      this.onLinkLost(tcp, 'socket_error');
    });
  }

  private onMessage(tcp: socket.TCPSocket, info: socket.SocketMessageInfo): void {
    if (this.socketRef !== tcp || this.terminal) {
      return;
    }
    const framer: RpcFramer | undefined = this.framer;
    if (framer === undefined) {
      return;
    }
    let decoded: RpcDecodeResult;
    try {
      decoded = framer.decodeChunk(new Uint8Array(info.message));
    } catch (_) {
      this.counters.frameErrors += 1;
      this.onLinkLost(tcp, 'decode_failed');
      return;
    }
    const errors: RpcFrameError[] = decoded.errors;
    for (let index: number = 0; index < errors.length; index++) {
      this.counters.frameErrors += 1;
      logWarn('frame_error', 0);
      if (errors[index].code === 'buffer_overflow') {
        // 设计 §5.2：未成帧缓冲超限必须立即断开，不继续读取。
        this.onLinkLost(tcp, 'buffer_overflow');
        return;
      }
    }
    const frames: object[] = decoded.frames;
    for (let index: number = 0; index < frames.length; index++) {
      if (this.socketRef !== tcp || this.terminal) {
        return;
      }
      this.handleFrame(frames[index]);
    }
  }

  /** 单帧分发：push、响应、非法信封三种路径。异常只计数，不打断事件泵。 */
  private handleFrame(frame: object): void {
    this.counters.frames += 1;
    try {
      const view: FrameView = frame as FrameView;
      if (view.push !== undefined) {
        this.handlePush(view);
        return;
      }
      if (typeof view.id === 'string') {
        this.handleResponse(view);
        return;
      }
      this.counters.malformedFrames += 1;
    } catch (_) {
      this.counters.malformedFrames += 1;
      logWarn('handler_failed', 0);
    }
  }

  private handlePush(view: FrameView): void {
    const kind: RpcPushChannel | undefined = pushChannel(view.push);
    const data: object | undefined = asPlainObject(view.data);
    if (kind === undefined || data === undefined) {
      this.counters.malformedFrames += 1;
      return;
    }
    if (kind === 'fault') {
      // fault 必须先通过字段白名单，畸形推送不交给 UI。
      const fault: RpcFault | undefined = parseFault(data);
      if (fault === undefined) {
        this.counters.malformedFrames += 1;
        return;
      }
      this.counters.pushes += 1;
      this.emitPush(kind, data);
      if (fault.code === 'session_rotated') {
        // 设计 §5.1：旧客户端收到轮换信号后不再重连，由上层用新 ack 重建。
        // 先完成终止态再回调，避免回调内重新 connect 被同一次终止覆盖。
        this.finishTerminal('session_rotated');
        this.emitFault(fault);
        return;
      }
      this.emitFault(fault);
      return;
    }
    this.counters.pushes += 1;
    this.emitPush(kind, data);
  }

  private handleResponse(view: FrameView): void {
    const id: string = view.id as string;
    const pending: PendingRequest | undefined = this.pending.get(id);
    if (pending === undefined) {
      // 超时后迟到、或旧会话的响应：按 id 丢弃，绝不交给新请求。
      this.counters.lateResponses += 1;
      return;
    }
    const hasResult: boolean = view.result !== undefined;
    const hasError: boolean = view.error !== undefined;
    if (hasResult === hasError) {
      // 信封形状不合法：立即结束该请求，避免等到超时才失败。
      clearTimeout(pending.timer);
      this.pending.delete(id);
      this.counters.malformedFrames += 1;
      pending.reject(new RpcClientError(RPC_ERROR_MALFORMED_FRAME, 'response_shape'));
      return;
    }
    clearTimeout(pending.timer);
    this.pending.delete(id);
    if (hasError) {
      const body: object | undefined = asPlainObject(view.error);
      if (body === undefined) {
        this.counters.malformedFrames += 1;
        pending.reject(new RpcClientError(RPC_ERROR_MALFORMED_FRAME, 'error_body'));
        return;
      }
      const errorView: RpcErrorView = body as RpcErrorView;
      if (typeof errorView.code !== 'string' || errorView.code.length === 0) {
        this.counters.malformedFrames += 1;
        pending.reject(new RpcClientError(RPC_ERROR_MALFORMED_FRAME, 'error_code'));
        return;
      }
      pending.reject(new RpcClientError(normalizeServerCode(errorView.code), pending.method));
      if (pending.method === 'auth') {
        this.counters.authFailures += 1;
      }
      return;
    }
    const result: JsonPayload = view.result === undefined ? null : view.result;
    pending.resolve(result);
  }

  // -------------------------------------------------------------------------
  // 断线、重连与终止
  // -------------------------------------------------------------------------

  /**
   * 已建立连接断开：立即拒绝全部 pending 并上报 `link_lost`，随后按预算重连。
   * 握手期间的断开由握手调用方处理，这里不重复调度。
   */
  private onLinkLost(tcp: socket.TCPSocket, detail: string): void {
    if (this.socketRef !== tcp) {
      return;
    }
    this.socketRef = undefined;
    this.framer = undefined;
    this.closeSocket(tcp);
    this.rejectAllPending(RPC_ERROR_LINK_LOST, detail);
    if (this.terminal) {
      return;
    }
    if (this.connecting || this.reconnectInFlight) {
      return;
    }
    if (this.session === undefined) {
      this.setState('closed');
      return;
    }
    // 先排重连再回调：回调内如重新 connect，会取消这次调度而不是被它覆盖。
    this.scheduleReconnect();
    this.emitDisconnected('link_lost');
  }

  private scheduleReconnect(): void {
    if (this.terminal || this.reconnectTimer >= 0) {
      return;
    }
    if (this.session === undefined) {
      this.finishTerminal('extension_crashed');
      return;
    }
    if (this.reconnectAttempts >= MAX_RECONNECT_ATTEMPTS) {
      this.exhaustReconnect();
      return;
    }
    const delay: number = RECONNECT_BACKOFF_MS[this.reconnectAttempts];
    this.reconnectAttempts += 1;
    this.setState('reconnecting');
    logInfo('reconnect_scheduled', this.reconnectAttempts);
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = -1;
      this.runReconnect().catch((error: Error) => {
        this.counters.reconnectFailures += 1;
        logWarn('reconnect_runner_failed', 0);
      });
    }, delay);
  }

  private async runReconnect(): Promise<void> {
    const session: RpcSession | undefined = this.session;
    if (session === undefined || this.terminal || this.socketRef !== undefined) {
      return;
    }
    this.reconnectInFlight = true;
    this.counters.reconnectTries += 1;
    const epoch: number = this.epoch;
    try {
      const identity: SessionIdentity = { pid: session.pid, bootId: session.bootId };
      await this.openAndHandshake(session.port, session.token, session.nonce, identity, epoch);
    } catch (_) {
      this.counters.reconnectFailures += 1;
      if (this.terminal || this.epoch !== epoch) {
        return;
      }
      if (this.reconnectAttempts >= MAX_RECONNECT_ATTEMPTS) {
        this.exhaustReconnect();
        return;
      }
      this.scheduleReconnect();
    } finally {
      this.reconnectInFlight = false;
    }
  }

  /** 预算耗尽：先上报结构化 fault，再以 `extension_crashed` 终止。 */
  private exhaustReconnect(): void {
    if (this.terminal) {
      return;
    }
    this.counters.reconnectExhausted += 1;
    const fault: RpcFault = {
      code: 'extension_crashed',
      detailCode: 'reconnect_exhausted',
      count: this.reconnectAttempts
    };
    logWarn('reconnect_exhausted', this.reconnectAttempts);
    this.finishTerminal('extension_crashed');
    this.emitFault(fault);
  }

  /**
   * 终止态统一收敛：停表、拒绝 pending、关闭 socket、清空 token、上报状态与原因。
   * 重复调用是幂等的。
   */
  private finishTerminal(reason: RpcDisconnectReason): void {
    if (this.terminal) {
      return;
    }
    // 从未建立过连接时关闭（例如启动前放弃）不产生断线回调。
    const wasIdle: boolean = this.linkState === 'idle';
    this.terminal = true;
    this.epoch += 1;
    this.cancelReconnect();
    this.cancelStableTimer();
    this.wakeSleep();
    this.rejectAllPending(RPC_ERROR_CLOSED, 'closed');
    this.closeSocketReference();
    this.dropSession();
    this.setState('closed');
    if (!wasIdle) {
      this.emitDisconnected(reason);
    }
  }

  /** 稳定 60 s 后清零重连预算；期间再次断线仍使用剩余预算。 */
  private armStableTimer(): void {
    this.cancelStableTimer();
    this.stableTimer = setTimeout(() => {
      this.stableTimer = -1;
      this.resetBudget();
      logInfo('stable_reset', 0);
    }, STABLE_RESET_MS);
  }

  private resetBudget(): void {
    this.reconnectAttempts = 0;
  }

  private cancelReconnect(): void {
    if (this.reconnectTimer >= 0) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = -1;
    }
  }

  private cancelStableTimer(): void {
    if (this.stableTimer >= 0) {
      clearTimeout(this.stableTimer);
      this.stableTimer = -1;
    }
  }

  private closeSocketReference(): void {
    const tcp: socket.TCPSocket | undefined = this.socketRef;
    this.socketRef = undefined;
    this.framer = undefined;
    if (tcp !== undefined) {
      this.closeSocket(tcp);
    }
  }

  private closeSocket(tcp: socket.TCPSocket): void {
    try {
      tcp.off('message');
      tcp.off('connect');
      tcp.off('close');
      tcp.off('error');
    } catch (_) {
      logWarn('socket_detach_failed', 0);
    }
    tcp.close().catch((error: BusinessError) => {
      logWarn('socket_close_failed', error.code);
    });
  }

  /** 清理会话材料；调用后同会话重连不再可能，必须由上层重新 `connect`。 */
  private dropSession(): void {
    this.session = undefined;
  }

  private sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      this.sleepWake = resolve;
      this.sleepTimer = setTimeout(() => {
        this.sleepTimer = -1;
        this.sleepWake = undefined;
        resolve();
      }, ms);
    });
  }

  private wakeSleep(): void {
    if (this.sleepTimer >= 0) {
      clearTimeout(this.sleepTimer);
      this.sleepTimer = -1;
    }
    const wake: (() => void) | undefined = this.sleepWake;
    this.sleepWake = undefined;
    if (wake !== undefined) {
      wake();
    }
  }

  private setState(next: RpcLinkState): void {
    if (this.linkState === next) {
      return;
    }
    this.linkState = next;
    hilog.info(LOG_DOMAIN, LOG_TAG, 'rpc state %{public}s attempt %{public}d', next,
      this.reconnectAttempts);
    const callback = this.handlers.onState;
    if (callback !== undefined) {
      try {
        callback(next);
      } catch (_) {
        logWarn('state_handler_failed', 0);
      }
    }
  }

  private emitPush(kind: RpcPushChannel, data: object): void {
    const callback = this.handlers.onPush;
    if (callback !== undefined) {
      try {
        callback(kind, data);
      } catch (_) {
        logWarn('push_handler_failed', 0);
      }
    }
  }

  private emitFault(fault: RpcFault): void {
    const callback = this.handlers.onFault;
    if (callback !== undefined) {
      try {
        callback(fault);
      } catch (_) {
        logWarn('fault_handler_failed', 0);
      }
    }
  }

  private emitDisconnected(reason: RpcDisconnectReason): void {
    const callback = this.handlers.onDisconnected;
    if (callback !== undefined) {
      try {
        callback(reason);
      } catch (_) {
        logWarn('disconnect_handler_failed', 0);
      }
    }
  }
}

// ---------------------------------------------------------------------------
// 纯函数辅助
// ---------------------------------------------------------------------------

function isValidAckPort(port: number): boolean {
  if (!Number.isSafeInteger(port)) {
    return false;
  }
  if (port < MIN_PORT || port > MAX_PORT) {
    return false;
  }
  return port !== SESSION_LEGACY_PORT;
}

function toIdentity(ack: SessionAck): SessionIdentity {
  const identity: SessionIdentity = { pid: ack.pid, bootId: ack.bootId };
  return identity;
}

/** 只接受 JSON 对象；数组、标量与 null 都不是本协议的信封。 */
function asPlainObject(value: JsonPayload | undefined): object | undefined {
  if (value === undefined || value === null) {
    return undefined;
  }
  if (typeof value !== 'object') {
    return undefined;
  }
  if (Array.isArray(value)) {
    return undefined;
  }
  return value as object;
}

function pushChannel(value: JsonPayload | undefined): RpcPushChannel | undefined {
  if (value === 'state') {
    return 'state';
  }
  if (value === 'event') {
    return 'event';
  }
  if (value === 'fault') {
    return 'fault';
  }
  return undefined;
}

/** fault 字段白名单：code 必填，detailCode/count 可选且只保留合法值。 */
function parseFault(data: object): RpcFault | undefined {
  const view: RpcFaultView = data as RpcFaultView;
  if (typeof view.code !== 'string' || !ERROR_CODE_PATTERN.test(view.code)) {
    return undefined;
  }
  let detailCode: string | undefined = undefined;
  if (typeof view.detailCode === 'string' && ERROR_CODE_PATTERN.test(view.detailCode)) {
    detailCode = view.detailCode;
  }
  let count: number = 0;
  if (typeof view.count === 'number' && Number.isSafeInteger(view.count) && view.count >= 0) {
    count = view.count;
  }
  if (detailCode === undefined) {
    const fault: RpcFault = { code: view.code, count: count };
    return fault;
  }
  const fault: RpcFault = { code: view.code, detailCode: detailCode, count: count };
  return fault;
}

/** hello 只读取 `coreLoaded`；版本缺失时保留空串，不伪造。 */
function acceptHello(payload: JsonPayload): RpcHello {
  const body: object | undefined = asPlainObject(payload);
  if (body === undefined) {
    throw new RpcClientError(RPC_ERROR_UNAVAILABLE, 'hello_malformed');
  }
  const view: RpcHelloView = body as RpcHelloView;
  if (typeof view.coreLoaded !== 'boolean') {
    throw new RpcClientError(RPC_ERROR_UNAVAILABLE, 'hello_malformed');
  }
  let version: string = '';
  if (typeof view.coreVersion === 'string') {
    version = view.coreVersion;
  }
  const hello: RpcHello = { coreLoaded: view.coreLoaded, coreVersion: version };
  return hello;
}

function normalizeServerCode(code: string): string {
  // 服务端 `auth_failed` 与 UI 错误码表统一为 `rpc_auth_failed`（设计 §5.8）。
  if (code === 'auth_failed') {
    return RPC_ERROR_AUTH_FAILED;
  }
  if (ERROR_CODE_PATTERN.test(code)) {
    return code;
  }
  return 'internal';
}

function defaultTimeoutFor(method: string): number {
  if (method === 'auth' || method === 'hello') {
    return AUTH_TIMEOUT_MS;
  }
  if (method === 'core.init') {
    return 30000;
  }
  if (method === 'core.quickStart' || method === 'tun.start') {
    return 120000;
  }
  if (method === 'tun.stop' || method === 'session.shutdown') {
    return 30000;
  }
  if (method === 'vpn.options') {
    return 10000;
  }
  if (method === 'core.action') {
    return 15000;
  }
  if (method === 'notification.update' || method === 'diagnostics.snapshot') {
    return 5000;
  }
  return DEFAULT_REQUEST_TIMEOUT_MS;
}

function mapEncodeFailure(error: Error): RpcClientError {
  if (error instanceof RpcFrameException) {
    const frameError: RpcFrameException = error as RpcFrameException;
    if (frameError.error.code === 'frame_too_large') {
      return new RpcClientError(RPC_ERROR_FRAME_TOO_LARGE, 'frame_too_large');
    }
    return new RpcClientError(RPC_ERROR_MALFORMED_FRAME, frameError.error.code);
  }
  return new RpcClientError(RPC_ERROR_MALFORMED_FRAME, 'encode_failed');
}

/** `encodeRequest` 返回定长字节；此处再按视图裁剪，杜绝把多余容量发出。 */
function toSendBuffer(frame: Uint8Array): ArrayBuffer {
  const buffer: ArrayBuffer = frame.buffer as ArrayBuffer;
  if (frame.byteOffset === 0 && frame.byteLength === buffer.byteLength) {
    return buffer;
  }
  return buffer.slice(frame.byteOffset, frame.byteOffset + frame.byteLength);
}

function randomHex8(): string {
  const uuid: string = util.generateRandomUUID(false);
  const compact: string = uuid.split('-').join('');
  if (compact.length >= 8) {
    return compact.substring(0, 8);
  }
  return '00000000';
}

/** 只记录固定码与计数；不记录 token、nonce、sessionId、请求/响应正文。 */
function logInfo(code: string, value: number): void {
  hilog.info(LOG_DOMAIN, LOG_TAG, 'rpc %{public}s %{public}d', code, value);
}

function logWarn(code: string, value: number): void {
  hilog.warn(LOG_DOMAIN, LOG_TAG, 'rpc %{public}s %{public}d', code, value);
}