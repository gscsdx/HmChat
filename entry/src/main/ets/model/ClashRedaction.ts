/**
 * Unified redaction shared by proxy logs, diagnostics, error summaries and
 * public assets (task T-S1-05, design §8.6).
 *
 * Rules:
 * - A failure path never echoes the original input.
 * - `redactUrl` collapses a URL to `scheme://<host summary>[:port]`; userinfo,
 *   path, query and fragment are always dropped.
 * - `redactHost` keeps only the last two labels of a domain name and only the
 *   leading groups of an IP literal.
 * - `hashName` turns node/group names into a stable `n-<8hex>` digest.
 * - `safeError` exposes a code and an optional detail code only; `message`,
 *   response body, URL and file path are never read.
 *
 * This file is pure TypeScript (no Kit imports) so host tests can run it.
 */

export interface ProxyErrorLike {
  code: string;
  detailCode?: string;
}

const INVALID_URL: string = 'invalid-url';
const INVALID_HOST: string = 'invalid-host';
const UNKNOWN_CODE: string = 'unknown';
const EMPTY_NAME_HASH: string = 'n-empty';

const MAX_INPUT_LENGTH: number = 8192;
const MAX_HOST_LENGTH: number = 253;
const MAX_LABEL_LENGTH: number = 63;
const MAX_CODE_LENGTH: number = 32;
const MAX_PORT: number = 65535;

