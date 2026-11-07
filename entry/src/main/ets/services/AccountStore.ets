import { asset } from '@kit.AssetStoreKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';

export interface AccountProfile { id: string; name: string; avatar?: string; color?: string; avatarPath?: string; avatarFileId?: number; }
export interface AccountRegistry { active: string; accounts: AccountProfile[]; pending?: string; version?: number; }

/** Account labels are private metadata; keep them in Asset, separate from message storage. */
export class AccountStore {
  private static writes: Promise<void> = Promise.resolve();
  private static alias(): Uint8Array { return new util.TextEncoder().encodeInto('harlgram.accounts.v1'); }
  static async load(): Promise<AccountRegistry> {
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, AccountStore.alias());
    query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
    try {
      const rows = await asset.query(query);
      if (rows.length === 0) { return { active: 'primary', accounts: [] }; }
      const bytes = rows[0].get(asset.Tag.SECRET) as Uint8Array;
      const value = JSON.parse(new util.TextDecoder().decodeToString(bytes)) as AccountRegistry;
      if (!value || !Array.isArray(value.accounts) ||
        !value.accounts.every((item: AccountProfile) => item && (item.id === 'primary' || /^[a-f0-9]{32}$/.test(item.id)) && typeof item.name === 'string') ||
        (value.active !== 'primary' && !/^[a-f0-9]{32}$/.test(value.active)) ||
        (value.pending !== undefined && !/^[a-f0-9]{32}$/.test(value.pending))) {
        throw new Error('账户列表无法读取');
      }
      // Migrate old unfinished slots into private login progress, never visible accounts.
      const unfinished = value.version === 2 ? [] : value.accounts.filter((item: AccountProfile) => item.name === '未登录账户');
      if (!value.pending && unfinished.length > 0) {
        value.pending = unfinished.find((item: AccountProfile) => item.id === value.active)?.id || unfinished[0].id;
      }
      if (value.version !== 2) { value.accounts = value.accounts.filter((item: AccountProfile) => item.name !== '未登录账户'); }
      value.version = 2;
      if (value.active !== 'primary' && value.active !== value.pending && !value.accounts.some((item: AccountProfile) => item.id === value.active)) {
        throw new Error('当前账户无法读取');
      }
      return value;
    } catch (error) {
      if ((error as BusinessError).code === 24000002) { return { active: 'primary', accounts: [] }; }
      throw error as Error;
    }
  }
  static save(value: AccountRegistry): Promise<void> {
    const snapshot: AccountRegistry = { active: value.active, accounts: value.accounts, pending: value.pending, version: 2 };
    const encoded = new util.TextEncoder().encodeInto(JSON.stringify(snapshot));
    const work = AccountStore.writes.catch(() => {}).then(async (): Promise<void> => {
      const attrs: asset.AssetMap = new Map();
      attrs.set(asset.Tag.ALIAS, AccountStore.alias());
      attrs.set(asset.Tag.SECRET, encoded);
      attrs.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED);
      attrs.set(asset.Tag.CONFLICT_RESOLUTION, asset.ConflictResolution.OVERWRITE);
      await asset.add(attrs);
    });
    AccountStore.writes = work;
    return work;
  }
}
