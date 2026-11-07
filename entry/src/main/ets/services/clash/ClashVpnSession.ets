/**
 * VPN 扩展进程的 TUN 会话：VpnConfig 构造、`create`/`startTun`/`getRunTime` 三重证据、
 * protect 可靠性与降级、停止收敛、范围切换重建。
 *
 * 任务：S4-05 / S4-06 / S4-07（docs/integration/clash-proxy-tasks.md L908–L948）。
 *
 * 证据：
 * - docs/integration/clash-proxy-design.md §7.3（VpnConfig 字段与校验）、§7.5（三重证据）、
 *   §7.6（protect 扩展侧约束）、§5.6（停止收敛顺序）、§7.9（错误码）。
 * - 本机 SDK 26 `@ohos.net.vpnExtension.d.ts`：`createVpnConnection(context)`、
 *   `VpnConnection.create(config): Promise<number>`（拒绝授权为 `2203001`）、
 *   `protect(socketFd)`、`destroy()`；`VpnConfig.mtu` 取值 [576,1500]。
 * - entry/src/main/ets/model/ClashVpnConfig.ts（纯构造与校验，MTU 1420、名单互斥）。
 * - entry/src/main/ets/services/clash/ClashCoreBridge.ets（内核门面）；startTun/stopTun/
 *   getCurrentProfileName 尚未由桥导出，本文件按原生 Index.d.ts 的短调用契约直接使用，
 *   属于待回收的临时接缝（见 startTunFd 注释）。
 *
 * 约束：
 * - 只使用具名接口与字符串联合；不使用 `any`/`unknown`/枚举。
 * - 不打印 fd、地址、节点名、配置正文或异常文本；日志只记固定类别码。
 * - `startTun(fd)` 成功后 fd 所有权转移给内核；失败路径只 `conn.destroy()`，
 *   **不重复 close(fd)**。
 * - protect 分支在本类中保持同步入口：先计数、再异步 `conn.protect`，不 await 其他慢操作。
 * - `routeReady` 目前只能以 `conn.create` 成功为依据（设计 §7.5 的已知限制）。
 */

import { VpnExtensionContext, vpnExtension } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AccessControlOptions, CoreState, JsonPayload, ProxyScope, VpnOptions } from '../../model/ClashModels';
import {
  buildVpnConfig,
  validateVpnOptions,
  VPN_CODE_OPTIONS_FALLBACK,
  VPN_CODE_TUN_CONFIG_INVALID,
  VpnAddressPlan,
  VpnConfigPlan,
  VpnRoutePlan
} from '../../model/ClashVpnConfig';
import { clashCoreBridge } from './ClashCoreBridge';

const LOG_DOMAIN: number = 0x0000;
const LOG_TAG: string = 'HarlgramVpnSession';

/** 停止前等待 pending protect 结算的上限（设计 §7.6）。 */
const PROTECT_SETTLE_TIMEOUT_MS: number = 3000;
/** 本端 protect 握手的上限；超时也要 ack，避免 Go dialer 永久阻塞。 */
const PROTECT_ACK_TIMEOUT_MS: number = 3000;
/** 连续失败阈值。 */
const PROTECT_CONSECUTIVE_LIMIT: number = 3;
/** 60 s 窗口内失败次数阈值。 */
const PROTECT_WINDOW_MS: number = 60000;
const PROTECT_WINDOW_LIMIT: number = 5;
/** 失败率阈值与最小样本量。 */
const PROTECT_RATE_MAX: number = 0.01;
const PROTECT_RATE_MIN_ATTEMPTS: number = 100;
/** 连续失败计数在多久无失败后清零。 */
const PROTECT_STREAK_RESET_MS: number = 60000;

const MAX_COUNTER: number = 1000000000;

/** VPN 授权被系统拒绝的错误码（SDK 26 `create` 文档）。 */
const VPN_CREATE_DENIED_CODE: number = 2203001;
/** 通用权限拒绝错误码。 */
const PERMISSION_DENIED_CODE: number = 201;

/** 结构化失败码；与设计 §7.9 共用码表一致。 */
export type TunFailureCode =
  | 'core_init_failed'
  | 'tun_config_invalid'
  | 'tun_create_denied'
  | 'tun_create_failed'
  | 'tun_start_failed'
  | 'protect_degraded'
  | 'internal';

/** protect 最近结果码；不含 fd 值。 */
export type ProtectLastCode =
  | ''
  | 'protect_ok'
  | 'protect_rejected'
  | 'protect_timeout'
  | 'invalid_fd'
  | 'tun_absent'
  | 'protect_degraded'
  | 'notify_failed';

