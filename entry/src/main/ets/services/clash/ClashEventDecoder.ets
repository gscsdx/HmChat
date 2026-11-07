/**
 * Clash 内核事件解码与最小化（T-S2-09）。
 *
 * 证据来源：
 * - docs/integration/clash-proxy-design.md §5.7（推送与事件最小化）、§3.2（事件链路）、
 *   §9.5（流量/日志）、§9.6（事件失败语义）。
 * - docs/integration/clash-proxy-tasks.md T-S2-09。
 * - 上游固定版本 source-refs/FlClashX/core/constant.go（`Message{type,data}`、
 *   `Delay{url,name,value}`）与 core/hub.go（delay/log 推送点）。
 *
 * 不变量：
 * 1. 只认识 `loaded` / `delay` / `traffic` / `log`；`request`、连接明细、原始 JSON 与
 *    未知 `type` 一律返回 null 并累加 `droppedEvents`，绝不交给 UI、绝不写日志。
 * 2. `delay` 的 url 先经 `ClashRedaction.redactUrl` 摘要化，再作为 `ClashDelayMap`
 *    的键和 `DecodedEvent.url` 输出；原始测速/订阅 URL 不在本模块内保留。
 * 3. `traffic` 在 1 s 窗口内合并（窗口内字节量求和），最多输出一次，避免高频事件
 *    打满 UI；首个采样立即输出，保证界面不会等满一秒才有数据。
 * 4. `log` 只按 `level`（error / warning）与分类码 `code` 输出；上游 `Payload`/
 *    日志原文从不读取，因此不可能通过本模块泄漏域名或请求路径。
 * 5. `state` / `fault` 推送由调用方单独处理，不进入本解码器。
 * 6. 解析失败、字段不合法或处理器内部异常都只累加计数并返回 null，不抛未捕获
 *    异常、不打印 payload，保证事件泵继续工作。
 *
 * 本文件不引用任何 HarmonyOS Kit，也不引用 TelegramService；保持纯逻辑，
 * 便于把后缀改为 `.ts` 后在宿主机上直接做类型与行为校验。
 */

import { DelayMap } from '../../model/ClashModels';
import { applyDelay, clearAll } from '../../model/ClashDelayMap';
import { redactUrl } from '../../model/ClashRedaction';

// ---------------------------------------------------------------------------
// 常量
// ---------------------------------------------------------------------------

/** traffic 输出窗口：同一窗口内的采样合并成一次 UI 更新。 */
const TRAFFIC_WINDOW_MS: number = 1000;

/**
 * 单条 payload 的长度上限（64 KiB）。事件字段都是短文本，超长载荷通常意味着
 * 上游把原始日志/JSON 塞了进来；直接按畸形事件丢弃，避免无谓的解析开销。
 */
const MAX_PAYLOAD_LENGTH: number = 65536;

/** 节点名上限；上游节点名很短，超长只可能是异常输入。 */
const MAX_NAME_LENGTH: number = 128;

/** 分类码上限，与 ClashRedaction 的 CODE_PATTERN 保持一致。 */
const MAX_CODE_LENGTH: number = 32;

/** 单次测速值上限（10 分钟）；超过后视为异常输入，不进入 DelayMap。 */
const MAX_DELAY_MS: number = 600000;

/** 计数饱和值，避免长期运行后整数精度失真。 */
const MAX_COUNT: number = Number.MAX_SAFE_INTEGER;

/** redactUrl 的畸形输入返回值；命中它说明 url 不可用，也不应写入 DelayMap。 */
const INVALID_URL: string = 'invalid-url';

/** 分类码形状：小写开头，只允许小写字母、数字与 `_.-`。 */
const CODE_PATTERN: RegExp = /^[a-z][a-z0-9_.-]{0,31}$/;

