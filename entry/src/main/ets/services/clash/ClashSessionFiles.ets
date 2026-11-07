/**
 * Session hand-off files between the UI process and the Clash VPN extension
 * (design §5.1, task T-S2-02).
 *
 * Layout: `<filesDir>/proxy/session/req-<nonce>.json` and
 * `<filesDir>/proxy/session/ack-<nonce>.json`. Every write goes to
 * `<name>.tmp` first, is flushed with `fsync`, and is then renamed over the
 * target, so a reader never observes a partially written file. The previous
 * target is unlinked before the rename because OHOS `rename` semantics are not
 * guaranteed to replace an existing file.
 *
 * POSIX mode note (SDK 26): `@kit.CoreFileKit` (`@ohos.file.fs`) exposes
 * `stat().mode` as read-only but provides no `chmod`/`mkdir(mode)` API, and the
 * deprecated `@ohos.fileio` module is intentionally not used (project rule:
 * CoreFileKit `fs` only). Files and directories created inside the app sandbox
 * are owned by the app UID and are not reachable by other applications, so this
 * module relies on the sandbox default (owner-only access) and verifies the
 * effective mode through `stat().mode & 0o777`; a mismatch is logged as a
 * category only. Permissions are never loosened here.
 *
 * Security: the nonce is validated against `^[a-f0-9]{32}$` before it becomes
 * part of a path, so `..`/separator traversal cannot happen. Tokens and nonces
 * never reach logs, Preferences or Asset. `readRequest`/`readAck` never throw:
 * every failure is returned as an explicit error code.
 */

import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';

/** Session hand-off protocol version written into req/ack files. */
export const SESSION_PROTO_VERSION: number = 1;
/** Default request lifetime; the UI sets this explicitly on every session. */
export const SESSION_REQUEST_TTL_MS: number = 15000;
/** Fixed port from older builds; permanently rejected (design §5.1). */
export const SESSION_LEGACY_PORT: number = 47471;

const MIN_TTL_MS: number = 1000;
const MAX_TTL_MS: number = 600000;
/** Tolerated clock difference between the UI and extension processes. */
const CLOCK_SKEW_MS: number = 5000;
/** Upper bound for a hand-off file; real payloads stay below 512 bytes. */
const MAX_FILE_BYTES: number = 4096;
/** An ack without a matching request (or this old) is stale. */
const ACK_MAX_AGE_MS: number = 60000;
/** A leftover temporary file older than this is stale. */
const TMP_MAX_AGE_MS: number = 60000;

const DIRECTORY_MODE: number = 0o700;
const FILE_MODE: number = 0o600;

const NONCE_PATTERN: RegExp = /^[a-f0-9]{32}$/;
const TOKEN_PATTERN: RegExp = /^[a-f0-9]{64}$/;
const BOOT_ID_PATTERN: RegExp = /^[a-f0-9]{16}$/;

const LOG_DOMAIN: number = 0x0000;
const LOG_TAG: string = 'HarlgramProxySession';

/** Request file payload (design §5.1). `token` is 32 random bytes as hex. */
export interface SessionRequest {
  proto: number;
  token: string;
  nonce: string;
  issuedAt: number;
  ttlMs: number;
}

/** Ack file payload; `errorCode` is present only for a failed bind. */
export interface SessionAck {
  port: number;
  pid: number;
  bootId: string;
  ready: boolean;
  errorCode?: string;
}

/**
 * Explicit failure codes returned by this module. `token_invalid`,
 * `path_rejected` and `rpc_auth_failed` are the hand-shake rejection codes from
 * the P0 contract; the remaining ones describe local file conditions.
 */
export type SessionFileErrorCode =
  | 'session_missing'
  | 'session_malformed'
  | 'token_invalid'
  | 'path_rejected'
  | 'rpc_auth_failed'
  | 'write_failed';

/** Result of `readRequest`: exactly one of `request`/`errorCode` is set. */
export interface SessionRequestResult {
  request?: SessionRequest;
  errorCode?: SessionFileErrorCode;
}

/** Result of `readAck`: exactly one of `ack`/`errorCode` is set. */
export interface SessionAckResult {
  ack?: SessionAck;
  errorCode?: SessionFileErrorCode;
}

/** Result of a write; `errorCode` is set when `ok` is false. */
export interface SessionWriteResult {
  ok: boolean;
  errorCode?: SessionFileErrorCode;
}