/** 停止状态；任一资源释放失败即 `stopped_with_warning`。 */
export type StopStatus = 'stopped' | 'stopped_with_warning';

/** 单次 protect 的结果；只在 `handleProtect` 内部使用。 */
type ProtectOutcome = 'ok' | 'rejected' | 'timeout';

/**
 * 结构化会话错误。`message` 只等于稳定码，调用方只应依赖 `code`/`detailCode`；
 * 原始异常文本、路径与地址不进入错误对象。
 */
export class ClashSessionError extends Error {
  readonly code: TunFailureCode;
  readonly detailCode: string;

  constructor(code: TunFailureCode, detailCode: string = '') {
    super(code);
    this.name = 'ClashSessionError';
    this.code = code;
    this.detailCode = detailCode;
  }
}

/** `tun.start` 的入参；`coreReady` 由调用链（core.init + quickStart）传入，不自行假设。 */
export interface TunStartRequest {
  scope: ProxyScope;
  coreReady: boolean;
  state?: CoreState;
}

/** 三重证据；任何一项为 false，UI 不得进入 `connected`（设计 §3.3）。 */
export interface TunEvidence {
  coreReady: boolean;
  tunReady: boolean;
  routeReady: boolean;
}

/** 回给 UI 的脱敏 TUN 参数摘要（不含 fd 之外的路径或凭据）。 */
export interface TunOptionsSummary {
  ipv4Address: string;
  ipv6Address: string;
  dnsServerAddress: string;
  mtu: number;
  scope: ProxyScope;
  trustedOnly: boolean;
}

export interface TunStartResult {
  fd: number;
  startedAt: number;
  evidence: TunEvidence;
  options: TunOptionsSummary;
  /** 构造期的诊断码：`options_fallback` 等；不阻断启动。 */
  codes: string[];
}

/** protect 计数快照；可直接写入 `diagnostics.snapshot`。 */
export interface ProtectCounters {
  attempts: number;
  failures: number;
  timeouts: number;
  dropped: number;
  lastCode: ProtectLastCode;
  /** 原生 protect 代次，仅诊断用，不含 fd。 */
  lastEpoch: number;
  lastGen: number;
  degraded: boolean;
}

export interface TunRelease {
  tun: boolean;
  rpc: boolean;
}

export interface TunStopResult {
  stopped: boolean;
  status: StopStatus;
  released: TunRelease;
  /** 固定码列表：`tun_stop_failed`/`tun_destroy_failed`/`rpc_release_failed`/`session_cleanup_failed`。 */
  warnings: string[];
}

/**
 * 停止期间由扩展提供的资源钩子。
 *
 * 顺序由 `ClashVpnSession.stop()` 控制；钩子只负责执行单项释放并返回是否成功，
 * 不得抛出异常（抛出会被计为失败）。
 */
export interface StopHooks {
  /** 推送 `state{stopped}`；必须立即返回，不得 await 网络。 */
  notifyStopped: () => void;
  /** 关闭 RPC 连接与监听，返回端口是否已不再监听。 */
  releaseRpc: () => Promise<boolean>;
  /** 删除 `req-*`/`ack-*` 会话文件，返回目录是否已清空。 */
  cleanupSessionFiles: () => Promise<boolean>;
}

/** 会话内回调；扩展用它推送 fault/state，不阻塞 protect 路径。 */
export interface ClashSessionCallbacks {
  /** 首次 protect 失败（已计数）；扩展可推一条 `fault{protect_failed}`。 */
  onProtectFailure: (code: string) => void;
  /** protect 降级：已调用 `stopTun`，扩展必须推 `state{failed,protect_degraded}`。 */
  onDegraded: (code: string) => void;
}

/** `vpn.options` 读取结果；`codes` 含 `options_fallback`/`tun_config_invalid`。 */
export interface VpnOptionsReadResult {
  options: VpnOptions;
  codes: string[];
}

/** 会话快照；供 `diagnostics.snapshot` 使用。 */
export interface SessionSnapshot {
  active: boolean;
  fd: number;
  startedAt: number;
  scope: ProxyScope;
  evidence: TunEvidence;
  protect: ProtectCounters;
}

/** 内核 `getAndroidVpnOptions` 的线格式视图（字段全部可缺省）。 */
interface VpnOptionsWire {
  enable?: JsonPayload;
  port?: JsonPayload;
  accessControl?: JsonPayload;
  allowBypass?: JsonPayload;
  systemProxy?: JsonPayload;
  bypassDomain?: JsonPayload;
  routeAddress?: JsonPayload;
  ipv4Address?: JsonPayload;
  ipv6Address?: JsonPayload;
  dnsServerAddress?: JsonPayload;
  includePackage?: JsonPayload;
  excludePackage?: JsonPayload;
}

