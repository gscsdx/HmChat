/** Byte ranges are checked against TDLib's contiguous-prefix query, never sparse-file length. */
export interface VideoRangeState { path: string; size: number; downloaded: number; complete: boolean; }
export interface VideoWindow { offset: number; limit: number; }
export interface VideoRangeTransport {
  state(): VideoRangeState;
  prefix(offset: number): Promise<number>;
  download(window: VideoWindow): Promise<void>;
  read(path: string, offset: number, length: number): Promise<ArrayBuffer>;
  current(): boolean;
  cancel(): void;
}
export const VIDEO_CHUNK = 64 * 1024;
export const VIDEO_WINDOW = 2 * 1024 * 1024;
export const VIDEO_SPEEDS: number[] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2];
export function seekPosition(value: number, duration: number): number {
  return Number.isFinite(value) && Number.isFinite(duration) ? Math.floor(Math.max(0, Math.min(value, Math.max(0, duration - 1)))) : 0;
}
export function videoWindow(offset: number, size: number): VideoWindow {
  if (!Number.isSafeInteger(offset) || !Number.isSafeInteger(size) || offset < 0 || offset >= size) { throw new Error('无效的视频读取范围'); }
  const aligned = Math.floor(offset / (128 * 1024)) * (128 * 1024);
  return { offset: aligned, limit: Math.min(VIDEO_WINDOW, size - aligned) };
}
export class VideoRangeReader {
  private closed = false;
  private window: VideoWindow = { offset: -1, limit: 0 };
  constructor(private transport: VideoRangeTransport, private wait: () => Promise<void> = () => new Promise<void>(resolve => setTimeout(resolve, 120))) {}
  state(): VideoRangeState { return this.transport.state(); }
  close(): void { if (!this.closed) { this.closed = true; if (this.transport.current()) { this.transport.cancel(); } } }
  private check(live: () => boolean): void {
    if (this.closed || !this.transport.current() || !live()) { throw new Error('视频读取已取消'); }
  }
  async read(offset: number, length: number, live: () => boolean): Promise<ArrayBuffer> {
    this.check(live); const initial = this.transport.state();
    if (!Number.isSafeInteger(offset) || offset < 0 || offset > initial.size || !Number.isSafeInteger(length) || length <= 0) { throw new Error('无效的视频读取范围'); }
    if (offset === initial.size) { return new ArrayBuffer(0); }
    const deadline = Date.now() + 30000;
    while (Date.now() < deadline) {
      this.check(live);
      const state = this.transport.state();
      const available = state.complete ? state.size - offset : await this.transport.prefix(offset);
      this.check(live);
      if (available > 0 && state.path) {
        const amount = Math.min(length, VIDEO_CHUNK, available, state.size - offset);
        const latest = this.transport.state();
        const buffer = await this.transport.read(latest.path || state.path, offset, amount); this.check(live);
        if (buffer.byteLength === 0) { throw new Error('视频缓存暂不可读，请重试'); }
        return buffer;
      }
      if (offset < this.window.offset || offset >= this.window.offset + this.window.limit) {
        this.window = videoWindow(offset, state.size); await this.transport.download(this.window); this.check(live);
      }
      await this.wait();
    }
    throw new Error('视频缓冲超时，请检查网络后重试');
  }
}
/** Native seek is asynchronous: run one request, coalesce intervening gestures to the latest target. */
export class VideoSeekQueue {
  private active: number | undefined = undefined;
  private queued: number | undefined = undefined;
  request(target: number): number | undefined {
    if (this.active === undefined) { this.active = target; return target; }
    this.queued = target; return undefined;
  }
  complete(): number | undefined {
    const next = this.queued; this.queued = undefined;
    if (next !== undefined && next !== this.active) { this.active = next; return next; }
    this.active = undefined; return undefined;
  }
  pending(): boolean { return this.active !== undefined; }
  reset(): void { this.active = undefined; this.queued = undefined; }
}
export interface VideoHttpRange { start: number; end: number; partial: boolean; }
export function videoHttpRange(value: string, size: number): VideoHttpRange | undefined {
  if (!Number.isSafeInteger(size) || size <= 0) { return undefined; }
  if (!value) { return { start: 0, end: size - 1, partial: false }; }
  const match = /^bytes=(\d*)-(\d*)$/i.exec(value.trim());
  if (!match || (!match[1] && !match[2])) { return undefined; }
  let start: number, end: number;
  if (!match[1]) {
    const suffix = Number(match[2]); if (!Number.isSafeInteger(suffix) || suffix <= 0) { return undefined; }
    start = Math.max(0, size - suffix); end = size - 1;
  } else {
    start = Number(match[1]); end = match[2] ? Number(match[2]) : size - 1;
    if (!Number.isSafeInteger(start) || !Number.isSafeInteger(end) || start >= size || start > end) { return undefined; }
    end = Math.min(end, size - 1);
  }
  return { start: start, end: end, partial: true };
}
