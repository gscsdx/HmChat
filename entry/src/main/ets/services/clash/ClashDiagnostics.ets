/**
 * Clash 代理诊断：状态迁移环形缓冲、protect / 鉴权计数与脱敏导出（T-S2-11）。
 *
 * 证据来源：
 * - docs/integration/clash-proxy-design.md §5.4（diagnostics.snapshot 字段）、
 *   §5.7（推送字段白名单）、§5.8（诊断快照只含计数、状态、错误码、版本）、
 *   §8.3（诊断导出为去敏 JSON）；§6.6（getProtectStats 字段）。
 * - docs/integration/clash-proxy-tasks.md T-S2-11。
 *
 * 不变量：
 * 1. 环形缓冲最多 DIAGNOSTICS_MAX_RECORDS 条，只存在于内存；本模块不写文件、
 *    不打印日志、不缓存配置文本。
 * 2. 条目固定为 {at, from, to, event, errorCode, epoch}，不含路径、URL、IP、
 *    节点名或 token。
 * 3. snapshot() 与 export() 都重新做白名单校验：白名单之外的状态 / 事件值按
 *    ClashRedaction.hashName 收敛为 n-<8hex>，原始文本永不输出；errorCode 经
 *    ClashRedaction.safeError 收敛，非法值丢弃为空串。
 * 4. 时间与 epoch 全部由调用方注入，本模块不读时钟、不推测时间。
 */

import { ClashState, StateEvent } from '../../model/ClashModels';
import { ProxyErrorLike, hashName, safeError } from '../../model/ClashRedaction';

// ---------------------------------------------------------------------------
// 常量
// ---------------------------------------------------------------------------

/** 环形缓冲上限：T-S2-11 要求的 256 条。 */
export const DIAGNOSTICS_MAX_RECORDS: number = 256;

/** 导出结构版本；新增字段时递增，消费方据此判断兼容性。 */
export const DIAGNOSTICS_SCHEMA: number = 1;

/** 单个字符串字段参与哈希前的截断上限，限制异常输入带来的开销。 */
const MAX_FIELD_LENGTH: number = 512;

/** 计数上限：超过后饱和，避免长期运行后整数精度失真。 */
const MAX_COUNT: number = Number.MAX_SAFE_INTEGER;

/** ClashRedaction.safeError 的兜底码；出现时说明输入不是合法分类码。 */
const UNKNOWN_CODE: string = 'unknown';

/** 与 ClashModels.ClashState 一一对应，用于导出时的运行时白名单校验。 */
const CLASH_STATES: string[] = [
  'unconfigured',
  'unauthorized',
  'preparing',
  'connected',
  'stopped',
  'failed',
];

/** 与 ClashModels.StateEvent 一一对应，用于导出时的运行时白名单校验。 */
const STATE_EVENTS: string[] = [
  'importSucceeded',
  'enableRequested',
  'profileRemoved',
  'evidenceReady',
  'authDenied',
  'evidenceFailed',
  'prepareTimeout',
  'cancelled',
  'stopRequested',
  'linkLost',
  'reconnectExhausted',
  'retryRequested',
  'appRestarted',
];

/** hashName 的输出形状（含空输入的 n-empty）；已是摘要的值不再二次哈希。 */
const NAME_HASH_PATTERN: RegExp = /^n-(?:[0-9a-f]{8}|empty)$/;

/** 序列化失败时的最小安全输出：只表明导出未完成，不含任何运行数据。 */
const FALLBACK_EXPORT: string = '{"schema":1,"exported":false}';

// ---------------------------------------------------------------------------
// 类型
// ---------------------------------------------------------------------------

/** 可独立增量的诊断计数器名称；protect 计数由 setProtectStats 整体同步。 */
export type DiagnosticsCounterName =
  | 'authTimeout'
  | 'staleToken'
  | 'frameTooLarge'
  | 'rateLimited'
  | 'illegalTransitions'
  | 'droppedEvents';

/** 内核 protect() 的累计统计（getProtectStats 的子集；fd 不进入诊断）。 */
export interface ProtectStats {
  attempts: number;
  failures: number;
  timeouts: number;
  dropped: number;
}

