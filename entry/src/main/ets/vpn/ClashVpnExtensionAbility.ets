/**
 * Clash VPN 扩展入口（S4-02 生命周期骨架；设计 §7.1）。
 *
 * 职责边界：
 * - 承载 RPC 监听、内核桥、TUN 会话与通知，是 RPC 服务的**唯一**宿主；
 * - `onCreate` 只搭 RPC（读 req → bind(0) → 写 ack），**不加载内核、不建 TUN、不弹授权**；
 * - `onConnect` 按新 nonce 轮换会话（旧连接先收 `fault{session_rotated}`）；
 * - `onDestroy` 推 `fault{extension_destroyed}` → 停 TUN → 销毁连接 → 关 RPC → 删会话文件 → 取消通知。
 *
 * 证据：
 * - docs/integration/clash-proxy-design.md §5.1（会话交接）、§5.4（方法表）、§5.6（停止收敛）、
 *   §7.1（生命周期与 homeDir）、§7.2（扩展 import 隔离）、§7.7（通知）、§7.9（错误码）。
 * - docs/integration/clash-proxy-tasks.md T-S4-02 / T-S4-03 / T-S4-04。
 * - 本机 SDK 26 `@ohos.app.ability.VpnExtensionAbility.d.ts`：只声明 `onCreate`/`onDestroy`；
 *   `onConnect`/`onDisconnect` 作为兼容钩子保留（见文件末尾「已知限制」）。
 *
 * 约束：
 * - 本目录及 services/clash 不得 import contacts/geo/audio/camera/call/sim/sms/TelephonyKit/
 *   TelegramService/MediaNetworkMonitor/telegram/data/components/pages（设计 §7.2）。
 * - 不使用 `any`/`unknown`/枚举；不打印 token、nonce、URL、端口、节点名或配置正文。
 * - 会话文件、通知、RPC 都由本类释放；`ClashVpnSession` 只负责 TUN 与 protect。
 *
 * 已知限制（如实记录，不伪造能力）：
 * 1. SDK 26 `VpnExtensionAbility` 类型声明没有 `onConnect`/`onDisconnect`；系统若回调，
 *    本类按设计轮换；若系统只回调 `onCreate`，同一路径仍会在 `onCreate` 里完成握手。
 * 2. SDK 26 `VpnExtensionContext` 没有 `terminateSelf()`，`shutdown` 后由系统回收进程（Q5）。
 * 3. `hello.coreLoaded` 用 `getRunTime()` 短调用做「桥库 + 内核库已映射」探测；内核版本号
 *    只有 `core.init` 成功后才知道，未初始化时返回空串，不伪造版本。
 * 4. `ClashCoreBridge` 目前只转发 `event`/`message`/`actionResult` 三种 sink 信封；
 *    原生 `{type:"protect"}` 载荷需要桥侧补一条分支后才会到达 `onCoreEvent`（已知缺口，
 *    本文件已按「到达即处理」的契约接好，桥侧修复不需要再改本文件）。
 */

import { Want } from '@kit.AbilityKit';
import { VpnExtensionAbility, VpnExtensionContext } from '@kit.NetworkKit';
import { process, util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  ActionResultEnvelope,
  CoreState,
  JsonPayload,
  ProxyScope,
  SetupParams,
  VpnPropsState
} from '../model/ClashModels';
import {
  ClashBridgeCounters,
  ClashBridgeError,
  ClashCoreEvent,
  CoreInitResult,
  clashCoreBridge
} from '../services/clash/ClashCoreBridge';
import { DecodedEvent, ClashEventDecoder } from '../services/clash/ClashEventDecoder';
import {
  ClashRpcServer,
  RpcCallContext,
  RpcHandlerError,
  RpcListenerCloseReason,
  RpcServerHandlers,
  RpcServerSession,
  RpcStartResult
} from '../services/clash/ClashRpcServer';
import {
  ClashSessionFiles,
  SessionCleanupSummary,
  SessionRequest,
  SessionRequestResult
} from '../services/clash/ClashSessionFiles';
import {
  ClashNotification,
  ClashNotificationStatus,
  NOTIFICATION_TEXT_CONNECTED,
  NOTIFICATION_TEXT_STARTING,
  NOTIFICATION_TEXT_STOPPED
} from '../services/clash/ClashNotification';
import {
  ClashSessionCallbacks,
  ClashSessionError,
  ClashVpnSession,
  ProtectCounters,
  readCurrentProfileName,
  readVpnOptions,
  StopHooks,
  StopStatus,
  TunStartResult,
  TunStopResult,
  VpnOptionsReadResult
} from '../services/clash/ClashVpnSession';

const LOG_DOMAIN: number = 0x0000;
const LOG_TAG: string = 'HarlgramVpnExt';

/** Want 中只携带 nonce 与相对文件名；token/端口不进入 Want（设计 §5.1）。 */
const WANT_KEY_NONCE: string = 'clashSessionNonce';
const WANT_KEY_FILE: string = 'clashSessionFile';

