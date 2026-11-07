/**
 * Clash 运行状态机：六态唯一真值、三重证据、epoch 丢弃与重连预算（T-S1-03）。
 *
 * 纯 TypeScript 模块：不引用任何 HarmonyOS Kit，不读时钟、不读文件、不发请求，
 * 时间与计数全部由调用方注入，可在宿主机 TypeScript / Node 下直接转译与单元测试。
 *
 * 证据来源：
 * - docs/integration/clash-proxy-design.md §3.3（六态、三重证据、迁移表与实现约束）、
 *   §5.5（断线、重连退避 1/2/4/8/16 s 与预算耗尽）、§7.9（错误码文案）。
 * - docs/integration/clash-proxy-tasks.md T-S1-03、T-S1-13。
 * - entry/src/main/ets/model/ClashModels.ts 的 StateTransitionInput / StateTransitionOutput
 *   与 entry/src/main/ets/model/ClashError.ts 的 ProxyErrorCode 为共享契约。
 *
 * 不变量：
 * 1. 只有三重证据 `coreReady && tunReady && routeReady` 全真，且事件 epoch 与当前 epoch
 *    相同，才允许 `preparing → connected`；任一单点成功（`init ok`、`port ok`、RPC 可达）
 *    都不迁移。没有证据的路径一律返回 `rejected{code:'illegal_transition'}`。
 * 2. 旧 epoch 事件丢弃并计数，不改变状态与当前 epoch；`appRestarted` 是本地重建事件，
 *    不携带扩展会话 epoch，因此不受该守卫限制。
 * 3. 非法迁移只拒绝并计数，不写状态；任何 UI 都不得绕过本模块直接改状态。
 * 4. `preparing` 超过 60 s 未完成迁移为 `failed(timeout)`；`connected` 收到 `linkLost`
 *    先回 `preparing(reason='reconnect')`，按 1/2/4/8/16 s 退避，5 次耗尽后
 *    `failed(extension_crashed)`，只保留手动重试。
 *
 * epoch 约定：进入 `preparing`（开始、重试、重连）以及进入 `stopped`、`failed`、
 * `unauthorized`、`unconfigured` 都使用 `input.epoch + 1`，使旧会话的迟到事件自然
 * 变成 `stale_epoch`；`preparing → connected` 只有证据完整时才保持同一 epoch。
 */

import {
  ClashState,
  PreparingReason,
  StateEvidence,
  StateRejection,
  StateTransitionInput,
  StateTransitionOutput,
  StateTransitionRecord,
} from './ClashModels';
import { ProxyErrorCode } from './ClashError';

// ---------------------------------------------------------------------------
// 常量（设计 §3.3、§5.5）
// ---------------------------------------------------------------------------

/** preparing 总预算：超时后必须失败，不允许无限等待。 */
export const PREPARING_TIMEOUT_MS: number = 60000;

/** 重连预算：最多 5 次自动重连，之后只允许手动重试。 */
export const RECONNECT_MAX_ATTEMPTS: number = 5;

/** 重连退避序列（毫秒）：1、2、4、8、16 s，上限 16 s。 */
export const RECONNECT_BACKOFF_MS: number[] = [1000, 2000, 4000, 8000, 16000];

/**
 * 拒绝码字面量联合。
 * 与 ClashModels.StateRejection.code 保持一致；本模块不修改共享模型，故在此复述。
 */
type RejectionCode = 'stale_epoch' | 'illegal_transition' | 'no_valid_profile';

// ---------------------------------------------------------------------------
// 输入 / 输出扩展
// ---------------------------------------------------------------------------

/**
 * 状态机输入：在共享 StateTransitionInput 之外补充时间与计数。
 *
 * 新增字段全部可选，因此共享契约的 `StateTransitionInput` 仍可直接传入；调用方按需
 * 传入 `nowMs` / `preparingStartedAtMs` 即可获得超时判定与截止时间。计数器采用
 * 「传入旧值、传出新值」的方式，保持本模块为纯函数，不在模块内保存可变全局状态。
 */
