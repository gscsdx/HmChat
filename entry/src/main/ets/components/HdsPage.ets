import { HdsNavigation, HdsNavigationAttribute, HdsNavigationTitleMode, HdsNavigationMenuItemOptions } from '@kit.UIDesignKit';
import { SymbolGlyphModifier } from '@kit.ArkUI';

/** Shared native title bar. Content is bounded below the SDK's 56 vp MINI bar. */
@Component
export struct HdsPage {
  @Prop title: string = '';
  @Prop subtitle: string = '';
  @Prop showBack: boolean = true;
  @Prop isEnabled: boolean = true;
  @Prop dark: boolean = false;
  @Prop surface: boolean = false;
  @Prop firstLabel: string = '';
  @Prop firstEnabled: boolean = true;
  @Prop firstSymbol: Resource = $r('sys.symbol.ellipsis_circle');
  @Prop secondLabel: string = '';
  @Prop secondSymbol: Resource = $r('sys.symbol.magnifyingglass');
  onBack: () => void = () => {};
  firstAction: () => void = () => {};
  secondAction: () => void = () => {};
  @BuilderParam content: () => void = this.empty;
  @Builder private empty() {}
  private menus(): HdsNavigationMenuItemOptions[] {
    const items: HdsNavigationMenuItemOptions[] = [];
    if (this.firstLabel) items.push({ content: { label: this.firstLabel,
      icon: new SymbolGlyphModifier(this.firstSymbol).fontColor([$r('sys.color.icon_primary')]),
      isEnabled: this.isEnabled && this.firstEnabled, action: () => this.firstAction() } });
    if (this.secondLabel) items.push({ content: { label: this.secondLabel,
      icon: new SymbolGlyphModifier(this.secondSymbol).fontColor([$r('sys.color.icon_primary')]),
      isEnabled: this.isEnabled, action: () => this.secondAction() } });
    return items;
  }
  build() {
    HdsNavigation() {
      Column() { this.content() }.width('100%').height('100%').padding({ top: 56 })
    }.width('100%').height('100%').mode(NavigationMode.Stack).titleMode(HdsNavigationTitleMode.MINI)
      .hideBackButton(!this.showBack).hideToolBar(true)
      .titleBar({ content: {
        title: { mainTitle: this.title, subTitle: this.subtitle },
        backIcon: { label: '返回', isEnabled: this.isEnabled, action: () => this.onBack(),
          icon: new SymbolGlyphModifier($r('sys.symbol.chevron_backward')).fontColor([$r('sys.color.icon_primary')]) },
        menu: { value: this.menus() }
      } }).backgroundColor(this.surface ? (this.dark ? '#182430' : '#FFFFFF') : (this.dark ? '#101A25' : '#F4F7FB'))
  }
}
