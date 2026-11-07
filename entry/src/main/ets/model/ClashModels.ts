/**
 * Clash 领域模型与 RPC / Action 信封类型。
 *
 * 纯类型与常量模块：不引用任何 HarmonyOS Kit，也不引用工程内其他模块，
 * 可在宿主机 TypeScript 下直接转译与单元测试。
 *
 * 证据来源：
 * - docs/integration/clash-proxy-design.md §8.2（字段定义与 Dart 对应）、
 *   §3.3（六态与三重证据）、§5.2-§5.4（RPC 帧、方法表与上限）、§9（Action 真实协议）。
 * - FlClash Dart 侧 lib/models/profile.dart（Profile/SubscriptionInfo/OverrideData）、
 *   lib/models/common.dart（Proxy/Group）、core/constant.go（InitParams/SetupParams）、
 *   core/state/state.go（CoreState/VpnOptions）。
 *
 * 安全约定：订阅 URL 明文、节点密码、UUID、token 不进入本模型。Profile 只保存
 * 「是否存在订阅 URL」与域名摘要；真实 URL 由 Asset 安全存储持有。
 */

// ---------------------------------------------------------------------------
// 状态与范围（设计 §3.3、§8.2；全部用字符串字面量联合，ArkTS 不使用枚举）
// ---------------------------------------------------------------------------

/** 代理运行状态唯一真值；只有 connected 允许成功视觉。 */
export type ClashState =
  | 'unconfigured'
  | 'unauthorized'
  | 'preparing'
  | 'connected'
  | 'stopped'
  | 'failed';

/** 代理生效范围：global 为设备级，harlgramOnly 仅本应用走代理。 */
export type ProxyScope = 'global' | 'harlgramOnly';

/** preparing 的细分原因，仅用于文案与重连预算，不新增顶层状态。 */
export type PreparingReason = 'start' | 'apply' | 'scope' | 'reconnect';

// ---------------------------------------------------------------------------
// 状态机输入输出（供 model/ClashStateMachine.ts 使用）
// ---------------------------------------------------------------------------

/**
 * 状态机事件，逐项对应设计 §3.3 迁移表：
 * - importSucceeded：导入有效配置（unconfigured → stopped）
 * - enableRequested：用户请求开启（stopped → preparing；无有效配置时拒绝）
 * - profileRemoved：生效配置被删除或外部失效（→ unconfigured）
 * - evidenceReady：E1+E2+E3 齐备（preparing → connected）
 * - authDenied：系统授权被拒（preparing → unauthorized）
 * - evidenceFailed：任一证据失败（preparing → failed）
 * - prepareTimeout：准备阶段 60 s 超时（preparing → failed）
 * - cancelled：用户取消启动（preparing → stopped）
 * - stopRequested：用户关闭（connected → stopped）
 * - linkLost：断连/扩展被回收（connected → preparing 或 failed）
 * - reconnectExhausted：重连预算（5 次）耗尽（→ failed）
 * - retryRequested：用户重试（unauthorized/failed → preparing）
 * - appRestarted：应用重启重建（任意 → stopped 或 unconfigured）
 */
export type StateEvent =
  | 'importSucceeded'
  | 'enableRequested'
  | 'profileRemoved'
  | 'evidenceReady'
  | 'authDenied'
  | 'evidenceFailed'
  | 'prepareTimeout'
  | 'cancelled'
  | 'stopRequested'
  | 'linkLost'
  | 'reconnectExhausted'
  | 'retryRequested'
  | 'appRestarted';

/** 三重证据：E1 内核就绪、E2 TUN 就绪、E3 路由就绪；缺一不可进入 connected。 */
export interface StateEvidence {
  coreReady: boolean;
  tunReady: boolean;
  routeReady: boolean;
}

/** 状态迁移的守卫事实；时间由调用方注入，状态机自身不读时钟。 */
export interface StateFacts {
  evidence: StateEvidence;
  /** 是否存在有效配置（校验通过且节点数大于 0）。 */
  hasValidProfile: boolean;
  /** 事件携带的会话 epoch；与输入 epoch 不一致时按 stale_epoch 拒绝。 */
  epoch: number;
  reason?: PreparingReason;
  /** 失败分类码；由 S1-02 的 ProxyErrorCode 收窄，本层先用字符串承载。 */
  errorCode?: string;
}

/** 状态机拒绝原因：旧 epoch、非法迁移、无有效配置。 */
export interface StateRejection {
  code: 'stale_epoch' | 'illegal_transition' | 'no_valid_profile';
  detail?: string;
}