export interface StateMachineInput extends StateTransitionInput {
  /** 当前时间（epoch ms），由调用方注入；缺省时不做超时判定。 */
  nowMs?: number;
  /** 本次 preparing 开始时间（epoch ms），由调用方在进入 preparing 时记录并回传。 */
  preparingStartedAtMs?: number;
  /** 当前 preparing 的细分原因；重连预算需要据此区分首启与重连。 */
  stateReason?: PreparingReason;
  /** 上一次输出累计的非法迁移次数。 */
  illegalTransitions?: number;
  /** 上一次输出累计的旧 epoch 丢弃次数。 */
  staleEpochEvents?: number;
  /** 本次断线重连已尝试的次数；0 表示当前不在重连预算中。 */
  reconnectAttempts?: number;
}

/** 状态机输出：共享 StateTransitionOutput 加上诊断计数与重连提示。 */
export interface StateMachineOutput extends StateTransitionOutput {
  /** 累计非法迁移次数（本次拒绝时已自增）。 */
  illegalTransitions: number;
  /** 累计旧 epoch 丢弃次数。 */
  staleEpochEvents: number;
  /** 输出状态对应的重连尝试次数；进入 connected 或手动重试后归零。 */
  reconnectAttempts: number;
  /** 若输出为 preparing(reconnect)，给出下一次重连应等待的毫秒数。 */
  nextRetryDelayMs?: number;
  /** 进入 preparing 时给出的截止时间（epoch ms）；仅在注入 nowMs 时提供。 */
  preparingDeadlineMs?: number;
}

// ---------------------------------------------------------------------------
// 内部结构
// ---------------------------------------------------------------------------

/** 一次成功迁移的计划；由各分支填充，统一生成记录与输出。 */
interface TransitionPlan {
  state: ClashState;
  epoch: number;
  reason?: PreparingReason;
  errorCode?: string;
  reconnectAttempts: number;
  nextRetryDelayMs?: number;
  preparingDeadlineMs?: number;
}

/** 需要跨事件累计的诊断计数。 */
interface MachineCounters {
  illegalTransitions: number;
  staleEpochEvents: number;
}

// ---------------------------------------------------------------------------
// 纯辅助函数
// ---------------------------------------------------------------------------

/** 计数输入容错：非数字、负数、非有限值一律按 0 处理，避免 NaN 污染诊断。 */
function normalizeCount(value: number | undefined): number {
  if (value === undefined) {
    return 0;
  }
  if (!Number.isFinite(value) || value < 0) {
    return 0;
  }
  return Math.floor(value);
}

/** 三重证据是否齐备；缺一不可。 */
export function isEvidenceComplete(evidence: StateEvidence): boolean {
  return evidence.coreReady && evidence.tunReady && evidence.routeReady;
}

/**
 * 证据失败时的默认错误码（设计 §3.3 E1/E2/E3 的对应关系）。
 * 调用方传入 `facts.errorCode` 时以调用方为准；全真却仍收到失败事件时兜底 `internal`。
 */
export function defaultFailureCode(evidence: StateEvidence): ProxyErrorCode {
  if (!evidence.coreReady) {
    return 'core_init_failed';
  }
  if (!evidence.tunReady) {
    return 'tun_start_failed';
  }
  if (!evidence.routeReady) {
    return 'tun_route_failed';
  }
  return 'internal';
}

/**
 * 判断当前 preparing 是否已超时。
 * 只有在状态为 preparing 且注入的两个时间点都合法时才计算，不读系统时钟。
 */
export function isPreparingExpired(input: StateMachineInput): boolean {
  if (input.state !== 'preparing') {
    return false;
  }
  const nowMs = input.nowMs;
  const startedAt = input.preparingStartedAtMs;
  if (nowMs === undefined || startedAt === undefined) {
    return false;
  }
  if (!Number.isFinite(nowMs) || !Number.isFinite(startedAt)) {
    return false;
  }
  return nowMs - startedAt >= PREPARING_TIMEOUT_MS;
}

/** 按尝试序号取退避毫秒数；序号从 1 开始，越界时夹到首尾，避免返回 undefined。 */
export function reconnectDelayMs(attempt: number): number {
  if (!Number.isFinite(attempt) || attempt <= 1) {
    return RECONNECT_BACKOFF_MS[0];
  }
  if (attempt >= RECONNECT_BACKOFF_MS.length) {
    return RECONNECT_BACKOFF_MS[RECONNECT_BACKOFF_MS.length - 1];
  }
  return RECONNECT_BACKOFF_MS[Math.floor(attempt) - 1];
}

