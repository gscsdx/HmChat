import { HdsPage } from '../components/HdsPage';
import { HdsSettingsRow } from '../components/HdsSettingsRow';
import { StoragePage } from '../components/StoragePage';
import { ProxyPage } from '../components/ProxyPage';
import { clashService } from '../services/clash/ClashService';
import { common } from '@kit.AbilityKit';
import { KeyboardAvoidMode, SymbolGlyphModifier } from '@kit.ArkUI';
import { CommonModifier } from '@ohos.arkui.modifier';
import { WindowAppearance } from '../services/WindowAppearance';
import { AppearanceMode } from '../model/Appearance';
import { UserAvatar } from '../components/UserAvatar';
import { ComposerContextBar } from '../components/ComposerContextBar';
import { ForwardChatSheet } from '../components/ForwardChatSheet';
import { AttachmentService } from '../services/AttachmentService';
import { MessageText } from '../components/MessageText';
import { albumLayout, singleMediaSize, messagesGrouped, safeMessageLink, MediaFrame } from '../model/MessagePresentation';
import { MediaViewer } from '../components/MediaViewer';
import { MediaAttachment, mediaAlbumAt, mediaTime, mediaBytes } from '../model/MediaModels';
import { NativeBottomTabsStyle } from '../components/NativeBottomTabsStyle';
import { SystemAppearanceObserver } from '../components/SystemAppearanceObserver';
import { TELEGRAM_API_PRESETS, TelegramApiPreset } from '../config/TelegramBuildConfig';
import { LoginApiPreferences } from '../services/LoginApiPreferences';
import { ChatSummary, ChatMessage, Contact, MessagePermissions, RichContentBlock } from '../model/ChatModels';
import { chatRepository } from '../data/ChatRepository';
import { LocalStore } from '../services/LocalStore';
import { AccountProfile } from '../services/AccountStore';
import { telegramService, TelegramState } from '../services/TelegramService';
import { TelegramHistoryState } from '../telegram/TdTypes';
import { PhoneCountry, findPhoneCountry, searchPhoneCountries, matchPhoneCountryByDialCode,
  splitInternationalPhone, normalizePhoneNumber } from '../model/PhoneNumber';

interface PhotoDraft {
  chatId: string;
  path: string;
  caption: string;
  attachments: MediaAttachment[];
}

interface ComposerAction {
  chatId: string;
  messageId: string;
  mode: string;
  title: string;
  preview: string;
  text: string;
  caption: boolean;
  token: string;
  submittedText: string;
  error: string;
}

interface PendingMessageAction {
  token: string;
  kind: string;
  chatId: string;
  messageId: string;
  navigationIntent?: number;
}

interface MessageDialogButton { text: string; color: string; }

@Entry
@Component
struct Index {
  @StorageProp('harlgram.darkMode') @Watch('syncWindowBackground') private darkMode: boolean = false;
  @StorageProp('harlgram.appearanceMode') private appearanceMode: AppearanceMode = 'system';
  @State private menuVisible: boolean = false;
  @State private storageRoute: string = 'storage';
  @State @Watch('syncWindowBackground') private currentTab: number = 2;
  @State @Watch('syncWindowBackground') private page: string = 'home';
  @State private isTelegram: boolean = false;
  @State private showDeveloperConfig: boolean = false;
  @State private apiId: string = '';
  @State private apiHash: string = '';
  @State private loginApiIndex: number = 0;
  @State private phone: string = '';
  @State private callingCode: string = '+86';
  @State private selectedCountryIso: string = 'CN';
  @State private countrySearch: string = '';
  @State private countryPickerVisible: boolean = false;
  @State private authCode: string = '';
  @State private password: string = '';
  @State private registrationFirst: string = '';
  @State private registrationLast: string = '';
  @State private registrationAccepted: boolean = false;
  @State private email: string = '';
  @State private emailCode: string = '';
  @State private authSubmitting: boolean = false;
  @State private localError: string = '';
  @State private accountProfiles: AccountProfile[] = [];
  @State private activeAccountId: string = 'primary';
  @State private accountSwitching: boolean = false;
  @State private telegram: TelegramState = { phase: 'idle', error: '', connection: '', ready: false };
  @State private searchText: string = '';
  @State private chatSearchVisible: boolean = false;
  @State private searchBackgroundHeight: number = 0;
  @State private contactSearch: string = '';
  @State private selectedFilter: number = 0;
  @State private chats: ChatSummary[] = [];
  @State private messages: ChatMessage[] = [];
  @State private contacts: Contact[] = [];
  @State private currentUser: Contact | undefined = undefined;
  @State private draft: string = '';
  @State private ready: boolean = false;
  @State private appearanceObserverReady: boolean = false;
  @State private viewportWidth: number = 360;
  @State private photoDrafts: PhotoDraft[] = [];
  @State private choosingImage: boolean = false;
  @State private composerActions: ComposerAction[] = [];
  @State private selectedMessage: ChatMessage | undefined = undefined;
  @State private messagePermissions: MessagePermissions = {
    loading: false, loaded: false, error: '', canReply: false, canEdit: false,
    canDeleteForSelf: false, canDeleteForAll: false, canForward: false, canCopy: false
  };
  @State private forwardSheetVisible: boolean = false;
  @State private forwardMessageSource: ChatMessage | undefined = undefined;
  @State private forwardBusy: boolean = false;
  @State private forwardError: string = '';
  @State @Watch('mediaPresentationChanged') private photoViewerVisible: boolean = false;
  @State private mediaViewerId: string = '';
  @State private historyState: TelegramHistoryState = { loading: false, hasMore: true, loaded: false, error: '' };
  @State private activeChat: ChatSummary = {
    id: '', title: '', subtitle: '', avatar: '', color: '#268BDE', kind: 'private',
    time: '', unread: 0, pinned: false, muted: false, online: false
  };
  private readonly filters: string[] = ['全部', '未读', '群组', '频道'];
  private readonly tabBarStyle: NativeBottomTabsStyle = new NativeBottomTabsStyle();
  private readonly chatTabSymbol: TabBarSymbol = {
    normal: new SymbolGlyphModifier($r('sys.symbol.message')),
    selected: new SymbolGlyphModifier($r('sys.symbol.message_fill'))
  };
  private readonly contactsTabSymbol: TabBarSymbol = {
    normal: new SymbolGlyphModifier($r('sys.symbol.person_2')),
    selected: new SymbolGlyphModifier($r('sys.symbol.person_2_fill'))
  };
  private readonly settingsTabSymbol: TabBarSymbol = {
    normal: new SymbolGlyphModifier($r('sys.symbol.gearshape')),
    selected: new SymbolGlyphModifier($r('sys.symbol.gearshape_fill'))
  };
  private navigationStack: NavPathStack = new NavPathStack();
  private messageScroller: Scroller = new Scroller();
  private readonly chatSearchController: SearchController = new SearchController();
  private readonly chatSearchScroller: Scroller = new Scroller();
  private chatPaneHeight: number = 0;
  private chatSearchNeedsFocus: boolean = false;
  private draftTimer: number = -1;
  private pendingDraftChatId: string = '';
  private pendingDraftText: string = '';
  private attachmentEpoch: number = 0;
  private pendingBottomChatId: string = '';
  private wasAtBottom: boolean = true;
  private userMessageScrolling: boolean = false;
  private bottomLayoutRevision: number = 0;
  private messageContentHeight: number = 0;
  private messageViewportHeight: number = 0;
  private olderAnchorChatId: string = '';
  private olderAnchorFirstId: string = '';
  private olderAnchorCount: number = 0;
  private olderAnchorOffset: number = 0;
  private olderAnchorHeight: number = 0;
  private olderMessagesArrived: boolean = false;
  private historyScrollArmed: boolean = false;
  private initialHistoryExtraLoaded: boolean = false;
  private focusPhoneAfterPicker: boolean = false;
  private pendingMessageActions: PendingMessageAction[] = [];
  private pendingLocateChatId: string = '';
  private pendingLocateMessageId: string = '';
  private replyLocateGeneration: number = 0;
  private messageMenuOpen: boolean = false;
  private returnToAccountManagement: boolean = false;
  private pendingComposerFocusChatId: string = '';

