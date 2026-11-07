import { media } from '@kit.MediaKit';
import { MediaAttachment } from '../model/MediaModels';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo, fileUri } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';

const MAX_PHOTO_BYTES: number = 10000000;
const COPY_CHUNK_BYTES: number = 64 * 1024;

class AttachmentFailure extends Error {
  constructor(message: string) { super(message); }
}

/** User-driven, local-only selection. A returned path is not permission to send a message. */
export class AttachmentService {
  private static picking: boolean = false;

  static async pickMedia(context: common.UIAbilityContext): Promise<MediaAttachment[]> {
    if (AttachmentService.picking) { throw new AttachmentFailure('图片选择器已经打开'); }
    AttachmentService.picking = true;
    try {
      const options = new photoAccessHelper.PhotoSelectOptions();
      options.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_VIDEO_TYPE;
      options.maxSelectNumber = 10;
      options.isPhotoTakingSupported = false;
      const mimeFilter = new photoAccessHelper.MimeTypeFilter();
      mimeFilter.mimeTypeArray = ['image/jpeg', 'image/png', 'video/mp4', 'video/quicktime'];
      options.mimeTypeFilter = mimeFilter;
      const picker = new photoAccessHelper.PhotoViewPicker();
      let selected: photoAccessHelper.PhotoSelectResult;
      try {
        selected = await picker.select(options);
      } catch {
        // The official API defines no dedicated cancellation error code. Do not hide real errors.
        throw new AttachmentFailure('无法打开系统相册，请稍后重试');
      }
      if (selected.photoUris.length === 0) { return []; }
      await new Promise<void>((resolve: () => void) => { setTimeout(resolve, 0); });
      const result: MediaAttachment[] = [];
      let currentPath: string = '';
      try {
        for (const uri of selected.photoUris) {
          const path = await AttachmentService.copySelectedImage(context, uri);
          currentPath = path;
          const info = await fileIo.stat(path);
          const video = path.endsWith('.mp4');
          let width: number = 0, height: number = 0, duration: number = 0;
          if (video) {
            const file = await fileIo.open(path, fileIo.OpenMode.READ_ONLY);
            let extractor: media.AVMetadataExtractor | undefined = undefined;
            try {
              extractor = await media.createAVMetadataExtractor();
              extractor.fdSrc = { fd: file.fd, offset: 0, length: info.size };
              const metadata = await extractor.fetchMetadataWithTimeout(10000);
              width = Number(metadata?.videoWidth || 0); height = Number(metadata?.videoHeight || 0);
              duration = Math.ceil(Number(metadata?.duration || 0) / 1000);
              if (![width, height, duration].every((value: number) => Number.isSafeInteger(value) && value > 0 && value <= 2147483647)) { throw new AttachmentFailure('无法读取视频信息，请选择其他视频'); }
            } finally {
              if (extractor) { await extractor.release(); }
              await fileIo.close(file);
            }
          }
          result.push({ path: path, kind: video ? 'video' : 'photo', width: width, height: height, duration: duration, size: info.size });
        }
        return result;
      } catch (error) {
        if (currentPath) { await AttachmentService.removeIncomplete(currentPath, currentPath.slice(0, currentPath.lastIndexOf('/'))); }
        for (const item of result) { await AttachmentService.removeIncomplete(item.path, item.path.slice(0, item.path.lastIndexOf('/'))); }
        throw new AttachmentFailure((error as Error).message || '无法读取附件，请重新选择');
      }
    } finally {
      AttachmentService.picking = false;
    }
  }

  static async saveMedia(context: common.UIAbilityContext, path: string, video: boolean): Promise<boolean> {
    const probe = await fileIo.open(path, fileIo.OpenMode.READ_ONLY);
    let extension: string = '';
    try { extension = AttachmentService.imageExtension(await AttachmentService.readHeader(probe.fd)); }
    finally { await fileIo.close(probe); }
    if (!extension) { throw new AttachmentFailure('暂不支持将此媒体格式保存到相册'); }
    const helper = photoAccessHelper.getPhotoAccessHelper(context);
    let source: fileIo.File | undefined = undefined;
    let destination: fileIo.File | undefined = undefined;
    try {
      const uris = await helper.showAssetsCreationDialog([fileUri.getUriFromPath(path)], [{
        title: 'HmChat-' + Date.now(), fileNameExtension: extension,
        photoType: video ? photoAccessHelper.PhotoType.VIDEO : photoAccessHelper.PhotoType.IMAGE
      }]);
      if (!uris.length) { return false; }
      source = await fileIo.open(path, fileIo.OpenMode.READ_ONLY);
      destination = await fileIo.open(uris[0], fileIo.OpenMode.WRITE_ONLY);
      await fileIo.copyFile(source.fd, destination.fd);
      return true;
    } finally {
      await AttachmentService.closeFile(destination); await AttachmentService.closeFile(source);
      await helper.release();
    }
  }

