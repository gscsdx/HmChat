import { VideoRangeReader, VideoRangeState, VideoWindow, VideoRangeTransport } from '../model/VideoPlayback';
import { StorageManager } from './StorageManager';
import { MediaAttachment } from '../model/MediaModels';
import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { pasteboard } from '@kit.BasicServicesKit';
import nativeTdlib from 'libentry.so';
import { chatRepository } from '../data/ChatRepository';
import { TelegramClient } from '../telegram/TelegramClient';
import { TdTransport, TelegramState, TelegramParameters, TelegramHistoryState } from '../telegram/TdTypes';
import { CredentialVault, TelegramCredentials } from './CredentialVault';
import { AttachmentService } from './AttachmentService';
import { Contact, MessagePermissions, MessageActionState } from '../model/ChatModels';
import { sessionStorageDirectory } from '../model/SessionStorage';
import { AccountStore, AccountProfile, AccountRegistry } from './AccountStore';
import { LoginApiPreferences } from './LoginApiPreferences';
import { TELEGRAM_API_ID, TELEGRAM_API_HASH, TELEGRAM_API_PRESETS } from '../config/TelegramBuildConfig';

export { TelegramState, TelegramHistoryState } from '../telegram/TdTypes';

class NativeTransport implements TdTransport {
  createClient(): number { return nativeTdlib.createClient(); }
  send(clientId: number, request: string): void { nativeTdlib.send(clientId, request); }
  receive(): string { return nativeTdlib.receive(); }
}

class TelegramService {
  private client: TelegramClient = new TelegramClient(new NativeTransport(), chatRepository);
  readonly storageManager: StorageManager = new StorageManager(this.client);
  private storageMaintenanceTick: number = 0;
  private videoEpoch: number = 0;
  private timer: number = -1;
  private starting: boolean = false;
  private freshStorageRequested: boolean = false;

  private registry: AccountRegistry = { active: 'primary', accounts: [] };
  private switching: boolean = false;
  private registryLoaded: boolean = false;
  accounts(): AccountProfile[] { return this.registry.accounts.map((item: AccountProfile): AccountProfile => ({ id: item.id, name: item.name, avatar: item.avatar, color: item.color, avatarPath: item.avatarPath, avatarFileId: item.avatarFileId })); }
  activeAccount(): string { return this.registry.active; }
  isSwitching(): boolean { return this.switching; }
  private async loadAccounts(): Promise<void> {
    if (!this.registryLoaded) { this.registry = await AccountStore.load(); this.registryLoaded = true; }
  }
  private async closeForSwitch(): Promise<void> {
    this.videoEpoch++;
    if (this.state().phase === 'idle' || this.state().phase === 'closed') { return; }
    this.client.leaveChat();
    this.client.close();
    for (let count = 0; count < 200 && this.state().phase !== 'closed'; count++) {
      if (this.timer < 0) { this.client.drain(); }
      await new Promise<void>((resolve: () => void) => { setTimeout(resolve, 50); });
    }
    if (this.state().phase !== 'closed') { throw new Error('连接尚未关闭，请稍后重试'); }
  }
  async switchAccount(context: common.UIAbilityContext, accountId: string): Promise<void> {
    if (this.switching || this.starting) { throw new Error('账户正在切换'); }
    this.switching = true;
    try {
      await this.loadAccounts();
      if (accountId === this.registry.active) { return; }
      if (!this.registry.accounts.some((item: AccountProfile) => item.id === accountId)) { throw new Error('账户不存在'); }
      const target = await CredentialVault.load(accountId);
      await this.closeForSwitch();
      this.freshStorageRequested = false;
      const next: AccountRegistry = { active: accountId, accounts: this.registry.accounts, pending: this.registry.pending };
      await AccountStore.save(next);
      this.registry = next;
      if (target) { await this.connect(context, target); }
      else { await this.startDefault(context); }
    } finally { this.switching = false; }
  }
  async addAccount(context: common.UIAbilityContext): Promise<void> {
    if (this.switching || this.starting) { throw new Error('账户正在切换'); }
    this.switching = true;
    try {
      await this.loadAccounts();
      // A pending login is not an account. Reuse its isolated storage without listing it.
      const id = this.registry.pending || CredentialVault.createAccountId();
      await this.closeForSwitch();
      this.freshStorageRequested = false;
      const next: AccountRegistry = { active: id, accounts: this.registry.accounts, pending: id };
      await AccountStore.save(next);
      this.registry = next;
      await this.startDefault(context);
    } finally { this.switching = false; }
  }

