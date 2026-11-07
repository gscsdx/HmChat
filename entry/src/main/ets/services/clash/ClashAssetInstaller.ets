/**
 * Clash geo 资产首次部署（设计 §10.6，任务 T-S2-10）。
 *
 * 目标：在 `<filesDir>` 根准备内核固定查找的四个文件（`core/constant/path.go`）：
 * `GeoIP.dat`、`GeoSite.dat`、`geoip.metadb`、`ASN.mmdb`，数据来自随 HAP 分发的
 * rawfile，首次启动时复制，避免内核在 `geo-auto-update=false` 时尝试联网下载。
 *
 * 行为：
 * - 已存在且与 `<filesDir>/proxy/geo.json` 记录的 SHA-256/大小一致时跳过；
 *   校验按固定顺序对四个文件做一次合并 SHA-256，不依赖文件名拼接。
 * - 否则从 `rawfile/clash/geo/`（兼容 `rawfile/clash/`）按 ≤1 MB 分块读取/写入，
 *   每块后让出事件循环；先写临时文件、`fsync`，全部成功后再逐个重命名，
 *   避免在 home 根留下半截 geo 文件。
 * - 整个流程（含校验、复制、元数据写入）总超时 90 s；进度回调固定上报
 *   「正在准备代理数据」。
 * - `<filesDir>/proxy/geo.json` 只写 `{version, sha256, size, copiedAt}`，
 *   不含任何绝对路径、订阅信息或账号数据。
 *
 * 失败语义（设计 §10.6）：任何缺失/失败都返回 `ok=false`，调用方必须放弃
 * `core.init`/TUN，不得在没有 geo 的情况下假装规则可用。
 * `model/ClashError.ts` 的权威码表没有 `geo_missing`，因此这里按约定返回已有的
 * `config_missing`，并用 `reason` 区分真实原因；待码表正式增加 `geo_missing`
 * 时只需替换 `GEO_FAILURE_CODE`。
 *
 * 约束：不引用聊天服务或媒体网络监控模块；不使用 ArkTS 禁止的动态类型与枚举；
 * 文件名全部来自本模块的静态白名单，不接受调用方传入路径。
 */

import { common } from '@kit.AbilityKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { fileIo } from '@kit.CoreFileKit';
import { resourceManager } from '@kit.LocalizationKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { util } from '@kit.ArkTS';
import { ProxyErrorCode } from '../../model/ClashError';

/** 内核在 home 根查找的固定文件名；顺序同时用于合并哈希。 */
export const CLASH_GEO_FILE_NAMES: string[] = ['GeoIP.dat', 'GeoSite.dat', 'geoip.metadb', 'ASN.mmdb'];
/** 当前随包分发的 geo 数据集版本；替换 rawfile 时同步递增。 */
export const CLASH_GEO_VERSION: string = 'harlgram-bundled-v1';
/** 部署期间唯一对用户可见的阶段文案（设计 §10.6）。 */
export const CLASH_GEO_PROGRESS_LABEL: string = '正在准备代理数据';
/** 首次部署总超时（含哈希校验与元数据写入）。 */
export const CLASH_GEO_TOTAL_TIMEOUT_MS: number = 90000;

const CHUNK_BYTES: number = 1048576;
const RAW_GEO_DIR: string = 'clash/geo';
const RAW_GEO_FALLBACK_DIR: string = 'clash';
const METADATA_DIR: string = 'proxy';
const METADATA_FILE: string = 'geo.json';
const METADATA_TEMP_FILE: string = '.geo.json.tmp';
const TEMP_PREFIX: string = '.geo-';
const TEMP_SUFFIX: string = '.tmp';

const MAX_METADATA_BYTES: number = 4096;
const MAX_VERSION_LENGTH: number = 64;
const MAX_COPIED_AT_LENGTH: number = 40;
const HASH_HEX_LENGTH: number = 64;
const SHA256_ALGORITHM: string = 'SHA256';
const HASH_PATTERN: RegExp = /^[a-f0-9]{64}$/;

const LOG_DOMAIN: number = 0x0000;
const LOG_TAG: string = 'HarlgramProxyGeo';