/** 停止后无新会话的静默期；到期释放内核（设计 §5.6）。 */
const IDLE_SHUTDOWN_MS: number = 60000;

const NONCE_PATTERN: RegExp = /^[a-f0-9]{32}$/;

/** 允许从 UI 发起的 Action 方法（设计 §5.4 白名单）。 */
const ACTION_METHODS: string[] = [
  'getProxies',
  'changeProxy',
  'asyncTestDelay',
  'healthCheck',
  'getConfig',
  'validateConfig',
  'setupConfig',
  'updateConfig',
  'getConnections',
  'closeConnections',
  'getCoreVersion',
  'getTraffic',
  'getTotalTraffic',
  'resetTraffic',
  'getRunTime',
  'getCurrentProfileName',
  'getAndroidVpnOptions',
  'getIsInit',
  'setState',
  'shutdown',
  'startLog',
  'stopLog',
  'getMemory',
  'forceGc'
];

interface HelloCapabilities {
  tun: boolean;
  protect: boolean;
  asyncStart: boolean;
}

interface HelloResult {
  coreLoaded: boolean;
  coreVersion: string;
  capabilities: HelloCapabilities;
  homeDirKind: string;
}

interface CoreInitView {
  homeDirKind?: JsonPayload;
}

interface QuickStartView {
  init?: JsonPayload;
  params?: JsonPayload;
  state?: JsonPayload;
}



interface VpnPropsWire {
  enable?: JsonPayload;
  systemProxy?: JsonPayload;
  ipv6?: JsonPayload;
  allowBypass?: JsonPayload;
}

interface ActionView {
  id?: JsonPayload;
  method?: JsonPayload;
  data?: JsonPayload;
}

interface ActionParamsView {
  action?: JsonPayload;
}

interface TunStartView {
  scope?: JsonPayload;
  state?: JsonPayload;
}

interface NotificationUpdateView {
  title?: JsonPayload;
  text?: JsonPayload;
  status?: JsonPayload;
  nodeName?: JsonPayload;
}

interface ProtectEventView {
  fd?: JsonPayload;
  epoch?: JsonPayload;
  gen?: JsonPayload;
}

interface StatePushData {
  state: string;
  scope?: string;
  startedAt?: number;
  errorCode?: string;
}

interface FaultPushData {
  code: string;
  detailCode?: string;
  count: number;
}

interface NotificationUpdateResult {
  updated: boolean;
}

interface DiagnosticsSession {
  epoch: number;
  uptimeMs: number;
}

interface DiagnosticsCounters {
  pendingActions: number;
  unrecognizedPayloads: number;
  malformedPayloads: number;
  lateResults: number;
  handlerFailures: number;
  notificationsPublished: number;
  notificationsFailed: number;
  eventsDecoded: number;
  eventsDropped: number;
}

interface DiagnosticsResult {
  protect: ProtectCounters;
  session: DiagnosticsSession;
  counters: DiagnosticsCounters;
}

function logInfo(code: string, value: number): void {
  hilog.info(LOG_DOMAIN, LOG_TAG, 'vpn ext %{public}s %{public}d', code, value);
}

function logWarn(category: string, code: string): void {
  hilog.warn(LOG_DOMAIN, LOG_TAG, 'vpn ext %{public}s: %{public}s', category, code);
}

function isPlainObject(value: JsonPayload | undefined): boolean {
  return value !== undefined && value !== null && typeof value === 'object' && !Array.isArray(value);
}

function readBoolean(value: JsonPayload | undefined, fallback: boolean): boolean {
  return typeof value === 'boolean' ? value : fallback;
}

function readWantString(want: Want, key: string): string {
  const parameters: Record<string, Object> | undefined = want.parameters;
  if (parameters === undefined) {
    return '';
  }
  const value: Object | undefined = parameters[key];
  return typeof value === 'string' ? value : '';
}

/** 16 hex 进程标识；只用于 ack/auth 关联，不承载任何凭据。 */
function createBootId(): string {
  const uuid: string = util.generateRandomUUID(false);
  const compact: string = uuid.split('-').join('').toLowerCase();
  if (compact.length < 16) {
    return '0000000000000000';
  }
  return compact.substring(0, 16);
}

function defaultCoreState(): CoreState {
  const props: VpnPropsState = {
    enable: true,
    systemProxy: false,
    ipv6: false,
    allowBypass: false
  };
  const state: CoreState = {
    'vpn-props': props,
    'current-profile-name': '',
    'bypass-domain': []
  };
  return state;
}

function readStringArray(value: JsonPayload | undefined): string[] {
  const result: string[] = [];
  if (value === undefined || value === null || !Array.isArray(value)) {
    return result;
  }
  const list: JsonPayload[] = value as JsonPayload[];
  for (let index: number = 0; index < list.length; index++) {
    const item: JsonPayload = list[index];
    if (typeof item === 'string' && item.length > 0) {
      result.push(item);
    }
  }
  return result;
}