/** 运行时计数器：鉴权、帧、限流、状态机与事件解码的累计次数。 */
export interface DiagnosticsCounters {
  authTimeout: number;
  staleToken: number;
  frameTooLarge: number;
  rateLimited: number;
  illegalTransitions: number;
  droppedEvents: number;
}

/** recordTransition 的入参；时间由调用方注入。 */
export interface DiagnosticsTransitionInput {
  /** 迁移发生时间（epoch ms）；非法值按 0（未知）记录。 */
  at: number;
  from: ClashState;
  to: ClashState;
  event: StateEvent;
  /** 本次会话 epoch；与 ClashModels 的 epoch 语义一致。 */
  epoch: number;
  /** 失败分类码；未脱敏的任意文本不会被原样保留。 */
  errorCode?: string;
}

/** 环形缓冲条目：固定六字段，全部为脱敏后的值。 */
export interface DiagnosticsTransitionRecord {
  at: number;
  from: string;
  to: string;
  event: string;
  errorCode: string;
  epoch: number;
}

/** 环形缓冲元信息：容量、当前条数与累计被覆盖的条数。 */
export interface DiagnosticsRingMeta {
  capacity: number;
  recorded: number;
  dropped: number;
}

/** 脱敏快照；export() 为其 JSON 序列化结果。 */
export interface DiagnosticsSnapshot {
  schema: number;
  protect: ProtectStats;
  counters: DiagnosticsCounters;
  /** 最近一条迁移的 epoch；无记录时为 0。 */
  epoch: number;
  /** 最近一个非空错误码；无记录时为空串。 */
  lastErrorCode: string;
  ring: DiagnosticsRingMeta;
  /** 按时间正序（旧 → 新）排列，最多 256 条。 */
  transitions: DiagnosticsTransitionRecord[];
}

// ---------------------------------------------------------------------------
// 脱敏与数值收敛
// ---------------------------------------------------------------------------

function boundedText(value: string): string {
  if (value.length <= MAX_FIELD_LENGTH) {
    return value;
  }
  return value.slice(0, MAX_FIELD_LENGTH);
}

function isNameHash(value: string): boolean {
  return NAME_HASH_PATTERN.test(value);
}

/**
 * 白名单内的状态 / 事件值原样保留；其余值一律视为不可信文本并哈希。
 *
 * 这样即使调用方误把节点名、订阅 URL、文件路径或 IP 传给本模块，缓冲区与
 * 导出中也只会出现稳定摘要，原始文本不会被保存或输出。
 */
function sanitizeEnum(value: string, allowed: string[]): string {
  if (typeof value !== 'string' || value.length === 0) {
    return hashName('');
  }
  if (allowed.indexOf(value) >= 0 || isNameHash(value)) {
    return value;
  }
  return hashName(boundedText(value));
}

/** 错误码只接受 ClashRedaction 认可的短分类码；URL、路径与凭据形状一律丢弃。 */
function normalizeErrorCode(value: string | undefined): string {
  if (value === undefined || value.length === 0) {
    return '';
  }
  const safe: ProxyErrorLike = safeError(value);
  if (safe.code === UNKNOWN_CODE) {
    return '';
  }
  return safe.code;
}

/** 非负整数收敛：计数、epoch 与时间戳共用；非法或负数按 0，超大值饱和。 */
function sanitizeCount(value: number): number {
  if (!Number.isFinite(value)) {
    return 0;
  }
  const numeric: number = Math.floor(value);
  if (numeric <= 0) {
    return 0;
  }
  return numeric > MAX_COUNT ? MAX_COUNT : numeric;
}

/** 饱和加一，避免计数器溢出为 Infinity 或丢失精度。 */
function nextCount(current: number): number {
  if (current >= MAX_COUNT) {
    return MAX_COUNT;
  }
  return current + 1;
}

