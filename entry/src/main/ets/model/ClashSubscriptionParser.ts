/**
 * 订阅边界纯逻辑（任务 T-S1-07，设计 §10.2-§10.3）。
 *
 * 职责只有四件事：
 * 1. 判断订阅 URL 是否可发起请求（scheme、长度、字符、userinfo）；
 * 2. 从白名单响应头读取名称、流量与建议更新周期；
 * 3. 对已下载正文做字节级边界检查并解码为 UTF-8 文本；
 * 4. 给出显示名回退候选与 base64 订阅提示。
 *
 * 约束：
 * - 纯 TypeScript，不引用 HarmonyOS Kit，不发起请求、不读时钟、不写文件；
 * - 只依赖 `./ClashModels` 的类型、`./ClashRedaction` 的 URL/主机校验和
 *   `./ClashProfileRules` 的显示名清洗；
 * - 不依赖平台文本解码器、Node 缓冲区或 base64 快捷函数：UTF-8 校验与解码在本文件内完成；
 * - 顶层错误码只使用 `ClashError` 已有的 `config_invalid` / `unsupported`；
 *   `detailCode` 是边界细分原因，不回显任何用户输入；
 * - 不记录、不保存完整 URL、token、查询参数或响应正文。
 */

import { SubscriptionInfo } from './ClashModels';
import { redactHost } from './ClashRedaction';
import { sanitizeDisplayName } from './ClashProfileRules';

/** 订阅 URL 最大长度（UTF-16 单元，与设计 §10.2 一致）。 */
export const MAX_SUBSCRIPTION_URL_LENGTH: number = 2048;

/** 订阅正文最大字节数：8 MiB（8,388,608 字节），含 BOM。 */
export const MAX_SUBSCRIPTION_BODY_BYTES: number = 8388608;

/** `ClashRedaction.redactHost` 对非法主机返回的固定摘要。 */
const INVALID_HOST_SUMMARY: string = 'invalid-host';

const HEADER_CONTENT_DISPOSITION: string = 'content-disposition';
const HEADER_SUBSCRIPTION_USERINFO: string = 'subscription-userinfo';
const HEADER_PROFILE_UPDATE_INTERVAL: string = 'profile-update-interval';

const URL_SCHEME_PATTERN: RegExp = /^([A-Za-z][A-Za-z0-9+.-]*):\/\//;
/** 空白（含全角空格）与 C0/C1 控制字符：URL 中一律拒绝。 */
const WHITESPACE_OR_CONTROL_PATTERN: RegExp = /[\s\u0000-\u001F\u007F-\u009F]/;
const DIGITS_PATTERN: RegExp = /^\d+$/;

/** `filename*=` 的 RFC 5987 扩展值；优先于普通 `filename=`。 */
const FILENAME_EXTENDED_PATTERN: RegExp = /filename\*\s*=\s*(?:"([^"]*)"|([^;]*))/i;
const FILENAME_PLAIN_PATTERN: RegExp = /(?:^|;)\s*filename\s*=\s*(?:"([^"]*)"|([^;]*))/i;

const MAX_SAFE_INTEGER_VALUE: number = 9007199254740991;
const MAX_PORT: number = 65535;
const UTF8_CHUNK_LENGTH: number = 4096;

const UTF8_BOM_0: number = 0xEF;
const UTF8_BOM_1: number = 0xBB;
const UTF8_BOM_2: number = 0xBF;

/** 空白压缩后至少 64 个 base64 字符才提示；避免把短标识误判为订阅。 */
const MIN_BASE64_CANDIDATE_LENGTH: number = 64;

/** userinfo 的固定提示；不拼接原始 URL 或账号。 */
const USERINFO_HINT: string = '请移除 URL 中的账号信息';

/** 常见二进制文件魔数；命中即按「明显二进制」拒绝，不尝试解码。 */
const BINARY_SIGNATURES: number[][] = [
  [0x1F, 0x8B],
  [0x50, 0x4B, 0x03, 0x04],
  [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A],
  [0xFF, 0xD8, 0xFF],
  [0x25, 0x50, 0x44, 0x46],
  [0x7F, 0x45, 0x4C, 0x46],
  [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07],
  [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C],
  [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]
];