  aboutToAppear(): void {
    // Register the native source before the child creates its @StorageProp link.
    this.getUIContext().runScopedTask(() => { Environment.envProp('colorMode', ColorMode.LIGHT); });
    this.appearanceObserverReady = true;
    // Resize the available page instead of moving Navigation above the keyboard.
    this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE);
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    LoginApiPreferences.load(context, TELEGRAM_API_PRESETS.length).then((index: number) => {
      // Ignore a stale index when presets changed since the choice was saved.
      if (index >= 0 && index < TELEGRAM_API_PRESETS.length) { this.loginApiIndex = index; }
    }).catch(() => {});
    LocalStore.initialize(context).catch(() => {
      this.toast('本地数据加载失败，当前更改可能无法保存');
    }).then(() => {
      this.syncWindowBackground();
      this.refresh();
      // 冷启动先呈现未登录设置页；会话恢复成功后由 becameReady 切到聊天 Tab。
      this.useOfflineSettings();
      this.ready = true;
      telegramService.subscribe((state: TelegramState) => {
        const becameReady = state.ready && !this.telegram.ready;
        if (state.error.length > 0 && state.error !== this.telegram.error) {
          this.getUIContext().getFocusController().clearFocus();
        }
        if (state.phase !== this.telegram.phase) { this.registrationAccepted = false; }
        this.telegram = state;
        this.accountProfiles = telegramService.accounts();
        this.activeAccountId = telegramService.activeAccount();
        this.authSubmitting = state.submitting === true;
        if (state.phase !== 'phone') { this.countryPickerVisible = false; }
        if (state.phase === 'closed') {
          this.closeChatSearch();
          this.attachmentEpoch += 1;
          this.photoDrafts = [];
          this.composerActions = [];
          this.selectedMessage = undefined;
          this.forwardMessageSource = undefined;
          this.forwardSheetVisible = false;
          this.forwardBusy = false;
          this.pendingMessageActions = [];
          this.photoViewerVisible = false;
          this.pendingBottomChatId = '';
          this.olderAnchorChatId = '';
          this.cancelPendingDraft();
          this.navigationStack.clear(false);
          this.isTelegram = false;
          this.activeChat = {
            id: '', title: '', subtitle: '', avatar: '', color: '#268BDE', kind: 'private',
            time: '', unread: 0, pinned: false, muted: false, online: false
          };
          this.messages = [];
          this.draft = '';
          this.phone = '';
          this.registrationFirst = '';
          this.registrationLast = '';
          this.registrationAccepted = false;
          this.apiHash = '';
          this.password = '';
          this.authCode = '';
          this.emailCode = '';
          if (this.returnToAccountManagement) {
            this.page = 'accounts';
            this.currentTab = 2;
          } else {
            // 退出登录或连接关闭：回到未登录设置页，不保留任何已登录假象。
            this.useOfflineSettings();
          }
        } else if (state.ready) {
          this.isTelegram = true;
          this.apiHash = '';
          this.password = '';
          this.authCode = '';
          this.emailCode = '';
          if (becameReady) {
            if (this.returnToAccountManagement) {
              this.page = 'accounts';
              this.currentTab = 2;
              this.returnToAccountManagement = false;
            } else {
              // 会话恢复或登录成功：离开启动过渡的设置页，进入聊天 Tab。
              this.page = 'home';
              this.currentTab = 0;
              this.syncNavigation();
            }
          }
        }
        if (this.returnToAccountManagement && !state.ready && ['phone', 'code', 'registration', 'password', 'email', 'emailCode'].includes(state.phase)) {
          this.page = 'account'; this.returnToAccountManagement = false;
        }
        if (state.error.length > 0) { this.returnToAccountManagement = false; }
        this.refresh();
      });
      telegramService.resume(context).catch(() => this.localError = '恢复登录状态失败，请重新连接');
    });
  }

  aboutToDisappear(): void {
    WindowAppearance.setMediaOverlay(false).catch(() => {});
    this.chatSearchNeedsFocus = false;
    this.persistDraft();
    if (this.isTelegram && this.page === 'chat') { telegramService.leaveChat(); }
    telegramService.unsubscribe();
  }

  onPageHide(): void {
    this.persistDraft();
  }

  onBackPress(): boolean {
    if (this.page === 'storage' && this.storageRoute !== 'storage') { this.storageRoute = 'storage'; return true; }
    if (this.photoViewerVisible) { this.photoViewerVisible = false; return true; }
    if (this.forwardSheetVisible) { this.forwardSheetVisible = false; return true; }
    if (this.countryPickerVisible) { this.countryPickerVisible = false; return true; }
    if (this.page !== 'home') {
      this.goBack();
      return true;
    }
    if (this.currentTab === 0 && this.chatSearchVisible) {
      this.closeChatSearch();
      return true;
    }
    if (this.currentTab !== 0) {
      this.currentTab = 0;
      return true;
    }
    return false;
  }

  private fingerprint(value: string): string {
    let hash = 2166136261;
    for (let index = 0; index < value.length; index++) { hash = Math.imul(hash ^ value.charCodeAt(index), 16777619); }
    return `${value.length}-${(hash >>> 0).toString(36)}`;
  }

  private chatRenderKey(chat: ChatSummary): string {
    return `${chat.id}:${this.fingerprint(`${chat.title}|${chat.subtitle}|${chat.avatarPath || ''}|${chat.avatar}|${chat.color}|${chat.time}|${chat.unread}|${chat.pinned}|${chat.muted}|${chat.online}|${chat.kind}`)}`;
  }

  private contactRenderKey(contact: Contact): string {
    return `${contact.id}:${this.fingerprint(`${contact.name}|${contact.subtitle}|${contact.avatarPath || ''}|${contact.avatar}|${contact.color}|${contact.online}`)}`;
  }

  private messageRenderKey(message: ChatMessage): string {
    return `${message.chatId}:${message.id}:${message.status}:${this.fingerprint(`${message.richTruncated}|${message.richLoading}|${message.richError || ''}|${JSON.stringify(message.richBlocks || [])}|${JSON.stringify(message.entities || [])}|${message.stickerPath || ''}|${message.largeEmoji}|${message.forwardName || ''}|${message.senderAvatarPath || ''}|${message.read}|${message.service}|${JSON.stringify(message.linkPreview || null)}|${message.mediaAlbumId || ''}|${message.mediaProgress || 0}|${message.mediaDownloading}|${message.thumbnailPath || ''}|${message.mediaError || ''}|${message.mediaPath || ''}|${message.mediaFileId || 0}|${message.mediaKind || ''}|${message.text}|${message.time}|${message.outgoing}|${message.date || 0}|${message.senderName || ''}|${message.senderColor || ''}|${message.editDate || 0}|${message.replyThumbnailPath || ''}|${message.replyPreview || ''}|${message.replySenderName || ''}`)}`;
  }

  private messageDayKey(message: ChatMessage): string {
    if (!message.date || message.date <= 0) { return ''; }
    const date = new Date(message.date * 1000);
    return `${date.getFullYear()}-${date.getMonth()}-${date.getDate()}`;
  }

  private showsMessageDate(index: number): boolean {
    if (index < 0 || index >= this.messages.length) { return false; }
    const day = this.messageDayKey(this.messages[index]);
    return day.length > 0 && (index === 0 || day !== this.messageDayKey(this.messages[index - 1]));
  }

  private messageDateLabel(message: ChatMessage): string {
    const date = new Date((message.date || 0) * 1000);
    const today = new Date();
    if (date.toDateString() === today.toDateString()) { return '今天'; }
    const yesterday = new Date(today.getFullYear(), today.getMonth(), today.getDate() - 1);
    if (date.toDateString() === yesterday.toDateString()) { return '昨天'; }
    const label = `${date.getMonth() + 1}月${date.getDate()}日`;
    return date.getFullYear() === today.getFullYear() ? label : `${date.getFullYear()}年${label}`;
  }

  private isWide(): boolean { return this.viewportWidth >= 600; }
  private navigationWidth(): number { return this.viewportWidth >= 840 ? 320 : 280; }

  private updateViewport(width: number): void {
    if (!Number.isFinite(width) || width <= 0 || Math.abs(this.viewportWidth - width) < 1) { return; }
    this.viewportWidth = width;
    setTimeout((): void => { this.syncNavigation(); }, 0);
  }

  private syncNavigation(): void {
    if (this.page !== 'home' && this.page !== 'chat') { return; }
    if ((this.page === 'chat' || this.isWide()) && this.navigationStack.size() === 0) {
      this.navigationStack.pushPath({ name: 'conversation' }, false);
    } else if (this.page === 'home' && !this.isWide() && this.navigationStack.size() > 0) {
      this.navigationStack.clear(false);
    }
  }

  private surface(): string { return this.darkMode ? '#182430' : '#FFFFFF'; }
  private pageBackground(): string { return this.darkMode ? '#101A25' : '#F4F7FB'; }
  private ink(): string { return this.darkMode ? '#EEF4FC' : '#162B40'; }
  private mutedInk(): string { return this.darkMode ? '#94A6BA' : '#8493A5'; }
  private line(): string { return this.darkMode ? '#253443' : '#EEF2F6'; }
  private softBlue(): string { return this.darkMode ? '#203B55' : '#EAF4FF'; }
  private windowBackground(): string {
    if (this.photoViewerVisible) { return '#101418'; }
    return this.page === 'storage' || this.page === 'accounts' || this.page === 'account' || this.page === 'proxy' || (this.page === 'home' && this.currentTab === 2) ?
      this.pageBackground() : this.surface();
  }

  private mediaPresentationChanged(): void {
    WindowAppearance.setMediaOverlay(this.photoViewerVisible).catch(() => {});
    this.syncWindowBackground();
  }

  private syncWindowBackground(): void {
    WindowAppearance.setBackgroundColor(this.windowBackground()).catch(() => {});
  }

  private appearanceLabel(): string {
    return this.appearanceMode === 'system' ? '跟随系统' : this.appearanceMode === 'dark' ? '深色' : '浅色';
  }

  private chooseAppearance(): void {
    this.getUIContext().getPromptAction().showActionMenu({
      title: '外观',
      buttons: [
        { text: '跟随系统', color: this.appearanceMode === 'system' ? '#268BDE' : this.ink() },
        { text: '浅色', color: this.appearanceMode === 'light' ? '#268BDE' : this.ink() },
        { text: '深色', color: this.appearanceMode === 'dark' ? '#268BDE' : this.ink() }
      ]
    }).then((result) => {
      const modes: AppearanceMode[] = ['system', 'light', 'dark'];
      const mode = modes[result.index];
      if (mode) {
        WindowAppearance.setMode(mode).catch(() => this.toast('外观设置保存失败，请重试'));
      }
    }).catch(() => {});
  }
  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message, duration: 2200 });
  }

  private refresh(): void {
    this.chats = chatRepository.getChats();
    this.contacts = chatRepository.getContacts();
    this.currentUser = this.isTelegram ? telegramService.getCurrentUser() : undefined;
    if (this.isTelegram && this.selectedMessage &&
      (this.selectedMessage.status === 'received' || this.selectedMessage.status === 'sent')) {
      this.messagePermissions = telegramService.getMessagePermissions(this.selectedMessage.chatId, this.selectedMessage.id);
    }
    this.processMessageActions();
    if (this.activeChat.id.length > 0) {
      const chat = this.chats.find((item: ChatSummary) => item.id === this.activeChat.id);
      if (chat) {
        this.activeChat = chat;
        this.historyState = this.isTelegram ? telegramService.getHistoryState(chat.id) :
          { loading: false, hasMore: false, loaded: true, error: '' };
        const nextMessages = chatRepository.getMessages(chat.id);
        const lastId = this.messages.length > 0 ? this.messages[this.messages.length - 1].id : '';
        const nextLastId = nextMessages.length > 0 ? nextMessages[nextMessages.length - 1].id : '';
        if (this.olderAnchorChatId === chat.id && nextMessages.length > this.olderAnchorCount &&
          nextMessages[0].id !== this.olderAnchorFirstId) {
          this.olderMessagesArrived = true;
          this.pendingBottomChatId = '';
        } else if (this.page === 'chat' && this.wasAtBottom && lastId !== nextLastId) {
          this.pendingBottomChatId = chat.id;
        }
        if (this.olderAnchorChatId === chat.id && !this.historyState.loading &&
          nextMessages.length === this.olderAnchorCount) {
          this.olderAnchorChatId = '';
        }
        this.messages = nextMessages;
        if (this.isTelegram && this.draft.length === 0 && this.pendingDraftChatId !== chat.id) {
          this.draft = chatRepository.getDraft(chat.id);
        }
      }
    }
  }

  private loadOlderMessages(): void {
    const chatId = this.activeChat.id;
    if (!this.isTelegram || this.historyState.loading ||
      (!this.historyState.hasMore && this.historyState.error.length === 0)) { return; }
    if (this.messages.length === 0) {
      this.olderAnchorChatId = '';
      this.pendingBottomChatId = chatId;
      telegramService.loadOlderMessages(chatId);
      return;
    }
    this.olderAnchorChatId = chatId;
    this.olderAnchorFirstId = this.messages.length > 0 ? this.messages[0].id : '';
    this.olderAnchorCount = this.messages.length;
    this.olderAnchorOffset = this.messageScroller.currentOffset().yOffset;
    this.olderAnchorHeight = this.messageContentHeight;
    this.olderMessagesArrived = false;
    this.pendingBottomChatId = '';
    telegramService.loadOlderMessages(chatId);
  }

  private updateMessageViewport(height: number): void {
    if (!Number.isFinite(height) || height <= 0 || height === this.messageViewportHeight) { return; }
    this.messageViewportHeight = height;
    this.loadOneShortHistoryPage();
    if (this.page !== 'chat' || !this.wasAtBottom || this.olderAnchorChatId.length > 0) { return; }
    const chatId = this.activeChat.id;
    setTimeout((): void => {
      if (this.page === 'chat' && this.activeChat.id === chatId && this.wasAtBottom) {
        this.messageScroller.scrollEdge(Edge.Bottom);
      }
    }, 0);
  }

  private updateMessageContentHeight(height: number): void {
    if (!Number.isFinite(height) || height <= 0 || this.page !== 'chat') { return; }
    this.messageContentHeight = height;
    if (this.scrollToReplyTarget()) { return; }
    if (this.olderMessagesArrived && this.olderAnchorChatId === this.activeChat.id) {
      const offset = this.olderAnchorOffset + Math.max(0, height - this.olderAnchorHeight);
      this.olderMessagesArrived = false;
      this.olderAnchorChatId = '';
      this.messageScroller.scrollTo({ xOffset: 0, yOffset: offset, animation: false });
    } else if ((this.pendingBottomChatId === this.activeChat.id || this.wasAtBottom) && this.messages.length > 0) {
      this.pendingBottomChatId = '';
      this.wasAtBottom = true;
      const chatId = this.activeChat.id;
      const revision = ++this.bottomLayoutRevision;
      setTimeout(() => {
        if (this.page === 'chat' && this.activeChat.id === chatId && this.wasAtBottom &&
          !this.userMessageScrolling && this.olderAnchorChatId.length === 0 && revision === this.bottomLayoutRevision) {
          this.messageScroller.scrollEdge(Edge.Bottom);
        }
      }, 16);
    }
    this.loadOneShortHistoryPage();
  }

  private loadOneShortHistoryPage(): void {
    if (this.initialHistoryExtraLoaded || this.page !== 'chat' || !this.isTelegram ||
      this.messages.length === 0 || !this.historyState.loaded || this.historyState.loading ||
      !this.historyState.hasMore || this.historyState.error.length > 0 || this.messageViewportHeight <= 0 ||
      this.messageContentHeight <= 0 || this.messageContentHeight > this.messageViewportHeight) { return; }
    this.initialHistoryExtraLoaded = true;
    const chatId = this.activeChat.id;
    setTimeout((): void => {
      if (this.page === 'chat' && this.activeChat.id === chatId) { this.loadOlderMessages(); }
    }, 0);
  }

  private loadHistoryAtStart(): void {
    if (!this.historyScrollArmed || this.page !== 'chat' || !this.isTelegram ||
      !this.historyState.loaded || this.historyState.loading || !this.historyState.hasMore ||
      this.historyState.error.length > 0) { return; }
    this.historyScrollArmed = false;
    const chatId = this.activeChat.id;
    setTimeout((): void => {
      if (this.page === 'chat' && this.activeChat.id === chatId) { this.loadOlderMessages(); }
    }, 0);
  }

  private observeHistoryScroll(yOffset: number, source: ScrollSource): void {
    const fromUser = source === ScrollSource.DRAG || source === ScrollSource.FLING ||
      source === ScrollSource.OTHER_USER_INPUT || source === ScrollSource.SCROLL_BAR ||
      source === ScrollSource.SCROLL_BAR_FLING;
    if (fromUser) { this.userMessageScrolling = true; }
    if (!fromUser || yOffset >= 0) { return; }
    this.historyScrollArmed = true;
    if (this.messageScroller.currentOffset().yOffset <= 24) { this.loadHistoryAtStart(); }
  }

  private save(): void {
    LocalStore.save().catch(() => this.toast('保存失败，请检查设备存储空间'));
  }

  private cancelPendingDraft(): void {
    if (this.draftTimer >= 0) { clearTimeout(this.draftTimer); }
    this.draftTimer = -1;
    this.pendingDraftChatId = '';
    this.pendingDraftText = '';
  }

  private flushRemoteDraft(): void {
    const chatId = this.pendingDraftChatId;
    const text = this.pendingDraftText;
    this.cancelPendingDraft();
    if (this.isTelegram && chatId.length > 0) { telegramService.setDraft(chatId, text); }
  }

  private scheduleRemoteDraft(chatId: string, text: string): void {
    if (!this.isTelegram || chatId.length === 0) { return; }
    if (this.pendingDraftChatId.length > 0 && this.pendingDraftChatId !== chatId) { this.flushRemoteDraft(); }
    if (this.draftTimer >= 0) { clearTimeout(this.draftTimer); }
    this.pendingDraftChatId = chatId;
    this.pendingDraftText = text;
    this.draftTimer = setTimeout((): void => {
      // Use the queued chat ID, never the conversation that happens to be visible later.
      this.flushRemoteDraft();
    }, 750);
  }

  private updateDraft(text: string): void {
    const chatId = this.activeChat.id;
    if (chatId.length === 0 || this.page !== 'chat') { return; }
    this.draft = text;
    chatRepository.setDraft(chatId, text);
    this.save();
    this.scheduleRemoteDraft(chatId, text);
  }

  private persistDraft(): void {
    if (this.page === 'chat' && this.activeChat.id.length > 0) {
      const chatId = this.activeChat.id;
      chatRepository.setDraft(chatId, this.draft);
      this.save();
      this.scheduleRemoteDraft(chatId, this.draft);
    }
    this.flushRemoteDraft();
  }

  private mediaSource(path: string): string { return path.startsWith('/') ? `file://${path}` : path; }
  private messageMaxWidth(): number {
    const paneWidth = this.isWide() ? this.viewportWidth - this.navigationWidth() : this.viewportWidth;
    return Math.min(420, Math.max(120, paneWidth - (this.activeChat.kind === 'group' ? 64 : 32)));
  }
  private messageMediaWidth(): number { return Math.min(400, this.messageMaxWidth()); }
  private selectedPhotoPath(): string {
    return this.photoDrafts.find((item: PhotoDraft) => item.chatId === this.activeChat.id)?.path || '';
  }
  private selectedPhotoCaption(): string {
    return this.photoDrafts.find((item: PhotoDraft) => item.chatId === this.activeChat.id)?.caption || '';
  }
  private hasSelectedPhoto(): boolean { return this.selectedPhotoPath().length > 0; }
  private messageCaption(message: ChatMessage): string {
    return message.contentKind === 'photo' || !!message.mediaKind ?
      (message.caption !== undefined ? message.caption : message.text.replace(/^\[(图片|视频)\]\s?/, '')) : message.text;
  }

  private currentComposerAction(): ComposerAction | undefined {
    return this.composerActions.find((action: ComposerAction) => action.chatId === this.activeChat.id);
  }

  private cloneComposerAction(action: ComposerAction): ComposerAction {
    return { chatId: action.chatId, messageId: action.messageId, mode: action.mode, title: action.title,
      preview: action.preview, text: action.text, caption: action.caption, token: action.token,
      submittedText: action.submittedText, error: action.error };
  }

  private setComposerAction(action: ComposerAction): void {
    this.composerActions = this.composerActions.filter((item: ComposerAction) => item.chatId !== action.chatId).concat([action]);
  }

  private composerBusy(): boolean { return (this.currentComposerAction()?.token || '').length > 0; }
  private composerText(): string {
    const action = this.currentComposerAction();
    if (action?.mode === 'edit') { return action.text; }
    return !action && this.hasSelectedPhoto() ? this.selectedPhotoCaption() : this.draft;
  }
  private composerLimit(): number {
    const action = this.currentComposerAction();
    return (action?.mode === 'edit' && action.caption) || (!action && this.hasSelectedPhoto()) ? 1024 : 4096;
  }
  private composerCanSend(): boolean {
    if (this.composerBusy()) { return false; }
    const action = this.currentComposerAction();
    if (action?.mode === 'edit') { return action.caption || action.text.trim().length > 0; }
    return (!action && this.hasSelectedPhoto()) || this.draft.trim().length > 0;
  }
  private updateComposerText(value: string): void {
    const current = this.currentComposerAction();
    if (current?.mode === 'edit') {
      const action = this.cloneComposerAction(current);
      action.text = value;
      action.error = '';
      this.setComposerAction(action);
    } else if (!current && this.hasSelectedPhoto()) {
      this.updatePhotoCaption(value);
    } else {
      this.updateDraft(value);
    }
  }

  private cancelComposerAction(): void {
    if (this.composerBusy()) { return; }
    const chatId = this.activeChat.id;
    this.composerActions = this.composerActions.filter((action: ComposerAction) => action.chatId !== chatId);
  }

  private focusComposer(chatId: string): void {
    this.pendingComposerFocusChatId = chatId;
    if (!this.messageMenuOpen) { this.focusAfterMessageMenu(); }
  }

  private focusAfterMessageMenu(): void {
    const chatId = this.pendingComposerFocusChatId;
    this.pendingComposerFocusChatId = '';
    if (!chatId) { return; }
    setTimeout((): void => {
      if (this.page === 'chat' && this.activeChat.id === chatId) {
        this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE);
        this.getUIContext().getFocusController().requestFocus('message-input');
      }
    }, 0);
  }

  private prepareMessageMenu(message: ChatMessage): void {
    this.messageMenuOpen = true;
    this.selectedMessage = message;
    if (!this.isTelegram || message.status === 'local' || message.status === 'failed' || message.status === 'pending') {
      this.messagePermissions = { loading: false, loaded: true, error: '', canReply: false, canEdit: false,
        canDeleteForSelf: false, canDeleteForAll: false, canForward: false, canCopy: true };
      return;
    }
    this.messagePermissions = telegramService.getMessagePermissions(message.chatId, message.id);
    telegramService.loadMessageProperties(message.chatId, message.id);
  }

  private menuMatches(message: ChatMessage): boolean {
    return this.selectedMessage?.chatId === message.chatId && this.selectedMessage?.id === message.id;
  }

  private closeMessageMenu(): void { this.getUIContext().getContextMenuController().close(); }

  private copyMessage(message: ChatMessage): void {
    if (!this.menuMatches(message) || !this.messagePermissions.canCopy) { return; }
    const text = this.messageCaption(message);
    if (text.length === 0) { return; }
    this.closeMessageMenu();
    telegramService.copyText(text).then(() => this.toast('已复制')).catch(() => this.toast('复制失败，请重试'));
  }

  private beginComposerAction(message: ChatMessage, mode: string): void {
    const permissions = telegramService.getMessagePermissions(message.chatId, message.id);
    if (!permissions.loaded || (mode === 'edit' ? !permissions.canEdit : !permissions.canReply) ||
      this.activeChat.id !== message.chatId || this.page !== 'chat') { return; }
    this.closeMessageMenu();
    const current = this.currentComposerAction();
    if (current?.token) { this.toast('正在处理当前消息，请稍候'); return; }
    if (current && current.mode === mode && current.messageId === message.id) { this.focusComposer(message.chatId); return; }
    if (current?.mode === 'edit') {
      const chatId = message.chatId;
      const epoch = this.attachmentEpoch;
      this.getUIContext().getPromptAction().showDialog({
        title: '放弃当前编辑？', message: '正在编辑的文字尚未保存，原来的普通草稿会保留。',
        buttons: [{ text: '继续编辑', color: '#718398' }, { text: '放弃编辑', color: '#268BDE' }]
      }).then((result) => {
        if (result.index === 1 && this.page === 'chat' && this.activeChat.id === chatId && epoch === this.attachmentEpoch) {
          this.activateComposerAction(message, mode);
        }
      }).catch(() => {});
      return;
    }
    this.activateComposerAction(message, mode);
  }

  private activateComposerAction(message: ChatMessage, mode: string): void {
    // Editing has its own buffer; ordinary text and any selected photo stay untouched.
    this.persistDraft();
    this.setComposerAction({ chatId: message.chatId, messageId: message.id, mode: mode,
      title: mode === 'edit' ? '编辑消息' : (message.senderName ? `回复 ${message.senderName}` : '回复消息'),
      preview: this.messageCaption(message) || '图片', text: this.messageCaption(message),
      caption: message.contentKind === 'photo' || message.contentKind === 'video' || !!message.mediaKind,
      token: '', submittedText: '', error: '' });
    this.focusComposer(message.chatId);
  }

  private sendComposerAction(): void {
    const current = this.currentComposerAction();
    if (!current || current.token.length > 0 || !this.composerCanSend()) { return; }
    const action = this.cloneComposerAction(current);
    const text = action.mode === 'edit' ? action.text : this.draft;
    if (action.mode === 'reply') { this.flushRemoteDraft(); }
    const token = action.mode === 'edit' ? telegramService.editMessage(action.chatId, action.messageId, text) :
      telegramService.sendReply(action.chatId, text, action.messageId);
    action.token = token;
    action.submittedText = text;
    action.error = token.length > 0 ? '' : (this.telegram.error || '未能提交，请重试');
    this.setComposerAction(action);
    if (token.length > 0) { this.processMessageActions(); }
  }

  private confirmDeleteMessage(message: ChatMessage): void {
    const permissions = telegramService.getMessagePermissions(message.chatId, message.id);
    if (!permissions.loaded || (!permissions.canDeleteForSelf && !permissions.canDeleteForAll)) { return; }
    this.closeMessageMenu();
    const buttons: MessageDialogButton[] = [{ text: '取消', color: '#718398' }];
    const scopes: boolean[] = [false];
    if (permissions.canDeleteForSelf) { buttons.push({ text: '仅为我删除', color: '#D56464' }); scopes.push(false); }
    if (permissions.canDeleteForAll) { buttons.push({ text: '为所有人删除', color: '#D56464' }); scopes.push(true); }
    const chatId = message.chatId;
    const messageId = message.id;
    const epoch = this.attachmentEpoch;
    this.getUIContext().getPromptAction().showDialog({
      title: '删除这条消息？', message: '删除后无法撤销。', buttons: buttons
    }).then((result) => {
      if (result.index <= 0 || result.index >= scopes.length || epoch !== this.attachmentEpoch ||
        this.page !== 'chat' || this.activeChat.id !== chatId) { return; }
      if (this.pendingMessageActions.some((item: PendingMessageAction) => item.kind === 'delete' &&
        item.chatId === chatId && item.messageId === messageId)) { return; }
      const token = telegramService.deleteMessage(chatId, messageId, scopes[result.index]);
      if (token.length === 0) { this.toast(this.telegram.error || '未能删除，请重试'); return; }
      this.pendingMessageActions.push({ token: token, kind: 'delete', chatId: chatId, messageId: messageId });
      this.processMessageActions();
    }).catch(() => {});
  }

  private beginForwardMessage(message: ChatMessage): void {
    if (!telegramService.getMessagePermissions(message.chatId, message.id).canForward) { return; }
    this.closeMessageMenu();
    if (this.forwardBusy) { this.toast('正在转发，请稍候'); return; }
    this.forwardMessageSource = message;
    this.forwardError = '';
    this.forwardSheetVisible = true;
  }

  private submitForwardMessage(targetChatId: string): void {
    const source = this.forwardMessageSource;
    if (!source || this.forwardBusy || !this.chats.some((chat: ChatSummary) => chat.id === targetChatId)) { return; }
    const token = telegramService.forwardMessage(source.chatId, source.id, targetChatId);
    if (token.length === 0) { this.forwardError = this.telegram.error || '未能转发，请重试'; return; }
    this.forwardBusy = true;
    this.forwardError = '';
    this.pendingMessageActions.push({ token: token, kind: 'forward', chatId: source.chatId, messageId: source.id });
    this.processMessageActions();
  }

  private messageNodeId(chatId: string, messageId: string): string {
    return `message-${this.fingerprint(`${chatId}:${messageId}`)}`;
  }

  private locateReply(message: ChatMessage): void {
    if (!this.isTelegram || this.pendingMessageActions.some((item: PendingMessageAction) => item.kind === 'locate' &&
      item.chatId === message.chatId && item.messageId === message.id)) { return; }
    const token = telegramService.loadReplyTarget(message.chatId, message.id);
    if (!token) { this.toast(this.telegram.error || '无法加载原消息'); return; }
    this.replyLocateGeneration++;
    this.pendingMessageActions.push({ token: token, kind: 'locate', chatId: message.chatId,
      messageId: message.id, navigationIntent: this.replyLocateGeneration });
    this.processMessageActions();
  }

  private scrollToReplyTarget(): boolean {
    if (this.page !== 'chat' || this.pendingLocateChatId !== this.activeChat.id || !this.pendingLocateMessageId) { return false; }
    try {
      const utils = this.getUIContext().getComponentUtils();
      const target = utils.getRectangleById(this.messageNodeId(this.pendingLocateChatId, this.pendingLocateMessageId));
      const scroll = utils.getRectangleById('message-scroll');
      if (target.size.height <= 0 || scroll.size.height <= 0) { return false; }
      const offset = this.messageScroller.currentOffset().yOffset +
        this.getUIContext().px2vp(target.windowOffset.y - scroll.windowOffset.y) - 12;
      this.pendingLocateChatId = '';
      this.pendingLocateMessageId = '';
      this.pendingBottomChatId = '';
      this.wasAtBottom = false;
      this.messageScroller.scrollTo({ xOffset: 0, yOffset: Math.max(0, offset), animation: false });
      return true;
    } catch { return false; }
  }

  private processMessageActions(): void {
    if (!this.isTelegram) { return; }
    const composers: ComposerAction[] = [];
    let changed = false;
    this.composerActions.forEach((current: ComposerAction) => {
      const result = current.token ? telegramService.getMessageAction(current.token) : undefined;
      if (!result || result.status === 'pending') { composers.push(current); return; }
      changed = true;
      if (result.status === 'failed') {
        const action = this.cloneComposerAction(current);
        action.token = '';
        action.error = result.error || '操作失败，请重试';
        composers.push(action);
      } else if (current.mode === 'reply' && this.activeChat.id === current.chatId && this.draft === current.submittedText) {
        if (this.pendingDraftChatId === current.chatId) { this.cancelPendingDraft(); }
        this.draft = chatRepository.getDraft(current.chatId);
        this.pendingBottomChatId = current.chatId;
      }
    });
    if (changed) { this.composerActions = composers; }
    const pending: PendingMessageAction[] = [];
    this.pendingMessageActions.forEach((item: PendingMessageAction) => {
      const result = telegramService.getMessageAction(item.token);
      if (!result || result.status === 'pending') { pending.push(item); return; }
      if (item.kind === 'forward') {
        this.forwardBusy = false;
        if (result.status === 'succeeded') { this.forwardSheetVisible = false; this.toast('已转发'); }
        else { this.forwardError = result.error || '转发失败，请重试'; }
      } else if (item.kind === 'locate' && result.status === 'succeeded') {
        if (item.navigationIntent !== this.replyLocateGeneration) { return; }
        const targetChatId = result.targetChatId || item.chatId;
        const targetMessageId = result.targetMessageId || '';
        const epoch = this.attachmentEpoch;
        setTimeout((): void => {
          if (item.navigationIntent !== this.replyLocateGeneration || this.page !== 'chat' ||
            this.activeChat.id !== item.chatId || this.attachmentEpoch !== epoch || !targetMessageId) { return; }
          if (targetChatId !== this.activeChat.id) {
            const chat = this.chats.find((entry: ChatSummary) => entry.id === targetChatId);
            if (!chat) { this.toast('原消息所在聊天不可用'); return; }
            this.openChat(chat);
          }
          this.pendingLocateChatId = targetChatId;
          this.pendingLocateMessageId = targetMessageId;
          this.pendingBottomChatId = '';
          this.scrollToReplyTarget();
        }, 0);
      } else if (result.status === 'failed') {
        this.toast(result.error || (item.kind === 'locate' ? '无法加载原消息' : '删除失败，请重试'));
      }
    });
    this.pendingMessageActions = pending;
  }
  private setPhotoDraft(chatId: string, path: string, caption: string, attachments: MediaAttachment[]): void {
    this.photoDrafts = this.photoDrafts.filter((item: PhotoDraft) => item.chatId !== chatId);
    if (path.length > 0) { this.photoDrafts = this.photoDrafts.concat([{ chatId: chatId, path: path, caption: caption.slice(0, 1024), attachments: attachments }]); }
  }
  private updatePhotoCaption(caption: string): void {
    const chatId = this.activeChat.id;
    const path = this.selectedPhotoPath();
    if (path.length > 0) { this.setPhotoDraft(chatId, path, caption, this.selectedAttachments()); }
  }
  private chooseImage(): void {
    if (!this.isTelegram) { this.toast('请登录 Telegram 后发送图片'); return; }
    if (this.choosingImage || this.activeChat.id.length === 0) { return; }
    const chatId = this.activeChat.id;
    const epoch = this.attachmentEpoch;
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.choosingImage = true;
    telegramService.pickMedia(context).then((items: MediaAttachment[]) => {
      if (items.length === 0 || epoch !== this.attachmentEpoch || !this.isTelegram) { return; }
      const prior = this.photoDrafts.find((item: PhotoDraft) => item.chatId === chatId);
      this.setPhotoDraft(chatId, items[0].path, prior ? prior.caption : '', items);
    }).catch((error: Error) => this.toast(error.message || '未能选择图片或视频')).finally(() => { this.choosingImage = false; });
  }
  private sendSelectedPhoto(): void {
    const chatId = this.activeChat.id;
    const selected = this.photoDrafts.find((item: PhotoDraft) => item.chatId === chatId);
    if (!this.isTelegram || !selected) { return; }
    if (telegramService.sendMedia(chatId, selected.attachments, selected.caption)) {
      this.photoDrafts = this.photoDrafts.filter((item: PhotoDraft) => item.chatId !== chatId);
      this.refresh();
      this.pendingBottomChatId = chatId;
    }
  }

  private restoreFailedMessage(message: ChatMessage): void {
    if (message.status !== 'failed' || message.chatId !== this.activeChat.id || this.page !== 'chat') { return; }
    const chatId = message.chatId;
    const text = this.messageCaption(message);
    if (message.mediaKind && message.mediaPath) {
      if (this.hasSelectedPhoto()) { this.toast('请先发送或取消当前附件'); return; }
      const group = this.messages.filter((item: ChatMessage) => item.status === 'failed' &&
        (message.mediaAlbumId ? item.mediaAlbumId === message.mediaAlbumId : item.id === message.id));
      const attachments: MediaAttachment[] = group.map((item: ChatMessage): MediaAttachment => ({
        path: item.mediaPath || '', kind: item.mediaKind === 'video' ? 'video' : 'photo',
        width: item.mediaWidth || 0, height: item.mediaHeight || 0, duration: item.mediaDuration || 0, size: item.mediaSize || 1
      }));
      this.setPhotoDraft(chatId, attachments[0].path, this.messageCaption(group[0]), attachments);
      return;
    }
    if (this.draft.length === 0 || this.draft === text) {
      this.updateDraft(text);
      this.getUIContext().getFocusController().requestFocus('message-input');
      return;
    }
    this.getUIContext().getPromptAction().showDialog({
      title: '替换当前草稿？',
      message: '输入框中已有未发送的内容。使用这条失败消息替换后，你可以编辑并重新发送。',
      buttons: [{ text: '取消', color: '#718398' }, { text: '使用此消息', color: '#268BDE' }]
    }).then((result) => {
      if (result.index === 1 && this.page === 'chat' && this.activeChat.id === chatId) {
        this.updateDraft(text);
        this.getUIContext().getFocusController().requestFocus('message-input');
      }
    }).catch(() => {});
  }

  private goBack(): void {
    if (this.page === 'proxy') {
      this.closeProxy();
      return;
    }
    this.replyLocateGeneration++;
    this.pendingComposerFocusChatId = '';
    this.pendingLocateChatId = '';
    this.pendingLocateMessageId = '';
    this.forwardSheetVisible = false;
    this.photoViewerVisible = false;
    this.closeMessageMenu();
    this.countryPickerVisible = false;
    this.persistDraft();
    if (this.isTelegram && this.page === 'chat') { telegramService.leaveChat(); }
    // 返回设置页时，未完成的登录不能继续显示为已登录账号。
    if (!this.telegram.ready) { this.isTelegram = false; }
    this.page = 'home';
    this.navigationStack.clear(false);
    this.menuVisible = false;
    this.syncNavigation();
    this.refresh();
  }

  private openChat(chat: ChatSummary): void {
    this.chatSearchNeedsFocus = false;
    if (this.chatSearchVisible) { this.chatSearchController.stopEditing(); }
    this.replyLocateGeneration++;
    this.pendingComposerFocusChatId = '';
    this.pendingLocateChatId = '';
    this.pendingLocateMessageId = '';
    this.closeMessageMenu();
    this.persistDraft();
    this.activeChat = chat;
    this.pendingBottomChatId = chat.id;
    this.wasAtBottom = true;
    this.userMessageScrolling = false;
    this.bottomLayoutRevision++;
    this.messageContentHeight = 0;
    this.messageViewportHeight = 0;
    this.olderAnchorChatId = '';
    this.olderMessagesArrived = false;
    this.historyScrollArmed = false;
    this.initialHistoryExtraLoaded = false;
    if (this.isTelegram) { telegramService.openChat(chat.id); } else { chatRepository.markRead(chat.id); }
    this.messages = chatRepository.getMessages(chat.id);
    this.draft = chatRepository.getDraft(chat.id);
    this.page = 'chat';
    this.menuVisible = false;
    this.syncNavigation();
    this.refresh();
    this.save();

  }

  private openSavedMessages(): void {
    const chatId = this.isTelegram ? telegramService.openSavedMessages() : 'saved';
    if (chatId.length === 0) { this.toast('收藏夹正在准备，请稍后重试'); return; }
    this.refresh();
    const chat = this.chats.find((item: ChatSummary) => item.id === chatId);
    if (chat) { this.openChat(chat); }
  }

  private openContact(contact: Contact): void {
    const chatId = this.isTelegram ? telegramService.openContact(contact.id) : chatRepository.openContact(contact.id);
    this.refresh();
    const chat = this.chats.find((item: ChatSummary) => item.id === chatId);
    if (chat) {
      this.openChat(chat);
    }
  }

  private send(): void {
    if (this.currentComposerAction()) { this.sendComposerAction(); return; }
    if (this.hasSelectedPhoto()) { this.sendSelectedPhoto(); return; }
    const chatId = this.activeChat.id;
    const text = this.draft;
    const sent = this.isTelegram ? telegramService.sendMessage(chatId, text) : chatRepository.sendMessage(chatId, text);
    if (sent) {
      // The TDLib send request clears the server draft; an older timer must not restore it afterwards.
      if (this.pendingDraftChatId === chatId) { this.cancelPendingDraft(); }
      this.draft = '';
      chatRepository.setDraft(chatId, '');
      this.refresh();
      this.save();
      this.pendingBottomChatId = chatId;
    }
  }

  private filteredChats(): ChatSummary[] {
    return this.chats.filter((chat: ChatSummary) => {
      return this.selectedFilter === 0 ||
        (this.selectedFilter === 1 && chat.unread > 0) ||
        (this.selectedFilter === 2 && chat.kind === 'group') ||
        (this.selectedFilter === 3 && chat.kind === 'channel');
    });
  }

  private searchedChats(): ChatSummary[] {
    const query = this.searchText.trim().toLowerCase();
    return this.chats.filter((chat: ChatSummary) => query.length === 0 ||
      chat.title.toLowerCase().includes(query) || chat.subtitle.toLowerCase().includes(query));
  }

  private openChatSearch(): void {
    this.searchBackgroundHeight = this.chatPaneHeight;
    this.searchText = '';
    this.chatSearchNeedsFocus = true;
    this.chatSearchVisible = true;
  }

  private closeChatSearch(): void {
    this.chatSearchNeedsFocus = false;
    if (this.chatSearchVisible) { this.chatSearchController.stopEditing(); }
    this.chatSearchVisible = false;
    this.searchText = '';
  }

  private focusChatSearch(): void {
    setTimeout((): void => {
      if (!this.chatSearchNeedsFocus || !this.chatSearchVisible || this.currentTab !== 0 ||
        (this.page !== 'home' && !(this.page === 'chat' && this.isWide()))) { return; }
      this.chatSearchNeedsFocus = false;
      try {
        this.getUIContext().getFocusController().requestFocus('chat-list-search');
      } catch (_) {
        // The destination may have disappeared between scheduling and focus delivery.
      }
    }, 0);
  }

  private tabBarVisibility(): CommonModifier {
    // Change visibility only; floating geometry and material remain platform-owned.
    return new CommonModifier().visibility(this.chatSearchVisible ? Visibility.Hidden : Visibility.Visible);
  }

  private filteredContacts(): Contact[] {
    const query = this.contactSearch.trim().toLowerCase();
    return this.contacts.filter((contact: Contact) => query.length === 0 ||
      contact.name.toLowerCase().includes(query) || contact.subtitle.toLowerCase().includes(query));
  }

  private unreadCount(): number {
    return this.chats.filter((chat: ChatSummary) => chat.unread > 0).length;
  }

  private chatDescription(): string {
    if (this.activeChat.kind === 'saved') { return '收藏夹'; }
    if (this.isTelegram) {
      if (this.activeChat.kind === 'channel') { return '频道'; }
      if (this.activeChat.kind === 'group') { return '群组'; }
      return this.activeChat.online ? '在线' : '最近上线';
    }
    if (this.activeChat.kind === 'channel') { return '演示频道 · 只读'; }
    if (this.activeChat.kind === 'group') { return '演示群组 · 本地消息'; }
    return '离线预览';
  }

  private changeAccount(accountId: string = ''): void {
    if (this.accountSwitching) { return; }
    if (this.photoDrafts.length > 0 || this.composerActions.length > 0) {
      this.toast('请先完成或取消待发送图片、回复和编辑'); return;
    }
    this.persistDraft();
    this.returnToAccountManagement = this.page === 'accounts' && accountId.length > 0;
    this.accountSwitching = true;
    this.localError = '';
    this.searchText = '';
    this.contactSearch = '';
    this.selectedFilter = 0;
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const operation = accountId.length > 0 ? telegramService.switchAccount(context, accountId) : telegramService.addAccount(context);
    operation.catch(() => this.toast('账户切换失败，请重试')).finally(() => {
      this.accountSwitching = false;
      this.accountProfiles = telegramService.accounts();
      this.activeAccountId = telegramService.activeAccount();
      if (!this.telegram.ready && !this.returnToAccountManagement) { this.page = 'account'; }
    });
  }

  private confirmLogOut(): void {
    this.getUIContext().getPromptAction().showDialog({
      title: '退出 Telegram 账号',
      message: '退出后需要重新验证手机号才能访问会话。云端消息仍保留在 Telegram。',
      buttons: [{ text: '取消', color: '#718398' }, { text: '退出登录', color: '#D56464' }]
    }).then((result) => {
      if (result.index === 1) { this.persistDraft(); telegramService.logOut(); }
    }).catch(() => {});
  }

  private openAbout(): void {
    this.persistDraft();
    if (this.isTelegram && this.page === 'chat') { telegramService.leaveChat(); }
    this.page = 'about';
  }

  private openProxy(): void {
    this.persistDraft();
    if (this.isTelegram && this.page === 'chat') { telegramService.leaveChat(); }
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    clashService.init(context).catch(() => {});
    this.page = 'proxy';
  }

  private closeProxy(): void {
    this.page = 'home';
    this.currentTab = 2;
    this.menuVisible = false;
    this.syncNavigation();
    this.refresh();
  }

  private proxySummary(): string {
    const state: string = clashService.snapshot().state;
    if (state === 'connected') { return '已连接'; }
    if (state === 'preparing') { return '正在启动'; }
    if (state === 'unauthorized') { return '未授权'; }
    if (state === 'failed') { return '启动失败'; }
    if (state === 'unconfigured') { return '未配置'; }
    return '已停止';
  }

  /** Masked tail only: full API id/hash must never reach the UI or logs. */
  private apiMaskTail(value: string): string {
    const text: string = value.trim();
    if (text.length === 0) { return ''; }
    if (text.length <= 4) { return '****'; }
    return `****${text.slice(text.length - 4)}`;
  }

  private apiPresetLabel(index: number): string {
    if (index < 0 || index >= TELEGRAM_API_PRESETS.length) { return '未配置'; }
    const preset: TelegramApiPreset = TELEGRAM_API_PRESETS[index];
    const idMask: string = this.apiMaskTail(String(preset.id));
    const hashMask: string = this.apiMaskTail(preset.hash);
    const parts: string[] = [];
    if (idMask.length > 0) { parts.push(`ID ${idMask}`); }
    if (hashMask.length > 0) { parts.push(`Hash ${hashMask}`); }
    if (parts.length === 0) { return '未配置'; }
    // A preset label must not repeat the full id or hash; drop unsafe labels instead.
    const rawLabel: string = (preset.label || '').trim();
    const idText: string = String(preset.id);
    const leaksId: boolean = idText.length >= 4 && rawLabel.includes(idText);
    const leaksHash: boolean = preset.hash.length >= 4 && rawLabel.includes(preset.hash);
    const label: string = leaksId || leaksHash ? '' : rawLabel;
    return label.length > 0 ? `${label} · ${parts.join(' · ')}` : parts.join(' · ');
  }

  private apiPresetOptions(): SelectOption[] {
    const options: SelectOption[] = [];
    for (let index: number = 0; index < TELEGRAM_API_PRESETS.length; index++) {
      const option: SelectOption = { value: this.apiPresetLabel(index) };
      options.push(option);
    }
    return options;
  }

  private selectLoginApi(index: number): void {
    const max: number = TELEGRAM_API_PRESETS.length;
    if (max <= 0) { return; }
    const next: number = Math.min(Math.max(index, 0), max - 1);
    this.loginApiIndex = next;
    LoginApiPreferences.save(next, max).catch(() => this.toast('API 凭据选择保存失败，请重试'));
  }

  private enterAccount(): void {
    this.persistDraft();
    if (this.isTelegram && this.page === 'chat') { telegramService.leaveChat(); }
    this.page = 'account';
    this.showDeveloperConfig = false;
    if (this.telegram.phase === 'idle' || this.telegram.phase === 'closed') {
      this.beginDefaultLogin();
    }
  }

  private beginDefaultLogin(): void {
    this.localError = '';
    this.isTelegram = true;
    this.authSubmitting = true;
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    telegramService.startDefault(context, this.loginApiIndex).then(() => {
      this.authSubmitting = false;
    }).catch(() => {
      this.authSubmitting = false;
      this.localError = '连接初始化失败，请稍后重试';
    });
  }

  private startLogin(): void {
    if (this.authSubmitting || this.telegram.submitting === true) { return; }
    this.localError = '';
    const phase = this.telegram.phase;
    if (phase === 'phone') {
      const normalizedPhone = normalizePhoneNumber(this.callingCode, this.phone);
      if (normalizedPhone.error.length > 0) { this.localError = normalizedPhone.error; return; }
      this.authSubmitting = true;
      telegramService.setPhone(normalizedPhone.value);
    } else if (phase === 'code') {
      if (this.authCode.trim().length === 0) { this.localError = '请输入 Telegram 验证码'; return; }
      this.authSubmitting = true;
      telegramService.setCode(this.authCode.trim());
    } else if (phase === 'registration') {
      telegramService.register(this.registrationFirst, this.registrationLast, this.registrationAccepted);
    } else if (phase === 'password') {
      if (this.password.length === 0) { this.localError = '请输入两步验证密码'; return; }
      this.authSubmitting = true;
      telegramService.setPassword(this.password);
    } else if (phase === 'email') {
      if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(this.email.trim())) {
        this.localError = '请输入有效的邮箱地址'; return;
      }
      this.authSubmitting = true;
      telegramService.setEmail(this.email.trim());
    } else if (phase === 'emailCode') {
      if (this.emailCode.trim().length === 0) { this.localError = '请输入邮箱验证码'; return; }
      this.authSubmitting = true;
      telegramService.setEmailCode(this.emailCode.trim());
    } else {
      if (!this.showDeveloperConfig) { this.beginDefaultLogin(); return; }
      if (!/^[1-9][0-9]*$/.test(this.apiId.trim()) || !/^[a-fA-F0-9]{32}$/.test(this.apiHash.trim())) {
        this.localError = '请填写有效的 API ID 和 32 位 API Hash'; return;
      }
      this.isTelegram = true;
      this.authSubmitting = true;
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      telegramService.start(context, this.apiId.trim(), this.apiHash.trim()).then(() => {
        this.authSubmitting = false;
      }).catch(() => {
        this.authSubmitting = false;
        this.localError = '连接初始化失败，请检查配置后重试';
      });
    }
  }

  private countryName(): string {
    const country = findPhoneCountry(this.selectedCountryIso);
    return country ? country.name : '选择国家或地区';
  }

  private choosePhoneCountry(country: PhoneCountry): void {
    this.selectedCountryIso = country.iso;
    this.callingCode = country.dialCode;
    this.localError = '';
    this.focusPhoneAfterPicker = true;
    this.countryPickerVisible = false;
  }

  private updateCallingCode(value: string): void {
    this.callingCode = value;
    this.localError = '';
    // Keep the editable code as typed; only derive the region from a valid dial code.
    // Unmatched input clears the selection, matching the previous behaviour.
    const matched = matchPhoneCountryByDialCode(value, this.selectedCountryIso);
    this.selectedCountryIso = matched ? matched.iso : '';
  }

  private updatePhone(value: string): void {
    this.localError = '';
    const international = splitInternationalPhone(value, this.selectedCountryIso);
    if (international) {
      this.callingCode = international.dialCode;
      this.phone = international.number;
      this.selectedCountryIso = international.countryIso;
    } else {
      this.phone = value;
    }
  }

  private authTitle(): string {
    const phase = this.telegram.phase;
    if (phase === 'registration') { return '创建你的账号'; }
    if (phase === 'phone') { return '你的手机号码'; }
    if (phase === 'code') { return '输入验证码'; }
    if (phase === 'password') { return '两步验证'; }
    if (phase === 'email') { return '验证电子邮箱'; }
    if (phase === 'emailCode') { return '查看你的邮箱'; }
    if (phase === 'starting') { return '正在连接 Telegram'; }
    if (phase === 'storageRecovery') { return '重新登录'; }
    if (phase === 'error') { return '暂时无法连接'; }
    if (phase === 'unsupported') { return '需要进一步验证'; }
    if (this.telegram.ready) { return 'Telegram 已连接'; }
    return this.showDeveloperConfig ? '开发者配置' : '连接你的 Telegram';
  }

  private authHint(): string {
    const phase = this.telegram.phase;
    if (phase === 'registration') { return '手机号已验证，请填写姓名并阅读服务条款。'; }
    if (phase === 'phone') { return '请选择国家或地区，输入你的手机号码。'; }
    if (phase === 'code') {
      const method = this.telegram.codeDelivery || '';
      if (method === 'authenticationCodeTypeTelegramMessage') { return '请在其他已登录的 Telegram 设备中查看验证码。'; }
      if (method.includes('Sms')) { return '请查看手机收到的短信验证码。'; }
      if (method === 'authenticationCodeTypeCall') { return '请接听 Telegram 来电获取验证码。'; }
      if (method.includes('FlashCall') || method.includes('MissedCall')) { return '请按 Telegram 来电验证要求完成验证。'; }
      return '请按 Telegram 提供的方式获取验证码。';
    }
    if (phase === 'password') { return '你的账号启用了两步验证，请输入 Telegram 云密码。'; }
    if (phase === 'email') { return 'Telegram 需要验证你的邮箱，请输入可以接收验证码的邮箱地址。'; }
    if (phase === 'emailCode') { return '请输入 Telegram 发送到你的邮箱的验证码。'; }
    if (phase === 'starting') { return '正在准备安全连接，请稍候。'; }
    if (phase === 'storageRecovery') { return '使用新的本地存储连接账号，原有缓存将保留。'; }
    if (phase === 'unsupported') { return '请根据下方 Telegram 返回的信息完成操作。'; }
    if (this.telegram.ready) { return '会话和消息来自你的 Telegram 账号。发送的消息会送达真实联系人。'; }
    return this.showDeveloperConfig ? '可选：使用你自己的 Telegram 应用身份进行调试。' : '使用你的手机号码登录或创建 Telegram 账号。';
  }

  /** 未登录初始态：使用离线预览数据并停在设置 Tab，不触发 Telegram 登录。 */
  private useOfflineSettings(): void {
    if (chatRepository.isRemote()) { chatRepository.useDemoData(); }
    this.isTelegram = false;
    this.page = 'home';
    this.currentTab = 2;
    this.syncNavigation();
    this.refresh();
  }

  @Builder
  private icon(source: Resource, size: number = 22) {
    Image(source).width(size).height(size).objectFit(ImageFit.Contain)
  }

  @Builder
  private avatar(text: string, color: string, size: number = 52, online: boolean = false, imagePath: string = '') {
    UserAvatar({ text: text, color: color, avatarSize: size, online: online, imagePath: imagePath, avatarBorderColor: this.surface() })
  }

  @Builder
  private contactsSearchBox() {
    Search({ value: this.contactSearch, placeholder: '搜索联系人' }).height(44).width('100%')
      .textFont({ size: 16 }).cancelButton({ style: CancelButtonStyle.INPUT })
      .onChange((value: string) => { this.contactSearch = value; }).accessibilityText('搜索联系人')
      .margin({ bottom: 8 }).padding({ left: 16, right: 16 })
  }

  @Builder
  private filterTab(label: string, index: number) {
    // Custom fixed-width tab: Tabs divides the bar evenly, so the four labels
    // always keep full width on compact phones without SubTabBar side padding.
    Column({ space: 6 }) {
      Text(index === 1 && this.unreadCount() > 0 ? `${label} ${this.unreadCount()}` : label)
        .fontSize(14)
        .fontWeight(this.selectedFilter === index ? FontWeight.Medium : FontWeight.Regular)
        .fontColor(this.selectedFilter === index ? '#268BDE' : this.mutedInk())
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(TextAlign.Center).width('100%')
      Row().width(18).height(3).borderRadius(1.5)
        .backgroundColor(this.selectedFilter === index ? '#268BDE' : Color.Transparent)
    }
    .width('100%').height(48).padding({ left: 4, right: 4 })
    .justifyContent(FlexAlign.Center)
    .accessibilityText(`筛选：${label}${index === 1 && this.unreadCount() > 0 ? `，${this.unreadCount()} 个会话未读` : ''}`)
  }

  @Builder
  private filterBar() {
    Tabs({ index: $$this.selectedFilter }) {
      ForEach(this.filters, (label: string, index: number) => {
        TabContent() { Column() {}.height(0) }
          .tabBar(this.filterTab(label, index))
      }, (label: string) => label)
    }.width('100%').height(48).barWidth('100%').barHeight(48).barMode(BarMode.Fixed)
      .scrollable(false).animationDuration(0).divider(null).padding(0)
  }

  @Builder
  private chatRow(chat: ChatSummary) {
    Row({ space: 13 }) {
      if (chat.kind === 'saved') {
        Stack() { this.icon($r('app.media.hg_bookmark_white'), 25) }
          .width(53).height(53).backgroundColor('#5A9DE1').borderRadius(27)
      } else {
        this.avatar(chat.avatar, chat.color, 53, chat.online, chat.avatarPath || '')
      }
      Column({ space: 8 }) {
        Row({ space: 5 }) {
          if (chat.kind === 'group') { this.icon($r('app.media.hg_group'), 14) }
          if (chat.kind === 'channel') { this.icon($r('app.media.hg_channel'), 14) }
          Text(chat.title).fontSize(16).fontWeight(FontWeight.Medium).fontColor(this.ink())
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
          Text(chat.time).fontSize(11).fontColor(chat.unread > 0 ? '#268BDE' : this.mutedInk())
        }.width('100%')
        Row({ space: 8 }) {
          Text(chat.subtitle).fontSize(13).fontColor(this.mutedInk()).maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
          if (chat.unread > 0) {
            Text(chat.unread > 99 ? '99+' : chat.unread.toString()).fontSize(11).fontWeight(FontWeight.Medium).fontColor('#FFFFFF')
              .constraintSize({ minWidth: 20 }).height(20).textAlign(TextAlign.Center)
              .padding({ left: 5, right: 5 }).backgroundColor(chat.muted ? '#A4B4C7' : '#3296E4').borderRadius(10)
          } else if (chat.pinned) {
            this.icon($r('app.media.hg_pin'), 13)
          }
          if (chat.muted) {
            this.icon($r('app.media.hg_bell'), 12)
          }
        }.width('100%')
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
    }.width('100%').padding({ left: 16, right: 16, top: 13, bottom: 13 })
      .backgroundColor(this.isWide() && this.page === 'chat' && this.activeChat.id === chat.id ? this.softBlue() : this.surface()).onClick(() => this.openChat(chat))
      .accessibilityText(`${chat.title}，${chat.subtitle}，${chat.unread}条未读消息`)
  }

  @Builder
  private emptyState(title: string, detail: string) {
    Column({ space: 12 }) {
      Stack() { this.icon($r('app.media.hg_search_blue'), 32) }
        .width(76).height(76).backgroundColor(this.softBlue()).borderRadius(27)
      Text(title).fontSize(17).fontColor(this.ink()).fontWeight(FontWeight.Medium).margin({ top: 4 })
      Text(detail).fontSize(13).fontColor(this.mutedInk()).textAlign(TextAlign.Center).lineHeight(21)
    }.width('100%').padding({ left: 30, right: 30, top: 65, bottom: 40 })
  }

  @Builder
  private mainChatsList() {
    HdsPage({ title: 'HmChat', subtitle: this.isTelegram ? '' : '离线预览', showBack: false,
      surface: true, dark: this.darkMode, firstLabel: '新建会话', firstSymbol: $r('sys.symbol.square_and_pencil'),
      firstAction: () => { this.currentTab = 1; this.contactSearch = ''; },
      secondLabel: '搜索会话', secondSymbol: $r('sys.symbol.magnifyingglass'), secondAction: () => this.openChatSearch(), content: () => { this.chatsBody() } }).width('100%')
      .height(this.chatSearchVisible && this.searchBackgroundHeight > 0 ? this.searchBackgroundHeight : '100%')
      .backgroundColor(this.surface())
      .onAreaChange((_oldArea: Area, area: Area) => {
        if (!this.chatSearchVisible) { this.chatPaneHeight = Number(area.height); }
      })
      .visibility(this.chatSearchVisible ? Visibility.Hidden : Visibility.Visible)
  }

  @Builder
  private chatSearchPage() {
    Column() {
      Row({ space: 8 }) {
        Search({ value: this.searchText, placeholder: '搜索', controller: this.chatSearchController })
          .id('chat-list-search').height(44).layoutWeight(1)
          .textFont({ size: 16 }).fontColor(this.ink()).placeholderColor(this.mutedInk())
          .backgroundColor(this.pageBackground()).cancelButton({ style: CancelButtonStyle.INPUT })
          .onChange((value: string) => {
            this.searchText = value;
            this.chatSearchScroller.scrollTo({ xOffset: 0, yOffset: 0, animation: false });
          })
          .onSubmit(() => { this.chatSearchController.stopEditing(); })
          .onAppear(() => this.focusChatSearch()).accessibilityText('搜索会话')
        Button('取消', { type: ButtonType.Normal, buttonStyle: ButtonStyleMode.TEXTUAL }).height(44).width(52).fontSize(16)
          .padding(0).fontColor('#268BDE').backgroundColor(Color.Transparent)
          .onClick(() => this.closeChatSearch()).accessibilityText('取消搜索').id('cancel-chat-search')
      }.height(64).width('100%').padding({ left: 16, right: 8 })
      List({ scroller: this.chatSearchScroller }) {
        if (this.searchedChats().length === 0) {
          ListItem() { this.emptyState('没有找到会话', '试试其他关键词') }
        }
        ForEach(this.searchedChats(), (chat: ChatSummary) => {
          ListItem() { this.chatRow(chat) }
        }, (chat: ChatSummary) => this.chatRenderKey(chat))
      }.layoutWeight(1).width('100%').scrollBar(BarState.Off)
        .divider({ strokeWidth: 0.5, color: this.line(), startMargin: 82, endMargin: 16 })
        .onReachEnd(() => {
          if (this.isTelegram && this.chatSearchVisible && this.currentTab === 0 && this.page === 'home') {
            telegramService.loadMoreChats();
          }
        })
    }.width('100%').height('100%').backgroundColor(this.surface())
  }

  @Builder
  private chatsPage() {
    Stack({ alignContent: Alignment.TopStart }) {
      // Keep the main list mounted, unfiltered by the query, and at its pre-keyboard height.
      this.mainChatsList()
      if (this.chatSearchVisible) { this.chatSearchPage() }
    }.width('100%').height('100%').clip(true)
  }

  @Builder
  private contactsPage() {
    HdsPage({ title: '联系人', showBack: false, surface: true, dark: this.darkMode, content: () => { this.contactsBody() } }).height('100%').width('100%').backgroundColor(this.surface())
  }

  @Builder
  private sectionLabel(label: string) {
    Text(label).fontSize(11).fontWeight(FontWeight.Medium).fontColor(this.mutedInk()).letterSpacing(1)
      .width('100%').padding({ left: 5, top: 24, bottom: 11 })
  }

  @Builder
  private settingRow(icon: Resource, title: string, detail: string, action: () => void) {
    HdsSettingsRow({ title: title, value: detail, icon: icon, action: action })
  }

  @Builder
  private settingsPage() {
    HdsPage({ title: '设置', showBack: false, dark: this.darkMode, content: () => { this.settingsBody() } })
  }

  @Builder
  private accountRow(account: AccountProfile) {
    Row({ space: 14 }) {
      this.avatar(account.avatar || account.name.slice(0, 1), account.color || '#78A5D8', 44, false, account.avatarPath || '')
      Text(account.name).fontSize(16).fontColor(this.ink()).layoutWeight(1)
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      if (account.id === this.activeAccountId) {
        if (this.accountSwitching || !this.telegram.ready) { LoadingProgress().width(22).height(22).color('#268BDE') }
        else { this.icon($r('app.media.hg_check_blue'), 22) }
      }
    }.width('100%').height(76).padding({ left: 16, right: 16 })
      .onClick(() => this.changeAccount(account.id)).enabled(!this.accountSwitching)
      .accessibilityText(`${account.name}${account.id === this.activeAccountId ? '，当前账户' : ''}`)
  }

  @Builder
  private accountManagementPage() {
    HdsPage({ title: '账户管理', dark: this.darkMode, onBack: () => this.goBack(), content: () => { this.accountsBody() } }).width('100%').height('100%').backgroundColor(this.pageBackground())
  }

  @Builder
  private chatHeader() {
    Row({ space: 9 }) {
      if (!this.isWide()) {
        Button({ type: ButtonType.Circle }) { this.icon($r('app.media.hg_back_blue'), 25) }
          .width(36).height(42).backgroundColor(Color.Transparent).onClick(() => this.goBack())
          .accessibilityText('返回会话列表')
      }
      this.avatar(this.activeChat.avatar, this.activeChat.color, 40, false, this.activeChat.avatarPath || '')
      Column({ space: 5 }) {
        Text(this.activeChat.title).fontSize(17).fontWeight(FontWeight.Medium).fontColor(this.ink())
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.activeChat.kind !== 'saved') {
          Text(this.chatDescription()).fontSize(10).fontColor(this.mutedInk()).maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      Button({ type: ButtonType.Circle }) { this.icon($r('app.media.hg_more'), 23) }
        .width(40).height(40).backgroundColor(Color.Transparent)
        .onClick(() => this.menuVisible = !this.menuVisible).accessibilityText('会话操作')
    }.width('100%').height(56).padding({ left: this.isWide() ? 18 : 8, right: 15 }).backgroundColor(this.surface())
    if (this.menuVisible) {
      Row({ space: 10 }) {
        Button(this.activeChat.pinned ? '取消置顶' : '置顶会话').fontSize(13).fontColor('#268BDE')
          .height(36).layoutWeight(1).backgroundColor(this.softBlue()).onClick(() => {
            if (this.isTelegram) { telegramService.togglePinned(this.activeChat.id); }
            else { chatRepository.togglePinned(this.activeChat.id); }
            this.refresh(); this.save(); this.menuVisible = false;
          })
        Button(this.activeChat.muted ? '取消静音' : '静音会话').fontSize(13).fontColor('#268BDE')
          .height(36).layoutWeight(1).backgroundColor(this.softBlue()).onClick(() => {
            if (this.isTelegram) { telegramService.toggleMuted(this.activeChat.id); }
            else { chatRepository.toggleMuted(this.activeChat.id); }
            this.refresh(); this.save(); this.menuVisible = false;
          })
      }.width('100%').padding({ left: 20, right: 20, top: 6, bottom: 14 }).backgroundColor(this.surface())
    }
  }

  @Builder
  private messageActionMenu(message: ChatMessage) {
    Menu() {
      if (!this.menuMatches(message) || this.messagePermissions.loading ||
        (!this.messagePermissions.loaded && this.messagePermissions.error.length === 0)) {
        MenuItem({ content: '正在加载…' }).enabled(false)
      } else if (this.messagePermissions.error.length > 0) {
        MenuItem({ content: '加载失败，重试' }).onClick(() => this.prepareMessageMenu(message))
      } else {
        if (this.messagePermissions.canReply) {
          MenuItem({ content: '回复' }).onClick(() => this.beginComposerAction(message, 'reply'))
        }
        if (this.messagePermissions.canEdit) {
          MenuItem({ content: '编辑' }).onClick(() => this.beginComposerAction(message, 'edit'))
        }
        if (this.messagePermissions.canCopy && this.messageCaption(message).length > 0) {
          MenuItem({ content: '复制文字' }).onClick(() => this.copyMessage(message))
        }
        if (this.messagePermissions.canForward) {
          MenuItem({ content: '转发' }).onClick(() => this.beginForwardMessage(message))
        }
        if (this.messagePermissions.canDeleteForSelf || this.messagePermissions.canDeleteForAll) {
          MenuItem({ content: '删除' }).contentFontColor('#D56464').onClick(() => this.confirmDeleteMessage(message))
        }
        if (!this.messagePermissions.canReply && !this.messagePermissions.canEdit &&
          !this.messagePermissions.canForward && !this.messagePermissions.canDeleteForSelf &&
          !this.messagePermissions.canDeleteForAll && (!this.messagePermissions.canCopy || this.messageCaption(message).length === 0)) {
          MenuItem({ content: '没有可用操作' }).enabled(false)
        }
      }
    }
  }

  private selectedAttachments(): MediaAttachment[] {
    return this.photoDrafts.find((item: PhotoDraft) => item.chatId === this.activeChat.id)?.attachments || [];
  }
  private removeAttachment(path: string): void {
    const items = this.selectedAttachments().filter((item: MediaAttachment) => item.path !== path);
    this.setPhotoDraft(this.activeChat.id, items[0]?.path || '', this.selectedPhotoCaption(), items);
  }
  private viewerItems(): ChatMessage[] {
    const result: ChatMessage[] = [];
    this.messages.forEach((item: ChatMessage) => {
      if (item.status === 'failed') { return; }
      if (item.mediaKind) { result.push(item); }
      item.richBlocks?.forEach((block: RichContentBlock) => { if (block.media) { result.push(block.media); } });
    });
    return result;
  }
  private downloadViewerItem(item: ChatMessage, cancel: boolean = false): void {
    if (item.sourceMessageId && item.mediaFileId) {
      telegramService.downloadRichMedia(item.chatId, item.sourceMessageId, item.mediaFileId, cancel);
    } else if (cancel) { telegramService.cancelMedia(item.chatId, item.id); }
    else { telegramService.downloadMedia(item.chatId, item.id); }
  }
  private tapMessage(message: ChatMessage): void {
    if (message.status === 'failed') { this.restoreFailedMessage(message); return; }
    if (message.mediaKind) {
      this.mediaViewerId = message.id;
      this.photoViewerVisible = true;
      if (message.mediaKind !== 'video' && !message.mediaPath && !message.mediaDownloading) { this.downloadViewerItem(message); }
    }
  }
  @Builder
  private fullScreenPhoto() {
    MediaViewer({ items: this.viewerItems(), initialId: this.mediaViewerId,
      onClose: () => { this.photoViewerVisible = false; },
      onSave: (item: ChatMessage) => {
        if (!item.mediaPath) { return; }
        const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
        AttachmentService.saveMedia(context, item.mediaPath, item.mediaKind === 'video').then((saved: boolean) => {
          if (saved) { this.toast('已保存到相册'); }
        }).catch(() => this.toast('未能保存到相册，请重试'));
      },
      onDownload: (item: ChatMessage) => this.downloadViewerItem(item),
      onCancel: (item: ChatMessage) => this.downloadViewerItem(item, true) })
  }

  private messageMetadata(message: ChatMessage): string {
    const edited = message.editDate ? '已编辑 ' : '';
    const state = !message.outgoing ? '' : message.status === 'failed' ? ' !' : message.status === 'pending' ? ' ◷' :
      message.status === 'local' ? ' 本地' : message.read ? ' ✓✓' : ' ✓';
    return edited + message.time + state;
  }
  private hasMessageHeader(message: ChatMessage, index: number): boolean {
    return !!message.forwardName || !!message.replyPreview ||
      (!this.groupPrevious(index) && this.activeChat.kind === 'group' && !message.outgoing && !!message.senderName);
  }
  private groupPrevious(index: number): boolean { return messagesGrouped(this.messages[index - 1], this.messages[index]); }
  private groupNext(index: number, count: number = 1): boolean { return messagesGrouped(this.messages[index + count - 1], this.messages[index + count]); }
  private albumFrames(items: ChatMessage[]): MediaFrame[] { return albumLayout(items, this.messageMediaWidth()).frames; }
  private singleWidth(message: ChatMessage): number { return singleMediaSize(message, this.messageMediaWidth()).width; }
  private singleHeight(message: ChatMessage): number { return singleMediaSize(message, this.messageMediaWidth()).height; }
  private messageBubbleColor(message: ChatMessage): string {
    return message.outgoing ? (this.darkMode ? '#244765' : '#DAEDFF') : this.surface();
  }
  private openMessageLink(url: string): void {
    const link = safeMessageLink(url);
    if (!link) { return; }
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    context.openLink(link).catch(() => this.toast('无法打开此链接'));
  }

  @Builder
  private senderAvatar(message: ChatMessage, show: boolean) {
    if (this.activeChat.kind === 'group' && !message.outgoing) {
      if (show) {
        UserAvatar({ text: (message.senderName || '').slice(0, 1), color: message.senderColor || '#268BDE',
          avatarSize: 30, imagePath: message.senderAvatarPath || '' })
      } else { Blank().width(30).height(1) }
    }
  }

  @Builder
  private messageHeader(message: ChatMessage, showSender: boolean) {
    if (showSender && this.activeChat.kind === 'group' && !message.outgoing && message.senderName) {
      Text(message.senderName).fontSize(13).fontWeight(FontWeight.Medium)
        .fontColor(message.senderColor || '#268BDE').maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        .constraintSize({ maxWidth: this.messageMaxWidth() - 16 }).margin({ bottom: 3 })
    }
    if (message.forwardName) {
      Text('转发自 ' + message.forwardName).fontSize(12).fontColor('#268BDE').fontWeight(FontWeight.Medium)
        .maxLines(2).constraintSize({ maxWidth: this.messageMaxWidth() - 16 }).margin({ bottom: 4 })
    }
    if (message.replyPreview) {
      Row({ space: 6 }) {
        if (message.replyThumbnailPath) {
          Image(this.mediaSource(message.replyThumbnailPath)).width(34).height(34).objectFit(ImageFit.Cover).borderRadius(3)
        }
        Column({ space: 2 }) {
          Text(message.replySenderName || '回复消息').fontSize(12).fontColor('#268BDE').fontWeight(FontWeight.Medium)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(message.replyPreview).fontSize(13).fontColor(this.ink()).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
        }.alignItems(HorizontalAlign.Start).constraintSize({ maxWidth: this.messageMaxWidth() - (message.replyThumbnailPath ? 70 : 32) })
      }.alignItems(VerticalAlign.Center).padding({ left: 8, right: 8, top: 5, bottom: 5 })
        .backgroundColor(this.darkMode ? '#294359' : '#DFEAF3').borderRadius(5)
        .border({ width: { left: 3 }, color: '#268BDE' }).constraintSize({ maxWidth: this.messageMaxWidth() - 16 })
        .margin({ bottom: 5 }).onClick(() => this.locateReply(message)).accessibilityText('查看回复的原消息')
    }
  }

  @Builder
  private messageLinkPreview(message: ChatMessage) {
    if (message.linkPreview) {
      Column({ space: 3 }) {
        if (message.linkPreview?.siteName) {
          Text(message.linkPreview?.siteName || '').fontSize(12).fontColor('#268BDE').fontWeight(FontWeight.Medium)
        }
        if (message.linkPreview?.title) {
          Text(message.linkPreview?.title || '').fontSize(14).fontColor(this.ink()).fontWeight(FontWeight.Medium).maxLines(3)
        }
        if (message.linkPreview?.description) {
          Text(message.linkPreview?.description || '').fontSize(13).fontColor(this.ink()).maxLines(6)
            .textOverflow({ overflow: TextOverflow.Ellipsis }).lineHeight(18)
        }
      }.alignItems(HorizontalAlign.Start).padding({ left: 8, right: 5, top: 6, bottom: 6 })
        .backgroundColor(this.darkMode ? '#253B50' : '#CFE4F4').borderRadius(5)
        .border({ width: { left: 3 }, color: '#268BDE' }).constraintSize({ maxWidth: this.messageMaxWidth() - 16 })
        .margin({ top: 4 }).onClick(() => this.openMessageLink(message.linkPreview?.url || ''))
    }
  }

  @Builder
  private mediaTile(message: ChatMessage, width: number, height: number) {
    Stack({ alignContent: Alignment.Center }) {
      if (message.mediaPath && message.mediaKind === 'photo') {
        Image(this.mediaSource(message.mediaPath)).width(width).height(height).objectFit(ImageFit.Cover).draggable(false)
      } else if (message.thumbnailPath) {
        Image(this.mediaSource(message.thumbnailPath)).width(width).height(height).objectFit(ImageFit.Cover).draggable(false)
      }
      if (message.mediaKind === 'video' && !message.mediaDownloading) {
        Row() {
          Text(mediaTime(message.mediaDuration || 0)).fontSize(11).fontColor(Color.White)
            .padding({ left: 6, right: 6, top: 2, bottom: 2 }).backgroundColor('#99000000').borderRadius(12)
        }.width('100%').height('100%').alignItems(VerticalAlign.Top).padding(6)
      }
      if (message.mediaKind === 'video' || !message.mediaPath) {
        Column({ space: 4 }) {
          if (message.mediaDownloading) { Text(`${message.mediaProgress || 0}%`).fontSize(14).fontColor(Color.White) }
          else { SymbolGlyph(message.mediaKind === 'video' ? $r('sys.symbol.play_fill') : $r('sys.symbol.arrow_down'))
            .fontSize(22).fontColor([Color.White]) }
          if (message.mediaError) { Text('重试').fontSize(11).fontColor(Color.White) }
        }.padding(12).backgroundColor('#77000000').borderRadius(28)
      }
    }.width(width).height(height).backgroundColor(this.darkMode ? '#233443' : '#B8CAD8').clip(true)
      .onClick(() => this.tapMessage(message)).id('message-media-' + message.id)
  }

  @Builder
  private albumBubble(items: ChatMessage[], index: number) {
    Row({ space: 6 }) {
      this.senderAvatar(items[0], !this.groupNext(index, items.length))
      Column() {
        if (this.hasMessageHeader(items[0], index)) {
          Column() { this.messageHeader(items[0], !this.groupPrevious(index)) }
            .alignItems(HorizontalAlign.Start).padding({ left: 8, right: 8, top: 4 })
        }
        Stack({ alignContent: Alignment.TopStart }) {
          ForEach(this.albumFrames(items), (frame: MediaFrame) => {
            Column() { this.mediaTile(items[frame.index], frame.width, frame.height) }
              .position({ x: frame.x, y: frame.y }).id(this.messageNodeId(items[frame.index].chatId, items[frame.index].id))
              .bindContextMenu(this.messageActionMenu(items[frame.index]), ResponseType.LongPress, {
                aboutToAppear: () => this.prepareMessageMenu(items[frame.index]),
                onDisappear: () => { this.messageMenuOpen = false; this.focusAfterMessageMenu(); } })
              .onVisibleAreaChange([0.5], (visible: boolean, ratio: number) => {
                if (visible && ratio >= 0.5 && this.isTelegram && this.page === 'chat' && items[0].chatId === this.activeChat.id) {
                  telegramService.viewVisibleMessages(items[frame.index].chatId, [items[frame.index].id]);
                }
              })
          }, (frame: MediaFrame) => this.messageRenderKey(items[frame.index]))
          if (!items.some((item: ChatMessage) => this.messageCaption(item).length > 0)) {
            Text(this.messageMetadata(items[items.length - 1])).fontSize(11).fontColor(Color.White)
              .padding({ left: 6, right: 6, top: 2, bottom: 2 }).backgroundColor('#77000000').borderRadius(10)
              .position({ x: this.messageMediaWidth() - 92, y: albumLayout(items, this.messageMediaWidth()).height - 25 })
          }
        }.width(this.messageMediaWidth()).height(albumLayout(items, this.messageMediaWidth()).height)
        ForEach(items.filter((item: ChatMessage) => this.messageCaption(item).length > 0), (item: ChatMessage, captionIndex: number) => {
          MessageText({ text: this.messageCaption(item), entities: item.entities || [], foreground: this.ink(), secondary: this.mutedInk(),
            rightMetadata: true, metadata: captionIndex === items.filter((candidate: ChatMessage) => this.messageCaption(candidate).length > 0).length - 1 ?
              this.messageMetadata(items[items.length - 1]) : '', maxWidth: this.messageMediaWidth() - 16, dark: this.darkMode })
            .padding({ left: 8, right: 8, top: 5, bottom: 5 }).alignSelf(ItemAlign.Start)
        }, (item: ChatMessage) => this.messageRenderKey(item))
      }.width(this.messageMediaWidth()).backgroundColor(this.messageBubbleColor(items[0])).borderRadius(12).clip(true)
    }.width('100%').alignItems(VerticalAlign.Bottom).justifyContent(items[0].outgoing ? FlexAlign.End : FlexAlign.Start)
      .margin({ bottom: this.groupNext(index, items.length) ? 3 : 9 })
  }

  @Builder
  private forwardChatPicker() {
    ForwardChatSheet({ chats: this.chats, preview: this.forwardMessageSource ?
      (this.messageCaption(this.forwardMessageSource) || '图片') : '', busy: this.forwardBusy,
      error: this.forwardError, dark: this.darkMode, onForward: (chatId: string) => this.submitForwardMessage(chatId) })
  }

  @Builder
  private messageBubble(message: ChatMessage, index: number) {
    if (message.service) {
      Row() {
        Text(message.text).fontSize(12).fontColor(this.mutedInk()).textAlign(TextAlign.Center)
          .padding({ left: 10, right: 10, top: 4, bottom: 4 }).backgroundColor(this.darkMode ? '#263746' : '#DDE7F0').borderRadius(12)
          .constraintSize({ maxWidth: this.messageMaxWidth() })
      }.width('100%').justifyContent(FlexAlign.Center).margin({ top: 6, bottom: 9 }).id(this.messageNodeId(message.chatId, message.id))
    } else {
      Row({ space: 6 }) {
        this.senderAvatar(message, !this.groupNext(index))
        Column() {
          if (this.hasMessageHeader(message, index)) {
            Column() { this.messageHeader(message, !this.groupPrevious(index)) }
              .alignItems(HorizontalAlign.Start).padding({ left: 8, right: 8, top: 4 })
          } else if (!message.mediaKind) { Row().height(4) }
          if (message.mediaKind) {
            Stack({ alignContent: Alignment.BottomEnd }) {
              this.mediaTile(message, this.singleWidth(message), this.singleHeight(message))
              if (this.messageCaption(message).length === 0) {
                Text(this.messageMetadata(message)).fontSize(11).fontColor(Color.White)
                  .padding({ left: 6, right: 6, top: 2, bottom: 2 }).backgroundColor('#77000000').borderRadius(10).margin(5)
              }
            }.width(this.singleWidth(message)).height(this.singleHeight(message))
          }
          if (message.richBlocks) {
            Column({ space: 6 }) {
              ForEach(message.richBlocks, (block: RichContentBlock, blockIndex: number) => {
                if (block.media) {
                  Stack({ alignContent: Alignment.BottomEnd }) {
                    this.mediaTile(block.media, Math.min(this.singleWidth(block.media), this.messageMaxWidth() - 16),
                      this.singleHeight(block.media) * Math.min(this.singleWidth(block.media), this.messageMaxWidth() - 16) / this.singleWidth(block.media))
                    if (!block.text && blockIndex === (message.richBlocks?.length || 0) - 1) {
                      Text(this.messageMetadata(message)).fontSize(11).fontColor(Color.White)
                        .padding({ left: 6, right: 6, top: 2, bottom: 2 }).backgroundColor('#77000000').borderRadius(10).margin(5)
                    }
                  }
                  if (block.text) {
                    MessageText({ text: block.text, entities: block.entities, foreground: this.ink(), secondary: this.mutedInk(),
                    textSize: block.kind === 'heading' ? block.level === 1 ? 18 : block.level === 2 ? 16 : 15 : 15,
                      metadata: blockIndex === (message.richBlocks?.length || 0) - 1 ? this.messageMetadata(message) : '',
                      maxWidth: this.messageMaxWidth() - 16, dark: this.darkMode })
                  }
                } else if (block.kind === 'divider') {
                  Divider().color(this.line()).width(this.messageMaxWidth() - 16)
                } else {
                  MessageText({ text: block.text, entities: block.entities, foreground: this.ink(), secondary: this.mutedInk(),
                    textSize: block.kind === 'heading' ? block.level === 1 ? 18 : block.level === 2 ? 16 : 15 : 15,
                    metadata: blockIndex === (message.richBlocks?.length || 0) - 1 ? this.messageMetadata(message) : '',
                    maxWidth: this.messageMaxWidth() - 16, dark: this.darkMode })
                }
              })
              if (message.richTruncated) {
                Button(message.richLoading ? '正在加载…' : message.richError ? '重试加载全文' : '展开全文')
                  .fontSize(13).fontColor('#268BDE').backgroundColor(Color.Transparent).height(36)
                  .enabled(!message.richLoading).onClick(() => telegramService.loadFullRichMessage(message.chatId, message.id))
              }
            }.padding({ left: 8, right: 8, bottom: 5 }).alignItems(HorizontalAlign.Start)
          } else if (message.contactName) {
            Row({ space: 10 }) {
              UserAvatar({ text: message.contactName.slice(0, 1), color: '#5A9BD5', avatarSize: 40 })
              Column({ space: 3 }) {
                Text(message.contactName).fontSize(15).fontWeight(FontWeight.Medium).fontColor(this.ink())
                Text(message.contactPhone || '').fontSize(13).fontColor('#268BDE')
                Text(this.messageMetadata(message)).fontSize(11).fontColor(this.mutedInk())
              }.alignItems(HorizontalAlign.Start)
            }.padding({ left: 8, right: 8, top: 2, bottom: 7 })
          } else if (message.sticker) {
            Stack({ alignContent: Alignment.BottomEnd }) {
              if (message.stickerPath) {
                Image(this.mediaSource(message.stickerPath)).width(180).height(180).objectFit(ImageFit.Contain).draggable(false)
              } else { Text(message.stickerEmoji || '贴纸').fontSize(64).width(180).height(180).textAlign(TextAlign.Center) }
              Text(this.messageMetadata(message)).fontSize(11).fontColor(this.mutedInk()).padding(4)
            }.width(180).height(200)
          } else if (message.largeEmoji) {
            Row({ space: 8 }) {
              Text(message.text).fontSize(52)
              Text(this.messageMetadata(message)).fontSize(11).fontColor(this.mutedInk()).alignSelf(ItemAlign.End)
            }.padding(5)
          } else if (this.messageCaption(message).length > 0) {
            MessageText({ text: this.messageCaption(message), entities: message.entities || [], foreground: this.ink(),
              secondary: message.status === 'failed' ? '#D56464' : this.mutedInk(),
              rightMetadata: !!message.mediaKind, metadata: message.linkPreview ? '' : this.messageMetadata(message),
              maxWidth: message.mediaKind ? this.singleWidth(message) - 16 : this.messageMaxWidth() - 16, dark: this.darkMode })
              .id('message-body-' + (message.contentType || 'text'))
              .padding({ left: 8, right: 8, top: message.mediaKind ? 5 : 0, bottom: 5 }).alignSelf(ItemAlign.Start)
          }
          this.messageLinkPreview(message)
          if (message.linkPreview) {
            Text(this.messageMetadata(message)).fontSize(11).fontColor(this.mutedInk()).alignSelf(ItemAlign.End).padding({ right: 8, bottom: 4 })
          }
        }.constraintSize({ maxWidth: this.messageMaxWidth(), minWidth: 45 })
          .alignItems(HorizontalAlign.Start).backgroundColor(message.sticker || message.largeEmoji ? Color.Transparent : this.messageBubbleColor(message))
          .borderRadius({ topLeft: 13, topRight: 13, bottomLeft: !message.outgoing && !this.groupNext(index) ? 4 : 13,
            bottomRight: message.outgoing && !this.groupNext(index) ? 4 : 13 }).clip(true)
          .onClick(() => { if (message.status === 'failed' && !message.mediaKind) { this.restoreFailedMessage(message); } })
          .bindContextMenu(this.messageActionMenu(message), ResponseType.LongPress,
            { aboutToAppear: () => this.prepareMessageMenu(message), onDisappear: () => {
              this.messageMenuOpen = false; this.focusAfterMessageMenu();
            } })
      }.width('100%').alignItems(VerticalAlign.Bottom).justifyContent(message.outgoing ? FlexAlign.End : FlexAlign.Start)
        .id(this.messageNodeId(message.chatId, message.id)).margin({ bottom: this.groupNext(index) ? 3 : 9 })
        .onVisibleAreaChange([0, 0.5], (visible: boolean, ratio: number) => {
          if (visible && ratio >= 0.5 && this.isTelegram && this.page === 'chat' && this.activeChat.id === message.chatId) {
            telegramService.viewVisibleMessages(message.chatId, [message.id]);
          }
        })
    }
  }

  @Builder
  private composer() {
    if (this.activeChat.kind === 'channel' && !this.currentComposerAction()) {
      Row({ space: 8 }) {
        this.icon($r('app.media.hg_channel'), 17)
        Text(this.isTelegram ? '频道 · 仅可浏览' : '演示频道 · 仅可浏览').fontSize(13).fontColor(this.mutedInk())
      }.height(68).width('100%').justifyContent(FlexAlign.Center).backgroundColor(this.surface())
    } else {
      Column({ space: 8 }) {
        if (this.currentComposerAction()) {
          ComposerContextBar({ title: this.currentComposerAction()?.title || '',
            preview: this.currentComposerAction()?.preview || '', foreground: this.ink(), secondary: this.mutedInk(),
            busy: this.composerBusy(), onCancel: () => this.cancelComposerAction() })
          if ((this.currentComposerAction()?.error || '').length > 0) {
            Text(this.currentComposerAction()?.error || '').fontSize(12).fontColor('#C55D5D')
              .width('100%').padding({ left: 8, right: 8 })
          }
        }
        if (!this.currentComposerAction() && this.hasSelectedPhoto()) {
          Scroll() {
            Row({ space: 8 }) {
              ForEach(this.selectedAttachments(), (item: MediaAttachment) => {
                Stack({ alignContent: Alignment.TopEnd }) {
                  if (item.kind === 'photo') {
                    Image(this.mediaSource(item.path)).width(110).height(100).objectFit(ImageFit.Cover).borderRadius(8)
                  } else {
                    Text(`▶ ${mediaTime(item.duration)}`).width(110).height(100).textAlign(TextAlign.Center)
                      .fontColor(this.ink()).backgroundColor(this.pageBackground()).borderRadius(8)
                  }
                  Button('×').width(28).height(28).fontSize(18).backgroundColor('#99000000').fontColor(Color.White)
                    .onClick(() => this.removeAttachment(item.path)).accessibilityText('移除此附件')
                }
              }, (item: MediaAttachment) => item.path)
            }
          }.scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).width('100%').height(104)
        }
        Row({ space: 7 }) {
          Button({ type: ButtonType.Circle }) { this.icon($r('app.media.hg_attach'), 23) }
            .width(37).height(42).backgroundColor(Color.Transparent)
            .enabled(this.isTelegram && !this.choosingImage && !this.currentComposerAction()).onClick(() => this.chooseImage())
            .accessibilityText('选择图片或视频')
          TextArea({ text: this.composerText(),
            placeholder: !this.currentComposerAction() && this.hasSelectedPhoto() ? '添加说明…' :
              (this.isTelegram ? '输入消息…' : '输入本地消息…') })
            .layoutWeight(1).minLines(1).constraintSize({ minHeight: 44, maxHeight: 132 })
            .maxLines(5, { overflowMode: MaxLinesMode.SCROLL }).textOverflow(TextOverflow.Clip)
            .fontSize(14).lineHeight(22).fontColor(this.ink()).placeholderColor(this.mutedInk())
            .backgroundColor(this.pageBackground()).borderRadius(23).padding({ left: 16, right: 12, top: 11, bottom: 11 })
            .id('message-input').maxLength(this.composerLimit()).enterKeyType(EnterKeyType.NEW_LINE).caretColor('#268BDE')
            .enabled(!this.composerBusy()).onChange((value: string) => this.updateComposerText(value))
            .accessibilityText(this.isTelegram ? '消息输入框' : '本地消息输入框')
          Button({ type: ButtonType.Circle }) {
            if (this.currentComposerAction()?.mode === 'edit') { Text('✓').fontSize(23).fontColor('#FFFFFF') }
            else { this.icon($r('app.media.hg_send_white'), 21) }
          }.width(42).height(42).backgroundColor(this.composerCanSend() ? '#268BDE' : '#A9CBE7')
            .enabled(this.composerCanSend()).onClick(() => this.send())
            .accessibilityText(this.currentComposerAction()?.mode === 'edit' ? '保存编辑' : '发送消息')
        }.width('100%').alignItems(VerticalAlign.Bottom)
        if (!this.isTelegram) {
          Text('离线预览 · 消息不会发送').fontSize(10).fontColor(this.mutedInk())
        }
      }.width('100%').padding({ left: 8, right: 10, top: 6, bottom: 6 }).backgroundColor(this.surface())
    }
  }

  @Builder
  private chatPage() {
    Column() {
      this.chatHeader()
      if (this.isTelegram && this.telegram.error.length > 0) {
        Text(this.telegram.error).fontSize(12).fontColor('#C55D5D').lineHeight(19)
          .width('100%').padding({ left: 18, right: 18, top: 10, bottom: 10 })
          .backgroundColor(this.darkMode ? '#39272D' : '#FFF0F0')
      }
      Scroll(this.messageScroller) {
        Column() {
          if (this.isTelegram && this.historyState.error.length > 0) {
            Column({ space: 6 }) {
              Text(this.historyState.error).fontSize(12).fontColor('#C55D5D').textAlign(TextAlign.Center)
              Button('重新加载').fontSize(12).fontColor('#268BDE').height(32)
                .backgroundColor(Color.Transparent).enabled(!this.historyState.loading)
                .onClick(() => this.loadOlderMessages())
            }.width('100%').padding({ bottom: 12 })
          } else if (this.isTelegram && this.messages.length > 0 && this.historyState.loading) {
            LoadingProgress().width(22).height(22).color('#268BDE').margin({ top: 6, bottom: 12 })
          }
          if (this.messages.length === 0) {
            Column({ space: 12 }) {
              if (this.isTelegram && (this.historyState.loading ||
                (!this.historyState.loaded && this.historyState.error.length === 0))) {
                LoadingProgress().width(28).height(28).color('#268BDE')
              } else if (!this.isTelegram || (this.historyState.loaded && this.historyState.error.length === 0)) {
                Text('暂无消息').fontSize(14).fontColor(this.mutedInk())
              }
            }.width('100%').padding({ top: 55, bottom: 55 })
          }
          ForEach(this.messages, (message: ChatMessage, index: number) => {
            if (this.showsMessageDate(index)) {
              Row() {
                Text(this.messageDateLabel(message)).fontSize(11).fontColor(this.darkMode ? '#D4E3F0' : '#62788D')
                  .padding({ left: 11, right: 11, top: 5, bottom: 5 })
                  .backgroundColor(this.darkMode ? '#263746' : '#DDE7F0').borderRadius(12)
              }.width('100%').justifyContent(FlexAlign.Center).margin({ top: 5, bottom: 14 })
            }
            if (!message.mediaKind || mediaAlbumAt(this.messages, index).length === 1) {
              this.messageBubble(message, index)
            } else if (mediaAlbumAt(this.messages, index).length > 1) {
              this.albumBubble(mediaAlbumAt(this.messages, index), index)
            }
          }, (message: ChatMessage, index: number) => `${this.messageRenderKey(message)}:${this.showsMessageDate(index)}:${this.groupPrevious(index)}:${this.groupNext(index)}:${mediaAlbumAt(this.messages, index).map((item: ChatMessage) => this.messageRenderKey(item)).join(";")}`)
        }.width('100%').padding({ left: 8, right: 8, top: 8, bottom: 6 })
          .onAreaChange((_oldArea: Area, area: Area) => this.updateMessageContentHeight(Number(area.height)))
      }.width('100%').layoutWeight(1).scrollBar(BarState.Off).id('message-scroll')
        .onDidScroll(() => { if (this.userMessageScrolling) { this.wasAtBottom = this.messageScroller.isAtEnd(); } })
        .onScrollStop(() => {
          if (this.userMessageScrolling) { this.wasAtBottom = this.messageScroller.isAtEnd(); this.userMessageScrolling = false; }
        })
        .onWillScroll((_xOffset: number, yOffset: number, _state: ScrollState, source: ScrollSource) => {
          this.observeHistoryScroll(yOffset, source);
        })
        .onReachStart(() => { this.loadHistoryAtStart(); })
        .onAreaChange((_oldArea: Area, area: Area) => { this.updateMessageViewport(Number(area.height)); })
        .align(this.messages.length > 0 ? Alignment.Bottom : Alignment.Center)
        .backgroundColor(this.darkMode ? '#111D29' : '#EDF3F8')
      this.composer()
    }.width('100%').height('100%')
  }

  @Builder
  private brandLogo(size: number, radius: number) {
    Image($r('app.media.harlgram_icon')).width(size).height(size)
      .objectFit(ImageFit.Contain).borderRadius(radius).clip(true)
      .draggable(false).accessibilityText('HmChat Logo')
  }

  @Builder
  private authField(label: string, placeholder: string, value: string, inputType: InputType, change: (value: string) => void) {
    Column({ space: 9 }) {
      Text(label).fontSize(12).fontWeight(FontWeight.Medium).fontColor(this.ink())
      TextInput({ text: value, placeholder: placeholder }).type(inputType)
        .height(50).width('100%').fontSize(14).fontColor(this.ink()).placeholderColor(this.mutedInk())
        .padding({ left: 16, right: 16 })
        .caretColor('#268BDE').onChange(change).onSubmit(() => this.startLogin())
        .accessibilityText(label)
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  private phoneCountryPicker() {
    Column({ space: 12 }) {
      Search({ value: this.countrySearch, placeholder: '搜索国家或区号' })
        .height(46).width('100%').fontColor(this.ink()).placeholderColor(this.mutedInk())
        .textFont({ size: 15 }).backgroundColor(this.pageBackground())
        .onChange((value: string) => { this.countrySearch = value; })
      List() {
        if (searchPhoneCountries(this.countrySearch).length === 0) {
          ListItem() {
            Text('没有找到国家或地区').fontSize(14).fontColor(this.mutedInk())
              .width('100%').padding(24).textAlign(TextAlign.Center)
          }
        }
        ForEach(searchPhoneCountries(this.countrySearch), (country: PhoneCountry) => {
          ListItem() {
            Row({ space: 12 }) {
              Text(country.name).fontSize(16).fontColor(this.ink()).layoutWeight(1)
                .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(country.dialCode).fontSize(15).fontColor('#268BDE')
              if (country.iso === this.selectedCountryIso) { this.icon($r('app.media.hg_check_blue'), 16) }
            }.width('100%').height(52).padding({ left: 8, right: 8 })
              .onClick(() => this.choosePhoneCountry(country)).accessibilityText(`${country.name}，区号 ${country.dialCode}`)
          }
        }, (country: PhoneCountry) => `${country.iso}:${country.iso === this.selectedCountryIso}`)
      }.layoutWeight(1).width('100%').scrollBar(BarState.Auto)
        .divider({ strokeWidth: 0.5, color: this.line() })
    }.width('100%').height('100%').padding({ left: 18, right: 18, top: 8, bottom: 16 })
      .backgroundColor(this.surface())
  }

  @Builder
  private phoneNumberFields() {
    Column({ space: 18 }) {
      Column({ space: 9 }) {
        Text('国家或地区').fontSize(12).fontWeight(FontWeight.Medium).fontColor(this.ink())
        Button({ type: ButtonType.Normal }) {
          Row({ space: 12 }) {
            Text(this.countryName()).fontSize(15).fontColor(this.ink()).layoutWeight(1)
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).textAlign(TextAlign.Start)
            this.icon($r('app.media.hg_chevron'), 16)
          }.width('100%')
        }.height(50).width('100%').padding({ left: 15, right: 15 })
          .backgroundColor(this.surface()).borderRadius(13)
          .onClick(() => { this.countrySearch = ''; this.countryPickerVisible = true; })
          .accessibilityText(`国家或地区：${this.countryName()}`)
          .bindSheet($$this.countryPickerVisible, this.phoneCountryPicker(), {
            height: SheetSize.LARGE, preferType: SheetType.BOTTOM, showClose: true,
            title: { title: '国家或地区' }, backgroundColor: this.surface(),
            keyboardAvoidMode: SheetKeyboardAvoidMode.RESIZE_ONLY,
            onDisappear: () => {
              this.countrySearch = '';
              if (this.focusPhoneAfterPicker && this.page === 'account' && this.telegram.phase === 'phone') {
                this.getUIContext().getFocusController().requestFocus('login-phone-number');
              }
              this.focusPhoneAfterPicker = false;
            }
          })
      }.width('100%').alignItems(HorizontalAlign.Start)
      Row({ space: 12 }) {
        Column({ space: 9 }) {
          Text('区号').fontSize(12).fontWeight(FontWeight.Medium).fontColor(this.ink())
          TextInput({ text: this.callingCode, placeholder: '+86' }).type(InputType.PhoneNumber)
            .height(50).width('100%').fontSize(16).fontColor(this.ink()).placeholderColor(this.mutedInk())
            .backgroundColor(this.surface()).borderRadius(13).padding({ left: 14, right: 10 }).maxLength(6)
            .caretColor('#268BDE').onChange((value: string) => this.updateCallingCode(value))
            .enterKeyType(EnterKeyType.Next)
            .onSubmit(() => { this.getUIContext().getFocusController().requestFocus('login-phone-number'); })
            .accessibilityText('国家或地区电话区号')
        }.width(86).alignItems(HorizontalAlign.Start)
        Column({ space: 9 }) {
          Text('手机号码').fontSize(12).fontWeight(FontWeight.Medium).fontColor(this.ink())
          TextInput({ text: this.phone, placeholder: '手机号码' }).type(InputType.PhoneNumber)
            .id('login-phone-number').height(50).width('100%').fontSize(16)
            .fontColor(this.ink()).placeholderColor(this.mutedInk()).backgroundColor(this.surface())
            .borderRadius(13).padding({ left: 15, right: 15 }).maxLength(40).caretColor('#268BDE')
            .onChange((value: string) => this.updatePhone(value)).onSubmit(() => this.startLogin())
            .accessibilityText('手机号码')
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      }.width('100%').alignItems(VerticalAlign.Top)
    }.width('100%')
  }

  @Builder
  private accountPage() {
    HdsPage({ title: 'Telegram 账号', dark: this.darkMode, onBack: () => this.goBack(), content: () => { this.accountBody() } }).width('100%').height('100%').backgroundColor(this.pageBackground())
  }

  @Builder
  private aboutPage() {
    HdsPage({ title: '关于 HmChat', surface: true, dark: this.darkMode, onBack: () => this.goBack(), content: () => { this.aboutBody() } }).width('100%').height('100%').backgroundColor(this.surface())
  }

  @Builder
  private masterPane() {
    Tabs({ barPosition: BarPosition.End, index: $$this.currentTab, barModifier: this.tabBarVisibility() }) {
      TabContent() { this.chatsPage() }
        .tabBar(BottomTabBarStyle.of(this.chatTabSymbol, '聊天'))
      TabContent() { this.contactsPage() }
        .tabBar(BottomTabBarStyle.of(this.contactsTabSymbol, '联系人'))
      TabContent() { this.settingsPage() }
        .tabBar(BottomTabBarStyle.of(this.settingsTabSymbol, '设置'))
    }.width('100%').height('100%').barMode(BarMode.Fixed)
      .attributeModifier(this.tabBarStyle)
      .barOverlap(true).divider(null).scrollable(false).animationDuration(0)
      .onChange((index: number) => {
        this.currentTab = index;
        if (index !== 0) { this.closeChatSearch(); }
      })
      .expandSafeArea([], [])
  }

  @Builder
  private destinationContent(name: string) {
    // Keep the cover on this node and the sheet on the root: closing an absent
    // sheet can otherwise dismiss a cover sharing its target node in ArkUI.
    NavDestination() {
      if (this.page === 'chat' && this.activeChat.id.length > 0) {
        this.chatPage()
      } else {
        Column({ space: 14 }) {
          this.icon($r('app.media.hg_chat'), 40)
          Text('选择一个聊天').fontSize(15).fontColor(this.mutedInk())
        }.width('100%').height('100%').justifyContent(FlexAlign.Center)
          .backgroundColor(this.pageBackground())
      }
    }.hideTitleBar(true).expandSafeArea([], [])
      .bindContentCover($$this.photoViewerVisible, this.fullScreenPhoto(), { modalTransition: ModalTransition.ALPHA })
      .onBackPressed((): boolean => { this.goBack(); return true; })
  }

  @Builder
  private conversationNavigation() {
    Navigation(this.navigationStack) {
      this.masterPane()
    }.mode(NavigationMode.Auto)
      .navBarWidth(this.navigationWidth()).navBarWidthRange([280, 320]).minContentWidth(320)
      .navBarPosition(NavBarPosition.Start).hideTitleBar(true).hideToolBar(true)
      .navDestination(this.destinationContent).expandSafeArea([], [])
      .width('100%').height('100%').backgroundColor(this.pageBackground())
      .onAppear(() => { this.syncNavigation(); })
  }

  @Builder
  private chatsBody() {
      this.filterBar()
      if (this.isTelegram && this.telegram.connection.length > 0 && this.telegram.connection !== '已连接') {
        Text(this.telegram.connection).fontSize(12).fontColor(this.mutedInk())
          .width('100%').padding({ top: 7, bottom: 7 }).textAlign(TextAlign.Center)
      }
      List() {
        if (this.filteredChats().length === 0) {
          if (this.selectedFilter === 1) {
            ListItem() {
              this.emptyState('没有未读消息', '所有会话都已读')
            }
          } else {
            ListItem() {
              this.emptyState('没有找到会话', '可从联系人开始聊天')
            }
          }
        }
        ForEach(this.filteredChats(), (chat: ChatSummary) => {
          ListItem() { this.chatRow(chat) }
        }, (chat: ChatSummary) => this.chatRenderKey(chat))
      }.layoutWeight(1).width('100%').edgeEffect(EdgeEffect.Spring)
        .divider({ strokeWidth: 0.5, color: this.line(), startMargin: 82, endMargin: 16 }).contentEndOffset(84)
        .scrollBar(BarState.Off)
        .onReachEnd(() => {
          if (this.isTelegram && !this.chatSearchVisible && this.currentTab === 0 && this.page === 'home') {
            telegramService.loadMoreChats();
          }
        })

  }

  @Builder
  private contactsBody() {
      this.contactsSearchBox()
      List() {
        if (this.filteredContacts().length === 0) {
          ListItem() { this.emptyState('没有找到联系人', '请尝试其他姓名或关键词') }
        }
        ForEach(this.filteredContacts(), (contact: Contact) => {
          ListItem() {
            Row({ space: 12 }) {
              this.avatar(contact.avatar, contact.color, 46, contact.online, contact.avatarPath || '')
              Column({ space: 6 }) {
                Text(contact.name).fontSize(16).fontWeight(FontWeight.Medium).fontColor(this.ink())
                  .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(contact.subtitle).fontSize(12).fontColor(this.mutedInk()).maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }.layoutWeight(1).alignItems(HorizontalAlign.Start)
            }.width('100%').padding({ left: 16, right: 16, top: 14, bottom: 14 })
              .onClick(() => this.openContact(contact)).accessibilityText(`与${contact.name}开始会话`)
          }
        }, (contact: Contact) => this.contactRenderKey(contact))
      }.layoutWeight(1).width('100%').scrollBar(BarState.Off)
        .divider({ strokeWidth: 0.5, color: this.line(), startMargin: 74, endMargin: 16 }).contentEndOffset(84)

  }

  @Builder
  private settingsBody() {
    Scroll() {
      Column() {
        Column({ space: 16 }) {
          Row({ space: 15 }) {
            this.avatar(this.currentUser?.avatar || '我', this.currentUser?.color || '#78A5D8', 44, false, this.currentUser?.avatarPath || '')
            Column({ space: 7 }) {
              Text(this.isTelegram ? (this.currentUser?.name || 'Telegram') : '离线预览')
                .fontSize(17).fontWeight(FontWeight.Medium).fontColor(this.ink())
                .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(this.isTelegram ? '已登录' : '消息仅保存在本机').fontSize(11).fontColor(this.mutedInk())
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          }.width('100%')
          if (!this.isTelegram) {
            Button({ type: ButtonType.Normal }) {
              Row({ space: 8 }) {
                this.icon($r('app.media.hg_send_blue'), 17)
                Text('登录 Telegram').fontSize(13).fontWeight(FontWeight.Medium).fontColor('#268BDE')
                Blank()
                this.icon($r('app.media.hg_chevron_blue'), 15)
              }.width('100%')
            }.height(42).width('100%').backgroundColor(this.softBlue()).borderRadius(11)
              .onClick(() => this.enterAccount())
          }
        }.width('100%').padding(16).backgroundColor(this.surface()).borderRadius(16)
        if (this.isTelegram) {
          Column() {
            this.settingRow($r('app.media.hg_group'), '账户管理', '', () => {
              this.accountProfiles = telegramService.accounts();
              this.activeAccountId = telegramService.activeAccount();
              this.page = 'accounts';
            })
          }.width('100%').backgroundColor(this.surface()).borderRadius(17).margin({ top: 16 })
        }
        if (this.isTelegram) {
          this.sectionLabel('数据与存储')
          Column() {
            this.settingRow($r('app.media.hg_globe_blue'), '存储管理', '', () => { this.storageRoute = 'storage'; this.page = 'storage'; })
          }.width('100%').backgroundColor(this.surface()).borderRadius(17)
        }
        if (!this.isTelegram) {
          this.sectionLabel('账号')
          Column() {
            this.settingRow($r('app.media.hg_send_blue'), '登录 Telegram', '', () => this.enterAccount())
            Divider().color(this.line()).margin({ left: 62, right: 17 })
            Row({ space: 12 }) {
              this.icon($r('app.media.hg_edit_blue'), 22)
              Text('API 凭据').fontSize(15).fontColor(this.ink()).maxLines(1)
              Blank()
              Select(this.apiPresetOptions())
                .selected(this.loginApiIndex)
                .value(this.apiPresetLabel(this.loginApiIndex))
                .font({ size: 13, weight: FontWeight.Medium })
                .fontColor(this.mutedInk())
                .optionWidth(OptionWidthMode.FIT_CONTENT)
                .constraintSize({ maxWidth: 170 })
                .enabled(TELEGRAM_API_PRESETS.length > 0)
                .onSelect((index: number) => this.selectLoginApi(index))
                .accessibilityText('API 凭据')
            }.width('100%').height(52).padding({ left: 16, right: 16 })
          }.width('100%').backgroundColor(this.surface()).borderRadius(17)
        }
        this.sectionLabel('网络')
        Column() {
          this.settingRow($r('app.media.hg_globe_blue'), '网络代理', this.proxySummary(), () => this.openProxy())
        }.width('100%').backgroundColor(this.surface()).borderRadius(17)
        this.sectionLabel('个性化')
        Column() {
          HdsSettingsRow({ title: '外观', value: this.appearanceLabel(), icon: $r('app.media.hg_moon_blue'), action: () => this.chooseAppearance() })
        }.width('100%').backgroundColor(this.surface()).borderRadius(17)
        this.sectionLabel('账号与数据')
        Column() {
          this.settingRow($r('app.media.hg_bookmark_blue'), '收藏夹', '', () => this.openSavedMessages())
          Divider().color(this.line()).margin({ left: 62, right: 17 })
          this.settingRow($r('app.media.hg_globe_blue'), '连接状态',
            this.isTelegram ? (this.telegram.connection || '连接中') : '离线预览', () => this.enterAccount())
        }.width('100%').backgroundColor(this.surface()).borderRadius(17)
        this.sectionLabel('关于')
        Column() {
          this.settingRow($r('app.media.hg_info_blue'), '关于 HmChat', '1.0.0', () => this.openAbout())
        }.width('100%').backgroundColor(this.surface()).borderRadius(17)
        if (this.isTelegram) {
          Button('退出 Telegram 账号').buttonStyle(ButtonStyleMode.TEXTUAL).role(ButtonRole.ERROR).height(46).width('100%').margin({ top: 18 })
            .onClick(() => this.confirmLogOut())
        }
      }.width('100%').padding({ left: 16, right: 16, bottom: 100 })
    }.width('100%').height('100%').scrollBar(BarState.Off).align(Alignment.TopStart).backgroundColor(this.pageBackground())

  }

  @Builder
  private accountsBody() {
      Scroll() {
        Column({ space: 16 }) {
          Column() {
            ForEach(this.accountProfiles, (account: AccountProfile) => {
              this.accountRow(account)
            }, (account: AccountProfile) => account.id)
          }.width('100%').backgroundColor(this.surface()).borderRadius(17)
          Column() {
            this.settingRow($r('app.media.hg_edit_blue'), '添加账户', '', () => this.changeAccount())
          }.width('100%').backgroundColor(this.surface()).borderRadius(17).enabled(!this.accountSwitching)
          if (this.telegram.error.length > 0) {
            Text(this.telegram.error).fontSize(13).fontColor('#D56464').width('100%')
          }
        }.width('100%').padding(16)
      }.width('100%').layoutWeight(1).scrollBar(BarState.Off).align(Alignment.TopStart)

  }

  @Builder
  private accountBody() {
      if (this.accountProfiles.some((item: AccountProfile) => item.id !== this.activeAccountId)) {
        Row({ space: 8 }) {
          ForEach(this.accountProfiles.filter((item: AccountProfile) => item.id !== this.activeAccountId), (account: AccountProfile) => {
            Button({ type: ButtonType.Normal }) {
              Row({ space: 8 }) {
                this.avatar(account.avatar || account.name.slice(0, 1), account.color || '#78A5D8', 30, false, account.avatarPath || '')
                Text(account.name).fontSize(13).fontColor(this.ink()).maxLines(1)
              }.padding({ left: 10, right: 10 })
            }.height(46).backgroundColor(this.surface()).borderRadius(23)
              .onClick(() => this.changeAccount(account.id)).enabled(!this.accountSwitching)
          }, (account: AccountProfile) => account.id)
        }.padding(8).width('100%')
      }
      Scroll() {
        Column({ space: 18 }) {
          Column() { this.brandLogo(84, 24) }.margin({ top: 25, bottom: 8 })
          Text(this.authTitle()).fontSize(26).fontWeight(FontWeight.Bold).fontColor(this.ink()).textAlign(TextAlign.Center)
          Text(this.authHint()).fontSize(13).fontColor(this.mutedInk()).lineHeight(23).textAlign(TextAlign.Center)
            .width('100%').margin({ bottom: 12 })
          if (this.telegram.ready) {
            Row({ space: 8 }) {
              Text('').width(7).height(7).backgroundColor('#54C69E').borderRadius(4)
              Text(this.telegram.connection || '账号已就绪').fontSize(13).fontColor(this.ink())
            }.width('100%').padding(20).backgroundColor(this.surface()).borderRadius(16)
            Button('进入聊天').fontSize(15).fontColor('#FFFFFF').height(50).width('100%')
              .buttonStyle(ButtonStyleMode.EMPHASIZED).onClick(() => { this.page = 'home'; this.currentTab = 0; })
          } else if (this.telegram.phase === 'starting' && this.telegram.error.length === 0 && this.localError.length === 0) {
            LoadingProgress().width(40).height(40).color('#268BDE').margin({ top: 30, bottom: 30 })
          } else {
            if (this.telegram.phase === 'phone') {
              this.phoneNumberFields()
            } else if (this.telegram.phase === 'code') {
              this.authField('Telegram 验证码', '输入收到的验证码', this.authCode, InputType.Normal, (value: string) => this.authCode = value)
            } else if (this.telegram.phase === 'registration') {
              this.authField('名字', '必填', this.registrationFirst, InputType.Normal, (value: string) => this.registrationFirst = value)
              this.authField('姓氏', '选填', this.registrationLast, InputType.Normal, (value: string) => this.registrationLast = value)
              if ((this.telegram.termsText || '').length > 0) {
                Scroll() { Text(this.telegram.termsText || '').fontSize(13).fontColor(this.ink()).width('100%') }
                  .width('100%').constraintSize({ maxHeight: 220 })
              }
              Hyperlink('https://telegram.org/tos', 'Telegram 服务条款')
              if ((this.telegram.minAge || 0) > 0) {
                Text(`最低年龄：${this.telegram.minAge} 岁`).fontSize(12).fontColor(this.mutedInk())
              }
              Row({ space: 8 }) {
                Checkbox().select(this.registrationAccepted).onChange((value: boolean) => this.registrationAccepted = value)
                Text('我已阅读并同意条款，且符合最低年龄要求').fontSize(12).fontColor(this.ink()).layoutWeight(1)
              }.width('100%')
            } else if (this.telegram.phase === 'password') {
              this.authField('两步验证密码', '输入你的云密码', this.password, InputType.Password, (value: string) => this.password = value)
            } else if (this.telegram.phase === 'email') {
              this.authField('电子邮箱', 'name@example.com', this.email, InputType.Email, (value: string) => this.email = value)
            } else if (this.telegram.phase === 'emailCode') {
              this.authField('邮箱验证码', '输入邮件中的验证码', this.emailCode, InputType.Normal, (value: string) => this.emailCode = value)
            } else if (this.showDeveloperConfig) {
              this.authField('API ID', 'Telegram 应用 API ID', this.apiId, InputType.Number, (value: string) => this.apiId = value)
              this.authField('API Hash', '32 位应用密钥', this.apiHash, InputType.Password, (value: string) => this.apiHash = value)
              Text('应用配置可在 my.telegram.org 的 API development tools 中获取。配置安全保存在此设备，验证码和密码不会持久保存。')
                .fontSize(11).fontColor(this.mutedInk()).lineHeight(20).width('100%')
            }
            if (this.telegram.phase === 'code' || this.telegram.phase === 'emailCode') {
              Button((this.telegram.resendSeconds || 0) > 0 ? `${this.telegram.resendSeconds} 秒后可重发` : '未收到验证码？重新发送')
                .fontSize(13).buttonStyle(ButtonStyleMode.TEXTUAL).fontColor('#268BDE')
                .enabled(this.telegram.canResend === true).onClick(() => telegramService.resendCode())
              if (this.telegram.phase === 'code' && !this.telegram.nextDelivery) {
                Text('Telegram 暂未提供其他发送方式，请确认号码并稍后重试。').fontSize(12).fontColor(this.mutedInk())
              }
            }
            if (this.localError.length > 0 || this.telegram.error.length > 0) {
              Text(this.telegram.error.length > 0 ? this.telegram.error : this.localError).fontSize(12).fontColor('#D56464')
                .lineHeight(21).width('100%').padding(15)
                .backgroundColor(this.darkMode ? '#39272D' : '#FFF0F0').borderRadius(12)
            }
            if (this.telegram.phase !== 'unsupported' || this.showDeveloperConfig) {
              Button(this.authSubmitting ? '正在处理…' : (this.telegram.phase === 'storageRecovery' ? '重新登录' :
                (this.telegram.phase === 'registration' ? '同意并创建账号' : (this.telegram.phase === 'password' ? '验证并登录' : '继续'))))
                .fontSize(15).fontWeight(FontWeight.Medium).fontColor('#FFFFFF')
                .height(50).width('100%').buttonStyle(ButtonStyleMode.EMPHASIZED)
                .enabled(!this.authSubmitting).onClick(() => this.startLogin())
            }
          }
          if (!this.telegram.ready && (this.telegram.phase === 'idle' || this.telegram.phase === 'error' ||
            this.telegram.phase === 'closed' || this.telegram.phase === 'unsupported')) {
            Button(this.showDeveloperConfig ? '收起开发者配置' : '开发者配置（可选）').fontSize(12).fontColor('#268BDE')
              .height(36).buttonStyle(ButtonStyleMode.TEXTUAL)
              .onClick(() => { this.showDeveloperConfig = !this.showDeveloperConfig; this.localError = ''; })
          }
          if (this.telegram.phase === 'code' || this.telegram.phase === 'emailCode' || this.telegram.phase === 'registration' || this.telegram.phase === 'password') {
            Button('更换手机号').fontSize(13).buttonStyle(ButtonStyleMode.TEXTUAL).fontColor('#268BDE')
              .enabled(!this.authSubmitting).onClick(() => telegramService.editPhone())
          }
          Blank().height(24)
        }.width('100%').constraintSize({ maxWidth: 480 }).padding({ left: 26, right: 26 })
      }.width('100%').layoutWeight(1).scrollBar(BarState.Off).align(Alignment.Top)

  }

  @Builder
  private aboutBody() {
      Scroll() {
        Column({ space: 20 }) {
          Column() { this.brandLogo(86, 24) }.margin({ top: 28 })
          Text('HmChat').fontSize(28).fontWeight(FontWeight.Medium).fontColor(this.ink())
          Text('版本 1.0.0').fontSize(12).fontColor(this.mutedInk())
          Text('基于 Telegram 服务的 HarmonyOS 原生客户端。第三方独立项目，与 Telegram 官方无隶属关系。')
            .fontSize(14).fontColor(this.mutedInk()).lineHeight(24).width('100%').margin({ top: 12 })
          Text('离线预览使用虚构联系人，消息仅保存在本机。')
            .fontSize(13).fontColor(this.mutedInk()).lineHeight(22).width('100%')
        }.width('100%').constraintSize({ maxWidth: 480 }).padding({ left: 28, right: 28, bottom: 32 })
      }.layoutWeight(1).width('100%').scrollBar(BarState.Off).align(Alignment.Top)

  }

  build() {
    WithTheme({ colorMode: this.appearanceMode === 'system' ? ThemeColorMode.SYSTEM :
      this.darkMode ? ThemeColorMode.DARK : ThemeColorMode.LIGHT }) {
    Column() {
      if (this.appearanceObserverReady) { SystemAppearanceObserver() }
      if (!this.ready) {
        Column() {
          LoadingProgress().width(36).height(36).color('#268BDE')
        }.width('100%').height('100%').justifyContent(FlexAlign.Center)
      } else if (this.page === 'account') {
        this.accountPage()
      } else if (this.page === 'accounts') {
        this.accountManagementPage()
      } else if (this.page === 'storage') {
        StoragePage({ manager: telegramService.storageManager, route: this.$storageRoute, dark: this.darkMode,
          onClose: () => { this.page = 'home'; this.currentTab = 2; } })
      } else if (this.page === 'proxy') {
        ProxyPage({ service: clashService, dark: this.darkMode, onBack: () => this.closeProxy() })
      } else if (this.page === 'about') {
        this.aboutPage()
      } else {
        this.conversationNavigation()
      }
    }.width('100%').height('100%').backgroundColor(this.windowBackground())
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
      .onAreaChange((_oldArea: Area, newArea: Area) => { this.updateViewport(Number(newArea.width)); })
      .bindSheet($$this.forwardSheetVisible, this.forwardChatPicker(), {
        height: SheetSize.LARGE, preferType: SheetType.BOTTOM, showClose: true,
        title: { title: '转发消息' }, backgroundColor: this.surface(),
        keyboardAvoidMode: SheetKeyboardAvoidMode.RESIZE_ONLY,
        onWillDismiss: (action: DismissSheetAction) => { action.dismiss(); }
      })
    }
  }
}
