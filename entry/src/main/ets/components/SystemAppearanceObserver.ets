import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppearanceMode } from '../model/Appearance';
import { WindowAppearance } from '../services/WindowAppearance';

/** Mount only after Environment.envProp registers its native color-mode source. */
@Component
export struct SystemAppearanceObserver {
  @StorageProp('colorMode') @Watch('colorModeChanged') private colorMode: ColorMode = ColorMode.LIGHT;
  @StorageProp('harlgram.appearanceMode') private appearanceMode: AppearanceMode = 'system';

  private colorModeChanged(): void {
    if (this.appearanceMode !== 'system') { return; }
    // ArkUI and AbilityKit color-mode enums have different numeric values: use this as a signal only.
    WindowAppearance.refreshSystemAppearance().catch(() => {
      hilog.warn(0x0000, 'HarlgramTheme', 'Unable to refresh appearance after render environment change');
    });
  }

  build() {
    Row() {}.width(0).height(0).accessibilityLevel('no').hitTestBehavior(HitTestMode.None)
  }
}