/** `CoreState` 线格式 → 显式模型；缺字段用安全默认值，不把 undefined 传给内核。 */
function parseCoreState(value: JsonPayload | undefined): CoreState | undefined {
  if (!isPlainObject(value)) {
    return undefined;
  }
  // ArkTS 禁止按索引读取接口字段（arkts-no-props-by-index）；带连字符的键用 Record 承载。
  const wire: Record<string, JsonPayload> = value as Record<string, JsonPayload>;
  let propsWire: VpnPropsWire = {};
  const propsValue: JsonPayload | undefined = wire['vpn-props'];
  if (isPlainObject(propsValue)) {
    propsWire = propsValue as VpnPropsWire;
  }
  const props: VpnPropsState = {
    enable: readBoolean(propsWire.enable, true),
    systemProxy: readBoolean(propsWire.systemProxy, false),
    ipv6: readBoolean(propsWire.ipv6, false),
    allowBypass: readBoolean(propsWire.allowBypass, false)
  };
  const profileName: JsonPayload | undefined = wire['current-profile-name'];
  const state: CoreState = {
    'vpn-props': props,
    'current-profile-name': typeof profileName === 'string' ? profileName : '',
    'bypass-domain': readStringArray(wire['bypass-domain'])
  };
  return state;
}

function parseSetupParams(value: JsonPayload | undefined): SetupParams | undefined {
  if (!isPlainObject(value)) {
    return undefined;
  }
  const wire: Record<string, JsonPayload> = value as Record<string, JsonPayload>;
  const configValue: JsonPayload | undefined = wire['config'];
  if (!isPlainObject(configValue)) {
    return undefined;
  }
  const testUrl: JsonPayload | undefined = wire['test-url'];
  if (typeof testUrl !== 'string' || testUrl.length === 0) {
    return undefined;
  }
  const selected: Record<string, string> = {};
  const selectedValue: JsonPayload | undefined = wire['selected-map'];
  if (isPlainObject(selectedValue)) {
    const source: Record<string, string> = selectedValue as Record<string, string>;
    const keys: string[] = Object.keys(source);
    for (let index: number = 0; index < keys.length; index++) {
      const key: string = keys[index];
      const item: JsonPayload = source[key] as JsonPayload;
      if (typeof item === 'string' && item.length > 0) {
        selected[key] = item;
      }
    }
  }
  const setup: SetupParams = {
    config: configValue as object,
    'selected-map': selected,
    'test-url': testUrl
  };
  return setup;
}

function readScope(value: JsonPayload | undefined): ProxyScope | undefined {
  if (value === 'global' || value === 'harlgramOnly') {
    return value;
  }
  return undefined;
}

function readNotificationStatus(status: JsonPayload | undefined,
  text: JsonPayload | undefined): ClashNotificationStatus {
  if (status === 'starting' || status === 'connected' || status === 'stopped') {
    return status;
  }
  if (typeof text === 'string') {
    if (text === NOTIFICATION_TEXT_STARTING) {
      return 'starting';
    }
    if (text === NOTIFICATION_TEXT_CONNECTED) {
      return 'connected';
    }
    if (text === NOTIFICATION_TEXT_STOPPED) {
      return 'stopped';
    }
  }
  return 'connected';
}

/** Action 默认超时；与设计 §5.4 的方法表一致。 */
function actionTimeout(method: string): number {
  if (method === 'getProxies' || method === 'changeProxy' || method === 'getConnections') {
    return 15000;
  }
  if (method === 'asyncTestDelay') {
    return 7000;
  }
  if (method === 'healthCheck' || method === 'validateConfig') {
    return 30000;
  }
  if (method === 'getConfig') {
    return 20000;
  }
  if (method === 'setupConfig') {
    return 60000;
  }
  if (method === 'getCoreVersion' || method === 'getRunTime' || method === 'getIsInit') {
    return 5000;
  }
  if (method === 'shutdown') {
    return 10000;
  }
  return 15000;
}

/** 桥错误收敛为短码；未知错误不返回原始文本。 */
function bridgeErrorCode(error: ClashBridgeError): string {
  const code: string = typeof error.code === 'string' ? error.code : '';
  if (code === 'config_invalid' || code === 'timeout' || code === 'core_load_failed' ||
    code === 'core_init_failed' || code === 'core_symbol_missing') {
    return code;
  }
  return 'internal';
}

/**
 * 扩展 Ability：一个进程只有一个实例。
 *
 * 所有可能抛错的异步路径都在入口处转换为固定码日志或结构化 RPC 错误，
 * 不允许未捕获的 Promise 拒绝终结扩展进程。
 */
export default class ClashVpnExtensionAbility extends VpnExtensionAbility {
  private rpcServer: ClashRpcServer | undefined = undefined;
  private sessionFiles: ClashSessionFiles | undefined = undefined;
  private session: ClashVpnSession | undefined = undefined;
  private readonly notification: ClashNotification = new ClashNotification();
  private readonly decoder: ClashEventDecoder = new ClashEventDecoder();
  private readonly pid: number = process.pid;
  private readonly bootId: string = createBootId();