/**
 * URL 拒绝原因。只描述边界，不包含原始输入：
 * - empty：空串
 * - too_long：超过 2048 个 UTF-16 单元
 * - invalid_characters：含空白或控制字符
 * - invalid_scheme：不是 http/https
 * - userinfo：authority 中出现 `@`（含 `user:pass@`）
 * - invalid_url：缺主机、端口非法、路径分隔符异常或整体结构不合法
 */
export type UrlRejectReason =
  | 'empty'
  | 'too_long'
  | 'invalid_characters'
  | 'invalid_scheme'
  | 'userinfo'
  | 'invalid_url';

/** URL 校验结果：成功时 code 为空串，失败时使用 ClashError 已有码。 */
export interface UrlValidationResult {
  ok: boolean;
  /** 空串表示通过；失败时为 `config_invalid` 或 `unsupported`。 */
  code: 'config_invalid' | 'unsupported' | '';
  /** 细分原因，仅用于本地文案映射。 */
  detailCode?: UrlRejectReason;
  /** 仅当 URL 通过且 scheme 为 http 时为 true。 */
  plaintextWarning: boolean;
  /** 固定提示；目前仅 userinfo 场景提供。 */
  hint?: string;
}

/** 正文拒绝原因：体积、二进制特征或 UTF-8 编码问题。 */
export type BodyRejectReason = 'too_large' | 'binary_rejected' | 'encoding_rejected';

/** 正文检查结果：成功时 text 为去掉 BOM 的 UTF-8 文本。 */
export interface BodyCheckResult {
  ok: boolean;
  /** 合法文本；失败时为空串，不保留已解码的部分内容。 */
  text: string;
  /** 空串表示通过；失败时固定为 `config_invalid`。 */
  code: 'config_invalid' | '';
  detailCode?: BodyRejectReason;
}

/**
 * 响应头白名单解析结果。
 * 只读 `content-disposition`、`subscription-userinfo`、`profile-update-interval`；
 * `flclashx-*` 与其他头一律忽略。
 */
export interface ParsedResponseHeaders {
  /** `content-disposition` 中提取并解码的文件名（已去目录部分）；缺失时省略。 */
  disposition?: string;
  /** 建议更新周期（小时）；非正数或非法值省略，不参与自动更新。 */
  updateIntervalHours?: number;
  /** 流量/到期信息；只有至少一个合法字段时存在。 */
  subscriptionInfo?: SubscriptionInfo;
}

/** 构造 URL 失败结果；固定错误码，不拼接任何输入。 */
function buildUrlRejection(
  reason: UrlRejectReason,
  code: 'config_invalid' | 'unsupported',
  hint?: string
): UrlValidationResult {
  if (hint !== undefined) {
    return { ok: false, code: code, detailCode: reason, plaintextWarning: false, hint: hint };
  }
  return { ok: false, code: code, detailCode: reason, plaintextWarning: false };
}

/** 端口为空或为 1..65535 的十进制整数。 */
function isValidPort(port: string): boolean {
  if (port.length === 0) {
    return true;
  }
  if (port.length > 5 || !DIGITS_PATTERN.test(port)) {
    return false;
  }
  const numeric: number = Number(port);
  return Number.isInteger(numeric) && numeric >= 1 && numeric <= MAX_PORT;
}

/** authority 结束位置：路径、查询或片段之前。 */
function findAuthorityEnd(remainder: string): number {
  let end: number = remainder.length;
  const stops: string[] = ['/', '?', '#'];
  for (let index: number = 0; index < stops.length; index++) {
    const found: number = remainder.indexOf(stops[index]);
    if (found >= 0 && found < end) {
      end = found;
    }
  }
  return end;
}

/**
 * 校验订阅 URL。
 *
 * - 仅接受 `http://` / `https://`，scheme 大小写不敏感；
 * - 长度不超过 2048 个 UTF-16 单元；
 * - 任意空白或控制字符直接拒绝；
 * - authority 中出现 `@` 即视为 userinfo，返回「请移除 URL 中的账号信息」；
 * - 主机必须能通过 `redactHost` 的语法校验，端口必须是 1..65535；
 * - `http` 通过时 `plaintextWarning=true`，由 UI 提示明文传输。
 */