/** 一次迁移的记录，用于诊断环形缓冲。 */
export interface StateTransitionRecord {
  from: ClashState;
  to: ClashState;
  event: StateEvent;
  epoch: number;
  reason?: PreparingReason;
  errorCode?: string;
}

/** 状态机输入：当前状态、当前会话 epoch、事件与守卫事实。 */
export interface StateTransitionInput {
  state: ClashState;
  epoch: number;
  event: StateEvent;
  facts: StateFacts;
}

/** 状态机输出：新状态、是否变化、可选拒绝信息与迁移记录。 */
export interface StateTransitionOutput {
  state: ClashState;
  epoch: number;
  changed: boolean;
  rejected?: StateRejection;
  record: StateTransitionRecord;
}

// ---------------------------------------------------------------------------
// Profile（Dart Profile：lib/models/profile.dart）
// ---------------------------------------------------------------------------

/** 订阅响应头 subscription-userinfo 的四项统计；expire 单位为秒（上游一致）。 */
export interface SubscriptionInfo {
  upload?: number;
  download?: number;
  total?: number;
  expire?: number;
}

/** 规则覆盖方式：added 追加、override 替换（Dart OverrideData.type）。 */
export type OverrideType = 'added' | 'override';

/** 规则覆盖/追加（Dart OverrideData/OverrideRule）。 */
export interface OverrideData {
  enable: boolean;
  type: OverrideType;
  overrideRules: string[];
  addedRules: string[];
}

/**
 * 配置/订阅元数据（Dart Profile）。
 * 与 Dart 的差异：url 不再是明文字段，只保留 hasUrl 与域名摘要 urlHost；
 * autoUpdateDuration 统一用毫秒表示；unfoldSet 用数组保存以保持 JSON 可序列化。
 */
export interface ProxyProfile {
  /** 本地生成，满足 PROFILE_ID_PATTERN。 */
  id: string;
  /** 用户可见名，空则由调用方生成；不超过 64 字符。 */
  label?: string;
  /** 最近一次应用的组名（Dart currentGroupName）。 */
  currentGroupName?: string;
  /** 是否为订阅来源（Dart url 非空即订阅；明文 URL 不进入本模型）。 */
  hasUrl: boolean;
  /** 订阅 URL 的域名摘要，仅用于展示；不含 userinfo、path、query。 */
  urlHost?: string;
  /** 最近一次成功更新时间（epoch ms，Dart lastUpdateDate）。 */
  lastUpdateDate?: number;
  /** 自动更新间隔（毫秒，Dart autoUpdateDuration）。 */
  autoUpdateDurationMs: number;
  /** 是否参与自动更新（Dart autoUpdate）。 */
  autoUpdate: boolean;
  subscriptionInfo?: SubscriptionInfo;
  /** 组名 → 节点名；随 profile 保存，切换 profile 不串用。 */
  selectedMap: Record<string, string>;
  /** UI 展开的组名（Dart Set<String>，持久化用数组）。 */
  unfoldSet: string[];
  overrideData: OverrideData;
  /** 订阅响应头白名单缓存（Dart providerHeaders）。 */
  providerHeaders: Record<string, string>;
}

// ---------------------------------------------------------------------------
// 设置（设计 §8.2 ProxySettings + Dart AppSettingProps 子集）
// ---------------------------------------------------------------------------

/** 内核日志级别（core UpdateParams 的 log-level 取值）。 */
export type LogLevel = 'silent' | 'error' | 'warning' | 'info' | 'debug';

/**
 * 代理行为设置。
 * scope 对应设计新增的范围开关；testUrl/autoUpdate/logLevel/closeConnections/
 * sendDeviceHeaders 来自 Dart AppSettingProps 与 NetworkProps。
 */
export interface ProxySettings {
  scope: ProxyScope;
  /** 测速地址；非敏感，可配置，非法值由上层回退默认。 */
  testUrl: string;
  /** 是否启用订阅自动更新（本 MVP 固定为 false）。 */
  autoUpdate: boolean;
  logLevel: LogLevel;
  /** 切换节点后是否关闭已有连接（Dart closeConnections）。 */
  closeConnections: boolean;
  /** 拉取订阅时是否附加设备信息头（Dart sendDeviceHeaders）。 */
  sendDeviceHeaders: boolean;
}

// ---------------------------------------------------------------------------
// 节点、组与延迟（Dart Proxy/Group：lib/models/common.dart、lib/providers/app.dart）
// ---------------------------------------------------------------------------

