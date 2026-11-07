/**
 * NDJSON framing for the loopback RPC channel (task T-S1-11, design §5.2).
 *
 * Wire format: one UTF-8 JSON object per line, terminated by a single `0x0A`.
 *
 * Why this file owns its UTF-8 codec:
 * - The runtime target is ArkTS, which exposes no portable platform text codec
 *   and no Node byte-buffer globals.
 * - Frames must be split on bytes (`0x0A`), never on decoded text: a TCP chunk may
 *   end in the middle of a multi-byte sequence, and decoding that chunk first
 *   corrupts the following frames.
 *
 * Failure policy: no uncaught exceptions escape `push`. Structural problems are
 * reported as `FrameError` codes that carry a line number only, never the frame
 * content (content may contain node names or configuration text).
 *
 * This module is pure TypeScript (no HarmonyOS Kit imports) so it can be
 * transpiled and unit-tested on the host.
 */

import { JsonPayload, RPC_MAX_FRAME_BYTES } from '../../model/ClashModels';

/** Single frame limit (1 MiB); reuses the shared model constant. */
export const MAX_FRAME_BYTES: number = RPC_MAX_FRAME_BYTES;

const LINE_FEED: number = 0x0A;

/** Exported so the ArkTS facade can map a thrown encode failure to a structured code. */
export const ERROR_FRAME_TOO_LARGE: string = 'frame_too_large';
const ERROR_ENCODE_FAILED: string = 'encode_failed';

/** Minimal pending-buffer capacity so tiny first chunks do not reallocate often. */
const MIN_PENDING_CAPACITY: number = 64;

/** Number of UTF-16 code units assembled per string concatenation. */
const STRING_CHUNK_SIZE: number = 1024;

/** Structural decode failure. `line` is 1-based and never carries content. */
export type FrameErrorCode = 'malformed_frame' | 'buffer_overflow' | 'invalid_utf8';

export interface FrameError {
  code: FrameErrorCode;
  /** 1-based index of the terminated (or still accumulating) line. */
  line: number;
}

export interface DecodeResult {
  /** Successfully decoded JSON objects, in wire order. */
  frames: object[];
  /** Structural errors encountered in this call, in wire order. */
  errors: FrameError[];
}

/** Envelope view used for structural checks; every field is read defensively. */
interface EnvelopeView {
  id?: JsonPayload;
  method?: JsonPayload;
  params?: JsonPayload;
  result?: JsonPayload;
  error?: JsonPayload;
  push?: JsonPayload;
  data?: JsonPayload;
}

/** Shape of `error` inside an RPC response. */
interface RpcErrorView {
  code?: JsonPayload;
  message?: JsonPayload;
}

// ---------------------------------------------------------------------------
// UTF-8 codec (1-4 byte sequences, surrogate pairs, strict validation)
// ---------------------------------------------------------------------------

/**
 * Encodes a string as UTF-8.
 * Returns `null` for unpaired surrogates instead of throwing; the caller maps
 * that to the structured `encode_failed` error.
 */
function encodeUtf8(text: string): Uint8Array | null {
  const bytes: number[] = [];
  let index: number = 0;
  while (index < text.length) {
    let codePoint: number = text.charCodeAt(index);
    index += 1;
    if (codePoint >= 0xD800 && codePoint <= 0xDBFF) {
      if (index >= text.length) {
        return null;
      }
      const low: number = text.charCodeAt(index);
      if (low < 0xDC00 || low > 0xDFFF) {
        return null;
      }
      index += 1;
      codePoint = 0x10000 + ((codePoint - 0xD800) << 10) + (low - 0xDC00);
    } else if (codePoint >= 0xDC00 && codePoint <= 0xDFFF) {
      return null;
    }
    appendCodePoint(bytes, codePoint);
  }
  return new Uint8Array(bytes);
}

