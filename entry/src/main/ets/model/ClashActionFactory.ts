/**
 * Action 信封构造、方法白名单、超时表与结果解码（任务 T-S1-06）。
 *
 * 证据来源：
 * - docs/integration/clash-proxy-design.md §5.4（core.action 方法白名单与超时表）、
 *   §9.1（Action/ActionResult 线格式、id 规则、code 语义）、§9.3（配置类空串成功）、
 *   §9.4（changeProxy/healthCheck/asyncTestDelay 参数与失败语义）、§5.7（事件白名单）。
 * - docs/integration/flclash-core-lib-baseline.md §2（真实方法表、参数 schema、空节点名）。
 * - docs/integration/clash-proxy-tasks.md T-S1-06。
 *
 * 约束：
 * - 纯 TypeScript：只依赖 ./ClashModels 与 ./ClashError，不引用 Kit，不读文件、不发请求、
 *   不读时钟；可在宿主机直接转译与单元测试。
 * - 所有 Action 载荷都是 JSON 字符串或普通字符串，绝不把对象直接交给内核。
 * - 白名单外的方法在构造阶段直接抛 `method_not_allowed`，不产生请求。
 * - 解码必须同时检查 `code === 0` 与字符串类方法的 `data === ''`；不能把 `''` 单独
 *   当作成功（设计 §9.6）。
 */

import {
  ActionEnvelope,
  JsonPayload,
  ProxyError,
  RawConfig,
  SetupParams,
} from './ClashModels';
import { ProxyErrorCode } from './ClashError';

// ---------------------------------------------------------------------------
// 固定错误码（抛出的 Error.message 只含稳定码，不拼接用户输入）
// ---------------------------------------------------------------------------

/** 方法不在设计 §5.4 白名单内。 */
export const ACTION_METHOD_NOT_ALLOWED: string = 'method_not_allowed';
/** id 不符合 `<method>#<epoch>-<seq>` 或与 method 不一致。 */
export const ACTION_INVALID_ID: string = 'invalid_action_id';
/** 载荷类型错误（例如把对象当字符串传入）。 */
export const ACTION_INVALID_DATA: string = 'invalid_action_data';
/** 组名为空，无法构造 changeProxy / selected-map。 */
export const ACTION_EMPTY_GROUP: string = 'empty_group_name';
/** 节点名为空；内核会 `ForceSet("")`，禁止发送（设计 §9.4）。 */
export const ACTION_EMPTY_PROXY: string = 'empty_proxy_name';
/** 测速超时不是正整数。 */
export const ACTION_INVALID_TIMEOUT: string = 'invalid_timeout';
/** getConfig 的路径为空或含 NUL。 */
export const ACTION_INVALID_PATH: string = 'invalid_path';
/** setupConfig 的 config 或 selected-map 结构非法。 */
export const ACTION_INVALID_CONFIG: string = 'invalid_setup_config';
/** RawConfig 顶层出现 `rules` 而没有 `rule`：必须是 `rule`（设计 §9.3）。 */
export const ACTION_RULES_KEY_MISMATCH: string = 'rules_key_mismatch';
/** JSON 序列化失败（循环引用、BigInt 等）。 */
export const ACTION_ENCODE_FAILED: string = 'encode_failed';

// ---------------------------------------------------------------------------
// 方法白名单（严格等于设计 §5.4 的 24 项）
// ---------------------------------------------------------------------------

/**
 * `core.action` 允许从 UI 发起的方法。
 * 顺序与设计 §5.4 一致；新增/删除必须同步设计文档与 T-S1-06 验收用例。
 */
export type ClashActionMethod =
  | 'getProxies'
  | 'changeProxy'
  | 'asyncTestDelay'
  | 'healthCheck'
  | 'getConfig'
  | 'validateConfig'
  | 'setupConfig'
  | 'updateConfig'
  | 'getConnections'
  | 'closeConnections'
  | 'getCoreVersion'
  | 'getTraffic'
  | 'getTotalTraffic'
  | 'resetTraffic'
  | 'getRunTime'
  | 'getCurrentProfileName'
  | 'getAndroidVpnOptions'
  | 'getIsInit'
  | 'setState'
  | 'shutdown'
  | 'startLog'
  | 'stopLog'
  | 'getMemory'
  | 'forceGc';

/** 24 项白名单，逐项对应设计 §5.4。 */
export const METHOD_WHITELIST: ClashActionMethod[] = [
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
  'forceGc',
];