function sanitizeRecord(source: DiagnosticsTransitionRecord): DiagnosticsTransitionRecord {
  const record: DiagnosticsTransitionRecord = {
    at: sanitizeCount(source.at),
    from: sanitizeEnum(source.from, CLASH_STATES),
    to: sanitizeEnum(source.to, CLASH_STATES),
    event: sanitizeEnum(source.event, STATE_EVENTS),
    errorCode: normalizeErrorCode(source.errorCode),
    epoch: sanitizeCount(source.epoch),
  };
  return record;
}

function copyProtect(source: ProtectStats): ProtectStats {
  const copy: ProtectStats = {
    attempts: sanitizeCount(source.attempts),
    failures: sanitizeCount(source.failures),
    timeouts: sanitizeCount(source.timeouts),
    dropped: sanitizeCount(source.dropped),
  };
  return copy;
}

function copyCounters(source: DiagnosticsCounters): DiagnosticsCounters {
  const copy: DiagnosticsCounters = {
    authTimeout: sanitizeCount(source.authTimeout),
    staleToken: sanitizeCount(source.staleToken),
    frameTooLarge: sanitizeCount(source.frameTooLarge),
    rateLimited: sanitizeCount(source.rateLimited),
    illegalTransitions: sanitizeCount(source.illegalTransitions),
    droppedEvents: sanitizeCount(source.droppedEvents),
  };
  return copy;
}

function emptyRecord(): DiagnosticsTransitionRecord {
  const record: DiagnosticsTransitionRecord = {
    at: 0,
    from: 'unconfigured',
    to: 'unconfigured',
    event: 'appRestarted',
    errorCode: '',
    epoch: 0,
  };
  return record;
}

/** 预分配固定槽位，写入时覆盖最旧一条，避免运行时扩容与数组搬移。 */
function createRing(): DiagnosticsTransitionRecord[] {
  const ring: DiagnosticsTransitionRecord[] = [];
  for (let index: number = 0; index < DIAGNOSTICS_MAX_RECORDS; index++) {
    ring.push(emptyRecord());
  }
  return ring;
}

// ---------------------------------------------------------------------------
// ClashDiagnostics
// ---------------------------------------------------------------------------

/**
 * 进程内诊断收集器。
 *
 * 只做内存记录与导出：不写盘、不订阅 RPC、不调用 Native，也不引用 Telegram
 * 或媒体模块，因此可以在状态机、RPC 服务与 UI 之间共享而不引入循环依赖。
 * 需要跨会话重置时直接丢弃实例（或由后续会话接入方新建），本类不做持久化。
 */
export class ClashDiagnostics {
  private static instance: ClashDiagnostics | null = null;

  /** 共享实例；仅用于进程内诊断汇聚。 */
  static get(): ClashDiagnostics {
    if (ClashDiagnostics.instance === null) {
      ClashDiagnostics.instance = new ClashDiagnostics();
    }
    return ClashDiagnostics.instance;
  }

  private readonly records: DiagnosticsTransitionRecord[] = createRing();
  /** 下一条写入位置；写满后始终指向最旧一条。 */
  private head: number = 0;
  private recorded: number = 0;
  private dropped: number = 0;
  private protectStats: ProtectStats = {
    attempts: 0,
    failures: 0,
    timeouts: 0,
    dropped: 0,
  };
  private counters: DiagnosticsCounters = {
    authTimeout: 0,
    staleToken: 0,
    frameTooLarge: 0,
    rateLimited: 0,
    illegalTransitions: 0,
    droppedEvents: 0,
  };
  private lastEpoch: number = 0;
  private lastErrorCode: string = '';

