/**
 * 代理错误码、用户文案与分类（T-S1-02）。
 *
 * 纯 TypeScript 模块：不引用任何 HarmonyOS Kit，也不引用工程内其他模块，
 * 可在宿主机 TypeScript / Node 下直接转译与单元测试。
 *
 * 证据来源：
 * - docs/integration/clash-proxy-design.md §8.2「错误枚举」为唯一权威码表；
 *   §7.9（用户文案与建议）、§11.5（状态与错误文案、禁止术语）。
 * - docs/integration/clash-proxy-tasks.md T-S1-02、T-S1-13。
 *
 * 约定：
 * - 错误码集合严格等于 §8.2/§7.9 的 18 项，UI、状态机、诊断共用同一份映射。
 * - 主文案与建议逐字采用设计 §7.9；§11.5 对同一情形有更新时以 §11.5 为准。
 * - 文案只描述用户可理解的现象与下一步，不出现 Action 名、SDK/ABI、文件路径、
 *   订阅 URL、节点名或任何凭据。
 * - `internal` 仅用于无法归类时的兜底，调用方应尽快把真实原因收敛到具体码，
 *   不得让 `internal` 长期停留在状态或诊断记录中。
 */

/** 错误分类：决定 UI 分组、图标语义与重试入口，不代表授权状态。 */
export type ErrorCategory =
  | 'config'
  | 'core'
  | 'tun'
  | 'rpc'
  | 'protect'
  | 'system'
  | 'auth'
  | 'profile';

/**
 * 代理错误码。
 * 与设计 §8.2「错误枚举」逐项一致；新增或改名必须同步设计文档与 T-S1-13 用例。
 */
export type ProxyErrorCode =
  | 'core_missing'
  | 'core_load_failed'
  | 'core_init_failed'
  | 'config_missing'
  | 'config_invalid'
  | 'tun_config_invalid'
  | 'tun_create_denied'
  | 'tun_create_failed'
  | 'tun_start_failed'
  | 'tun_route_failed'
  | 'rpc_unavailable'
  | 'rpc_auth_failed'
  | 'path_rejected'
  | 'protect_degraded'
  | 'extension_crashed'
  | 'timeout'
  | 'unsupported'
  | 'internal';

/** 用户可见的错误描述；同一码只对应一份文案。 */
export interface ErrorDescription {
  /** 主文案：一句话说明结果，不包含技术实现细节。 */
  title: string;
  /** 副文案：解释发生了什么，帮助用户判断影响。 */
  detail: string;
  /** 下一步建议：用户可执行的动作，不用内部接口名。 */
  nextAction: string;
  /** 是否允许用户直接重试；需要更换安装包或重新导入时为 false。 */
  retryable: boolean;
  /** 分类；内核缺失归 core，授权被拒归 auth，配置问题归 config。 */
  category: ErrorCategory;
}

/** 未分类兜底文案；只在输入无法匹配任何具体码时返回。 */
const INTERNAL_DESCRIPTION: ErrorDescription = {
  title: '操作失败',
  detail: '发生了未分类的错误，操作没有完成。',
  nextAction: '重试；反馈诊断',
  retryable: true,
  category: 'system',
};

/**
 * 返回错误码对应的用户文案。
 *
 * 入参使用 `string`：状态机与运行快照里的错误码以字符串承载，调用方可能尚未收窄；
 * 未匹配任何具体码时返回 `internal` 的兜底描述，不抛异常、不展示原始错误内容。
 */