/**
 * 失败的真实原因；`errorCode` 统一映射到 `config_missing`。
 * - `path_unavailable`：filesDir 不可用；
 * - `rawfile_missing`：至少一个 rawfile 不在安装包里（`missingRawFiles` 列出）；
 * - `copy_failed`：读取/写入/重命名失败；
 * - `metadata_failed`：`proxy/geo.json` 无法写入；
 * - `timeout`：超过 90 s 总超时。
 */
export type ClashGeoFailureReason =
  | 'path_unavailable'
  | 'rawfile_missing'
  | 'copy_failed'
  | 'metadata_failed'
  | 'timeout';

/** 进度阶段：准备中 / 已可用。 */
export type ClashGeoStage = 'preparing' | 'completed';

/** 部署进度；不包含绝对路径、文件名只在复制阶段出现固定白名单值。 */
export interface ClashGeoProgress {
  stage: ClashGeoStage;
  label: string;
  fileName: string;
  fileIndex: number;
  fileCount: number;
  copiedBytes: number;
  totalBytes: number;
}

/** 进度监听器；实现方应保持轻量，异常会被吞掉且不影响安装。 */
export type ClashGeoProgressListener = (progress: ClashGeoProgress) => void;

/** 部署结果；`ok=false` 时调用方不得启动内核。 */
export interface ClashGeoInstallResult {
  ok: boolean;
  /** 失败码；码表无 `geo_missing`，统一为 `config_missing`。 */
  errorCode?: ProxyErrorCode;
  /** 真实失败原因，仅用于诊断；不面向用户展示原始内容。 */
  reason?: ClashGeoFailureReason;
  /** true 表示已存在且哈希一致，未发生复制。 */
  skipped: boolean;
  /** 四个文件的总字节数（成功时为实际落盘大小）。 */
  totalBytes: number;
  /** 合并 SHA-256（小写十六进制）；失败时为空串。 */
  sha256: string;
  /** rawfile 中缺失的文件名（按白名单顺序），用于诊断与日志。 */
  missingRawFiles: string[];
  /** 本次实际复制的文件名。 */
  copiedFiles: string[];
}

/** geo.json 落盘结构；字段固定，不含路径。 */
interface ClashGeoMetadata {
  version: string;
  sha256: string;
  size: number;
  copiedAt: string;
}

interface ClashGeoRawSource {
  name: string;
  rawPath: string;
  length: number;
}

interface ClashGeoInstalledState {
  matched: boolean;
  timedOut: boolean;
  size: number;
  sha256: string;
}

interface ClashGeoHashOutcome {
  ok: boolean;
  timedOut: boolean;
  size: number;
  sha256: string;
}

interface ClashGeoCopyOutcome {
  ok: boolean;
  timedOut: boolean;
  bytes: number;
}

type ClashGeoWriteOutcome = 'ok' | 'timeout' | 'failed';

/** 权威码表暂无 `geo_missing`；按任务约定退回已有的 `config_missing`。 */
const GEO_FAILURE_CODE: ProxyErrorCode = 'config_missing';

/**
 * 单实例部署器：每个沙箱（UI 进程或 VPN 扩展进程，二者 filesDir 相同）各构造一次。
 * 并发调用会共享同一次部署结果，避免重复复制和重命名竞争。
 */
export class ClashAssetInstaller {
  private readonly context: common.Context;
  private readonly homeDir: string;
  private pending: Promise<ClashGeoInstallResult> | undefined = undefined;

  constructor(context: common.Context) {
    this.context = context;
    this.homeDir = normalizeRoot(context.filesDir);
  }

  /**
   * 确保四个 geo 文件可用。
   *
   * `onProgress` 只上报「正在准备代理数据」及各阶段字节数；回调抛错不会中断安装。
   * 返回值永不抛异常：调用方只需检查 `ok`。
   */
  async ensureInstalled(onProgress?: ClashGeoProgressListener): Promise<ClashGeoInstallResult> {
    if (this.pending !== undefined) {
      return this.pending;
    }
    const task: Promise<ClashGeoInstallResult> = this.install(onProgress);
    this.pending = task;
    task.then((): void => {
      this.pending = undefined;
    }, (): void => {
      this.pending = undefined;
    });
    return task;
  }

