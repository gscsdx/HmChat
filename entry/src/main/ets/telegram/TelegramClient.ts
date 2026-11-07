import { MediaPolicy, MediaNetwork, AutoMediaKind, defaultMediaPolicy, cloneMediaPolicy, autoDownloadAllowed, StorageUsage, FastStorageUsage, NetworkUsage, StorageOptimize } from '../model/StorageModels';
import { decodeRichBlocks } from './RichMessage';
import { concealedMessageText } from '../model/MessagePresentation';
import { MediaAttachment } from '../model/MediaModels';
import { ChatRepository } from '../data/ChatRepository';
import { ChatSummary, ChatMessage, Contact, MessagePermissions, MessageActionState, MessageActionKind } from '../model/ChatModels';
import { TdChat, TdMessage, TdUser, TdEvent, TdAuthorization, TdPosition, TdTransport, TelegramParameters, TelegramState, TelegramHistoryState, TdDraft, TdFile, TdPhotoSize, TdMessageProperties, TdTextEntity, TdMessageReply, TdContent, TdRichMessage } from './TdTypes';

interface HistoryRequest { chatId: number; fromId: number; }
interface DraftState { text: string; version: number; savedVersion: number; }
interface DraftRequest { chatId: number; version: number; }
interface PendingSend { chatId: string; text: string; mediaPath?: string; mediaKind?: 'photo' | 'video'; attachments?: MediaAttachment[]; }
interface ViewRequest { chatId: number; ids: string[]; }
interface MessageRef { chatId: string; messageId: string; }
interface RichReadRequest extends MessageRef { deadline: number; }
interface ActionRequest { state: MessageActionState; text?: string; draftText?: string; draftVersion?: number; revoke?: boolean; }

/** Protocol state machine, independent of ArkUI and device APIs. */
export class TelegramClient {
  private clientId = 0;
  private sequence = 0;
  private current: TelegramState = { phase: 'idle', error: '', connection: '未连接', ready: false };
  private listener: ((state: TelegramState) => void) | undefined;
  private parameters: TelegramParameters | undefined;
  private chats = new Map<number, TdChat>();
  private users = new Map<number, TdUser>();
  private activeChat = 0;
  private openedChat = 0;
  private historyRequests = new Map<string, HistoryRequest>();
  private historyInFlight = new Set<number>();
  private oldestMessages = new Map<number, number>();
  private historyEnded = new Set<number>();
  private historyStalls = new Map<number, number>();
  private historyLoaded = new Set<number>();
  private historyErrors = new Map<number, string>();
  private viewedMessages = new Set<string>();
  private viewRequests = new Map<string, ViewRequest>();
  private chatListRequest = '';
  private chatListEnded = false;
  private localDrafts = new Map<number, DraftState>();
  private draftRequests = new Map<string, DraftRequest>();
  private draftInFlight = new Set<number>();
  private photoFiles = new Map<number, TdFile>();
  private photoDownloads = new Set<number>();
  private downloadRequests = new Map<string, number>();
  private readonly photoDownloadLimit = 20 * 1024 * 1024;
  private readonly videoDownloadLimit = 2000000000;
  private readonly avatarDownloadLimit = 512 * 1024;
  private requestedChats = new Set<number>();
  private privateChatRequests = new Map<string, number>();
  private readyInitialized = false;
  private selfUserId = 0;
  private meRequest = '';
  private foreground = true;
  private contactIds = new Set<number>();
  private mediaPolicy: MediaPolicy = defaultMediaPolicy();
  private mediaNetwork: MediaNetwork = 'unknown';
  private automaticMedia = new Map<number, AutoMediaKind>();
  private automaticMediaChats = new Map<number, number>();
  private manualMedia = new Set<number>();
  private streamingVideos = new Map<number, { active: boolean; manual: boolean }>();
  private managedRequests = new Map<string, { resolve: (event: TdEvent) => void; reject: (error: Error) => void; deadline: number }>();
  private managedKeys = new Set<string>();
  private pendingSends = new Map<string, PendingSend>();
  private pendingAuthRequest = '';
  private authDeadline = 0;
  private resendAt = 0;
  private lastResendSeconds = 0;
  private initializationDeadline = 0;
  private expiredAuthRequests = new Set<string>();
  private richMessageRequests = new Map<string, RichReadRequest>();
  private replyPreviewRequests = new Map<string, MessageRef>();
  private replyPreviewAttempted = new Set<string>();
  private messageDetails = new Map<string, TdMessage>();
  private messagePermissions = new Map<string, MessagePermissions>();
  private propertyRequests = new Map<string, MessageRef>();
  private messageActions = new Map<string, ActionRequest>();
  private sendActionMessages = new Map<string, string>();
  // TDLib may emit completion before the send/forward response reaches its caller.
  private completedSendMessages = new Map<string, TdMessage>();

  configureMediaPolicy(policy: MediaPolicy, network: MediaNetwork): void {
    this.mediaPolicy = cloneMediaPolicy(policy); this.mediaNetwork = network;
    this.automaticMedia.forEach((kind: AutoMediaKind, id: number) => {
      const file = this.photoFiles.get(id);
      if (file?.local.is_downloading_active && !this.manualMedia.has(id) && !autoDownloadAllowed(policy, network, kind, file.size || file.expected_size)) {
        this.request('cancelDownloadFile', { file_id: id, only_if_pending: false }); this.photoDownloads.delete(id);
      } else if (file && this.activeChat !== 0 && this.automaticMediaChats.get(id) === this.activeChat && autoDownloadAllowed(policy, network, kind, file.size || file.expected_size)) {
        this.downloadFile(id, kind === 'photo' ? this.photoDownloadLimit : this.videoDownloadLimit);
      }
    });
  }
  setMediaNetwork(network: MediaNetwork): void {
    this.configureMediaPolicy(this.mediaPolicy, network);
    if (this.current.ready) {
      const type = network === 'wifi' ? 'networkTypeWiFi' : network === 'mobile' ? 'networkTypeMobile' : network === 'roaming' ? 'networkTypeMobileRoaming' : network === 'none' ? 'networkTypeNone' : 'networkTypeOther';
      this.request('setNetworkType', { type: { '@type': type } });
    }
  }
  private downloadAutomatic(fileId: number, kind: AutoMediaKind): void {
    const file = this.photoFiles.get(fileId);
    if (!file) { return; }
    this.automaticMedia.set(fileId, kind); this.automaticMediaChats.set(fileId, this.activeChat);
    if (!autoDownloadAllowed(this.mediaPolicy, this.mediaNetwork, kind, file.size || file.expected_size)) { return; }
    this.downloadFile(fileId, kind === 'photo' ? this.photoDownloadLimit : this.videoDownloadLimit);
  }
  private managedRequest(method: string, params: Record<string, unknown> = {}): Promise<TdEvent> {
    if (!this.current.ready) { return Promise.reject(new Error('请先登录并等待连接完成')); }
    return new Promise<TdEvent>((resolve, reject) => {
      const key = this.request(method, params);
      if (!key) { reject(new Error('无法发送存储请求，请重试')); return; }
      this.managedKeys.add(key);
      if (this.managedKeys.size > 2048) {
        for (const oldKey of this.managedKeys) { if (!this.managedRequests.has(oldKey)) { this.managedKeys.delete(oldKey); if (this.managedKeys.size <= 1024) { break; } } }
      }
      this.managedRequests.set(key, { resolve: resolve, reject: reject, deadline: Date.now() + 30000 });
    });
  }
  async storageStatistics(): Promise<StorageUsage> { return await this.managedRequest('getStorageStatistics', { chat_limit: 10000 }) as unknown as StorageUsage; }
  async fastStorageStatistics(): Promise<FastStorageUsage> { return await this.managedRequest('getStorageStatisticsFast') as unknown as FastStorageUsage; }
  async networkStatistics(): Promise<NetworkUsage> { return await this.managedRequest('getNetworkStatistics', { only_current: false }) as unknown as NetworkUsage; }
  async resetNetworkStatistics(): Promise<void> { await this.managedRequest('resetNetworkStatistics'); }
  async storageChat(id: number): Promise<TdChat> {
    const cached = this.chats.get(id); if (cached) { return cached; }
    return await this.managedRequest('getChat', { chat_id: id }) as unknown as TdChat;
  }
  isSavedStorageChat(id: number): boolean { return this.chats.get(id)?.type.user_id === this.selfUserId && this.selfUserId !== 0; }
  protectedCacheChats(): number[] {
    const ids: number[] = this.activeChat ? [this.activeChat] : [];
    this.chats.forEach((chat: TdChat) => { if (chat.type['@type'] === 'chatTypeSecret' && !ids.includes(chat.id)) { ids.push(chat.id); } });
    this.pendingSends.forEach((send: PendingSend) => { if (!ids.includes(Number(send.chatId))) { ids.push(Number(send.chatId)); } });
    this.messageDetails.forEach((message: TdMessage) => { if (message.sending_state && !ids.includes(message.chat_id)) { ids.push(message.chat_id); } });
    return ids;
  }
  async optimizeCache(command: StorageOptimize): Promise<StorageUsage> {
    const result = await this.managedRequest('optimizeStorage', { size: command.size, ttl: command.ttl, count: command.count,
      immunity_delay: command.immunity_delay, file_types: command.file_types, chat_ids: command.chat_ids,
      exclude_chat_ids: command.exclude_chat_ids, return_deleted_file_statistics: command.return_deleted_file_statistics, chat_limit: command.chat_limit });
    // Re-read known file handles locally; GC updates may arrive after the aggregate response.
    this.photoFiles.forEach((_file: TdFile, id: number) => { this.request('getFile', { file_id: id }); });
    return result as unknown as StorageUsage;
  }

  constructor(private transport: TdTransport, private repository: ChatRepository) {}

  state(): TelegramState {
    return { phase: this.current.phase, error: this.current.error, connection: this.current.connection, ready: this.current.ready,
      submitting: this.pendingAuthRequest.length > 0,
      codeDelivery: this.current.codeDelivery, nextDelivery: this.current.nextDelivery,
      termsText: this.current.termsText, minAge: this.current.minAge,
      resendSeconds: Math.max(0, Math.ceil((this.resendAt - Date.now()) / 1000)),
      canResend: !this.pendingAuthRequest && Date.now() >= this.resendAt &&
        (this.current.phase === 'emailCode' || (this.current.phase === 'code' && !!this.current.nextDelivery)) };
  }
  subscribe(listener: (state: TelegramState) => void): void { this.listener = listener; listener(this.state()); }
  unsubscribe(): void { this.listener = undefined; }
  private emit(): void { if (this.listener) { this.listener(this.state()); } }
  fail(message: string): void {
    if (this.current.phase === 'idle' || this.current.phase === 'starting') { this.current.phase = 'error'; }
    this.current.error = message;
    this.emit();
  }

  start(parameters: TelegramParameters): void {
    if (this.clientId !== 0) { this.fail('已有连接正在运行，请继续当前登录流程。'); return; }
    this.parameters = parameters;
    this.authDeadline = 0;
    this.expiredAuthRequests.clear();
    this.resendAt = 0;
    this.lastResendSeconds = 0;
    this.initializationDeadline = Date.now() + 30000;
    this.pendingAuthRequest = '';
    this.repository.useRemoteData();
    this.current = { phase: 'starting', error: '', connection: '连接中', ready: false };
    try {
      this.clientId = this.transport.createClient();
      // TDLib starts delivering the authorization state after its first request.
      this.request('getOption', { name: 'version' });
    } catch {
      this.current.phase = 'error';
      this.current.error = '无法启动 Telegram 协议引擎，请检查原生库是否已打包。';
    }
    this.emit();
  }

  private request(type: string, fields: Record<string, unknown> = {}, extra = ''): string {
    const key = extra || `${type}:${++this.sequence}`;
    const request: Record<string, unknown> = { '@type': type, '@extra': key };
    Object.keys(fields).forEach((name: string) => { request[name] = fields[name]; });
    try {
      this.transport.send(this.clientId, JSON.stringify(request));
      return key;
    } catch {
      this.fail('协议引擎无法提交请求，请稍后重试。');
      return '';
    }
  }

