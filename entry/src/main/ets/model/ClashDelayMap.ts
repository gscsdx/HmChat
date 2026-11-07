/**
 * Clash 延迟结果聚合与批量测速调度计划（任务 T-S1-09）。
 *
 * 职责：
 * - 维护「测速地址 url → 节点名 → DelayEntry」的只读内存快照，供节点列表展示；
 * - 合并异步到达的测速结果：同 url + name 覆盖，按调用方传入的 at 丢弃乱序旧值；
 * - 生成并发受控的分批派发计划，并在取消时保留已完成项、把未完成项置 idle；
 * - 按节点名清除结果，或清空全部结果。
 *
 * 约束（docs/integration/clash-proxy-tasks.md T-S1-09、设计 §8.2）：
 * - 纯 TypeScript，只依赖 ./ClashModels 的类型；不引用 Kit、不发请求、不读时钟。
 *   `at` 由调用方以 epoch 毫秒传入，本模块只按它比较新旧。
 * - 不修改入参：applyDelay / cancel / clearProfile 都返回新对象；未受影响的内层
 *   容器按引用共享，调用方可直接把返回值交给 UI 状态替换。
 * - value 语义固定：-1 失败、0 未完成（加载中）、大于 0 为毫秒。0 绝不代表成功，
 *   成功判定必须使用 isSuccess()，不能只看 value 是否非负。
 * - 上游 `delay{name,url,value}` 事件可能乱序到达，后到的旧值不能覆盖先到的新值。
 */

import { DelayEntry, DelayMap, DelayState } from './ClashModels';

/** 失败结果的标准值；任何非正数、非有限数都归一化为它。 */
export const DELAY_VALUE_FAILED: number = -1;

/** 未完成结果的标准值；loading 与 idle 都用它，二者由 state 区分。 */
export const DELAY_VALUE_PENDING: number = 0;

/** 批量派发的最小并发。 */
export const MIN_BATCH_CONCURRENCY: number = 4;

/** 批量派发的最大并发。 */
export const MAX_BATCH_CONCURRENCY: number = 8;

/** 未指定并发时使用的最小并发（设计「批量：并发 4（可配 4–8）」）。 */
export const DEFAULT_BATCH_CONCURRENCY: number = 4;

// ---------------------------------------------------------------------------
// 内部：结果构造与不可变复制
// ---------------------------------------------------------------------------

/** 把上游数值分类成状态；非有限数按失败处理，0 只表示未完成。 */
function classifyDelayValue(value: number): DelayState {
  if (Number.isFinite(value) && value > 0) {
    return 'ok';
  }
  if (value === 0) {
    return 'loading';
  }
  return 'failed';
}

/** 状态是唯一真值，value 只保存该状态下的标准表示。 */
function canonicalDelayValue(value: number, state: DelayState): number {
  if (state === 'ok') {
    return value;
  }
  if (state === 'loading') {
    return DELAY_VALUE_PENDING;
  }
  return DELAY_VALUE_FAILED;
}

/** 构造一条结果记录；时间由调用方提供，不读本机时钟。 */
function makeDelayEntry(value: number, at: number): DelayEntry {
  const state: DelayState = classifyDelayValue(value);
  return { value: canonicalDelayValue(value, state), at: at, state: state };
}

/** 复制外层 url → bucket 映射；bucket 本身按引用共享，后续只替换被修改的那一个。 */
function copyDelayMap(map: DelayMap): DelayMap {
  const next: DelayMap = {};
  if (!map) {
    return next;
  }
  const urls: string[] = Object.keys(map);
  for (let index: number = 0; index < urls.length; index++) {
    const url: string = urls[index];
    next[url] = map[url];
  }
  return next;
}

/** 复制单个 url 下的 name → entry 映射；entry 不可变，按引用共享。 */
function copyDelayBucket(bucket: Record<string, DelayEntry>): Record<string, DelayEntry> {
  const next: Record<string, DelayEntry> = {};
  if (!bucket) {
    return next;
  }
  const proxyNames: string[] = Object.keys(bucket);
  for (let index: number = 0; index < proxyNames.length; index++) {
    const proxyName: string = proxyNames[index];
    next[proxyName] = bucket[proxyName];
  }
  return next;
}

// ---------------------------------------------------------------------------
// 查询
// ---------------------------------------------------------------------------

/**
 * 判断一条结果是否可作为成功展示。
 *
 * 必须同时满足 state 为 ok 且 value 大于 0：value 为 0 的加载中占位、value 为 -1
 * 的失败、以及缺失的结果都不能显示成延迟毫秒数。
 */
export function isSuccess(entry?: DelayEntry): boolean {
  if (!entry) {
    return false;
  }
  return entry.state === 'ok' && entry.value > 0;
}

// ---------------------------------------------------------------------------
// 写入
// ---------------------------------------------------------------------------

/**
 * 合并一次测速结果。
 *
 * - 同一 url + name 覆盖旧值；不同 url 之间互不影响；
 * - 乱序保护：仅当 `at` 大于已保存记录的 `at` 时才覆盖，否则丢弃本次到达的旧值。
 *   调用方应以「请求时刻」写入 loading 占位、以「结果到达时刻」写入终值，
 *   两者必须严格递增；
 * - name 或 url 为空、at 非有限数时不做写入，仍返回新 map，便于调用方统一替换；
 * - 不修改 map 入参。
 */
