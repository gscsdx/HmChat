/**
 * libclash_bridge NAPI 契约（仅 VPN 扩展进程 import）。
 *
 * 依据 docs/integration/clash-proxy-design.md §6.2 与
 * docs/integration/clash-proxy-tasks.md T-S2-03。
 *
 * 约束：
 * - 入参一律为 JSON 字符串或显式标量，不暴露裸对象或动态类型；
 * - Promise 结果使用显式接口 `CoreInitResult`；
 * - 本文件只声明契约，cpp 实现属于 S3；UI 进程不链接本库。
 */

/** `initCoreAsync` 的初始化结果。 */
export interface CoreInitResult {
  /** 内核是否已成功初始化。 */
  initialized: boolean;
  /** 内核自报的初始化状态（`getIsInit` 语义）。 */
  isInit: boolean;
  /** 内核版本号；未知时为空串。 */
  version: string;
  /** 稳定错误码（如 `core_init_failed`）；不含路径、堆栈或配置内容。 */
  errorCode?: string;
}

/**
 * 异步初始化内核（`napi_async_work`，推荐路径）：
 * 注册回调、`setEventListener`、`initClashSync(29, homeDir)`。
 * 失败时 resolved 值 `initialized=false` 且带 `errorCode`，不抛异常。
 */
export const initCoreAsync: (homeDir: string) => Promise<CoreInitResult>;

/**
 * 异步启动内核（`napi_async_work` + 回调式 `quickStart`，禁用同步版本）。
 * 返回空串表示成功；非空为错误信息，由上层映射为 `config_invalid`。
 */
export const quickStartAsync: (init: string, params: string, state: string) => Promise<string>;

/**
 * fire-and-forget 下发 Action（JSON 字符串，含 `id`/`method`/`data`）。
 * 结果经事件通道回投，不通过返回值传递。
 */
export const invokeAction: (json: string) => void;

/**
 * 转交 TUN fd 所有权。返回 true 表示内核已接管该 fd；
 * 失败时不得重复 close（内核可能已关闭）。
 */
export const startTun: (fd: number) => boolean;

/** 仅停止 TUN，不销毁 VpnConnection。 */
export const stopTun: () => void;

/** 内核启动时间戳（epoch ms）；0 表示未启动。 */
export const getRunTime: () => number;

/** 内核建议的 TUN 参数 JSON 字符串。 */
export const getAndroidVpnOptions: () => string;

/** 当前生效配置名，仅用于展示；未启动时为空串。 */
export const getCurrentProfileName: () => string;

/** 上报当前 CoreState（JSON 字符串）。 */
export const setState: (json: string) => void;

/** 发送 `shutdown` Action；结果非 UI 关键，失败返回 false。 */
export const shutdownCore: () => boolean;

/** 通知 Go dialer 指定 fd 的 protect 握手已结束，解除其等待。 */
export const notifyProtected: (fd: number) => void;

/**
 * protect 握手统计 JSON：`{attempts,failures,timeouts,dropped,lastFd}`。
 * 仅用于诊断，不含域名、路径或配置内容。
 */
export const getProtectStats: () => string;

/**
 * 注册事件回调（创建 TSFN）。payload 为 UTF-8 JSON 字符串。
 * 只允许设置一次；重复设置先释放旧 TSFN。
 */
export const setEventSink: (cb: (payload: string) => void) => void;