  state(): TelegramState { return this.client.state(); }
  subscribe(listener: (state: TelegramState) => void): void { this.client.subscribe((state: TelegramState) => {
    const user = state.ready ? this.client.getCurrentUser() : undefined;
    const profile = this.registry.accounts.find((item: AccountProfile) => item.id === this.registry.active);
    if (user) {
      const path = user.avatarPath || (profile?.avatarFileId === user.avatarFileId ? profile?.avatarPath : '') || '';
      if (!profile || profile.name !== user.name || profile.avatarPath !== path ||
        profile.avatar !== user.avatar || profile.color !== user.color || profile.avatarFileId !== user.avatarFileId) {
        const updated: AccountProfile = { id: this.registry.active, name: user.name,
          avatar: user.avatar, color: user.color, avatarPath: path, avatarFileId: user.avatarFileId };
        this.registry.accounts = profile ? this.registry.accounts.map((item: AccountProfile): AccountProfile => item.id === updated.id ? updated : item) : this.registry.accounts.concat([updated]);
        if (this.registry.pending === this.registry.active) { this.registry.pending = undefined; }
        AccountStore.save(this.registry).catch(() => this.client.fail('账户资料保存失败，请稍后重试'));
      }
    }
    listener(state);
  }); }
  unsubscribe(): void { this.client.unsubscribe(); }

  async resume(context: common.UIAbilityContext): Promise<void> {
    if (this.state().phase !== 'idle') { return; }
    try {
      await this.loadAccounts();
      const credentials = await CredentialVault.load(this.registry.active);
      if (credentials) { await this.connect(context, credentials); }
    } catch {
      this.client.fail('无法恢复登录，请重试。');
    }
  }

  async startDefault(context: common.UIAbilityContext, presetIndex?: number): Promise<void> {
    const total = TELEGRAM_API_PRESETS.length;
    if (total > 0) {
      const index = await this.resolvePresetIndex(context, total, presetIndex);
      const preset = TELEGRAM_API_PRESETS[index];
      // Generated presets are validated by the build script; re-check before touching credentials.
      if (!Number.isSafeInteger(preset.id) || preset.id <= 0 || preset.id > 2147483647 ||
        !/^[a-fA-F0-9]{32}$/.test(preset.hash)) {
        this.client.fail('API ID 应为正整数，API Hash 应为 32 位十六进制字符。');
        throw new Error('API 配置格式不正确');
      }
      await this.start(context, String(preset.id), preset.hash);
      return;
    }
    if (TELEGRAM_API_ID <= 0 || !/^[a-fA-F0-9]{32}$/.test(TELEGRAM_API_HASH)) {
      this.client.fail('尚未配置应用 API 身份。请在本机 config/telegram.local.json 填写开发者配置并重新构建，或打开开发者配置。');
      throw new Error('应用尚未配置 API 身份');
    }
    await this.start(context, String(TELEGRAM_API_ID), TELEGRAM_API_HASH);
  }

  /**
   * Resolves the preset index in 0..total-1. An explicit index wins; otherwise the choice saved
   * by the account settings UI is used. The UI owns writes, so starting a connection never
   * rewrites the selection.
   */
  private async resolvePresetIndex(context: common.UIAbilityContext, total: number, presetIndex?: number): Promise<number> {
    if (presetIndex === undefined) {
      try { return await LoginApiPreferences.load(context, total); } catch { return 0; }
    }
    if (!Number.isSafeInteger(presetIndex) || presetIndex < 0) { return 0; }
    return presetIndex > total - 1 ? total - 1 : presetIndex;
  }