/** 判断方法是否允许从 UI 发起；未列入的方法一律拒绝。 */
export function isActionMethod(method: string): boolean {
  return METHOD_WHITELIST.indexOf(method as ClashActionMethod) >= 0;
}

// ---------------------------------------------------------------------------
// 超时表（T-S1-06 交付口径：单列项 + 其余统一 15 s）
// ---------------------------------------------------------------------------

/** 未单列方法的统一超时。 */
export const DEFAULT_ACTION_TIMEOUT_MS: number = 15000;
/** 单节点测速的默认 timeout；与上游 `TestDelayParams.timeout` 默认值一致。 */
export const DEFAULT_TEST_TIMEOUT_MS: number = 5000;
/** `asyncTestDelay` 在请求 timeout 之上预留的余量。 */
export const ASYNC_TEST_DELAY_MARGIN_MS: number = 2000;

/**
 * 方法超时表（毫秒），集中维护。
 * `asyncTestDelay` 的取值是「默认 timeout + 2 s」；自定义 timeout 时用
 * `resolveTimeoutMs(method, timeout)` 计算，二者保持一致。
 */
export interface ActionTimeoutTable {
  getProxies: number;
  changeProxy: number;
  asyncTestDelay: number;
  healthCheck: number;
  getConfig: number;
  validateConfig: number;
  setupConfig: number;
  updateConfig: number;
  getConnections: number;
  closeConnections: number;
  getCoreVersion: number;
  getTraffic: number;
  getTotalTraffic: number;
  resetTraffic: number;
  getRunTime: number;
  getCurrentProfileName: number;
  getAndroidVpnOptions: number;
  getIsInit: number;
  setState: number;
  shutdown: number;
  startLog: number;
  stopLog: number;
  getMemory: number;
  forceGc: number;
}

export const TIMEOUT_MS: ActionTimeoutTable = {
  getProxies: 15000,
  changeProxy: 15000,
  asyncTestDelay: DEFAULT_TEST_TIMEOUT_MS + ASYNC_TEST_DELAY_MARGIN_MS,
  healthCheck: DEFAULT_ACTION_TIMEOUT_MS,
  getConfig: 20000,
  validateConfig: 30000,
  setupConfig: 60000,
  updateConfig: DEFAULT_ACTION_TIMEOUT_MS,
  getConnections: DEFAULT_ACTION_TIMEOUT_MS,
  closeConnections: DEFAULT_ACTION_TIMEOUT_MS,
  getCoreVersion: DEFAULT_ACTION_TIMEOUT_MS,
  getTraffic: DEFAULT_ACTION_TIMEOUT_MS,
  getTotalTraffic: DEFAULT_ACTION_TIMEOUT_MS,
  resetTraffic: DEFAULT_ACTION_TIMEOUT_MS,
  getRunTime: DEFAULT_ACTION_TIMEOUT_MS,
  getCurrentProfileName: DEFAULT_ACTION_TIMEOUT_MS,
  getAndroidVpnOptions: DEFAULT_ACTION_TIMEOUT_MS,
  getIsInit: DEFAULT_ACTION_TIMEOUT_MS,
  setState: DEFAULT_ACTION_TIMEOUT_MS,
  shutdown: DEFAULT_ACTION_TIMEOUT_MS,
  startLog: DEFAULT_ACTION_TIMEOUT_MS,
  stopLog: DEFAULT_ACTION_TIMEOUT_MS,
  getMemory: DEFAULT_ACTION_TIMEOUT_MS,
  forceGc: DEFAULT_ACTION_TIMEOUT_MS,
};

/** 返回方法的基础超时；调用前必须已通过白名单。 */
function baseTimeoutFor(method: string): number {
  switch (method) {
    case 'getProxies':
      return TIMEOUT_MS.getProxies;
    case 'changeProxy':
      return TIMEOUT_MS.changeProxy;
    case 'getConfig':
      return TIMEOUT_MS.getConfig;
    case 'validateConfig':
      return TIMEOUT_MS.validateConfig;
    case 'setupConfig':
      return TIMEOUT_MS.setupConfig;
    case 'asyncTestDelay':
      return TIMEOUT_MS.asyncTestDelay;
    default:
      return DEFAULT_ACTION_TIMEOUT_MS;
  }
}

/**
 * 计算某方法的请求超时。
 * `asyncTestDelay` 使用实际发送的 timeout + 2 s；其余方法查 `TIMEOUT_MS`。
 * 方法不在白名单或 timeout 非法时抛稳定错误码。
 */
