/**
 * Clash 订阅受控 HTTP 拉取（任务 T-S2-07，设计 §10.2）。
 *
 * 职责只有一件事：把一次订阅请求的正文写入调用方提供的临时文件，并返回
 * 显式的成功/失败结果。本模块不做 YAML 校验、不解析响应头、不重命名文件、
 * 不读写 Preferences、不调用内核，也不引用聊天服务或媒体网络监控模块。
 *
 * 受控边界：
 * - 仅接受 http/https 的初始 URL，复用 `ClashSubscriptionParser.validateUrl`；
 * - 使用 NetworkKit 非流式 `http.createHttp().request()` 一次取回正文；
 * - 连接超时 15 s、读取超时 60 s；调用方可用 `timeoutMs` 追加整体上限，
 *   到时会 `destroy()` 客户端并返回 `timeout`；
 * - 自动跟随重定向最多 5 次；初始 URL 已限定 scheme，重定向目标由
 *   NetworkKit 协议栈处理，非 http/https 目标会以 `2300001` 失败并归入
 *   `unsupported`；未被跟随的 3xx 归入 `redirect_limit`；
 * - 请求头只发送调用方提供的 `User-Agent`（默认 `clash-verge/v2.4.5`，经安全归一）；
 *   **不发送任何认证头、Cookie 或设备标识头**，因此跨域重定向没有认证头可携带；
 * - 只把 2xx 视为成功；接收上限设 9 MiB（8 MiB 正文 + 1 MiB 守卫），
 *   取回后正文超过 8 MiB 返回 `too_large`，0 字节返回 `network`；
 * - 正文只写入调用方提供的临时文件（CREATE | TRUNC | WRITE_ONLY），写完
 *   尽力 `fsync` 并关闭；失败时尽力删除该临时文件，返回后不保留句柄、
 *   正文或全局引用；
 * - 同一 profile 同时只允许一个拉取，全局最多 2 个；重复或超限立即返回 `busy`；
 * - 错误结果只带 `status`、`bytes`、`errorCode` 和经 `ClashRedaction.redactUrl`
 *   处理的 `hostSummary`，不包含完整 URL、查询参数、正文、请求头或响应头；
 * - 本模块不输出日志，也不读取异常 `message`。
 *
 * 未覆盖项：
 * - 响应头白名单（`content-disposition` 等）由上层另行处理，本任务只交付正文文件；
 * - 临时文件的目录存在性、最终原子替换、权限校验由调用方和
 *   `ClashProfileStore` 负责。
 */

import { http } from '@kit.NetworkKit';
import { fileIo } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import { redactUrl } from '../../model/ClashRedaction';
import { isValidProfileId } from '../../model/ClashProfileRules';
import { DEFAULT_SUBSCRIPTION_UA, normalizeSubscriptionUserAgent } from './ClashProfileStore';
import {
  MAX_SUBSCRIPTION_BODY_BYTES,
  UrlValidationResult,
  validateUrl
} from '../../model/ClashSubscriptionParser';

// ---------------------------------------------------------------------------
// 常量
// ---------------------------------------------------------------------------

/** 设计 §10.2：与上游一致的连接超时。 */
const CONNECT_TIMEOUT_MS: number = 15000;
/** 设计 §10.2：与上游一致的读取超时。 */
const READ_TIMEOUT_MS: number = 60000;
/** 未显式传入 `timeoutMs` 时的整体上限；覆盖连接 + 读取并留出余量。 */
const DEFAULT_TOTAL_TIMEOUT_MS: number = 120000;
const MIN_TOTAL_TIMEOUT_MS: number = 1000;
const MAX_TOTAL_TIMEOUT_MS: number = 600000;
/** 设计 §10.2：自动跟随上限。 */
const MAX_REDIRECTS: number = 5;
/** 设计 §10.2：同一 profile 单飞、全局并发上限。 */
const MAX_GLOBAL_CONCURRENT: number = 2;
/** 接收上限余量：让 8 MiB 的业务边界由本模块判定，而不是被传输层截断。 */
const CONTENT_LIMIT_GUARD_BYTES: number = 1048576;
/** 调用方提供的临时文件路径上限；只接受应用沙箱绝对路径。 */
const MAX_TARGET_PATH_LENGTH: number = 1024;
/** 临时文件路径中不允许的控制字符。 */
const CONTROL_CHARACTER_PATTERN: RegExp = /[\u0000-\u001F\u007F-\u009F]/;
/** OHOS HTTP 错误码；只读取 `code`，不读取 `message`。 */
const ERROR_UNSUPPORTED_PROTOCOL: number = 2300001;
const ERROR_INVALID_URL: number = 2300003;
const ERROR_WRITE_TO_DISK: number = 2300023;
const ERROR_OPERATION_TIMEOUT: number = 2300028;
const ERROR_TOO_MANY_REDIRECTS: number = 2300047;
const ERROR_MAXIMUM_FILE_SIZE: number = 2300063;

