import { window } from '@kit.ArkUI';
import { ChatMessage } from '../model/ChatModels';
import { mediaBytes } from '../model/MediaModels';
import { PhotoViewer } from './PhotoViewer';
import { VideoPlayer } from './VideoPlayer';

@Component
export struct MediaViewer {
  @Prop items: ChatMessage[] = [];
  @Prop initialId: string = '';
  @State private selectedId: string = '';
  @State private inset: number = 0;
  onClose: () => void = () => {};
  onSave: (item: ChatMessage) => void = () => {};
  onDownload: (item: ChatMessage) => void = () => {};
  onCancel: (item: ChatMessage) => void = () => {};
  aboutToAppear(): void {
    this.selectedId = this.initialId;
    try {
      const host = window.findWindow(this.getUIContext().getWindowName());
      this.inset = this.getUIContext().px2vp(host.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM).topRect.height);
    } catch (_) {}
  }
  private index(): number { return Math.max(0, this.items.findIndex((item: ChatMessage) => item.id === this.selectedId)); }
  private current(): ChatMessage { return this.items[this.index()]; }
  private step(delta: number): void {
    const index = this.index() + delta;
    if (index >= 0 && index < this.items.length) { this.selectedId = this.items[index].id; }
  }
  build() {
    Column() {
      Row({ space: 14 }) {
        Button({ type: ButtonType.Circle }) {
          Image($r('app.media.hg_close_white')).width(20).height(20)
        }.width(44).height(44).backgroundColor('#30343A').onClick(() => this.onClose()).accessibilityText('关闭媒体预览')
        Blank()
        Text(`${this.index() + 1} / ${this.items.length}`).fontColor(Color.White).fontSize(14)
        Blank()
        Button('保存').height(40).fontSize(14).fontColor(Color.White).backgroundColor('#30343A')
          .enabled(this.items.length > 0 && !!this.current().mediaPath && this.current().canSave !== false).onClick(() => this.onSave(this.current()))
      }.width('100%').padding({ top: this.inset + 8, bottom: 8, left: 12, right: 12 })
      if (this.items.length > 0) {
        if (this.current().mediaKind === 'video' && (this.current().mediaPath || this.current().mediaFileId)) {
          VideoPlayer({ path: this.current().mediaPath || '', fileId: this.current().mediaFileId || 0, chatId: this.current().chatId,
            messageId: this.current().sourceMessageId || this.current().id, downloadProgress: this.current().mediaProgress || 0,
            downloading: this.current().mediaDownloading || false, onDownload: () => this.onDownload(this.current()) }).layoutWeight(1)
        } else if (this.current().mediaPath) {
            PhotoViewer({ imagePath: this.current().mediaPath || '', embedded: true,
              onClose: () => this.onClose(), onNavigate: (delta: number) => this.step(delta) }).layoutWeight(1)
        } else {
          Column({ space: 20 }) {
            Blank()
            if (this.current().thumbnailPath) {
              Image('file://' + this.current().thumbnailPath).width('90%').height(220).objectFit(ImageFit.Contain)
            }
            Text(this.current().mediaError || mediaBytes(this.current().mediaSize || 0)).fontColor(Color.White)
            Button(this.current().mediaDownloading ? `${this.current().mediaProgress || 0}% · 取消` : '下载')
              .onClick(() => {
                if (this.current().mediaDownloading) { this.onCancel(this.current()); }
                else { this.onDownload(this.current()); }
              })
            Blank()
          }.width('100%').layoutWeight(1)
        }
        if (this.items.length > 1) {
          Row() {
            Button('‹').width(56).height(40).fontSize(26).fontColor(Color.White).backgroundColor('#30343A')
              .enabled(this.index() > 0).onClick(() => this.step(-1)).accessibilityText('上一个媒体')
            Blank()
            Button('›').width(56).height(40).fontSize(26).fontColor(Color.White).backgroundColor('#30343A')
              .enabled(this.index() < this.items.length - 1).onClick(() => this.step(1)).accessibilityText('下一个媒体')
          }.width('100%').padding({ top: 6, bottom: 12, left: 16, right: 16 })
        }
      } else { Blank() }
    }.width('100%').height('100%').backgroundColor('#101418')
  }
}