export function resolveTimeoutMs(method: string, testTimeoutMs?: number): number {
  if (!isActionMethod(method)) {
    throw new Error(ACTION_METHOD_NOT_ALLOWED);
  }
  if (method === 'asyncTestDelay') {
    return normalizeTestTimeout(testTimeoutMs) + ASYNC_TEST_DELAY_MARGIN_MS;
  }
  return baseTimeoutFor(method);
}

// ---------------------------------------------------------------------------
// 通用校验与序列化
// ---------------------------------------------------------------------------

function isNonBlank(value: string): boolean {
  return typeof value === 'string' && value.trim().length > 0;
}

function requireNonBlank(value: string, code: string): void {
  if (!isNonBlank(value)) {
    throw new Error(code);
  }
}

/** 仅接受十进制数字串（epoch/seq 不含符号、空格或前导 `+`）。 */
function isUnsignedIntegerText(text: string): boolean {
  if (text.length === 0) {
    return false;
  }
  for (let index: number = 0; index < text.length; index++) {
    const code: number = text.charCodeAt(index);
    if (code < 0x30 || code > 0x39) {
      return false;
    }
  }
  return true;
}

/** id 必须精确等于 `<method>#<epoch>-<seq>`。 */
function isValidActionId(id: string, method: ClashActionMethod): boolean {
  if (typeof id !== 'string' || id.length === 0) {
    return false;
  }
  const hashIndex: number = id.indexOf('#');
  if (hashIndex < 0 || id.substring(0, hashIndex) !== method) {
    return false;
  }
  const range: string = id.substring(hashIndex + 1);
  const dashIndex: number = range.indexOf('-');
  if (dashIndex < 0) {
    return false;
  }
  const epochText: string = range.substring(0, dashIndex);
  const seqText: string = range.substring(dashIndex + 1);
  if (seqText.indexOf('-') >= 0) {
    return false;
  }
  return isUnsignedIntegerText(epochText) && isUnsignedIntegerText(seqText);
}

/** 验证非负整数（epoch/seq）。 */
function isUnsignedInteger(value: number): boolean {
  return Number.isFinite(value) && Math.floor(value) === value && value >= 0;
}

/**
 * 校验并返回测速 timeout（毫秒）。
 * 未提供时回退默认 5000；非正整数直接抛错，避免内核收到 0 或负数。
 */
function normalizeTestTimeout(timeout: number | undefined): number {
  if (timeout === undefined) {
    return DEFAULT_TEST_TIMEOUT_MS;
  }
  if (!Number.isFinite(timeout) || Math.floor(timeout) !== timeout || timeout <= 0) {
    throw new Error(ACTION_INVALID_TIMEOUT);
  }
  return timeout;
}

/** JSON 序列化；失败统一转成 `encode_failed`，不回显载荷内容。 */
function encodeJson(value: object): string {
  let encoded: string | undefined = undefined;
  try {
    encoded = JSON.stringify(value);
  } catch {
    throw new Error(ACTION_ENCODE_FAILED);
  }
  if (typeof encoded !== 'string') {
    throw new Error(ACTION_ENCODE_FAILED);
  }
  return encoded;
}

// ---------------------------------------------------------------------------
// Action 信封
// ---------------------------------------------------------------------------

/**
 * 生成客户端 Action id：`<method>#<epoch>-<seq>`（设计 §9.1）。
 * epoch/seq 必须是非负整数，避免 id 在不同会话间产生歧义。
 */
export function makeActionId(method: string, epoch: number, seq: number): string {
  if (!isActionMethod(method)) {
    throw new Error(ACTION_METHOD_NOT_ALLOWED);
  }
  const actionMethod: ClashActionMethod = method as ClashActionMethod;
  if (!isUnsignedInteger(epoch) || !isUnsignedInteger(seq)) {
    throw new Error(ACTION_INVALID_ID);
  }
  return actionMethod + '#' + String(epoch) + '-' + String(seq);
}

/**
 * 构造 Action 信封。
 * - 方法必须在 24 项白名单内，否则抛 `method_not_allowed`。
 * - id 必须与 method 匹配，形如 `<method>#<epoch>-<seq>`。
 * - 无参数方法省略 `data`；有参数时只接受字符串（JSON 字符串或普通字符串）。
 */
