@Component
export struct ComposerContextBar {
  @Prop title: string = '';
  @Prop preview: string = '';
  @Prop foreground: string = '#162B40';
  @Prop secondary: string = '#8493A5';
  @Prop busy: boolean = false;
  onCancel: () => void = () => {};

  build() {
    Row({ space: 10 }) {
      Text('').width(3).height(34).backgroundColor('#268BDE').borderRadius(2)
      Column({ space: 4 }) {
        Text(this.title).fontSize(12).fontColor('#268BDE').fontWeight(FontWeight.Medium)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.preview).fontSize(12).fontColor(this.secondary)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      if (this.busy) {
        LoadingProgress().width(24).height(24).color('#268BDE').margin(8)
      } else {
        Button({ type: ButtonType.Circle }) {
          Text('×').fontSize(24).fontColor(this.foreground)
        }.width(40).height(40).backgroundColor(Color.Transparent)
          .onClick(() => this.onCancel()).accessibilityText('取消回复或编辑')
      }
    }.width('100%').padding({ left: 8, right: 2, top: 2, bottom: 2 })
  }
}