export function validateUrl(url: string): UrlValidationResult {
  if (typeof url !== 'string' || url.length === 0) {
    return buildUrlRejection('empty', 'config_invalid');
  }
  if (url.length > MAX_SUBSCRIPTION_URL_LENGTH) {
    return buildUrlRejection('too_long', 'config_invalid');
  }
  if (WHITESPACE_OR_CONTROL_PATTERN.test(url)) {
    return buildUrlRejection('invalid_characters', 'config_invalid');
  }
  // 反斜杠在不同解析器中的归一化行为不一致，订阅地址不保留该写法。
  if (url.indexOf('\\') >= 0) {
    return buildUrlRejection('invalid_url', 'config_invalid');
  }
  const schemeMatch: RegExpExecArray | null = URL_SCHEME_PATTERN.exec(url);
  if (schemeMatch === null) {
    return buildUrlRejection('invalid_url', 'config_invalid');
  }
  const scheme: string = schemeMatch[1].toLowerCase();
  if (scheme !== 'http' && scheme !== 'https') {
    return buildUrlRejection('invalid_scheme', 'unsupported');
  }
  const remainder: string = url.slice(schemeMatch[0].length);
  const authority: string = remainder.slice(0, findAuthorityEnd(remainder));
  if (authority.length === 0) {
    return buildUrlRejection('invalid_url', 'config_invalid');
  }
  if (authority.indexOf('@') >= 0) {
    return buildUrlRejection('userinfo', 'config_invalid', USERINFO_HINT);
  }

  let host: string = authority;
  let port: string = '';
  if (authority.startsWith('[')) {
    const close: number = authority.indexOf(']');
    if (close < 0) {
      return buildUrlRejection('invalid_url', 'config_invalid');
    }
    host = authority.slice(0, close + 1);
    const rest: string = authority.slice(close + 1);
    if (rest.length > 0) {
      if (!rest.startsWith(':')) {
        return buildUrlRejection('invalid_url', 'config_invalid');
      }
      port = rest.slice(1);
      if (port.length === 0) {
        return buildUrlRejection('invalid_url', 'config_invalid');
      }
    }
  } else {
    const colon: number = authority.lastIndexOf(':');
    if (colon >= 0) {
      if (authority.indexOf(':') !== colon) {
        // 未加方括号的 IPv6 不是合法 URL authority。
        return buildUrlRejection('invalid_url', 'config_invalid');
      }
      host = authority.slice(0, colon);
      port = authority.slice(colon + 1);
      if (port.length === 0) {
        return buildUrlRejection('invalid_url', 'config_invalid');
      }
    }
  }

  if (host.length === 0 || redactHost(host) === INVALID_HOST_SUMMARY) {
    return buildUrlRejection('invalid_url', 'config_invalid');
  }
  if (!isValidPort(port)) {
    return buildUrlRejection('invalid_url', 'config_invalid');
  }

  return {
    ok: true,
    code: '',
    plaintextWarning: scheme === 'http'
  };
}

/** 大小写不敏感地读取白名单头；值只做 trim，不改写内容。 */
function findHeader(headers: Record<string, string>, name: string): string {
  if (!headers || typeof headers !== 'object') {
    return '';
  }
  const keys: string[] = Object.keys(headers);
  for (let index: number = 0; index < keys.length; index++) {
    const key: string = keys[index];
    if (typeof key !== 'string' || key.toLowerCase() !== name) {
      continue;
    }
    const value: string = headers[key];
    if (typeof value !== 'string') {
      return '';
    }
    return value.trim();
  }
  return '';
}

/** 只接受十进制非负整数；小数、符号、空串和超安全整数一律忽略。 */
function parseNonNegativeInteger(raw: string): number | undefined {
  const text: string = raw.trim();
  if (text.length === 0 || text.length > 16) {
    return undefined;
  }
  if (!DIGITS_PATTERN.test(text)) {
    return undefined;
  }
  const value: number = Number(text);
  if (!Number.isInteger(value) || value < 0 || value > MAX_SAFE_INTEGER_VALUE) {
    return undefined;
  }
  return value;
}

/** 十六进制字符值；非法返回 -1。 */
function hexValue(code: number): number {
  if (code >= 0x30 && code <= 0x39) {
    return code - 0x30;
  }
  if (code >= 0x41 && code <= 0x46) {
    return code - 0x41 + 10;
  }
  if (code >= 0x61 && code <= 0x66) {
    return code - 0x61 + 10;
  }
  return -1;
}