export function buildAction(id: string, method: string, data?: string): ActionEnvelope {
  if (!isActionMethod(method)) {
    throw new Error(ACTION_METHOD_NOT_ALLOWED);
  }
  const actionMethod: ClashActionMethod = method as ClashActionMethod;
  if (typeof id !== 'string' || !isValidActionId(id, actionMethod)) {
    throw new Error(ACTION_INVALID_ID);
  }
  if (data !== undefined && typeof data !== 'string') {
    throw new Error(ACTION_INVALID_DATA);
  }
  const envelope: ActionEnvelope = { id: id, method: actionMethod };
  if (data !== undefined) {
    envelope.data = data;
  }
  return envelope;
}

// ---------------------------------------------------------------------------
// 载荷构造器（只组装 data，不生成 id、不读文件、不发请求）
// ---------------------------------------------------------------------------

/** `changeProxy` 的参数（baseline §2.3 ChangeProxyParams）。 */
export interface ChangeProxyParams {
  'group-name': string;
  'proxy-name': string;
}

/**
 * 组装 `changeProxy` 的 JSON 字符串：`{"group-name","proxy-name"}`。
 * 空组名或空节点名直接抛错；空 `proxy-name` 会让内核 `ForceSet("")`。
 */
export function buildChangeProxy(group: string, proxy: string): string {
  requireNonBlank(group, ACTION_EMPTY_GROUP);
  requireNonBlank(proxy, ACTION_EMPTY_PROXY);
  const params: ChangeProxyParams = {
    'group-name': group,
    'proxy-name': proxy,
  };
  return encodeJson(params);
}

/** `asyncTestDelay` 的参数（baseline §2.3 TestDelayParams）。 */
export interface AsyncTestDelayParams {
  'proxy-name': string;
  'test-url': string;
  timeout: number;
}

/**
 * 组装 `asyncTestDelay` 的 JSON 字符串。
 * `url` 允许为空串（内核回退默认测速地址）；`timeout` 必须为正整数毫秒。
 */
export function buildAsyncTestDelay(name: string, url: string, timeout: number): string {
  requireNonBlank(name, ACTION_EMPTY_PROXY);
  if (typeof url !== 'string') {
    throw new Error(ACTION_INVALID_DATA);
  }
  const params: AsyncTestDelayParams = {
    'proxy-name': name,
    'test-url': url,
    timeout: normalizeTestTimeout(timeout),
  };
  return encodeJson(params);
}

/** 读取 selected-map 用的宽松视图；只做结构校验，不改写节点名。 */
function assertSelectedMap(selectedMap: Record<string, string>): void {
  if (selectedMap === null || typeof selectedMap !== 'object' || Array.isArray(selectedMap)) {
    throw new Error(ACTION_INVALID_CONFIG);
  }
  const groups: string[] = Object.keys(selectedMap);
  for (let index: number = 0; index < groups.length; index++) {
    const group: string = groups[index];
    requireNonBlank(group, ACTION_EMPTY_GROUP);
    const proxy: string = selectedMap[group];
    if (!isNonBlank(proxy)) {
      throw new Error(ACTION_EMPTY_PROXY);
    }
  }
}

/** 只探测会误用的顶层规则键；不遍历整个 RawConfig。 */
interface RawConfigRuleProbe {
  rule?: JsonPayload;
  rules?: JsonPayload;
}

/**
 * 组装 `setupConfig` 的 JSON 字符串：`SetupParams{config,selected-map,test-url}`。
 * 只组装载荷，不写文件、不读 YAML。`rules` 键误用在此拦截（设计 §9.3 要求 `rule`）。
 */
export function buildSetupConfig(
  config: RawConfig,
  selectedMap: Record<string, string>,
  testUrl: string,
): string {
  if (config === null || typeof config !== 'object' || Array.isArray(config)) {
    throw new Error(ACTION_INVALID_CONFIG);
  }
  const probe: RawConfigRuleProbe = config as RawConfigRuleProbe;
  if (probe.rules !== undefined && probe.rule === undefined) {
    throw new Error(ACTION_RULES_KEY_MISMATCH);
  }
  assertSelectedMap(selectedMap);
  if (typeof testUrl !== 'string') {
    throw new Error(ACTION_INVALID_DATA);
  }
  const params: SetupParams = {
    config: config,
    'selected-map': selectedMap,
    'test-url': testUrl,
  };
  return encodeJson(params);
}