  private homeDir: string = '';
  private ownBundle: string = '';
  private nonce: string = '';
  private coreReady: boolean = false;
  private coreVersion: string = '';
  private startedAt: number = 0;
  private activeScope: ProxyScope = 'global';
  private idleTimer: number = -1;
  private lastStateEpoch: number = 0;

  onCreate(want: Want): void {
    logInfo('create_pid', this.pid);
    this.homeDir = this.computeHomeDir();
    this.ownBundle = this.context.applicationInfo.name;
    this.sessionFiles = new ClashSessionFiles(this.context.filesDir);
    this.rpcServer = new ClashRpcServer(this.context.filesDir);
    // 事件泵只把白名单事件转给 UI；内核未初始化时不会触发。
    clashCoreBridge.eventHandler = (event: ClashCoreEvent): void => {
      this.onCoreEvent(event);
    };
    // 设计 §7.1：这里只建 RPC，不调用 initCore/quickStart，不建 TUN。
    this.acceptSession(want);
  }

  /**
   * 兼容钩子：系统在扩展已运行时再次 `startVpnExtensionAbility` 可能回调这里。
   * 只要拿到新 nonce 就走轮换；`onCreate` 已经处理过同一 nonce 时不会重复 bind。
   */
  onConnect(want: Want): void {
    logInfo('connect', 1);
    this.acceptSession(want);
  }

  onDisconnect(want: Want): void {
    // 设计 §7.1：断线不停代理，停止由 RPC `tun.stop` 决定。
    logInfo('disconnect', 0);
  }

  onDestroy(): void {
    logInfo('destroy', 0);
    this.cancelIdleShutdown();
    const rpc: ClashRpcServer | undefined = this.rpcServer;
    if (rpc !== undefined) {
      const fault: FaultPushData = { code: 'extension_destroyed', count: 1 };
      rpc.push('fault', fault);
    }
    this.teardown().catch((): void => {
      logWarn('destroy', 'teardown_failed');
    });
  }

  // -------------------------------------------------------------------------
  // 会话握手
  // -------------------------------------------------------------------------

  private computeHomeDir(): string {
    const extFilesDir: string = this.context.filesDir;
    const marker: string = '/haps/';
    const index: number = extFilesDir.indexOf(marker);
    if (index > 0) {
      // .../el2/base/haps/entry/files → .../el2/base/files（与核心 home 一致）。
      return extFilesDir.substring(0, index) + '/files';
    }
    return extFilesDir;
  }

  /**
   * 读取 Want 中的 nonce 并请求 RPC 绑定。
   *
   * 防重复 bind：`onCreate` 与 `onConnect` 都可能收到同一个 want；同一 nonce 且监听
   * 已在运行时直接返回，避免 ack 覆盖（T-S4-02 风险项）。
   */
  private acceptSession(want: Want): void {
    const nonce: string = readWantString(want, WANT_KEY_NONCE);
    if (!NONCE_PATTERN.test(nonce)) {
      logWarn('session', 'nonce_invalid');
      return;
    }
    const rpc: ClashRpcServer | undefined = this.rpcServer;
    if (nonce === this.nonce && rpc !== undefined && rpc.isRunning()) {
      return;
    }
    this.nonce = nonce;
    this.bindSession(nonce);
  }

  private bindSession(nonce: string): void {
    const files: ClashSessionFiles | undefined = this.sessionFiles;
    const rpc: ClashRpcServer | undefined = this.rpcServer;
    if (files === undefined || rpc === undefined) {
      logWarn('session', 'not_ready');
      return;
    }
    const work = async (): Promise<void> => {
      const read: SessionRequestResult = await files.readRequest(nonce);
      const request: SessionRequest | undefined = read.request;
      if (request === undefined) {
        // 不合法请求已由 ClashSessionFiles 删除；不 bind，避免向未知对端暴露监听。
        logWarn('session', read.errorCode === undefined ? 'session_missing' : read.errorCode);
        return;
      }
      const session: RpcServerSession = { nonce: request.nonce, token: request.token };
      const handlers: RpcServerHandlers = {
        session: session,
        pid: this.pid,
        bootId: this.bootId,
        handle: (method: string, params: object, context: RpcCallContext): Promise<object> =>
          this.handle(method, params, context),
        onListenerClosed: (reason: RpcListenerCloseReason): void => {
          logWarn('listener', reason);
        }
      };
      const result: RpcStartResult = await rpc.start(handlers);
      if (!result.ok) {
        logWarn('rpc', result.errorCode === undefined ? 'rpc_bind_failed' : result.errorCode);
        return;
      }
      this.cancelIdleShutdown();
      // 不记录端口；只记录绑定成功。
      logInfo('rpc_bound', 1);
    };
    work().catch((): void => {
      logWarn('session', 'bind_failed');
    });
  }

  // -------------------------------------------------------------------------
  // 内核事件
  // -------------------------------------------------------------------------