function appendCodePoint(bytes: number[], codePoint: number): void {
  if (codePoint <= 0x7F) {
    bytes.push(codePoint);
    return;
  }
  if (codePoint <= 0x7FF) {
    bytes.push(0xC0 | (codePoint >> 6));
    bytes.push(0x80 | (codePoint & 0x3F));
    return;
  }
  if (codePoint <= 0xFFFF) {
    bytes.push(0xE0 | (codePoint >> 12));
    bytes.push(0x80 | ((codePoint >> 6) & 0x3F));
    bytes.push(0x80 | (codePoint & 0x3F));
    return;
  }
  bytes.push(0xF0 | (codePoint >> 18));
  bytes.push(0x80 | ((codePoint >> 12) & 0x3F));
  bytes.push(0x80 | ((codePoint >> 6) & 0x3F));
  bytes.push(0x80 | (codePoint & 0x3F));
}

/**
 * Decodes a complete line of UTF-8 bytes.
 * Rejects truncated sequences, stray continuation bytes, overlong forms,
 * surrogate code points and values above U+10FFFF by returning `null`.
 */
function decodeUtf8(bytes: Uint8Array): string | null {
  const units: number[] = [];
  const length: number = bytes.length;
  let index: number = 0;
  while (index < length) {
    const first: number = bytes[index];
    index += 1;
    if (first < 0x80) {
      units.push(first);
      continue;
    }
    let continuationCount: number = 0;
    let codePoint: number = 0;
    let minimum: number = 0;
    if ((first & 0xE0) === 0xC0) {
      continuationCount = 1;
      codePoint = first & 0x1F;
      minimum = 0x80;
    } else if ((first & 0xF0) === 0xE0) {
      continuationCount = 2;
      codePoint = first & 0x0F;
      minimum = 0x800;
    } else if ((first & 0xF8) === 0xF0) {
      continuationCount = 3;
      codePoint = first & 0x07;
      minimum = 0x10000;
    } else {
      return null;
    }
    if (index + continuationCount > length) {
      return null;
    }
    for (let offset: number = 0; offset < continuationCount; offset++) {
      const next: number = bytes[index + offset];
      if ((next & 0xC0) !== 0x80) {
        return null;
      }
      codePoint = (codePoint << 6) | (next & 0x3F);
    }
    index += continuationCount;
    if (codePoint < minimum || codePoint > 0x10FFFF) {
      return null;
    }
    if (codePoint >= 0xD800 && codePoint <= 0xDFFF) {
      return null;
    }
    if (codePoint <= 0xFFFF) {
      units.push(codePoint);
    } else {
      const offset: number = codePoint - 0x10000;
      units.push(0xD800 + (offset >> 10));
      units.push(0xDC00 + (offset & 0x3FF));
    }
  }
  return joinCodeUnits(units);
}

/** Joins code units in bounded batches to keep `String.fromCharCode` calls small. */
function joinCodeUnits(units: number[]): string {
  let output: string = '';
  let start: number = 0;
  while (start < units.length) {
    const end: number = start + STRING_CHUNK_SIZE < units.length
      ? start + STRING_CHUNK_SIZE
      : units.length;
    let piece: string = '';
    for (let index: number = start; index < end; index++) {
      piece += String.fromCharCode(units[index]);
    }
    output += piece;
    start = end;
  }
  return output;
}

// ---------------------------------------------------------------------------
// Encoding
// ---------------------------------------------------------------------------

/**
 * Serializes one frame to UTF-8 bytes terminated by `0x0A`.
 * Throws `Error('frame_too_large')` when the frame (payload plus delimiter)
 * exceeds `MAX_FRAME_BYTES`, and `Error('encode_failed')` when the value cannot
 * be serialized (circular structure, BigInt, throwing `toJSON`, unpaired
 * surrogate).
 */