/** 首启/配置应用/范围切换只接受这三个原因；`reconnect` 只能由 linkLost 产生。 */
function startReason(reason: PreparingReason | undefined): PreparingReason {
  if (reason === 'apply' || reason === 'scope') {
    return reason;
  }
  return 'start';
}

/** 进入 preparing 时的截止时间；未注入 nowMs 时不提供，避免伪造时间。 */
function deadlineFrom(input: StateMachineInput): number | undefined {
  if (input.nowMs === undefined || !Number.isFinite(input.nowMs)) {
    return undefined;
  }
  return input.nowMs + PREPARING_TIMEOUT_MS;
}

/** 生成成功迁移的记录与输出。 */
function applyPlan(
  input: StateMachineInput,
  counters: MachineCounters,
  plan: TransitionPlan,
): StateMachineOutput {
  const record: StateTransitionRecord = {
    from: input.state,
    to: plan.state,
    event: input.event,
    epoch: plan.epoch,
  };
  if (plan.reason !== undefined) {
    record.reason = plan.reason;
  }
  if (plan.errorCode !== undefined) {
    record.errorCode = plan.errorCode;
  }
  const output: StateMachineOutput = {
    state: plan.state,
    epoch: plan.epoch,
    changed: plan.state !== input.state || plan.epoch !== input.epoch,
    record: record,
    illegalTransitions: counters.illegalTransitions,
    staleEpochEvents: counters.staleEpochEvents,
    reconnectAttempts: plan.reconnectAttempts,
  };
  if (plan.nextRetryDelayMs !== undefined) {
    output.nextRetryDelayMs = plan.nextRetryDelayMs;
  }
  if (plan.preparingDeadlineMs !== undefined) {
    output.preparingDeadlineMs = plan.preparingDeadlineMs;
  }
  return output;
}

/** 生成拒绝输出：状态、epoch 不变，记录中 from 与 to 相同。 */
function rejectTransition(
  input: StateMachineInput,
  counters: MachineCounters,
  code: RejectionCode,
  detail: string,
): StateMachineOutput {
  if (code === 'illegal_transition') {
    counters.illegalTransitions += 1;
  }
  const rejection: StateRejection = { code: code };
  if (detail.length > 0) {
    rejection.detail = detail;
  }
  const record: StateTransitionRecord = {
    from: input.state,
    to: input.state,
    event: input.event,
    epoch: input.epoch,
  };
  return {
    state: input.state,
    epoch: input.epoch,
    changed: false,
    rejected: rejection,
    record: record,
    illegalTransitions: counters.illegalTransitions,
    staleEpochEvents: counters.staleEpochEvents,
    reconnectAttempts: normalizeCount(input.reconnectAttempts),
  };
}

/** preparing 超时的统一出口。 */
function failByTimeout(
  input: StateMachineInput,
  counters: MachineCounters,
): StateMachineOutput {
  return applyPlan(input, counters, {
    state: 'failed',
    epoch: input.epoch + 1,
    errorCode: 'timeout',
    reconnectAttempts: 0,
  });
}

// ---------------------------------------------------------------------------
// 状态机
// ---------------------------------------------------------------------------

/**
 * 唯一状态迁移入口。
 *
 * 纯函数：同一输入必得同一输出；不修改 `input`、不保留模块级可变状态。
 * 调用方保存输出中的 epoch 与计数，并在下一次事件中原样注入。
 */