  /**
   * 核心事件泵。
   *
   * protect 分支必须**先**处理且不 await 其他慢操作；其余事件经白名单解码后
   * 只推 `event` 通道（节点名可推送，URL 由解码器摘要化）。
   */
  private onCoreEvent(event: ClashCoreEvent): void {
    if (event.type === 'protect') {
      this.handleProtectPayload(event.data);
      return;
    }
    const payload: string = eventPayload(event.data);
    if (payload.length === 0) {
      return;
    }
    const decoded: DecodedEvent | null = this.decoder.decode(payload);
    if (decoded === null) {
      return;
    }
    const rpc: ClashRpcServer | undefined = this.rpcServer;
    if (rpc === undefined) {
      return;
    }
    rpc.push('event', decoded as object);
  }

  private handleProtectPayload(data: JsonPayload): void {
    if (!isPlainObject(data)) {
      return;
    }
    const view: ProtectEventView = data as ProtectEventView;
    const fd: number = typeof view.fd === 'number' ? view.fd : 0;
    const epoch: number = typeof view.epoch === 'number' ? view.epoch : 0;
    const gen: number = typeof view.gen === 'number' ? view.gen : 0;
    const session: ClashVpnSession | undefined = this.session;
    if (session === undefined) {
      return;
    }
    session.handleProtect(fd, epoch, gen);
  }

  // -------------------------------------------------------------------------
  // RPC 分发
  // -------------------------------------------------------------------------

  private handle(method: string, params: object, context: RpcCallContext): Promise<object> {
    logInfo('method_epoch', context.epoch);
    if (method === 'hello') {
      return Promise.resolve(this.handleHello());
    }
    if (method === 'core.init') {
      return this.handleCoreInit(params);
    }
    if (method === 'core.quickStart') {
      return this.handleQuickStart(params);
    }
    if (method === 'core.action') {
      return this.handleAction(params);
    }
    if (method === 'tun.start') {
      return this.handleTunStart(params);
    }
    if (method === 'tun.stop') {
      return this.handleTunStop();
    }
    if (method === 'vpn.options') {
      return Promise.resolve(this.handleVpnOptions());
    }
    if (method === 'notification.update') {
      return this.handleNotificationUpdate(params);
    }
    if (method === 'diagnostics.snapshot') {
      return Promise.resolve(this.handleDiagnostics());
    }
    if (method === 'session.shutdown') {
      return this.handleShutdown();
    }
    return Promise.reject(new RpcHandlerError('method_not_allowed'));
  }

  /** 只读能力探测：不初始化内核、不建 TUN、不请求授权。 */
  private handleHello(): HelloResult {
    const capabilities: HelloCapabilities = { tun: true, protect: true, asyncStart: true };
    const result: HelloResult = {
      coreLoaded: this.probeCoreLoaded(),
      coreVersion: this.coreVersion,
      capabilities: capabilities,
      homeDirKind: 'files'
    };
    return result;
  }

  /**
   * 「已加载」判定：`getRunTime()` 是短调用，能返回说明桥库与 DT_NEEDED 的内核库都已映射。
   * 内核未 `core.init` 时返回 0，仍算已加载；版本号保持空串，不伪造。
   */
  private probeCoreLoaded(): boolean {
    if (this.coreReady) {
      return true;
    }
    try {
      clashCoreBridge.getRunTime();
      return true;
    } catch (error) {
      return false;
    }
  }

  private async handleCoreInit(params: object): Promise<object> {
    const view: CoreInitView = params as CoreInitView;
    if (view.homeDirKind !== undefined && view.homeDirKind !== 'files') {
      throw new RpcHandlerError('invalid_params');
    }
    if (this.homeDir.length === 0) {
      throw new RpcHandlerError('core_init_failed');
    }
    if (this.coreReady) {
      // 同一进程内核仍处于已初始化状态：复用，避免重复 initClashSync。
      const reused: CoreInitResult = {
        initialized: true,
        isInit: true,
        version: this.coreVersion
      };
      return reused;
    }
    const result: CoreInitResult = await clashCoreBridge.initCore(this.homeDir);
    if (result.initialized) {
      this.coreReady = true;
      if (result.version.length > 0) {
        this.coreVersion = result.version;
      }
    } else {
      const code: string = result.errorCode === undefined ? 'core_init_failed' : result.errorCode;
      this.pushFault(code, 'core_init');
    }
    return result;
  }

  private async handleQuickStart(params: object): Promise<object> {
    const view: QuickStartView = params as QuickStartView;
    const setup: SetupParams | undefined = parseSetupParams(view.params);
    if (setup === undefined) {
      const invalid: QuickStartResult = { error: 'config_invalid' };
      return invalid;
    }
    let state: CoreState = defaultCoreState();
    const parsed: CoreState | undefined = parseCoreState(view.state);
    if (parsed !== undefined) {
      state = parsed;
    }
    try {
      await clashCoreBridge.quickStart(setup, state);
      this.coreReady = true;
      const result: QuickStartResult = { error: '' };
      return result;
    } catch (error) {
      const code: string = bridgeErrorCode(error as ClashBridgeError);
      logWarn('quick_start', code);
      const result: QuickStartResult = { error: code };
      return result;
    }
  }

