import { HdsListItemCard, HdsListItemCardAttribute, PrefixIcon, SuffixTextAndArrow } from '@kit.UIDesignKit';

/** Keep values reactive; the native card owns text, icon, trailing arrow and hit target. */
@Component
export struct HdsSettingsRow {
  @Prop title: string = '';
  @Prop value: string = '';
  @Prop icon: Resource | undefined = undefined;
  @Prop isEnabled: boolean = true;
  action: () => void = () => {};
  build() {
    HdsListItemCard({
      prefixItem: this.icon ? new PrefixIcon({ iconValue: { image: this.icon } }) : undefined,
      textItem: { primaryText: { text: this.title } },
      suffixItem: new SuffixTextAndArrow({ text: this.value }),
      cardBackgroundColor: Color.Transparent,
      enable: this.isEnabled, onClick: () => this.action()
    }).width('100%')
  }
}