/** 将 RFC 5987 的 `filename*` 值解码为 UTF-8 文本；失败返回 null。 */
function decodePercentEncodedUtf8(value: string): string | null {
  let output: string = '';
  let index: number = 0;
  while (index < value.length) {
    const code: number = value.charCodeAt(index);
    if (code !== 0x25) {
      output += value.charAt(index);
      index++;
      continue;
    }
    // 连续收集 %HH 字节，交给 UTF-8 解码器一次处理多字节字符。
    const bytes: number[] = [];
    while (index + 2 < value.length && value.charCodeAt(index) === 0x25) {
      const high: number = hexValue(value.charCodeAt(index + 1));
      const low: number = hexValue(value.charCodeAt(index + 2));
      if (high < 0 || low < 0) {
        break;
      }
      const decoded: number = high * 16 + low;
      bytes.push(decoded);
      index += 3;
    }
    if (bytes.length === 0) {
      output += '%';
      index++;
      continue;
    }
    const chunk: Uint8Array = new Uint8Array(bytes.length);
    for (let offset: number = 0; offset < bytes.length; offset++) {
      chunk[offset] = bytes[offset];
    }
    const decodedText: string | null = decodeUtf8(chunk, 0);
    if (decodedText === null) {
      return null;
    }
    output += decodedText;
  }
  return output;
}

/** 去掉目录部分；`.`、`..` 与空结果返回空串。 */
function stripPathComponent(value: string): string {
  let text: string = value.trim();
  let cut: number = text.lastIndexOf('/');
  const backward: number = text.lastIndexOf('\\');
  if (backward > cut) {
    cut = backward;
  }
  if (cut >= 0) {
    text = text.slice(cut + 1);
  }
  text = text.trim();
  if (text === '.' || text === '..') {
    return '';
  }
  return text;
}

/** 去掉 filename 值两侧可能残留的引号。 */
function unquoteFilename(value: string): string {
  let text: string = value.trim();
  if (text.length >= 2 && text.startsWith('"') && text.endsWith('"')) {
    text = text.slice(1, text.length - 1);
  }
  return text;
}

/** 解析 `filename*=UTF-8''...` 的编码与语言前缀。 */
function decodeExtendedFilename(value: string): string {
  let text: string = unquoteFilename(value);
  const first: number = text.indexOf("'");
  if (first >= 0) {
    const second: number = text.indexOf("'", first + 1);
    if (second > first) {
      text = text.slice(second + 1);
    }
  }
  const decoded: string | null = decodePercentEncodedUtf8(text);
  return decoded !== null ? decoded : unquoteFilename(value);
}

/** 判断文本是否像 `inline`/`attachment` 形式的原始响应头。 */
function looksLikeDispositionHeader(value: string): boolean {
  const lower: string = value.toLowerCase();
  const separator: number = lower.indexOf(';');
  const headerType: string = (separator >= 0 ? lower.slice(0, separator) : lower).trim();
  if (headerType === 'inline' || headerType === 'attachment') {
    return true;
  }
  return lower.indexOf('filename=') >= 0 || lower.indexOf('filename*=') >= 0;
}

/**
 * 从 `content-disposition` 提取文件名。
 * 支持 `filename*=`（优先）与 `filename=` 的带引号/不带引号形式；
 * 去目录部分后返回，缺失或非法时返回空串。
 */
function extractDispositionFileName(disposition: string): string {
  if (typeof disposition !== 'string') {
    return '';
  }
  const text: string = disposition.trim();
  if (text.length === 0) {
    return '';
  }
  const extended: RegExpExecArray | null = FILENAME_EXTENDED_PATTERN.exec(text);
  if (extended !== null) {
    const raw: string = extended[1] !== undefined ? extended[1] : extended[2];
    const name: string = stripPathComponent(decodeExtendedFilename(raw));
    if (name.length > 0) {
      return name;
    }
  }
  const plain: RegExpExecArray | null = FILENAME_PLAIN_PATTERN.exec(text);
  if (plain !== null) {
    const raw: string = plain[1] !== undefined ? plain[1] : plain[2];
    const name: string = stripPathComponent(unquoteFilename(raw));
    if (name.length > 0) {
      return name;
    }
  }
  return '';
}