const URL_SCHEME_PATTERN: RegExp = /^([A-Za-z][A-Za-z0-9+.-]{0,31}):\/\//;
const CONTROL_PATTERN: RegExp = /[\u0000-\u001F\u007F]/;
const WHITESPACE_PATTERN: RegExp = /\s/;
const HOST_LABEL_PATTERN: RegExp = /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/;
const NUMERIC_ONLY_PATTERN: RegExp = /^[0-9.]+$/;
const IPV4_PATTERN: RegExp = /^\d{1,3}(?:\.\d{1,3}){3}$/;
const IPV6_CHARS_PATTERN: RegExp = /^[0-9a-f:]+$/;
const IPV6_GROUP_PATTERN: RegExp = /^[0-9a-f]{1,4}$/;
const CODE_PATTERN: RegExp = /^[a-z][a-z0-9_.-]{0,31}$/;
/** Credential shapes (UUID, long hex token) must never travel through a code field. */
const HEX_TOKEN_PATTERN: RegExp = /^(?:[0-9a-f]{16,}|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$/;
const DIGITS_PATTERN: RegExp = /^\d+$/;

/** Width of the authority section: everything before a path, query or fragment. */
function findAuthorityEnd(remainder: string): number {
  let end: number = remainder.length;
  const stops: string[] = ['/', '?', '#', '\\'];
  for (let index: number = 0; index < stops.length; index++) {
    const found: number = remainder.indexOf(stops[index]);
    if (found >= 0 && found < end) {
      end = found;
    }
  }
  return end;
}

function isHighSurrogate(value: number): boolean {
  return value >= 0xD800 && value <= 0xDBFF;
}

function isLowSurrogate(value: number): boolean {
  return value >= 0xDC00 && value <= 0xDFFF;
}

/** Full Unicode code point at `index`, or -1 when out of range. */
function codePointAt(value: string, index: number): number {
  if (index < 0 || index >= value.length) {
    return -1;
  }
  const first: number = value.charCodeAt(index);
  if (isHighSurrogate(first) && index + 1 < value.length) {
    const second: number = value.charCodeAt(index + 1);
    if (isLowSurrogate(second)) {
      return ((first - 0xD800) * 0x400) + (second - 0xDC00) + 0x10000;
    }
  }
  return first;
}

/** Full Unicode code point of the last character, or -1 for an empty string. */
function lastCodePoint(value: string): number {
  if (value.length === 0) {
    return -1;
  }
  return codePointAt(value, value.length - (isLowSurrogate(value.charCodeAt(value.length - 1)) ? 2 : 1));
}

/** Remove one complete code point; never leaves half of a surrogate pair behind. */
function dropLastCodePoint(value: string): string {
  if (value.length === 0) {
    return value;
  }
  const last: number = value.charCodeAt(value.length - 1);
  if (isLowSurrogate(last) && value.length >= 2 && isHighSurrogate(value.charCodeAt(value.length - 2))) {
    return value.slice(0, value.length - 2);
  }
  return value.slice(0, value.length - 1);
}

/** Emoji continuation code points: ZWJ, variation selectors, skin tones, keycap, tags. */
function isEmojiContinuation(value: number): boolean {
  if (value === 0x200D || value === 0xFE0E || value === 0xFE0F || value === 0x20E3) {
    return true;
  }
  if (value >= 0x1F3FB && value <= 0x1F3FF) {
    return true;
  }
  return value >= 0xE0020 && value <= 0xE007F;
}

function isRegionalIndicator(value: number): boolean {
  return value >= 0x1F1E6 && value <= 0x1F1FF;
}

function sanitizePort(value: string): string {
  if (value.length === 0 || value.length > 5 || !DIGITS_PATTERN.test(value)) {
    return '';
  }
  const numeric: number = Number(value);
  if (!Number.isInteger(numeric) || numeric < 1 || numeric > MAX_PORT) {
    return '';
  }
  return String(numeric);
}

function redactIpv4(host: string): string {
  const parts: string[] = host.split('.');
  const octets: string[] = [];
  for (let index: number = 0; index < parts.length; index++) {
    const numeric: number = Number(parts[index]);
    if (!Number.isInteger(numeric) || numeric < 0 || numeric > 255) {
      return INVALID_HOST;
    }
    octets.push(String(numeric));
  }
  return octets[0] + '.' + octets[1] + '.*.*';
}

function redactIpv6(host: string): string {
  if (host.length === 0 || host.indexOf(':') < 0 || !IPV6_CHARS_PATTERN.test(host)) {
    return INVALID_HOST;
  }
  const firstDouble: number = host.indexOf('::');
  if (firstDouble >= 0 && host.indexOf('::', firstDouble + 2) >= 0) {
    return INVALID_HOST;
  }
  const groups: string[] = host.split(':');
  let named: number = 0;
  for (let index: number = 0; index < groups.length; index++) {
    const group: string = groups[index];
    if (group.length === 0) {
      continue;
    }
    if (!IPV6_GROUP_PATTERN.test(group)) {
      return INVALID_HOST;
    }
    named++;
  }
  if (firstDouble >= 0) {
    if (named > 7) {
      return INVALID_HOST;
    }
  } else if (groups.length !== 8) {
    return INVALID_HOST;
  }
  const first: string = groups.length > 0 ? groups[0] : '';
  const second: string = groups.length > 1 ? groups[1] : '';
  return first + ':' + second + ':*';
}

function redactDomain(host: string): string {
  const labels: string[] = host.split('.');
  for (let index: number = 0; index < labels.length; index++) {
    const label: string = labels[index];
    if (label.length === 0 || label.length > MAX_LABEL_LENGTH) {
      return INVALID_HOST;
    }
    if (!HOST_LABEL_PATTERN.test(label)) {
      return INVALID_HOST;
    }
  }
  if (labels.length === 1) {
    return labels[0];
  }
  // Keep only the last two labels: `sub.example.invalid` -> `example.invalid`.
  return labels[labels.length - 2] + '.' + labels[labels.length - 1];
}

/**
 * Reduce a host to a non-identifying summary.
 *
 * - `sub.example.invalid` -> `example.invalid`
 * - `192.0.2.10` -> `192.0.*.*`
 * - `2001:db8:85a3::8a2e` -> `2001:db8:*`
 * - malformed input -> `invalid-host` (the original is never echoed)
 */
export function redactHost(input: string): string {
  if (typeof input !== 'string') {
    return INVALID_HOST;
  }
  let host: string = input.trim().toLowerCase();
  if (host.length === 0 || host.length > MAX_HOST_LENGTH) {
    return INVALID_HOST;
  }
  if (CONTROL_PATTERN.test(host) || WHITESPACE_PATTERN.test(host)) {
    return INVALID_HOST;
  }
  if (host.startsWith('[')) {
    if (!host.endsWith(']') || host.length < 3) {
      return INVALID_HOST;
    }
    host = host.slice(1, host.length - 1);
    return redactIpv6(host);
  }
  while (host.endsWith('.')) {
    host = host.slice(0, host.length - 1);
  }
  if (host.length === 0) {
    return INVALID_HOST;
  }
  if (host.indexOf(':') >= 0) {
    return redactIpv6(host);
  }
  if (IPV4_PATTERN.test(host)) {
    return redactIpv4(host);
  }
  // Numeric fragments such as `192.0.2` or `999.1.1.1` are not domains.
  if (NUMERIC_ONLY_PATTERN.test(host)) {
    return INVALID_HOST;
  }
  return redactDomain(host);
}

/**
 * Collapse a URL to `scheme://<host summary>[:port]`.
 *
 * Userinfo (`user:pass@`), path, query and fragment are always dropped, so a
 * subscription token cannot survive anywhere in the output.
 * `https://user:pass@sub.example.invalid:8443/api/v1?token=x#frag`
 * -> `https://example.invalid:8443`
 *
 * Malformed input returns `invalid-url`; the original text is never echoed.
 */
export function redactUrl(input: string): string {
  if (typeof input !== 'string') {
    return INVALID_URL;
  }
  const text: string = input.trim();
  if (text.length === 0 || text.length > MAX_INPUT_LENGTH) {
    return INVALID_URL;
  }
  if (CONTROL_PATTERN.test(text) || WHITESPACE_PATTERN.test(text)) {
    return INVALID_URL;
  }
  const schemeMatch: RegExpExecArray | null = URL_SCHEME_PATTERN.exec(text);
  if (schemeMatch === null) {
    return INVALID_URL;
  }
  const scheme: string = schemeMatch[1].toLowerCase();
  const remainder: string = text.slice(schemeMatch[0].length);
  const authority: string = remainder.slice(0, findAuthorityEnd(remainder));
  if (authority.length === 0) {
    return INVALID_URL;
  }
  const at: number = authority.lastIndexOf('@');
  const hostPort: string = at >= 0 ? authority.slice(at + 1) : authority;
  if (hostPort.length === 0) {
    return INVALID_URL;
  }
  let host: string = hostPort;
  let port: string = '';
  if (hostPort.startsWith('[')) {
    const close: number = hostPort.indexOf(']');
    if (close < 0) {
      return INVALID_URL;
    }
    host = hostPort.slice(0, close + 1);
    const rest: string = hostPort.slice(close + 1);
    if (rest.length > 0) {
      if (!rest.startsWith(':')) {
        return INVALID_URL;
      }
      port = rest.slice(1);
    }
  } else {
    const colon: number = hostPort.lastIndexOf(':');
    if (colon >= 0) {
      if (hostPort.indexOf(':') !== colon) {
        // Unbracketed IPv6 literals are not valid URLs.
        return INVALID_URL;
      }
      host = hostPort.slice(0, colon);
      port = hostPort.slice(colon + 1);
    }
  }
  const hostSummary: string = redactHost(host);
  if (hostSummary === INVALID_HOST) {
    return INVALID_URL;
  }
  const safePort: string = sanitizePort(port);
  const hostText: string = hostSummary.indexOf(':') >= 0 ? '[' + hostSummary + ']' : hostSummary;
  return scheme + '://' + hostText + (safePort.length > 0 ? ':' + safePort : '');
}

/**
 * Stable FNV-1a 32-bit digest of a node or group name: `n-<8hex>`.
 * The same input always yields the same output; no random salt is used.
 * Empty or missing input returns `n-empty`.
 */
export function hashName(input: string): string {
  if (typeof input !== 'string') {
    return EMPTY_NAME_HASH;
  }
  const text: string = input.trim();
  if (text.length === 0) {
    return EMPTY_NAME_HASH;
  }
  let hash: number = 0x811C9DC5;
  for (let index: number = 0; index < text.length; index++) {
    hash = Math.imul(hash ^ text.charCodeAt(index), 0x01000193) >>> 0;
  }
  let hex: string = hash.toString(16);
  while (hex.length < 8) {
    hex = '0' + hex;
  }
  return 'n-' + hex;
}

/**
 * Cut text to at most `max` UTF-16 units without splitting a surrogate pair or
 * an emoji cluster. Callers must redact before truncating; use
 * `redactAndTruncateUrl` when a URL is involved.
 */
export function truncate(text: string, max: number): string {
  if (typeof text !== 'string' || text.length === 0) {
    return '';
  }
  if (!Number.isFinite(max)) {
    return '';
  }
  const limit: number = Math.floor(max);
  if (limit <= 0) {
    return '';
  }
  if (text.length <= limit) {
    return text;
  }
  let cut: string = text.slice(0, limit);
  let guard: number = 0;
  while (cut.length > 0 && guard < 8) {
    guard++;
    // A trailing high surrogate means the cut landed inside a surrogate pair.
    if (isHighSurrogate(cut.charCodeAt(cut.length - 1))) {
      cut = cut.slice(0, cut.length - 1);
      continue;
    }
    const last: number = lastCodePoint(cut);
    const next: number = codePointAt(text, cut.length);
    if (isEmojiContinuation(last) || isEmojiContinuation(next)) {
      cut = dropLastCodePoint(cut);
      continue;
    }
    break;
  }
  // A dangling regional indicator would render as a lone letter, not a flag.
  let flag: string = cut;
  let indicators: number = 0;
  while (flag.length > 0 && indicators < 2 && isRegionalIndicator(lastCodePoint(flag))) {
    indicators++;
    flag = dropLastCodePoint(flag);
  }
  if (indicators === 1) {
    cut = flag;
  }
  return cut;
}

/**
 * Redact first, truncate second. `invalid-url` is kept intact so callers can
 * still recognise a malformed input.
 */
export function redactAndTruncateUrl(input: string, max: number): string {
  const redacted: string = redactUrl(input);
  if (redacted === INVALID_URL) {
    return INVALID_URL;
  }
  return truncate(redacted, max);
}

interface ErrorFields {
  code?: string | number;
  errorCode?: string;
  detailCode?: string;
  status?: number;
  statusCode?: number;
  name?: string;
}

function normalizeCode(value: string | undefined): string {
  if (typeof value !== 'string') {
    return '';
  }
  const text: string = value.trim().toLowerCase();
  if (text.length === 0 || text.length > MAX_CODE_LENGTH) {
    return '';
  }
  if (!CODE_PATTERN.test(text)) {
    return '';
  }
  if (HEX_TOKEN_PATTERN.test(text)) {
    return '';
  }
  return text;
}

function numericCode(value: number): string {
  if (!Number.isFinite(value)) {
    return '';
  }
  const numeric: number = Math.floor(value);
  if (numeric < 0 || numeric > 999999) {
    return '';
  }
  if (numeric >= 100 && numeric <= 599) {
    return 'http_' + String(numeric);
  }
  return 'code_' + String(numeric);
}

function statusCode(value: number | undefined): string {
  if (typeof value !== 'number') {
    return '';
  }
  const numeric: number = Math.floor(value);
  if (numeric < 100 || numeric > 599) {
    return '';
  }
  return 'http_' + String(numeric);
}

/** Only standard JS error class names are surfaced; arbitrary `name` values are dropped. */
function knownErrorName(value: string | undefined): string {
  const name: string = normalizeCode(value);
  if (name === 'typeerror' || name === 'rangeerror' || name === 'syntaxerror' ||
    name === 'referenceerror' || name === 'evalerror' || name === 'urierror') {
    return name;
  }
  return '';
}

/**
 * Reduce an error to `{ code, detailCode? }`.
 *
 * Only `code`, `errorCode`, `detailCode`, `status`, `statusCode` and a known
 * error class `name` are read. `message`, `stack`, response body, URL and file
 * path are never copied, so nothing sensitive can leak through this function.
 */
export function safeError(error: object | string | null): ProxyErrorLike {
  if (error === null || error === undefined) {
    return { code: UNKNOWN_CODE };
  }
  if (typeof error === 'string') {
    const token: string = normalizeCode(error);
    return token.length > 0 ? { code: token } : { code: UNKNOWN_CODE };
  }
  const fields: ErrorFields = error as ErrorFields;
  let code: string = '';
  if (typeof fields.code === 'string') {
    code = normalizeCode(fields.code);
  } else if (typeof fields.code === 'number') {
    code = numericCode(fields.code);
  }
  if (code.length === 0) {
    code = statusCode(fields.status);
  }
  if (code.length === 0) {
    code = statusCode(fields.statusCode);
  }
  if (code.length === 0) {
    code = knownErrorName(fields.name);
  }
  if (code.length === 0) {
    code = UNKNOWN_CODE;
  }
  let detail: string = normalizeCode(fields.detailCode);
  if (detail.length === 0) {
    detail = normalizeCode(fields.errorCode);
  }
  if (detail.length > 0 && detail !== code) {
    return { code: code, detailCode: detail };
  }
  return { code: code };
}