  private async install(onProgress?: ClashGeoProgressListener): Promise<ClashGeoInstallResult> {
    if (this.homeDir.length === 0) {
      logWarn('path_unavailable', '');
      return failureResult('path_unavailable', []);
    }
    const deadline: number = Date.now() + CLASH_GEO_TOTAL_TIMEOUT_MS;
    try {
      await ensureDirectory(this.metadataDir());
    } catch {
      logWarn('metadata_failed', 'mkdir');
      return failureResult('metadata_failed', []);
    }

    this.notify(onProgress, 'preparing', '', 0, 0, 0);

    // 1. 已有元数据且四个文件哈希一致：跳过复制。
    const installed: ClashGeoInstalledState = await this.readInstalledState(deadline);
    if (installed.timedOut) {
      logWarn('timeout', 'verify');
      return failureResult('timeout', []);
    }
    if (installed.matched) {
      logInfo('skipped', '');
      this.notify(onProgress, 'completed', '', CLASH_GEO_FILE_NAMES.length, installed.size, installed.size);
      const skipped: ClashGeoInstallResult = {
        ok: true,
        skipped: true,
        totalBytes: installed.size,
        sha256: installed.sha256,
        missingRawFiles: [],
        copiedFiles: []
      };
      return skipped;
    }

    // 2. 预检全部 rawfile，一次性报告所有缺失，避免只复制一部分。
    const sources: ClashGeoRawSource[] = [];
    const missing: string[] = [];
    for (let index: number = 0; index < CLASH_GEO_FILE_NAMES.length; index++) {
      if (Date.now() > deadline) {
        logWarn('timeout', 'probe');
        return failureResult('timeout', []);
      }
      const name: string = CLASH_GEO_FILE_NAMES[index];
      const source: ClashGeoRawSource | undefined = await this.probeRawSource(name);
      if (source === undefined) {
        missing.push(name);
      } else {
        sources.push(source);
      }
    }
    if (missing.length > 0) {
      logWarn('rawfile_missing', String(missing.length));
      return failureResult('rawfile_missing', missing);
    }

    let expectedBytes: number = 0;
    for (let index: number = 0; index < sources.length; index++) {
      expectedBytes += sources[index].length;
    }

    // 3. 分块复制到临时文件，同时计算合并哈希。
    let digest: cryptoFramework.Md;
    try {
      digest = cryptoFramework.createMd(SHA256_ALGORITHM);
    } catch {
      logWarn('copy_failed', 'md');
      return failureResult('copy_failed', []);
    }

    const temporaries: string[] = [];
    const copiedFiles: string[] = [];
    let copiedBytes: number = 0;
    for (let index: number = 0; index < sources.length; index++) {
      if (Date.now() > deadline) {
        await removeFiles(temporaries);
        logWarn('timeout', 'copy');
        return failureResult('timeout', []);
      }
      const temp: string = this.homeDir + '/' + TEMP_PREFIX + sources[index].name + TEMP_SUFFIX;
      const outcome: ClashGeoCopyOutcome = await this.copyToTemp(
        sources[index], temp, digest, onProgress, index + 1, copiedBytes, expectedBytes, deadline);
      if (!outcome.ok) {
        await removeFiles(temporaries);
        const reason: ClashGeoFailureReason = outcome.timedOut ? 'timeout' : 'copy_failed';
        logWarn(reason, sources[index].name);
        return failureResult(reason, []);
      }
      copiedBytes += outcome.bytes;
      temporaries.push(temp);
      copiedFiles.push(sources[index].name);
    }

    if (copiedBytes !== expectedBytes) {
      await removeFiles(temporaries);
      logWarn('copy_failed', 'size');
      return failureResult('copy_failed', []);
    }

    // 4. 全部临时文件就绪后再重命名；中途失败时旧 geo.json 仍与部分文件不符，
    //    下次启动会重新复制整组，不会把混用数据当作一致。
    for (let index: number = 0; index < temporaries.length; index++) {
      if (Date.now() > deadline) {
        await removeFiles(temporaries.slice(index));
        logWarn('timeout', 'rename');
        return failureResult('timeout', []);
      }
      const target: string = this.homeDir + '/' + sources[index].name;
      try {
        await removeFile(target);
        await fileIo.rename(temporaries[index], target);
      } catch {
        await removeFiles(temporaries.slice(index));
        logWarn('copy_failed', 'rename');
        return failureResult('copy_failed', []);
      }
    }

    // 5. 计算合并哈希并原子写入 geo.json；元数据失败则不启动。
    let sha256: string = '';
    try {
      const result: cryptoFramework.DataBlob = digest.digestSync();
      sha256 = toHex(result.data);
    } catch {
      logWarn('copy_failed', 'digest');
      return failureResult('copy_failed', []);
    }
    if (sha256.length !== HASH_HEX_LENGTH || !HASH_PATTERN.test(sha256)) {
      logWarn('copy_failed', 'digest_shape');
      return failureResult('copy_failed', []);
    }

    const metadata: ClashGeoMetadata = {
      version: CLASH_GEO_VERSION,
      sha256: sha256,
      size: copiedBytes,
      copiedAt: new Date().toISOString()
    };
    const writeOutcome: ClashGeoWriteOutcome = await this.writeMetadata(metadata, deadline);
    if (writeOutcome !== 'ok') {
      const reason: ClashGeoFailureReason = writeOutcome === 'timeout' ? 'timeout' : 'metadata_failed';
      logWarn(reason, 'geo_json');
      return failureResult(reason, []);
    }

    logInfo('installed', String(copiedBytes));
    this.notify(onProgress, 'completed', '', CLASH_GEO_FILE_NAMES.length, copiedBytes, copiedBytes);
    const result: ClashGeoInstallResult = {
      ok: true,
      skipped: false,
      totalBytes: copiedBytes,
      sha256: sha256,
      missingRawFiles: [],
      copiedFiles: copiedFiles
    };
    return result;
  }