/** Counts of removed files, never names, nonces or tokens. */
export interface SessionCleanupSummary {
  requests: number;
  acks: number;
  temporaries: number;
  failures: number;
}

/** Ack file on disk; `proto` is written but optional when reading older files. */
interface AckWire {
  proto?: number;
  port: number;
  pid: number;
  bootId: string;
  ready: boolean;
  errorCode?: string;
}

interface SessionEntryName {
  kind: 'req' | 'ack' | 'temporary';
  nonce: string;
}

type CleanupEntryKind = 'request' | 'ack' | 'temporary' | 'other';

/**
 * Owns every read/write/cleanup operation for one application sandbox.
 *
 * Construct once per files directory (UI ability context `filesDir` or the VPN
 * extension context `filesDir`; both point at the same sandbox for the same
 * bundle). Methods are safe to call when the directory does not exist yet.
 */
export class ClashSessionFiles {
  private readonly sessionDir: string;
  private directoryModeChecked: boolean = false;

  constructor(filesDir: string) {
    const root: string = normalizeRoot(filesDir);
    this.sessionDir = root.length === 0 ? '' : root + '/proxy/session';
  }

  /** Absolute session directory, for diagnostics only (never sent to Wants). */
  directory(): string {
    return this.sessionDir;
  }

  /**
   * Reads and validates `req-<nonce>.json`.
   *
   * Rejection order: nonce/path shape -> missing -> malformed JSON -> filename
   * nonce mismatch (`path_rejected`) -> token shape (`token_invalid`) ->
   * protocol/expiry (`rpc_auth_failed`). Invalid files are deleted, matching
   * design §5.1 rule 3 (the extension deletes and rejects bad requests).
   */
  async readRequest(nonce: string, now: number = Date.now()): Promise<SessionRequestResult> {
    if (this.sessionDir.length === 0 || !NONCE_PATTERN.test(nonce)) {
      return { errorCode: 'path_rejected' };
    }
    const path: string = this.requestPath(nonce);
    if (!await this.exists(path)) {
      return { errorCode: 'session_missing' };
    }
    let text: string = '';
    try {
      text = await this.readSmallText(path);
    } catch (error) {
      await this.unlinkQuietly(path);
      logWarn('req', 'read_failed');
      return { errorCode: 'session_malformed' };
    }
    const request: SessionRequest | undefined = parseRequestValue(text);
    if (request === undefined) {
      await this.unlinkQuietly(path);
      return { errorCode: 'session_malformed' };
    }
    const current: number = Number.isSafeInteger(now) ? now : Date.now();
    const structureError: SessionFileErrorCode | undefined = requestStructureError(request, nonce);
    if (structureError !== undefined) {
      await this.unlinkQuietly(path);
      return { errorCode: structureError };
    }
    const timeError: SessionFileErrorCode | undefined = requestTimeError(request, current);
    if (timeError !== undefined) {
      await this.unlinkQuietly(path);
      return { errorCode: timeError };
    }
    return { request: request };
  }

  /**
   * Atomically writes `req-<nonce>.json`.
   *
   * The caller generates `nonce`/`token` and sets `issuedAt`/`ttlMs`; this
   * method only validates their shape and never extends the lifetime.
   */
  async writeRequest(nonce: string, request: SessionRequest): Promise<SessionWriteResult> {
    if (this.sessionDir.length === 0 || !NONCE_PATTERN.test(nonce)) {
      return { ok: false, errorCode: 'path_rejected' };
    }
    const structureError: SessionFileErrorCode | undefined = requestStructureError(request, nonce);
    if (structureError !== undefined) {
      return { ok: false, errorCode: structureError };
    }
    // Write exactly the contract fields; never persist caller extras.
    const wire: SessionRequest = {
      proto: request.proto,
      token: request.token,
      nonce: request.nonce,
      issuedAt: request.issuedAt,
      ttlMs: request.ttlMs
    };
    return this.writeAtomic(requestFileName(nonce), JSON.stringify(wire), 'req');
  }