// ---------------------------------------------------------------------------
// 公开类型
// ---------------------------------------------------------------------------

/**
 * 拉取失败的稳定细分码。
 *
 * - `invalid_url` / `unsupported`：URL 校验失败；
 * - `invalid_profile` / `invalid_target`：调用参数不合法；
 * - `busy`：同一 profile 已在拉取，或全局并发已达上限；
 * - `too_large`：正文超过 8 MiB；
 * - `timeout`：连接/读取/整体超时；
 * - `redirect_limit`：重定向次数超限，或 3xx 未被自动跟随；
 * - `http_status`：服务器返回非 2xx；
 * - `network`：DNS、连接、TLS、响应为空等传输失败；
 * - `write_failed`：临时文件打开或写入失败；
 * - `internal`：未归类的内部失败。
 */
export type FetchErrorCode =
  | 'invalid_url'
  | 'invalid_profile'
  | 'invalid_target'
  | 'unsupported'
  | 'busy'
  | 'too_large'
  | 'timeout'
  | 'redirect_limit'
  | 'http_status'
  | 'network'
  | 'write_failed'
  | 'internal';

/**
 * 一次受控拉取的显式结果。
 *
 * - `status`：HTTP 状态码；未拿到响应时为 0；
 * - `bytes`：本次接收的字节数；失败时为失败前已确认的数量；
 * - `errorCode`：仅失败时存在；
 * - `hostSummary`：仅失败时存在，形如 `https://example.com` 或
 *   `https://example.com:8443`，由 `redactUrl` 去掉 userinfo、路径、查询与片段。
 */
export interface FetchResult {
  ok: boolean;
  status: number;
  bytes: number;
  errorCode?: FetchErrorCode;
  hostSummary?: string;
}

// ---------------------------------------------------------------------------
// 模块级状态
// ---------------------------------------------------------------------------

/**
 * 在途 profile 集合。ArkTS 单线程执行，`has` 与 `add` 之间没有 await，
 * 因此检查与占用是原子的。集合只保存调用方传入的 profile id，不含 URL。
 */
const inFlightProfiles: Set<string> = new Set<string>();

// ---------------------------------------------------------------------------
// 结果构造与参数校验
// ---------------------------------------------------------------------------

function buildFailure(errorCode: FetchErrorCode, status: number, bytes: number,
  hostSummary: string): FetchResult {
  return {
    ok: false,
    status: status,
    bytes: bytes,
    errorCode: errorCode,
    hostSummary: hostSummary
  };
}

function buildSuccess(status: number, bytes: number): FetchResult {
  return {
    ok: true,
    status: status,
    bytes: bytes
  };
}

/** 调用方传入的整体超时：未提供时取默认值，0 表示只依赖连接/读取超时。 */
function effectiveTotalTimeout(timeoutMs: number | undefined): number {
  if (timeoutMs === undefined) {
    return DEFAULT_TOTAL_TIMEOUT_MS;
  }
  if (!Number.isFinite(timeoutMs)) {
    return DEFAULT_TOTAL_TIMEOUT_MS;
  }
  if (timeoutMs <= 0) {
    return 0;
  }
  const rounded: number = Math.floor(timeoutMs);
  return Math.min(MAX_TOTAL_TIMEOUT_MS, Math.max(MIN_TOTAL_TIMEOUT_MS, rounded));
}

/**
 * 临时文件必须是应用沙箱内的绝对路径。
 * 本模块不创建目录，也不接受相对路径、反斜杠、控制字符或 `..` 段。
 */
function isSafeTargetPath(path: string): boolean {
  if (typeof path !== 'string' || path.length < 2 || path.length > MAX_TARGET_PATH_LENGTH) {
    return false;
  }
  if (!path.startsWith('/') || path.endsWith('/')) {
    return false;
  }
  if (path.indexOf('\\') >= 0 || CONTROL_CHARACTER_PATTERN.test(path)) {
    return false;
  }
  const segments: string[] = path.split('/');
  for (let index: number = 0; index < segments.length; index++) {
    if (segments[index] === '.' || segments[index] === '..') {
      return false;
    }
  }
  return true;
}

/**
 * 请求头只使用调用方提供的 UA；未提供或值不安全时回退默认 `clash-verge/v2.4.5`。
 * 归一由 `ClashProfileStore` 的同一函数完成，保证不出现 CR/LF 或控制字符。
 */