  /**
   * 校验已落盘数据：元数据可读、四个文件存在且总大小一致，再流式计算合并哈希。
   * 每次启动只读一次 42.8 MB，换取「哈希一致才跳过」的确定行为。
   */
  private async readInstalledState(deadline: number): Promise<ClashGeoInstalledState> {
    const metadata: ClashGeoMetadata | undefined = await this.readMetadata();
    if (metadata === undefined) {
      return unmatchedState();
    }
    const paths: string[] = this.targetPaths();
    let size: number = 0;
    for (let index: number = 0; index < paths.length; index++) {
      try {
        const info: fileIo.Stat = await fileIo.stat(paths[index]);
        if (!Number.isSafeInteger(info.size) || info.size <= 0) {
          return unmatchedState();
        }
        size += info.size;
      } catch {
        return unmatchedState();
      }
    }
    if (size !== metadata.size) {
      return unmatchedState();
    }
    const hashed: ClashGeoHashOutcome = await ClashAssetInstaller.hashFiles(paths, deadline);
    if (hashed.timedOut) {
      const timedOut: ClashGeoInstalledState = {
        matched: false,
        timedOut: true,
        size: size,
        sha256: ''
      };
      return timedOut;
    }
    if (!hashed.ok || hashed.size !== metadata.size) {
      return unmatchedState();
    }
    const state: ClashGeoInstalledState = {
      matched: hashed.sha256 === metadata.sha256,
      timedOut: false,
      size: size,
      sha256: hashed.sha256
    };
    return state;
  }

  /** 依次尝试候选 rawfile 路径，返回长度；不保留 fd。 */
  private async probeRawSource(name: string): Promise<ClashGeoRawSource | undefined> {
    const candidates: string[] = [RAW_GEO_DIR + '/' + name, RAW_GEO_FALLBACK_DIR + '/' + name];
    for (let index: number = 0; index < candidates.length; index++) {
      const rawPath: string = candidates[index];
      let opened: boolean = false;
      let length: number = -1;
      try {
        const raw: resourceManager.RawFileDescriptor = await this.context.resourceManager.getRawFd(rawPath);
        opened = true;
        if (Number.isSafeInteger(raw.length)) {
          length = raw.length;
        }
      } catch {
        length = -1;
      }
      if (opened) {
        await this.closeRawFd(rawPath);
      }
      if (length > 0) {
        const source: ClashGeoRawSource = {
          name: name,
          rawPath: rawPath,
          length: length
        };
        return source;
      }
    }
    return undefined;
  }

