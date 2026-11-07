import { window, uiAppearance } from '@kit.ArkUI';
import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppearanceMode, AppearanceState } from '../model/Appearance';
import { AppearancePreferences } from './AppearancePreferences';

/** Keep the system-owned safe areas in the same color scheme as the app. */
export class WindowAppearance {
  private static mainWindow: window.Window | undefined = undefined;
  private static context: common.UIAbilityContext | undefined = undefined;
  private static appearance: AppearanceState = new AppearanceState();
  private static initializing: Promise<void> | undefined = undefined;
  private static backgroundColor: string = '';
  private static mediaOverlay: boolean = false;
  private static appliedColorMode: ConfigurationConstant.ColorMode | undefined = undefined;
  private static generation: number = 0;
  private static pending: Promise<void> = Promise.resolve();
  private static focusListener: ((event: window.WindowEventType) => void) | undefined = undefined;

  static initialize(context: common.UIAbilityContext): Promise<void> {
    WindowAppearance.context = context;
    if (!WindowAppearance.initializing) {
      const revision = WindowAppearance.appearance.selectionRevision();
      WindowAppearance.initializing = AppearancePreferences.load(context).then((mode: AppearanceMode): void => {
        WindowAppearance.appearance.restore(mode, revision);
      }).finally((): void => {
        WindowAppearance.readSystemAppearance();
        WindowAppearance.publish();
      }).catch((error: Error) => {
        WindowAppearance.initializing = undefined;
        throw error;
      });
    }
    return WindowAppearance.initializing;
  }

  /** Call only after loadContent succeeds: window background APIs require loaded content. */
  static async attach(stage: window.WindowStage, context: common.UIAbilityContext): Promise<void> {
    const generation = ++WindowAppearance.generation;
    const main = await stage.getMainWindow();
    if (generation !== WindowAppearance.generation) { return; }
    WindowAppearance.removeFocusListener();
    WindowAppearance.context = context;
    WindowAppearance.mainWindow = main;
    WindowAppearance.appliedColorMode = undefined;
    // Control Center can take focus without taking the UIAbility out of the foreground.
    // Read the actual system appearance when focus returns, independently of config callbacks.
    const listener = (event: window.WindowEventType): void => {
      if (generation !== WindowAppearance.generation || event !== window.WindowEventType.WINDOW_ACTIVE) { return; }
      hilog.debug(0x0000, 'HarlgramTheme', 'Main window active; refreshing system appearance');
      WindowAppearance.refreshSystemAppearance().catch(() => {
        hilog.warn(0x0000, 'HarlgramTheme', 'Unable to refresh appearance after window activation');
      });
    };
    try {
      main.on('windowEvent', listener);
      WindowAppearance.focusListener = listener;
    } catch {
      hilog.warn(0x0000, 'HarlgramTheme', 'Unable to register window focus listener');
    }
    await WindowAppearance.reapply();
  }

  static detach(): void {
    WindowAppearance.generation++;
    WindowAppearance.removeFocusListener();
    WindowAppearance.mainWindow = undefined;
    WindowAppearance.context = undefined;
    WindowAppearance.appliedColorMode = undefined;
  }

  private static removeFocusListener(): void {
    const main = WindowAppearance.mainWindow;
    const listener = WindowAppearance.focusListener;
    WindowAppearance.focusListener = undefined;
    if (main && listener) {
      try { main.off('windowEvent', listener); } catch {
        hilog.warn(0x0000, 'HarlgramTheme', 'Unable to remove obsolete window focus listener');
      }
    }
  }

  static async setMode(mode: AppearanceMode): Promise<void> {
    WindowAppearance.appearance.select(mode);
    WindowAppearance.readSystemAppearance();
    WindowAppearance.publish();
    const apply = WindowAppearance.reapply();
    const context = WindowAppearance.context;
    if (!context) { await apply; throw new Error('外观设置暂时无法保存，请重试。'); }
    // Retry initialization after a storage failure, without letting its old value replace this selection.
    const save = AppearancePreferences.load(context).then(() => AppearancePreferences.save(mode));
    await Promise.all([apply, save]);
  }

  static refreshSystemAppearance(): Promise<void> {
    WindowAppearance.readSystemAppearance();
    WindowAppearance.publish();
    return WindowAppearance.reapply();
  }

  static setBackgroundColor(color: string): Promise<void> {
    WindowAppearance.backgroundColor = color;
    return WindowAppearance.reapply();
  }

  private static readSystemAppearance(): void {
    try {
      // Configuration.colorMode is the application value and may contain our override.
      const systemMode = uiAppearance.getDarkMode();
      WindowAppearance.appearance.updateSystemDark(systemMode === uiAppearance.DarkMode.ALWAYS_DARK);
      hilog.debug(0x0000, 'HarlgramTheme', 'preference=%{public}s system=%{public}d effective=%{public}d',
        WindowAppearance.appearance.getMode(), systemMode, WindowAppearance.appearance.isDark() ? 0 : 1);
    } catch {
      hilog.warn(0x0000, 'Harlgram', 'Unable to read system appearance; retaining last known mode');
    }
  }

  private static publish(): void {
    const mode = WindowAppearance.appearance.getMode();
    const dark = WindowAppearance.appearance.isDark();
    if (AppStorage.get<AppearanceMode>('harlgram.appearanceMode') !== mode) {
      AppStorage.setOrCreate<AppearanceMode>('harlgram.appearanceMode', mode);
    }
    if (AppStorage.get<boolean>('harlgram.darkMode') !== dark) {
      AppStorage.setOrCreate<boolean>('harlgram.darkMode', dark);
    }
  }

  static setMediaOverlay(visible: boolean): Promise<void> {
    WindowAppearance.mediaOverlay = visible;
    return WindowAppearance.reapply();
  }

  static reapply(): Promise<void> {
    // Serialize platform calls and read the latest theme when the work executes.
    const work = WindowAppearance.pending.catch(() => {}).then(async (): Promise<void> => {
      const main = WindowAppearance.mainWindow;
      if (!main) { return; }
      const mode = WindowAppearance.appearance.getMode();
      const dark = WindowAppearance.appearance.isDark();
      const background = WindowAppearance.mediaOverlay ? '#101418' : WindowAppearance.backgroundColor || (dark ? '#182430' : '#FFFFFF');
      const foreground = WindowAppearance.mediaOverlay || dark ? '#EEF4FC' : '#162B40';
      const applicationMode = mode === 'system' ? ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET :
        mode === 'dark' ? ConfigurationConstant.ColorMode.COLOR_MODE_DARK : ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT;
      if (WindowAppearance.appliedColorMode !== applicationMode) {
        WindowAppearance.context?.getApplicationContext().setColorMode(applicationMode);
        WindowAppearance.appliedColorMode = applicationMode;
      }
      main.setWindowBackgroundColor(background);
      await main.setWindowSystemBarProperties({
        statusBarColor: background,
        navigationBarColor: background,
        statusBarContentColor: foreground,
        navigationBarContentColor: foreground,
        enableStatusBarAnimation: false,
        enableNavigationBarAnimation: false
      });
    });
    WindowAppearance.pending = work;
    return work;
  }
}
