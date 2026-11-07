/**
 * ArkTS facade over the NDJSON framing implemented in `ClashRpcProtocol.ts`
 * (design §5.2, task T-S2-01).
 *
 * The byte-level UTF-8 codec, line splitting and frame limits stay in the pure
 * TypeScript module so the host test suite can import them unchanged; this file
 * only exposes them to ArkTS callers with explicit types.
 *
 * Why the `Bridge` suffix: the ArkTS compiler warns when an `.ets` and a `.ts`
 * share a basename ("Duplicate file names detected, which may cause compilation
 * errors"). The SDK build confirmed that warning for a same-named
 * `ClashRpcProtocol.ets`; this file therefore carries a distinct name while the
 * implementation keeps its path used by host tests.
 *
 * This module performs no I/O and imports no HarmonyOS Kit; the RPC client and
 * server decide how bytes reach it.
 */

import {
  DecodeResult,
  FrameDecoder,
  FrameError,
  encodeFrame,
  ERROR_FRAME_TOO_LARGE
} from './ClashRpcProtocol';

/** Single frame limit (1 MiB), re-exported so callers never restate the value. */
export { MAX_FRAME_BYTES, MAX_FRAME_BYTES as RPC_MAX_FRAME_BYTES } from './ClashRpcProtocol';

/** Protocol version from the shared model; the `.ts` frame limit originates there too. */
export { RPC_PROTO } from '../../model/ClashModels';

/**
 * Every structural frame failure the RPC layer surfaces.
 *
 * `frame_too_large` is produced by the encoder before any byte is written;
 * the other three come from the decoder and match `FrameErrorCode` in the
 * `.ts` module.
 */
export type RpcFrameErrorCode =
  | 'frame_too_large'
  | 'malformed_frame'
  | 'buffer_overflow'
  | 'invalid_utf8';

/**
 * Structured frame failure. Callers branch on `code`, never on free-form text.
 * `line` is the 1-based wire line for decode errors and 0 for encode errors,
 * which fail before a line exists. Frame content is never retained.
 */
export interface RpcFrameError {
  code: RpcFrameErrorCode;
  line: number;
}

/** Frames decoded from one transport chunk, plus the structural errors seen. */
export interface RpcDecodeResult {
  frames: object[];
  errors: RpcFrameError[];
}

/**
 * Carries a structured `RpcFrameError` out of APIs whose success type is bytes.
 * Extends `Error` so ordinary `catch` blocks still observe it.
 */
export class RpcFrameException extends Error {
  readonly error: RpcFrameError;

  constructor(error: RpcFrameError) {
    super(error.code);
    this.error = error;
  }
}

/**
 * Serializes one RPC envelope and terminates it with `0x0A`.
 *
 * Throws `RpcFrameException` with `frame_too_large` when the encoded frame
 * exceeds the shared limit, and with `malformed_frame` when the envelope cannot
 * be serialized at all (circular value, unpaired surrogate, throwing `toJSON`).
 * The `.ts` implementation reports the second case as `encode_failed`; the RPC
 * contract has no such code, so it maps to `malformed_frame`.
 */
export function encodeRequest(request: object): Uint8Array {
  try {
    return encodeFrame(request);
  } catch (error) {
    throw new RpcFrameException(classifyEncodeFailure(error as Error));
  }
}

/**
 * One framing state per RPC connection.
 *
 * The decoder buffers a partial line across transport chunks (design §5.2), so
 * a module-level singleton would mix bytes from concurrent connections; the
 * server accepts up to four. Callers create one framer per socket and call
 * `reset()` if the socket is reused for a new session.
 */
export class RpcFramer {
  private readonly decoder: FrameDecoder = new FrameDecoder();

  /** Convenience so a connection owns both directions through one object. */
  encodeRequest(request: object): Uint8Array {
    return encodeRequest(request);
  }

  /** Feeds one transport chunk; never throws for malformed input. */
  decodeChunk(chunk: Uint8Array): RpcDecodeResult {
    return toRpcDecodeResult(this.decoder.push(chunk));
  }

  /** Drops buffered bytes and the line counter when a new session starts. */
  reset(): void {
    this.decoder.reset();
  }
}

function classifyEncodeFailure(error: Error): RpcFrameError {
  const code: RpcFrameErrorCode =
    error.message === ERROR_FRAME_TOO_LARGE ? 'frame_too_large' : 'malformed_frame';
  const failure: RpcFrameError = { code: code, line: 0 };
  return failure;
}

function toRpcDecodeResult(result: DecodeResult): RpcDecodeResult {
  const errors: RpcFrameError[] = [];
  for (let index: number = 0; index < result.errors.length; index++) {
    const source: FrameError = result.errors[index];
    const mapped: RpcFrameError = { code: source.code, line: source.line };
    errors.push(mapped);
  }
  const decoded: RpcDecodeResult = { frames: result.frames, errors: errors };
  return decoded;
}