export function applyDelay(
  map: DelayMap,
  name: string,
  url: string,
  value: number,
  at: number,
): DelayMap {
  const next: DelayMap = copyDelayMap(map);
  if (typeof name !== 'string' || name.length === 0) {
    return next;
  }
  if (typeof url !== 'string' || url.length === 0) {
    return next;
  }
  if (!Number.isFinite(at)) {
    return next;
  }
  const existingBucket: Record<string, DelayEntry> | undefined = next[url];
  const bucket: Record<string, DelayEntry> = existingBucket ? copyDelayBucket(existingBucket) : {};
  const existing: DelayEntry | undefined = bucket[name];
  if (existing !== undefined && at <= existing.at) {
    // 旧事件迟到（或同刻重放），保留已存在的较新结果。
    return next;
  }
  bucket[name] = makeDelayEntry(value, at);
  next[url] = bucket;
  return next;
}

// ---------------------------------------------------------------------------
// 批量调度计划
// ---------------------------------------------------------------------------

/** 并发夹紧到 4–8；非有限数与小数按向下取整处理，未知值回退默认并发。 */
function clampConcurrency(concurrency: number): number {
  if (!Number.isFinite(concurrency)) {
    return DEFAULT_BATCH_CONCURRENCY;
  }
  const floored: number = Math.floor(concurrency);
  if (floored < MIN_BATCH_CONCURRENCY) {
    return MIN_BATCH_CONCURRENCY;
  }
  if (floored > MAX_BATCH_CONCURRENCY) {
    return MAX_BATCH_CONCURRENCY;
  }
  return floored;
}

/**
 * 生成分批派发计划：返回 `string[][]`，每批最多 `concurrency` 个节点名。
 *
 * - 并发夹紧 4–8，默认 4；
 * - 空名丢弃、重复名只保留首次出现（测速结果按 name 关联，重复只会互相覆盖）；
 * - 只做计划，不派发请求、不写 DelayMap；调用方按返回顺序逐批执行即可。
 */
export function planBatch(
  names: string[],
  concurrency: number = DEFAULT_BATCH_CONCURRENCY,
): string[][] {
  const batches: string[][] = [];
  if (!Array.isArray(names)) {
    return batches;
  }
  const size: number = clampConcurrency(concurrency);
  const unique: string[] = [];
  const seen: Set<string> = new Set<string>();
  for (let index: number = 0; index < names.length; index++) {
    const name: string = names[index];
    if (typeof name !== 'string' || name.length === 0) {
      continue;
    }
    if (seen.has(name)) {
      continue;
    }
    seen.add(name);
    unique.push(name);
  }
  for (let start: number = 0; start < unique.length; start += size) {
    batches.push(unique.slice(start, start + size));
  }
  return batches;
}

// ---------------------------------------------------------------------------
// 取消与清除
// ---------------------------------------------------------------------------

/**
 * 取消一轮批量测速后的结果快照。
 *
 * - 已完成的 ok / failed 结果原样保留；
 * - 仍为 loading 的未完成项置为 idle，value 归零，保留其请求时刻 at；
 * - 不修改入参，空的 url bucket 保持原样（取消不清除历史结果）。
 */
export function cancel(results: DelayMap): DelayMap {
  const next: DelayMap = {};
  if (!results) {
    return next;
  }
  const urls: string[] = Object.keys(results);
  for (let urlIndex: number = 0; urlIndex < urls.length; urlIndex++) {
    const url: string = urls[urlIndex];
    const bucket: Record<string, DelayEntry> = results[url];
    const nextBucket: Record<string, DelayEntry> = {};
    const proxyNames: string[] = Object.keys(bucket);
    let changed: boolean = false;
    for (let nameIndex: number = 0; nameIndex < proxyNames.length; nameIndex++) {
      const proxyName: string = proxyNames[nameIndex];
      const entry: DelayEntry = bucket[proxyName];
      if (entry.state === 'loading') {
        nextBucket[proxyName] = { value: DELAY_VALUE_PENDING, at: entry.at, state: 'idle' };
        changed = true;
      } else {
        nextBucket[proxyName] = entry;
      }
    }
    next[url] = changed ? nextBucket : bucket;
  }
  return next;
}

/**
 * 清除指定节点在全部测速地址下的结果（设计 §9 删除 profile 时清理节点延迟）。
 *
 * - 只按节点名匹配，跨 url 删除；
 * - 删除后为空的 url bucket 从结果中移除，避免残留空地址；
 * - 未命中的 bucket 按引用保留，不修改入参。
 */
export function clearProfile(map: DelayMap, names: string[]): DelayMap {
  if (!Array.isArray(names)) {
    return copyDelayMap(map);
  }
  const targets: Set<string> = new Set<string>();
  for (let index: number = 0; index < names.length; index++) {
    const name: string = names[index];
    if (typeof name === 'string' && name.length > 0) {
      targets.add(name);
    }
  }
  if (targets.size === 0) {
    return copyDelayMap(map);
  }
  const next: DelayMap = {};
  if (!map) {
    return next;
  }
  const urls: string[] = Object.keys(map);
  for (let urlIndex: number = 0; urlIndex < urls.length; urlIndex++) {
    const url: string = urls[urlIndex];
    const bucket: Record<string, DelayEntry> = map[url];
    const nextBucket: Record<string, DelayEntry> = {};
    const proxyNames: string[] = Object.keys(bucket);
    let removed: boolean = false;
    for (let nameIndex: number = 0; nameIndex < proxyNames.length; nameIndex++) {
      const proxyName: string = proxyNames[nameIndex];
      if (targets.has(proxyName)) {
        removed = true;
        continue;
      }
      nextBucket[proxyName] = bucket[proxyName];
    }
    if (!removed) {
      next[url] = bucket;
      continue;
    }
    if (Object.keys(nextBucket).length > 0) {
      next[url] = nextBucket;
    }
  }
  return next;
}

/** 清空全部测速结果；只返回新的空 map，不触碰任何入参。 */
export function clearAll(): DelayMap {
  return {};
}