  /**
   * 记录一次状态迁移。
   *
   * 写入前立即脱敏：`from` / `to` / `event` 只保留白名单值或哈希摘要，
   * `errorCode` 只保留分类码。缓冲满时覆盖最旧一条并累加 ring.dropped。
   * 非法的 `at` / `epoch` 记为 0（未知），绝不补造时间。
   */
  recordTransition(input: DiagnosticsTransitionInput): void {
    const record: DiagnosticsTransitionRecord = {
      at: sanitizeCount(input.at),
      from: sanitizeEnum(input.from, CLASH_STATES),
      to: sanitizeEnum(input.to, CLASH_STATES),
      event: sanitizeEnum(input.event, STATE_EVENTS),
      errorCode: normalizeErrorCode(input.errorCode),
      epoch: sanitizeCount(input.epoch),
    };
    if (this.recorded >= DIAGNOSTICS_MAX_RECORDS) {
      this.dropped = nextCount(this.dropped);
    } else {
      this.recorded++;
    }
    this.records[this.head] = record;
    this.head = (this.head + 1) % DIAGNOSTICS_MAX_RECORDS;
    this.lastEpoch = record.epoch;
    if (record.errorCode.length > 0) {
      this.lastErrorCode = record.errorCode;
    }
  }

  /** 单次累加一个顶层计数器；未知名称不改变任何计数。 */
  increment(name: DiagnosticsCounterName): void {
    switch (name) {
      case 'authTimeout':
        this.counters.authTimeout = nextCount(this.counters.authTimeout);
        break;
      case 'staleToken':
        this.counters.staleToken = nextCount(this.counters.staleToken);
        break;
      case 'frameTooLarge':
        this.counters.frameTooLarge = nextCount(this.counters.frameTooLarge);
        break;
      case 'rateLimited':
        this.counters.rateLimited = nextCount(this.counters.rateLimited);
        break;
      case 'illegalTransitions':
        this.counters.illegalTransitions = nextCount(this.counters.illegalTransitions);
        break;
      case 'droppedEvents':
        this.counters.droppedEvents = nextCount(this.counters.droppedEvents);
        break;
      default:
        break;
    }
  }

  /**
   * 用内核 getProtectStats 的结果整体覆盖 protect 计数。
   *
   * 内核重启会让计数回退，这是真实状态，不做单调修正；调用方需要跨重启
   * 累计时自行在更上层累加。
   */
  setProtectStats(stats: ProtectStats): void {
    this.protectStats = copyProtect(stats);
  }

  /**
   * 生成脱敏快照（深拷贝）。
   *
   * 返回的数组与对象都是新建的，调用方修改不会影响内部环形缓冲。所有字符串
   * 再次经过白名单 / 哈希 / 分类码收敛，返回值可直接用于 RPC 推送或界面展示。
   */
  snapshot(): DiagnosticsSnapshot {
    const transitions: DiagnosticsTransitionRecord[] = [];
    const start: number = (this.head - this.recorded + DIAGNOSTICS_MAX_RECORDS) % DIAGNOSTICS_MAX_RECORDS;
    for (let offset: number = 0; offset < this.recorded; offset++) {
      const index: number = (start + offset) % DIAGNOSTICS_MAX_RECORDS;
      transitions.push(sanitizeRecord(this.records[index]));
    }
    const ring: DiagnosticsRingMeta = {
      capacity: DIAGNOSTICS_MAX_RECORDS,
      recorded: this.recorded,
      dropped: sanitizeCount(this.dropped),
    };
    const result: DiagnosticsSnapshot = {
      schema: DIAGNOSTICS_SCHEMA,
      protect: copyProtect(this.protectStats),
      counters: copyCounters(this.counters),
      epoch: sanitizeCount(this.lastEpoch),
      lastErrorCode: normalizeErrorCode(this.lastErrorCode),
      ring: ring,
      transitions: transitions,
    };
    return result;
  }

  /**
   * 导出脱敏 JSON 文本。
   *
   * 输出中不会出现 `http(s)://`、IPv4 / IPv6 字面量、`/data/` 等沙箱路径、
   * home 目录或 token：这些内容若被误写入 `from` / `to` / `event`，已在快照
   * 阶段替换为 `n-<8hex>`；`errorCode` 位置只可能是短分类码或空串。
   * 序列化失败时返回最小安全文本，诊断导出不得影响代理主流程。
   */
  export(): string {
    try {
      const serialized: string | undefined = JSON.stringify(this.snapshot());
      if (serialized === undefined || serialized.length === 0) {
        return FALLBACK_EXPORT;
      }
      return serialized;
    } catch (error) {
      return FALLBACK_EXPORT;
    }
  }
}