/** 解析 `subscription-userinfo`；任何单项非法只跳过该项。 */
function parseSubscriptionUserInfo(raw: string): SubscriptionInfo | null {
  const info: SubscriptionInfo = {};
  let found: boolean = false;
  const parts: string[] = raw.split(';');
  for (let index: number = 0; index < parts.length; index++) {
    const part: string = parts[index].trim();
    if (part.length === 0) {
      continue;
    }
    const separator: number = part.indexOf('=');
    if (separator <= 0) {
      continue;
    }
    const key: string = part.slice(0, separator).trim().toLowerCase();
    const value: number | undefined = parseNonNegativeInteger(part.slice(separator + 1));
    if (value === undefined) {
      continue;
    }
    if (key === 'upload') {
      info.upload = value;
      found = true;
    } else if (key === 'download') {
      info.download = value;
      found = true;
    } else if (key === 'total') {
      info.total = value;
      found = true;
    } else if (key === 'expire') {
      info.expire = value;
      found = true;
    }
  }
  return found ? info : null;
}

/**
 * 解析白名单响应头。
 *
 * - 头名大小写不敏感，只读取三个白名单键；
 * - `content-disposition` 只取 filename，名称清洗交给 `deriveDisplayName`；
 * - `subscription-userinfo` 的 `upload/download/total/expire` 逐项解析，
 *   非法项单独忽略，不影响其他项；
 * - `profile-update-interval` 只接受非负整数，非法值省略；
 * - `flclashx-*` 与其他头不会被读取。
 */
export function parseResponseHeaders(headers: Record<string, string>): ParsedResponseHeaders {
  const result: ParsedResponseHeaders = {};
  if (!headers || typeof headers !== 'object') {
    return result;
  }
  const dispositionHeader: string = findHeader(headers, HEADER_CONTENT_DISPOSITION);
  if (dispositionHeader.length > 0) {
    const fileName: string = extractDispositionFileName(dispositionHeader);
    if (fileName.length > 0) {
      result.disposition = fileName;
    }
  }
  const userInfoHeader: string = findHeader(headers, HEADER_SUBSCRIPTION_USERINFO);
  if (userInfoHeader.length > 0) {
    const info: SubscriptionInfo | null = parseSubscriptionUserInfo(userInfoHeader);
    if (info !== null) {
      result.subscriptionInfo = info;
    }
  }
  const intervalHeader: string = findHeader(headers, HEADER_PROFILE_UPDATE_INTERVAL);
  if (intervalHeader.length > 0) {
    const interval: number | undefined = parseNonNegativeInteger(intervalHeader);
    if (interval !== undefined && interval > 0) {
      result.updateIntervalHours = interval;
    }
  }
  return result;
}

/** 读取 disposition 候选项；原始响应头先提取 filename，普通文件名去目录部分。 */
function readDispositionCandidate(value: string): string {
  if (typeof value !== 'string') {
    return '';
  }
  const text: string = value.trim();
  if (text.length === 0) {
    return '';
  }
  const extracted: string = extractDispositionFileName(text);
  if (extracted.length > 0) {
    return extracted;
  }
  if (looksLikeDispositionHeader(text)) {
    return '';
  }
  return stripPathComponent(text);
}

/** YAML 组名与域名摘要只做 trim；它们不是文件路径，保留原有分隔符。 */
function readPlainNameCandidate(value: string): string {
  if (typeof value !== 'string') {
    return '';
  }
  return value.trim();
}

/**
 * 按「content-disposition 文件名 → YAML 组名提示 → 域名摘要」回退，
 * 最后交给 `sanitizeDisplayName` 去控制字符、压缩空白并截断到 64 字符。
 *
 * 三个入参都允许为空；全部为空时得到「未命名配置」。第一个参数可以是
 * 已提取的文件名，也可以是原始 `content-disposition` 头。名称不参与路径构造。
 */
export function deriveDisplayName(disposition: string, yamlHint: string, urlHost: string): string {
  const candidates: string[] = [
    readDispositionCandidate(disposition),
    readPlainNameCandidate(yamlHint),
    readPlainNameCandidate(urlHost)
  ];
  for (let index: number = 0; index < candidates.length; index++) {
    const candidate: string = candidates[index];
    if (candidate.length > 0) {
      return sanitizeDisplayName(candidate);
    }
  }
  return sanitizeDisplayName('');
}

