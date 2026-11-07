/**
 * T-S1-17 RPC 分帧单元测试（设计 §5.2）。
 *
 * 覆盖任务卡：单块多帧、跨块半帧、emoji 被切成 2 字节/4 字节两段、
 * 1 MiB 恰好通过、1 MiB+1 失败、无换行大帧、空行忽略、reset() 后可复用。
 * 只覆盖 Uint8Array 契约（Node Buffer 语义不参与断言）。
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const {
  MAX_FRAME_BYTES,
  encodeFrame,
  FrameDecoder,
  isRpcRequest,
  isRpcResponse,
  isRpcPush,
} = require('../../artifacts/tests/js/services/clash/ClashRpcProtocol.js');

const encoder = new TextEncoder();
const LINE_FEED = 0x0a;

function bytesOf(text) {
  return encoder.encode(text);
}

function concatBytes(...parts) {
  const total = parts.reduce((sum, part) => sum + part.length, 0);
  const out = new Uint8Array(total);
  let offset = 0;
  for (const part of parts) {
    out.set(part, offset);
    offset += part.length;
  }
  return out;
}

/** 找到某个字节值第一次出现的位置；不存在返回 -1。 */
function indexOfByte(bytes, target) {
  for (let index = 0; index < bytes.length; index += 1) {
    if (bytes[index] === target) {
      return index;
    }
  }
  return -1;
}

/** 构造恰好 `payloadBytes` 字节的 JSON 文本：`{"d":"aaa..."}`。 */
function payloadOfLength(payloadBytes) {
  return JSON.stringify({ d: 'a'.repeat(payloadBytes - 8) });
}

test('单帧上限常量为 1 MiB', () => {
  assert.equal(MAX_FRAME_BYTES, 1048576);
});

test('encodeFrame 输出以单个 LF 结尾并可还原对象', () => {
  const frame = encodeFrame({ id: 'u-00000000-1', method: 'hello', params: { v: '节点-a 😀' } });
  assert.equal(frame[frame.length - 1], LINE_FEED);
  assert.equal(frame.indexOf(LINE_FEED), frame.length - 1);
  const text = new TextDecoder().decode(frame.subarray(0, frame.length - 1));
  assert.deepEqual(JSON.parse(text), { id: 'u-00000000-1', method: 'hello', params: { v: '节点-a 😀' } });
});

test('encodeFrame 对循环引用、BigInt 与抛错的 toJSON 返回 encode_failed', () => {
  const circular = {};
  circular.self = circular;
  assert.throws(() => encodeFrame(circular), { message: 'encode_failed' });
  assert.throws(() => encodeFrame({ n: 1n }), { message: 'encode_failed' });
  assert.throws(() => encodeFrame({ toJSON() { throw new Error('fixture'); } }), { message: 'encode_failed' });
});

test('编码边界：载荷 limit-1 通过，limit 与 limit+1 均拒绝', () => {
  // JSON 文本长度 = 载荷字节数（ASCII 夹具）。
  const belowText = payloadOfLength(MAX_FRAME_BYTES - 1);
  assert.equal(belowText.length, MAX_FRAME_BYTES - 1);
  const below = encodeFrame(JSON.parse(belowText));
  assert.equal(below.length, MAX_FRAME_BYTES);

  const exactText = payloadOfLength(MAX_FRAME_BYTES);
  assert.equal(exactText.length, MAX_FRAME_BYTES);
  assert.throws(() => encodeFrame(JSON.parse(exactText)), { message: 'frame_too_large' });

  const aboveText = payloadOfLength(MAX_FRAME_BYTES + 1);
  assert.equal(aboveText.length, MAX_FRAME_BYTES + 1);
  assert.throws(() => encodeFrame(JSON.parse(aboveText)), { message: 'frame_too_large' });
});

test('单块多帧：一次 push 解析出全部完整帧并保持线上顺序', () => {
  const decoder = new FrameDecoder();
  const chunk = concatBytes(encodeFrame({ id: 'a' }), encodeFrame({ id: 'b' }), encodeFrame({ id: 'c' }));
  const result = decoder.push(chunk);
  assert.deepEqual(result.frames, [{ id: 'a' }, { id: 'b' }, { id: 'c' }]);
  assert.deepEqual(result.errors, []);
});

test('跨块半帧：无换行的前半段被缓冲，后半段到达后才产出帧', () => {
  const decoder = new FrameDecoder();
  const frame = encodeFrame({ id: 'u-00000000-7', result: { value: 1 } });
  const split = Math.floor(frame.length / 2);
  const first = decoder.push(frame.subarray(0, split));
  assert.deepEqual(first.frames, []);
  assert.deepEqual(first.errors, []);
  // 空块不改变缓冲状态。
  assert.deepEqual(decoder.push(new Uint8Array(0)), { frames: [], errors: [] });
  const second = decoder.push(frame.subarray(split));
  assert.deepEqual(second.frames, [{ id: 'u-00000000-7', result: { value: 1 } }]);
  assert.deepEqual(second.errors, []);
});

test('4 字节 emoji 被切成 2+2 字节两段仍能正确解码', () => {
  const decoder = new FrameDecoder();
  const frame = encodeFrame({ v: '😀' });
  const start = indexOfByte(frame, 0xf0);
  assert.notEqual(start, -1);
  const first = decoder.push(frame.subarray(0, start + 2));
  assert.deepEqual(first.frames, []);
  const second = decoder.push(frame.subarray(start + 2));
  assert.deepEqual(second.frames, [{ v: '😀' }]);
  assert.deepEqual(second.errors, []);
});