  private async handleAction(params: object): Promise<object> {
    const view: ActionParamsView = params as ActionParamsView;
    if (!isPlainObject(view.action)) {
      throw new RpcHandlerError('invalid_params');
    }
    const action: ActionView = view.action as ActionView;
    const method: string = typeof action.method === 'string' ? action.method : '';
    if (method.length === 0) {
      throw new RpcHandlerError('invalid_params');
    }
    if (ACTION_METHODS.indexOf(method) < 0) {
      throw new RpcHandlerError('method_not_allowed');
    }
    const data: string = typeof action.data === 'string' ? action.data : '';
    let payload: string = data;
    if (method === 'getConfig') {
      if (isValidProfileId(data)) {
        payload = this.resolveProfileYamlPath(data);
      } else if (isSafeProfileYamlPath(data)) {
        // UI 侧已有唯一路径；只接受应用私有 files/profiles 下的 .yaml。
        payload = data;
      } else {
        throw new RpcHandlerError('path_rejected');
      }
    }
    try {
      // 其余 Action 的 data 原样透传（如 validateConfig 的 YAML 文本）。
      const result: ActionResultEnvelope = await clashCoreBridge.action(method, payload, actionTimeout(method));
      return result;
    } catch (error) {
      throw new RpcHandlerError(bridgeErrorCode(error as ClashBridgeError));
    }
  }

  /**
   * 把已校验的 profileId 解析成内核可读的 `<home>/profiles/<id>.yaml`。
   *
   * homeDir 来自系统 VpnExtensionContext，不是外部输入，因此只校验非空，
   * 不把系统返回的合法私有路径误判为 path_rejected。
   */
  private resolveProfileYamlPath(profileId: string): string {
    // homeDir 来自系统 VpnExtensionContext，不是外部输入；路径穿越风险只来自 profileId，
    // 后者已由 isValidProfileId 拒绝分隔符、NUL、`.`/`..` 与超长值。
    // 这里只拒绝空 home，避免把系统返回的合法私有路径误判为 path_rejected。
    const home: string = this.homeDir;
    if (home.length === 0) {
      throw new RpcHandlerError('path_rejected');
    }
    return home + '/profiles/' + profileId + '.yaml';
  }

  /**
   * 返回已校验的 `VpnOptions`（设计 §5.4：`vpn.options` 只回 VpnOptions）。
   * 回退码只写固定日志，不混入返回结构。
   */
  private handleVpnOptions(): object {
    const read: VpnOptionsReadResult = readVpnOptions();
    for (let index: number = 0; index < read.codes.length; index++) {
      logWarn('vpn_options', read.codes[index]);
    }
    return read.options;
  }

  private async handleTunStart(params: object): Promise<object> {
    const view: TunStartView = params as TunStartView;
    const scope: ProxyScope | undefined = readScope(view.scope);
    if (scope === undefined) {
      throw new RpcHandlerError('invalid_params');
    }
    const state: CoreState | undefined = parseCoreState(view.state);
    const session: ClashVpnSession = this.ensureSession();

    this.notification.show('starting').then((): void => {}, (): void => {});

    try {
      const result: TunStartResult = await session.start(this.context, {
        scope: scope,
        coreReady: this.coreReady,
        state: state
      });
      this.startedAt = result.startedAt;
      this.activeScope = scope;
      this.lastStateEpoch++;
      this.pushState('connected', scope, result.startedAt, '');
      const profileName: string = readCurrentProfileName();
      this.notification.show('connected', profileName).then((): void => {}, (): void => {});
      return result;
    } catch (error) {
      const failure: ClashSessionError = error as ClashSessionError;
      const code: string = typeof failure.code === 'string' ? failure.code : 'internal';
      const detail: string = failure.detailCode === undefined ? 'start_failed' : failure.detailCode;
      logWarn('tun_start', code);
      this.pushFault(code, detail);
      this.notification.cancel().then((): void => {}, (): void => {});
      throw new RpcHandlerError(code);
    }
  }

  /**
   * `tun.stop`：应答必须先回给客户端，再关监听（由 `stopProxy(true)` 安排 post-reply 关闭）。
   * 停止后通知立即取消，不留「VPN 运行中」。
   */
  private async handleTunStop(): Promise<object> {
    const result: TunStopResult = await this.stopProxy(true);
    this.notification.cancel().then((): void => {}, (): void => {});
    return result;
  }

  private async handleNotificationUpdate(params: object): Promise<object> {
    const view: NotificationUpdateView = params as NotificationUpdateView;
    const status: ClashNotificationStatus = readNotificationStatus(view.status, view.text);
    const nodeName: string = typeof view.nodeName === 'string' ? view.nodeName : '';
    const updated: boolean = await this.notification.show(status, nodeName);
    const result: NotificationUpdateResult = { updated: updated };
    return result;
  }

