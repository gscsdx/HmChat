import { ChatSummary } from '../model/ChatModels';
import { UserAvatar } from './UserAvatar';

@Component
export struct ForwardChatSheet {
  @Prop chats: ChatSummary[] = [];
  @Prop preview: string = '';
  @Prop busy: boolean = false;
  @Prop error: string = '';
  @Prop dark: boolean = false;
  @State private query: string = '';
  @State private selectedId: string = '';
  onForward: (chatId: string) => void = () => {};

  private foreground(): string { return this.dark ? '#EEF4FC' : '#162B40'; }
  private secondary(): string { return this.dark ? '#94A6BA' : '#8493A5'; }
  private surface(): string { return this.dark ? '#182430' : '#FFFFFF'; }
  private filteredChats(): ChatSummary[] {
    const query = this.query.trim().toLowerCase();
    const matches = this.chats.filter((chat: ChatSummary) => query.length === 0 || chat.title.toLowerCase().includes(query));
    return matches.filter((chat: ChatSummary) => chat.kind === 'saved')
      .concat(matches.filter((chat: ChatSummary) => chat.kind !== 'saved'));
  }
  private selectedTitle(): string {
    return this.chats.find((chat: ChatSummary) => chat.id === this.selectedId)?.title || '';
  }

  build() {
    Column({ space: 12 }) {
      Text(this.preview).fontSize(13).fontColor(this.secondary()).maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%').padding({ left: 6, right: 6 })
      Search({ value: this.query, placeholder: '搜索聊天' }).height(46).width('100%')
        .fontColor(this.foreground()).placeholderColor(this.secondary())
        .backgroundColor(this.dark ? '#101A25' : '#F4F7FB').enabled(!this.busy)
        .onChange((value: string) => { this.query = value; })
      List() {
        if (this.filteredChats().length === 0) {
          ListItem() {
            Text('没有找到聊天').fontSize(14).fontColor(this.secondary()).width('100%').padding(24)
              .textAlign(TextAlign.Center)
          }
        }
        ForEach(this.filteredChats(), (chat: ChatSummary) => {
          ListItem() {
            Row({ space: 12 }) {
              UserAvatar({ text: chat.avatar, color: chat.color, avatarSize: 42,
                imagePath: chat.avatarPath || '', avatarBorderColor: this.surface() })
              Text(chat.title).fontSize(15).fontColor(this.foreground()).maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
              Radio({ value: chat.id, group: 'forward-target' }).checked(chat.id === this.selectedId)
                .enabled(!this.busy).onChange((checked: boolean) => { if (checked) this.selectedId = chat.id; })
            }.width('100%').padding({ left: 10, right: 14, top: 10, bottom: 10 }).borderRadius(12)
              .backgroundColor(Color.Transparent)
              .enabled(!this.busy).onClick(() => { this.selectedId = chat.id; })
          }
        }, (chat: ChatSummary) => `${chat.id}:${chat.avatarPath || ''}:${chat.title}:${chat.id === this.selectedId}`)
      }.width('100%').layoutWeight(1).scrollBar(BarState.Auto)
      if (this.error.length > 0) {
        Text(this.error).fontSize(12).fontColor('#C55D5D').width('100%').maxLines(3)
      }
      Button(this.busy ? '正在转发…' : (this.selectedId.length > 0 ? `转发到「${this.selectedTitle()}」` : '选择一个聊天'))
        .buttonStyle(ButtonStyleMode.EMPHASIZED).height(48).width('100%')
        .enabled(this.selectedId.length > 0 && !this.busy).onClick(() => this.onForward(this.selectedId))
    }.width('100%').height('100%').padding({ left: 16, right: 16, top: 8, bottom: 18 }).backgroundColor(this.surface())
  }
}