export function transition(input: StateMachineInput): StateMachineOutput {
  const counters: MachineCounters = {
    illegalTransitions: normalizeCount(input.illegalTransitions),
    staleEpochEvents: normalizeCount(input.staleEpochEvents),
  };
  const event = input.event;
  const facts = input.facts;
  const from = input.state;
  const attempts = normalizeCount(input.reconnectAttempts);

  // 非法 epoch：既不是有限数也不可能是当前会话，按非法迁移拒绝。
  if (!Number.isFinite(input.epoch) || input.epoch < 0) {
    return rejectTransition(input, counters, 'illegal_transition', 'invalid_epoch');
  }

  // 旧 epoch 事件丢弃。appRestarted 是本地重建，不依赖扩展会话 epoch。
  if (event !== 'appRestarted') {
    if (!Number.isFinite(facts.epoch) || facts.epoch !== input.epoch) {
      counters.staleEpochEvents += 1;
      return rejectTransition(input, counters, 'stale_epoch', 'event_epoch_mismatch');
    }
  }

  const expired = isPreparingExpired(input);

  switch (event) {
    case 'importSucceeded': {
      // 迁移表：unconfigured + 导入成功 → stopped（守卫：配置有效、节点数>0）。
      if (from !== 'unconfigured') {
        return rejectTransition(input, counters, 'illegal_transition', 'import_requires_unconfigured');
      }
      if (!facts.hasValidProfile) {
        return rejectTransition(input, counters, 'no_valid_profile', 'import_without_valid_profile');
      }
      return applyPlan(input, counters, {
        state: 'stopped',
        epoch: input.epoch + 1,
        reconnectAttempts: 0,
      });
    }

    case 'enableRequested': {
      // 迁移表：unconfigured + 请求开启 → 保持 unconfigured 并拒绝。
      if (from === 'unconfigured') {
        return rejectTransition(input, counters, 'no_valid_profile', 'enable_without_profile');
      }
      // 迁移表：stopped + 请求开启且配置有效 → preparing。
      if (from !== 'stopped') {
        return rejectTransition(input, counters, 'illegal_transition', 'enable_requires_stopped');
      }
      if (!facts.hasValidProfile) {
        return rejectTransition(input, counters, 'no_valid_profile', 'enable_without_valid_profile');
      }
      return applyPlan(input, counters, {
        state: 'preparing',
        epoch: input.epoch + 1,
        reason: startReason(facts.reason),
        reconnectAttempts: 0,
        preparingDeadlineMs: deadlineFrom(input),
      });
    }

    case 'profileRemoved': {
      // 生效配置被删除或外部失效：任何非 unconfigured 状态回到 unconfigured。
      if (from === 'unconfigured') {
        return rejectTransition(input, counters, 'illegal_transition', 'profile_already_absent');
      }
      return applyPlan(input, counters, {
        state: 'unconfigured',
        epoch: input.epoch + 1,
        reconnectAttempts: 0,
      });
    }

    case 'evidenceReady': {
      // 迁移表：preparing + E1+E2+E3 → connected（守卫：同一 epoch、三重证据全真）。
      if (from !== 'preparing') {
        return rejectTransition(input, counters, 'illegal_transition', 'evidence_requires_preparing');
      }
      if (expired) {
        return failByTimeout(input, counters);
      }
      if (!isEvidenceComplete(facts.evidence)) {
        return rejectTransition(input, counters, 'illegal_transition', 'evidence_incomplete');
      }
      // 此处 facts.epoch 已与 input.epoch 相等，即证据与本次 preparing 属于同一 epoch。
      return applyPlan(input, counters, {
        state: 'connected',
        epoch: input.epoch,
        reconnectAttempts: 0,
      });
    }

    case 'authDenied': {
      // 迁移表：preparing + 授权被拒 → unauthorized；connected + 系统撤销授权 → unauthorized。
      // 授权结论优先于超时判定；断连走 linkLost 的重连预算，不与本事件混用。
      if (from !== 'preparing' && from !== 'connected') {
        return rejectTransition(input, counters, 'illegal_transition', 'auth_denied_requires_active_session');
      }
      return applyPlan(input, counters, {
        state: 'unauthorized',
        epoch: input.epoch + 1,
        errorCode: facts.errorCode !== undefined ? facts.errorCode : 'tun_create_denied',
        reconnectAttempts: 0,
      });
    }

    case 'evidenceFailed': {
      // 迁移表：preparing + 任一证据失败 → failed（携带错误码）。
      if (from !== 'preparing') {
        return rejectTransition(input, counters, 'illegal_transition', 'evidence_failed_requires_preparing');
      }
      if (expired) {
        return failByTimeout(input, counters);
      }
      return applyPlan(input, counters, {
        state: 'failed',
        epoch: input.epoch + 1,
        errorCode: facts.errorCode !== undefined ? facts.errorCode : defaultFailureCode(facts.evidence),
        reconnectAttempts: 0,
      });
    }

    case 'prepareTimeout': {
      // 迁移表：preparing + 60 s 超时 → failed(timeout)。
      if (from !== 'preparing') {
        return rejectTransition(input, counters, 'illegal_transition', 'timeout_requires_preparing');
      }
      return failByTimeout(input, counters);
    }

    case 'cancelled': {
      // 迁移表：preparing + 用户取消 → stopped（资源释放完成后落状态）。
      if (from !== 'preparing') {
        return rejectTransition(input, counters, 'illegal_transition', 'cancel_requires_preparing');
      }
      return applyPlan(input, counters, {
        state: 'stopped',
        epoch: input.epoch + 1,
        reconnectAttempts: 0,
      });
    }

    case 'stopRequested': {
      // 迁移表：connected + 用户关闭 → stopped（停止收敛完成）。
      if (from !== 'connected') {
        return rejectTransition(input, counters, 'illegal_transition', 'stop_requires_connected');
      }
      return applyPlan(input, counters, {
        state: 'stopped',
        epoch: input.epoch + 1,
        reconnectAttempts: 0,
      });
    }

    case 'linkLost': {
      // 迁移表：connected + 断连/进程回收 → preparing(reason=reconnect)，先不 failed。
      if (from === 'connected') {
        return applyPlan(input, counters, {
          state: 'preparing',
          epoch: input.epoch + 1,
          reason: 'reconnect',
          reconnectAttempts: 1,
          nextRetryDelayMs: reconnectDelayMs(1),
          preparingDeadlineMs: deadlineFrom(input),
        });
      }
      // 重连过程中再次断线：累加尝试次数，预算耗尽才 failed(extension_crashed)。
      if (from === 'preparing' && input.stateReason === 'reconnect') {
        const nextAttempt = attempts + 1;
        if (nextAttempt > RECONNECT_MAX_ATTEMPTS) {
          return applyPlan(input, counters, {
            state: 'failed',
            epoch: input.epoch + 1,
            errorCode: 'extension_crashed',
            reconnectAttempts: RECONNECT_MAX_ATTEMPTS,
          });
        }
        return applyPlan(input, counters, {
          state: 'preparing',
          epoch: input.epoch + 1,
          reason: 'reconnect',
          reconnectAttempts: nextAttempt,
          nextRetryDelayMs: reconnectDelayMs(nextAttempt),
          preparingDeadlineMs: deadlineFrom(input),
        });
      }
      return rejectTransition(input, counters, 'illegal_transition', 'link_lost_outside_session');
    }

    case 'reconnectExhausted': {
      // 重连预算耗尽：只允许来自重连中的 preparing。
      if (from !== 'preparing' || input.stateReason !== 'reconnect') {
        return rejectTransition(input, counters, 'illegal_transition', 'exhausted_requires_reconnect');
      }
      return applyPlan(input, counters, {
        state: 'failed',
        epoch: input.epoch + 1,
        errorCode: 'extension_crashed',
        reconnectAttempts: RECONNECT_MAX_ATTEMPTS,
      });
    }

    case 'retryRequested': {
      // 迁移表：unauthorized / failed + 手动重试 → preparing（重置崩溃计数）。
      if (from !== 'unauthorized' && from !== 'failed') {
        return rejectTransition(input, counters, 'illegal_transition', 'retry_requires_unauthorized_or_failed');
      }
      if (!facts.hasValidProfile) {
        return rejectTransition(input, counters, 'no_valid_profile', 'retry_without_valid_profile');
      }
      return applyPlan(input, counters, {
        state: 'preparing',
        epoch: input.epoch + 1,
        reason: startReason(facts.reason),
        reconnectAttempts: 0,
        preparingDeadlineMs: deadlineFrom(input),
      });
    }

    case 'appRestarted': {
      // 迁移表：任意 + 应用重启 → stopped（有配置）或 unconfigured；禁止恢复 connected。
      return applyPlan(input, counters, {
        state: facts.hasValidProfile ? 'stopped' : 'unconfigured',
        epoch: input.epoch + 1,
        reconnectAttempts: 0,
      });
    }

    default: {
      // 运行时兜底：JS 调用方可能传入未知事件，按非法迁移拒绝而不是抛异常。
      return rejectTransition(input, counters, 'illegal_transition', 'unsupported_event');
    }
  }
}

/** 解析 preparing 的文案原因；未提供有效原因时按首启处理。 */
export function resolvePreparingReason(input: StateMachineInput): PreparingReason {
  if (input.state === 'preparing' && input.stateReason !== undefined) {
    return input.stateReason;
  }
  if (input.state === 'preparing') {
    return 'start';
  }
  return input.facts.reason !== undefined ? startReason(input.facts.reason) : 'start';
}