  async start(context: common.UIAbilityContext, apiId: string, apiHash: string): Promise<void> {
    // Keep recovery intent across close -> closed and a failed Asset write, so retry stays isolated.
    if (this.state().phase === 'storageRecovery') { this.freshStorageRequested = true; }
    const id = Number(apiId);
    if (!Number.isSafeInteger(id) || id <= 0 || !/^[a-fA-F0-9]{32}$/.test(apiHash)) {
      this.client.fail('API ID 应为正整数，API Hash 应为 32 位十六进制字符。');
      throw new Error('API 配置格式不正确');
    }
    if (this.starting) { return; }
    this.starting = true;
    try {
      if ((this.timer >= 0 || this.freshStorageRequested) && this.state().phase !== 'closed' && this.state().phase !== 'idle') {
        this.client.close();
        for (let count = 0; count < 100 && this.state().phase !== 'closed'; count++) {
          if (this.timer < 0) { this.client.drain(); }
          await new Promise<void>((resolve: () => void) => { setTimeout(resolve, 50); });
        }
        if (this.state().phase !== 'closed') { throw new Error('正在关闭上一次连接，请稍后重试'); }
      }
      await this.loadAccounts();
      const credentials = await CredentialVault.save(id, apiHash, this.freshStorageRequested, this.registry.active);
      this.freshStorageRequested = false;
      await this.connect(context, credentials);
    } finally { this.starting = false; }
  }

  private async connect(context: common.UIAbilityContext, credentials: TelegramCredentials): Promise<void> {
    if (nativeTdlib.getTdlibStatus() !== 'available') {
      this.client.fail('此安装包尚未包含可用的 TDLib 原生库，请先运行 build-tdlib.sh 并重新构建。');
      throw new Error('TDLib 原生库不可用');
    }
    const directory = sessionStorageDirectory(context.filesDir, credentials.databaseNamespace);
    if (!fileIo.accessSync(directory)) { fileIo.mkdirSync(directory, true); }
    const files = directory + '/files';
    if (!fileIo.accessSync(files)) { fileIo.mkdirSync(files, true); }
    const parameters: TelegramParameters = {
      apiId: credentials.apiId, apiHash: credentials.apiHash,
      databaseDirectory: directory, filesDirectory: files, encryptionKey: credentials.encryptionKey
    };
    await this.storageManager.initialize(context, this.registry.active);
    this.videoEpoch++; this.client.start(parameters);
    if (this.timer < 0) {
      this.timer = setInterval(() => {
        try {
          this.client.drain();
          if (Date.now() - this.storageMaintenanceTick > 60000) {
            this.storageMaintenanceTick = Date.now(); this.storageManager.maintain(false).catch(() => {});
          }
        } catch {
          this.client.fail('协议引擎运行异常，请重新启动应用。');
          clearInterval(this.timer);
          this.timer = -1;
        }
      }, 60);
    }
  }

