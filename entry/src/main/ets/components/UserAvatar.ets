@Component
export struct UserAvatar {
  @Prop text: string = '';
  @Prop color: string = '#5A9BD5';
  @Prop avatarSize: number = 48;
  @Prop online: boolean = false;
  @Prop avatarBorderColor: string = '#FFFFFF';
  @Prop @Watch('resetImage') imagePath: string = '';
  @State private imageFailed: boolean = false;

  private resetImage(): void { this.imageFailed = false; }
  private source(): string { return this.imagePath.startsWith('/') ? `file://${this.imagePath}` : this.imagePath; }

  build() {
    Stack({ alignContent: Alignment.BottomEnd }) {
      Text(this.text).fontSize(this.avatarSize * 0.33).fontWeight(FontWeight.Medium).fontColor('#FFFFFF')
        .width(this.avatarSize).height(this.avatarSize).textAlign(TextAlign.Center)
        .backgroundColor(this.color).borderRadius(this.avatarSize / 2)
      if (this.imagePath.length > 0 && !this.imageFailed) {
        Image(this.source()).width(this.avatarSize).height(this.avatarSize).objectFit(ImageFit.Cover)
          .borderRadius(this.avatarSize / 2).onError(() => { this.imageFailed = true; })
      }
      if (this.online) {
        Text('').width(12).height(12).backgroundColor('#53C5A3').borderRadius(6)
          .border({ width: 2.5, color: this.avatarBorderColor })
      }
    }.width(this.avatarSize).height(this.avatarSize)
  }
}
