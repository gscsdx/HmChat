/**
 * Loopback RPC server owned by the Clash VPN extension (tasks T-S2-12/T-S2-13,
 * design §5.1-§5.5).
 *
 * The extension accepts exactly one client at a time in practice (the UI), but
 * the transport still enforces the full exposure limits because the loopback
 * port is reachable by every process running under the same user:
 *
 * - random loopback port, never the permanently disabled 47471;
 * - first frame must be `auth{token,nonce,proto}` within 5 s;
 * - ≤4 connections, ≤1 MiB per frame / pending buffer, per-connection and
 *   global token buckets, 30 s idle close, bounded pending requests;
 * - pushes only go to authenticated connections and are rebuilt from a field
 *   whitelist, so paths, URLs, tokens and domains cannot be forwarded.
 *
 * Security notes:
 * - The token is compared with a constant-time XOR accumulation. No secret
 *   value, request body or socket address is logged.
 * - `sessionId` is a fresh 16-hex value per authenticated connection and is not
 *   derived from the token.
 * - `req-<nonce>.json` is removed only after a successful authentication.
 *   `ClashSessionFiles` intentionally exposes no single-file delete, so the
 *   request path is rebuilt here after a strict nonce shape check.
 *
 * SDK 26 API note: `@kit.NetworkKit` TCPSocket exposes `close()` on listeners
 * and connections; there is no `destroy()`/`shutdown()` method for TCP server
 * sockets. Every socket is therefore tracked in `connections` and closed
 * explicitly on stop/rotation, which is the equivalent of the design's
 * "shutdown all sockets" requirement.
 *
 * Device verification status: see the task report. This module cannot be
 * exercised without a HarmonyOS process that can bind a socket and inject
 * handlers; host tests would only cover the pure limit helpers, which live in
 * this file but are not exported as a separate test target.
 */

import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { socket } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';

import {
  JsonPayload,
  RpcErrorBody,
  RpcPush,
  RpcPushChannel,
  RpcResponse
} from '../../model/ClashModels';
import {
  ClashSessionFiles,
  SESSION_LEGACY_PORT,
  SessionAck,
  SessionWriteResult
} from './ClashSessionFiles';
import {
  RPC_PROTO,
  RpcFramer,
  encodeRequest
} from './ClashRpcProtocolBridge';

// ---------------------------------------------------------------------------
// Exposure limits (exported so callers, tests and docs share one source)
// ---------------------------------------------------------------------------

/** Maximum concurrent connections; excess connections are closed, not queued. */
export const RPC_SERVER_MAX_CONNECTIONS: number = 4;
/** A connection must authenticate within this budget (design §5.3). */
export const RPC_SERVER_AUTH_TIMEOUT_MS: number = 5000;
/** A connection with no request/push activity for this long is closed. */
export const RPC_SERVER_IDLE_TIMEOUT_MS: number = 30000;
/** Per-connection request budget: sustained rate and burst capacity. */
export const RPC_SERVER_PER_CONNECTION_RATE: number = 50;
export const RPC_SERVER_PER_CONNECTION_BURST: number = 100;
/** Server-wide request budget. */
export const RPC_SERVER_GLOBAL_RATE: number = 200;
export const RPC_SERVER_GLOBAL_BURST: number = 200;
/** Consecutive rate-limit hits that terminate a connection. */
export const RPC_SERVER_RATE_VIOLATION_LIMIT: number = 3;
/** Pending request caps (per connection / server). */
export const RPC_SERVER_PENDING_PER_CLIENT: number = 256;
export const RPC_SERVER_PENDING_TOTAL: number = 512;
/** Bind attempts after the first failure and the delay between them. */
export const RPC_SERVER_BIND_RETRIES: number = 3;
export const RPC_SERVER_BIND_RETRY_DELAY_MS: number = 100;

const LOOPBACK_ADDRESS: string = '127.0.0.1';
const MIN_PORT: number = 1024;
const MAX_PORT: number = 65535;
/** Idle sweep granularity; the exact deadline is checked against each socket. */
const IDLE_SWEEP_INTERVAL_MS: number = 1000;
/** Upper bound for decoded frames handled from one transport chunk. */
const MAX_FRAMES_PER_CHUNK: number = 256;
/** Upper bound for flushing a final push before sockets are closed. */
const DRAIN_TIMEOUT_MS: number = 250;

