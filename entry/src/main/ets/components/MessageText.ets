import { common } from '@kit.AbilityKit';
import { MessageEntity } from '../model/ChatModels';
import { MessageBlock, MessageRun, messageBlocks, safeMessageLink } from '../model/MessagePresentation';

/** Native spans preserve TDLib UTF-16 entity offsets; no HTML or WebView. */
@Component
export struct MessageText {
  @Prop @Watch('resetSpoilers') text: string = '';
  @Prop entities: MessageEntity[] = [];
  @Prop foreground: string = '#162B40';
  @Prop secondary: string = '#8493A5';
  @Prop rightMetadata: boolean = false;
  @Prop metadata: string = '';
  @Prop maxWidth: number = 380;
  @Prop textSize: number = 15;
  @Prop dark: boolean = false;
  @State private revealed: boolean = false;
  private resetSpoilers(): void { this.revealed = false; }
  private blocks(): MessageBlock[] { return messageBlocks(this.text, this.entities); }
  private activate(run: MessageRun): void {
    if (run.spoiler && !this.revealed) { this.revealed = true; return; }
    const link = safeMessageLink(run.link);
    if (!link) { return; }
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const action = /^https?:/i.test(link) ? context.openLink(link) :
      context.startAbility({ action: 'ohos.want.action.viewData', uri: link });
    action.catch(() => { this.getUIContext().getPromptAction().showToast({ message: '无法打开此链接' }); });
  }
  build() {
    Column({ space: 3 }) {
      ForEach(this.blocks(), (block: MessageBlock, blockIndex: number) => {
        Stack({ alignContent: Alignment.BottomEnd }) {
        Row({ space: 6 }) {
          Text() {
            ForEach(block.runs, (run: MessageRun) => {
              Span(run.text).fontSize(run.mono ? 14 : this.textSize)
                .fontWeight(run.bold ? FontWeight.Bold : FontWeight.Normal)
                .fontStyle(run.italic ? FontStyle.Italic : FontStyle.Normal)
                .fontFamily(run.mono ? 'monospace' : 'HarmonyOS Sans')
                .fontColor(run.spoiler && !this.revealed ? '#8493A5' : run.link ? '#268BDE' : this.foreground)
                .textBackgroundStyle({ color: run.spoiler && !this.revealed ? '#8493A5' : Color.Transparent, radius: 2 })
                .decoration({ type: run.strike ? TextDecorationType.LineThrough : run.underline ? TextDecorationType.Underline : TextDecorationType.None })
                .onClick(() => this.activate(run))
            })
            if (blockIndex === this.blocks().length - 1 && this.metadata.length > 0) {
              Span(this.rightMetadata ? '\u00A0'.repeat(Math.ceil(this.metadata.length * 1.6) + 2) : '\u00A0\u00A0' + this.metadata)
                .fontSize(11).fontColor(this.secondary)
            }
          }.fontSize(this.textSize).lineHeight(Math.max(21, this.textSize * 1.4)).fontColor(this.foreground).wordBreak(WordBreak.BREAK_WORD)
            .constraintSize({ maxWidth: this.maxWidth - (block.kind === 'quote' ? 12 : 0), minWidth: this.rightMetadata ? this.maxWidth - (block.kind === 'quote' ? 12 : 0) : 0 })
        }.alignItems(VerticalAlign.Top)
          .padding(block.kind === 'text' ? 0 : 7)
          .backgroundColor(block.kind === 'text' ? Color.Transparent : this.dark ? '#263949' : '#E6EEF5')
          .borderRadius(5).border({ width: { left: block.kind === 'quote' ? 3 : 0 }, color: '#268BDE' })
          .constraintSize({ maxWidth: this.maxWidth })
          if (this.rightMetadata && blockIndex === this.blocks().length - 1 && this.metadata) {
            Text(this.metadata).fontSize(11).fontColor(this.secondary).margin({ bottom: 2 }).hitTestBehavior(HitTestMode.None)
          }
        }.constraintSize({ maxWidth: this.maxWidth })
      })
    }.alignItems(HorizontalAlign.Start).constraintSize({ maxWidth: this.maxWidth })
  }
}
