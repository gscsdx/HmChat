import { BusinessError } from '@kit.BasicServicesKit';
import { socket } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { VideoRangeReader, videoHttpRange, VIDEO_CHUNK } from '../model/VideoPlayback';
interface VideoConnection { socket: socket.TCPSocketConnection; header: string; busy: boolean; live: boolean; timer: number; }

/** Ephemeral loopback-only, unguessable per-viewer route. Only one authorized TDLib video can be served. */
export class VideoHttpStream {
  private reader: VideoRangeReader;
  private failed: (message: string) => void;
  private server: socket.TCPSocketServer | undefined = undefined;
  private clients: Map<number, VideoConnection> = new Map<number, VideoConnection>();
  private route: string = '/' + util.generateRandomUUID(false) + '/video.mp4';
  private stopped: boolean = false;
  constructor(reader: VideoRangeReader, failed: (message: string) => void) { this.reader = reader; this.failed = failed; }
  async open(): Promise<string> {
    const server = socket.constructTCPSocketServerInstance(); this.server = server;
    server.on('connect', (connection: socket.TCPSocketConnection) => this.accept(connection));
    server.on('error', () => { if (!this.stopped) { this.failed('视频缓冲通道不可用，请重试'); } });
    await server.listen({ address: '127.0.0.1', port: 0, family: 1 });
    const address = await server.getLocalAddress();
    if (this.stopped) { await server.close(); throw new Error('视频已关闭'); }
    return 'http://127.0.0.1:' + address.port + this.route;
  }
  downloaded(): number { return this.reader.state().downloaded; }
  size(): number { return this.reader.state().size; }
  private accept(connection: socket.TCPSocketConnection): void {
    if (this.stopped || this.clients.size >= 4) { connection.close().catch(() => {}); return; }
    const item: VideoConnection = { socket: connection, header: '', busy: false, live: true, timer: -1 };
    this.clients.set(connection.clientId, item);
    item.timer = setTimeout(() => this.drop(item), 8000);
    connection.on('close', () => this.drop(item));
    connection.on('error', () => this.drop(item));
    connection.on('message', (info: socket.SocketMessageInfo) => {
      if (!item.live || item.busy) { return; }
      for (const byte of new Uint8Array(info.message)) { item.header += String.fromCharCode(byte); }
      if (item.header.length > 8192) { this.drop(item); return; }
      if (item.header.includes('\r\n\r\n')) {
        item.busy = true; clearTimeout(item.timer); item.timer = -1;
        this.serve(item).catch((error: Error) => {
          if (item.live && !this.stopped) { console.info('HarlgramVideo rangeFailed kind=' + error.name + ' code=' + (error as BusinessError).code + ' timeout=' + error.message.includes('超时')); this.drop(item);
            this.failed(error.message.includes('超时') ? '视频缓冲超时，请检查网络后重试' : '视频缓冲失败，请重试'); }
        });
      }
    });
  }
  private drop(item: VideoConnection): void {
    if (!item.live) { return; } item.live = false;
    if (item.timer >= 0) { clearTimeout(item.timer); item.timer = -1; }
    this.clients.delete(item.socket.clientId);
    try { item.socket.off('message'); item.socket.off('close'); item.socket.off('error'); } catch (_) {}
    item.socket.close().catch(() => {});
  }
  private async send(item: VideoConnection, data: string | ArrayBuffer): Promise<boolean> {
    if (!item.live || this.stopped) { return false; }
    try { await item.socket.send({ data: data }); return item.live; } catch (_) { this.drop(item); return false; }
  }
  private async reject(item: VideoConnection, status: string, extra: string = ''): Promise<void> {
    await this.send(item, 'HTTP/1.1 ' + status + '\r\nContent-Length: 0\r\nConnection: close\r\n' + extra + '\r\n'); this.drop(item);
  }
  private async serve(item: VideoConnection): Promise<void> {
    const lines = item.header.split('\r\n'), first = lines[0].split(' ');
    if (first.length !== 3 || first[2] !== 'HTTP/1.1' && first[2] !== 'HTTP/1.0') { await this.reject(item, '400 Bad Request'); return; }
    if (first[0] !== 'GET' && first[0] !== 'HEAD') { await this.reject(item, '405 Method Not Allowed'); return; }
    if (first[1] !== this.route) { await this.reject(item, '404 Not Found'); return; }
    let range: string = '', hasRange: boolean = false;
    for (const line of lines.slice(1)) {
      const colon = line.indexOf(':');
      if (colon > 0 && line.slice(0, colon).trim().toLowerCase() === 'range') {
        if (hasRange) { await this.reject(item, '400 Bad Request'); return; }
        range = line.slice(colon + 1).trim(); hasRange = true;
      }
    }
    const size = this.reader.state().size, selected = videoHttpRange(range, size);
    if (!selected || hasRange && !range) { await this.reject(item, '416 Range Not Satisfiable', 'Content-Range: bytes */' + size + '\r\n'); return; }
    // A fresh GET replaces an old prefetch/seek connection; do not keep competing download offsets alive.
    if (first[0] === 'GET') { this.clients.forEach((other: VideoConnection) => { if (other !== item && other.busy) { this.drop(other); } }); }
    console.info('HarlgramVideo httpRange offset=' + selected.start + ' end=' + selected.end);
    const headers = 'HTTP/1.1 ' + (selected.partial ? '206 Partial Content' : '200 OK') + '\r\n' +
      'Content-Type: video/mp4\r\nAccept-Ranges: bytes\r\nContent-Length: ' + (selected.end - selected.start + 1) + '\r\n' +
      (selected.partial ? 'Content-Range: bytes ' + selected.start + '-' + selected.end + '/' + size + '\r\n' : '') +
      'Cache-Control: no-store\r\nConnection: close\r\n\r\n';
    if (!await this.send(item, headers)) { return; }
    if (first[0] === 'HEAD') { this.drop(item); return; }
    const live = (): boolean => item.live && !this.stopped;
    let offset = selected.start;
    while (live() && offset <= selected.end) {
      const data = await this.reader.read(offset, Math.min(VIDEO_CHUNK, selected.end - offset + 1), live);
      if (!live()) { return; }
      if (!await this.send(item, data)) { return; } offset += data.byteLength;
    }
    this.drop(item);
  }
  close(): void {
    if (this.stopped) { return; } this.stopped = true;
    this.clients.forEach((item: VideoConnection) => this.drop(item)); this.reader.close();
    const server = this.server; this.server = undefined;
    try { server?.off('connect'); server?.off('error'); } catch (_) {}
    server?.close().catch(() => {});
  }
}