interface AccessControlWire {
  enable?: JsonPayload;
  mode?: JsonPayload;
  acceptList?: JsonPayload;
  rejectList?: JsonPayload;
}

/** 内部 protect 累加状态；`streak`/`failureTimes` 不对外暴露内容。 */
interface ProtectState {
  attempts: number;
  failures: number;
  timeouts: number;
  dropped: number;
  lastCode: ProtectLastCode;
  lastEpoch: number;
  lastGen: number;
  degraded: boolean;
  streak: number;
  lastFailureAt: number;
  firstFailureNotified: boolean;
  failureTimes: number[];
}

function nextCount(value: number): number {
  return value >= MAX_COUNTER ? MAX_COUNTER : value + 1;
}

function emptyEvidence(): TunEvidence {
  return { coreReady: false, tunReady: false, routeReady: false };
}

function emptyOptionsSummary(): TunOptionsSummary {
  return {
    ipv4Address: '',
    ipv6Address: '',
    dnsServerAddress: '',
    mtu: 0,
    scope: 'global',
    trustedOnly: false
  };
}

function createProtectState(): ProtectState {
  return {
    attempts: 0,
    failures: 0,
    timeouts: 0,
    dropped: 0,
    lastCode: '',
    lastEpoch: 0,
    lastGen: 0,
    degraded: false,
    streak: 0,
    lastFailureAt: 0,
    firstFailureNotified: false,
    failureTimes: []
  };
}

/** 固定类别码日志；不含地址、fd、节点名或异常文本。 */
function logWarn(category: string, code: string): void {
  hilog.warn(LOG_DOMAIN, LOG_TAG, 'vpn session %{public}s: %{public}s', category, code);
}

/**
 * 交接 TUN fd 给内核（`startTun` 成功后所有权转移）。
 *
 * 说明：内核短调用统一经 `ClashCoreBridge` 门面，扩展目录不直接 import 原生库。
 * 本模块只在扩展进程内使用，不进入 UI 进程。
 */
function startTunFd(fd: number): boolean {
  return clashCoreBridge.startTun(fd);
}

/** 只停止 TUN；返回是否成功。 */
function stopTunSafely(): boolean {
  try {
    clashCoreBridge.stopTun();
    return true;
  } catch (error) {
    return false;
  }
}

/** 只停止 TUN；短调用失败不抛给调用方，只记固定码。 */
function stopTunQuietly(): void {
  if (!stopTunSafely()) {
    logWarn('tun', 'stop_tun_failed');
  }
}

/** 当前生效配置名（用户可见名称）；未启动或原生不可用时返回空串。 */
export function readCurrentProfileName(): string {
  try {
    return clashCoreBridge.getCurrentProfileName();
  } catch (error) {
    return '';
  }
}

// ---------------------------------------------------------------------------
// 选项读取（`vpn.options` 与 `tun.start` 共用）
// ---------------------------------------------------------------------------

function readBoolean(value: JsonPayload | undefined, fallback: boolean): boolean {
  return typeof value === 'boolean' ? value : fallback;
}

function readNumber(value: JsonPayload | undefined, fallback: number): number {
  if (typeof value !== 'number' || !Number.isFinite(value)) {
    return fallback;
  }
  return value;
}

