import { uiMaterial } from '@kit.ArkUI';
import { deviceInfo } from '@kit.BasicServicesKit';

/** Use the system glass without a separate opaque gradient behind the whole bottom area. */
export class NativeBottomTabsStyle implements AttributeModifier<TabsAttribute> {
  private readonly floatingStyle: FloatingTabBarStyle = { maskColor: Color.Transparent, barBottomMargin: 12 };

  constructor() {
    if (deviceInfo.sdkApiVersion >= 26 && uiMaterial.isImmersiveMaterialSupported()) {
      this.floatingStyle.systemMaterial = new uiMaterial.ImmersiveMaterial({
        style: uiMaterial.ImmersiveStyle.ULTRA_THIN
      });
    }
  }

  applyNormalAttribute(instance: TabsAttribute): void {
    // Keep the existing API 24 minimum: never invoke the API 26 method on older devices.
    if (deviceInfo.sdkApiVersion >= 26) {
      instance.barFloatingStyle(this.floatingStyle);
    } else {
      instance.barBackgroundBlurStyle(BlurStyle.COMPONENT_THIN);
    }
  }
}