  /** 复制单个 rawfile 到临时文件：≤1 MB 读、完整写、逐块更新哈希并让出事件循环。 */
  private async copyToTemp(source: ClashGeoRawSource, temp: string, digest: cryptoFramework.Md,
    onProgress: ClashGeoProgressListener | undefined, fileIndex: number, copiedBefore: number,
    totalBytes: number, deadline: number): Promise<ClashGeoCopyOutcome> {
    let file: fileIo.File | undefined = undefined;
    let rawOpened: boolean = false;
    let bytes: number = 0;
    let succeeded: boolean = false;
    let timedOut: boolean = false;
    try {
      const raw: resourceManager.RawFileDescriptor = await this.context.resourceManager.getRawFd(source.rawPath);
      rawOpened = true;
      if (raw.length !== source.length) {
        throw new Error('raw_size_changed');
      }
      file = await fileIo.open(temp,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC | fileIo.OpenMode.WRITE_ONLY);
      const buffer: ArrayBuffer = new ArrayBuffer(CHUNK_BYTES);
      let position: number = 0;
      while (position < source.length) {
        if (Date.now() > deadline) {
          timedOut = true;
          throw new Error('timeout');
        }
        const wanted: number = Math.min(CHUNK_BYTES, source.length - position);
        const count: number = await fileIo.read(raw.fd, buffer, {
          offset: raw.offset + position,
          length: wanted
        });
        if (count <= 0 || count > wanted) {
          throw new Error('short_read');
        }
        const chunk: Uint8Array = new Uint8Array(buffer, 0, count);
        await writeFully(file.fd, chunk);
        const blob: cryptoFramework.DataBlob = { data: chunk };
        digest.updateSync(blob);
        position += count;
        bytes += count;
        this.notify(onProgress, 'preparing', source.name, fileIndex, copiedBefore + bytes, totalBytes);
        await yieldToEventLoop();
      }
      if (position !== source.length) {
        throw new Error('size_mismatch');
      }
      // fsync 是尽力而为：内容已写完即可交给重命名，失败不伪造成功。
      try {
        await fileIo.fsync(file.fd);
      } catch {
      }
      succeeded = true;
      const outcome: ClashGeoCopyOutcome = { ok: true, timedOut: false, bytes: bytes };
      return outcome;
    } catch {
      const failed: ClashGeoCopyOutcome = {
        ok: false,
        timedOut: timedOut,
        bytes: bytes
      };
      return failed;
    } finally {
      if (file !== undefined) {
        try {
          await fileIo.close(file);
        } catch {
        }
      }
      if (rawOpened) {
        await this.closeRawFd(source.rawPath);
      }
      if (!succeeded) {
        await removeFile(temp);
      }
    }
  }

  /** 原子写 geo.json：临时文件 -> fsync -> 删除旧文件 -> 重命名。 */
  private async writeMetadata(metadata: ClashGeoMetadata, deadline: number): Promise<ClashGeoWriteOutcome> {
    const text: string = JSON.stringify(metadata);
    // 防御：元数据中绝不能出现沙箱绝对路径。
    if (this.homeDir.length === 0 || text.indexOf(this.homeDir) >= 0) {
      return 'failed';
    }
    const encoded: Uint8Array = new util.TextEncoder().encodeInto(text);
    if (encoded.length > MAX_METADATA_BYTES) {
      return 'failed';
    }
    const temp: string = this.metadataTempPath();
    let file: fileIo.File | undefined = undefined;
    try {
      file = await fileIo.open(temp,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC | fileIo.OpenMode.WRITE_ONLY);
      await writeFully(file.fd, encoded);
      try {
        await fileIo.fsync(file.fd);
      } catch {
      }
    } catch {
      if (file !== undefined) {
        try {
          await fileIo.close(file);
        } catch {
        }
        file = undefined;
      }
      await removeFile(temp);
      return 'failed';
    }
    if (file !== undefined) {
      try {
        await fileIo.close(file);
      } catch {
        await removeFile(temp);
        return 'failed';
      }
      file = undefined;
    }
    if (Date.now() > deadline) {
      await removeFile(temp);
      return 'timeout';
    }
    try {
      await removeFile(this.metadataPath());
      await fileIo.rename(temp, this.metadataPath());
    } catch {
      await removeFile(temp);
      return 'failed';
    }
    return 'ok';
  }