/** 节点可用性：第三个取值表示内核未给出 alive 或类型无法判定，UI 需中性展示。 */
export type ProxyAvailability = 'available' | 'unavailable' | 'unknown';

/** 节点展示模型（Dart Proxy：name/type/now/serverDescription）。 */
export interface ProxyNode {
  /** 内存键 groupName + '/' + name，不持久化、不写入日志。 */
  id: string;
  name: string;
  /** 内核 protocol type，如 Shadowsocks/VMess/Selector。 */
  type: string;
  /** 大写展示标签，如 SS/VMESS。 */
  protocolLabel: string;
  availability: ProxyAvailability;
  /** 不可用原因，已脱敏、用户可读。 */
  unavailableReason?: string;
  /** 组当前出口或节点描述（Dart Proxy.now）。 */
  now?: string;
  groupName: string;
}

/** 组类型（设计 §9.4：Selector 可手动选择，其余为自动组）。 */
export type ProxyGroupType = 'Selector' | 'URLTest' | 'Fallback' | 'LoadBalance' | 'Relay';

/** 组展示模型（Dart Group：type/all/now/hidden/testUrl/icon）。 */
export interface ProxyGroup {
  name: string;
  type: ProxyGroupType;
  /** 自动组只读；等价于 type 不是 Selector。 */
  isAuto: boolean;
  hidden: boolean;
  /** 组内成员（已按 getProxies 解析；嵌套组按 all 展开）。 */
  all: ProxyNode[];
  /** 组当前出口（解析到叶子，深度上限 16）。 */
  now?: string;
  testUrl?: string;
  icon?: string;
}

/** 延迟状态：idle 未测、loading 进行中、ok 成功、failed 失败。 */
export type DelayState = 'idle' | 'loading' | 'ok' | 'failed';

/** 单次测速结果；value 为毫秒，失败时无意义（上游 -1/0 的显式化替身）。 */
export interface DelayEntry {
  value: number;
  /** 测量时间（epoch ms），用于标记历史值。 */
  at: number;
  state: DelayState;
}

/** 测速地址 → 节点名 → 结果（Dart Map<url, Map<proxy, int?>>）。 */
export type DelayMap = Record<string, Record<string, DelayEntry>>;

// ---------------------------------------------------------------------------
// 运行快照与错误（设计 §3.3、§7.9）
// ---------------------------------------------------------------------------

/**
 * 运行事实快照（对应 getCoreState / ClashManager）。
 * 仅内存、可重建；不含路径、URL、token 或端口。
 */
export interface ProxyRuntimeSnapshot {
  state: ClashState;
  /** 内核版本；不可得时省略，UI 显示「未知」而不编造。 */
  coreVersion?: string;
  /** 内核实际加载的 profile。 */
  profileId?: string;
  /** 内核实际出口节点名。 */
  currentNode?: string;
  /** 连接建立时间（epoch ms）。 */
  connectedAt?: number;
  /** 最近错误分类码；由 S1-02 的 ProxyErrorCode 收窄。 */
  lastErrorCode?: string;
  /** protect 失败次数，仅诊断。 */
  protectFailures: number;
  /** 本次会话 epoch，事件与快照必须一致。 */
  epoch: number;
}

/** 结构化代理错误：只保存分类码与细分码，不保存原始响应体或堆栈。 */
export interface ProxyError {
  code: string;
  detailCode?: string;
}

// ---------------------------------------------------------------------------
// RPC 信封（设计 §5.2-§5.4）
// ---------------------------------------------------------------------------

/** 协议版本，必须与 req/ack 文件及 auth.proto 一致。 */
export const RPC_PROTO = 1;

/** 单帧与未成帧缓冲上限（1 MiB）；超限立即断开并计数。 */
export const RPC_MAX_FRAME_BYTES = 1048576;

/** 监听端最大并发连接数；超限拒绝新连接，不排队。 */
export const RPC_MAX_CONNECTIONS = 4;

/** profile id 允许字符与长度（设计 §8.2）。 */
export const PROFILE_ID_PATTERN = '^[A-Za-z0-9_-]{1,64}$';

/** 内核 home 在应用沙箱内的子目录名。 */
export const CLASH_HOME_SUBDIR = 'clash';

/** JSON 标量或对象载荷；ArkTS 不支持索引签名，嵌套结构统一用 object 承载。 */
export type JsonPayload = string | number | boolean | object | null;