/**
 * 组装 `getConfig` 的 data：文件路径或 profileId，原样交给扩展解析。
 * 只拒绝空串与 NUL，不做路径归一化（越界判断由扩展侧负责）。
 */
export function buildGetConfig(path: string): string {
  if (!isNonBlank(path) || path.indexOf('\u0000') >= 0) {
    throw new Error(ACTION_INVALID_PATH);
  }
  return path;
}

/**
 * 组装 `healthCheck` 的 data：组名；空或未提供表示全部组（设计 §9.4）。
 * 结果通过 `delay` 事件推送，不依赖 ActionResult.data。
 */
export function buildHealthCheck(group?: string): string {
  if (group === undefined || group === null) {
    return '';
  }
  if (typeof group !== 'string') {
    throw new Error(ACTION_INVALID_DATA);
  }
  return group.trim().length === 0 ? '' : group;
}

// ---------------------------------------------------------------------------
// ActionResult / message 解码
// ---------------------------------------------------------------------------

/** 内核事件类型白名单（设计 §5.7）。 */
export type ClashEventType = 'loaded' | 'delay' | 'traffic' | 'log';

/** 解出的事件包装：与内核 `Message{type,data}` 一致。 */
export interface DecodedMessageEvent {
  type: ClashEventType;
  data?: JsonPayload;
}

/** 解码结果种类：普通 ActionResult 或 method="message" 的事件包装。 */
export type ActionDecodeKind = 'result' | 'message';

/**
 * 解码后的 Action 结果。
 * - `ok=true` 仅当 `code===0` 且该方法的结果判据成立。
 * - `error` 只含分类码与细分码，不含原始 data/错误字符串（可能含节点名或配置文本）。
 * - `kind=message` 时 `eventType` 为白名单事件类型，`data` 为事件载荷，不参与 ok 判定。
 */
export interface DecodedActionResult {
  kind: ActionDecodeKind;
  ok: boolean;
  method: string;
  eventType?: ClashEventType;
  data?: JsonPayload;
  error?: ProxyError;
}

/** ActionResult 的宽松视图：每个字段都防御性读取。 */
interface ActionResultView {
  id?: JsonPayload;
  method?: JsonPayload;
  data?: JsonPayload;
  code?: JsonPayload;
}

/** message 事件内部 `{type,data}` 的宽松视图。 */
interface MessageView {
  type?: JsonPayload;
  data?: JsonPayload;
}

/** 把字符串 JSON 或对象统一转成对象；标量、数组与非法 JSON 返回 null。 */
function parseEnvelope(raw: JsonPayload): object | null {
  let value: JsonPayload = raw;
  if (typeof raw === 'string') {
    try {
      value = JSON.parse(raw) as JsonPayload;
    } catch {
      return null;
    }
  }
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    return null;
  }
  return value as object;
}

/** 读取整数 code；缺失、非数字或非整数返回 null。 */
function readInteger(value: JsonPayload | undefined): number | null {
  if (typeof value !== 'number' || !Number.isFinite(value)) {
    return null;
  }
  if (Math.floor(value) !== value) {
    return null;
  }
  return value;
}

/** 字符串类方法：成功时 data 必须为空串（设计 §9.1、§9.6）。 */
function isErrorStringMethod(method: string): boolean {
  return method === 'changeProxy'
    || method === 'validateConfig'
    || method === 'setupConfig'
    || method === 'updateConfig'
    || method === 'healthCheck';
}

/** 这些方法必须带回非空结果；空结果按失败处理，不能伪造成功。 */
function requiresResultData(method: string): boolean {
  return method === 'getProxies'
    || method === 'getConfig'
    || method === 'asyncTestDelay';
}

/** 按方法把失败映射到 ClashError 的权威码表；不向外暴露错误字符串。 */
function errorCodeFor(method: string): ProxyErrorCode {
  if (method === 'validateConfig' || method === 'setupConfig') {
    // 配置类：空串=成功，非空字符串=失败（设计 §9.3）。
    return 'config_invalid';
  }
  if (method === 'updateConfig') {
    return 'config_invalid';
  }
  if (method === 'getConfig') {
    // ActionResult 无法区分 path_rejected 与解析失败；扩展侧先归类。
    return 'config_invalid';
  }
  return 'internal';
}

function failure(method: string, code: ProxyErrorCode, detailCode: string): DecodedActionResult {
  return {
    kind: 'result',
    ok: false,
    method: method,
    error: { code: code, detailCode: detailCode },
  };
}