  private handleDiagnostics(): DiagnosticsResult {
    const session: ClashVpnSession | undefined = this.session;
    const protect: ProtectCounters = session === undefined ? emptyProtect() : session.protectStats();
    const rpc: ClashRpcServer | undefined = this.rpcServer;
    let epoch: number = this.lastStateEpoch;
    if (rpc !== undefined) {
      epoch = rpc.stats().epoch;
    }
    let uptimeMs: number = 0;
    if (this.startedAt > 0 && session !== undefined && session.isActive()) {
      uptimeMs = Math.max(0, Date.now() - this.startedAt);
    }
    const bridge: ClashBridgeCounters = clashCoreBridge.getCounters();
    const counters: DiagnosticsCounters = {
      pendingActions: bridge.pendingActions,
      unrecognizedPayloads: bridge.unrecognizedPayloads,
      malformedPayloads: bridge.malformedPayloads,
      lateResults: bridge.lateResults,
      handlerFailures: bridge.handlerFailures,
      notificationsPublished: this.notification.snapshot().published,
      notificationsFailed: this.notification.snapshot().failed,
      eventsDecoded: this.decoder.snapshot().received,
      eventsDropped: this.decoder.snapshot().droppedEvents
    };
    const result: DiagnosticsResult = {
      protect: protect,
      session: { epoch: epoch, uptimeMs: uptimeMs },
      counters: counters
    };
    return result;
  }

  private async handleShutdown(): Promise<object> {
    // 监听由 RpcServer 在应答后自行关闭（`session.shutdown` 特例）。
    await this.stopProxy(true);
    const shut: boolean = clashCoreBridge.shutdown();
    if (!shut) {
      logWarn('shutdown', 'core_shutdown_failed');
    }
    this.coreReady = false;
    // stopProxy 已安排静默期定时器；内核在这里已经释放，取消定时器避免重复 shutdown。
    this.cancelIdleShutdown();
    this.notification.cancel().then((): void => {}, (): void => {});
    const result: ShutdownResult = { closed: true };
    return result;
  }

  // -------------------------------------------------------------------------
  // 资源释放
  // -------------------------------------------------------------------------

  private async stopProxy(deferRpcClose: boolean): Promise<TunStopResult> {
    const hooks: StopHooks = {
      // RpcServer.stop() 自身会推 state{stopped}；这里不重复推送。
      notifyStopped: (): void => {},
      releaseRpc: (): Promise<boolean> => this.releaseRpc(deferRpcClose),
      cleanupSessionFiles: (): Promise<boolean> => this.cleanupSessionFiles()
    };
    const session: ClashVpnSession | undefined = this.session;
    let result: TunStopResult;
    if (session === undefined) {
      const rpcReleased: boolean = await this.releaseRpc(deferRpcClose);
      const filesReleased: boolean = await this.cleanupSessionFiles();
      const warnings: string[] = [];
      if (!rpcReleased) {
        warnings.push('rpc_release_failed');
      }
      if (!filesReleased) {
        warnings.push('session_cleanup_failed');
      }
      const status: StopStatus = warnings.length === 0 ? 'stopped' : 'stopped_with_warning';
      result = {
        stopped: true,
        status: status,
        released: { tun: true, rpc: rpcReleased },
        warnings: warnings
      };
    } else {
      result = await session.stop(hooks);
    }
    this.startedAt = 0;
    this.scheduleIdleShutdown();
    return result;
  }

  /**
   * 关闭 RPC。
   *
   * `defer=true`（tun.stop / session.shutdown）时本次应答还没入队，直接关连接会吞掉结果；
   * 因此安排到下一轮事件循环，由 `stop()` 排空写队列后再关监听。返回 true 表示
   * 「监听仍运行且关闭已安排」或「已经不在监听」。
   */
  private async releaseRpc(defer: boolean): Promise<boolean> {
    const rpc: ClashRpcServer | undefined = this.rpcServer;
    if (rpc === undefined) {
      return true;
    }
    if (!rpc.isRunning()) {
      return true;
    }
    if (defer) {
      setTimeout((): void => {
        this.closeRpcNow().then((): void => {}, (): void => {});
      }, 0);
      return true;
    }
    return await this.closeRpcNow();
  }

  private async closeRpcNow(): Promise<boolean> {
    const rpc: ClashRpcServer | undefined = this.rpcServer;
    if (rpc === undefined) {
      return true;
    }
    try {
      await rpc.stop();
    } catch (error) {
      logWarn('rpc', 'stop_failed');
      return false;
    }
    if (rpc.isRunning()) {
      logWarn('rpc', 'listener_still_bound');
      return false;
    }
    return true;
  }

  private async cleanupSessionFiles(): Promise<boolean> {
    const files: ClashSessionFiles | undefined = this.sessionFiles;
    if (files === undefined) {
      return true;
    }
    try {
      const summary: SessionCleanupSummary = await files.cleanup();
      return summary.failures === 0;
    } catch (error) {
      logWarn('session', 'cleanup_failed');
      return false;
    }
  }

