import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { chatRepository } from '../data/ChatRepository';

/** Single-writer persistence queue prevents an older async flush overwriting a newer edit. */
export class LocalStore {
  private static storage: preferences.Preferences | undefined = undefined;
  private static loading: Promise<void> | undefined = undefined;
  private static writes: Promise<void> = Promise.resolve();

  static async initialize(context: common.UIAbilityContext): Promise<void> {
    if (LocalStore.storage) { return; }
    if (!LocalStore.loading) { LocalStore.loading = LocalStore.load(context); }
    try { await LocalStore.loading; } catch (error) {
      LocalStore.loading = undefined;
      throw error as Error;
    }
  }

  private static async load(context: common.UIAbilityContext): Promise<void> {
    const storage = await preferences.getPreferences(context, { name: 'harlgram_local_v1' });
    const raw = await storage.get('snapshot', '');
    if (typeof raw === 'string' && raw.length > 0 && !chatRepository.restore(raw)) {
      // Retain the damaged source for diagnosis without exposing conversation text in logs.
      await storage.put('recovery_snapshot', raw);
      await storage.flush();
    }
    LocalStore.storage = storage;
  }

  static async save(): Promise<void> {
    // Real account content belongs only to the encrypted TDLib database.
    if (chatRepository.isRemote()) { return; }
    const snapshot = chatRepository.serialize();
    const write = LocalStore.writes.catch((): void => {}).then(async (): Promise<void> => {
      const storage = LocalStore.storage;
      if (!storage) { throw new Error('本地存储尚未初始化'); }
      await storage.put('snapshot', snapshot);
      await storage.flush();
    });
    LocalStore.writes = write;
    return write;
  }
}
