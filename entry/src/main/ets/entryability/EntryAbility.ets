import { AbilityConstant, Configuration, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { telegramService } from '../services/TelegramService';
import { WindowAppearance } from '../services/WindowAppearance';

const DOMAIN = 0x0000;

export default class EntryAbility extends UIAbility {
  private currentWindowStage: window.WindowStage | undefined = undefined;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');
  }

  onDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    this.currentWindowStage = windowStage;
    // Main window is created, set main page for this ability
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');

    this.loadWindowContent(windowStage).catch(() => {
      hilog.error(DOMAIN, 'Harlgram', 'Unable to initialize window content');
    });
  }

  private async loadWindowContent(windowStage: window.WindowStage): Promise<void> {
    try { await WindowAppearance.initialize(this.context); } catch {
      // Preferences errors must not leave a blank window; defaults remain published.
      hilog.warn(DOMAIN, 'Harlgram', 'Unable to restore appearance preferences; using current mode');
    }
    if (this.currentWindowStage !== windowStage) { return; }

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      if (this.currentWindowStage !== windowStage) { return; }
      WindowAppearance.attach(windowStage, this.context).catch(() => {
        hilog.warn(DOMAIN, 'Harlgram', 'Unable to synchronize system bar appearance');
      });
      hilog.info(DOMAIN, 'testTag', 'Succeeded in loading the content.');
    });
  }

  onWindowStageDestroy(): void {
    this.currentWindowStage = undefined;
    WindowAppearance.detach();
    // Main window is destroyed, release UI related resources
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    AppStorage.setOrCreate('mediaForeground', true);
    telegramService.setForeground(true);
    WindowAppearance.refreshSystemAppearance().catch(() => {
      hilog.warn(DOMAIN, 'Harlgram', 'Unable to restore system bar appearance');
    });
    // Ability has brought to foreground
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
  }

  onConfigurationUpdate(newConfig: Configuration): void {
    hilog.debug(DOMAIN, 'HarlgramTheme', 'Configuration color=%{public}d',
      newConfig.colorMode === undefined ? -2 : newConfig.colorMode);
    WindowAppearance.refreshSystemAppearance().catch(() => {
      hilog.warn(DOMAIN, 'Harlgram', 'Unable to synchronize changed system appearance');
    });
  }

  onBackground(): void {
    AppStorage.setOrCreate('mediaForeground', false);
    telegramService.setForeground(false);
    // Ability has back to background
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
  }
}