export function encodeFrame(value: object): Uint8Array {
  let encoded: JsonPayload = null;
  try {
    encoded = JSON.stringify(value) as JsonPayload;
  } catch {
    throw new Error(ERROR_ENCODE_FAILED);
  }
  if (typeof encoded !== 'string') {
    throw new Error(ERROR_ENCODE_FAILED);
  }
  // UTF-16 length is a lower bound for the UTF-8 byte count, so an oversized
  // text can be rejected before allocating the byte buffer.
  if (encoded.length > MAX_FRAME_BYTES) {
    throw new Error(ERROR_FRAME_TOO_LARGE);
  }
  const payload: Uint8Array | null = encodeUtf8(encoded);
  if (payload === null) {
    throw new Error(ERROR_ENCODE_FAILED);
  }
  if (payload.length + 1 > MAX_FRAME_BYTES) {
    throw new Error(ERROR_FRAME_TOO_LARGE);
  }
  const frame: Uint8Array = new Uint8Array(payload.length + 1);
  frame.set(payload, 0);
  frame[payload.length] = LINE_FEED;
  return frame;
}

// ---------------------------------------------------------------------------
// Decoding
// ---------------------------------------------------------------------------

/**
 * Incremental byte-level NDJSON decoder.
 *
 * `push` accepts arbitrary TCP chunk boundaries: bytes without a `0x0A` are
 * buffered, complete lines are decoded independently. Call `reset()` when a
 * connection is reused for a new session.
 */
export class FrameDecoder {
  /** Pending bytes of the line currently being assembled (no delimiter yet). */
  private pending: Uint8Array = new Uint8Array(0);
  private pendingLength: number = 0;
  /** Number of terminated lines seen since construction or the last `reset`. */
  private lineCount: number = 0;

  /**
   * Feeds one transport chunk.
   *
   * On `buffer_overflow` the buffered bytes are discarded and the remainder of
   * the chunk is ignored: the caller must close the connection (design §5.2).
   * Empty lines are dropped; malformed frames are skipped and counted.
   */
  push(chunk: Uint8Array): DecodeResult {
    const frames: object[] = [];
    const errors: FrameError[] = [];
    if (chunk.length === 0) {
      return { frames: frames, errors: errors };
    }
    let index: number = 0;
    while (index < chunk.length) {
      const newlineIndex: number = findByte(chunk, LINE_FEED, index);
      if (newlineIndex < 0) {
        this.appendPending(chunk, index, chunk.length, errors);
        return { frames: frames, errors: errors };
      }
      const segmentLength: number = newlineIndex - index;
      if (this.pendingLength + segmentLength > MAX_FRAME_BYTES) {
        errors.push({ code: 'buffer_overflow', line: this.lineCount + 1 });
        this.reset();
        return { frames: frames, errors: errors };
      }
      const lineBytes: Uint8Array = this.takeLine(chunk, index, segmentLength);
      index = newlineIndex + 1;
      this.lineCount += 1;
      if (lineBytes.length === 0) {
        continue;
      }
      const text: string | null = decodeUtf8(lineBytes);
      if (text === null) {
        errors.push({ code: 'invalid_utf8', line: this.lineCount });
        continue;
      }
      const frame: object | null = parseFrameObject(text);
      if (frame === null) {
        errors.push({ code: 'malformed_frame', line: this.lineCount });
        continue;
      }
      frames.push(frame);
    }
    return { frames: frames, errors: errors };
  }

  /** Drops buffered bytes and resets the line counter for a new connection. */
  reset(): void {
    this.pending = new Uint8Array(0);
    this.pendingLength = 0;
    this.lineCount = 0;
  }

  private appendPending(chunk: Uint8Array, start: number, end: number, errors: FrameError[]): void {
    const length: number = end - start;
    const required: number = this.pendingLength + length;
    if (required > MAX_FRAME_BYTES) {
      errors.push({ code: 'buffer_overflow', line: this.lineCount + 1 });
      this.reset();
      return;
    }
    if (required > this.pending.length) {
      let capacity: number = this.pending.length === 0 ? MIN_PENDING_CAPACITY : this.pending.length;
      while (capacity < required) {
        capacity = capacity * 2;
      }
      if (capacity > MAX_FRAME_BYTES) {
        capacity = MAX_FRAME_BYTES;
      }
      const grown: Uint8Array = new Uint8Array(capacity);
      if (this.pendingLength > 0) {
        grown.set(this.pending.subarray(0, this.pendingLength), 0);
      }
      this.pending = grown;
    }
    this.pending.set(chunk.subarray(start, end), this.pendingLength);
    this.pendingLength = required;
  }