/** 判断字节序列在指定偏移处是否命中某个二进制魔数。 */
function matchesSignature(bytes: Uint8Array, start: number, signature: number[]): boolean {
  if (start + signature.length > bytes.length) {
    return false;
  }
  for (let index: number = 0; index < signature.length; index++) {
    if (bytes[start + index] !== signature[index]) {
      return false;
    }
  }
  return true;
}

/** 命中常见容器/压缩/图片/文档魔数即视为明显二进制。 */
function hasBinarySignature(bytes: Uint8Array, start: number): boolean {
  for (let index: number = 0; index < BINARY_SIGNATURES.length; index++) {
    if (matchesSignature(bytes, start, BINARY_SIGNATURES[index])) {
      return true;
    }
  }
  return false;
}

/**
 * NUL 或不可打印控制字节即视为二进制。
 * 允许 TAB、LF、FF、CR，拒绝其余 0x00-0x1F 与 DEL。
 */
function hasForbiddenControl(bytes: Uint8Array, start: number): boolean {
  for (let index: number = start; index < bytes.length; index++) {
    const value: number = bytes[index];
    if (value === 0x00) {
      return true;
    }
    if (value < 0x09) {
      return true;
    }
    if (value === 0x0B) {
      return true;
    }
    if (value >= 0x0E && value <= 0x1F) {
      return true;
    }
    if (value === 0x7F) {
      return true;
    }
  }
  return false;
}

/**
 * 严格 UTF-8 解码，只使用字节运算与 `String.fromCharCode`。
 * 拒绝过长编码、代理项、超出 U+10FFFF 的码点与截断序列；失败返回 null。
 */
function decodeUtf8(bytes: Uint8Array, start: number): string | null {
  const chunks: string[] = [];
  let chunk: string = '';
  let index: number = start;
  while (index < bytes.length) {
    const first: number = bytes[index];
    if (first < 0x80) {
      chunk += String.fromCharCode(first);
      index++;
    } else if (first >= 0xC2 && first <= 0xDF) {
      if (index + 1 >= bytes.length) {
        return null;
      }
      const second: number = bytes[index + 1];
      if ((second & 0xC0) !== 0x80) {
        return null;
      }
      const code: number = ((first & 0x1F) << 6) | (second & 0x3F);
      chunk += String.fromCharCode(code);
      index += 2;
    } else if (first >= 0xE0 && first <= 0xEF) {
      if (index + 2 >= bytes.length) {
        return null;
      }
      const second: number = bytes[index + 1];
      const third: number = bytes[index + 2];
      if ((third & 0xC0) !== 0x80) {
        return null;
      }
      if (first === 0xE0) {
        if (second < 0xA0 || second > 0xBF) {
          return null;
        }
      } else if (first === 0xED) {
        // 排除 UTF-8 代理项 U+D800..U+DFFF。
        if (second < 0x80 || second > 0x9F) {
          return null;
        }
      } else if (second < 0x80 || second > 0xBF) {
        return null;
      }
      const code: number = ((first & 0x0F) << 12) |
        ((second & 0x3F) << 6) |
        (third & 0x3F);
      chunk += String.fromCharCode(code);
      index += 3;
    } else if (first >= 0xF0 && first <= 0xF4) {
      if (index + 3 >= bytes.length) {
        return null;
      }
      const second: number = bytes[index + 1];
      const third: number = bytes[index + 2];
      const fourth: number = bytes[index + 3];
      if ((third & 0xC0) !== 0x80 || (fourth & 0xC0) !== 0x80) {
        return null;
      }
      if (first === 0xF0) {
        if (second < 0x90 || second > 0xBF) {
          return null;
        }
      } else if (first === 0xF4) {
        // 上限 U+10FFFF。
        if (second < 0x80 || second > 0x8F) {
          return null;
        }
      } else if (second < 0x80 || second > 0xBF) {
        return null;
      }
      const code: number = ((first & 0x07) << 18) |
        ((second & 0x3F) << 12) |
        ((third & 0x3F) << 6) |
        (fourth & 0x3F);
      const adjusted: number = code - 0x10000;
      const high: number = 0xD800 + (adjusted >> 10);
      const low: number = 0xDC00 + (adjusted & 0x3FF);
      chunk += String.fromCharCode(high, low);
      index += 4;
    } else {
      return null;
    }
    if (chunk.length >= UTF8_CHUNK_LENGTH) {
      chunks.push(chunk);
      chunk = '';
    }
  }
  chunks.push(chunk);
  return chunks.join('');
}