  setPhone(phone: string): void { this.client.setPhone(phone); }
  editPhone(): void { this.client.editPhone(); }
  resendCode(): void { this.client.resendCode(); }
  register(first: string, last: string, accepted: boolean): void { this.client.register(first, last, accepted); }
  setCode(code: string): void { this.client.setCode(code); }
  setPassword(password: string): void { this.client.setPassword(password); }
  setEmail(email: string): void { this.client.setEmail(email); }
  setEmailCode(code: string): void { this.client.setEmailCode(code); }
  openChat(id: string): void { this.client.openChat(id); }
  loadMoreChats(): void { this.client.loadMoreChats(); }
  loadOlderMessages(id: string): void { this.client.loadOlderMessages(id); }
  getHistoryState(id: string): TelegramHistoryState { return this.client.getHistoryState(id); }
  viewVisibleMessages(id: string, ids: string[]): void { this.client.viewVisibleMessages(id, ids); }
  setDraft(id: string, text: string): void { this.client.setDraft(id, text); }
  async pickMedia(context: common.UIAbilityContext): Promise<MediaAttachment[]> { return AttachmentService.pickMedia(context); }
  sendMedia(id: string, items: MediaAttachment[], caption: string): boolean { return this.client.sendMedia(id, items, caption); }
  loadFullRichMessage(chatId: string, id: string): void { this.client.loadFullRichMessage(chatId, id); }
  downloadRichMedia(chatId: string, id: string, fileId: number, cancel: boolean = false): void { this.client.downloadRichMedia(chatId, id, fileId, cancel); }
  async createVideoReader(chatId: string, messageId: string, fileId: number): Promise<VideoRangeReader> {
    const account = this.activeAccount(), epoch = this.videoEpoch;
    const initialVideo = this.client.videoFile(chatId, messageId, fileId);
    console.info('HarlgramVideo source complete=' + initialVideo.local.is_downloading_completed + ' bytes=' + initialVideo.local.downloaded_size + ' hasPath=' + !!initialVideo.local.path);
    const current = (): boolean => epoch === this.videoEpoch && account === this.activeAccount() && this.state().ready;
    // TDLib can retain a partial-file path after cache GC; downloadFile revalidates the native location.
    let exists: boolean = false;
    try { exists = !!initialVideo.local.path && await fileIo.access(initialVideo.local.path); } catch (_) {}
    if (!current()) { throw new Error('账户已切换，请重新打开视频'); }
    if (!exists) { await this.client.videoRange(fileId, 0, Math.min(2 * 1024 * 1024, initialVideo.size)); }
    if (!current()) { throw new Error('账户已切换，请重新打开视频'); }
    const source: VideoRangeTransport = {
      current: current,
      state: (): VideoRangeState => {
        if (!current()) { throw new Error('账户已切换，请重新打开视频'); }
        const file = this.client.videoFile(chatId, messageId, fileId);
        return { path: file.local.path, size: file.size, downloaded: file.local.downloaded_size || 0, complete: file.local.is_downloading_completed };
      },
      prefix: (offset: number): Promise<number> => this.client.videoPrefix(fileId, offset).catch((error: Error) => { console.info('HarlgramVideo prefixFailed'); throw error; }),
      download: (range: VideoWindow): Promise<void> => { console.info('HarlgramVideo range offset=' + range.offset + ' limit=' + range.limit); return this.client.videoRange(fileId, range.offset, range.limit); },
      read: async (path: string, offset: number, length: number): Promise<ArrayBuffer> => {
        const file = await fileIo.open(path, fileIo.OpenMode.READ_ONLY);
        try {
          const buffer = new ArrayBuffer(length);
          const count = await fileIo.read(file.fd, buffer, { offset: offset, length: length });
          return count === length ? buffer : buffer.slice(0, count);
        } finally { await fileIo.close(file); }
      },
      cancel: (): void => { if (current()) { this.client.stopVideoRange(fileId); } }
    };
    return new VideoRangeReader(source);
  }
  downloadMedia(chatId: string, id: string): void { this.client.downloadMedia(chatId, id); }
  cancelMedia(chatId: string, id: string): void { this.client.cancelMedia(chatId, id); }
  sendPhoto(id: string, path: string, caption: string): boolean { return this.client.sendPhoto(id, path, caption); }
  leaveChat(): void { this.client.leaveChat(); }
  setForeground(value: boolean): void { this.client.setForeground(value); if (value) { this.storageManager.foreground(); } }
  openContact(id: string): string { return this.client.openContact(id); }
  openSavedMessages(): string { return this.client.openSavedMessages(); }
  getCurrentUser(): Contact | undefined { return this.client.getCurrentUser(); }
  sendMessage(id: string, text: string): boolean { return this.client.sendMessage(id, text); }
  loadMessageProperties(chatId: string, messageId: string): void { this.client.loadMessageProperties(chatId, messageId); }
  getMessagePermissions(chatId: string, messageId: string): MessagePermissions {
    return this.client.getMessagePermissions(chatId, messageId);
  }
  getMessageAction(token: string): MessageActionState | undefined { return this.client.getMessageAction(token); }
  sendReply(chatId: string, text: string, replyToMessageId: string): string {
    return this.client.sendReply(chatId, text, replyToMessageId);
  }
  editMessage(chatId: string, messageId: string, text: string): string {
    return this.client.editMessage(chatId, messageId, text);
  }
  deleteMessage(chatId: string, messageId: string, revoke: boolean): string {
    return this.client.deleteMessage(chatId, messageId, revoke);
  }
  forwardMessage(fromChatId: string, messageId: string, toChatId: string): string {
    return this.client.forwardMessage(fromChatId, messageId, toChatId);
  }
  loadReplyTarget(chatId: string, messageId: string): string { return this.client.loadReplyTarget(chatId, messageId); }
  async copyText(text: string): Promise<void> {
    const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
    const property = data.getProperty();
    property.shareOption = pasteboard.ShareOption.LOCALDEVICE;
    data.setProperty(property);
    await pasteboard.getSystemPasteboard().setData(data);
  }
  togglePinned(id: string): void { this.client.togglePinned(id); }
  toggleMuted(id: string): void { this.client.toggleMuted(id); }
  logOut(): void { this.client.logOut(); }
}

export const telegramService = new TelegramService();
