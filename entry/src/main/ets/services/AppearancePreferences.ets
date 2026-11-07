import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { AppearanceMode, isAppearanceMode, migrateAppearanceMode } from '../model/Appearance';

/** Appearance persists independently of demo snapshots and Telegram account storage. */
export class AppearancePreferences {
  private static storage: preferences.Preferences | undefined = undefined;
  private static loading: Promise<AppearanceMode> | undefined = undefined;
  private static writes: Promise<void> = Promise.resolve();

  static load(context: common.UIAbilityContext): Promise<AppearanceMode> {
    if (!AppearancePreferences.loading) {
      AppearancePreferences.loading = AppearancePreferences.read(context).catch((error: Error) => {
        AppearancePreferences.loading = undefined;
        throw error;
      });
    }
    return AppearancePreferences.loading;
  }

  private static async read(context: common.UIAbilityContext): Promise<AppearanceMode> {
    const storage = await preferences.getPreferences(context, { name: 'harlgram_appearance_v1' });
    const stored = await storage.get('mode', '');
    if (typeof stored === 'string' && isAppearanceMode(stored)) {
      AppearancePreferences.storage = storage;
      return stored;
    }
    const legacyStorage = await preferences.getPreferences(context, { name: 'harlgram_local_v1' });
    const legacy = await legacyStorage.get('snapshot', '');
    const mode = migrateAppearanceMode(typeof stored === 'string' ? stored : '', typeof legacy === 'string' ? legacy : '');
    await storage.put('mode', mode);
    await storage.flush();
    AppearancePreferences.storage = storage;
    return mode;
  }

  static save(mode: AppearanceMode): Promise<void> {
    const work = AppearancePreferences.writes.catch(() => {}).then(async (): Promise<void> => {
      const storage = AppearancePreferences.storage;
      if (!storage) { throw new Error('外观设置暂时无法保存，请重试。'); }
      await storage.put('mode', mode);
      await storage.flush();
    });
    AppearancePreferences.writes = work;
    return work;
  }
}
