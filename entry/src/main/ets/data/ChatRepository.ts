import { ChatSummary, ChatMessage, Contact, ChatDraft, ChatSnapshot } from '../model/ChatModels';
import { createDemoChats, createDemoMessages, createDemoContacts } from './DemoData';

/** Local sandbox repository. Remote delivery must never be inferred from a local write. */
export class ChatRepository {
  private chats: ChatSummary[] = createDemoChats();
  private messages: ChatMessage[] = createDemoMessages();
  private contacts: Contact[] = createDemoContacts();
  private drafts: ChatDraft[] = [];
  private darkMode: boolean = false;
  private sequence: number = 0;
  private remote: boolean = false;

  isRemote(): boolean { return this.remote; }

  useRemoteData(): void {
    this.remote = true;
    this.chats = [];
    this.messages = [];
    this.contacts = [];
    this.drafts = [];
  }

  useDemoData(): void {
    this.remote = false;
    this.chats = createDemoChats();
    this.messages = createDemoMessages();
    this.contacts = createDemoContacts();
    this.drafts = [];
  }

  upsertChat(chat: ChatSummary): void {
    chat.draft = this.getDraft(chat.id) || undefined;
    const index = this.chats.findIndex((item: ChatSummary): boolean => item.id === chat.id);
    if (index < 0) { this.chats.push(chat); } else { this.chats[index] = chat; }
  }

  removeChat(chatId: string): void {
    this.chats = this.chats.filter((item: ChatSummary): boolean => item.id !== chatId);
  }

  upsertContact(contact: Contact): void {
    const index = this.contacts.findIndex((item: Contact): boolean => item.id === contact.id);
    if (index < 0) { this.contacts.push(contact); } else { this.contacts[index] = contact; }
  }

  upsertMessage(message: ChatMessage, oldId: string = ''): void {
    this.messages = this.messages.filter((item: ChatMessage): boolean =>
      !(item.chatId === message.chatId && (item.id === message.id || (oldId !== '' && item.id === oldId))));
    this.messages.push(message);
  }

  replaceMessages(chatId: string, messages: ChatMessage[]): void {
    this.messages = this.messages.filter((item: ChatMessage): boolean => item.chatId !== chatId).concat(messages);
  }

  deleteMessages(chatId: string, ids: string[]): void {
    this.messages = this.messages.filter((item: ChatMessage): boolean => item.chatId !== chatId || !ids.includes(item.id));
  }

  private mediaMessages(): ChatMessage[] {
    const result: ChatMessage[] = [];
    this.messages.forEach((message: ChatMessage) => {
      result.push(message); message.richBlocks?.forEach((block) => { if (block.media) { result.push(block.media); } });
    });
    return result;
  }

  updatePhotoFile(fileId: number, path: string): void {
    this.mediaMessages().forEach((message: ChatMessage): void => {
      if (message.mediaKind && message.mediaFileId === fileId) { message.mediaPath = path; }
      if (message.replyThumbnailFileId === fileId) { message.replyThumbnailPath = path; }
    });
  }

  updateMediaTransfer(fileId: number, progress: number, downloading: boolean, error: string = ''): void {
    this.mediaMessages().forEach((message: ChatMessage): void => {
      if (message.mediaFileId === fileId) {
        message.mediaProgress = progress; message.mediaDownloading = downloading; message.mediaError = error;
      }
    });
  }
  updateThumbnailFile(fileId: number, path: string): void {
    this.mediaMessages().forEach((message: ChatMessage): void => { if (message.thumbnailFileId === fileId) { message.thumbnailPath = path; } });
  }

  updateSenderAvatar(senderId: string, fileId: number | undefined, path: string): void {
    this.messages.forEach((item: ChatMessage) => {
      if (item.senderId === senderId) { item.senderAvatarFileId = fileId; item.senderAvatarPath = path; }
    });
  }
  updateOutboxRead(chatId: string, lastRead: number): void {
    this.messages.forEach((item: ChatMessage) => {
      if (item.chatId === chatId && item.outgoing) { item.read = item.status === 'sent' && Number(item.id) <= lastRead; }
    });
  }

  updateSenderName(senderId: string, name: string, color: string): void {
    this.messages.forEach((message: ChatMessage): void => {
      if (message.senderId === senderId) { message.senderName = name; message.senderColor = color; }
    });
  }

  updateAvatarFile(fileId: number, path: string): void {
    this.messages.forEach((item: ChatMessage) => {
      if (item.senderAvatarFileId === fileId) { item.senderAvatarPath = path; }
      if (item.stickerFileId === fileId) { item.stickerPath = path; }
    });
    this.chats.forEach((chat: ChatSummary): void => { if (chat.avatarFileId === fileId) { chat.avatarPath = path; } });
    this.contacts.forEach((contact: Contact): void => { if (contact.avatarFileId === fileId) { contact.avatarPath = path; } });
  }

  getChats(): ChatSummary[] {
    return this.chats.slice().sort((a: ChatSummary, b: ChatSummary): number => {
      if (this.remote) {
        const first = a.order || '0';
        const second = b.order || '0';
        if (first.length !== second.length) { return second.length - first.length; }
        return first < second ? 1 : first > second ? -1 : 0;
      }
      if (a.pinned === b.pinned) { return 0; }
      return a.pinned ? -1 : 1;
    });
  }