  /**
   * Copies the complete line (pending prefix plus chunk segment) into one view.
   * Returns a subarray of `chunk` when nothing was buffered; the bytes are only
   * read synchronously inside `push`, so retaining the caller's buffer is safe.
   */
  private takeLine(chunk: Uint8Array, start: number, segmentLength: number): Uint8Array {
    if (this.pendingLength === 0) {
      return chunk.subarray(start, start + segmentLength);
    }
    const lineBytes: Uint8Array = new Uint8Array(this.pendingLength + segmentLength);
    lineBytes.set(this.pending.subarray(0, this.pendingLength), 0);
    lineBytes.set(chunk.subarray(start, start + segmentLength), this.pendingLength);
    this.pendingLength = 0;
    return lineBytes;
  }
}

function findByte(bytes: Uint8Array, target: number, from: number): number {
  for (let index: number = from; index < bytes.length; index++) {
    if (bytes[index] === target) {
      return index;
    }
  }
  return -1;
}

/**
 * Parses one line into a frame object.
 * Returns `null` for invalid JSON, JSON scalars/`null` and arrays: the wire
 * contract only allows JSON objects.
 */
function parseFrameObject(text: string): object | null {
  let parsed: JsonPayload = null;
  try {
    parsed = JSON.parse(text) as JsonPayload;
  } catch {
    return null;
  }
  if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
    return null;
  }
  return parsed as object;
}

// ---------------------------------------------------------------------------
// Envelope shape checks (structure only, business fields are not inspected)
// ---------------------------------------------------------------------------

function asEnvelope(value: object): EnvelopeView {
  return value as EnvelopeView;
}

function isPlainObject(value: JsonPayload | undefined): boolean {
  if (value === undefined || value === null) {
    return false;
  }
  if (typeof value !== 'object') {
    return false;
  }
  return !Array.isArray(value);
}

function isNonEmptyString(value: JsonPayload | undefined): boolean {
  return typeof value === 'string' && value.length > 0;
}

function isPushChannel(value: string): boolean {
  return value === 'state' || value === 'event' || value === 'fault';
}

/** `{"id","method","params"?}`; responses and pushes must not match. */
export function isRpcRequest(value: object): boolean {
  const view: EnvelopeView = asEnvelope(value);
  if (!isNonEmptyString(view.id) || !isNonEmptyString(view.method)) {
    return false;
  }
  if (view.params !== undefined && !isPlainObject(view.params)) {
    return false;
  }
  if (view.result !== undefined || view.error !== undefined || view.push !== undefined) {
    return false;
  }
  return view.data === undefined;
}

/** `{"id","result"}` xor `{"id","error":{"code","message"}}`; requires exactly one. */
export function isRpcResponse(value: object): boolean {
  const view: EnvelopeView = asEnvelope(value);
  if (!isNonEmptyString(view.id)) {
    return false;
  }
  if (view.method !== undefined || view.push !== undefined || view.data !== undefined) {
    return false;
  }
  const hasResult: boolean = view.result !== undefined;
  const hasError: boolean = view.error !== undefined;
  if (hasResult === hasError) {
    return false;
  }
  if (hasError) {
    if (!isPlainObject(view.error)) {
      return false;
    }
    const errorView: RpcErrorView = view.error as RpcErrorView;
    if (!isNonEmptyString(errorView.code)) {
      return false;
    }
    if (typeof errorView.message !== 'string') {
      return false;
    }
  }
  return true;
}

/** `{"push":"state"|"event"|"fault","data":{...}}`; `id` must be absent. */
export function isRpcPush(value: object): boolean {
  const view: EnvelopeView = asEnvelope(value);
  if (view.id !== undefined) {
    return false;
  }
  if (typeof view.push !== 'string' || !isPushChannel(view.push)) {
    return false;
  }
  if (!isPlainObject(view.data)) {
    return false;
  }
  return view.method === undefined && view.result === undefined && view.error === undefined;
}