function userAgent(value: string | undefined): string {
  return normalizeSubscriptionUserAgent(value === undefined ? DEFAULT_SUBSCRIPTION_UA : value);
}

interface FetchRequest {
  url: string;
  profileId: string;
  targetPath: string;
  totalTimeoutMs: number;
  hostSummary: string;
  userAgent: string;
}

interface PreparedFetch {
  ok: boolean;
  request?: FetchRequest;
  errorCode?: FetchErrorCode;
  hostSummary: string;
}

/**
 * 同步校验全部入参。任何失败都转成固定错误码，不回显原始输入。
 * `redactUrl` 在入口只计算一次，后续错误共用同一个摘要。
 */
function prepareFetch(url: string, profileId: string, targetPath: string,
  timeoutMs: number | undefined, userAgentValue: string | undefined): PreparedFetch {
  const hostSummary: string = redactUrl(url);
  const validation: UrlValidationResult = validateUrl(url);
  if (!validation.ok) {
    const code: FetchErrorCode = validation.code === 'unsupported' ? 'unsupported' : 'invalid_url';
    return { ok: false, errorCode: code, hostSummary: hostSummary };
  }
  if (!isValidProfileId(profileId)) {
    return { ok: false, errorCode: 'invalid_profile', hostSummary: hostSummary };
  }
  if (!isSafeTargetPath(targetPath)) {
    return { ok: false, errorCode: 'invalid_target', hostSummary: hostSummary };
  }
  const request: FetchRequest = {
    url: url,
    profileId: profileId,
    targetPath: targetPath,
    totalTimeoutMs: effectiveTotalTimeout(timeoutMs),
    hostSummary: hostSummary,
    userAgent: userAgent(userAgentValue)
  };
  return { ok: true, request: request, hostSummary: hostSummary };
}

// ---------------------------------------------------------------------------
// 资源收尾
// ---------------------------------------------------------------------------

async function closeQuietly(file: fileIo.File): Promise<void> {
  try {
    await fileIo.close(file);
  } catch (_) {
  }
}

/** 失败时删除临时文件；删除失败不覆盖原始错误。 */
async function removeQuietly(path: string): Promise<void> {
  try {
    await fileIo.unlink(path);
  } catch (_) {
  }
}

// ---------------------------------------------------------------------------
// 网络错误映射
// ---------------------------------------------------------------------------

/**
 * 只按 `code` 分类；`message` 可能包含完整 URL，绝不读取。
 * 未列出的传输错误统一归入 `network`，保持上层可重试语义。
 */
function mapNetworkError(error: BusinessError): FetchErrorCode {
  if (error === undefined || error === null) {
    return 'network';
  }
  const code: number = Number.isFinite(error.code) ? Math.floor(error.code) : 0;
  if (code === ERROR_OPERATION_TIMEOUT) {
    return 'timeout';
  }
  if (code === ERROR_TOO_MANY_REDIRECTS) {
    return 'redirect_limit';
  }
  if (code === ERROR_MAXIMUM_FILE_SIZE) {
    return 'too_large';
  }
  if (code === ERROR_UNSUPPORTED_PROTOCOL) {
    return 'unsupported';
  }
  if (code === ERROR_INVALID_URL) {
    return 'invalid_url';
  }
  if (code === ERROR_WRITE_TO_DISK) {
    return 'write_failed';
  }
  return 'network';
}

// ---------------------------------------------------------------------------
// 一次性请求
// ---------------------------------------------------------------------------

/** 一次非流式请求的落定结果：只会是响应、超时或映射后的错误码之一。 */
interface NetworkOutcome {
  timedOut: boolean;
  response?: http.HttpResponse;
  errorCode?: FetchErrorCode;
}

/**
 * 只发送 UA。没有 Authorization、Cookie 或设备标识头，跨域重定向因此
 * 没有认证头可携带；不使用缓存，避免命中上次响应。
 * `maxLimit` 预留 1 MiB 余量，8 MiB 的业务边界仍由本模块判定。
 */
function buildRequestOptions(request: FetchRequest): http.HttpRequestOptions {
  const headers: Record<string, string> = {
    'User-Agent': request.userAgent
  };
  const options: http.HttpRequestOptions = {
    method: http.RequestMethod.GET,
    header: headers,
    expectDataType: http.HttpDataType.ARRAY_BUFFER,
    connectTimeout: CONNECT_TIMEOUT_MS,
    readTimeout: READ_TIMEOUT_MS,
    usingCache: false,
    maxRedirects: MAX_REDIRECTS,
    maxLimit: MAX_SUBSCRIPTION_BODY_BYTES + CONTENT_LIMIT_GUARD_BYTES
  };
  return options;
}

