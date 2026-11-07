export type MediaNetwork = 'wifi' | 'mobile' | 'roaming' | 'unknown' | 'none';
export type AutoMediaKind = 'photo' | 'video' | 'animation';
export interface DownloadProfile { enabled: boolean; photos: boolean; videos: boolean; animations: boolean; photoLimit: number; videoLimit: number; animationLimit: number; }
export interface MediaPolicy { version: number; wifi: DownloadProfile; mobile: DownloadProfile; roaming: DownloadProfile; privateDays: number; groupDays: number; channelDays: number; cacheLimit: number; }
export interface CacheCategory { id: string; label: string; color: string; types: string[]; bytes: number; count: number; cleanable: boolean; }
export interface CacheChat { id: number; title: string; kind: string; bytes: number; }
export interface StorageSnapshot { categories: CacheCategory[]; chats: CacheChat[]; bytes: number; databaseBytes: number; logBytes: number; temporaryBytes: number; diskTotal: number; diskFree: number; }
export interface FileTypeUsage { file_type: { '@type': string }; size: number; count: number; }
export interface ChatStorageUsage { chat_id: number; size: number; count: number; by_file_type: FileTypeUsage[]; }
export interface StorageUsage { size: number; count: number; by_chat: ChatStorageUsage[]; }
export interface FastStorageUsage { files_size: number; database_size: number; language_pack_database_size: number; log_size: number; }
export interface NetworkUsageEntry { '@type': string; network_type: { '@type': string }; sent_bytes: number; received_bytes: number; }
export interface NetworkUsage { since_date: number; entries: NetworkUsageEntry[]; }
export interface StorageOptimize { size: number; ttl: number; count: number; immunity_delay: number; file_types: { '@type': string }[]; chat_ids: number[]; exclude_chat_ids: number[]; return_deleted_file_statistics: boolean; chat_limit: number; }
export const MAX_STORAGE_BYTES = 4503599627370495;
export const MAX_STORAGE_AGE = 2147483647;
export const RETENTION_DAYS: number[] = [0, 1, 7, 30, 90];
export const CACHE_LIMITS: number[] = [0, 1024 ** 3, 2 * 1024 ** 3, 5 * 1024 ** 3, 10 * 1024 ** 3];
export function defaultMediaPolicy(): MediaPolicy {
  return { version: 1, wifi: { enabled: true, photos: true, videos: false, animations: false, photoLimit: 20 * 1024 ** 2, videoLimit: 50 * 1024 ** 2, animationLimit: 10 * 1024 ** 2 },
    mobile: { enabled: true, photos: true, videos: false, animations: false, photoLimit: 1024 ** 2, videoLimit: 10 * 1024 ** 2, animationLimit: 5 * 1024 ** 2 },
    roaming: { enabled: false, photos: true, videos: false, animations: false, photoLimit: 1024 ** 2, videoLimit: 5 * 1024 ** 2, animationLimit: 1024 ** 2 },
    privateDays: 0, groupDays: 0, channelDays: 0, cacheLimit: 0 };
}
export function cloneMediaPolicy(policy: MediaPolicy): MediaPolicy { return { ...policy, wifi: { ...policy.wifi }, mobile: { ...policy.mobile }, roaming: { ...policy.roaming } }; }
export function validMediaPolicy(policy: MediaPolicy): boolean {
  if (!policy || policy.version !== 1 || !RETENTION_DAYS.includes(policy.privateDays) || !RETENTION_DAYS.includes(policy.groupDays) || !RETENTION_DAYS.includes(policy.channelDays) || !CACHE_LIMITS.includes(policy.cacheLimit)) { return false; }
  return [policy.wifi, policy.mobile, policy.roaming].every((p: DownloadProfile) => !!p && typeof p.enabled === 'boolean' && typeof p.photos === 'boolean' && typeof p.videos === 'boolean' && typeof p.animations === 'boolean' &&
    [p.photoLimit, p.videoLimit, p.animationLimit].every((n: number) => Number.isSafeInteger(n) && n > 0 && n <= 2 * 1024 ** 3));
}
export function autoDownloadAllowed(policy: MediaPolicy, network: MediaNetwork, kind: AutoMediaKind, bytes: number): boolean {
  if (network === 'none' || network === 'unknown' || !Number.isSafeInteger(bytes) || bytes <= 0) { return false; }
  const p = network === 'wifi' ? policy.wifi : network === 'roaming' ? policy.roaming : policy.mobile;
  return p.enabled && (kind === 'photo' ? p.photos && bytes <= p.photoLimit : kind === 'video' ? p.videos && bytes <= p.videoLimit : p.animations && bytes <= p.animationLimit);
}
export function emptyCategories(): CacheCategory[] {
  return [
    { id: 'photo', label: '图片', color: '#42A5F5', types: ['fileTypePhoto'], bytes: 0, count: 0, cleanable: true },
    { id: 'video', label: '视频', color: '#8E6CE8', types: ['fileTypeVideo', 'fileTypeVideoNote'], bytes: 0, count: 0, cleanable: true },
    { id: 'animation', label: '动图', color: '#E887AB', types: ['fileTypeAnimation'], bytes: 0, count: 0, cleanable: true },
    { id: 'sticker', label: '贴纸和 Emoji', color: '#F59B3A', types: ['fileTypeSticker'], bytes: 0, count: 0, cleanable: true },
    { id: 'avatar', label: '头像', color: '#46B9B0', types: ['fileTypeProfilePhoto'], bytes: 0, count: 0, cleanable: true },
    { id: 'document', label: '文件', color: '#6BBD66', types: ['fileTypeDocument'], bytes: 0, count: 0, cleanable: true },
    { id: 'audio', label: '音频和语音', color: '#E2B74D', types: ['fileTypeAudio', 'fileTypeVoiceNote'], bytes: 0, count: 0, cleanable: true },
    { id: 'other', label: '其他缓存', color: '#7692AE', types: ['fileTypeThumbnail', 'fileTypeWallpaper', 'fileTypeNotificationSound'], bytes: 0, count: 0, cleanable: true },
    { id: 'protected', label: '受保护文件', color: '#A6ACB5', types: [], bytes: 0, count: 0, cleanable: false }
  ];
}
export function storageCategories(stats: StorageUsage): CacheCategory[] {
  const categories = emptyCategories();
  (stats.by_chat || []).forEach((chat: ChatStorageUsage) => (chat.by_file_type || []).forEach((usage: FileTypeUsage) => {
    const category = categories.find((c: CacheCategory) => c.types.includes(usage.file_type['@type'])) || categories[categories.length - 1];
    category.bytes += Math.max(0, usage.size); category.count += Math.max(0, usage.count);
  }));
  return categories.sort((a: CacheCategory, b: CacheCategory) => b.bytes - a.bytes);
}
export function selectedCacheTypes(ids: string[]): string[] {
  const types: string[] = [];
  emptyCategories().filter((c: CacheCategory) => c.cleanable && ids.includes(c.id)).forEach((c: CacheCategory) => c.types.forEach((type: string) => types.push(type)));
  return types;
}
export function clearCacheCommand(ids: string[], chats: number[] = [], excluded: number[] = []): StorageOptimize | undefined {
  const types = selectedCacheTypes(ids);
  if (!types.length || chats.some((id: number) => !Number.isSafeInteger(id)) || excluded.some((id: number) => !Number.isSafeInteger(id))) { return undefined; }
  return { size: 0, ttl: 0, count: 0, immunity_delay: 0, file_types: types.map((type: string) => ({ '@type': type })),
    chat_ids: chats.slice(), exclude_chat_ids: excluded.slice(), return_deleted_file_statistics: true, chat_limit: 0 };
}
export function formatStorageBytes(bytes: number): string {
  if (!Number.isFinite(bytes) || bytes <= 0) { return '0 KB'; }
  if (bytes < 1024 ** 2) { return `${(bytes / 1024).toFixed(bytes < 10240 ? 1 : 0)} KB`; }
  if (bytes < 1024 ** 3) { return `${(bytes / 1024 ** 2).toFixed(1)} MB`; }
  return `${(bytes / 1024 ** 3).toFixed(1)} GB`;
}
export function retentionLabel(days: number): string { return days === 0 ? '永久保留' : days === 1 ? '1 天' : days === 7 ? '1 周' : days === 30 ? '1 个月' : '3 个月'; }