  setPhone(phone: string): void {
    if (this.current.phase !== 'phone' || this.pendingAuthRequest) { return; }
    const normalized = phone.replace(/[\s()-]/g, '');
    if (!/^\+[1-9]\d{5,14}$/.test(normalized)) { this.fail('请输入带国家区号的手机号，例如 +86…'); return; }
    this.current.error = '';
    this.pendingAuthRequest = this.request('setAuthenticationPhoneNumber', { phone_number: normalized, settings: { '@type': 'phoneNumberAuthenticationSettings', allow_flash_call: false, allow_missed_call: false, is_current_phone_number: false, allow_sms_retriever_api: false } });
    this.authDeadline = this.pendingAuthRequest ? Date.now() + 30000 : 0;
    this.emit();
  }
  setCode(code: string): void {
    if (this.current.phase !== 'code' || this.pendingAuthRequest) { return; }
    // Telegram can send numeric codes, SMS words or SMS phrases.
    if (!code.trim() || code.trim().length > 256) { this.fail('请输入 Telegram 发给你的验证码（最多 256 个字符）。'); return; }
    this.current.error = '';
    this.pendingAuthRequest = this.request('checkAuthenticationCode', { code: code.trim() });
    this.authDeadline = this.pendingAuthRequest ? Date.now() + 30000 : 0;
    this.emit();
  }
  setPassword(password: string): void {
    if (this.current.phase !== 'password' || this.pendingAuthRequest) { return; }
    if (!password) { this.fail('请输入两步验证密码。'); return; }
    this.current.error = '';
    this.pendingAuthRequest = this.request('checkAuthenticationPassword', { password: password });
    this.authDeadline = this.pendingAuthRequest ? Date.now() + 30000 : 0;
    this.emit();
  }
  setEmail(email: string): void {
    if (this.current.phase !== 'email' || this.pendingAuthRequest) { return; }
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email.trim())) { this.fail('请输入有效的邮箱地址。'); return; }
    this.current.error = '';
    this.pendingAuthRequest = this.request('setAuthenticationEmailAddress', { email_address: email.trim() });
    this.authDeadline = this.pendingAuthRequest ? Date.now() + 30000 : 0;
    this.emit();
  }
  setEmailCode(code: string): void {
    if (this.current.phase !== 'emailCode' || this.pendingAuthRequest) { return; }
    if (!code.trim()) { this.fail('请输入邮箱验证码。'); return; }
    this.current.error = '';
    this.pendingAuthRequest = this.request('checkAuthenticationEmailCode', { code: { '@type': 'emailAddressAuthenticationCode', code: code.trim() } });
    this.authDeadline = this.pendingAuthRequest ? Date.now() + 30000 : 0;
    this.emit();
  }

  editPhone(): void {
    if (this.pendingAuthRequest || !['code', 'emailCode', 'registration', 'password', 'email'].includes(this.current.phase)) { return; }
    this.current.phase = 'phone';
    this.current.error = '';
    this.current.codeDelivery = '';
    this.current.nextDelivery = '';
    this.current.termsText = '';
    this.resendAt = 0;
    this.emit();
  }

  resendCode(): void {
    if (!this.state().canResend) { return; }
    this.current.error = '';
    this.pendingAuthRequest = this.request('resendAuthenticationCode', { reason: null });
    this.resendAt = Date.now() + 30000;
    this.authDeadline = this.pendingAuthRequest ? Date.now() + 30000 : 0;
    this.emit();
  }

  register(firstName: string, lastName: string, accepted: boolean): void {
    if (this.current.phase !== 'registration' || this.pendingAuthRequest) { return; }
    if (!accepted) { this.fail('请先阅读并同意服务条款及最低年龄要求。'); return; }
    const first = firstName.trim(), last = lastName.trim();
    if (!first || Array.from(first).length > 64 || Array.from(last).length > 64) {
      this.fail('请填写名字；名字和姓氏各不超过 64 个字符。'); return;
    }
    this.current.error = '';
    this.pendingAuthRequest = this.request('registerUser', { first_name: first, last_name: last, disable_notification: true });
    this.authDeadline = this.pendingAuthRequest ? Date.now() + 30000 : 0;
    this.emit();
  }

  /** The only receiver in this process. Bound work per frame and never wait on the UI thread. */
  drain(): void {
    if (this.clientId === 0) { return; }
    let changed = false;
    this.managedRequests.forEach((operation, key: string) => {
      if (operation.deadline <= Date.now()) { this.managedRequests.delete(key); operation.reject(new Error('请求超时，请重试')); changed = true; }
    });
    this.richMessageRequests.forEach((request: RichReadRequest, key: string) => {
      if (request.deadline > Date.now()) { return; }
      this.richMessageRequests.delete(key);
      const message = this.findMessage(request.chatId, request.messageId);
      if (message) { this.repository.upsertMessage({ ...message, richLoading: false, richError: '加载超时，请重试' }); changed = true; }
    });
    const remaining = Math.max(0, Math.ceil((this.resendAt - Date.now()) / 1000));
    if (remaining !== this.lastResendSeconds) { this.lastResendSeconds = remaining; changed = true; }
    if (this.authDeadline > 0 && Date.now() >= this.authDeadline && this.pendingAuthRequest) {
      this.expiredAuthRequests.add(this.pendingAuthRequest);
      this.pendingAuthRequest = '';
      this.authDeadline = 0;
      this.current.error = '请求超时，请检查网络后重试；若验证码稍后送达，请勿反复申请。';
      changed = true;
    }
    if (this.initializationDeadline > 0 && Date.now() >= this.initializationDeadline) {
      this.initializationDeadline = 0;
      if (this.current.phase === 'starting') {
        this.current.phase = 'error';
        this.current.error = '连接超时，请检查网络后重试，或切回已有账户。';
        changed = true;
      }
    }
    const started = Date.now();
    for (let index = 0; index < 64 && Date.now() - started < 12; index++) {
      let raw = '';
      try { raw = this.transport.receive(); } catch {
        this.pendingAuthRequest = '';
        this.current.error = '协议引擎接收失败，请重新启动应用。';
        changed = true;
        break;
      }
      if (!raw) { break; }
      try {
        const event = JSON.parse(raw) as TdEvent;
        if (event['@client_id'] && event['@client_id'] !== this.clientId) { continue; }
        this.handle(event);
        changed = true;
      } catch {
        this.current.error = '收到无法处理的协议数据，请重启客户端重试。';
        changed = true;
      }
    }
    if (changed) { this.emit(); }
  }

  private authorize(auth: TdAuthorization): void {
    this.pendingAuthRequest = '';
    this.current.error = '';
    this.authDeadline = 0;
    const phase = auth['@type'];
    if (phase !== 'authorizationStateWaitTdlibParameters') { this.initializationDeadline = 0; }
    this.current.codeDelivery = '';
    this.current.nextDelivery = '';
    this.current.termsText = '';
    this.current.minAge = 0;
    this.resendAt = 0;
    if (phase === 'authorizationStateWaitTdlibParameters') {
      const config = this.parameters;
      if (!config) { return; }
      this.request('setTdlibParameters', {
        use_test_dc: false, database_directory: config.databaseDirectory,
        files_directory: config.filesDirectory, database_encryption_key: config.encryptionKey,
        use_file_database: true, use_chat_info_database: true, use_message_database: true,
        use_secret_chats: false, api_id: config.apiId, api_hash: config.apiHash,
        system_language_code: 'zh', device_model: 'HarmonyOS NEXT', system_version: 'HarmonyOS',
        application_version: '0.1.0'
      });
    } else if (phase === 'authorizationStateWaitPhoneNumber') {
      this.current.phase = 'phone';
    } else if (phase === 'authorizationStateWaitCode') {
      this.current.phase = 'code';
      this.current.codeDelivery = auth.code_info?.type?.['@type'] || '';
      this.current.nextDelivery = auth.code_info?.next_type?.['@type'] || '';
      this.resendAt = Date.now() + Math.max(0, auth.code_info?.timeout || 0) * 1000;
    } else if (phase === 'authorizationStateWaitRegistration') {
      this.current.phase = 'registration';
      this.current.termsText = auth.terms_of_service?.text.text || '';
      this.current.minAge = auth.terms_of_service?.min_user_age || 0;
    } else if (phase === 'authorizationStateWaitPassword') {
      this.current.phase = 'password';
    } else if (phase === 'authorizationStateWaitEmailAddress') {
      this.current.phase = 'email';
    } else if (phase === 'authorizationStateWaitEmailCode') {
      this.current.phase = 'emailCode';
    } else if (phase === 'authorizationStateReady') {
      this.current.phase = 'ready';
      this.current.ready = true; this.setMediaNetwork(this.mediaNetwork);
      if (!this.readyInitialized) {
        this.readyInitialized = true;
        this.loadMoreChats();
        this.request('getContacts');
        this.meRequest = this.request('getMe');
      }
    } else if (phase === 'authorizationStateClosed') {
      this.current.phase = 'closed'; this.current.ready = false; this.current.connection = '连接已关闭';
      this.managedRequests.forEach((operation) => operation.reject(new Error('账户连接已关闭，请重新打开')));
      this.managedRequests.clear(); this.managedKeys.clear(); this.automaticMedia.clear(); this.automaticMediaChats.clear(); this.manualMedia.clear(); this.streamingVideos.clear();
      this.clientId = 0; this.readyInitialized = false; this.chats.clear(); this.users.clear();
      this.activeChat = 0; this.openedChat = 0; this.historyRequests.clear(); this.pendingSends.clear();
      this.requestedChats.clear(); this.privateChatRequests.clear(); this.contactIds.clear();
      this.historyInFlight.clear(); this.oldestMessages.clear(); this.historyEnded.clear(); this.historyStalls.clear();
      this.historyLoaded.clear(); this.historyErrors.clear(); this.resetViewedMessages();
      this.chatListRequest = ''; this.chatListEnded = false;
      this.localDrafts.clear(); this.draftRequests.clear(); this.draftInFlight.clear();
      this.photoFiles.clear(); this.photoDownloads.clear(); this.downloadRequests.clear();
      this.selfUserId = 0; this.meRequest = '';
      this.richMessageRequests.clear(); this.replyPreviewRequests.clear(); this.replyPreviewAttempted.clear();
      this.messageDetails.clear(); this.messagePermissions.clear(); this.propertyRequests.clear();
      this.messageActions.clear(); this.sendActionMessages.clear(); this.completedSendMessages.clear();
      this.repository.useRemoteData();
    } else if (phase === 'authorizationStateLoggingOut' || phase === 'authorizationStateClosing') {
      this.current.ready = false; this.current.phase = 'starting';
    } else {
      this.current.phase = 'unsupported';
      this.current.error = phase === 'authorizationStateWaitOtherDeviceConfirmation'
          ? 'Telegram 要求在另一台已登录设备上确认本次登录，请前往该设备。'
          : 'Telegram 要求额外的授权步骤，当前版本尚未支持。请使用官方客户端完成后重试。';
    }
  }

  private handle(event: TdEvent): void {
    const type = event['@type'];
    const responseKey = event['@extra'] || '';
    if (this.expiredAuthRequests.has(responseKey)) { this.expiredAuthRequests.delete(responseKey); return; }
    if ((type === 'ok' || type === 'error') && responseKey === this.pendingAuthRequest) { this.pendingAuthRequest = ''; this.authDeadline = 0; }
    const operation = this.managedRequests.get(responseKey);
    if (operation) {
      this.managedRequests.delete(responseKey);
      if (type === 'error') { operation.reject(new Error('操作未完成，请稍后重试')); }
      else { operation.resolve(event); }
      return;
    }
    if (this.managedKeys.has(responseKey)) { return; }
    const richRequest = this.richMessageRequests.get(responseKey);
    if (richRequest) {
      this.richMessageRequests.delete(responseKey);
      const original = this.messageDetails.get(this.messageKey(richRequest.chatId, richRequest.messageId));
      const existing = this.findMessage(richRequest.chatId, richRequest.messageId);
      if (original && existing) {
        if (type === 'richMessage') {
          const updated = this.mapMessage({ ...original, content: { ...original.content, message: event as unknown as TdRichMessage } });
          this.repository.upsertMessage(updated); this.refreshReplyPreviews(updated);
        } else { this.repository.upsertMessage({ ...existing, richLoading: false, richError: '无法加载全文，请重试' }); }
      }
      return;
    }
    if (responseKey.startsWith('getFullRichMessage:')) { return; }
    const replyPreview = this.replyPreviewRequests.get(responseKey);
    if (replyPreview) {
      this.replyPreviewRequests.delete(responseKey);
      const replying = this.findMessage(replyPreview.chatId, replyPreview.messageId);
      if (replying) {
        if (type === 'message') {
          const original = this.mapMessage(event as unknown as TdMessage, false);
          const detail = this.messageDetails.get(this.messageKey(replyPreview.chatId, replyPreview.messageId));
          if (detail?.reply_to) { detail.reply_to.chat_id = Number(original.chatId); detail.reply_to.message_id = Number(original.id); }
          const thumbnail = this.replyThumbnail((event as unknown as TdMessage).content, replyPreview.chatId);
          this.repository.upsertMessage({ ...replying, replyToChatId: original.chatId, replyToMessageId: original.id,
            replyThumbnailFileId: thumbnail?.id, replyThumbnailPath: thumbnail?.local.is_downloading_completed ? thumbnail.local.path : undefined,
            replyPreview: detail?.reply_to?.quote?.text.text ? concealedMessageText(detail.reply_to.quote.text.text,
              (detail.reply_to.quote.text.entities || []).map((e: TdTextEntity) => ({ offset: e.offset, length: e.length, type: e.type['@type'] }))) :
              concealedMessageText(original.text, original.entities), replySenderName: original.senderName });
        } else if (!this.messageDetails.get(this.messageKey(replyPreview.chatId, replyPreview.messageId))?.reply_to?.quote?.text.text) {
          this.repository.upsertMessage({ ...replying, replyPreview: '原消息不可用' });
        }
      }
      this.loadReplyPreviews();
      return;
    }
    if (this.handleMessageActionResponse(event, responseKey)) { return; }
    if (type === 'ok') {
      if (responseKey === this.chatListRequest) { this.chatListRequest = ''; }
      this.viewRequests.delete(responseKey);
      this.completeDraft(responseKey, true);
      return;
    }
    if (type === 'updateFile' && event.file) { this.updatePhoto(event.file); return; }
    if (type === 'file') {
      this.downloadRequests.delete(responseKey);
      this.updatePhoto(event as unknown as TdFile); return;
    }
    if (type === 'updateAuthorizationState' && event.authorization_state) { this.authorize(event.authorization_state); return; }
    if (type === 'updateConnectionState' && event.state) {
      const name = event.state['@type'];
      this.current.connection = name === 'connectionStateReady' ? '已连接' : name === 'connectionStateUpdating' ? '同步中' : name === 'connectionStateWaitingForNetwork' ? '等待网络' : '连接中';
      return;
    }
    if (type === 'error') {
      const extra = event['@extra'] || '';
      if (extra === this.chatListRequest) {
        this.chatListRequest = '';
        if (event.code === 404) { this.chatListEnded = true; return; }
      }
      const history = this.historyRequests.get(extra);
      if (history) { this.historyInFlight.delete(history.chatId); this.historyRequests.delete(extra); }
      this.completeDraft(extra, false);
      const download = this.downloadRequests.get(extra);
      if (download !== undefined) { this.photoDownloads.delete(download); this.downloadRequests.delete(extra);
        this.repository.updateMediaTransfer(download, 0, false, '下载失败，点击重试'); }
      const requestedChat = this.privateChatRequests.get(extra);
      if (requestedChat !== undefined) {
        this.privateChatRequests.delete(extra);
        this.requestedChats.delete(requestedChat);
      }
      const view = this.viewRequests.get(extra);
      if (view) {
        if (view.chatId === this.openedChat) { view.ids.forEach((id: string) => this.viewedMessages.delete(id)); }
        this.viewRequests.delete(extra);
      }
      if ((extra.startsWith('loadChats:') && event.code === 404) || extra.startsWith('viewMessages:')) { return; }
      const raw = JSON.parse(JSON.stringify(event)) as Record<string, unknown>;
      const errorMessage = String(raw['message'] || '');
      if ((this.current.phase === 'code' || this.current.phase === 'emailCode') && (event.code === 429 || errorMessage.includes('FLOOD'))) {
        const wait = /FLOOD_WAIT_(\d+)/.exec(errorMessage);
        this.resendAt = Date.now() + (wait ? Math.max(1, Number(wait[1])) : 60) * 1000;
      }
      this.current.error = this.describeError(errorMessage, event.code || 0);
      if (!this.current.ready && this.current.phase === 'starting') {
        this.current.phase = extra.startsWith('setTdlibParameters:') && event.code === 401 &&
          String(raw['message'] || '').includes('Wrong database encryption key') ? 'storageRecovery' : 'error';
      }
      if (history) { this.historyErrors.set(history.chatId, this.current.error); }
      if (requestedChat !== undefined) { this.historyErrors.set(requestedChat, this.current.error); }
      const pending = this.pendingSends.get(extra);
      if (pending) {
        // Preserve a newer draft too: a failed request must never silently discard user text.
        const newer = this.repository.getDraft(pending.chatId);
        if (!newer && pending.text && !pending.mediaPath) { this.setDraft(pending.chatId, pending.text); }
        this.repository.upsertMessage({ id: `failed:${extra}`, chatId: pending.chatId, text: pending.text,
          time: this.time(Math.floor(Date.now() / 1000)), outgoing: true, status: 'failed',
          mediaKind: pending.mediaKind || (pending.mediaPath ? 'photo' : undefined), mediaPath: pending.mediaPath,
          contentKind: pending.mediaKind, mediaAlbumId: pending.attachments && pending.attachments.length > 1 ? `failed:${extra}` : undefined });
        if (pending.attachments) {
          this.repository.deleteMessages(pending.chatId, [`failed:${extra}`]);
          pending.attachments.forEach((_item: MediaAttachment, index: number) => this.retainFailedMedia(pending, extra, index));
        }
        this.pendingSends.delete(extra);
      }
      return;
    }
    if (type === 'updateNewChat' && event.chat) {
      this.chats.set(event.chat.id, event.chat); this.syncChat(event.chat);
      this.restoreRemoteDraft(event.chat.id, event.chat.draft_message); return;
    }
    if (type === 'chat') {
      const chat = event as unknown as TdChat;
      this.chats.set(chat.id, chat); this.syncChat(chat);
      this.restoreRemoteDraft(chat.id, chat.draft_message);
      const extra = event['@extra'] || '';
      const requestedChat = this.privateChatRequests.get(extra);
      if (requestedChat !== undefined) {
        this.privateChatRequests.delete(extra);
        this.requestedChats.delete(requestedChat);
        if (chat.id === requestedChat) { this.activateChat(chat.id); }
        else { this.fail('返回的会话与请求不一致，请重新打开联系人。'); }
      }
      return;
    }
    if (type === 'updateUser' && event.user) { this.syncUser(event.user); return; }
    if (type === 'user') {
      const user = event as unknown as TdUser;
      if (responseKey === this.meRequest) { this.selfUserId = user.id; }
      this.syncUser(user);
      return;
    }
    if (type === 'users' && event.user_ids) {
      event.user_ids.forEach((id: number) => { this.contactIds.add(id); this.request('getUser', { user_id: id }); }); return;
    }
    if (type === 'updateUserStatus' && event.user_id && event.status) {
      const user = this.users.get(event.user_id);
      if (user) { user.status = event.status; this.syncUser(user); }
      return;
    }
    if (type === 'messages' && event.messages) {
      const album = this.pendingSends.get(responseKey);
      if (album?.attachments) {
        const attachments = album.attachments;
        attachments.forEach((_attachment: MediaAttachment, index: number) => {
          const item = event.messages?.[index];
          if (item && String(item.chat_id) === album.chatId) { this.repository.upsertMessage(this.mapMessage(item)); }
          else { this.retainFailedMedia(album, responseKey, index); }
        });
        this.pendingSends.delete(responseKey);
      }
      const history = this.historyRequests.get(responseKey);
      if (history) {
        // Merge avoids losing new-message updates arriving while history was loading.
        const messages = event.messages.filter((message: TdMessage | null): message is TdMessage => !!message && message.chat_id === history.chatId);
        messages.forEach((message: TdMessage) => this.repository.upsertMessage(this.mapMessage(message)));
        const ids = messages.filter((message: TdMessage) => !message.sending_state && Number.isSafeInteger(message.id) && message.id > 0)
          .map((message: TdMessage) => message.id);
        if (ids.length > 0) {
          if (history.fromId === 0) { this.historyEnded.delete(history.chatId); }
          const oldest = Math.min(...ids);
          this.oldestMessages.set(history.chatId, Math.min(this.oldestMessages.get(history.chatId) || oldest, oldest));
          if (history.fromId > 0 && oldest >= history.fromId) {
            const stalls = (this.historyStalls.get(history.chatId) || 0) + 1;
            this.historyStalls.set(history.chatId, stalls);
            if (stalls >= 2) { this.historyEnded.add(history.chatId); }
          } else { this.historyStalls.delete(history.chatId); }
        } else if (event.messages.length === 0) { this.historyEnded.add(history.chatId); }
        this.historyRequests.delete(responseKey); this.historyInFlight.delete(history.chatId);
        this.historyLoaded.add(history.chatId); this.historyErrors.delete(history.chatId);
        this.loadReplyPreviews();
      }
      return;
    }
    if ((type === 'updateNewMessage' || type === 'updateMessageSendSucceeded' || type === 'updateMessageSendFailed') && event.message) {
      const message = this.mapMessage(event.message);
      if (type === 'updateMessageSendFailed') { message.status = 'failed'; }
      this.repository.upsertMessage(message, event.old_message_id ? String(event.old_message_id) : '');
      this.loadReplyPreviews();
      if (event.old_message_id && type !== 'updateNewMessage') {
        const oldKey = this.messageKey(String(event.message.chat_id), String(event.old_message_id));
        this.messageDetails.delete(oldKey); this.messagePermissions.delete(oldKey);
        this.completedSendMessages.set(oldKey, event.message);
        if (this.completedSendMessages.size > 128) { this.completedSendMessages.delete(this.completedSendMessages.keys().next().value as string); }
        const token = this.sendActionMessages.get(oldKey);
        if (token) { this.finishSendAction(token, event.message, type === 'updateMessageSendFailed'); }
      }
      return;
    }
    if (type === 'message') {
      this.pendingSends.delete(event['@extra'] || '');
      this.repository.upsertMessage(this.mapMessage(event as unknown as TdMessage)); return;
    }
    if (type === 'updateDeleteMessages' && event.chat_id && event.message_ids && event.is_permanent) {
      this.removeMessages(String(event.chat_id), event.message_ids.map((id: number) => String(id))); return;
    }
    if (type === 'updateMessageEdited' && event.chat_id && event.message_id) {
      const key = this.messageKey(String(event.chat_id), String(event.message_id));
      const detail = this.messageDetails.get(key);
      if (detail) { detail.edit_date = event.edit_date || 0; }
      const message = this.findMessage(String(event.chat_id), String(event.message_id));
      if (message) { this.repository.upsertMessage({ ...message, editDate: event.edit_date || 0 }); }
      return;
    }
    if (type === 'updateMessageContent' && event.chat_id && event.message_id && event.new_content) {
      const messages = this.repository.getMessages(String(event.chat_id));
      const message = messages.find((item: ChatMessage) => item.id === String(event.message_id));
      if (message) {
        const detail = this.messageDetails.get(this.messageKey(message.chatId, message.id));
        const updated = this.mapMessage({ ...detail, '@type': 'message', id: event.message_id, chat_id: event.chat_id,
          date: message.date || 0, is_outgoing: message.outgoing, content: event.new_content });
        updated.time = message.time;
        updated.status = message.status;
        updated.senderId = message.senderId;
        updated.senderName = message.senderName;
        updated.senderColor = message.senderColor;
        this.repository.upsertMessage(updated);
        this.refreshReplyPreviews(updated);
        this.invalidateMessageProperties(message.chatId, message.id, true);
      }
      return;
    }
    if (event.chat_id) {
      const chat = this.chats.get(event.chat_id);
      if (!chat) { return; }
      if (type === 'updateChatLastMessage') { chat.last_message = event.last_message; if (event.positions) { chat.positions = event.positions; } }
      if (type === 'updateChatPosition' && event.position) {
        chat.positions = chat.positions.filter((position: TdPosition) => position.list['@type'] !== event.position?.list['@type']);
        chat.positions.push(event.position);
      }
      if (type === 'updateChatReadInbox' && event.unread_count !== undefined) { chat.unread_count = event.unread_count; }
      if (type === 'updateChatReadOutbox' && event.last_read_outbox_message_id !== undefined) {
        chat.last_read_outbox_message_id = event.last_read_outbox_message_id;
        if (chat.type.user_id !== this.selfUserId) { this.repository.updateOutboxRead(String(chat.id), event.last_read_outbox_message_id); }
      }
      if (type === 'updateChatTitle' && event.title) { chat.title = event.title; }
      if (type === 'updateChatPhoto') { chat.photo = event.photo; }
      if (type === 'updateChatNotificationSettings' && event.notification_settings) { chat.notification_settings = event.notification_settings; }
      if (type === 'updateChatDraftMessage') {
        chat.draft_message = event.draft_message;
        if (event.positions) { chat.positions = event.positions; }
      }
      this.syncChat(chat);
      if (type === 'updateChatDraftMessage') { this.restoreRemoteDraft(chat.id, event.draft_message); }
    }
  }

  private syncUser(user: TdUser): void {
    this.users.set(user.id, user);
    const name = `${user.first_name || ''} ${user.last_name || ''}`.trim() || 'Telegram 用户';
    this.repository.updateSenderName(`user:${user.id}`, name, this.color(user.id));
    if (this.activeChat && this.repository.getMessages(String(this.activeChat)).some((item: ChatMessage) => item.senderId === `user:${user.id}`)) {
      const senderPhoto = this.avatar(user.profile_photo?.small);
      this.repository.updateSenderAvatar(`user:${user.id}`, senderPhoto?.id, senderPhoto?.local.is_downloading_completed ? senderPhoto.local.path : '');
    }
    const online = user.status?.['@type'] === 'userStatusOnline';
    const isContact = user.is_contact || this.contactIds.has(user.id);
    const avatar = isContact || user.id === this.selfUserId ? this.avatar(user.profile_photo?.small) : undefined;
    const contact: Contact = { id: String(user.id), name: name, subtitle: online ? '在线' : '最近上线', avatar: name.slice(0, 1), color: this.color(user.id), online: online,
      avatarFileId: avatar?.id, avatarPath: avatar?.local.is_downloading_completed ? avatar.local.path : undefined };
    if (user.is_contact || this.contactIds.has(user.id)) { this.repository.upsertContact(contact); }
    this.chats.forEach((chat: TdChat) => { if (chat.type.user_id === user.id) { this.syncChat(chat); } });
  }

  private syncChat(chat: TdChat): void {
    this.repository.updateSenderName(`chat:${chat.id}`, chat.title, this.color(chat.id));
    const position = chat.positions?.find((item: TdPosition) => item.list['@type'] === 'chatListMain');
    if ((!position || position.order === '0') && chat.id !== this.activeChat) { this.repository.removeChat(String(chat.id)); return; }
    const saved = this.selfUserId > 0 && chat.type.user_id === this.selfUserId;
    const kind = saved ? 'saved' : chat.type['@type'] === 'chatTypePrivate' ? 'private'
      : chat.type.is_channel && chat.type.is_megagroup ? 'group'
      : chat.type.is_channel ? 'channel' : 'group';
    const user = chat.type.user_id ? this.users.get(chat.type.user_id) : undefined;
    const avatar = saved ? undefined : this.avatar(chat.photo?.small || user?.profile_photo?.small);
    const summary: ChatSummary = {
      id: String(chat.id), title: saved ? '收藏夹' : chat.title, subtitle: chat.last_message ? this.contentText(chat.last_message.content) : '暂无消息',
      avatar: saved ? '★' : chat.title.slice(0, 1), color: saved ? '#4098E6' : this.color(chat.id), kind: kind,
      time: chat.last_message ? this.time(chat.last_message.date) : '', unread: chat.unread_count || 0,
      pinned: position?.is_pinned || false, muted: (chat.notification_settings?.mute_for || 0) > 0,
      online: user?.status?.['@type'] === 'userStatusOnline', order: position?.order || '0',
      avatarFileId: avatar?.id, avatarPath: avatar?.local.is_downloading_completed ? avatar.local.path : undefined
    };
    const newlyVisible = !this.repository.getChats().some((item: ChatSummary) => item.id === summary.id);
    this.repository.upsertChat(summary);
    // updateNewChat can precede the first nonzero main-list position.
    if (newlyVisible) { this.restoreRemoteDraft(chat.id, chat.draft_message); }
  }

  private mapMessage(message: TdMessage, autoDownload: boolean = true): ChatMessage {
    this.messageDetails.set(this.messageKey(String(message.chat_id), String(message.id)), message);
    const mapped: ChatMessage = { id: String(message.id), chatId: String(message.chat_id), text: this.contentText(message.content),
      time: this.messageTime(message.date), date: message.date, outgoing: message.is_outgoing,
      status: !message.is_outgoing ? 'received' : message.sending_state?.['@type'] === 'messageSendingStateFailed' ? 'failed' : message.sending_state ? 'pending' : 'sent',
      canSave: message.can_be_saved, contentType: message.content['@type'],
      contentKind: message.content['@type'] === 'messageText' ? 'text' : message.content['@type'] === 'messagePhoto' ? 'photo' : message.content['@type'] === 'messageVideo' ? 'video' : 'other',
      mediaAlbumId: message.media_album_id ? String(message.media_album_id) : undefined,
      caption: message.content.caption?.text, editDate: message.edit_date || 0 };
    const formatted = ['messageText', 'messagePhoto', 'messageVideo', 'messageAnimation'].includes(message.content['@type']) ?
      message.content.text || message.content.caption : undefined;
    mapped.entities = (formatted?.entities || []).map((entity: TdTextEntity) => ({ offset: entity.offset,
      length: entity.length, type: entity.type['@type'], url: entity.type.url }));
    const preview = message.content.link_preview;
    if (preview) { mapped.linkPreview = { url: preview.url, title: preview.title || '',
      description: preview.description?.text || '', siteName: preview.site_name || '' }; }
    if (message.content['@type'] === 'messageRichMessage' && message.content.message) {
      mapped.richTruncated = message.content.message.is_full === false;
      const decoded = decodeRichBlocks(message.content.message.blocks || [], mapped);
      mapped.richBlocks = decoded.map((entry) => entry.block);
      let richOffset = 0;
      mapped.entities = [];
      mapped.text = mapped.richBlocks.map((block) => {
        const text = block.text || (block.media?.mediaKind === 'photo' ? '[图片]' : block.media ? '[视频]' : '');
        block.entities.forEach((entity) => mapped.entities?.push({ ...entity, offset: entity.offset + richOffset }));
        richOffset += text.length + 1; return text;
      }).join('\n');
      decoded.forEach((entry) => {
        const media = entry.block.media;
        if (!media || !entry.file) { return; }
        const file = this.photoFiles.get(entry.file.id) || entry.file; this.photoFiles.set(file.id, file);
        media.mediaPath = file.local.is_downloading_completed ? file.local.path : undefined;
        media.mediaDownloading = file.local.is_downloading_active;
        media.mediaProgress = Math.min(100, Math.floor((file.local.downloaded_size || 0) * 100 / Math.max(1, file.size || file.expected_size)));
        if (entry.thumbnail) {
          const thumbnail = this.photoFiles.get(entry.thumbnail.id) || entry.thumbnail; this.photoFiles.set(thumbnail.id, thumbnail);
          media.thumbnailFileId = thumbnail.id; media.thumbnailPath = thumbnail.local.is_downloading_completed ? thumbnail.local.path : undefined;
          if (autoDownload && this.activeChat === message.chat_id) { this.downloadFile(thumbnail.id, this.photoDownloadLimit); }
        }
        if (autoDownload && this.activeChat === message.chat_id) { this.downloadAutomatic(file.id, media.mediaKind === 'photo' ? 'photo' : 'video'); }
      });
    }
    if (message.content['@type'] === 'messageContact' && message.content.contact) {
      const contact = message.content.contact;
      mapped.contactName = `${contact.first_name || ''} ${contact.last_name || ''}`.trim() || '联系人';
      mapped.contactPhone = contact.phone_number;
    }
    const remoteChat = this.chats.get(message.chat_id);
    mapped.read = message.is_outgoing && !message.sending_state && remoteChat?.type.user_id !== this.selfUserId &&
      message.id <= (remoteChat?.last_read_outbox_message_id || 0);
    const origin = message.forward_info?.origin;
    if (origin) {
      const fromUser = origin.sender_user_id ? this.users.get(origin.sender_user_id) : undefined;
      mapped.forwardName = origin.sender_name || (fromUser ? `${fromUser.first_name || ''} ${fromUser.last_name || ''}`.trim() : '') ||
        this.chats.get(origin.sender_chat_id || origin.chat_id || 0)?.title || '来源未知';
    }
    const serviceLabel = this.serviceMessageText(message);
    if (serviceLabel) { mapped.service = true; mapped.text = serviceLabel; mapped.entities = []; }
    const sender = message.sender_id;
    if (sender?.['@type'] === 'messageSenderUser' && sender.user_id) {
      const user = this.users.get(sender.user_id);
      mapped.senderId = `user:${sender.user_id}`;
      mapped.senderName = user ? `${user.first_name || ''} ${user.last_name || ''}`.trim() || 'Telegram 用户' : 'Telegram 用户';
      mapped.senderColor = this.color(sender.user_id);
      if (autoDownload && this.activeChat === message.chat_id) {
        const avatar = this.avatar(user?.profile_photo?.small);
        mapped.senderAvatarFileId = avatar?.id; mapped.senderAvatarPath = avatar?.local.is_downloading_completed ? avatar.local.path : undefined;
      }
    } else if (sender?.['@type'] === 'messageSenderChat' && sender.chat_id) {
      mapped.senderId = `chat:${sender.chat_id}`;
      mapped.senderName = this.chats.get(sender.chat_id)?.title || '频道';
      mapped.senderColor = this.color(sender.chat_id);
    }
    const reply = message.reply_to;
    if (reply?.['@type'] === 'messageReplyToMessage') {
      // A zero chat/message ID denotes an unknown origin; never replace it with this chat.
      if (reply.chat_id && Number.isSafeInteger(reply.chat_id)) { mapped.replyToChatId = String(reply.chat_id); }
      if (reply.message_id && Number.isSafeInteger(reply.message_id)) { mapped.replyToMessageId = String(reply.message_id); }
      const original = mapped.replyToChatId && mapped.replyToMessageId ? this.findMessage(mapped.replyToChatId, mapped.replyToMessageId) : undefined;
      mapped.replyPreview = reply.quote?.text.text ? concealedMessageText(reply.quote.text.text, (reply.quote.text.entities || []).map((e: TdTextEntity) => ({ offset: e.offset, length: e.length, type: e.type['@type'] }))) :
        original ? concealedMessageText(original.text, original.entities) : reply.content ? this.contentText(reply.content) : '回复消息';
      mapped.replySenderName = original?.senderName;
      if (reply.content) {
        const thumbnail = this.replyThumbnail(reply.content, String(message.chat_id));
        mapped.replyThumbnailFileId = thumbnail?.id; mapped.replyThumbnailPath = thumbnail?.local.is_downloading_completed ? thumbnail.local.path : undefined;
      }
    }
    if (message.content['@type'] === 'messagePhoto' && !message.content.is_secret && !message.content.has_spoiler) {
      const sizes = (message.content.photo?.sizes || []).filter((size: TdPhotoSize) =>
        size.photo.size <= this.photoDownloadLimit && size.photo.expected_size <= this.photoDownloadLimit)
        .slice().sort((a: TdPhotoSize, b: TdPhotoSize) => b.width * b.height - a.width * a.height);
      const size = sizes[0];
      if (size) {
        const cached = this.photoFiles.get(size.photo.id);
        const file = cached || size.photo;
        this.photoFiles.set(file.id, file);
        mapped.mediaKind = 'photo'; mapped.mediaFileId = file.id; mapped.mediaWidth = size.width; mapped.mediaHeight = size.height;
        mapped.mediaSize = file.size || file.expected_size;
        mapped.mediaProgress = Math.min(100, Math.floor((file.local.downloaded_size || 0) * 100 / Math.max(1, mapped.mediaSize)));
        mapped.mediaDownloading = file.local.is_downloading_active;
        if (file.local.is_downloading_completed && file.local.path) { mapped.mediaPath = file.local.path; }
        if (autoDownload && this.activeChat === message.chat_id) { this.downloadPhoto(file.id); }
      }
    }
    if (message.content['@type'] === 'messageAnimatedEmoji' && message.content.emoji) {
      mapped.text = message.content.emoji; mapped.largeEmoji = true;
    }
    if (message.content['@type'] === 'messageSticker' && message.content.sticker) {
      const sticker = message.content.sticker;
      mapped.sticker = true; mapped.stickerEmoji = sticker.emoji;
      mapped.mediaWidth = sticker.width; mapped.mediaHeight = sticker.height;
      const source = sticker.format['@type'] === 'stickerFormatWebp' && sticker.sticker.size <= this.avatarDownloadLimit ? sticker.sticker : sticker.thumbnail?.file;
      if (source) {
        const file = this.photoFiles.get(source.id) || source;
        this.photoFiles.set(file.id, file); mapped.stickerFileId = file.id;
        if (file.local.is_downloading_completed) { mapped.stickerPath = file.local.path; }
        if (autoDownload && this.activeChat === message.chat_id) { this.downloadFile(file.id, this.avatarDownloadLimit); }
      }
    }
    if (message.content['@type'] === 'messageAnimation' && message.content.animation && !message.content.has_spoiler && !message.content.is_secret) {
      const animation = message.content.animation;
      const file = this.photoFiles.get(animation.animation.id) || animation.animation;
      this.photoFiles.set(file.id, file); mapped.mediaKind = 'video'; mapped.mediaFileId = file.id;
      if (autoDownload && this.activeChat === message.chat_id) { this.downloadAutomatic(file.id, 'animation'); }
      mapped.mediaWidth = animation.width; mapped.mediaHeight = animation.height; mapped.mediaDuration = animation.duration;
      mapped.mediaSize = file.size || file.expected_size;
      if (file.local.is_downloading_completed) { mapped.mediaPath = file.local.path; }
      const source = animation.thumbnail?.file;
      if (source) {
        const thumb = this.photoFiles.get(source.id) || source;
        this.photoFiles.set(thumb.id, thumb); mapped.thumbnailFileId = thumb.id;
        if (thumb.local.is_downloading_completed) { mapped.thumbnailPath = thumb.local.path; }
        if (autoDownload && this.activeChat === message.chat_id) { this.downloadFile(thumb.id, this.photoDownloadLimit); }
      }
    }
    if (message.content['@type'] === 'messageVideo' && !message.content.is_secret && !message.content.has_spoiler) {
      const video = message.content.video;
      if (video) {
        const file = this.photoFiles.get(video.video.id) || video.video;
        this.photoFiles.set(file.id, file);
        mapped.mediaKind = 'video'; mapped.mediaFileId = file.id;
        if (autoDownload && this.activeChat === message.chat_id) { this.downloadAutomatic(file.id, 'video'); }
        mapped.mediaWidth = video.width; mapped.mediaHeight = video.height; mapped.mediaDuration = video.duration;
        mapped.mediaSize = file.size || file.expected_size;
        mapped.mediaProgress = Math.min(100, Math.floor((file.local.downloaded_size || 0) * 100 / Math.max(1, mapped.mediaSize)));
        mapped.mediaDownloading = file.local.is_downloading_active;
        if (file.local.is_downloading_completed && file.local.path) { mapped.mediaPath = file.local.path; }
        const thumb = video.thumbnail?.file;
        if (thumb) {
          const cached = this.photoFiles.get(thumb.id) || thumb;
          this.photoFiles.set(cached.id, cached); mapped.thumbnailFileId = cached.id;
          if (cached.local.is_downloading_completed) { mapped.thumbnailPath = cached.local.path; }
          if (autoDownload && this.activeChat === message.chat_id) { this.downloadFile(cached.id, this.photoDownloadLimit); }
        }
      }
    }
    return mapped;
  }

  private replyThumbnail(content: TdContent, chatId: string): TdFile | undefined {
    if (content.is_secret || content.has_spoiler) { return undefined; }
    const photo = content.photo?.sizes.filter((size: TdPhotoSize) => size.photo.size <= this.avatarDownloadLimit && size.photo.expected_size <= this.avatarDownloadLimit)
      .slice().sort((a: TdPhotoSize, b: TdPhotoSize) => a.width * a.height - b.width * b.height)[0]?.photo;
    const source = photo || content.video?.thumbnail?.file || content.sticker?.thumbnail?.file || content.animation?.thumbnail?.file;
    if (!source || source.size > this.avatarDownloadLimit || source.expected_size > this.avatarDownloadLimit) { return undefined; }
    const file = this.photoFiles.get(source.id) || source; this.photoFiles.set(file.id, file);
    if (Number(chatId) === this.activeChat) { this.downloadFile(file.id, this.avatarDownloadLimit); }
    return file;
  }

  private quotedReplyText(reply: TdMessageReply | null | undefined, original: ChatMessage): string {
    const quote = reply?.quote?.text;
    return quote?.text ? concealedMessageText(quote.text, (quote.entities || []).map((entity: TdTextEntity) => ({
      offset: entity.offset, length: entity.length, type: entity.type['@type'] }))) : concealedMessageText(original.text, original.entities);
  }

  private loadReplyPreviews(): void {
    if (!this.current.ready || !this.activeChat) { return; }
    this.repository.getMessages(String(this.activeChat)).slice(-100).forEach((message: ChatMessage) => {
      if (this.replyPreviewRequests.size >= 12 || !message.replyToMessageId || !message.replyToChatId || message.replySenderName) { return; }
      const key = this.messageKey(message.chatId, message.id);
      if (this.replyPreviewAttempted.has(key)) { return; }
      this.replyPreviewAttempted.add(key);
      const request = this.request('getRepliedMessage', { chat_id: Number(message.chatId), message_id: Number(message.id) });
      if (request) { this.replyPreviewRequests.set(request, { chatId: message.chatId, messageId: message.id }); }
    });
  }

  private serviceMessageText(message: TdMessage): string {
    const type = message.content['@type'];
    const sender = message.sender_id;
    const user = sender?.user_id ? this.users.get(sender.user_id) : undefined;
    const name = user ? `${user.first_name || ''} ${user.last_name || ''}`.trim() || '成员' : '成员';
    if (['messageChatJoinByLink', 'messageChatJoinByRequest', 'messageChatJoinFromCommunity'].includes(type)) { return `${name} 加入了群聊`; }
    if (type === 'messageChatAddMembers') {
      const ids = message.content.member_user_ids || [];
      if (ids.length === 1 && ids[0] === sender?.user_id) { return `${name} 加入了群聊`; }
      return `${name} 添加了 ${ids.length} 位成员`;
    }
    if (type === 'messageChatDeleteMember') { return message.content.user_id === sender?.user_id ? `${name} 退出了群聊` : `${name} 移除了一位成员`; }
    if (type === 'messageChatChangeTitle') { return `${name} 将群名称改为「${message.content.title || ''}」`; }
    if (type === 'messageChatChangePhoto') { return `${name} 更新了群头像`; }
    if (type === 'messageChatDeletePhoto') { return `${name} 移除了群头像`; }
    if (type === 'messageBasicGroupChatCreate' || type === 'messageSupergroupChatCreate') { return `${name} 创建了群聊`; }
    if (type === 'messagePinMessage') { return `${name} 置顶了一条消息`; }
    if (type === 'messageScreenshotTaken') { return `${name} 截取了屏幕`; }
    if (type === 'messageContactRegistered') { return `${name} 加入了 Telegram`; }
    if (type === 'messageChatUpgradeTo' || type === 'messageChatUpgradeFrom') { return '群聊已升级'; }
    return '';
  }

  private messageKey(chatId: string, messageId: string): string { return `${chatId}/${messageId}`; }
  private validMessageRef(chatId: string, messageId: string): boolean {
    return /^-?[1-9]\d*$/.test(chatId) && /^[1-9]\d*$/.test(messageId) &&
      Number.isSafeInteger(Number(chatId)) && Number.isSafeInteger(Number(messageId));
  }
  private findMessage(chatId: string, messageId: string): ChatMessage | undefined {
    return this.repository.getMessages(chatId).find((message: ChatMessage) => message.id === messageId);
  }
  private emptyPermissions(error: string = ''): MessagePermissions {
    return { loading: false, loaded: false, error: error, canReply: false, canEdit: false,
      canDeleteForSelf: false, canDeleteForAll: false, canForward: false, canCopy: false };
  }
  getMessagePermissions(chatId: string, messageId: string): MessagePermissions {
    return { ...(this.messagePermissions.get(this.messageKey(chatId, messageId)) || this.emptyPermissions()) };
  }
  private invalidateMessageProperties(chatId: string, messageId: string, refreshObserved: boolean = false): void {
    const key = this.messageKey(chatId, messageId);
    const observed = this.messagePermissions.has(key);
    this.messagePermissions.delete(key);
    // Invalidate request identities too. A late response predating the content update
    // must not restore capabilities (or an error) over this replacement query.
    this.propertyRequests.forEach((ref: MessageRef, request: string) => {
      if (ref.chatId === chatId && ref.messageId === messageId) { this.propertyRequests.delete(request); }
    });
    if (refreshObserved && observed) { this.loadMessageProperties(chatId, messageId); }
  }
  loadMessageProperties(chatId: string, messageId: string): void {
    const key = this.messageKey(chatId, messageId);
    if (!this.current.ready || !this.validMessageRef(chatId, messageId) || !this.findMessage(chatId, messageId)) {
      this.messagePermissions.set(key, this.emptyPermissions('消息尚未就绪或已删除。')); this.emit(); return;
    }
    if (this.getMessagePermissions(chatId, messageId).loading) { return; }
    const permissions = this.emptyPermissions(); permissions.loading = true;
    this.messagePermissions.set(key, permissions);
    const request = this.request('getMessageProperties', { chat_id: Number(chatId), message_id: Number(messageId) });
    if (request) { this.propertyRequests.set(request, { chatId: chatId, messageId: messageId }); }
    else { this.messagePermissions.set(key, this.emptyPermissions(this.current.error)); }
    this.emit();
  }
  getMessageAction(token: string): MessageActionState | undefined {
    const action = this.messageActions.get(token);
    return action ? { ...action.state } : undefined;
  }
  private actionAllowed(chatId: string, messageId: string, permission: keyof MessagePermissions): boolean {
    const capabilities = this.getMessagePermissions(chatId, messageId);
    if (!this.current.ready || !this.validMessageRef(chatId, messageId) || !this.findMessage(chatId, messageId)) { return false; }
    if (!capabilities.loaded || capabilities.loading) {
      if (!capabilities.loading) { this.loadMessageProperties(chatId, messageId); }
      this.fail('正在重新检查消息权限，请稍后重试。'); return false;
    }
    if (capabilities[permission] !== true) {
      this.fail('当前消息不允许此操作，请重新打开菜单检查。'); return false;
    }
    return true;
  }
  private startMessageAction(kind: MessageActionKind, chatId: string, messageId: string, type: string,
    fields: Record<string, unknown>, details: { text?: string; draftText?: string; draftVersion?: number; revoke?: boolean; targetChatId?: string } = {}): string {
    // Serializing each kind prevents repeated taps from duplicating a send or forwarding twice.
    let pendingCount = 0;
    for (const action of this.messageActions.values()) {
      if (action.state.status === 'pending') { pendingCount++; }
      if (action.state.status === 'pending' && action.state.kind === kind && action.state.chatId === chatId &&
        action.state.messageId === messageId) { return ''; }
    }
    if (pendingCount >= 32) { this.fail('尚有较多操作等待确认，请稍后重试。'); return ''; }
    // Retain enough recent results for the UI, without retaining every edited draft forever.
    this.messageActions.forEach((action: ActionRequest, token: string) => {
      if (this.messageActions.size >= 256 && action.state.status !== 'pending') { this.messageActions.delete(token); }
    });
    this.current.error = '';
    const token = this.request(type, fields);
    if (!token) { return ''; }
    this.messageActions.set(token, { state: { status: 'pending', error: '', kind: kind, chatId: chatId,
      messageId: messageId, targetChatId: details.targetChatId }, text: details.text, draftText: details.draftText,
      draftVersion: details.draftVersion, revoke: details.revoke });
    this.emit();
    return token;
  }
  sendReply(chatId: string, text: string, replyToMessageId: string): string {
    if (!text.trim() || text.length > 4096 || !this.actionAllowed(chatId, replyToMessageId, 'canReply')) { return ''; }
    const original = this.messageDetails.get(this.messageKey(chatId, replyToMessageId));
    if (!original || this.requestedChats.has(Number(chatId))) { return ''; }
    // Received Saved Messages topics describe grouping, not a send destination.
    // TDLib MessageTopic::get_send_message_topic explicitly rejects that variant;
    // the reply reference itself still belongs to the Saved Messages chat.
    const topic = original.topic_id?.['@type'] === 'messageTopicSavedMessages' ? null : original.topic_id || null;
    return this.startMessageAction('reply', chatId, replyToMessageId, 'sendMessage', {
      chat_id: Number(chatId), topic_id: topic,
      reply_to: { '@type': 'inputMessageReplyToMessage', message_id: Number(replyToMessageId), quote: null, checklist_task_id: 0, poll_option_id: '' },
      options: null, reply_markup: null,
      input_message_content: { '@type': 'inputMessageText', text: { '@type': 'formattedText', text: text, entities: [] }, clear_draft: false }
    }, { text: text, draftText: this.repository.getDraft(chatId), draftVersion: this.localDrafts.get(Number(chatId))?.version || 0 });
  }
  editMessage(chatId: string, messageId: string, text: string): string {
    if (!this.actionAllowed(chatId, messageId, 'canEdit')) { return ''; }
    const message = this.messageDetails.get(this.messageKey(chatId, messageId));
    if (!message) { return ''; }
    if (message.content['@type'] === 'messageText') {
      if (!text.trim() || text.length > 4096) { this.fail('正文须为 1–4096 个字符。'); return ''; }
      return this.startMessageAction('edit', chatId, messageId, 'editMessageText', {
        chat_id: Number(chatId), message_id: Number(messageId), reply_markup: null,
        input_message_content: { '@type': 'inputMessageText', text: { '@type': 'formattedText', text: text, entities: [] }, clear_draft: false }
      }, { text: text });
    }
    if (message.content['@type'] === 'messagePhoto' || message.content['@type'] === 'messageVideo') {
      if (text.length > 1024) { this.fail('图片说明最多 1024 个字符。'); return ''; }
      return this.startMessageAction('edit', chatId, messageId, 'editMessageCaption', {
        chat_id: Number(chatId), message_id: Number(messageId), reply_markup: null,
        caption: { '@type': 'formattedText', text: text, entities: [] }, show_caption_above_media: message.content.show_caption_above_media === true
      }, { text: text });
    }
    return '';
  }
  deleteMessage(chatId: string, messageId: string, revoke: boolean): string {
    if (typeof revoke !== 'boolean' || !this.actionAllowed(chatId, messageId, revoke ? 'canDeleteForAll' : 'canDeleteForSelf')) { return ''; }
    return this.startMessageAction('delete', chatId, messageId, 'deleteMessages', {
      chat_id: Number(chatId), message_ids: [Number(messageId)], revoke: revoke
    }, { revoke: revoke });
  }
  forwardMessage(fromChatId: string, messageId: string, toChatId: string): string {
    if (!this.actionAllowed(fromChatId, messageId, 'canForward')) { return ''; }
    const target = this.chats.get(Number(toChatId));
    if (!this.validMessageRef(toChatId, messageId) || !target || target.type['@type'] === 'chatTypeSecret') {
      this.fail('请选择已加载的普通会话。'); return '';
    }
    // chat.permissions describes non-admin permissions, not the current user's effective rights.
    // TDLib validates the destination; errors never insert a fake forwarded message.
    return this.startMessageAction('forward', fromChatId, messageId, 'forwardMessages', {
      chat_id: Number(toChatId), topic_id: null, from_chat_id: Number(fromChatId), message_ids: [Number(messageId)],
      options: null, send_copy: false, remove_caption: false
    }, { targetChatId: toChatId });
  }
  loadReplyTarget(chatId: string, messageId: string): string {
    if (!this.current.ready || !this.validMessageRef(chatId, messageId)) { return ''; }
    const original = this.messageDetails.get(this.messageKey(chatId, messageId));
    if (original?.reply_to?.['@type'] !== 'messageReplyToMessage') { return ''; }
    return this.startMessageAction('locate', chatId, messageId, 'getRepliedMessage', { chat_id: Number(chatId), message_id: Number(messageId) });
  }
  private handleMessageActionResponse(event: TdEvent, key: string): boolean {
    if (!key) { return false; }
    const type = event['@type'];
    const property = this.propertyRequests.get(key);
    if (property) {
      this.propertyRequests.delete(key);
      const storageKey = this.messageKey(property.chatId, property.messageId);
      if (!this.findMessage(property.chatId, property.messageId)) { this.messagePermissions.delete(storageKey); return true; }
      if (type !== 'messageProperties') {
        this.messagePermissions.set(storageKey, this.emptyPermissions('无法检查消息权限，请重试。')); return true;
      }
      const properties = event as unknown as TdMessageProperties;
      const content = this.messageDetails.get(storageKey)?.content['@type'];
      this.messagePermissions.set(storageKey, { loading: false, loaded: true, error: '',
        canReply: properties.can_be_replied === true,
        canEdit: properties.can_be_edited === true && (content === 'messageText' || content === 'messagePhoto' || content === 'messageVideo'),
        canDeleteForSelf: properties.can_be_deleted_only_for_self === true,
        canDeleteForAll: properties.can_be_deleted_for_all_users === true,
        canForward: properties.can_be_forwarded === true,
        // can_be_copied is specifically for forwardMessages(send_copy=true), not clipboard text.
        canCopy: properties.can_be_saved === true });
      return true;
    }
    // Canceled property queries (including errors) are read-only obsolete results.
    // Consume them without reviving permissions or displaying a stale global error.
    if (key.startsWith('getMessageProperties:')) { return true; }
    const action = this.messageActions.get(key);
    if (!action || action.state.status !== 'pending') { return false; }
    if (type === 'error') {
      // Never surface TDLib's raw error text: it may include message content or request details.
      const error = action.state.kind === 'locate' ? '原消息无法加载，可能已删除或无权访问。'
        : `操作未成功（错误码 ${event.code || 0}），输入内容已保留。`;
      this.failMessageAction(key, error); return true;
    }
    if (action.state.kind === 'delete') {
      if (type === 'ok') {
        this.removeMessages(action.state.chatId, [action.state.messageId]);
        action.state.status = 'succeeded';
      } else { this.failMessageAction(key, '删除结果无法确认，请刷新后重试。'); }
      return true;
    }
    if (action.state.kind === 'forward') {
      const message = type === 'messages' && event.messages?.length === 1 ? event.messages[0] : null;
      if (!message || String(message.chat_id) !== action.state.targetChatId) {
        this.failMessageAction(key, '无法转发此消息，请检查目标会话权限。'); return true;
      }
      this.acceptSendAction(key, message); return true;
    }
    if (type !== 'message') { this.failMessageAction(key, '操作结果无法确认，请稍后重试。'); return true; }
    const message = event as unknown as TdMessage;
    if (!this.validMessageRef(String(message.chat_id), String(message.id))) {
      this.failMessageAction(key, '收到无效的消息结果，请稍后重试。'); return true;
    }
    if (action.state.kind === 'reply') {
      if (String(message.chat_id) !== action.state.chatId) { this.failMessageAction(key, '返回的会话与请求不一致。'); return true; }
      this.acceptSendAction(key, message); return true;
    }
    if (action.state.kind === 'edit' && (String(message.chat_id) !== action.state.chatId || String(message.id) !== action.state.messageId)) {
      this.failMessageAction(key, '返回的消息与编辑请求不一致，输入内容已保留。'); return true;
    }
    const mapped = this.mapMessage(message);
    this.repository.upsertMessage(mapped);
    this.refreshReplyPreviews(mapped);
    this.invalidateMessageProperties(mapped.chatId, mapped.id, true);
    if (action.state.kind === 'locate') {
      action.state.targetChatId = mapped.chatId; action.state.targetMessageId = mapped.id;
      const replying = this.findMessage(action.state.chatId, action.state.messageId);
      if (replying) {
        const detail = this.messageDetails.get(this.messageKey(replying.chatId, replying.id));
        if (detail?.reply_to) { detail.reply_to.chat_id = message.chat_id; detail.reply_to.message_id = message.id; }
        this.repository.upsertMessage({ ...replying, replyToChatId: mapped.chatId, replyToMessageId: mapped.id,
          replyPreview: this.quotedReplyText(detail?.reply_to, mapped), replySenderName: mapped.senderName });
      }
    }
    action.state.status = 'succeeded';
    return true;
  }
  private acceptSendAction(token: string, message: TdMessage): void {
    const action = this.messageActions.get(token);
    if (!action) { return; }
    const key = this.messageKey(String(message.chat_id), String(message.id));
    const completed = this.completedSendMessages.get(key);
    if (completed) { this.finishSendAction(token, completed, completed.sending_state?.['@type'] === 'messageSendingStateFailed'); return; }
    this.repository.upsertMessage(this.mapMessage(message));
    if (message.sending_state?.['@type'] === 'messageSendingStatePending') {
      this.sendActionMessages.set(key, token);
      action.state.targetChatId = String(message.chat_id); action.state.targetMessageId = String(message.id);
    } else { this.finishSendAction(token, message, !!message.sending_state); }
  }
  private finishSendAction(token: string, message: TdMessage, failed: boolean): void {
    const action = this.messageActions.get(token);
    if (!action || action.state.status !== 'pending') { return; }
    this.sendActionMessages.forEach((value: string, key: string) => { if (value === token) { this.sendActionMessages.delete(key); } });
    if (failed) { this.failMessageAction(token, '消息未发送成功，输入内容已保留。'); return; }
    this.repository.upsertMessage(this.mapMessage(message));
    action.state.targetChatId = String(message.chat_id); action.state.targetMessageId = String(message.id);
    action.state.status = 'succeeded';
    if (action.state.kind === 'reply' && action.text === action.draftText &&
      this.repository.getDraft(action.state.chatId) === action.draftText &&
      (this.localDrafts.get(Number(action.state.chatId))?.version || 0) === action.draftVersion) {
      this.setDraft(action.state.chatId, '');
    }
  }
  private failMessageAction(token: string, error: string): void {
    const action = this.messageActions.get(token);
    if (!action) { return; }
    action.state.status = 'failed'; action.state.error = error;
    this.sendActionMessages.forEach((value: string, key: string) => { if (value === token) { this.sendActionMessages.delete(key); } });
    this.current.error = error;
  }
  private removeMessages(chatId: string, ids: string[]): void {
    this.repository.deleteMessages(chatId, ids);
    ids.forEach((id: string) => {
      const key = this.messageKey(chatId, id);
      this.messageDetails.delete(key); this.messagePermissions.delete(key);
      // A late property response must not revive capabilities for a deleted message.
      this.propertyRequests.forEach((ref: MessageRef, request: string) => {
        if (ref.chatId === chatId && ref.messageId === id) { this.propertyRequests.delete(request); }
      });
    });
  }
  private refreshReplyPreviews(original: ChatMessage): void {
    this.messageDetails.forEach((detail: TdMessage) => {
      if (String(detail.reply_to?.chat_id) !== original.chatId || String(detail.reply_to?.message_id) !== original.id) { return; }
      const replying = this.findMessage(String(detail.chat_id), String(detail.id));
      if (replying) { this.repository.upsertMessage({ ...replying,
        replyPreview: this.quotedReplyText(detail.reply_to, original), replySenderName: original.senderName }); }
    });
  }
  private contentText(content: import('./TdTypes').TdContent): string {
    if (content.text?.text) { return content.text.text; }
    const type = content['@type'];
    if (type === 'messageRichMessage' && content.message) {
      return decodeRichBlocks(content.message.blocks || [], { id: '', chatId: '', text: '', time: '', status: 'received', outgoing: false })
        .map((entry) => entry.block.text || (entry.block.media ? '[媒体]' : '')).join('\n');
    }
    if (type === 'messageContact' && content.contact) { return `[联系人] ${content.contact.first_name || ''} ${content.contact.last_name || ''}`.trim(); }
    if (type === 'messageAnimatedEmoji' && content.emoji) { return content.emoji; }
    if (type === 'messageDocument' && content.document) { return `📄 ${content.document.file_name || '文件'}` + (content.caption?.text ? `\n${content.caption.text}` : ''); }
    if (type === 'messageVoiceNote' && content.voice_note) {
      const seconds = Math.max(0, Math.floor(content.voice_note.duration));
      return `[语音 ${Math.floor(seconds / 60)}:${(seconds % 60).toString().padStart(2, '0')}]` + (content.caption?.text ? `\n${content.caption.text}` : '');
    }
    if (type === 'messagePoll' && content.poll) { return content.poll.question.text + '\n' + content.poll.options.map((option) => '○ ' + option.text.text).join('\n'); }
    const label = type === 'messagePhoto' ? '[图片]' : type === 'messageVideo' ? '[视频]' : type === 'messageVoiceNote' ? '[语音]' : type === 'messageSticker' ? '[贴纸]' : type === 'messageDocument' ? '[文件]' : type === 'messageAnimation' ? '[动画]' : type === 'messageCall' ? '[通话]' : type === 'messageLocation' ? '[位置]' : '[暂不支持的消息]';
    return content.caption?.text ? `${label} ${content.caption.text}` : label;
  }
  private time(seconds: number): string {
    const date = new Date(seconds * 1000);
    const now = new Date();
    return date.toDateString() === now.toDateString()
      ? `${date.getHours().toString().padStart(2, '0')}:${date.getMinutes().toString().padStart(2, '0')}`
      : `${date.getMonth() + 1}/${date.getDate()}`;
  }
  private messageTime(seconds: number): string {
    if (!Number.isFinite(seconds) || seconds <= 0) { return ''; }
    const date = new Date(seconds * 1000);
    return `${date.getHours().toString().padStart(2, '0')}:${date.getMinutes().toString().padStart(2, '0')}`;
  }
  private color(id: number): string { return ['#5A9BD5', '#A087C8', '#65AA9B', '#D49C68', '#C3829A'][Math.abs(id) % 5]; }

  private avatar(file: TdFile | undefined): TdFile | undefined {
    if (!file || file.size > this.avatarDownloadLimit || file.expected_size > this.avatarDownloadLimit) { return undefined; }
    const cached = this.photoFiles.get(file.id);
    const current = cached || file;
    this.photoFiles.set(file.id, current);
    this.downloadFile(file.id, this.avatarDownloadLimit);
    return current;
  }
  private downloadPhoto(fileId: number): void { this.downloadAutomatic(fileId, 'photo'); }
  private downloadFile(fileId: number, limit: number): void {
    const file = this.photoFiles.get(fileId);
    if (!this.current.ready || !file || file.local.is_downloading_completed || file.local.is_downloading_active ||
      !file.local.can_be_downloaded || file.size > limit || file.expected_size > limit || this.photoDownloads.has(fileId)) { return; }
    const key = this.request('downloadFile', { file_id: fileId, priority: 16, offset: 0, limit: limit, synchronous: false });
    if (key) { this.photoDownloads.add(fileId); this.downloadRequests.set(key, fileId);
      this.repository.updateMediaTransfer(fileId, 0, true); }
  }
  private updatePhoto(file: TdFile): void {
    this.photoFiles.set(file.id, file);
    const total = file.size || file.expected_size;
    this.repository.updateMediaTransfer(file.id, file.local.is_downloading_completed ? 100 : Math.min(100, Math.floor((file.local.downloaded_size || 0) * 100 / Math.max(1, total))), file.local.is_downloading_active);
    if (file.local.is_downloading_completed) {
      this.photoDownloads.delete(file.id);
      if (file.local.path && file.size <= this.videoDownloadLimit) { this.repository.updatePhotoFile(file.id, file.local.path); }
      if (file.local.path && file.size <= this.photoDownloadLimit) { this.repository.updateThumbnailFile(file.id, file.local.path); }
      if (file.local.path && file.size <= this.avatarDownloadLimit) { this.repository.updateAvatarFile(file.id, file.local.path); }
    } else {
      this.repository.updatePhotoFile(file.id, '');
      this.repository.updateThumbnailFile(file.id, '');
      this.repository.updateAvatarFile(file.id, '');
      if (!file.local.is_downloading_active) { this.photoDownloads.delete(file.id); }
    }
  }

  loadMoreChats(): void {
    if (!this.current.ready || this.chatListEnded || this.chatListRequest) { return; }
    this.chatListRequest = this.request('loadChats', { chat_list: { '@type': 'chatListMain' }, limit: 100 });
  }
  getHistoryState(id: string): TelegramHistoryState {
    const chatId = Number(id);
    const valid = Number.isSafeInteger(chatId) && chatId !== 0;
    return { loading: valid && (this.historyInFlight.has(chatId) || this.requestedChats.has(chatId)),
      hasMore: valid && !this.historyEnded.has(chatId), loaded: valid && this.historyLoaded.has(chatId),
      error: valid ? this.historyErrors.get(chatId) || '' : '' };
  }
  loadOlderMessages(id: string): void {
    const chatId = Number(id);
    if (!this.current.ready || !Number.isSafeInteger(chatId) || chatId === 0 ||
      this.requestedChats.has(chatId) || this.historyEnded.has(chatId)) { return; }
    if (this.activeChat === chatId && this.openedChat !== chatId) { this.openChat(id); return; }
    if (!this.chats.has(chatId)) { return; }
    this.requestHistory(chatId, this.oldestMessages.get(chatId) || 0);
  }
  private requestHistory(chatId: number, fromId: number): void {
    if (this.historyInFlight.has(chatId)) { return; }
    this.historyErrors.delete(chatId);
    const key = this.request('getChatHistory', { chat_id: chatId, from_message_id: fromId, offset: 0, limit: 50, only_local: false });
    if (key) {
      this.historyRequests.set(key, { chatId: chatId, fromId: fromId });
      this.historyInFlight.add(chatId);
    } else { this.historyErrors.set(chatId, this.current.error); }
    this.emit();
  }

  setDraft(id: string, text: string): void {
    const chatId = Number(id);
    if (!this.current.ready || !Number.isSafeInteger(chatId) || chatId === 0 || text.length > 4096) { return; }
    this.repository.setDraft(id, text);
    const previous = this.localDrafts.get(chatId);
    if (!previous) {
      const remote = this.chats.get(chatId)?.draft_message;
      const remoteText = remote?.content['@type'] === 'draftMessageContentText' ? remote.content.text?.text || '' : '';
      // Navigation saves the composer even without edits. Do not replace the richer
      // server draft (reply, entities, preview options) just to save identical text.
      if (text === remoteText) { this.emit(); return; }
    }
    if (!previous || previous.text !== text) {
      this.localDrafts.set(chatId, { text: text, version: (previous?.version || 0) + 1, savedVersion: previous?.savedVersion || 0 });
    }
    this.flushDraft(chatId);
    this.emit();
  }
  private flushDraft(chatId: number): void {
    const draft = this.localDrafts.get(chatId);
    if (!this.current.ready || !draft || draft.version === draft.savedVersion || this.draftInFlight.has(chatId) ||
      this.requestedChats.has(chatId) || !this.chats.has(chatId)) { return; }
    const message = draft.text.length === 0 ? null : {
      '@type': 'draftMessage', reply_to: null, date: Math.floor(Date.now() / 1000), effect_id: '0', suggested_post_info: null,
      content: { '@type': 'draftMessageContentText', text: { '@type': 'formattedText', text: draft.text, entities: [] }, link_preview_options: null }
    };
    const key = this.request('setChatDraftMessage', { chat_id: chatId, topic_id: null, draft_message: message });
    if (key) { this.draftRequests.set(key, { chatId: chatId, version: draft.version }); this.draftInFlight.add(chatId); }
  }
  private completeDraft(key: string, success: boolean): void {
    const request = this.draftRequests.get(key);
    if (!request) { return; }
    this.draftRequests.delete(key); this.draftInFlight.delete(request.chatId);
    const current = this.localDrafts.get(request.chatId);
    if (current) {
      if (success) { current.savedVersion = request.version; }
      // A failed old version must not strand a newer edit. Retry that new version
      // once, but leave a failed current version pending until a user action retries.
      if (success || current.version > request.version) { this.flushDraft(request.chatId); }
    }
  }
  private restoreRemoteDraft(chatId: number, draft: TdDraft | null | undefined): void {
    // Local edits own this session. Even a late echo after Ok cannot replace newer typed text.
    // On the next client session TDLib's persisted draft becomes the initial source again.
    if (this.localDrafts.has(chatId)) { return; }
    if (!draft) { this.repository.setDraft(String(chatId), ''); }
    else if (draft.content['@type'] === 'draftMessageContentText') {
      this.repository.setDraft(String(chatId), draft.content.text?.text || '');
    }
  }

  openChat(id: string): void {
    if (!this.current.ready) { return; }
    const chatId = Number(id);
    if (!Number.isSafeInteger(chatId) || chatId === 0) { return; }
    if (this.openedChat && this.openedChat !== chatId) {
      this.request('closeChat', { chat_id: this.openedChat });
      this.openedChat = 0;
      this.resetViewedMessages();
    }
    this.activeChat = chatId;
    if (this.requestedChats.has(chatId)) { return; }
    if (!this.chats.has(chatId) && chatId > 0) { this.ensurePrivateChat(chatId); return; }
    this.activateChat(chatId);
  }
  private ensurePrivateChat(chatId: number): void {
    if (this.chats.has(chatId) || this.requestedChats.has(chatId)) { return; }
    this.historyErrors.delete(chatId);
    const key = this.request('createPrivateChat', { user_id: chatId, force: false });
    if (key) {
      this.requestedChats.add(chatId);
      this.privateChatRequests.set(key, chatId);
    } else { this.historyErrors.set(chatId, this.current.error); }
    this.emit();
  }
  private activateChat(chatId: number): void {
    if (!this.current.ready || this.activeChat !== chatId || this.openedChat === chatId) { return; }
    if (!this.request('openChat', { chat_id: chatId })) { return; }
    this.openedChat = chatId;
    this.requestHistory(chatId, 0);
    const chat = this.chats.get(chatId);
    if (chat) { this.restoreRemoteDraft(chatId, chat.draft_message); }
    this.flushDraft(chatId);
    this.repository.getMessages(String(chatId)).forEach((message: ChatMessage) => {
      if (message.mediaKind === 'photo' && message.mediaFileId) { this.downloadPhoto(message.mediaFileId); }
      if (message.stickerFileId) { this.downloadFile(message.stickerFileId, this.avatarDownloadLimit); }
      if (message.thumbnailFileId) { this.downloadFile(message.thumbnailFileId, this.photoDownloadLimit); }
    });
  }
  /** Only the UI knows which messages have actually entered the viewport. */
  viewVisibleMessages(id: string, ids: string[]): void {
    const chatId = Number(id);
    if (this.activeChat !== chatId || this.openedChat !== chatId || !this.foreground || !this.current.ready) { return; }
    const received = new Set(this.repository.getMessages(id)
      .filter((message: ChatMessage) => !message.outgoing && message.status === 'received')
      .map((message: ChatMessage) => message.id));
    const visible = Array.from(new Set(ids)).filter((messageId: string) => {
      const value = Number(messageId);
      return Number.isSafeInteger(value) && value > 0 && received.has(messageId) && !this.viewedMessages.has(messageId);
    });
    if (visible.length === 0) { return; }
    const key = this.request('viewMessages', { chat_id: chatId, message_ids: visible.map((messageId: string) => Number(messageId)),
      source: { '@type': 'messageSourceChatHistory' }, force_read: false });
    if (key) {
      visible.forEach((messageId: string) => this.viewedMessages.add(messageId));
      this.viewRequests.set(key, { chatId: chatId, ids: visible });
    }
  }
  private resetViewedMessages(): void {
    this.viewedMessages.clear();
    this.viewRequests.clear();
  }
  leaveChat(): void {
    if (this.openedChat && this.current.ready) { this.request('closeChat', { chat_id: this.openedChat }); }
    this.activeChat = 0;
    this.openedChat = 0;
    this.resetViewedMessages();
  }
  setForeground(value: boolean): void {
    this.foreground = value;
    if (!value) { this.resetViewedMessages(); }
  }
  openContact(id: string): string {
    if (!this.current.ready) { return ''; }
    const user = this.users.get(Number(id));
    if (!user) { return ''; }
    this.repository.openContact(id);
    this.ensurePrivateChat(Number(id));
    return id;
  }
  getCurrentUser(): Contact | undefined {
    const user = this.users.get(this.selfUserId);
    if (!user) { return undefined; }
    const name = `${user.first_name || ''} ${user.last_name || ''}`.trim() || 'Telegram';
    const file = user.profile_photo?.small;
    const latest = file ? (this.photoFiles.get(file.id) || file) : undefined;
    return { id: String(user.id), name: name, subtitle: '', avatar: name.slice(0, 1),
      color: this.color(user.id), online: false, avatarFileId: latest?.id,
      avatarPath: latest?.local.is_downloading_completed ? latest.local.path : undefined };
  }
  openSavedMessages(): string {
    if (!this.current.ready || this.selfUserId <= 0) { this.fail('账号信息正在加载，请稍后重试。'); return ''; }
    const id = String(this.selfUserId);
    if (!this.repository.getChats().some((chat: ChatSummary) => chat.id === id)) {
      this.repository.upsertChat({ id: id, title: '收藏夹', subtitle: '', avatar: '★', color: '#4098E6',
        kind: 'saved', time: '', unread: 0, pinned: false, muted: false, online: false });
    }
    this.ensurePrivateChat(this.selfUserId);
    return id;
  }
  sendMessage(id: string, text: string): boolean {
    if (!this.current.ready || !text.trim() || text.trim().length > 4096) { return false; }
    const chatId = Number(id);
    if (!Number.isSafeInteger(chatId) || chatId === 0) { return false; }
    if (this.requestedChats.has(chatId)) { this.fail('会话仍在加载，请稍后发送。'); return false; }
    this.current.error = '';
    const key = this.request('sendMessage', { chat_id: chatId, input_message_content: { '@type': 'inputMessageText', text: { '@type': 'formattedText', text: text.trim(), entities: [] }, clear_draft: true } });
    if (!key) { return false; }
    this.pendingSends.set(key, { chatId: id, text: text.trim() });
    this.setDraft(id, '');
    return true;
  }
  sendPhoto(id: string, path: string, caption: string = ''): boolean {
    const chatId = Number(id);
    if (!this.current.ready || !Number.isSafeInteger(chatId) || chatId === 0 || !path.startsWith('/') ||
      path.includes('\0') || caption.length > 1024) { return false; }
    if (this.requestedChats.has(chatId)) { this.fail('会话仍在加载，请稍后发送。'); return false; }
    this.current.error = '';
    const key = this.request('sendMessage', { chat_id: chatId, input_message_content: {
      '@type': 'inputMessagePhoto', photo: { '@type': 'inputPhoto', photo: { '@type': 'inputFileLocal', path: path },
        thumbnail: null, video: null, added_sticker_file_ids: [], width: 0, height: 0 },
      caption: { '@type': 'formattedText', text: caption, entities: [] },
      show_caption_above_media: false, self_destruct_type: null, has_spoiler: false
    } });
    if (!key) { return false; }
    this.pendingSends.set(key, { chatId: id, text: caption, mediaPath: path });
    return true;
  }
  loadFullRichMessage(chatId: string, messageId: string): void {
    const message = this.findMessage(chatId, messageId);
    if (Number(chatId) !== this.activeChat || !message?.richTruncated || message.richLoading || !this.current.ready) { return; }
    const key = this.request('getFullRichMessage', { chat_id: Number(chatId), message_id: Number(messageId) });
    if (key) {
      this.richMessageRequests.set(key, { chatId: chatId, messageId: messageId, deadline: Date.now() + 30000 });
      this.repository.upsertMessage({ ...message, richLoading: true, richError: '' }); this.emit();
    }
  }

  /** Resolve only a visible, non-secret video belonging to the active chat. */
  videoFile(chatId: string, messageId: string, fileId: number): TdFile {
    const parent = this.findMessage(chatId, messageId);
    const item = parent?.mediaFileId === fileId ? parent : parent?.richBlocks?.find(block => block.media?.mediaFileId === fileId)?.media;
    const file = this.photoFiles.get(fileId);
    if (!this.current.ready || Number(chatId) !== this.activeChat || !item || item.mediaKind !== 'video' || !file ||
      !(file.size > 0 && file.size <= this.videoDownloadLimit)) { throw new Error('此视频暂不可播放，请重新打开会话'); }
    if (!this.streamingVideos.has(fileId)) { this.streamingVideos.set(fileId, { active: file.local.is_downloading_active, manual: this.manualMedia.has(fileId) }); }
    return file;
  }
  async videoPrefix(fileId: number, offset: number): Promise<number> {
    if (!this.streamingVideos.has(fileId)) { throw new Error('视频读取已关闭'); }
    const file = this.photoFiles.get(fileId);
    if (!file?.local.path || file.local.downloaded_size === 0) { return 0; }
    const result = await this.managedRequest('getFileDownloadedPrefixSize', { file_id: fileId, offset: offset });
    return (result as unknown as { size: number }).size;
  }
  async videoRange(fileId: number, offset: number, limit: number): Promise<void> {
    if (!this.streamingVideos.has(fileId)) { throw new Error('视频读取已关闭'); }
    const session = this.clientId;
    this.manualMedia.add(fileId);
    const event = await this.managedRequest('downloadFile', { file_id: fileId, priority: 32, offset: offset, limit: limit, synchronous: false });
    if (session !== this.clientId || !this.current.ready) { throw new Error('账户连接已改变，请重新打开视频'); }
    if (event['@type'] !== 'file') { throw new Error('无法缓冲此视频，请重试'); }
    this.updatePhoto(event as unknown as TdFile); this.emit();
  }
  stopVideoRange(fileId: number): void {
    const previous = this.streamingVideos.get(fileId); if (!previous) { return; }
    this.streamingVideos.delete(fileId);
    if (!previous.manual) { this.manualMedia.delete(fileId); }
    const file = this.photoFiles.get(fileId), kind = this.automaticMedia.get(fileId) || 'video';
    if (previous.active && (previous.manual || (file && autoDownloadAllowed(this.mediaPolicy, this.mediaNetwork, kind, file.size)))) {
      this.request('downloadFile', { file_id: fileId, priority: 16, offset: 0, limit: this.videoDownloadLimit, synchronous: false });
    } else { this.request('cancelDownloadFile', { file_id: fileId, only_if_pending: false }); this.photoDownloads.delete(fileId); }
  }

  downloadRichMedia(chatId: string, messageId: string, fileId: number, cancel: boolean = false): void {
    if (Number(chatId) !== this.activeChat) { return; }
    const parent = this.findMessage(chatId, messageId);
    const media = parent?.richBlocks?.find((block) => block.media?.mediaFileId === fileId)?.media;
    if (!media) { return; }
    if (cancel) {
      this.request('cancelDownloadFile', { file_id: fileId, only_if_pending: false }); this.photoDownloads.delete(fileId);
      this.repository.updateMediaTransfer(fileId, media.mediaProgress || 0, false); return;
    }
    const limit = media.mediaKind === 'video' ? this.videoDownloadLimit : this.photoDownloadLimit;
    if ((media.mediaSize || 0) > limit) { this.fail('媒体文件超过当前可下载大小限制'); return; }
    this.manualMedia.add(fileId); this.downloadFile(fileId, limit);
  }

  private retainFailedMedia(pending: PendingSend, key: string, index: number): void {
    const item = pending.attachments?.[index];
    if (!item) { return; }
    this.repository.upsertMessage({ id: `failed:${key}:${index}`, chatId: pending.chatId,
      text: index === 0 ? pending.text : '', caption: index === 0 ? pending.text : '',
      time: this.time(Math.floor(Date.now() / 1000)), outgoing: true, status: 'failed',
      mediaPath: item.path, mediaKind: item.kind, contentKind: item.kind,
      mediaAlbumId: pending.attachments && pending.attachments.length > 1 ? `failed:${key}` : undefined,
      mediaWidth: item.width, mediaHeight: item.height, mediaDuration: item.duration, mediaSize: item.size });
  }
  downloadMedia(chatId: string, messageId: string): void {
    const message = this.findMessage(chatId, messageId);
    if (!message || !message.mediaFileId || Number(chatId) !== this.activeChat) { return; }
    const limit = message.mediaKind === 'video' ? this.videoDownloadLimit : this.photoDownloadLimit;
    if ((message.mediaSize || 0) > limit) { this.fail('媒体文件超过当前可下载大小限制'); return; }
    this.manualMedia.add(message.mediaFileId); this.downloadFile(message.mediaFileId, limit);
  }
  cancelMedia(chatId: string, messageId: string): void {
    const message = this.findMessage(chatId, messageId);
    if (!message?.mediaFileId || Number(chatId) !== this.activeChat) { return; }
    this.request('cancelDownloadFile', { file_id: message.mediaFileId, only_if_pending: false });
    this.photoDownloads.delete(message.mediaFileId);
    this.repository.updateMediaTransfer(message.mediaFileId, message.mediaProgress || 0, false);
  }
  sendMedia(id: string, attachments: MediaAttachment[], caption: string = ''): boolean {
    const chatId = Number(id);
    if (!this.current.ready || !Number.isSafeInteger(chatId) || !chatId || attachments.length < 1 || attachments.length > 10 || caption.length > 1024) { return false; }
    if (this.requestedChats.has(chatId)) { this.fail('会话仍在加载，请稍后发送。'); return false; }
    if (attachments.some((item: MediaAttachment) => !item.path.startsWith('/') || item.path.includes('\0') ||
      (item.kind !== 'photo' && item.kind !== 'video') || !Number.isSafeInteger(item.size) || item.size <= 0 || [item.width, item.height, item.duration].some((value: number) => !Number.isSafeInteger(value) || value < 0 || value > 2147483647) || item.size > (item.kind === 'photo' ? 10000000 : this.videoDownloadLimit))) { return false; }
    const contents = attachments.map((item: MediaAttachment, index: number): Record<string, unknown> => {
      const common = { caption: { '@type': 'formattedText', text: index === 0 ? caption : '', entities: [] },
        show_caption_above_media: false, self_destruct_type: null, has_spoiler: false };
      if (item.kind === 'video') {
        return { '@type': 'inputMessageVideo', video: { '@type': 'inputVideo', video: { '@type': 'inputFileLocal', path: item.path },
          thumbnail: null, cover: null, start_timestamp: 0, added_sticker_file_ids: [],
          duration: Math.floor(item.duration), width: item.width, height: item.height, supports_streaming: false }, ...common };
      }
      return { '@type': 'inputMessagePhoto', photo: { '@type': 'inputPhoto', photo: { '@type': 'inputFileLocal', path: item.path },
        thumbnail: null, video: null, added_sticker_file_ids: [], width: item.width, height: item.height }, ...common };
    });
    this.current.error = '';
    const key = attachments.length === 1 ? this.request('sendMessage', { chat_id: chatId, input_message_content: contents[0] }) :
      this.request('sendMessageAlbum', { chat_id: chatId, topic_id: null, reply_to: null, options: null, input_message_contents: contents });
    if (!key) { return false; }
    this.pendingSends.set(key, { chatId: id, text: caption, attachments: attachments.map((item: MediaAttachment): MediaAttachment => ({ path: item.path, kind: item.kind,
      width: item.width, height: item.height, duration: item.duration, size: item.size })), mediaPath: attachments[0].path, mediaKind: attachments[0].kind });
    return true;
  }
  togglePinned(id: string): void {
    const chat = this.repository.getChats().find((item: ChatSummary) => item.id === id);
    if (chat && this.current.ready) { this.request('toggleChatIsPinned', { chat_list: { '@type': 'chatListMain' }, chat_id: Number(id), is_pinned: !chat.pinned }); }
  }
  toggleMuted(id: string): void {
    const chat = this.repository.getChats().find((item: ChatSummary) => item.id === id);
    const remote = this.chats.get(Number(id));
    if (chat && remote && this.current.ready) {
      const settings = { ...remote.notification_settings, '@type': 'chatNotificationSettings',
        use_default_mute_for: false, mute_for: chat.muted ? 0 : 2147483647 };
      this.request('setChatNotificationSettings', { chat_id: Number(id), notification_settings: settings });
    }
  }
  logOut(): void { if (this.current.ready) { this.request('logOut'); } }
  close(): void { if (this.clientId) { this.request('close'); } }

  private describeError(message: string, code: number): string {
    if (code === 401 && message.includes('Wrong database encryption key')) {
      return '本机登录数据无法解锁。原有缓存会保留，请重新登录。';
    }
    if (message.includes('API_ID_INVALID') || message.includes('API_ID_PUBLISHED_FLOOD')) { return '应用 API 配置无效或测试身份受限，请在开发者配置中填写自己的 API ID / Hash。'; }
    if (message.includes('FIRSTNAME_INVALID') || message.includes('LASTNAME_INVALID')) { return '姓名不符合 Telegram 要求，请修改后重试。'; }
    if (message.includes('PHONE_NUMBER_INVALID')) { return '手机号格式不正确，请检查国家区号。'; }
    if (message.includes('PHONE_CODE_INVALID') || message.includes('CODE_INVALID')) { return '验证码不正确，请重新输入。'; }
    if (message.includes('PHONE_CODE_EXPIRED')) { return '验证码已过期，请重新发起登录。'; }
    if (message.includes('PASSWORD_HASH_INVALID')) { return '两步验证密码不正确。'; }
    if (message.includes('FLOOD') || code === 429) { return '操作过于频繁，请稍后再试。'; }
    if (message.includes('PHONE_NUMBER_BANNED')) { return 'Telegram 无法使用此号码登录，请通过官方客户端核实账号状态。'; }
    if (message.includes('CHAT_WRITE_FORBIDDEN')) { return '当前会话没有发送权限。'; }
    return `Telegram 请求未成功（错误码 ${code}），请检查网络或稍后重试。`;
  }
}