/** UUID / 长 hex token 不允许借分类码字段穿过白名单。 */
const HEX_TOKEN_PATTERN: RegExp =
  /^(?:[0-9a-f]{16,}|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$/;

/** 节点名中的控制字符会破坏展示与日志注入防护，直接拒绝。 */
const CONTROL_PATTERN: RegExp = /[\u0000-\u001F\u007F]/;

// ---------------------------------------------------------------------------
// 对外类型
// ---------------------------------------------------------------------------

/** 允许进入 UI 的事件类型；字符串字面量联合，ArkTS 不使用枚举。 */
export type DecodedEventType = 'loaded' | 'delay' | 'traffic' | 'log';

/** 允许进入 UI 的日志级别；info/debug/trace 不推送。 */
export type DecodedLogLevel = 'error' | 'warning';

/**
 * 解码后的事件。
 *
 * 用 `type` 区分字段归属，避免为 ArkTS 引入跨接口的可判别联合：
 * - `loaded`：无附加字段，仅表示内核配置已重载；
 * - `delay`：`name` / `url`（已摘要化）/ `value` / `at`；
 * - `traffic`：`up` / `down`（窗口内字节量）；
 * - `log`：`level` / `code`（分类码，不含日志原文）。
 */
export interface DecodedEvent {
  type: DecodedEventType;
  /** 仅 delay：节点名，UI 展示需要，不写入日志。 */
  name?: string;
  /** 仅 delay：经 redactUrl 摘要化的测速地址。 */
  url?: string;
  /** 仅 delay：-1 失败、0 进行中、大于 0 为毫秒。 */
  value?: number;
  /** 仅 delay：结果到达时刻（epoch ms），用于 ClashDelayMap 的乱序保护。 */
  at?: number;
  /** 仅 traffic：窗口内上行字节量。 */
  up?: number;
  /** 仅 traffic：窗口内下行字节量。 */
  down?: number;
  /** 仅 log：error / warning。 */
  level?: DecodedLogLevel;
  /** 仅 log：分类码，不含可读消息与域名。 */
  code?: string;
}

/**
 * 事件处理计数，供诊断入口只读展示。
 *
 * 计数语义：
 * - `received`：decode() 收到非空 payload 的次数；
 * - `loaded` / `delay` / `traffic` / `log`：实际输出给 UI 的事件数；
 * - `trafficSamples`：被折叠进 traffic 窗口的原始采样数（含已输出帧对应的采样）；
 * - `droppedEvents`：type 缺失或不在白名单的丢弃数（含 `request`）；
 * - `malformedEvents`：JSON 解析失败、结构非法或字段不合法的次数；
 * - `filteredLogs`：级别不在 error/warning 或分类码不合法的 log 过滤数。
 */
export interface EventStats {
  received: number;
  loaded: number;
  delay: number;
  traffic: number;
  trafficSamples: number;
  log: number;
  droppedEvents: number;
  malformedEvents: number;
  filteredLogs: number;
}

// ---------------------------------------------------------------------------
// 内部报文形状
// ---------------------------------------------------------------------------

/**
 * 上游事件的最小读取面。
 *
 * 只声明本模块会读取的字段；`payload` / 连接明细等一律不声明，从类型层面阻止
 * 误用。字段在运行时都可能缺失或类型不符，取值统一走下面的安全读取函数。
 */
interface RawEventFields {
  type?: string;
  method?: string;
  data?: object;
  name?: string;
  url?: string;
  value?: number;
  up?: number;
  down?: number;
  level?: string;
  code?: string;
}

// ---------------------------------------------------------------------------
// 安全读取与归一化
// ---------------------------------------------------------------------------

/** 计数加一，达到安全整数上限后饱和。 */
function nextCount(value: number): number {
  if (!Number.isFinite(value) || value < 0) {
    return 1;
  }
  if (value >= MAX_COUNT) {
    return MAX_COUNT;
  }
  return value + 1;
}

/** 字节量求和，达到安全整数上限后饱和。 */
function safeAdd(left: number, right: number): number {
  const sum: number = left + right;
  if (!Number.isFinite(sum) || sum >= MAX_COUNT) {
    return MAX_COUNT;
  }
  if (sum < 0) {
    return 0;
  }
  return sum;
}

/** 只接受字符串字段；其余类型按缺失处理。 */
function stringField(value: string | undefined): string {
  return typeof value === 'string' ? value : '';
}

/** 只接受有限整数；小数、NaN、Infinity 与字符串都按缺失处理。 */
function integerField(value: number | undefined): number | null {
  if (typeof value !== 'number' || !Number.isFinite(value) || Math.floor(value) !== value) {
    return null;
  }
  return value;
}

/** 只接受普通对象；数组、null 与标量都按缺失处理。 */
function objectField(value: object | undefined): RawEventFields | null {
  if (value === undefined || value === null || typeof value !== 'object' || Array.isArray(value)) {
    return null;
  }
  return value as RawEventFields;
}

/**
 * 取事件字段所在对象：优先 `data` 内的对象，其次事件自身。
 *
 * 上游固定版本是 `Message{type,data}`（delay/traffic/log 字段在 data 内）；
 * RPC 最小化推送可能把字段摊平到事件对象上，两种形态都接受。
 */
function nestedFields(event: RawEventFields): RawEventFields {
  const nested: RawEventFields | null = objectField(event.data);
  return nested === null ? event : nested;
}

/**
 * 剥掉一层传输信封。
 *
 * - `{type:"event"|"message", data:{type,...}}`：扩展侧/桥的传输包装；
 * - `{method:"message", data:{type,...}}`：上游 ActionResult 包装。
 *
 * 包装不是内核事件类型，剥掉后仍按内层 `type` 走白名单；缺失或畸形时返回 null，
 * 由调用方计入 droppedEvents。
 */
function unwrapEnvelope(fields: RawEventFields): RawEventFields | null {
  const type: string = stringField(fields.type).trim();
  if (type === 'event' || type === 'message') {
    return objectField(fields.data);
  }
  if (type.length === 0 && stringField(fields.method).trim() === 'message') {
    return objectField(fields.data);
  }
  return fields;
}

/** 日志级别归一化：只接受 error/warning；`warn` 视为 warning。 */
function normalizeLevel(value: string): DecodedLogLevel | null {
  const level: string = value.trim().toLowerCase();
  if (level === 'error') {
    return 'error';
  }
  if (level === 'warning' || level === 'warn') {
    return 'warning';
  }
  return null;
}

/**
 * 分类码归一化：必须满足 CODE_PATTERN，并拒绝 UUID / 长 hex token。
 * 非法值返回空串，调用方按过滤处理；原文不回显。
 */
function normalizeCode(value: string): string {
  const code: string = value.trim().toLowerCase();
  if (code.length === 0 || code.length > MAX_CODE_LENGTH) {
    return '';
  }
  if (!CODE_PATTERN.test(code)) {
    return '';
  }
  if (HEX_TOKEN_PATTERN.test(code)) {
    return '';
  }
  return code;
}

// ---------------------------------------------------------------------------
// 解码器
// ---------------------------------------------------------------------------

/**
 * 单个 UI 进程会话持有的内核事件解码器。
 *
 * 非线程安全：只在 UI 事件泵所在线程调用。`decode` 无副作用地返回事件或 null；
 * `snapshot` 返回计数副本；`reset` 在会话切换/账号隔离时清空全部状态。
 */
export class ClashEventDecoder {
  /** 摘要化后的延迟结果；由 ClashDelayMap 以不可变快照方式更新。 */
  private delays: DelayMap = {};

  private received: number = 0;
  private loaded: number = 0;
  private delay: number = 0;
  private traffic: number = 0;
  private trafficSamples: number = 0;
  private log: number = 0;
  private droppedEvents: number = 0;
  private malformedEvents: number = 0;
  private filteredLogs: number = 0;

  /** 当前 traffic 窗口内尚未输出的字节量。 */
  private pendingUp: number = 0;
  private pendingDown: number = 0;
  /** 上一次 traffic 输出的时刻；-1 表示本会话尚未输出。 */
  private lastTrafficEmitAt: number = -1;

  /**
   * 解码一条内核事件 JSON。
   *
   * @param payload 上游事件 JSON 文本（`{type,data}` 或已摊平的最小白名单字段）。
   * @returns 白名单事件；未知类型、畸形输入、被策略过滤的 log 均返回 null。
   *
   * 本方法保证不抛异常、不打印 payload。`state` / `fault` 推送不要调用本方法。
   */
  decode(payload: string): DecodedEvent | null {
    this.received = nextCount(this.received);
    if (typeof payload !== 'string' || payload.length === 0 || payload.length > MAX_PAYLOAD_LENGTH) {
      this.malformedEvents = nextCount(this.malformedEvents);
      return null;
    }
    let parsed: object | null = null;
    try {
      parsed = JSON.parse(payload) as object;
    } catch (_) {
      this.malformedEvents = nextCount(this.malformedEvents);
      return null;
    }
    if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
      this.malformedEvents = nextCount(this.malformedEvents);
      return null;
    }
    try {
      return this.dispatch(parsed as RawEventFields);
    } catch (_) {
      // 防御性兜底：任何非预期运行时形状都不得把异常抛回事件泵。
      this.malformedEvents = nextCount(this.malformedEvents);
      return null;
    }
  }

  /** 返回计数副本；调用方修改返回值不影响解码器。 */
  snapshot(): EventStats {
    const stats: EventStats = {
      received: this.received,
      loaded: this.loaded,
      delay: this.delay,
      traffic: this.traffic,
      trafficSamples: this.trafficSamples,
      log: this.log,
      droppedEvents: this.droppedEvents,
      malformedEvents: this.malformedEvents,
      filteredLogs: this.filteredLogs
    };
    return stats;
  }

  /**
   * 返回当前延迟结果的外层副本，供节点列表渲染。
   *
   * 内层 url bucket 与 DelayEntry 按引用共享（与 ClashDelayMap 的不可变约定一致），
   * 调用方只能读取，不能修改。
   */
  getDelayMap(): DelayMap {
    const copy: DelayMap = {};
    const urls: string[] = Object.keys(this.delays);
    for (let index: number = 0; index < urls.length; index++) {
      const url: string = urls[index];
      copy[url] = this.delays[url];
    }
    return copy;
  }

  /** 会话切换时清空全部计数、延迟结果与 traffic 窗口状态。 */
  reset(): void {
    this.delays = clearAll();
    this.received = 0;
    this.loaded = 0;
    this.delay = 0;
    this.traffic = 0;
    this.trafficSamples = 0;
    this.log = 0;
    this.droppedEvents = 0;
    this.malformedEvents = 0;
    this.filteredLogs = 0;
    this.pendingUp = 0;
    this.pendingDown = 0;
    this.lastTrafficEmitAt = -1;
  }

  /** 按白名单分发；未知或缺失 type 只计数丢弃。 */
  private dispatch(raw: RawEventFields): DecodedEvent | null {
    const event: RawEventFields | null = unwrapEnvelope(raw);
    if (event === null) {
      this.droppedEvents = nextCount(this.droppedEvents);
      return null;
    }
    const type: string = stringField(event.type).trim();
    if (type === 'loaded') {
      this.loaded = nextCount(this.loaded);
      const loaded: DecodedEvent = { type: 'loaded' };
      return loaded;
    }
    if (type === 'delay') {
      return this.decodeDelay(event);
    }
    if (type === 'traffic') {
      return this.decodeTraffic(event);
    }
    if (type === 'log') {
      return this.decodeLog(event);
    }
    // request、连接明细、未知拼写与空 type 都走这里。
    this.droppedEvents = nextCount(this.droppedEvents);
    return null;
  }

  /**
   * delay：`{name,url,value}` → 摘要化 url → ClashDelayMap + UI 事件。
   *
   * url 先摘要化再入 map，保证原始测速地址不会留在内存键里；摘要化失败的
   * url（invalid-url）无法与节点结果关联，按畸形事件丢弃。
   */
  private decodeDelay(event: RawEventFields): DecodedEvent | null {
    const data: RawEventFields = nestedFields(event);
    const name: string = stringField(data.name);
    const rawUrl: string = stringField(data.url);
    const value: number | null = integerField(data.value);
    if (name.trim().length === 0 || name.length > MAX_NAME_LENGTH || CONTROL_PATTERN.test(name)) {
      this.malformedEvents = nextCount(this.malformedEvents);
      return null;
    }
    if (rawUrl.length === 0 || value === null || value < -1 || value > MAX_DELAY_MS) {
      this.malformedEvents = nextCount(this.malformedEvents);
      return null;
    }
    const safeUrl: string = redactUrl(rawUrl);
    if (safeUrl === INVALID_URL) {
      this.malformedEvents = nextCount(this.malformedEvents);
      return null;
    }
    // 到达时刻用于乱序保护；同刻重放不会覆盖已保存结果。
    const at: number = Date.now();
    this.delays = applyDelay(this.delays, name, safeUrl, value, at);
    this.delay = nextCount(this.delay);
    const decoded: DecodedEvent = {
      type: 'delay',
      name: name,
      url: safeUrl,
      value: value,
      at: at
    };
    return decoded;
  }

  /**
   * traffic：`{up,down}` 1 Hz 聚合。
   *
   * 上游 `statistic.Now()` 返回自上次取样以来的字节增量，因此窗口内求和；
   * 首个采样立即输出，之后每满 1 s 输出一次，窗口内的其余采样返回 null。
   * 系统时钟回拨时按新窗口处理，避免长时间不输出。
   */
  private decodeTraffic(event: RawEventFields): DecodedEvent | null {
    const data: RawEventFields = nestedFields(event);
    const up: number | null = integerField(data.up);
    const down: number | null = integerField(data.down);
    if (up === null || down === null || up < 0 || down < 0 || up > MAX_COUNT || down > MAX_COUNT) {
      this.malformedEvents = nextCount(this.malformedEvents);
      return null;
    }
    this.trafficSamples = nextCount(this.trafficSamples);
    const now: number = Date.now();
    if (this.lastTrafficEmitAt < 0) {
      this.lastTrafficEmitAt = now;
      this.pendingUp = 0;
      this.pendingDown = 0;
      this.traffic = nextCount(this.traffic);
      const first: DecodedEvent = { type: 'traffic', up: up, down: down };
      return first;
    }
    const elapsed: number = now - this.lastTrafficEmitAt;
    if (elapsed >= 0 && elapsed < TRAFFIC_WINDOW_MS) {
      this.pendingUp = safeAdd(this.pendingUp, up);
      this.pendingDown = safeAdd(this.pendingDown, down);
      return null;
    }
    // 满 1 s（或时钟回拨）：把窗口内累计量与当前采样一起输出。
    const totalUp: number = safeAdd(this.pendingUp, up);
    const totalDown: number = safeAdd(this.pendingDown, down);
    this.pendingUp = 0;
    this.pendingDown = 0;
    this.lastTrafficEmitAt = now;
    this.traffic = nextCount(this.traffic);
    const aggregated: DecodedEvent = { type: 'traffic', up: totalUp, down: totalDown };
    return aggregated;
  }

  /**
   * log：`{level,code}` → 只输出 error/warning 的分类码。
   *
   * 上游日志原文（mihomo `log.Data.Payload`）不在读取面内，因此不可能被转发；
   * 级别或分类码不合格时只累加 filteredLogs。
   */
  private decodeLog(event: RawEventFields): DecodedEvent | null {
    const data: RawEventFields = nestedFields(event);
    const level: DecodedLogLevel | null = normalizeLevel(stringField(data.level));
    if (level === null) {
      this.filteredLogs = nextCount(this.filteredLogs);
      return null;
    }
    const code: string = normalizeCode(stringField(data.code));
    if (code.length === 0) {
      this.filteredLogs = nextCount(this.filteredLogs);
      return null;
    }
    this.log = nextCount(this.log);
    const decoded: DecodedEvent = { type: 'log', level: level, code: code };
    return decoded;
  }
}