/** 客户端请求：id 形如 u-<session8>-<seq> 或 e-<session8>-<seq>。 */
export interface RpcRequest {
  id: string;
  method: string;
  params?: object;
}

/** 结构化 RPC 错误；message 只用于诊断，不直接展示给用户。 */
export interface RpcErrorBody {
  code: string;
  message: string;
}

/**
 * 响应：result 与 error 互斥。
 * ArkTS 不支持可判别联合的索引访问，因此二者都声明为可选；调用方必须先判 error。
 */
export interface RpcResponse {
  id: string;
  result?: JsonPayload;
  error?: RpcErrorBody;
}

/** 推送通道：state 状态、event 内核事件、fault 异常。 */
export type RpcPushChannel = 'state' | 'event' | 'fault';

/** 推送帧：没有 id，只有通道与数据。 */
export interface RpcPush {
  push: RpcPushChannel;
  data: object;
}

// ---------------------------------------------------------------------------
// Action 信封（设计 §9.1；Dart Action/ActionResult）
// ---------------------------------------------------------------------------

/**
 * Action 请求：data 为 JSON 文本或普通字符串（如组名），无参数时省略。
 * id 由客户端生成，形如 <method>#<epoch>-<seq>。
 */
export interface ActionEnvelope {
  id: string;
  method: string;
  data?: string;
}

/**
 * Action 结果：必须检查 code（0 成功、-1 错误）；字符串类方法的成功判据是
 * data 为空串，二者都要检查。上游 Dart 忽略 code，不能照搬。
 */
export interface ActionResultEnvelope {
  id: string;
  method: string;
  data: JsonPayload;
  code: number;
}

// ---------------------------------------------------------------------------
// 配置载荷（core/constant.go、core/state/state.go）
// ---------------------------------------------------------------------------

/**
 * mihomo RawConfig 是开放 JSON 对象。ArkTS 不允许索引签名，因此用 object 作为
 * 开放载荷；已知顶层键见 RawConfigKnownKeys。规则键固定为 rule，不是 rules。
 */
export type RawConfig = object;

/** RawConfig 中本项目会读取/校验的少量顶层键。 */
export interface RawConfigKnownKeys {
  proxies?: object;
  'proxy-groups'?: object;
  rule?: string[];
  dns?: object;
  tun?: object;
}

/** setupConfig 的参数（core.constant.SetupParams）。 */
export interface SetupParams {
  config: RawConfig;
  /** 组名 → 节点名，由 profile.selectedMap 提供。 */
  'selected-map': Record<string, string>;
  'test-url': string;
}

/** 内核初始化参数（core.constant.InitParams）；version=29 关闭 per-app UID 解析。 */
export interface InitParams {
  'home-dir': string;
  version: number;
}

/** 分应用访问控制（上游字段；OHOS 侧暂不使用）。 */
export interface AccessControlOptions {
  enable: boolean;
  /** 上游只有 accept 走白名单，其余值一律走黑名单。 */
  mode: string;
  acceptList: string[];
  rejectList: string[];
}

/** 内核 VpnProps 子集，作为 CoreState 的 vpn-props。 */
export interface VpnPropsState {
  enable: boolean;
  systemProxy: boolean;
  ipv6: boolean;
  allowBypass: boolean;
  accessControl?: AccessControlOptions;
}

/**
 * quickStart 的第三个 JSON，也是 setState 的 data（core/state/state.go）。
 * Dart 额外的 only-statistics-proxy 被 Go 忽略，故不建模。
 */
export interface CoreState {
  'vpn-props': VpnPropsState;
  'current-profile-name': string;
  'bypass-domain': string[];
}

/**
 * getAndroidVpnOptions 返回的 TUN 参数（core/state.AndroidVpnOptions）。
 * OHOS 忽略 port 与 bypassDomain，accessControl 在本 MVP 也不使用；
 * 字段保留以完整镜像真实协议，避免把上游字段误当不存在。
 */
export interface VpnOptions {
  enable: boolean;
  /** 来自 mixed-port；OHOS 不用于系统代理。 */
  port: number;
  accessControl?: AccessControlOptions;
  allowBypass: boolean;
  /** Android 系统代理提示；OHOS 未使用。 */
  systemProxy: boolean;
  /** OHOS 未实现，仅透传。 */
  bypassDomain?: string[];
  routeAddress?: string[];
  ipv4Address: string;
  ipv6Address: string;
  dnsServerAddress: string;
  includePackage?: string[];
  excludePackage?: string[];
}