  /**
   * 停止后 60 s 无新会话：释放内核。SDK 26 `VpnExtensionContext` 没有 `terminateSelf()`，
   * 进程由系统回收（Q5）；这里只保证内核与通知都已释放。
   */
  private scheduleIdleShutdown(): void {
    this.cancelIdleShutdown();
    this.idleTimer = setTimeout((): void => {
      this.idleTimer = -1;
      const session: ClashVpnSession | undefined = this.session;
      if (session !== undefined && session.isActive()) {
        return;
      }
      const shut: boolean = clashCoreBridge.shutdown();
      if (!shut) {
        logWarn('idle', 'core_shutdown_failed');
      }
      this.coreReady = false;
      this.notification.cancel().then((): void => {}, (): void => {});
      this.closeRpcNow().then((): void => {}, (): void => {});
      logWarn('idle', 'terminate_unsupported');
    }, IDLE_SHUTDOWN_MS);
  }

  private cancelIdleShutdown(): void {
    if (this.idleTimer >= 0) {
      clearTimeout(this.idleTimer);
      this.idleTimer = -1;
    }
  }

  private async teardown(): Promise<void> {
    const session: ClashVpnSession | undefined = this.session;
    if (session !== undefined) {
      await session.destroy();
    }
    await this.releaseRpc(false);
    await this.cleanupSessionFiles();
    const shut: boolean = clashCoreBridge.shutdown();
    if (!shut) {
      logWarn('destroy', 'core_shutdown_failed');
    }
    clashCoreBridge.eventHandler = null;
    this.notification.cancel().then((): void => {}, (): void => {});
    this.rpcServer = undefined;
    this.sessionFiles = undefined;
    this.session = undefined;
  }

  // -------------------------------------------------------------------------
  // 内部工具
  // -------------------------------------------------------------------------

  private ensureSession(): ClashVpnSession {
    if (this.session !== undefined) {
      return this.session;
    }
    const callbacks: ClashSessionCallbacks = {
      onProtectFailure: (code: string): void => {
        // 首次失败只提示「网络保护异常（已记录）」；推送固定码，由 UI 决定文案。
        this.pushFault('protect_failed', code);
      },
      onDegraded: (code: string): void => {
        this.pushState('failed', this.activeScope, 0, code);
        this.notification.cancel().then((): void => {}, (): void => {});
      }
    };
    this.session = new ClashVpnSession(this.ownBundle, callbacks);
    return this.session;
  }


  private pushState(state: string, scope: ProxyScope, startedAt: number, errorCode: string): void {
    const rpc: ClashRpcServer | undefined = this.rpcServer;
    if (rpc === undefined) {
      return;
    }
    const data: StatePushData = { state: state, scope: scope };
    if (startedAt > 0) {
      data.startedAt = startedAt;
    }
    if (errorCode.length > 0) {
      data.errorCode = errorCode;
    }
    rpc.push('state', data);
  }

  private pushFault(code: string, detailCode: string): void {
    const rpc: ClashRpcServer | undefined = this.rpcServer;
    if (rpc === undefined) {
      return;
    }
    const data: FaultPushData = { code: code, detailCode: detailCode, count: 1 };
    rpc.push('fault', data);
  }
}

interface QuickStartResult {
  error: string;
}


interface ShutdownResult {
  closed: boolean;
}

/** 只接受规范化 profileId；任何路径分隔符、`..`、NUL 或空串都拒绝。 */
function isValidProfileId(value: string): boolean {
  if (value.length === 0 || value.length > 64) {
    return false;
  }
  if (value.indexOf('/') >= 0 || value.indexOf('\\') >= 0 || value.indexOf('\u0000') >= 0) {
    return false;
  }
  if (value === '.' || value === '..') {
    return false;
  }
  return true;
}

/**
 * 只接受应用私有 `files/profiles/*.yaml` 的绝对路径。
 *
 * 拒绝相对路径、NUL 与含 `..` 的值；非 `.yaml` 与其它目录一律不通过。
 * 不读取文件，也不记录路径内容。
 */
function isSafeProfileYamlPath(value: string): boolean {
  if (!value.startsWith('/') || value.indexOf('\u0000') >= 0 || value.indexOf('..') >= 0) {
    return false;
  }
  if (value.indexOf('/files/profiles/') < 0) {
    return false;
  }
  return value.endsWith('.yaml');
}

function emptyProtect(): ProtectCounters {
  return {
    attempts: 0,
    failures: 0,
    timeouts: 0,
    dropped: 0,
    lastCode: '',
    lastEpoch: 0,
    lastGen: 0,
    degraded: false
  };
}

/** 事件数据转 JSON 文本；对象才序列化，字符串原样返回。 */
function eventPayload(data: JsonPayload): string {
  if (typeof data === 'string') {
    return data;
  }
  if (data === null || typeof data !== 'object') {
    return '';
  }
  try {
    const text: string | undefined = JSON.stringify(data);
    return text === undefined ? '' : text;
  } catch (error) {
    return '';
  }
}