  private async readMetadata(): Promise<ClashGeoMetadata | undefined> {
    const path: string = this.metadataPath();
    let file: fileIo.File | undefined = undefined;
    try {
      if (!await fileIo.access(path)) {
        return undefined;
      }
      file = await fileIo.open(path, fileIo.OpenMode.READ_ONLY);
      const info: fileIo.Stat = await fileIo.stat(file.fd);
      if (!Number.isSafeInteger(info.size) || info.size <= 0 || info.size > MAX_METADATA_BYTES) {
        return undefined;
      }
      const buffer: ArrayBuffer = new ArrayBuffer(info.size);
      const target: Uint8Array = new Uint8Array(buffer);
      let total: number = 0;
      while (total < info.size) {
        const part: ArrayBuffer = new ArrayBuffer(info.size - total);
        const count: number = await fileIo.read(file.fd, part, { length: info.size - total });
        if (count <= 0) {
          return undefined;
        }
        target.set(new Uint8Array(part, 0, count), total);
        total += count;
      }
      if (total !== info.size) {
        return undefined;
      }
      const text: string = util.TextDecoder.create('utf-8').decodeToString(target);
      const parsed: ClashGeoMetadata = JSON.parse(text) as ClashGeoMetadata;
      return normalizeMetadata(parsed);
    } catch {
      return undefined;
    } finally {
      if (file !== undefined) {
        try {
          await fileIo.close(file);
        } catch {
        }
      }
    }
  }

  private async closeRawFd(rawPath: string): Promise<void> {
    try {
      await this.context.resourceManager.closeRawFd(rawPath);
    } catch {
    }
  }

  private metadataDir(): string {
    return this.homeDir + '/' + METADATA_DIR;
  }

  private metadataPath(): string {
    return this.metadataDir() + '/' + METADATA_FILE;
  }

  private metadataTempPath(): string {
    return this.metadataDir() + '/' + METADATA_TEMP_FILE;
  }

  private targetPaths(): string[] {
    const paths: string[] = [];
    for (let index: number = 0; index < CLASH_GEO_FILE_NAMES.length; index++) {
      paths.push(this.homeDir + '/' + CLASH_GEO_FILE_NAMES[index]);
    }
    return paths;
  }

  private notify(listener: ClashGeoProgressListener | undefined, stage: ClashGeoStage,
    fileName: string, fileIndex: number, copiedBytes: number, totalBytes: number): void {
    if (listener === undefined) {
      return;
    }
    const progress: ClashGeoProgress = {
      stage: stage,
      label: CLASH_GEO_PROGRESS_LABEL,
      fileName: fileName,
      fileIndex: fileIndex,
      fileCount: CLASH_GEO_FILE_NAMES.length,
      copiedBytes: copiedBytes,
      totalBytes: totalBytes
    };
    try {
      listener(progress);
    } catch {
      // UI 回调异常不影响部署结果。
    }
  }

  /** 按顺序流式计算多个文件的合并 SHA-256；用于校验已有数据。 */
  private static async hashFiles(paths: string[], deadline: number): Promise<ClashGeoHashOutcome> {
    let digest: cryptoFramework.Md;
    try {
      digest = cryptoFramework.createMd(SHA256_ALGORITHM);
    } catch {
      return hashFailure(false, 0);
    }
    const buffer: ArrayBuffer = new ArrayBuffer(CHUNK_BYTES);
    let size: number = 0;
    for (let index: number = 0; index < paths.length; index++) {
      let file: fileIo.File | undefined = undefined;
      try {
        file = await fileIo.open(paths[index], fileIo.OpenMode.READ_ONLY);
        let finished: boolean = false;
        while (!finished) {
          if (Date.now() > deadline) {
            return hashFailure(true, size);
          }
          const count: number = await fileIo.read(file.fd, buffer, { length: CHUNK_BYTES });
          if (count < 0) {
            return hashFailure(false, size);
          }
          if (count === 0) {
            finished = true;
          } else {
            const chunk: Uint8Array = new Uint8Array(buffer, 0, count);
            const blob: cryptoFramework.DataBlob = { data: chunk };
            digest.updateSync(blob);
            size += count;
          }
        }
      } catch {
        return hashFailure(Date.now() > deadline, size);
      } finally {
        if (file !== undefined) {
          try {
            await fileIo.close(file);
          } catch {
          }
        }
      }
    }
    if (size <= 0) {
      return hashFailure(false, 0);
    }
    try {
      const result: cryptoFramework.DataBlob = digest.digestSync();
      const sha256: string = toHex(result.data);
      if (sha256.length !== HASH_HEX_LENGTH || !HASH_PATTERN.test(sha256)) {
        return hashFailure(false, size);
      }
      const outcome: ClashGeoHashOutcome = {
        ok: true,
        timedOut: false,
        size: size,
        sha256: sha256
      };
      return outcome;
    } catch {
      return hashFailure(Date.now() > deadline, size);
    }
  }
}