  /**
   * Atomically writes `ack-<nonce>.json`.
   *
   * Bind failure callers pass `ready:false` and an `errorCode`; when the code is
   * missing it is normalized to `rpc_bind_failed` (design §5.1). A ready ack
   * must carry a system-assigned port in `[1024, 65535]` that is not the
   * permanently disabled 47471, a positive pid and a 16-hex boot id.
   */
  async writeAck(nonce: string, ack: SessionAck): Promise<SessionWriteResult> {
    if (this.sessionDir.length === 0 || !NONCE_PATTERN.test(nonce)) {
      return { ok: false, errorCode: 'path_rejected' };
    }
    const normalized: SessionAck = normalizeAck(ack);
    const structureError: SessionFileErrorCode | undefined = ackStructureError({
      port: normalized.port,
      pid: normalized.pid,
      bootId: normalized.bootId,
      ready: normalized.ready,
      errorCode: normalized.errorCode
    });
    if (structureError !== undefined) {
      return { ok: false, errorCode: structureError };
    }
    if (!await this.exists(this.requestPath(nonce))) {
      return { ok: false, errorCode: 'session_missing' };
    }
    const wire: AckWire = {
      proto: SESSION_PROTO_VERSION,
      port: normalized.port,
      pid: normalized.pid,
      bootId: normalized.bootId,
      ready: normalized.ready
    };
    if (!normalized.ready && normalized.errorCode !== undefined) {
      wire.errorCode = normalized.errorCode;
    }
    return this.writeAtomic(ackFileName(nonce), JSON.stringify(wire), 'ack');
  }

  /** Reads and validates `ack-<nonce>.json`; never throws. */
  async readAck(nonce: string): Promise<SessionAckResult> {
    if (this.sessionDir.length === 0 || !NONCE_PATTERN.test(nonce)) {
      return { errorCode: 'path_rejected' };
    }
    const path: string = this.ackPath(nonce);
    if (!await this.exists(path)) {
      return { errorCode: 'session_missing' };
    }
    let text: string = '';
    try {
      text = await this.readSmallText(path);
    } catch (error) {
      await this.unlinkQuietly(path);
      logWarn('ack', 'read_failed');
      return { errorCode: 'session_malformed' };
    }
    const wire: AckWire | undefined = parseAckValue(text);
    if (wire === undefined) {
      await this.unlinkQuietly(path);
      return { errorCode: 'session_malformed' };
    }
    const structureError: SessionFileErrorCode | undefined = ackStructureError(wire, wire.proto);
    if (structureError !== undefined) {
      await this.unlinkQuietly(path);
      return { errorCode: structureError };
    }
    const ack: SessionAck = {
      port: wire.port,
      pid: wire.pid,
      bootId: wire.bootId,
      ready: wire.ready
    };
    if (!wire.ready && wire.errorCode !== undefined) {
      ack.errorCode = wire.errorCode;
    }
    return { ack: ack };
  }

  /**
   * Removes every `req-*`, `ack-*` and matching `.tmp` file. Unknown names are
   * left untouched; only counts are returned and logged.
   */
  async cleanup(): Promise<SessionCleanupSummary> {
    const summary: SessionCleanupSummary = { requests: 0, acks: 0, temporaries: 0, failures: 0 };
    if (this.sessionDir.length === 0) {
      summary.failures = 1;
      return summary;
    }
    const names: string[] | undefined = await this.listNames();
    if (names === undefined) {
      summary.failures = 1;
      return summary;
    }
    for (let index: number = 0; index < names.length; index++) {
      const name: string = names[index];
      const kind: CleanupEntryKind = classifyCleanupEntry(name);
      if (kind === 'other') {
        continue;
      }
      const removed: boolean = await this.unlinkQuietly(this.sessionDir + '/' + name);
      if (!removed) {
        summary.failures++;
      } else if (kind === 'request') {
        summary.requests++;
      } else if (kind === 'ack') {
        summary.acks++;
      } else {
        summary.temporaries++;
      }
    }
    return summary;
  }