  getMessages(chatId: string): ChatMessage[] {
    const messages = this.messages.filter((message: ChatMessage): boolean => message.chatId === chatId);
    return this.remote ? messages.sort((a: ChatMessage, b: ChatMessage): number => {
      if (a.id.startsWith('failed:')) { return b.id.startsWith('failed:') ? 0 : 1; }
      if (b.id.startsWith('failed:')) { return -1; }
      return Number(a.id) - Number(b.id);
    }) : messages;
  }

  getContacts(): Contact[] { return this.contacts.slice(); }

  sendMessage(chatId: string, text: string): boolean {
    if (this.remote) { return false; }
    const content = text.trim();
    const chat = this.chats.find((item: ChatSummary): boolean => item.id === chatId);
    if (!chat || chat.kind === 'channel' || content.length === 0 || content.length > 4096) { return false; }
    const now = new Date();
    const time = `${now.getHours().toString().padStart(2, '0')}:${now.getMinutes().toString().padStart(2, '0')}`;
    this.sequence += 1;
    const message: ChatMessage = {
      id: `local-${now.getTime()}-${this.sequence}`, chatId: chatId, text: content,
      time: time, outgoing: true, status: 'local'
    };
    this.messages.push(message);
    chat.subtitle = content;
    chat.time = time;
    this.chats = this.chats.filter((item: ChatSummary): boolean => item.id !== chatId);
    this.chats.unshift(chat);
    this.setDraft(chatId, '');
    return true;
  }

  markRead(chatId: string): void {
    const chat = this.chats.find((item: ChatSummary): boolean => item.id === chatId);
    if (chat) { chat.unread = 0; }
  }

  togglePinned(chatId: string): void {
    const chat = this.chats.find((item: ChatSummary): boolean => item.id === chatId);
    if (chat) { chat.pinned = !chat.pinned; }
  }

  toggleMuted(chatId: string): void {
    const chat = this.chats.find((item: ChatSummary): boolean => item.id === chatId);
    if (chat) { chat.muted = !chat.muted; }
  }

  openContact(contactId: string): string {
    const contact = this.contacts.find((item: Contact): boolean => item.id === contactId);
    if (!contact) { return ''; }
    const existing = this.chats.find((item: ChatSummary): boolean => item.id === contactId);
    if (existing) { return existing.id; }
    const chat: ChatSummary = {
      id: contact.id, title: contact.name, subtitle: '开始一段新的对话', avatar: contact.avatar,
      color: contact.color, kind: 'private', time: '', unread: 0, pinned: false,
      muted: false, online: contact.online
    };
    this.chats.unshift(chat);
    return chat.id;
  }

  getDraft(chatId: string): string {
    const draft = this.drafts.find((item: ChatDraft): boolean => item.chatId === chatId);
    return draft ? draft.text : '';
  }

  setDraft(chatId: string, text: string): void {
    const chat = this.chats.find((item: ChatSummary): boolean => item.id === chatId);
    if (!chat) { return; }
    const content = text.slice(0, 4096);
    this.drafts = this.drafts.filter((item: ChatDraft): boolean => item.chatId !== chatId);
    if (content.length > 0) { this.drafts.push({ chatId: chatId, text: content }); }
    chat.draft = content || undefined;
  }

  getDarkMode(): boolean { return this.darkMode; }
  setDarkMode(value: boolean): void { this.darkMode = value; }

  serialize(): string {
    const snapshot: ChatSnapshot = {
      version: 1, chats: this.chats, messages: this.messages, drafts: this.drafts,
      darkMode: this.darkMode, sequence: this.sequence
    };
    return JSON.stringify(snapshot);
  }

  restore(raw: string): boolean {
    try {
      const snapshot = JSON.parse(raw) as ChatSnapshot;
      if (!snapshot || snapshot.version !== 1 || !Array.isArray(snapshot.chats) ||
        !Array.isArray(snapshot.messages) || !Array.isArray(snapshot.drafts) ||
        typeof snapshot.darkMode !== 'boolean' || !Number.isSafeInteger(snapshot.sequence) || snapshot.sequence < 0) {
        return false;
      }
      const ids = new Set<string>();
      for (const chat of snapshot.chats) {
        if (!chat || typeof chat.id !== 'string' || chat.id.length === 0 || ids.has(chat.id) ||
          typeof chat.title !== 'string' || typeof chat.subtitle !== 'string' ||
          typeof chat.avatar !== 'string' || typeof chat.color !== 'string' || typeof chat.time !== 'string' ||
          typeof chat.pinned !== 'boolean' || typeof chat.muted !== 'boolean' || typeof chat.online !== 'boolean' ||
          !Number.isSafeInteger(chat.unread) || chat.unread < 0 ||
          !['private', 'group', 'channel', 'saved'].includes(chat.kind)) { return false; }
        ids.add(chat.id);
      }
      const messageIds = new Set<string>();
      for (const message of snapshot.messages) {
        if (!message || typeof message.id !== 'string' || messageIds.has(message.id) || !ids.has(message.chatId) ||
          typeof message.text !== 'string' || typeof message.time !== 'string' || typeof message.outgoing !== 'boolean' ||
          !['local', 'received'].includes(message.status)) { return false; }
        messageIds.add(message.id);
      }
      for (const draft of snapshot.drafts) {
        if (!draft || !ids.has(draft.chatId) || typeof draft.text !== 'string' || draft.text.length > 4096) { return false; }
      }
      this.chats = snapshot.chats;
      this.messages = snapshot.messages;
      this.drafts = snapshot.drafts;
      this.darkMode = snapshot.darkMode;
      this.sequence = snapshot.sequence;
      return true;
    } catch { return false; }
  }
}

export const chatRepository = new ChatRepository();