/**
 * 发起一次请求并在整体超时到来时销毁客户端。
 *
 * `request` 只会落定一次：响应、传输错误、同步抛错或超时先到者生效，
 * 之后 `destroy()` 触发的失败不会覆盖已落定结果；所有路径都会清理 timer。
 */
function performRequest(client: http.HttpRequest,
  request: FetchRequest): Promise<NetworkOutcome> {
  return new Promise<NetworkOutcome>((resolve: (value: NetworkOutcome) => void): void => {
    let settled: boolean = false;
    let timer: number = -1;

    const settle = (outcome: NetworkOutcome): void => {
      if (settled) {
        return;
      }
      settled = true;
      if (timer >= 0) {
        clearTimeout(timer);
        timer = -1;
      }
      resolve(outcome);
    };

    if (request.totalTimeoutMs > 0) {
      timer = setTimeout((): void => {
        if (settled) {
          return;
        }
        const timedOut: NetworkOutcome = { timedOut: true };
        // 先落定 timeout，再 destroy，避免销毁产生的错误改写语义。
        settle(timedOut);
        try {
          client.destroy();
        } catch (_) {
        }
      }, request.totalTimeoutMs);
    }

    let work: Promise<http.HttpResponse>;
    try {
      work = client.request(request.url, buildRequestOptions(request));
    } catch (error) {
      const failed: NetworkOutcome = {
        timedOut: false,
        errorCode: mapNetworkError(error as BusinessError)
      };
      settle(failed);
      return;
    }

    work.then((response: http.HttpResponse): void => {
      const done: NetworkOutcome = { timedOut: false, response: response };
      settle(done);
    }).catch((error: Error): void => {
      const failed: NetworkOutcome = {
        timedOut: false,
        errorCode: mapNetworkError(error as BusinessError)
      };
      settle(failed);
    });
  });
}

// ---------------------------------------------------------------------------
// 响应处理与写盘
// ---------------------------------------------------------------------------

/** 状态码统一成整数；异常值按 0 处理，仍会走非 2xx 分支。 */
function normalizeStatus(code: http.ResponseCode | number): number {
  // 数值枚举需显式转成 number，避免依赖隐式枚举赋值。
  const numeric: number = Number(code);
  if (!Number.isFinite(numeric)) {
    return 0;
  }
  return Math.floor(numeric);
}

/**
 * 统一成字节视图：`ARRAY_BUFFER` 直接使用；个别实现返回字符串时按 UTF-8
 * 编码；其余对象类型无法安全转换为字节，返回 `undefined` 由调用方归入
 * `internal`。
 */
function toBytePayload(result: string | Object | ArrayBuffer): ArrayBuffer | undefined {
  if (result instanceof ArrayBuffer) {
    return result;
  }
  if (typeof result === 'string') {
    const encoded: Uint8Array = new util.TextEncoder().encodeInto(result);
    const bytes: ArrayBuffer = new ArrayBuffer(encoded.byteLength);
    new Uint8Array(bytes).set(encoded);
    return bytes;
  }
  return undefined;
}

/**
 * 把正文写入调用方提供的临时文件：CREATE | TRUNC | WRITE_ONLY，循环写直到
 * 写完，`fsync` 尽力而为，最后关闭。任何失败都关闭并尽力删除，返回
 * `write_failed`。
 */
async function writeBody(body: ArrayBuffer, targetPath: string): Promise<FetchErrorCode | undefined> {
  let file: fileIo.File;
  try {
    file = await fileIo.open(targetPath,
      fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC | fileIo.OpenMode.WRITE_ONLY);
  } catch (_) {
    return 'write_failed';
  }

  let failed: boolean = false;
  try {
    let offset: number = 0;
    while (offset < body.byteLength) {
      const part: ArrayBuffer = offset === 0 ? body : body.slice(offset);
      const count: number = await fileIo.write(file.fd, part);
      if (!Number.isFinite(count) || count <= 0) {
        failed = true;
        break;
      }
      offset += Math.floor(count);
    }
    if (!failed) {
      // fsync 尽力而为：持久性失败不应把已成功接收的正文变成失败。
      try {
        await fileIo.fsync(file.fd);
      } catch (_) {
      }
    }
  } catch (_) {
    failed = true;
  }

  await closeQuietly(file);
  if (failed) {
    await removeQuietly(targetPath);
    return 'write_failed';
  }
  return undefined;
}