  /**
   * Removes stale entries only:
   * - requests that are malformed, expired or from the future beyond skew;
   * - acks with no matching request, or older than `ACK_MAX_AGE_MS`;
   * - temporary files older than `TMP_MAX_AGE_MS`.
   *
   * Request bodies are parsed for `issuedAt`/`ttlMs` only; the token is
   * validated for shape but never logged.
   */
  async cleanupStale(now: number = Date.now()): Promise<SessionCleanupSummary> {
    const summary: SessionCleanupSummary = { requests: 0, acks: 0, temporaries: 0, failures: 0 };
    if (this.sessionDir.length === 0) {
      summary.failures = 1;
      return summary;
    }
    const current: number = Number.isSafeInteger(now) ? now : Date.now();
    const names: string[] | undefined = await this.listNames();
    if (names === undefined) {
      summary.failures = 1;
      return summary;
    }
    for (let index: number = 0; index < names.length; index++) {
      const name: string = names[index];
      const entry: SessionEntryName | undefined = parseSessionEntry(name);
      if (entry === undefined) {
        continue;
      }
      const path: string = this.sessionDir + '/' + name;
      if (entry.kind === 'temporary') {
        if (await this.isOlderThan(path, current, TMP_MAX_AGE_MS)) {
          if (await this.unlinkQuietly(path)) {
            summary.temporaries++;
          } else {
            summary.failures++;
          }
        }
        continue;
      }
      if (entry.kind === 'req') {
        if (await this.requestIsStale(path, entry.nonce, current)) {
          if (await this.unlinkQuietly(path)) {
            summary.requests++;
          } else {
            summary.failures++;
          }
        }
        continue;
      }
      const orphan: boolean = !await this.requestExists(entry.nonce);
      const tooOld: boolean = await this.isOlderThan(path, current, ACK_MAX_AGE_MS);
      if (orphan || tooOld) {
        if (await this.unlinkQuietly(path)) {
          summary.acks++;
        } else {
          summary.failures++;
        }
      }
    }
    return summary;
  }

  private requestPath(nonce: string): string {
    return this.sessionDir + '/' + requestFileName(nonce);
  }

  private ackPath(nonce: string): string {
    return this.sessionDir + '/' + ackFileName(nonce);
  }

