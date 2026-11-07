/**
 * 代理运行通知（设计 §7.7、任务 T-S4-04）。
 *
 * 目标：扩展进程有可见通知，且文案不含任何凭据。
 *
 * 证据：
 * - docs/integration/clash-proxy-design.md §7.7（ID 1001、BASIC_TEXT、标题与正文约束）。
 * - docs/integration/clash-proxy-tasks.md T-S4-04（固定 ID、状态文案、幂等取消、失败只告警）。
 * - 本机 SDK 26 `@ohos.notificationManager.d.ts`：`publish(request)`、`cancel(id)` 均为 Promise；
 *   `notificationContent.NotificationBasicContent` 的 `title`/`text` 不可为空串。
 *
 * 约束：
 * - 标题恒为「HmChat 网络代理」，不接受调用方覆盖（固定文案是验收项）。
 * - 正文只允许状态词与用户可见节点名；节点名过 URL/域名/主机端口形状即丢弃，
 *   不截断、不做二次拼接，避免把凭据或服务器地址显示到通知栏。
 * - 发布/取消失败只累加计数并记录固定码，不影响代理主流程；`cancel()` 幂等。
 * - 本文件不读配置文件、不访问网络，也不打印节点名。
 */

import { notificationManager } from '@kit.NotificationKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const LOG_DOMAIN: number = 0x0000;
const LOG_TAG: string = 'HarlgramProxyNotify';

/** 固定通知 ID，停止后按同一 ID 取消，不残留「VPN 运行中」。 */
export const CLASH_NOTIFICATION_ID: number = 1001;

/** 固定标题（设计要求，调用方不可覆写）。 */
export const CLASH_NOTIFICATION_TITLE: string = 'HmChat 网络代理';

export const NOTIFICATION_TEXT_STARTING: string = '正在启动';
export const NOTIFICATION_TEXT_CONNECTED: string = '已连接';
export const NOTIFICATION_TEXT_STOPPED: string = '已停止';

/** 通知正文可能出现的三种状态；用字面量联合，避免枚举。 */
export type ClashNotificationStatus = 'starting' | 'connected' | 'stopped';

/** 用户可见节点名上限；超长直接丢弃，不截断（避免显示半截域名）。 */
const MAX_NODE_NAME_LENGTH: number = 48;

const URL_PATTERN: RegExp = /(?:https?|socks5|socks4|ss|ssr|vmess|vless|trojan|hysteria2?):\/\//i;
/** `host:port` 形状：通知正文不得出现端口。 */
const HOST_PORT_PATTERN: RegExp = /:[0-9]{2,5}/;
/** 域名形状：`example.com`、`sub.example.co` 等。 */
const DOMAIN_LIKE_PATTERN: RegExp = /[A-Za-z0-9-]+\.[A-Za-z]{2,}/;
const CONTROL_PATTERN: RegExp = /[\u0000-\u001F\u007F]/;

/** 计数上限，避免长时间运行后溢出。 */
const MAX_COUNTER: number = 1000000000;

/** 只读计数快照；不含通知正文、节点名或异常文本。 */
export interface ClashNotificationCounters {
  published: number;
  failed: number;
  cancelled: number;
  /** 最近一次失败的固定码：`publish_failed` / `cancel_failed` / 空串。 */
  lastCode: string;
}

function nextCount(value: number): number {
  return value >= MAX_COUNTER ? MAX_COUNTER : value + 1;
}

/**
 * 清洗用户可见节点名。
 *
 * 返回空串表示不可使用：调用方只能显示状态词。拒绝条件（任一命中）：
 * 空串、超长、含控制字符、含 URL scheme、含域名形状、含 `:端口` 形状。
 */
export function safeNodeName(raw: string): string {
  const text: string = raw.trim();
  if (text.length === 0 || text.length > MAX_NODE_NAME_LENGTH) {
    return '';
  }
  if (CONTROL_PATTERN.test(text) || URL_PATTERN.test(text) ||
    HOST_PORT_PATTERN.test(text) || DOMAIN_LIKE_PATTERN.test(text)) {
    return '';
  }
  return text;
}

/** 状态词；未知状态回落「已停止」，不抛异常。 */
export function notificationStatusText(status: ClashNotificationStatus): string {
  if (status === 'starting') {
    return NOTIFICATION_TEXT_STARTING;
  }
  if (status === 'connected') {
    return NOTIFICATION_TEXT_CONNECTED;
  }
  return NOTIFICATION_TEXT_STOPPED;
}

/**
 * 组合通知正文：`<状态>` 或 `<状态> · <节点名>`。
 * 节点名不合法时只返回状态词，绝不透传原始输入。
 */
export function notificationText(status: ClashNotificationStatus, nodeName: string = ''): string {
  const base: string = notificationStatusText(status);
  const name: string = safeNodeName(nodeName);
  if (name.length === 0) {
    return base;
  }
  return base + ' · ' + name;
}

/**
 * 扩展进程内唯一的通知发布器。
 *
 * 生命周期：`onCreate` 可发布「正在启动」，`tun.start` 成功后发布「已连接」，
 * `tun.stop` / `onDestroy` 调用 `cancel()`。所有方法都不抛异常。
 */
export class ClashNotification {
  private counters: ClashNotificationCounters = {
    published: 0,
    failed: 0,
    cancelled: 0,
    lastCode: ''
  };

  /**
   * 发布或覆盖 ID 1001 的基础文本通知。
   *
   * 返回 true 表示系统接受了发布；false 表示失败（已计数）。权限被关闭、
   * 系统通知服务不可用等异常都在这里被吞掉，不向调用方抛出。
   */
  async show(status: ClashNotificationStatus, nodeName: string = ''): Promise<boolean> {
    const request: notificationManager.NotificationRequest = {
      id: CLASH_NOTIFICATION_ID,
      content: {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
        normal: {
          title: CLASH_NOTIFICATION_TITLE,
          text: notificationText(status, nodeName),
          additionalText: ''
        }
      }
    };
    try {
      await notificationManager.publish(request);
      this.counters.published = nextCount(this.counters.published);
      return true;
    } catch (error) {
      this.counters.failed = nextCount(this.counters.failed);
      this.counters.lastCode = 'publish_failed';
      const failure: BusinessError = error as BusinessError;
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'notification publish failed code=%{public}d', failure.code);
      return false;
    }
  }

  /**
   * 按固定 ID 取消通知。幂等：尚无通知、ID 不存在或系统异常都视为已完成，
   * 只记录计数与固定码。
   */
  async cancel(): Promise<void> {
    try {
      await notificationManager.cancel(CLASH_NOTIFICATION_ID);
      this.counters.cancelled = nextCount(this.counters.cancelled);
    } catch (error) {
      // 取消不到「不存在的通知」是正常状态，不是失败。
      const failure: BusinessError = error as BusinessError;
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'notification cancel skipped code=%{public}d', failure.code);
    }
  }

  /** 计数副本；调用方修改不影响内部状态。 */
  snapshot(): ClashNotificationCounters {
    const copy: ClashNotificationCounters = {
      published: this.counters.published,
      failed: this.counters.failed,
      cancelled: this.counters.cancelled,
      lastCode: this.counters.lastCode
    };
    return copy;
  }
}