test('2 字节字符被切成 1+1 字节两段仍能正确解码', () => {
  const decoder = new FrameDecoder();
  const frame = encodeFrame({ v: 'é' });
  const start = indexOfByte(frame, 0xc3);
  assert.notEqual(start, -1);
  assert.equal(decoder.push(frame.subarray(0, start + 1)).frames.length, 0);
  assert.deepEqual(decoder.push(frame.subarray(start + 1)).frames, [{ v: 'é' }]);
});

test('空行被忽略，不产生帧也不产生错误', () => {
  const decoder = new FrameDecoder();
  const result = decoder.push(bytesOf('\n\n{"a":1}\n\n'));
  assert.deepEqual(result.frames, [{ a: 1 }]);
  assert.deepEqual(result.errors, []);
  assert.deepEqual(decoder.push(bytesOf('\n\n')), { frames: [], errors: [] });
});

test('reset() 丢弃半帧并重置行号，可复用同一解码器', () => {
  const decoder = new FrameDecoder();
  const frame = encodeFrame({ id: 'reused' });
  decoder.push(frame.subarray(0, 10));
  decoder.reset();
  // 残留半帧已被丢弃，新帧独立解码。
  const result = decoder.push(frame);
  assert.deepEqual(result.frames, [{ id: 'reused' }]);
  assert.deepEqual(result.errors, []);

  // 完整帧已占用第 1 行，下一行是第 2 行；reset 后行号重新从 1 开始。
  assert.equal(decoder.push(bytesOf('bad\n')).errors[0].line, 2);
  decoder.reset();
  assert.equal(decoder.push(bytesOf('bad\n')).errors[0].line, 1);
});

test('结构错误按行计数：非法 UTF-8、非法 JSON、数组与标量', () => {
  const decoder = new FrameDecoder();
  const invalidUtf8 = new Uint8Array([0x61, 0xff, LINE_FEED]);
  const result = decoder.push(invalidUtf8);
  assert.deepEqual(result.errors, [{ code: 'invalid_utf8', line: 1 }]);
  assert.deepEqual(result.frames, []);

  const mixed = decoder.push(bytesOf('not json\n{"ok":1}\n[1]\n1\nnull\n'));
  assert.deepEqual(mixed.frames, [{ ok: 1 }]);
  // 行号：2 非法 JSON、4 数组、5 标量、6 null；合法帧在第 3 行。
  assert.deepEqual(mixed.errors, [
    { code: 'malformed_frame', line: 2 },
    { code: 'malformed_frame', line: 4 },
    { code: 'malformed_frame', line: 5 },
    { code: 'malformed_frame', line: 6 },
  ]);
});

test('1 MiB 行恰好通过，1 MiB+1 的未成帧缓冲触发 buffer_overflow', () => {
  const exact = payloadOfLength(MAX_FRAME_BYTES);
  assert.equal(exact.length, MAX_FRAME_BYTES);
  const decoder = new FrameDecoder();
  const accepted = decoder.push(concatBytes(bytesOf(exact), new Uint8Array([LINE_FEED])));
  assert.equal(accepted.errors.length, 0);
  assert.equal(accepted.frames.length, 1);

  const tooBig = payloadOfLength(MAX_FRAME_BYTES + 1);
  assert.equal(tooBig.length, MAX_FRAME_BYTES + 1);
  const over = new FrameDecoder().push(concatBytes(bytesOf(tooBig), new Uint8Array([LINE_FEED])));
  assert.deepEqual(over.frames, []);
  assert.deepEqual(over.errors, [{ code: 'buffer_overflow', line: 1 }]);
});

test('无换行大帧超过上限立即报错并丢弃缓冲，同块剩余字节不再解析', () => {
  const decoder = new FrameDecoder();
  const oversized = new Uint8Array(MAX_FRAME_BYTES + 1).fill(0x61);
  const valid = encodeFrame({ id: 'after-overflow' });
  const result = decoder.push(concatBytes(oversized, valid));
  assert.deepEqual(result.frames, []);
  assert.deepEqual(result.errors, [{ code: 'buffer_overflow', line: 1 }]);
  // 溢出已重置，下一块可正常解码。
  assert.deepEqual(decoder.push(valid).frames, [{ id: 'after-overflow' }]);
});

test('RPC 信封结构检查：请求、响应与推送互斥', () => {
  assert.equal(isRpcRequest({ id: 'u-abc-1', method: 'hello' }), true);
  assert.equal(isRpcRequest({ id: 'u-abc-1', method: 'core.action', params: {} }), true);
  assert.equal(isRpcRequest({ id: 'u-abc-1', method: 'hello', params: [] }), false);
  assert.equal(isRpcRequest({ id: 'u-abc-1', method: 'hello', result: {} }), false);
  assert.equal(isRpcRequest({ method: 'hello' }), false);

  assert.equal(isRpcResponse({ id: 'u-abc-1', result: null }), true);
  assert.equal(isRpcResponse({ id: 'u-abc-1', error: { code: 'auth_failed', message: '' } }), true);
  assert.equal(isRpcResponse({ id: 'u-abc-1', error: { code: 'auth_failed' } }), false);
  assert.equal(isRpcResponse({ id: 'u-abc-1', result: {}, error: { code: 'x', message: 'y' } }), false);
  assert.equal(isRpcResponse({ id: 'u-abc-1' }), false);
  assert.equal(isRpcResponse({ id: 'u-abc-1', result: {}, method: 'hello' }), false);

  assert.equal(isRpcPush({ push: 'state', data: {} }), true);
  assert.equal(isRpcPush({ push: 'fault', data: { code: 'x' } }), true);
  assert.equal(isRpcPush({ id: 'u-abc-1', push: 'state', data: {} }), false);
  assert.equal(isRpcPush({ push: 'bogus', data: {} }), false);
  assert.equal(isRpcPush({ push: 'state', data: [] }), false);
  assert.equal(isRpcPush({ push: 'state' }), false);
});