  private async writeAtomic(fileName: string, text: string, category: string): Promise<SessionWriteResult> {
    if (this.sessionDir.length === 0) {
      return { ok: false, errorCode: 'path_rejected' };
    }
    if (!await this.ensureDirectory()) {
      return { ok: false, errorCode: 'write_failed' };
    }
    const target: string = this.sessionDir + '/' + fileName;
    const temporary: string = target + '.tmp';
    try {
      // Design §5.1 rule 1: delete the old file before the rename.
      await this.unlinkQuietly(target);
      const file: fileIo.File = await fileIo.open(temporary,
        fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      try {
        const encoded: Uint8Array = new util.TextEncoder().encodeInto(text);
        const buffer: ArrayBuffer = encoded.buffer as ArrayBuffer;
        const length: number = encoded.length;
        let written: number = 0;
        while (written < length) {
          const count: number = await fileIo.write(file.fd, buffer.slice(written, length));
          if (count <= 0) {
            throw new Error('session_file_write_short');
          }
          written += count;
        }
        try {
          await fileIo.fsync(file.fd);
        } catch (error) {
          logWarn(category, 'fsync_failed');
        }
      } finally {
        try {
          await fileIo.close(file);
        } catch (error) {
          logWarn(category, 'close_failed');
        }
      }
      await this.replaceFile(temporary, target);
      await this.verifyFileMode(target, category);
      return { ok: true };
    } catch (error) {
      await this.unlinkQuietly(temporary);
      logWarn(category, 'write_failed');
      return { ok: false, errorCode: 'write_failed' };
    }
  }

  /** Renames over the target, retrying once after an explicit unlink. */
  private async replaceFile(temporary: string, target: string): Promise<void> {
    try {
      await fileIo.rename(temporary, target);
    } catch (error) {
      await this.unlinkQuietly(target);
      await fileIo.rename(temporary, target);
    }
  }

  private async ensureDirectory(): Promise<boolean> {
    if (this.sessionDir.length === 0) {
      return false;
    }
    try {
      if (!await fileIo.access(this.sessionDir)) {
        try {
          await fileIo.mkdir(this.sessionDir, true);
        } catch (error) {
          // A concurrent creator is fine as long as the directory now exists.
          if (!await fileIo.access(this.sessionDir)) {
            logWarn('session_dir', 'create_failed');
            return false;
          }
        }
      }
      if (!this.directoryModeChecked) {
        this.directoryModeChecked = true;
        const info: fileIo.Stat = await fileIo.stat(this.sessionDir);
        if (!info.isDirectory()) {
          logWarn('session_dir', 'not_directory');
          return false;
        }
        if ((info.mode & 0o777) !== DIRECTORY_MODE) {
          // Documented limitation: CoreFileKit has no chmod API on SDK 26.
          logWarn('session_dir', 'mode_mismatch');
        }
      }
      return true;
    } catch (error) {
      logWarn('session_dir', 'stat_failed');
      return false;
    }
  }

  private async verifyFileMode(path: string, category: string): Promise<void> {
    try {
      const info: fileIo.Stat = await fileIo.stat(path);
      if ((info.mode & 0o777) !== FILE_MODE) {
        // Documented limitation: CoreFileKit has no chmod API on SDK 26.
        logWarn(category, 'mode_mismatch');
      }
    } catch (error) {
      logWarn(category, 'stat_failed');
    }
  }

  /** Reads a hand-off file only when it is small enough to be one. */
  private async readSmallText(path: string): Promise<string> {
    const file: fileIo.File = await fileIo.open(path, fileIo.OpenMode.READ_ONLY);
    try {
      const info: fileIo.Stat = await fileIo.stat(file.fd);
      if (info.size > MAX_FILE_BYTES) {
        throw new Error('session_file_too_large');
      }
      if (info.size <= 0) {
        return '';
      }
      const buffer: ArrayBuffer = new ArrayBuffer(info.size);
      const count: number = await fileIo.read(file.fd, buffer);
      return new util.TextDecoder().decodeToString(new Uint8Array(buffer, 0, count));
    } finally {
      try {
        await fileIo.close(file);
      } catch (error) {
        logWarn('file', 'close_failed');
      }
    }
  }

  private async exists(path: string): Promise<boolean> {
    try {
      return await fileIo.access(path);
    } catch (error) {
      return false;
    }
  }

  private async unlinkQuietly(path: string): Promise<boolean> {
    try {
      await fileIo.unlink(path);
      return true;
    } catch (error) {
      return false;
    }
  }

  private async listNames(): Promise<string[] | undefined> {
    try {
      if (!await fileIo.access(this.sessionDir)) {
        return [];
      }
      return await fileIo.listFile(this.sessionDir);
    } catch (error) {
      logWarn('session_dir', 'list_failed');
      return undefined;
    }
  }

  private async requestIsStale(path: string, nonce: string, now: number): Promise<boolean> {
    let text: string = '';
    try {
      text = await this.readSmallText(path);
    } catch (error) {
      return true;
    }
    const request: SessionRequest | undefined = parseRequestValue(text);
    if (request === undefined) {
      return true;
    }
    if (requestStructureError(request, nonce) !== undefined) {
      return true;
    }
    return requestTimeError(request, now) !== undefined;
  }

  private async requestExists(nonce: string): Promise<boolean> {
    try {
      return await fileIo.access(this.requestPath(nonce));
    } catch (error) {
      // An unreadable directory is not proof of an orphan; keep the ack.
      return true;
    }
  }

  private async isOlderThan(path: string, now: number, maxAgeMs: number): Promise<boolean> {
    try {
      const info: fileIo.Stat = await fileIo.stat(path);
      return now - info.mtime * 1000 > maxAgeMs;
    } catch (error) {
      return false;
    }
  }
}

function requestFileName(nonce: string): string {
  return 'req-' + nonce + '.json';
}

function ackFileName(nonce: string): string {
  return 'ack-' + nonce + '.json';
}

function normalizeRoot(filesDir: string): string {
  let root: string = filesDir;
  while (root.length > 0 && (root.endsWith('/') || root.endsWith('\\'))) {
    root = root.substring(0, root.length - 1);
  }
  if (root.length === 0 || root.indexOf('\u0000') >= 0) {
    return '';
  }
  return root;
}

function requestStructureError(request: SessionRequest, nonce: string): SessionFileErrorCode | undefined {
  if (typeof request.proto !== 'number' || typeof request.token !== 'string' ||
    typeof request.nonce !== 'string' || typeof request.issuedAt !== 'number' ||
    typeof request.ttlMs !== 'number') {
    return 'session_malformed';
  }
  if (!NONCE_PATTERN.test(request.nonce) || request.nonce !== nonce) {
    return 'path_rejected';
  }
  if (!TOKEN_PATTERN.test(request.token)) {
    return 'token_invalid';
  }
  if (request.proto !== SESSION_PROTO_VERSION) {
    return 'rpc_auth_failed';
  }
  if (!Number.isSafeInteger(request.issuedAt) || request.issuedAt <= 0) {
    return 'session_malformed';
  }
  if (!Number.isSafeInteger(request.ttlMs) || request.ttlMs < MIN_TTL_MS || request.ttlMs > MAX_TTL_MS) {
    return 'session_malformed';
  }
  return undefined;
}

function requestTimeError(request: SessionRequest, now: number): SessionFileErrorCode | undefined {
  if (request.issuedAt > now + CLOCK_SKEW_MS) {
    return 'rpc_auth_failed';
  }
  if (now > request.issuedAt + request.ttlMs) {
    return 'rpc_auth_failed';
  }
  return undefined;
}

function normalizeAck(ack: SessionAck): SessionAck {
  if (!ack.ready && (ack.errorCode === undefined || ack.errorCode.length === 0)) {
    return { port: ack.port, pid: ack.pid, bootId: ack.bootId, ready: false, errorCode: 'rpc_bind_failed' };
  }
  return ack;
}

function ackStructureError(ack: AckWire, proto?: number): SessionFileErrorCode | undefined {
  if (typeof ack.ready !== 'boolean' || typeof ack.port !== 'number' ||
    typeof ack.pid !== 'number' || typeof ack.bootId !== 'string') {
    return 'session_malformed';
  }
  if (proto !== undefined && proto !== SESSION_PROTO_VERSION) {
    return 'session_malformed';
  }
  if (!Number.isSafeInteger(ack.port) || ack.port < 0 || ack.port > 65535) {
    return 'session_malformed';
  }
  if (!Number.isSafeInteger(ack.pid) || ack.pid <= 0) {
    return 'session_malformed';
  }
  if (!BOOT_ID_PATTERN.test(ack.bootId)) {
    return 'session_malformed';
  }
  if (ack.errorCode !== undefined && typeof ack.errorCode !== 'string') {
    return 'session_malformed';
  }
  if (ack.ready) {
    // Design §5.1: the port is system assigned and 47471 is never valid.
    if (ack.port < 1024 || ack.port === SESSION_LEGACY_PORT) {
      return 'session_malformed';
    }
  } else if (ack.errorCode === undefined || ack.errorCode.length === 0) {
    return 'session_malformed';
  }
  return undefined;
}

function parseRequestValue(text: string): SessionRequest | undefined {
  let parsed: object | null = null;
  try {
    parsed = JSON.parse(text) as object;
  } catch (error) {
    return undefined;
  }
  if (parsed === null) {
    return undefined;
  }
  return parsed as SessionRequest;
}

function parseAckValue(text: string): AckWire | undefined {
  let parsed: object | null = null;
  try {
    parsed = JSON.parse(text) as object;
  } catch (error) {
    return undefined;
  }
  if (parsed === null) {
    return undefined;
  }
  return parsed as AckWire;
}

function classifyCleanupEntry(name: string): CleanupEntryKind {
  const temporary: boolean = name.endsWith('.tmp');
  const base: string = temporary ? name.substring(0, name.length - 4) : name;
  if (!base.endsWith('.json')) {
    return 'other';
  }
  if (!base.startsWith('req-') && !base.startsWith('ack-')) {
    return 'other';
  }
  if (temporary) {
    return 'temporary';
  }
  return base.startsWith('req-') ? 'request' : 'ack';
}

function parseSessionEntry(name: string): SessionEntryName | undefined {
  let kind: 'req' | 'ack' = 'req';
  let rest: string = '';
  if (name.startsWith('req-')) {
    kind = 'req';
    rest = name.substring(4);
  } else if (name.startsWith('ack-')) {
    kind = 'ack';
    rest = name.substring(4);
  } else {
    return undefined;
  }
  let temporary: boolean = false;
  if (rest.endsWith('.tmp')) {
    temporary = true;
    rest = rest.substring(0, rest.length - 4);
  }
  if (!rest.endsWith('.json')) {
    return undefined;
  }
  const nonce: string = rest.substring(0, rest.length - 5);
  if (!NONCE_PATTERN.test(nonce)) {
    return undefined;
  }
  if (temporary) {
    return { kind: 'temporary', nonce: nonce };
  }
  return { kind: kind, nonce: nonce };
}

/** Logs a file category and a fixed code; never a nonce, token or path. */
function logWarn(category: string, code: string): void {
  hilog.warn(LOG_DOMAIN, LOG_TAG, 'session file %{public}s: %{public}s', category, code);
}