// ---------------------------------------------------------------------------
// 模块级辅助
// ---------------------------------------------------------------------------

function failureResult(reason: ClashGeoFailureReason, missing: string[]): ClashGeoInstallResult {
  const result: ClashGeoInstallResult = {
    ok: false,
    errorCode: GEO_FAILURE_CODE,
    reason: reason,
    skipped: false,
    totalBytes: 0,
    sha256: '',
    missingRawFiles: missing,
    copiedFiles: []
  };
  return result;
}

function unmatchedState(): ClashGeoInstalledState {
  const state: ClashGeoInstalledState = {
    matched: false,
    timedOut: false,
    size: 0,
    sha256: ''
  };
  return state;
}

function hashFailure(timedOut: boolean, size: number): ClashGeoHashOutcome {
  const outcome: ClashGeoHashOutcome = {
    ok: false,
    timedOut: timedOut,
    size: size,
    sha256: ''
  };
  return outcome;
}

/** 校验 geo.json 结构；任何多余/缺失/异常字段都视为不可信，触发重新复制。 */
function normalizeMetadata(value: ClashGeoMetadata): ClashGeoMetadata | undefined {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    return undefined;
  }
  if (typeof value.version !== 'string' || value.version.length === 0 ||
    value.version.length > MAX_VERSION_LENGTH) {
    return undefined;
  }
  if (typeof value.sha256 !== 'string' || !HASH_PATTERN.test(value.sha256)) {
    return undefined;
  }
  if (typeof value.size !== 'number' || !Number.isSafeInteger(value.size) || value.size <= 0) {
    return undefined;
  }
  if (typeof value.copiedAt !== 'string' || value.copiedAt.length === 0 ||
    value.copiedAt.length > MAX_COPIED_AT_LENGTH) {
    return undefined;
  }
  const metadata: ClashGeoMetadata = {
    version: value.version,
    sha256: value.sha256,
    size: value.size,
    copiedAt: value.copiedAt
  };
  return metadata;
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

async function ensureDirectory(path: string): Promise<void> {
  if (await fileIo.access(path)) {
    return;
  }
  await fileIo.mkdir(path, true);
}

async function removeFile(path: string): Promise<boolean> {
  try {
    await fileIo.unlink(path);
    return true;
  } catch {
    return false;
  }
}

async function removeFiles(paths: string[]): Promise<void> {
  for (let index: number = 0; index < paths.length; index++) {
    await removeFile(paths[index]);
  }
}

/** 单次 write 不保证写完；按剩余区间循环，避免大文件被截断。 */
async function writeFully(fd: number, data: Uint8Array): Promise<void> {
  let written: number = 0;
  while (written < data.length) {
    const remaining: ArrayBuffer =
      data.buffer.slice(data.byteOffset + written, data.byteOffset + data.length) as ArrayBuffer;
    const count: number = await fileIo.write(fd, remaining);
    if (count <= 0) {
      throw new Error('write_failed');
    }
    written += count;
  }
}

function yieldToEventLoop(): Promise<void> {
  return new Promise<void>((resolve: () => void): void => {
    setTimeout(resolve, 0);
  });
}

function toHex(data: Uint8Array): string {
  const digits: string = '0123456789abcdef';
  let output: string = '';
  for (let index: number = 0; index < data.length; index++) {
    const value: number = data[index] & 0xff;
    output += digits.charAt(value >> 4) + digits.charAt(value & 0x0f);
  }
  return output;
}

function logInfo(event: string, detail: string): void {
  hilog.info(LOG_DOMAIN, LOG_TAG, 'geo %{public}s %{public}s', event, detail);
}

function logWarn(reason: ClashGeoFailureReason, detail: string): void {
  hilog.warn(LOG_DOMAIN, LOG_TAG, 'geo failed %{public}s %{public}s', reason, detail);
}