function success(method: string, data?: JsonPayload): DecodedActionResult {
  const result: DecodedActionResult = {
    kind: 'result',
    ok: true,
    method: method,
  };
  if (data !== undefined) {
    result.data = data;
  }
  return result;
}

function isEventType(value: string): boolean {
  return value === 'loaded' || value === 'delay' || value === 'traffic' || value === 'log';
}

/**
 * 解码 `method="message"` 的事件包装为 `{type,data}`。
 * 只有 code=0、data 为对象且 type 在白名单内才返回；未知类型与畸形帧返回 null，
 * 由上层丢弃并计数（设计 §5.7）。
 */
function decodeMessagePayload(view: ActionResultView): DecodedMessageEvent | null {
  if (readInteger(view.code) !== 0) {
    return null;
  }
  const payload: JsonPayload | undefined = view.data;
  if (payload === undefined || payload === null || typeof payload !== 'object' || Array.isArray(payload)) {
    return null;
  }
  const message: MessageView = payload as MessageView;
  if (typeof message.type !== 'string' || !isEventType(message.type)) {
    return null;
  }
  const event: DecodedMessageEvent = {
    type: message.type as ClashEventType,
  };
  if (message.data !== undefined) {
    event.data = message.data;
  }
  return event;
}

/**
 * 独立解码事件帧，返回设计 §5.7 的 `{type,data}`；未知 type 与畸形帧返回 null。
 * 事件不是可调用 Action，因此不接受非 `method="message"` 的信封。
 */
export function decodeMessageEvent(raw: JsonPayload): DecodedMessageEvent | null {
  const envelope: object | null = parseEnvelope(raw);
  if (envelope === null) {
    return null;
  }
  const view: ActionResultView = envelope as ActionResultView;
  if (view.method !== 'message') {
    return null;
  }
  return decodeMessagePayload(view);
}

/**
 * 解码 ActionResult（对象或 JSON 字符串）。
 *
 * 成功判据（设计 §9.1、§9.6）：
 * - 必须 `code === 0`；
 * - 字符串类方法（changeProxy/validateConfig/setupConfig/updateConfig/healthCheck）
 *   还必须 `data === ''`；`setupConfig`/`validateConfig` 的空串是成功，非空串是失败；
 * - getProxies/getConfig/asyncTestDelay 必须有非空结果，否则按失败处理。
 *
 * `method="message"` 按事件解码为 `{type,data}`；未知 type 或畸形事件返回 null。
 * 其余非法输入返回 `ok=false` 的结构化错误，不抛异常。
 */
export function decodeActionResult(raw: JsonPayload): DecodedActionResult | null {
  const envelope: object | null = parseEnvelope(raw);
  if (envelope === null) {
    return failure('', 'internal', 'invalid_envelope');
  }
  const view: ActionResultView = envelope as ActionResultView;
  const method: string = typeof view.method === 'string' ? view.method : '';
  if (method === 'message') {
    const message: DecodedMessageEvent | null = decodeMessagePayload(view);
    if (message === null) {
      return null;
    }
    const event: DecodedActionResult = {
      kind: 'message',
      ok: true,
      method: 'message',
      eventType: message.type,
    };
    if (message.data !== undefined) {
      event.data = message.data;
    }
    return event;
  }
  if (method.length === 0) {
    return failure('', 'internal', 'invalid_envelope');
  }
  if (!isActionMethod(method)) {
    return failure(method, 'internal', 'method_not_allowed');
  }
  const code: number | null = readInteger(view.code);
  if (code === null) {
    return failure(method, 'internal', 'invalid_code');
  }
  if (code !== 0) {
    return failure(method, errorCodeFor(method), 'code_nonzero');
  }
  if (isErrorStringMethod(method)) {
    if (typeof view.data !== 'string') {
      return failure(method, errorCodeFor(method), 'invalid_error_string');
    }
    if (view.data.length !== 0) {
      // 非空错误字符串即使 code=0 也是失败（上游 setupConfig 可能如此）。
      return failure(method, errorCodeFor(method), 'error_string');
    }
    return success(method, '');
  }
  if (requiresResultData(method)) {
    if (view.data === undefined || view.data === null) {
      return failure(method, errorCodeFor(method), 'missing_result');
    }
    if (typeof view.data === 'string' && view.data.length === 0) {
      return failure(method, errorCodeFor(method), 'empty_result');
    }
  }
  return success(method, view.data);
}