/**
 * 检查订阅正文边界。
 *
 * - 原始字节数超过 8 MiB（含 BOM）→ `too_large`；
 * - 去掉开头的 UTF-8 BOM（EF BB BF）；
 * - NUL、明显控制字节或常见二进制魔数 → `binary_rejected`；
 * - 非法 UTF-8 → `encoding_rejected`；
 * - 通过时返回去掉 BOM 的文本，不保留原始字节。
 *
 * 顶层错误码固定为 `config_invalid`，细分原因放在 `detailCode`。
 * HTML 登录页属于合法文本，这里不拦截；是否可作配置由 `validateConfig` 判定。
 */
export function checkBody(bytes: Uint8Array): BodyCheckResult {
  if (!bytes) {
    return { ok: false, text: '', code: 'config_invalid', detailCode: 'encoding_rejected' };
  }
  if (bytes.length > MAX_SUBSCRIPTION_BODY_BYTES) {
    return { ok: false, text: '', code: 'config_invalid', detailCode: 'too_large' };
  }
  let start: number = 0;
  if (bytes.length >= 3 &&
    bytes[0] === UTF8_BOM_0 &&
    bytes[1] === UTF8_BOM_1 &&
    bytes[2] === UTF8_BOM_2) {
    start = 3;
  }
  if (hasBinarySignature(bytes, start) || hasForbiddenControl(bytes, start)) {
    return { ok: false, text: '', code: 'config_invalid', detailCode: 'binary_rejected' };
  }
  const text: string | null = decodeUtf8(bytes, start);
  if (text === null) {
    return { ok: false, text: '', code: 'config_invalid', detailCode: 'encoding_rejected' };
  }
  return { ok: true, text: text, code: '' };
}

/**
 * 判断正文是否像 base64 订阅（仅提示「暂不支持该订阅格式」，不解码）。
 *
 * 规则：忽略常见 ASCII 空白后，至少 64 个字符，只含标准 base64 字母表，
 * 可有一个或两个尾部 `=` 且填充后长度为 4 的倍数；未填充长度不得为 4n+1。
 * 同时要求出现字母与（数字或 `+`/`/`），降低把长标识误判为订阅的概率。
 * 返回 true 时调用方应提示「暂不支持该订阅格式」并映射 `unsupported`。
 */
export function looksLikeBase64Subscription(text: string): boolean {
  if (typeof text !== 'string') {
    return false;
  }
  let length: number = 0;
  let padding: number = 0;
  let hasLetter: boolean = false;
  let hasDigitOrSymbol: boolean = false;
  let paddingStarted: boolean = false;
  for (let index: number = 0; index < text.length; index++) {
    const code: number = text.charCodeAt(index);
    if (code === 0x20 || code === 0x09 || code === 0x0A || code === 0x0C || code === 0x0D) {
      continue;
    }
    if (code === 0x3D) {
      padding++;
      paddingStarted = true;
      if (padding > 2) {
        return false;
      }
      continue;
    }
    if (paddingStarted) {
      return false;
    }
    const upper: boolean = code >= 0x41 && code <= 0x5A;
    const lower: boolean = code >= 0x61 && code <= 0x7A;
    const digit: boolean = code >= 0x30 && code <= 0x39;
    const symbol: boolean = code === 0x2B || code === 0x2F;
    if (!upper && !lower && !digit && !symbol) {
      return false;
    }
    length++;
    if (upper || lower) {
      hasLetter = true;
    }
    if (digit || symbol) {
      hasDigitOrSymbol = true;
    }
  }
  const total: number = length + padding;
  if (total < MIN_BASE64_CANDIDATE_LENGTH) {
    return false;
  }
  if (length % 4 === 1) {
    return false;
  }
  if (padding > 0 && total % 4 !== 0) {
    return false;
  }
  return hasLetter && hasDigitOrSymbol;
}