  private static async copySelectedImage(context: common.UIAbilityContext, uri: string): Promise<string> {
    let source: fileIo.File | undefined = undefined;
    let destination: fileIo.File | undefined = undefined;
    let directory: string = '';
    let path: string = '';
    let complete: boolean = false;
    try {
      source = await fileIo.open(uri, fileIo.OpenMode.READ_ONLY);
      const info = await fileIo.stat(source.fd);
      if (!info.isFile() || info.size <= 0) { throw new AttachmentFailure('所选图片为空或无法读取'); }
      if (info.size > 2000000000) { throw new AttachmentFailure('请选择不超过 2 GB 的视频'); }

      const header = await AttachmentService.readHeader(source.fd);
      const extension = AttachmentService.imageExtension(header);
      if (extension.length === 0) { throw new AttachmentFailure('当前支持 JPEG、PNG 图片与 MP4、MOV 视频'); }
      const limit = extension === 'mp4' ? 2000000000 : MAX_PHOTO_BYTES;
      if (info.size > limit) { throw new AttachmentFailure('图片不能超过 10 MB，视频不能超过 2 GB'); }

      const root = context.cacheDir + '/harlgram-uploads';
      if (!await fileIo.access(root)) { await fileIo.mkdir(root, true); }
      directory = await fileIo.mkdtemp(root + '/image-XXXXXX');
      path = directory + '/image.' + extension;
      destination = await fileIo.open(path, fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE);
      await AttachmentService.writeAll(destination.fd, header.buffer as ArrayBuffer, header.byteLength);
      let copied: number = header.byteLength;
      const chunk = new ArrayBuffer(COPY_CHUNK_BYTES);
      while (true) {
        const count = await fileIo.read(source.fd, chunk);
        if (count === 0) { break; }
        if (copied + count > limit) { throw new AttachmentFailure('请选择不超过 10 MB 的图片'); }
        await AttachmentService.writeAll(destination.fd, chunk, count);
        copied += count;
      }
      if (copied !== info.size) { throw new AttachmentFailure('图片在读取时发生变化，请重新选择'); }
      const cached = await fileIo.stat(destination.fd);
      if (cached.size !== copied || cached.size > limit) {
        throw new AttachmentFailure('图片缓存未能完成，请重新选择');
      }
      complete = true;
    } catch (error) {
      if (error instanceof AttachmentFailure) { throw error; }
      const code = (error as BusinessError).code;
      if (code === 13900025 || code === 13900041) {
        throw new AttachmentFailure('设备存储空间不足，请清理后重试');
      }
      if (code === 13900012 || code === 13900001) {
        throw new AttachmentFailure('图片读取授权已失效，请重新选择');
      }
      throw new AttachmentFailure('无法读取所选图片，请重新选择');
    } finally {
      const destinationClosed = await AttachmentService.closeFile(destination);
      const sourceClosed = await AttachmentService.closeFile(source);
      if (!complete || !destinationClosed || !sourceClosed) {
        await AttachmentService.removeIncomplete(path, directory);
      }
      if (complete && (!destinationClosed || !sourceClosed)) {
        throw new AttachmentFailure('图片缓存未能完成，请重新选择');
      }
    }
    return path;
  }

  private static async readHeader(fd: number): Promise<Uint8Array> {
    const header = new Uint8Array(16);
    let used: number = 0;
    while (used < header.byteLength) {
      const buffer = new ArrayBuffer(header.byteLength - used);
      const count = await fileIo.read(fd, buffer);
      if (count === 0) { break; }
      header.set(new Uint8Array(buffer, 0, count), used);
      used += count;
    }
    return header.subarray(0, used);
  }

  private static imageExtension(header: Uint8Array): string {
    if (header.length >= 3 && header[0] === 0xff && header[1] === 0xd8 && header[2] === 0xff) { return 'jpg'; }
    if (header.length >= 8 && header[0] === 0x89 && header[1] === 0x50 && header[2] === 0x4e &&
      header[3] === 0x47 && header[4] === 0x0d && header[5] === 0x0a && header[6] === 0x1a && header[7] === 0x0a) {
      return 'png';
    }
    if (header.length >= 12 && header[4] === 0x66 && header[5] === 0x74 && header[6] === 0x79 && header[7] === 0x70) { return 'mp4'; }
    return '';
  }

  private static async writeAll(fd: number, buffer: ArrayBuffer, length: number): Promise<void> {
    let written: number = 0;
    while (written < length) {
      const count = await fileIo.write(fd, buffer.slice(written, length));
      if (count <= 0) { throw new AttachmentFailure('图片缓存未能完成，请重新选择'); }
      written += count;
    }
  }

  private static async closeFile(file: fileIo.File | undefined): Promise<boolean> {
    if (!file) { return true; }
    try { await fileIo.close(file); return true; } catch { return false; }
  }

  private static async removeIncomplete(path: string, directory: string): Promise<void> {
    if (path.length > 0) { try { await fileIo.unlink(path); } catch {} }
    if (directory.length > 0) { try { await fileIo.rmdir(directory); } catch {} }
  }
}
