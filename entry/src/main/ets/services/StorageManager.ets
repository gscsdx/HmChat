import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { fileIo, statfs } from '@kit.CoreFileKit';
import { TdType } from '../telegram/TdTypes';
import { TelegramClient } from '../telegram/TelegramClient';
import { MediaNetworkMonitor } from './MediaNetworkMonitor';
import { MediaPolicy, MediaNetwork, StorageSnapshot, StorageUsage, CacheChat, ChatStorageUsage, NetworkUsage,
  defaultMediaPolicy, cloneMediaPolicy, validMediaPolicy, storageCategories, clearCacheCommand, selectedCacheTypes,
  MAX_STORAGE_BYTES, MAX_STORAGE_AGE } from '../model/StorageModels';

/** All media deletion goes through TDLib; no traversal of account database directories. */
export class StorageManager {
  private policy: MediaPolicy = defaultMediaPolicy();
  private storage: preferences.Preferences | undefined = undefined;
  private context: common.UIAbilityContext | undefined = undefined;
  private account: string = '';
  private epoch: number = 0;
  private busy: boolean = false;
  private operationVersion: number = 0;
  private lastMaintenance: number = 0;
  private writes: Promise<void> = Promise.resolve();
  private network: MediaNetwork = 'unknown';
  private monitor: MediaNetworkMonitor;
  private chatInfo: Map<number, CacheChat> = new Map<number, CacheChat>();
  private client: TelegramClient;
  constructor(client: TelegramClient) {
    this.client = client;
    this.monitor = new MediaNetworkMonitor((network: MediaNetwork) => {
      const changed = this.network !== network; this.network = network;
      if (changed) { this.client.setMediaNetwork(network); }
    });
  }
  currentAccount(): string { return this.account; }
  currentNetwork(): MediaNetwork { return this.network; }
  settings(): MediaPolicy { return cloneMediaPolicy(this.policy); }
  isBusy(): boolean { return this.busy; }
  async initialize(context: common.UIAbilityContext, account: string): Promise<void> {
    if (this.account === account && this.storage) { this.monitor.start(); return; }
    const epoch = ++this.epoch; this.operationVersion++; this.busy = false; this.account = account; this.context = context; this.chatInfo.clear(); this.lastMaintenance = 0;
    this.storage = undefined; this.policy = defaultMediaPolicy();
    let storage: preferences.Preferences;
    let raw: preferences.ValueType;
    try {
      storage = await preferences.getPreferences(context, { name: 'harlgram_media_' + account });
      raw = await storage.get('policy', '');
    } catch (_) {
      this.check(epoch); this.client.configureMediaPolicy(this.policy, this.network); this.monitor.start(); return;
    }
    let policy = defaultMediaPolicy();
    try { const stored = JSON.parse(typeof raw === 'string' ? raw : '') as MediaPolicy; if (validMediaPolicy(stored)) { policy = stored; } } catch (_) {}
    this.check(epoch); this.storage = storage; this.policy = policy;
    this.client.configureMediaPolicy(policy, this.network); this.monitor.start();
  }
  foreground(): void { this.monitor.start(); this.maintain(false).catch(() => {}); }
  private check(epoch: number): void { if (epoch !== this.epoch) { throw new Error('账户已切换，请重新打开存储管理'); } }
  async savePolicy(policy: MediaPolicy): Promise<void> {
    if (!validMediaPolicy(policy) || !this.storage) { throw new Error('无法保存媒体设置，请重试'); }
    const epoch = this.epoch, storage = this.storage, next = cloneMediaPolicy(policy);
    const work = this.writes.catch(() => {}).then(async () => {
      this.check(epoch); await storage.put('policy', JSON.stringify(next)); await storage.flush(); this.check(epoch);
      this.policy = next; this.client.configureMediaPolicy(next, this.network);
    });
    this.writes = work; await work;
  }
  async chat(id: number, bytes: number = 0): Promise<CacheChat> {
    if (!id) { return { id: 0, title: '其他会话与公共缓存', kind: 'other', bytes: bytes }; }
    const cached = this.chatInfo.get(id); if (cached) { return { id: cached.id, title: cached.title, kind: cached.kind, bytes: bytes }; }
    const epoch = this.epoch;
    try {
      const chat = await this.client.storageChat(id); this.check(epoch);
      const type = chat.type['@type'];
      const kind = type === 'chatTypePrivate' ? 'private' : type === 'chatTypeBasicGroup' ? 'group' :
        type === 'chatTypeSupergroup' ? (chat.type.is_channel ? 'channel' : 'group') : 'other';
      const item: CacheChat = { id: id, title: this.client.isSavedStorageChat(id) ? '收藏夹' : chat.title || '会话', kind: kind, bytes: bytes }; this.chatInfo.set(id, item); return item;
    } catch (_) { this.check(epoch); return { id: id, title: '会话信息暂不可用', kind: 'other', bytes: bytes }; }
  }
  private async temporaryBytes(): Promise<number> {
    const root = this.context?.cacheDir + '/harlgram-uploads';
    if (!await fileIo.access(root)) { return 0; }
    let total: number = 0;
    for (const name of await fileIo.listFile(root, { recursion: true, listNum: 10000 })) {
      const info = await fileIo.stat(root + '/' + name); if (info.isFile()) { total += info.size; }
    }
    return total;
  }
  async read(): Promise<StorageSnapshot> {
    const epoch = this.epoch;
    const stats = await this.client.storageStatistics(); this.check(epoch);
    const fast = await this.client.fastStorageStatistics(); this.check(epoch);
    const chats: CacheChat[] = await Promise.all(stats.by_chat.filter((c: ChatStorageUsage) => c.chat_id !== 0)
      .sort((a: ChatStorageUsage, b: ChatStorageUsage) => b.size - a.size).slice(0, 12)
      .map(async (row: ChatStorageUsage): Promise<CacheChat> => this.chat(row.chat_id, row.size)));
    this.check(epoch);
    let diskTotal: number = 0, diskFree: number = 0, temporary: number = -1;
    try { diskTotal = await statfs.getTotalSize(this.context?.filesDir || ''); diskFree = await statfs.getFreeSize(this.context?.filesDir || ''); } catch (_) {}
    try { temporary = await this.temporaryBytes(); } catch (_) {}
    this.check(epoch);
    return { categories: storageCategories(stats), chats: chats, bytes: stats.size,
      databaseBytes: fast.database_size + fast.language_pack_database_size, logBytes: fast.log_size,
      temporaryBytes: temporary, diskTotal: diskTotal, diskFree: diskFree };
  }
  async traffic(): Promise<NetworkUsage> { const epoch = this.epoch; const value = await this.client.networkStatistics(); this.check(epoch); return value; }
  async resetTraffic(): Promise<void> { const epoch = this.epoch; await this.client.resetNetworkStatistics(); this.check(epoch); }
  async clear(ids: string[], chatIds: number[] = []): Promise<number> {
    if (this.busy) { throw new Error('正在整理缓存，请稍候'); }
    const command = clearCacheCommand(ids, chatIds, this.client.protectedCacheChats());
    if (!command) { throw new Error('请选择可清理的缓存类型'); }
    this.busy = true; const epoch = this.epoch, operation = ++this.operationVersion;
    try { const deleted = await this.client.optimizeCache(command); this.check(epoch); return deleted.size; }
    finally { if (operation === this.operationVersion) { this.busy = false; } }
  }
  async maintain(force: boolean): Promise<void> {
    if (!this.client.state().ready || this.busy || (!force && Date.now() - this.lastMaintenance < 30 * 60 * 1000)) { return; }
    if (!this.policy.cacheLimit && !this.policy.privateDays && !this.policy.groupDays && !this.policy.channelDays) { return; }
    this.busy = true; const epoch = this.epoch, operation = ++this.operationVersion, policy = this.settings();
    try {
      const stats = await this.client.storageStatistics(); this.check(epoch);
      const buckets: Map<number, number[]> = new Map<number, number[]>();
      const protectedKinds: number[] = [];
      for (const row of stats.by_chat) {
        if (!row.chat_id) { continue; }
        const chat = await this.chat(row.chat_id); this.check(epoch);
        if (chat.kind === 'other') { protectedKinds.push(row.chat_id); continue; }
        const days = chat.kind === 'private' ? policy.privateDays : chat.kind === 'group' ? policy.groupDays : chat.kind === 'channel' ? policy.channelDays : 0;
        if (days > 0) { const ids = buckets.get(days) || []; ids.push(row.chat_id); buckets.set(days, ids); }
      }
      const types = selectedCacheTypes(['photo', 'video', 'animation', 'document', 'audio']).map((type: string): TdType => ({ '@type': type }));
      for (const days of Array.from(buckets.keys())) {
        this.check(epoch);
        await this.client.optimizeCache({ size: MAX_STORAGE_BYTES, ttl: days * 86400, count: MAX_STORAGE_AGE, immunity_delay: 3600,
          file_types: types, chat_ids: buckets.get(days) || [], exclude_chat_ids: protectedKinds.concat(this.client.protectedCacheChats()),
          return_deleted_file_statistics: false, chat_limit: 0 });
      }
      if (policy.cacheLimit && stats.size > policy.cacheLimit) {
        this.check(epoch);
        await this.client.optimizeCache({ size: policy.cacheLimit, ttl: MAX_STORAGE_AGE, count: MAX_STORAGE_AGE, immunity_delay: 3600,
          file_types: types, chat_ids: [], exclude_chat_ids: [0].concat(protectedKinds, this.client.protectedCacheChats()),
          return_deleted_file_statistics: false, chat_limit: 0 });
      }
      this.check(epoch); this.lastMaintenance = Date.now();
    } finally { if (operation === this.operationVersion) { this.busy = false; } }
  }
}
