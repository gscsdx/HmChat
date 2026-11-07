export type ChatKind = 'private' | 'group' | 'channel' | 'saved';

export interface ChatSummary {
  id: string;
  title: string;
  subtitle: string;
  avatar: string;
  color: string;
  kind: ChatKind;
  time: string;
  unread: number;
  pinned: boolean;
  muted: boolean;
  online: boolean;
  order?: string;
  draft?: string;
  avatarPath?: string;
  avatarFileId?: number;
}

export interface MessageEntity { offset: number; length: number; type: string; url?: string; }
export interface MessageLinkPreview { url: string; title: string; description: string; siteName: string; }

export interface RichContentBlock { kind: string; text: string; entities: MessageEntity[]; level: number; media?: ChatMessage; }

export interface ChatMessage {
  id: string;
  chatId: string;
  text: string;
  time: string;
  outgoing: boolean;
  status: 'local' | 'received' | 'pending' | 'sent' | 'failed';
  date?: number;
  senderId?: string;
  senderName?: string;
  senderColor?: string;
  senderAvatarPath?: string;
  senderAvatarFileId?: number;
  sourceMessageId?: string;
  richBlocks?: RichContentBlock[];
  richTruncated?: boolean;
  richLoading?: boolean;
  richError?: string;
  contactName?: string;
  contactPhone?: string;
  contentType?: string;
  entities?: MessageEntity[];
  forwardName?: string;
  linkPreview?: MessageLinkPreview;
  service?: boolean;
  read?: boolean;
  canSave?: boolean;
  sticker?: boolean;
  stickerEmoji?: string;
  stickerPath?: string;
  stickerFileId?: number;
  largeEmoji?: boolean;
  mediaPath?: string;
  mediaFileId?: number;
  mediaKind?: 'photo' | 'video';
  mediaAlbumId?: string;
  thumbnailPath?: string;
  thumbnailFileId?: number;
  mediaWidth?: number;
  mediaHeight?: number;
  mediaDuration?: number;
  mediaSize?: number;
  mediaProgress?: number;
  mediaDownloading?: boolean;
  mediaError?: string;
  contentKind?: 'text' | 'photo' | 'video' | 'other';
  caption?: string;
  editDate?: number;
  replyToChatId?: string;
  replyToMessageId?: string;
  replyPreview?: string;
  replyThumbnailPath?: string;
  replyThumbnailFileId?: number;
  replySenderName?: string;
}

export interface MessagePermissions {
  loading: boolean;
  loaded: boolean;
  error: string;
  canReply: boolean;
  canEdit: boolean;
  canDeleteForSelf: boolean;
  canDeleteForAll: boolean;
  canForward: boolean;
  canCopy: boolean;
}

export type MessageActionKind = 'reply' | 'edit' | 'delete' | 'forward' | 'locate';
export interface MessageActionState {
  status: 'pending' | 'succeeded' | 'failed';
  error: string;
  kind: MessageActionKind;
  chatId: string;
  messageId: string;
  targetChatId?: string;
  targetMessageId?: string;
}

export interface Contact {
  id: string;
  name: string;
  subtitle: string;
  avatar: string;
  color: string;
  online: boolean;
  avatarPath?: string;
  avatarFileId?: number;
}

export interface ChatDraft {
  chatId: string;
  text: string;
}

export interface ChatSnapshot {
  version: number;
  chats: ChatSummary[];
  messages: ChatMessage[];
  drafts: ChatDraft[];
  darkMode: boolean;
  sequence: number;
}