function readText(value: JsonPayload | undefined): string {
  return typeof value === 'string' ? value : '';
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

function readAccessControl(value: JsonPayload | undefined): AccessControlOptions | undefined {
  if (value === undefined || value === null || typeof value !== 'object' || Array.isArray(value)) {
    return undefined;
  }
  const wire: AccessControlWire = value as AccessControlWire;
  if (typeof wire.enable !== 'boolean' || typeof wire.mode !== 'string') {
    return undefined;
  }
  const control: AccessControlOptions = {
    enable: wire.enable,
    mode: wire.mode,
    acceptList: readStringArray(wire.acceptList),
    rejectList: readStringArray(wire.rejectList)
  };
  return control;
}

function mergeCodes(target: string[], extra: string[]): void {
  for (let index: number = 0; index < extra.length; index++) {
    if (target.indexOf(extra[index]) < 0) {
      target.push(extra[index]);
    }
  }
}

/**
 * 读取并规范化内核建议的 TUN 参数。
 *
 * - 原生返回空串或非法 JSON：全部走设计默认值，并记录 `options_fallback`；
 * - 字段缺失/空串：`ClashVpnConfig` 会回退设计默认值，空 `ipv4Address`/`dnsServerAddress`
 *   也在此记录回退码（不把 `undefined` 传给下游）；
 * - 非法地址/路由：`validateVpnOptions` 返回 `tun_config_invalid`，调用方不得 `create`。
 */
export function readVpnOptions(): VpnOptionsReadResult {
  const codes: string[] = [];
  let wire: VpnOptionsWire | undefined = undefined;
  let raw: string = '';
  try {
    raw = clashCoreBridge.getAndroidVpnOptions();
  } catch (error) {
    raw = '';
  }
  if (raw.length === 0) {
    codes.push(VPN_CODE_OPTIONS_FALLBACK);
  } else {
    try {
      const parsed: object = JSON.parse(raw) as object;
      if (parsed !== null && typeof parsed === 'object' && !Array.isArray(parsed)) {
        wire = parsed as VpnOptionsWire;
      }
    } catch (error) {
      wire = undefined;
    }
    if (wire === undefined) {
      codes.push(VPN_CODE_OPTIONS_FALLBACK);
    }
  }

  const options: VpnOptions = {
    enable: true,
    port: 0,
    allowBypass: false,
    systemProxy: false,
    ipv4Address: '',
    ipv6Address: '',
    dnsServerAddress: ''
  };
  if (wire !== undefined) {
    options.enable = readBoolean(wire.enable, true);
    options.port = readNumber(wire.port, 0);
    options.allowBypass = readBoolean(wire.allowBypass, false);
    options.systemProxy = readBoolean(wire.systemProxy, false);
    options.ipv4Address = readText(wire.ipv4Address);
    options.ipv6Address = readText(wire.ipv6Address);
    options.dnsServerAddress = readText(wire.dnsServerAddress);
    options.routeAddress = readStringArray(wire.routeAddress);
    options.bypassDomain = readStringArray(wire.bypassDomain);
    options.includePackage = readStringArray(wire.includePackage);
    options.excludePackage = readStringArray(wire.excludePackage);
    const control: AccessControlOptions | undefined = readAccessControl(wire.accessControl);
    if (control !== undefined) {
      options.accessControl = control;
    }
    if (options.ipv4Address.length === 0) {
      codes.push(VPN_CODE_OPTIONS_FALLBACK);
    }
    if (options.dnsServerAddress.length === 0) {
      codes.push(VPN_CODE_OPTIONS_FALLBACK);
    }
  }

  mergeCodes(codes, validateVpnOptions(options));
  return { options: options, codes: codes };
}

// ---------------------------------------------------------------------------
// VpnConfig 映射
// ---------------------------------------------------------------------------

function addressFamily(address: string): number {
  return address.indexOf(':') >= 0 ? 2 : 1;
}

function toRoutePlan(route: VpnRoutePlan): vpnExtension.RouteInfo {
  const info: vpnExtension.RouteInfo = {
    interface: '',
    destination: {
      address: { address: route.address, family: addressFamily(route.address) },
      prefixLength: route.prefixLength
    },
    // `hasGateway=false` 时系统忽略 gateway 值，但字段类型要求非空结构。
    gateway: { address: '', family: 1 },
    hasGateway: false,
    isDefaultRoute: route.isDefaultRoute
  };
  return info;
}

/** 纯计划 → SDK `VpnConfig`；只映射设计 §7.3 字段，忽略 port/bypassDomain/accessControl。 */
function toVpnConfig(plan: VpnConfigPlan): vpnExtension.VpnConfig {
  const addresses: vpnExtension.LinkAddress[] = [];
  for (let index: number = 0; index < plan.addresses.length; index++) {
    const item: VpnAddressPlan = plan.addresses[index];
    addresses.push({
      address: { address: item.address, family: addressFamily(item.address) },
      prefixLength: item.prefixLength
    });
  }
  const routes: vpnExtension.RouteInfo[] = [];
  for (let index: number = 0; index < plan.routes.length; index++) {
    routes.push(toRoutePlan(plan.routes[index]));
  }
  const config: vpnExtension.VpnConfig = {
    addresses: addresses,
    routes: routes,
    mtu: plan.mtu,
    dnsAddresses: plan.dns,
    isIPv4Accepted: plan.isIPv4Accepted,
    isIPv6Accepted: plan.isIPv6Accepted,
    isInternal: false,
    isBlocking: false,
    trustedApplications: plan.trustedApplications,
    blockedApplications: plan.blockedApplications
  };
  return config;
}

function summarize(plan: VpnConfigPlan, scope: ProxyScope): TunOptionsSummary {
  const summary: TunOptionsSummary = {
    ipv4Address: plan.addresses.length > 0 ? plan.addresses[0].address : '',
    ipv6Address: plan.isIPv6Accepted && plan.addresses.length > 1 ? plan.addresses[1].address : '',
    dnsServerAddress: plan.dns.length > 0 ? plan.dns[0] : '',
    mtu: plan.mtu,
    scope: scope,
    trustedOnly: plan.trustedApplications.length > 0
  };
  return summary;
}

/** 把 `create` 异常收敛为稳定码；不保留异常文本。 */
function createFailure(error: BusinessError): ClashSessionError {
  if (error.code === VPN_CREATE_DENIED_CODE || error.code === PERMISSION_DENIED_CODE) {
    return new ClashSessionError('tun_create_denied', 'vpn_denied');
  }
  return new ClashSessionError('tun_create_failed', 'create_error');
}

// ---------------------------------------------------------------------------
// 会话
// ---------------------------------------------------------------------------

/**
 * 一个扩展进程内最多一个活动 TUN 会话。
 *
 * `start` 可重复调用：先销毁旧连接再建新连接（范围切换、重连都走同一条路径）。
 */
export class ClashVpnSession {
  private readonly ownBundle: string;
  private readonly callbacks: ClashSessionCallbacks;

  private connection: vpnExtension.VpnConnection | undefined = undefined;
  private fd: number = -1;
  private startedAt: number = 0;
  private scope: ProxyScope = 'global';
  private evidence: TunEvidence = emptyEvidence();
  private optionsSummary: TunOptionsSummary = emptyOptionsSummary();
  private protect: ProtectState = createProtectState();
  private pendingProtect: Set<Promise<void>> = new Set<Promise<void>>();

  constructor(ownBundle: string, callbacks: ClashSessionCallbacks) {
    this.ownBundle = ownBundle;
    this.callbacks = callbacks;
  }

  /**
   * 建 TUN 并交接 fd 给内核。
   *
   * 前置：调用方已确认 `core.init` 与 `quickStart` 成功（`request.coreReady=true`）。
   * 失败时抛出 `ClashSessionError`，不留下半建立的连接。
   */
  async start(context: VpnExtensionContext, request: TunStartRequest): Promise<TunStartResult> {
    if (!request.coreReady) {
      throw new ClashSessionError('core_init_failed', 'core_not_ready');
    }
    if (request.scope === 'harlgramOnly' && this.ownBundle.length === 0) {
      throw new ClashSessionError('tun_config_invalid', 'own_bundle_missing');
    }
    // 旧 TUN 必须先释放，避免第二个 vpn-tun（Q10）。
    if (this.connection !== undefined) {
      await this.destroyTunnel();
    }

    const read: VpnOptionsReadResult = readVpnOptions();
    if (read.codes.indexOf(VPN_CODE_TUN_CONFIG_INVALID) >= 0) {
      throw new ClashSessionError('tun_config_invalid', 'options');
    }

    if (request.state !== undefined) {
      // CoreState 只影响分流参数；失败不阻断 TUN（内核稍后可用 setState 修正）。
      try {
        clashCoreBridge.setState(request.state);
      } catch (error) {
        logWarn('state', 'set_state_failed');
      }
    }

    let plan: VpnConfigPlan;
    try {
      plan = buildVpnConfig(read.options, request.scope, this.ownBundle);
    } catch (error) {
      throw new ClashSessionError('tun_config_invalid', 'plan');
    }
    const config: vpnExtension.VpnConfig = toVpnConfig(plan);

    let conn: vpnExtension.VpnConnection;
    try {
      conn = vpnExtension.createVpnConnection(context);
    } catch (error) {
      throw new ClashSessionError('tun_create_failed', 'connection');
    }
    this.connection = conn;

    let createdFd: number;
    try {
      // 系统 VPN 授权弹窗在这里出现；用户拒绝会 reject（2203001）。
      createdFd = await conn.create(config);
    } catch (error) {
      this.connection = undefined;
      // 授权被拒/创建异常：不留半建立的连接，也不要重复 close(fd)。
      await this.destroyConnection(conn);
      const failure: ClashSessionError = createFailure(error as BusinessError);
      logWarn('tun', failure.detailCode);
      throw failure;
    }
    if (createdFd <= 0) {
      this.connection = undefined;
      await this.destroyConnection(conn);
      throw new ClashSessionError('tun_create_failed', 'fd_invalid');
    }

    this.fd = createdFd;
    let handedOver: boolean = false;
    try {
      handedOver = startTunFd(createdFd);
    } catch (error) {
      handedOver = false;
    }
    if (!handedOver) {
      // fd 所有权在 startTun 入口已转移给内核；失败时只销毁连接，不 close(fd)。
      this.resetTunnelState();
      await this.destroyConnection(conn);
      throw new ClashSessionError('tun_start_failed', 'start_tun');
    }

    let runtime: number = 0;
    try {
      runtime = clashCoreBridge.getRunTime();
    } catch (error) {
      runtime = 0;
    }
    if (runtime <= 0) {
      try {
        stopTunQuietly();
      } catch (error) {
        logWarn('tun', 'stop_after_runtime_zero_failed');
      }
      this.resetTunnelState();
      await this.destroyConnection(conn);
      throw new ClashSessionError('tun_start_failed', 'runtime_zero');
    }

    this.startedAt = Date.now();
    this.scope = request.scope;
    this.evidence = { coreReady: true, tunReady: true, routeReady: true };
    this.optionsSummary = summarize(plan, request.scope);
    this.protect = createProtectState();
    return {
      fd: this.fd,
      startedAt: this.startedAt,
      evidence: this.evidence,
      options: this.optionsSummary,
      codes: read.codes
    };
  }

  /**
   * 范围切换：先拆旧 TUN，再按新 `trustedApplications` 重建。
   *
   * 新范围失败时回滚旧范围并重建；若回滚也失败，错误码仍来自第一次失败，
   * `detailCode` 标记 `scope_rollback`。
   */
  async setScope(context: VpnExtensionContext, scope: ProxyScope,
    coreReady: boolean): Promise<TunStartResult> {
    const previous: ProxyScope = this.scope;
    const wasActive: boolean = this.connection !== undefined;
    await this.destroyTunnel();
    try {
      return await this.start(context, { scope: scope, coreReady: coreReady });
    } catch (error) {
      const failure: ClashSessionError = error as ClashSessionError;
      if (wasActive) {
        // 只有原本在运行时才回滚重建，避免「未开启」状态被错误地拉起 TUN。
        try {
          await this.start(context, { scope: previous, coreReady: coreReady });
        } catch (rollbackError) {
          const rollback: ClashSessionError = rollbackError as ClashSessionError;
          logWarn('scope', rollback.detailCode);
        }
      }
      throw new ClashSessionError(failure.code, 'scope_rollback');
    }
  }

  /**
   * protect 入口：**先**处理、**不 await** 其他慢操作。
   *
   * `fd<=0` 直接失败计数（无法 ack）；TUN 未建立时立即失败计数，绝不无保护放行。
   * 正常路径异步 `conn.protect(fd)`，成功/失败/超时都会 `notifyProtected(fd)`。
   */
  handleProtect(fd: number, epoch: number, gen: number): void {
    this.protect.attempts = nextCount(this.protect.attempts);
    this.protect.lastEpoch = epoch;
    this.protect.lastGen = gen;
    if (fd <= 0) {
      this.recordProtectFailure('invalid_fd');
      return;
    }
    const conn: vpnExtension.VpnConnection | undefined = this.connection;
    if (conn === undefined) {
      // 设计 T-S4-06：TUN 未建立也必须 ack，否则 Go dialer 会阻塞到 3 s 超时。
      this.recordProtectFailure('tun_absent');
      this.ackProtect(fd);
      return;
    }

    let settled: boolean = false;
    let timer: number = -1;
    const finish = (outcome: ProtectOutcome): void => {
      if (settled) {
        return;
      }
      settled = true;
      if (timer >= 0) {
        clearTimeout(timer);
        timer = -1;
      }
      if (outcome === 'ok') {
        this.protect.lastCode = 'protect_ok';
        this.protect.streak = 0;
      } else if (outcome === 'timeout') {
        this.protect.timeouts = nextCount(this.protect.timeouts);
        this.recordProtectFailure('protect_timeout');
      } else {
        this.recordProtectFailure('protect_rejected');
      }
      this.ackProtect(fd);
    };

    let call: Promise<void>;
    try {
      call = conn.protect(fd);
    } catch (error) {
      // 同步抛出等价于一次失败；fd 仍要 ack，避免 Go dialer 卡死。
      this.recordProtectFailure('protect_rejected');
      this.ackProtect(fd);
      return;
    }
    const tracked: Promise<void> = call.then((): void => {
      finish('ok');
    }, (): void => {
      finish('rejected');
    });
    this.pendingProtect.add(tracked);
    tracked.then((): void => {
      this.pendingProtect.delete(tracked);
    });
    timer = setTimeout((): void => {
      timer = -1;
      finish('timeout');
    }, PROTECT_ACK_TIMEOUT_MS);
  }

  /** protect 计数副本。 */
  protectStats(): ProtectCounters {
    const counters: ProtectCounters = {
      attempts: this.protect.attempts,
      failures: this.protect.failures,
      timeouts: this.protect.timeouts,
      dropped: this.protect.dropped,
      lastCode: this.protect.lastCode,
      lastEpoch: this.protect.lastEpoch,
      lastGen: this.protect.lastGen,
      degraded: this.protect.degraded
    };
    return counters;
  }

  isActive(): boolean {
    return this.connection !== undefined;
  }

  snapshot(): SessionSnapshot {
    const snapshot: SessionSnapshot = {
      active: this.connection !== undefined,
      fd: this.fd,
      startedAt: this.startedAt,
      scope: this.scope,
      evidence: this.evidence,
      protect: this.protectStats()
    };
    return snapshot;
  }

  /**
   * 停止收敛（设计 §5.6、T-S4-07）。
   *
   * 顺序：等待 pending protect 结算或 3 s → `stopTun`（失败继续）→ `destroy` →
   * `state{stopped}` → 关 RPC/监听 → 删会话文件。任一释放失败 → `stopped_with_warning`。
   */
  async stop(hooks: StopHooks): Promise<TunStopResult> {
    const warnings: string[] = [];
    await this.settleProtect();

    const hadTunnel: boolean = this.connection !== undefined || this.fd > 0;
    const tunStopped: boolean = stopTunSafely();
    if (!tunStopped && hadTunnel) {
      warnings.push('tun_stop_failed');
      logWarn('stop', 'stop_tun_failed');
    }

    const conn: vpnExtension.VpnConnection | undefined = this.connection;
    this.connection = undefined;
    let tunDestroyed: boolean = true;
    if (conn !== undefined) {
      try {
        await conn.destroy();
      } catch (error) {
        tunDestroyed = false;
        warnings.push('tun_destroy_failed');
        logWarn('stop', 'destroy_failed');
      }
    }
    // 没有活动 TUN 时视为已释放（create 失败或已降级销毁）。
    const tunReleased: boolean = hadTunnel ? (tunStopped && tunDestroyed) : true;
    this.resetTunnelState();

    try {
      hooks.notifyStopped();
    } catch (error) {
      warnings.push('state_push_failed');
    }

    let rpcReleased: boolean = false;
    try {
      rpcReleased = await hooks.releaseRpc();
    } catch (error) {
      rpcReleased = false;
    }
    if (!rpcReleased) {
      warnings.push('rpc_release_failed');
    }

    let filesReleased: boolean = true;
    try {
      filesReleased = await hooks.cleanupSessionFiles();
    } catch (error) {
      filesReleased = false;
    }
    if (!filesReleased) {
      warnings.push('session_cleanup_failed');
    }

    const status: StopStatus = warnings.length === 0 ? 'stopped' : 'stopped_with_warning';
    const result: TunStopResult = {
      stopped: tunReleased,
      status: status,
      released: { tun: tunReleased, rpc: rpcReleased },
      warnings: warnings
    };
    return result;
  }

  /** 扩展 `onDestroy` 的紧急拆除：等待 protect 结算后只释放 TUN 资源。 */
  async destroy(): Promise<void> {
    await this.settleProtect();
    try {
      stopTunQuietly();
    } catch (error) {
      logWarn('destroy', 'stop_tun_failed');
    }
    const conn: vpnExtension.VpnConnection | undefined = this.connection;
    this.connection = undefined;
    if (conn !== undefined) {
      try {
        await conn.destroy();
      } catch (error) {
        logWarn('destroy', 'destroy_failed');
      }
    }
    this.resetTunnelState();
  }

  // -------------------------------------------------------------------------
  // 内部：protect 计数与降级
  // -------------------------------------------------------------------------

  private recordProtectFailure(code: ProtectLastCode): void {
    const now: number = Date.now();
    if (this.protect.streak > 0 && now - this.protect.lastFailureAt >= PROTECT_STREAK_RESET_MS) {
      this.protect.streak = 0;
    }
    this.protect.failures = nextCount(this.protect.failures);
    this.protect.lastCode = code;
    this.protect.streak = nextCount(this.protect.streak);
    this.protect.lastFailureAt = now;
    this.protect.failureTimes.push(now);
    this.purgeFailureWindow(now);

    if (!this.protect.firstFailureNotified) {
      this.protect.firstFailureNotified = true;
      // 首次失败只上报一次，正文由 UI 决定（设计 T-S4-06）。
      this.callbacks.onProtectFailure(code);
    }
    this.evaluateDegradation();
  }

  private purgeFailureWindow(now: number): void {
    const kept: number[] = [];
    for (let index: number = 0; index < this.protect.failureTimes.length; index++) {
      const at: number = this.protect.failureTimes[index];
      if (now - at <= PROTECT_WINDOW_MS) {
        kept.push(at);
      }
    }
    this.protect.failureTimes = kept;
  }

  /**
   * 降级判定：连续 3 次 / 60 s 内 ≥5 次 / 失败率 >1% 且 attempts ≥100。
   * 命中后立即 `stopTun` 并销毁连接，不自动无限重试。
   */
  private evaluateDegradation(): void {
    if (this.protect.degraded) {
      return;
    }
    const now: number = Date.now();
    if (this.protect.streak > 0 && now - this.protect.lastFailureAt >= PROTECT_STREAK_RESET_MS) {
      this.protect.streak = 0;
    }
    this.purgeFailureWindow(now);

    const streakHit: boolean = this.protect.streak >= PROTECT_CONSECUTIVE_LIMIT;
    const windowHit: boolean = this.protect.failureTimes.length >= PROTECT_WINDOW_LIMIT;
    const rateHit: boolean = this.protect.attempts >= PROTECT_RATE_MIN_ATTEMPTS &&
      this.protect.failures > 0 &&
      this.protect.failures / this.protect.attempts > PROTECT_RATE_MAX;
    if (!streakHit && !windowHit && !rateHit) {
      return;
    }

    this.protect.degraded = true;
    this.protect.lastCode = 'protect_degraded';
    logWarn('protect', 'degraded');
    try {
      stopTunQuietly();
    } catch (error) {
      logWarn('protect', 'degrade_stop_tun_failed');
    }
    const conn: vpnExtension.VpnConnection | undefined = this.connection;
    this.connection = undefined;
    this.fd = -1;
    this.startedAt = 0;
    this.evidence = emptyEvidence();
    if (conn !== undefined) {
      // 不在这里 await：protect 路径不能等待慢操作。
      conn.destroy().catch((): void => {
        logWarn('protect', 'degrade_destroy_failed');
      });
    }
    try {
      this.callbacks.onDegraded('protect_degraded');
    } catch (error) {
      logWarn('protect', 'degrade_callback_failed');
    }
  }

  private ackProtect(fd: number): void {
    try {
      clashCoreBridge.notifyProtected(fd);
    } catch (error) {
      this.protect.dropped = nextCount(this.protect.dropped);
      this.protect.lastCode = 'notify_failed';
      logWarn('protect', 'notify_failed');
    }
  }

  // -------------------------------------------------------------------------
  // 内部：资源释放
  // -------------------------------------------------------------------------

  /** 等待在途 protect 结算或 3 s 超时，避免 fd 复用错配。 */
  private async settleProtect(): Promise<void> {
    if (this.pendingProtect.size === 0) {
      return;
    }
    const all: Promise<void>[] = [];
    this.pendingProtect.forEach((item: Promise<void>): void => {
      all.push(item);
    });
    if (all.length === 0) {
      return;
    }
    let timer: number = -1;
    const guard: Promise<void> = new Promise<void>((resolve: () => void): void => {
      timer = setTimeout((): void => {
        resolve();
      }, PROTECT_SETTLE_TIMEOUT_MS);
    });
    await Promise.race([Promise.all(all), guard]);
    if (timer >= 0) {
      clearTimeout(timer);
      timer = -1;
    }
    this.pendingProtect.clear();
  }

  /** 只拆 TUN，保留 RPC 与通知；用于范围切换与重连。 */
  private async destroyTunnel(): Promise<void> {
    await this.settleProtect();
    try {
      stopTunQuietly();
    } catch (error) {
      logWarn('destroy', 'stop_tun_failed');
    }
    const conn: vpnExtension.VpnConnection | undefined = this.connection;
    this.connection = undefined;
    if (conn !== undefined) {
      await this.destroyConnection(conn);
    }
    this.resetTunnelState();
  }

  private async destroyConnection(conn: vpnExtension.VpnConnection): Promise<void> {
    try {
      await conn.destroy();
    } catch (error) {
      logWarn('tun', 'destroy_failed');
    }
  }

  private resetTunnelState(): void {
    this.fd = -1;
    this.startedAt = 0;
    this.evidence = emptyEvidence();
    this.optionsSummary = emptyOptionsSummary();
  }
}