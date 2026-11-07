import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';

/**
 * Persists only the selected API preset index so the chosen developer identity survives restarts.
 * API IDs, hashes and labels stay in the generated build configuration; nothing here mirrors them.
 */
export class LoginApiPreferences {
  private static storage: preferences.Preferences | undefined = undefined;
  private static opening: Promise<preferences.Preferences> | undefined = undefined;
  private static writes: Promise<void> = Promise.resolve();

  /** Reads the selected preset index, clamped to 0..max-1; invalid values fall back to 0. */
  static async load(context: common.UIAbilityContext, max: number): Promise<number> {
    const storage = await LoginApiPreferences.open(context);
    const stored = await storage.get('selected', 0);
    return LoginApiPreferences.clamp(typeof stored === 'number' ? stored : 0, max);
  }

  /** Queues a serialized write of the selected index; out-of-range values are clamped first. */
  static save(index: number, max: number): Promise<void> {
    const work = LoginApiPreferences.writes.catch(() => {}).then(async (): Promise<void> => {
      const storage = LoginApiPreferences.storage;
      if (!storage) { throw new Error('登录 API 预设暂时无法保存，请重试。'); }
      await storage.put('selected', LoginApiPreferences.clamp(index, max));
      await storage.flush();
    });
    LoginApiPreferences.writes = work;
    return work;
  }

  private static clamp(index: number, max: number): number {
    if (max <= 0 || !Number.isSafeInteger(index) || index < 0) { return 0; }
    return index > max - 1 ? max - 1 : index;
  }

  private static open(context: common.UIAbilityContext): Promise<preferences.Preferences> {
    const storage = LoginApiPreferences.storage;
    if (storage) { return Promise.resolve(storage); }
    if (!LoginApiPreferences.opening) {
      LoginApiPreferences.opening = preferences.getPreferences(context, { name: 'harlgram_login_api_v1' })
        .then((opened: preferences.Preferences): preferences.Preferences => {
          LoginApiPreferences.storage = opened;
          return opened;
        })
        .catch((error: Error) => {
          LoginApiPreferences.opening = undefined;
          throw error;
        });
    }
    return LoginApiPreferences.opening;
  }
}