const NONCE_PATTERN: RegExp = /^[a-f0-9]{32}$/;
const TOKEN_PATTERN: RegExp = /^[a-f0-9]{64}$/;
const BOOT_ID_PATTERN: RegExp = /^[a-f0-9]{16}$/;
/** Wire request id shape: `u-<session8>-<seq>` / `e-<session8>-<seq>`. */
const REQUEST_ID_PATTERN: RegExp = /^[A-Za-z0-9_.-]{1,64}$/;
/** Structured error/detail codes; never free-form text. */
const CODE_PATTERN: RegExp = /^[a-z][a-z0-9_.-]{0,31}$/;
/** Credential shapes must not travel through a code or display-name field. */
const HEX_TOKEN_PATTERN: RegExp = /^(?:[0-9a-f]{16,}|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$/;
const DOMAIN_LIKE_PATTERN: RegExp = /[A-Za-z0-9-]+\.[A-Za-z]{2,}/;
const CONTROL_PATTERN: RegExp = /[\u0000-\u001F\u007F]/;

const MAX_DISPLAY_NAME_LENGTH: number = 128;
const MAX_FAULT_COUNT: number = 1000000000;

const LOG_DOMAIN: number = 0x0000;
const LOG_TAG: string = 'HarlgramRpcServer';

/** Methods the extension accepts after authentication (design §5.4). */
const ALLOWED_METHODS: string[] = [
  'hello',
  'core.init',
  'core.quickStart',
  'core.action',
  'tun.start',
  'tun.stop',
  'vpn.options',
  'notification.update',
  'diagnostics.snapshot',
  'session.shutdown'
];

const CLASH_STATES: string[] = [
  'unconfigured',
  'unauthorized',
  'preparing',
  'connected',
  'stopped',
  'failed'
];

const PROXY_SCOPES: string[] = ['global', 'harlgramOnly'];
const EVENT_TYPES: string[] = ['loaded', 'delay', 'traffic', 'log'];
const LOG_LEVELS: string[] = ['error', 'warning'];

interface EmptyParams {
  readonly empty: boolean;
}

const EMPTY_PARAMS: EmptyParams = { empty: true };

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

/** Credentials read from `req-<nonce>.json` by the extension. */
export interface RpcServerSession {
  /** 32 hex nonce; must match the req file name. */
  nonce: string;
  /** 64 hex token; never logged or returned. */
  token: string;
}

/** Read-only context passed to the injected dispatcher. */
export interface RpcCallContext {
  /** Per-connection 16-hex session id returned by `auth`. */
  sessionId: string;
  /** SDK connection id, for correlation in extension-side logs. */
  clientId: number;
  /** Session epoch; increments on every start/rotation. */
  epoch: number;
  /** Method name (never the params). */
  method: string;
  /** Local receive time in epoch ms. */
  receivedAt: number;
}

/**
 * Injected by the VPN extension on every `onConnect` / `onCreate`.
 *
 * `handle` receives only authenticated requests; it must return a JSON object
 * or throw `RpcHandlerError` with a structured code. The server owns method
 * whitelisting and transport limits.
 */
export interface RpcServerHandlers {
  /** Current session credentials; a different nonce triggers rotation. */
  session: RpcServerSession;
  /** Extension process id written into the ack and the auth result. */
  pid: number;
  /** 16 hex random boot id written into the ack and the auth result. */
  bootId: string;
  handle: (method: string, params: object, context: RpcCallContext) => Promise<object>;
  /** Optional notification after the listener has been closed. */
  onListenerClosed?: (reason: RpcListenerCloseReason) => void;
}

/** Why the listener stopped; used only for extension-side state cleanup. */
export type RpcListenerCloseReason =
  | 'stopped'
  | 'rotated'
  | 'bind_failed'
  | 'ack_failed';

/** Result of `start`; `errorCode` is present only when `ok` is false. */
export interface RpcStartResult {
  ok: boolean;
  port: number;
  errorCode?: string;
}

/** Structured failure thrown by an injected handler. */
export class RpcHandlerError extends Error {
  readonly code: string;

  constructor(code: string) {
    super(code);
    this.code = code;
  }
}

/** Transport counters; never contain request content or addresses. */
export interface RpcServerStats {
  running: boolean;
  port: number;
  epoch: number;
  connections: number;
  authenticated: number;
  accepted: number;
  rejectedConnections: number;
  authSuccesses: number;
  authFailures: number;
  authTimeouts: number;
  staleTokens: number;
  frameTooLarge: number;
  frameErrors: number;
  protocolErrors: number;
  rateLimited: number;
  rateDisconnects: number;
  idleClosed: number;
  pending: number;
  requests: number;
  handlerFailures: number;
  pendingRejected: number;
  pushSent: number;
  pushDropped: number;
  encodeFailures: number;
  writeFailures: number;
  bindFailures: number;
  ackFailures: number;
  listenerErrors: number;
  rotations: number;
  stops: number;
}

// ---------------------------------------------------------------------------
// Internal wire shapes (only fields this module reads are declared)
// ---------------------------------------------------------------------------

interface RpcEnvelopeView {
  id?: JsonPayload;
  method?: JsonPayload;
  params?: JsonPayload;
  result?: JsonPayload;
  error?: JsonPayload;
  push?: JsonPayload;
  data?: JsonPayload;
}

interface ParsedRequest {
  id: string;
  method: string;
  params: object;
}

interface AuthParamsView {
  token?: JsonPayload;
  nonce?: JsonPayload;
  proto?: JsonPayload;
}

interface AuthResult {
  proto: number;
  sessionId: string;
  pid: number;
  bootId: string;
  serverTime: number;
}

interface ShutdownResult {
  closed: boolean;
}

interface StopStateData {
  state: string;
  epoch: number;
  scope: string;
}

interface RotatedFaultData {
  code: string;
}

interface PushSourceView {
  state?: JsonPayload;
  epoch?: JsonPayload;
  errorCode?: JsonPayload;
  activeNodeName?: JsonPayload;
  startedAt?: JsonPayload;
  scope?: JsonPayload;
  type?: JsonPayload;
  name?: JsonPayload;
  value?: JsonPayload;
  up?: JsonPayload;
  down?: JsonPayload;
  level?: JsonPayload;
  code?: JsonPayload;
  at?: JsonPayload;
  detailCode?: JsonPayload;
  count?: JsonPayload;
}

interface PushStateData {
  state: string;
  epoch: number;
  errorCode?: string;
  activeNodeName?: string;
  startedAt?: number;
  scope?: string;
}

interface PushEventData {
  type: string;
  name?: string;
  value?: number;
  at?: number;
  up?: number;
  down?: number;
  level?: string;
  code?: string;
}

interface PushFaultData {
  code: string;
  detailCode?: string;
  count?: number;
}

interface BindOutcome {
  ok: boolean;
  server?: socket.TCPSocketServer;
  port: number;
  errorCode?: string;
}

interface ServerCounters {
  accepted: number;
  rejectedConnections: number;
  authSuccesses: number;
  authFailures: number;
  authTimeouts: number;
  staleTokens: number;
  frameTooLarge: number;
  frameErrors: number;
  protocolErrors: number;
  rateLimited: number;
  rateDisconnects: number;
  idleClosed: number;
  requests: number;
  handlerFailures: number;
  pendingRejected: number;
  pushSent: number;
  pushDropped: number;
  encodeFailures: number;
  writeFailures: number;
  bindFailures: number;
  ackFailures: number;
  listenerErrors: number;
  rotations: number;
  stops: number;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/** Token bucket with fractional replenishment; no timers, only call time. */
class TokenBucket {
  private tokens: number;
  private lastRefillAt: number;
  private readonly ratePerSecond: number;
  private readonly capacity: number;

  constructor(ratePerSecond: number, capacity: number, now: number) {
    this.ratePerSecond = ratePerSecond;
    this.capacity = capacity;
    this.tokens = capacity;
    this.lastRefillAt = now;
  }

  /** Consumes one token when available; returns false without consuming. */
  take(now: number): boolean {
    const elapsed: number = now > this.lastRefillAt ? now - this.lastRefillAt : 0;
    this.lastRefillAt = now;
    this.tokens = this.tokens + (elapsed / 1000) * this.ratePerSecond;
    if (this.tokens > this.capacity) {
      this.tokens = this.capacity;
    }
    if (this.tokens < 1) {
      return false;
    }
    this.tokens -= 1;
    return true;
  }
}

/** One accepted loopback socket plus its framing/limit state. */
class RpcConnection {
  readonly socket: socket.TCPSocketConnection;
  readonly framer: RpcFramer = new RpcFramer();
  readonly bucket: TokenBucket;
  authenticated: boolean = false;
  sessionId: string = '';
  pending: number = 0;
  rateViolations: number = 0;
  live: boolean = true;
  lastActivityAt: number;
  authTimer: number = -1;
  /** Serializes writes so responses and pushes never interleave on the wire. */
  writeChain: Promise<void> = Promise.resolve();
  /** Serializes frame validation; auth completes before later frames run. */
  inboundChain: Promise<void> = Promise.resolve();

  constructor(connection: socket.TCPSocketConnection, now: number) {
    this.socket = connection;
    this.lastActivityAt = now;
    this.bucket = new TokenBucket(
      RPC_SERVER_PER_CONNECTION_RATE,
      RPC_SERVER_PER_CONNECTION_BURST,
      now
    );
  }
}

function delay(milliseconds: number): Promise<void> {
  return new Promise<void>((resolve: () => void): void => {
    setTimeout(resolve, milliseconds);
  });
}

/** Copies an encoded frame into an exact-size ArrayBuffer for `socket.send`. */
function toArrayBuffer(bytes: Uint8Array): ArrayBuffer {
  const copy: Uint8Array = new Uint8Array(bytes.length);
  copy.set(bytes, 0);
  return copy.buffer as ArrayBuffer;
}

/**
 * Constant-time string comparison: XOR every byte of both values, never
 * returning before the full length has been scanned.
 */
function constantTimeEquals(expected: string, actual: string): boolean {
  let difference: number = expected.length ^ actual.length;
  const length: number = expected.length > actual.length ? expected.length : actual.length;
  for (let index: number = 0; index < length; index++) {
    const left: number = index < expected.length ? expected.charCodeAt(index) : 0;
    const right: number = index < actual.length ? actual.charCodeAt(index) : 0;
    difference |= left ^ right;
  }
  return difference === 0;
}

function randomHex(length: number): string {
  const raw: string = util.generateRandomUUID(false).replace(/-/g, '').toLowerCase();
  if (raw.length === 0) {
    return '';
  }
  return raw.length >= length ? raw.substring(0, length) : raw;
}

function normalizeFilesRoot(filesDir: string): string {
  let root: string = filesDir;
  while (root.length > 0 && (root.endsWith('/') || root.endsWith('\\'))) {
    root = root.substring(0, root.length - 1);
  }
  if (root.length === 0 || root.indexOf('\u0000') >= 0) {
    return '';
  }
  return root;
}

function isPlainObject(value: JsonPayload | undefined): boolean {
  return value !== undefined && value !== null && typeof value === 'object' && !Array.isArray(value);
}

function safeNonNegativeInteger(value: JsonPayload | undefined, maximum: number): number | undefined {
  if (typeof value !== 'number' || !Number.isFinite(value)) {
    return undefined;
  }
  if (!Number.isSafeInteger(value) || value < 0 || value > maximum) {
    return undefined;
  }
  return value;
}

function safeNumber(value: JsonPayload | undefined): number | undefined {
  if (typeof value !== 'number' || !Number.isFinite(value)) {
    return undefined;
  }
  return value;
}

function isSafeCode(value: string): boolean {
  return CODE_PATTERN.test(value) && !HEX_TOKEN_PATTERN.test(value);
}

/**
 * Display names (node/group) are allowed by the design, but values that look
 * like paths, URLs, domains or credentials are discarded so a misbehaving
 * core cannot use this field as an exfiltration channel.
 */
function isSafeDisplayName(value: string): boolean {
  if (value.length === 0 || value.length > MAX_DISPLAY_NAME_LENGTH) {
    return false;
  }
  if (CONTROL_PATTERN.test(value) || HEX_TOKEN_PATTERN.test(value)) {
    return false;
  }
  if (value.indexOf('://') >= 0 || value.indexOf('/') >= 0 ||
    value.indexOf('\\') >= 0 || value.indexOf('@') >= 0) {
    return false;
  }
  return !DOMAIN_LIKE_PATTERN.test(value);
}

function isAllowedState(value: string): boolean {
  return CLASH_STATES.indexOf(value) >= 0;
}

function isAllowedScope(value: string): boolean {
  return PROXY_SCOPES.indexOf(value) >= 0;
}

function errorMessage(code: string): string {
  if (code === 'auth_failed') {
    return 'authentication failed';
  }
  if (code === 'rate_limited') {
    return 'rate limit exceeded';
  }
  if (code === 'method_not_allowed') {
    return 'method not allowed';
  }
  if (code === 'path_rejected') {
    return 'path resolution unavailable';
  }
  if (code === 'pending_limit') {
    return 'too many pending requests';
  }
  if (code === 'invalid_result') {
    return 'handler returned an invalid result';
  }
  if (code === 'auth_replayed') {
    return 'authentication already completed';
  }
  if (code === 'protocol_error') {
    return 'protocol violation';
  }
  if (code === 'rpc_unavailable') {
    return 'rpc unavailable';
  }
  return 'handler failed';
}

/** Logs a fixed category/code pair only; never a token, nonce, path or address. */
function logWarn(category: string, code: string): void {
  hilog.warn(LOG_DOMAIN, LOG_TAG, 'rpc server %{public}s: %{public}s', category, code);
}

// ---------------------------------------------------------------------------
// Server
// ---------------------------------------------------------------------------

/**
 * One instance per extension process. `filesDir` must be the VPN extension
 * sandbox directory (same sandbox as the UI process for the same bundle).
 */
export class ClashRpcServer {
  private readonly filesRoot: string;
  private readonly sessionFiles: ClashSessionFiles;

  private handlers: RpcServerHandlers | undefined = undefined;
  private server: socket.TCPSocketServer | undefined = undefined;
  private listenerPort: number = 0;
  private lastBoundPort: number = 0;

  private readonly connections: Map<number, RpcConnection> =
    new Map<number, RpcConnection>();
  private globalBucket: TokenBucket =
    new TokenBucket(RPC_SERVER_GLOBAL_RATE, RPC_SERVER_GLOBAL_BURST, Date.now());

  private pendingTotal: number = 0;
  private epoch: number = 0;
  private idleTimer: number = -1;
  private lifecycle: Promise<void> = Promise.resolve();

  private counters: ServerCounters = {
    accepted: 0,
    rejectedConnections: 0,
    authSuccesses: 0,
    authFailures: 0,
    authTimeouts: 0,
    staleTokens: 0,
    frameTooLarge: 0,
    frameErrors: 0,
    protocolErrors: 0,
    rateLimited: 0,
    rateDisconnects: 0,
    idleClosed: 0,
    requests: 0,
    handlerFailures: 0,
    pendingRejected: 0,
    pushSent: 0,
    pushDropped: 0,
    encodeFailures: 0,
    writeFailures: 0,
    bindFailures: 0,
    ackFailures: 0,
    listenerErrors: 0,
    rotations: 0,
    stops: 0
  };

  constructor(filesDir: string) {
    this.filesRoot = normalizeFilesRoot(filesDir);
    this.sessionFiles = new ClashSessionFiles(this.filesRoot);
    if (this.filesRoot.length === 0) {
      logWarn('config', 'files_dir_invalid');
    }
  }

  /**
   * Starts or rotates the listener.
   *
   * If a listener already exists, the old authenticated connections first
   * receive `fault{session_rotated}`, then the old sockets/listener are closed
   * and a fresh random port is bound for the new session. Bind failures write
   * `ack{ready:false,errorCode:"rpc_bind_failed"}` and never leave a listener
   * behind.
   */
  start(handlers: RpcServerHandlers): Promise<RpcStartResult> {
    const run: Promise<RpcStartResult> = this.lifecycle.then(
      (): Promise<RpcStartResult> => this.startInternal(handlers)
    );
    this.lifecycle = run.then((): void => {}, (): void => {});
    return run;
  }

  /** Pushes `state{stopped}`, closes every socket and the listener. Idempotent. */
  stop(): Promise<void> {
    const run: Promise<void> = this.lifecycle.then(
      (): Promise<void> => this.stopInternal()
    );
    this.lifecycle = run.then((): void => {}, (): void => {});
    return run;
  }

  /** True while a validated listener is bound. */
  isRunning(): boolean {
    return this.server !== undefined;
  }

  /**
   * Sends one push frame to every authenticated connection.
   *
   * Returns true when at least one frame was queued. Unauthenticated
   * connections never receive anything; invalid fields are dropped rather than
   * forwarded.
   */
  push(kind: RpcPushChannel, data: object): boolean {
    const prepared: object | undefined = this.sanitizePush(kind, data);
    if (prepared === undefined) {
      this.counters.pushDropped++;
      return false;
    }
    const frame: RpcPush = { push: kind, data: prepared };
    let queued: boolean = false;
    this.connections.forEach((connection: RpcConnection): void => {
      if (!connection.live || !connection.authenticated) {
        return;
      }
      this.enqueue(connection, frame);
      queued = true;
    });
    if (!queued) {
      this.counters.pushDropped++;
      return false;
    }
    this.counters.pushSent++;
    return true;
  }

  /** Read-only counter snapshot; contains no session material. */
  stats(): RpcServerStats {
    let authenticated: number = 0;
    this.connections.forEach((connection: RpcConnection): void => {
      if (connection.authenticated) {
        authenticated++;
      }
    });
    const snapshot: RpcServerStats = {
      running: this.isRunning(),
      port: this.listenerPort,
      epoch: this.epoch,
      connections: this.connections.size,
      authenticated: authenticated,
      accepted: this.counters.accepted,
      rejectedConnections: this.counters.rejectedConnections,
      authSuccesses: this.counters.authSuccesses,
      authFailures: this.counters.authFailures,
      authTimeouts: this.counters.authTimeouts,
      staleTokens: this.counters.staleTokens,
      frameTooLarge: this.counters.frameTooLarge,
      frameErrors: this.counters.frameErrors,
      protocolErrors: this.counters.protocolErrors,
      rateLimited: this.counters.rateLimited,
      rateDisconnects: this.counters.rateDisconnects,
      idleClosed: this.counters.idleClosed,
      pending: this.pendingTotal,
      requests: this.counters.requests,
      handlerFailures: this.counters.handlerFailures,
      pendingRejected: this.counters.pendingRejected,
      pushSent: this.counters.pushSent,
      pushDropped: this.counters.pushDropped,
      encodeFailures: this.counters.encodeFailures,
      writeFailures: this.counters.writeFailures,
      bindFailures: this.counters.bindFailures,
      ackFailures: this.counters.ackFailures,
      listenerErrors: this.counters.listenerErrors,
      rotations: this.counters.rotations,
      stops: this.counters.stops
    };
    return snapshot;
  }

  // -------------------------------------------------------------------------
  // Lifecycle
  // -------------------------------------------------------------------------

  private async startInternal(handlers: RpcServerHandlers): Promise<RpcStartResult> {
    const validationError: string | undefined = this.validateHandlers(handlers);
    if (validationError !== undefined) {
      logWarn('start', validationError);
      return { ok: false, port: 0, errorCode: validationError };
    }

    // Same session handshake again: keep the current listener, refresh the
    // dispatcher and report the existing port instead of rotating.
    if (this.server !== undefined && this.handlers !== undefined &&
      this.handlers.session.nonce === handlers.session.nonce &&
      constantTimeEquals(this.handlers.session.token, handlers.session.token)) {
      this.handlers = handlers;
      return { ok: true, port: this.listenerPort };
    }

    if (this.server !== undefined || this.connections.size > 0) {
      await this.rotateAway();
    }

    this.epoch++;
    this.handlers = handlers;
    this.pendingTotal = 0;
    this.globalBucket = new TokenBucket(
      RPC_SERVER_GLOBAL_RATE,
      RPC_SERVER_GLOBAL_BURST,
      Date.now()
    );

    const bind: BindOutcome = await this.bindWithRetry();
    if (!bind.ok || bind.server === undefined) {
      this.handlers = undefined;
      await this.writeFailureAck(handlers, 'rpc_bind_failed');
      this.notifyClosed(handlers, 'bind_failed');
      return { ok: false, port: 0, errorCode: 'rpc_bind_failed' };
    }

    const listener: socket.TCPSocketServer = bind.server;
    this.server = listener;
    this.listenerPort = bind.port;
    this.lastBoundPort = bind.port;
    this.attachListener(listener);

    const ack: SessionAck = {
      port: bind.port,
      pid: handlers.pid,
      bootId: handlers.bootId,
      ready: true
    };
    const written: SessionWriteResult = await this.sessionFiles.writeAck(
      handlers.session.nonce,
      ack
    );
    if (!written.ok) {
      this.counters.ackFailures++;
      await this.closeAllConnections('ack_failed');
      await this.closeListener();
      this.handlers = undefined;
      this.notifyClosed(handlers, 'ack_failed');
      return { ok: false, port: 0, errorCode: 'rpc_ack_failed' };
    }

    this.scheduleIdleSweep();
    return { ok: true, port: bind.port };
  }

  private async stopInternal(): Promise<void> {
    const handlers: RpcServerHandlers | undefined = this.handlers;
    const wasActive: boolean = this.server !== undefined || this.connections.size > 0;
    if (!wasActive) {
      this.handlers = undefined;
      return;
    }
    this.counters.stops++;

    // Design §5.6 / T-S2-13: notify before destroying the transport.
    const stopped: StopStateData = {
      state: 'stopped',
      epoch: this.epoch,
      scope: 'global'
    };
    await this.pushToAll('state', stopped);

    await this.closeAllConnections('stopped');
    await this.closeListener();
    this.handlers = undefined;
    this.pendingTotal = 0;
    if (handlers !== undefined) {
      this.notifyClosed(handlers, 'stopped');
    }
  }

  /**
   * Rotates to a new session: fault to old clients, close old transport, then
   * clear session state. The caller immediately binds the new listener.
   */
  private async rotateAway(): Promise<void> {
    this.counters.rotations++;
    const oldHandlers: RpcServerHandlers | undefined = this.handlers;
    const rotated: RotatedFaultData = { code: 'session_rotated' };
    await this.pushToAll('fault', rotated);
    await this.closeAllConnections('rotated');
    await this.closeListener();
    this.handlers = undefined;
    this.pendingTotal = 0;
    if (oldHandlers !== undefined) {
      this.notifyClosed(oldHandlers, 'rotated');
    }
  }

  private validateHandlers(handlers: RpcServerHandlers): string | undefined {
    if (this.filesRoot.length === 0) {
      return 'session_invalid';
    }
    if (handlers === undefined || handlers.session === undefined) {
      return 'session_invalid';
    }
    if (typeof handlers.session.nonce !== 'string' ||
      !NONCE_PATTERN.test(handlers.session.nonce)) {
      return 'session_invalid';
    }
    if (typeof handlers.session.token !== 'string' ||
      !TOKEN_PATTERN.test(handlers.session.token)) {
      return 'session_invalid';
    }
    if (!Number.isSafeInteger(handlers.pid) || handlers.pid <= 0) {
      return 'session_invalid';
    }
    if (typeof handlers.bootId !== 'string' || !BOOT_ID_PATTERN.test(handlers.bootId)) {
      return 'session_invalid';
    }
    if (typeof handlers.handle !== 'function') {
      return 'session_invalid';
    }
    return undefined;
  }

  private notifyClosed(handlers: RpcServerHandlers, reason: RpcListenerCloseReason): void {
    if (handlers.onListenerClosed !== undefined) {
      try {
        handlers.onListenerClosed(reason);
      } catch (error) {
        logWarn('listener', 'callback_failed');
      }
    }
  }

  // -------------------------------------------------------------------------
  // Listener and accept
  // -------------------------------------------------------------------------

  private async bindWithRetry(): Promise<BindOutcome> {
    let lastError: string = 'rpc_bind_failed';
    for (let attempt: number = 0; attempt <= RPC_SERVER_BIND_RETRIES; attempt++) {
      if (attempt > 0) {
        await delay(RPC_SERVER_BIND_RETRY_DELAY_MS);
      }
      const outcome: BindOutcome = await this.bindOnce();
      if (outcome.ok) {
        return outcome;
      }
      this.counters.bindFailures++;
      if (outcome.errorCode !== undefined) {
        lastError = outcome.errorCode;
      }
      logWarn('bind', lastError);
    }
    const failed: BindOutcome = { ok: false, port: 0, errorCode: lastError };
    return failed;
  }

  private async bindOnce(): Promise<BindOutcome> {
    const listener: socket.TCPSocketServer = socket.constructTCPSocketServerInstance();
    const options: socket.NetAddress = {
      address: LOOPBACK_ADDRESS,
      port: 0,
      family: 1
    };
    try {
      await listener.listen(options);
      const local: socket.NetAddress = await listener.getLocalAddress();
      const rawPort: number | undefined = local.port;
      if (rawPort === undefined || !Number.isSafeInteger(rawPort) ||
        rawPort < MIN_PORT || rawPort > MAX_PORT || rawPort === SESSION_LEGACY_PORT) {
        await closeQuietly(listener);
        return { ok: false, port: 0, errorCode: 'rpc_bind_failed' };
      }
      const port: number = rawPort;
      // Consecutive sessions must not reuse a port (REQ-090); the OS normally
      // assigns a different ephemeral port, but assert it explicitly.
      if (this.lastBoundPort > 0 && port === this.lastBoundPort) {
        await closeQuietly(listener);
        return { ok: false, port: 0, errorCode: 'rpc_bind_failed' };
      }
      return { ok: true, server: listener, port: port };
    } catch (error) {
      await closeQuietly(listener);
      return { ok: false, port: 0, errorCode: 'rpc_bind_failed' };
    }
  }

  private attachListener(listener: socket.TCPSocketServer): void {
    listener.on('connect', (connection: socket.TCPSocketConnection): void => {
      this.accept(connection);
    });
    listener.on('error', (): void => {
      this.counters.listenerErrors++;
      logWarn('listener', 'socket_error');
    });
  }

  private accept(connection: socket.TCPSocketConnection): void {
    if (!this.isRunning()) {
      connection.close().catch((): void => {});
      return;
    }
    if (this.connections.size >= RPC_SERVER_MAX_CONNECTIONS) {
      this.counters.rejectedConnections++;
      logWarn('accept', 'connection_limit');
      connection.close().catch((): void => {});
      return;
    }
    const now: number = Date.now();
    const tracked: RpcConnection = new RpcConnection(connection, now);
    this.connections.set(connection.clientId, tracked);
    this.counters.accepted++;

    connection.on('message', (info: socket.SocketMessageInfo): void => {
      this.onMessage(tracked, info);
    });
    connection.on('close', (): void => {
      this.dropConnection(tracked, 'peer_closed');
    });
    connection.on('error', (): void => {
      this.dropConnection(tracked, 'socket_error');
    });

    tracked.authTimer = setTimeout((): void => {
      this.onAuthTimeout(tracked);
    }, RPC_SERVER_AUTH_TIMEOUT_MS);
  }

  private onAuthTimeout(connection: RpcConnection): void {
    connection.authTimer = -1;
    if (!connection.live || connection.authenticated) {
      return;
    }
    this.counters.authTimeouts++;
    this.counters.authFailures++;
    // No frame is sent: the client is unauthenticated and must learn the
    // failure from the disconnect (design §5.3).
    this.dropConnection(connection, 'auth_timeout');
  }

  // -------------------------------------------------------------------------
  // Inbound frames
  // -------------------------------------------------------------------------

  private onMessage(connection: RpcConnection, info: socket.SocketMessageInfo): void {
    if (!connection.live) {
      return;
    }
    connection.lastActivityAt = Date.now();
    const chunk: Uint8Array = new Uint8Array(info.message);
    const decoded = connection.framer.decodeChunk(chunk);
    if (decoded.errors.length > 0) {
      let tooLarge: boolean = false;
      for (let index: number = 0; index < decoded.errors.length; index++) {
        if (decoded.errors[index].code === 'buffer_overflow') {
          tooLarge = true;
        }
      }
      if (tooLarge) {
        this.counters.frameTooLarge++;
      } else {
        this.counters.frameErrors++;
      }
      logWarn('frame', tooLarge ? 'frame_too_large' : 'frame_error');
      this.dropConnection(connection, 'frame_error');
      return;
    }
    if (decoded.frames.length > MAX_FRAMES_PER_CHUNK) {
      this.counters.protocolErrors++;
      logWarn('frame', 'frame_burst');
      this.dropConnection(connection, 'frame_burst');
      return;
    }
    for (let index: number = 0; index < decoded.frames.length; index++) {
      const frame: object = decoded.frames[index];
      connection.inboundChain = connection.inboundChain.then(
        (): Promise<void> => this.processFrame(connection, frame)
      );
    }
  }

  private async processFrame(connection: RpcConnection, frame: object): Promise<void> {
    try {
      if (!connection.live) {
        return;
      }
      const parsed: ParsedRequest | undefined = parseRequest(frame);
      if (parsed === undefined) {
        this.counters.protocolErrors++;
        const id: string = readEnvelopeId(frame);
        if (id.length > 0) {
          await this.sendError(connection, id, 'protocol_error');
        }
        this.dropConnection(connection, 'protocol_error');
        return;
      }

      if (!connection.authenticated) {
        if (parsed.method !== 'auth') {
          await this.rejectAuth(connection, parsed.id);
          return;
        }
        await this.handleAuth(connection, parsed);
        return;
      }

      if (parsed.method === 'auth') {
        await this.sendError(connection, parsed.id, 'auth_replayed');
        this.dropConnection(connection, 'auth_replayed');
        return;
      }

      const now: number = Date.now();
      const perConnection: boolean = connection.bucket.take(now);
      const global: boolean = this.globalBucket.take(now);
      if (!perConnection || !global) {
        this.rejectRateLimited(connection, parsed.id);
        return;
      }
      connection.rateViolations = 0;

      if (connection.pending >= RPC_SERVER_PENDING_PER_CLIENT ||
        this.pendingTotal >= RPC_SERVER_PENDING_TOTAL) {
        this.counters.pendingRejected++;
        await this.sendError(connection, parsed.id, 'pending_limit');
        return;
      }

      if (ALLOWED_METHODS.indexOf(parsed.method) < 0) {
        await this.sendError(connection, parsed.id, 'method_not_allowed');
        return;
      }

      this.startRequest(connection, parsed, now);
    } catch (error) {
      this.counters.protocolErrors++;
      this.dropConnection(connection, 'internal_error');
    }
  }

  // -------------------------------------------------------------------------
  // Authentication
  // -------------------------------------------------------------------------

  private async handleAuth(connection: RpcConnection, request: ParsedRequest): Promise<void> {
    const handlers: RpcServerHandlers | undefined = this.handlers;
    if (handlers === undefined) {
      await this.rejectAuth(connection, request.id);
      return;
    }
    const params: AuthParamsView = request.params as AuthParamsView;
    const tokenValue: JsonPayload | undefined = params.token;
    const nonceValue: JsonPayload | undefined = params.nonce;
    const protoValue: JsonPayload | undefined = params.proto;

    const actualToken: string = typeof tokenValue === 'string' ? tokenValue : '';
    const actualNonce: string = typeof nonceValue === 'string' ? nonceValue : '';

    // Both comparisons run to completion regardless of earlier mismatches.
    const tokenMatches: boolean = constantTimeEquals(handlers.session.token, actualToken);
    const nonceMatches: boolean = constantTimeEquals(handlers.session.nonce, actualNonce);
    const shapeMatches: boolean = TOKEN_PATTERN.test(actualToken) &&
      NONCE_PATTERN.test(actualNonce) &&
      typeof protoValue === 'number' && protoValue === RPC_PROTO;

    if (!tokenMatches || !nonceMatches || !shapeMatches) {
      if (TOKEN_PATTERN.test(actualToken) && !tokenMatches) {
        this.counters.staleTokens++;
      }
      await this.rejectAuth(connection, request.id);
      return;
    }

    if (connection.authTimer >= 0) {
      clearTimeout(connection.authTimer);
      connection.authTimer = -1;
    }
    connection.authenticated = true;
    connection.sessionId = randomHex(16);
    this.counters.authSuccesses++;

    const result: AuthResult = {
      proto: RPC_PROTO,
      sessionId: connection.sessionId,
      pid: handlers.pid,
      bootId: handlers.bootId,
      serverTime: Date.now()
    };
    await this.sendResult(connection, request.id, result);
    // Design §5.1 rule 4: keep req until authentication succeeds, then delete.
    await this.removeRequestFile(handlers.session.nonce);
  }

  /** Rejects auth, sends a structured error when an id exists, then closes. */
  private async rejectAuth(connection: RpcConnection, id: string): Promise<void> {
    this.counters.authFailures++;
    await this.sendError(connection, id, 'auth_failed');
    this.dropConnection(connection, 'auth_failed');
  }

  // -------------------------------------------------------------------------
  // Request dispatch
  // -------------------------------------------------------------------------

  private startRequest(
    connection: RpcConnection,
    request: ParsedRequest,
    receivedAt: number
  ): void {
    this.runRequest(connection, request, receivedAt).catch((): void => {
      this.counters.protocolErrors++;
      this.dropConnection(connection, 'internal_error');
    });
  }

  private async runRequest(
    connection: RpcConnection,
    request: ParsedRequest,
    receivedAt: number
  ): Promise<void> {
    connection.pending++;
    this.pendingTotal++;
    this.counters.requests++;

    const handlers: RpcServerHandlers | undefined = this.handlers;
    let failureCode: string = '';
    let payload: JsonPayload = null;

    try {
      if (handlers === undefined) {
        failureCode = 'rpc_unavailable';
      } else {
        const context: RpcCallContext = {
          sessionId: connection.sessionId,
          clientId: connection.socket.clientId,
          epoch: this.epoch,
          method: request.method,
          receivedAt: receivedAt
        };
        payload = await handlers.handle(request.method, request.params, context);
      }
    } catch (error) {
      this.counters.handlerFailures++;
      failureCode = handlerErrorCode(error as Error);
    } finally {
      connection.pending--;
      if (this.pendingTotal > 0) {
        this.pendingTotal--;
      }
    }

    if (!connection.live) {
      return;
    }
    if (failureCode.length > 0) {
      await this.sendError(connection, request.id, failureCode);
      return;
    }
    if (payload === null || typeof payload !== 'object' || Array.isArray(payload)) {
      await this.sendError(connection, request.id, 'invalid_result');
      return;
    }

    const result: object = payload as object;
    const responseResult: object = request.method === 'session.shutdown'
      ? shutdownResult()
      : result;
    const sent: boolean = await this.sendResult(connection, request.id, responseResult);
    if (request.method === 'session.shutdown' && sent) {
      // The response above is already queued; `stop` drains writes first.
      this.scheduleStop();
    }
  }

  private scheduleStop(): void {
    setTimeout((): void => {
      this.stop();
    }, 0);
  }

  private rejectRateLimited(connection: RpcConnection, id: string): void {
    if (!connection.live) {
      return;
    }
    this.counters.rateLimited++;
    connection.rateViolations++;
    const shouldDrop: boolean = connection.rateViolations >= RPC_SERVER_RATE_VIOLATION_LIMIT;
    this.sendError(connection, id, 'rate_limited').then((): void => {
      if (shouldDrop && connection.live) {
        this.counters.rateDisconnects++;
        this.dropConnection(connection, 'rate_limited');
      }
    });
  }

  // -------------------------------------------------------------------------
  // Outbound frames and pushes
  // -------------------------------------------------------------------------

  private sendResult(connection: RpcConnection, id: string, result: object): Promise<boolean> {
    const response: RpcResponse = {
      id: id,
      result: result
    };
    return this.enqueue(connection, response);
  }

  private sendError(connection: RpcConnection, id: string, code: string): Promise<boolean> {
    const body: RpcErrorBody = {
      code: code,
      message: errorMessage(code)
    };
    const response: RpcResponse = {
      id: id,
      error: body
    };
    return this.enqueue(connection, response);
  }

  /**
   * Encodes and queues one frame. Failures never reject: a failed write drops
   * the connection and is counted.
   */
  private enqueue(connection: RpcConnection, value: object): Promise<boolean> {
    if (!connection.live) {
      return Promise.resolve(false);
    }
    let bytes: Uint8Array;
    try {
      bytes = encodeRequest(value);
    } catch (error) {
      this.counters.encodeFailures++;
      logWarn('encode', 'frame_rejected');
      return Promise.resolve(false);
    }
    const frame: ArrayBuffer = toArrayBuffer(bytes);
    const write: Promise<void> = connection.writeChain.then(
      (): Promise<void> => this.writeFrame(connection, frame)
    );
    const settled: Promise<void> = write.catch((): void => {
      this.counters.writeFailures++;
      this.dropConnection(connection, 'write_failed');
    });
    connection.writeChain = settled;
    return settled.then((): boolean => connection.live);
  }

  private async writeFrame(connection: RpcConnection, frame: ArrayBuffer): Promise<void> {
    if (!connection.live) {
      return;
    }
    await connection.socket.send({ data: frame });
    connection.lastActivityAt = Date.now();
  }

  /** Pushes to authenticated connections and waits briefly for the flush. */
  private async pushToAll(kind: RpcPushChannel, data: object): Promise<void> {
    const prepared: object | undefined = this.sanitizePush(kind, data);
    if (prepared === undefined) {
      this.counters.pushDropped++;
      return;
    }
    const frame: RpcPush = { push: kind, data: prepared };
    const targets: RpcConnection[] = [];
    this.connections.forEach((connection: RpcConnection): void => {
      if (connection.live && connection.authenticated) {
        targets.push(connection);
      }
    });
    for (let index: number = 0; index < targets.length; index++) {
      const connection: RpcConnection = targets[index];
      const sent: Promise<void> = this.enqueue(connection, frame).then((): void => {});
      const waits: Promise<void>[] = [sent, delay(DRAIN_TIMEOUT_MS)];
      await Promise.race(waits);
    }
  }

  /**
   * Rebuilds a push payload from the whitelist for the channel. Unexpected
   * fields, raw URLs, paths, domains and credentials are never copied.
   */
  private sanitizePush(kind: RpcPushChannel, data: object): object | undefined {
    if (data === null || typeof data !== 'object' || Array.isArray(data)) {
      return undefined;
    }
    const view: PushSourceView = data as PushSourceView;
    if (kind === 'state') {
      return sanitizeStatePush(view, this.epoch);
    }
    if (kind === 'event') {
      return sanitizeEventPush(view);
    }
    if (kind === 'fault') {
      return sanitizeFaultPush(view);
    }
    return undefined;
  }

  // -------------------------------------------------------------------------
  // Closedown helpers
  // -------------------------------------------------------------------------

  private async closeAllConnections(reason: string): Promise<void> {
    const targets: RpcConnection[] = [];
    this.connections.forEach((connection: RpcConnection): void => {
      targets.push(connection);
    });
    for (let index: number = 0; index < targets.length; index++) {
      this.dropConnection(targets[index], reason);
    }
    // Give socket close callbacks a chance to run before the listener closes.
    await delay(0);
  }

  private dropConnection(connection: RpcConnection, reason: string): void {
    if (!connection.live) {
      return;
    }
    connection.live = false;
    if (connection.authTimer >= 0) {
      clearTimeout(connection.authTimer);
      connection.authTimer = -1;
    }
    this.connections.delete(connection.socket.clientId);
    if (reason === 'idle') {
      this.counters.idleClosed++;
    }
    try {
      connection.socket.off('message');
      connection.socket.off('close');
      connection.socket.off('error');
    } catch (error) {
      logWarn('connection', 'off_failed');
    }
    connection.socket.close().catch((): void => {});
    logWarn('connection', reason);
  }

  private async closeListener(): Promise<void> {
    if (this.idleTimer >= 0) {
      clearTimeout(this.idleTimer);
      this.idleTimer = -1;
    }
    const listener: socket.TCPSocketServer | undefined = this.server;
    this.server = undefined;
    this.listenerPort = 0;
    if (listener === undefined) {
      return;
    }
    try {
      listener.off('connect');
      listener.off('error');
    } catch (error) {
      logWarn('listener', 'off_failed');
    }
    await closeQuietly(listener);
  }

  private scheduleIdleSweep(): void {
    if (!this.isRunning()) {
      return;
    }
    this.idleTimer = setTimeout((): void => {
      this.idleTimer = -1;
      this.sweepIdle();
    }, IDLE_SWEEP_INTERVAL_MS);
  }

  private sweepIdle(): void {
    const now: number = Date.now();
    const expired: RpcConnection[] = [];
    this.connections.forEach((connection: RpcConnection): void => {
      if (connection.live &&
        now - connection.lastActivityAt >= RPC_SERVER_IDLE_TIMEOUT_MS) {
        expired.push(connection);
      }
    });
    for (let index: number = 0; index < expired.length; index++) {
      this.dropConnection(expired[index], 'idle');
    }
    this.scheduleIdleSweep();
  }

  // -------------------------------------------------------------------------
  // Session files
  // -------------------------------------------------------------------------

  private async writeFailureAck(
    handlers: RpcServerHandlers,
    errorCode: string
  ): Promise<void> {
    const ack: SessionAck = {
      port: 0,
      pid: handlers.pid,
      bootId: handlers.bootId,
      ready: false,
      errorCode: errorCode
    };
    const written: SessionWriteResult = await this.sessionFiles.writeAck(
      handlers.session.nonce,
      ack
    );
    if (!written.ok) {
      this.counters.ackFailures++;
      logWarn('ack', 'write_failed');
    }
  }

  /**
   * Deletes only `req-<nonce>.json`. The nonce shape is re-checked so the
   * derived path cannot escape the session directory.
   */
  private async removeRequestFile(nonce: string): Promise<void> {
    if (this.filesRoot.length === 0 || !NONCE_PATTERN.test(nonce)) {
      return;
    }
    const path: string = this.filesRoot + '/proxy/session/req-' + nonce + '.json';
    try {
      if (await fileIo.access(path)) {
        await fileIo.unlink(path);
      }
    } catch (error) {
      logWarn('req', 'remove_failed');
    }
  }
}

// ---------------------------------------------------------------------------
// Frame parsing and push sanitizers
// ---------------------------------------------------------------------------

function readEnvelopeId(frame: object): string {
  const view: RpcEnvelopeView = frame as RpcEnvelopeView;
  return typeof view.id === 'string' ? view.id : '';
}

function parseRequest(frame: object): ParsedRequest | undefined {
  const view: RpcEnvelopeView = frame as RpcEnvelopeView;
  const idValue: JsonPayload | undefined = view.id;
  const methodValue: JsonPayload | undefined = view.method;
  if (typeof idValue !== 'string' || !REQUEST_ID_PATTERN.test(idValue)) {
    return undefined;
  }
  if (typeof methodValue !== 'string' || !REQUEST_ID_PATTERN.test(methodValue)) {
    return undefined;
  }
  if (view.result !== undefined || view.error !== undefined ||
    view.push !== undefined || view.data !== undefined) {
    return undefined;
  }
  if (view.params !== undefined && !isPlainObject(view.params)) {
    return undefined;
  }
  const params: object = view.params === undefined ? EMPTY_PARAMS : view.params as object;
  const request: ParsedRequest = {
    id: idValue,
    method: methodValue,
    params: params
  };
  return request;
}

function handlerErrorCode(error: Error): string {
  if (error instanceof RpcHandlerError && isSafeCode(error.code)) {
    return error.code;
  }
  return 'handler_failed';
}

/** `session.shutdown` always answers with the server-owned closed flag. */
function shutdownResult(): object {
  const result: ShutdownResult = { closed: true };
  return result;
}

function sanitizeStatePush(view: PushSourceView, fallbackEpoch: number): object | undefined {
  const stateValue: JsonPayload | undefined = view.state;
  if (typeof stateValue !== 'string' || !isAllowedState(stateValue)) {
    return undefined;
  }
  const epoch: number | undefined = safeNonNegativeInteger(view.epoch, Number.MAX_SAFE_INTEGER);
  const data: PushStateData = {
    state: stateValue,
    epoch: epoch === undefined ? fallbackEpoch : epoch
  };

  const errorCode: JsonPayload | undefined = view.errorCode;
  if (typeof errorCode === 'string' && isSafeCode(errorCode)) {
    data.errorCode = errorCode;
  }
  const nodeName: JsonPayload | undefined = view.activeNodeName;
  if (typeof nodeName === 'string' && isSafeDisplayName(nodeName)) {
    data.activeNodeName = nodeName;
  }
  const startedAt: number | undefined = safeNonNegativeInteger(
    view.startedAt,
    Number.MAX_SAFE_INTEGER
  );
  if (startedAt !== undefined) {
    data.startedAt = startedAt;
  }
  const scope: JsonPayload | undefined = view.scope;
  if (typeof scope === 'string' && isAllowedScope(scope)) {
    data.scope = scope;
  }
  return data;
}

function sanitizeEventPush(view: PushSourceView): object | undefined {
  const typeValue: JsonPayload | undefined = view.type;
  if (typeof typeValue !== 'string' || EVENT_TYPES.indexOf(typeValue) < 0) {
    return undefined;
  }
  if (typeValue === 'loaded') {
    const loaded: PushEventData = { type: 'loaded' };
    return loaded;
  }
  if (typeValue === 'delay') {
    const name: JsonPayload | undefined = view.name;
    const value: number | undefined = safeNumber(view.value);
    if (typeof name !== 'string' || !isSafeDisplayName(name) || value === undefined) {
      return undefined;
    }
    const delay: PushEventData = { type: 'delay', name: name, value: value };
    const at: number | undefined = safeNonNegativeInteger(view.at, Number.MAX_SAFE_INTEGER);
    if (at !== undefined) {
      delay.at = at;
    }
    // `url` is intentionally not copied: delay events are matched by name.
    return delay;
  }
  if (typeValue === 'traffic') {
    const up: number | undefined = safeNonNegativeInteger(view.up, Number.MAX_SAFE_INTEGER);
    const down: number | undefined = safeNonNegativeInteger(view.down, Number.MAX_SAFE_INTEGER);
    if (up === undefined || down === undefined) {
      return undefined;
    }
    const traffic: PushEventData = { type: 'traffic', up: up, down: down };
    return traffic;
  }
  // log
  const level: JsonPayload | undefined = view.level;
  const code: JsonPayload | undefined = view.code;
  if (typeof level !== 'string' || LOG_LEVELS.indexOf(level) < 0) {
    return undefined;
  }
  if (typeof code !== 'string' || !isSafeCode(code)) {
    return undefined;
  }
  const log: PushEventData = { type: 'log', level: level, code: code };
  return log;
}

function sanitizeFaultPush(view: PushSourceView): object | undefined {
  const code: JsonPayload | undefined = view.code;
  if (typeof code !== 'string' || !isSafeCode(code)) {
    return undefined;
  }
  const fault: PushFaultData = { code: code };
  const detail: JsonPayload | undefined = view.detailCode;
  if (typeof detail === 'string' && detail.length > 0 && isSafeCode(detail)) {
    fault.detailCode = detail;
  }
  const count: number | undefined = safeNonNegativeInteger(view.count, MAX_FAULT_COUNT);
  if (count !== undefined) {
    fault.count = count;
  }
  return fault;
}

async function closeQuietly(listener: socket.TCPSocketServer): Promise<void> {
  try {
    await listener.close();
  } catch (error) {
    logWarn('listener', 'close_failed');
  }
}