export function describe(code: string): ErrorDescription {
  switch (code) {
    case 'core_missing':
      return {
        title: '此安装包不包含代理内核',
        detail: '当前安装缺少代理所需的组件，无法启动代理。',
        nextAction: '更换完整安装包',
        retryable: false,
        category: 'core',
      };
    case 'core_load_failed':
      return {
        title: '代理内核加载失败',
        detail: '代理组件未能正常加载，无法启动代理。',
        nextAction: '重启应用；仍失败则更换安装包',
        retryable: false,
        category: 'core',
      };
    case 'core_init_failed':
      return {
        title: '代理服务初始化失败',
        detail: '代理服务初始化没有完成，可能存储空间不足。',
        nextAction: '重试；检查存储空间',
        retryable: true,
        category: 'core',
      };
    case 'config_missing':
      return {
        title: '尚未导入配置',
        detail: '当前没有可用的代理配置，无法开启代理。',
        nextAction: '导入订阅或本地配置',
        retryable: false,
        category: 'config',
      };
    case 'config_invalid':
      return {
        title: '配置无法使用',
        detail: '配置未通过校验，可能内容不完整或格式有误。',
        nextAction: '重新导入或更新订阅',
        retryable: false,
        category: 'config',
      };
    case 'tun_config_invalid':
      return {
        title: '网络参数无效',
        detail: '代理所需的网络参数无效，未建立连接。',
        nextAction: '重试；反馈诊断',
        retryable: true,
        category: 'tun',
      };
    case 'tun_create_denied':
      return {
        title: '未获得 VPN 授权',
        detail: '系统未授予建立网络连接所需的权限，代理没有启动。',
        nextAction: '重新开启并允许系统授权',
        retryable: true,
        category: 'auth',
      };
    case 'tun_create_failed':
      return {
        title: '无法建立 VPN 连接',
        detail: '系统未能建立代理所需的网络连接。',
        nextAction: '重试；检查是否被其他 VPN 占用',
        retryable: true,
        category: 'tun',
      };
    case 'tun_start_failed':
      return {
        title: '代理启动失败',
        detail: '代理未能启动，已停止本次尝试。',
        nextAction: '重试或重启应用',
        retryable: true,
        category: 'tun',
      };
    case 'tun_route_failed':
      return {
        title: '网络路由配置失败',
        detail: '代理所需的网络路由未能生效。',
        nextAction: '重试；切换网络',
        retryable: true,
        category: 'tun',
      };
    case 'rpc_unavailable':
      return {
        title: '内部服务连接失败',
        detail: '应用内部通信未能在预期时间内建立，代理没有启动。',
        nextAction: '重试或重启应用',
        retryable: true,
        category: 'rpc',
      };
    case 'rpc_auth_failed':
      return {
        title: '内部服务校验失败',
        detail: '内部连接的身份校验未通过，已中止本次连接。',
        nextAction: '重启应用',
        retryable: false,
        category: 'rpc',
      };
    case 'path_rejected':
      return {
        title: '配置路径无效',
        detail: '配置的存放位置无效，无法读取配置。',
        nextAction: '重新导入配置',
        retryable: false,
        category: 'profile',
      };
    case 'protect_degraded':
      return {
        title: '网络保护异常，已停止代理',
        detail: '网络保护连续出现异常，为避免流量异常已停止代理。',
        nextAction: '重试；仍失败请反馈诊断',
        retryable: true,
        category: 'protect',
      };
    case 'extension_crashed':
      return {
        title: '代理服务异常退出',
        detail: '负责代理的后台服务意外结束，代理已停止。',
        nextAction: '手动重试',
        retryable: true,
        category: 'system',
      };
    case 'timeout':
      return {
        title: '启动超时',
        detail: '启动代理等待时间过长，本次启动已停止。',
        nextAction: '重试或检查网络',
        retryable: true,
        category: 'system',
      };
    case 'unsupported':
      return {
        title: '当前系统不支持该功能',
        detail: '当前系统缺少代理所需的能力，无法开启。',
        nextAction: '升级系统或使用其他设备',
        retryable: false,
        category: 'system',
      };
    case 'internal':
    default:
      return INTERNAL_DESCRIPTION;
  }
}

/**
 * 返回错误码的分类。
 * 复用 `describe`，保证分类与文案来自同一份映射；未知输入按 `system` 兜底。
 */
export function classify(code: string): ErrorCategory {
  return describe(code).category;
}

/** 便捷函数：错误码分类，语义与 `classify` 相同。 */
export function categoryOf(code: string): ErrorCategory {
  return describe(code).category;
}

/** 便捷函数：是否允许用户直接重试。 */
export function isRetryable(code: string): boolean {
  return describe(code).retryable;
}