/**
 * 校验状态码与正文大小，然后落盘。
 *
 * - 3xx 说明重定向未被自动跟随，归入 `redirect_limit`；
 * - 其他非 2xx 归入 `http_status`；
 * - 正文为空归入 `network`（服务器或链路没有给出有效内容）；
 * - 超过 8 MiB 归入 `too_large`，客户端在返回前销毁。
 */
async function handleResponse(response: http.HttpResponse,
  request: FetchRequest): Promise<FetchResult> {
  const status: number = normalizeStatus(response.responseCode);
  if (status >= 300 && status < 400) {
    return buildFailure('redirect_limit', status, 0, request.hostSummary);
  }
  if (status < 200 || status >= 300) {
    return buildFailure('http_status', status, 0, request.hostSummary);
  }

  const payload: ArrayBuffer | undefined = toBytePayload(response.result);
  if (payload === undefined) {
    return buildFailure('internal', status, 0, request.hostSummary);
  }
  const size: number = payload.byteLength;
  if (size <= 0) {
    return buildFailure('network', status, 0, request.hostSummary);
  }
  if (size > MAX_SUBSCRIPTION_BODY_BYTES) {
    return buildFailure('too_large', status, size, request.hostSummary);
  }

  const writeCode: FetchErrorCode | undefined = await writeBody(payload, request.targetPath);
  if (writeCode !== undefined) {
    return buildFailure(writeCode, status, size, request.hostSummary);
  }
  return buildSuccess(status, size);
}

async function executeFetch(request: FetchRequest): Promise<FetchResult> {
  let client: http.HttpRequest;
  try {
    client = http.createHttp();
  } catch (_) {
    return buildFailure('internal', 0, 0, request.hostSummary);
  }

  try {
    const outcome: NetworkOutcome = await performRequest(client, request);
    if (outcome.timedOut) {
      return buildFailure('timeout', 0, 0, request.hostSummary);
    }
    if (outcome.errorCode !== undefined) {
      return buildFailure(outcome.errorCode, 0, 0, request.hostSummary);
    }
    const response: http.HttpResponse | undefined = outcome.response;
    if (response === undefined) {
      return buildFailure('internal', 0, 0, request.hostSummary);
    }
    return await handleResponse(response, request);
  } catch (_) {
    // 兜底：确保结果稳定，不把异常抛给调用方。
    return buildFailure('internal', 0, 0, request.hostSummary);
  } finally {
    // 请求结束即释放底层资源；超时路径已销毁过一次，重复销毁无害。
    try {
      client.destroy();
    } catch (_) {
    }
  }
}

// ---------------------------------------------------------------------------
// 入口
// ---------------------------------------------------------------------------

/**
 * 把订阅正文拉取到调用方提供的临时文件。
 *
 * 本函数不抛出未捕获异常：参数错误、文件错误、网络错误和内部错误都转成
 * `FetchResult`。并发限制在发起请求之前检查，被拒绝的调用不会触碰磁盘。
 *
 * @param url 订阅地址；仅接受 http/https。
 * @param profileId 已通过 `ClashProfileRules` 校验的 profile id，用于单飞。
 * @param targetPath 应用沙箱内的绝对临时文件路径；目录需由调用方创建。
 * @param timeoutMs 可选的整次拉取上限；0 表示只依赖连接/读取超时。
 * @param userAgentValue 可选的 User-Agent；未提供或非法时回退默认 `clash-verge/v2.4.5`。
 */
export function fetchToFile(url: string, profileId: string, targetPath: string,
  timeoutMs?: number, userAgentValue?: string): Promise<FetchResult> {
  try {
    const prepared: PreparedFetch =
      prepareFetch(url, profileId, targetPath, timeoutMs, userAgentValue);
    const hostSummary: string = prepared.hostSummary;
    if (!prepared.ok || prepared.request === undefined) {
      return Promise.resolve(buildFailure(
        prepared.errorCode !== undefined ? prepared.errorCode : 'internal',
        0, 0, hostSummary));
    }
    const request: FetchRequest = prepared.request;
    if (inFlightProfiles.has(request.profileId) ||
      inFlightProfiles.size >= MAX_GLOBAL_CONCURRENT) {
      return Promise.resolve(buildFailure('busy', 0, 0, request.hostSummary));
    }

    inFlightProfiles.add(request.profileId);
    return executeFetch(request).then((result: FetchResult): FetchResult => {
      inFlightProfiles.delete(request.profileId);
      return result;
    }, (): FetchResult => {
      inFlightProfiles.delete(request.profileId);
      return buildFailure('internal', 0, 0, request.hostSummary);
    });
  } catch (_) {
    return Promise.resolve(buildFailure('internal', 0, 0, 'invalid-url'));
  }
}