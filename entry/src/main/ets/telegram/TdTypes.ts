export interface TdType { '@type': string; }
export interface TdTextEntity { offset: number; length: number; type: { '@type': string; url?: string; }; }
export interface TdText extends TdType { text: string; entities?: TdTextEntity[]; }
export interface TdLocalFile {
  path: string; can_be_downloaded: boolean; is_downloading_active: boolean; is_downloading_completed: boolean; downloaded_size?: number; download_offset?: number; downloaded_prefix_size?: number;
}
export interface TdFile extends TdType { id: number; size: number; expected_size: number; local: TdLocalFile; }
export interface TdPhotoSize { type: string; photo: TdFile; width: number; height: number; }
export interface TdPhoto { sizes: TdPhotoSize[]; }
export interface TdProfilePhoto { small: TdFile; big?: TdFile; }
export interface TdVideo { duration: number; width: number; height: number; mime_type?: string; thumbnail?: { width: number; height: number; file: TdFile; }; video: TdFile; }
export interface TdRichText extends TdType {
  text?: TdRichText | string; texts?: TdRichText[]; url?: string; username?: string;
  email_address?: string; phone_number?: string; alternative_text?: string; expression?: string;
}
export interface TdRichMessage extends TdType { blocks: TdPageBlock[]; is_rtl: boolean; is_full: boolean; }
export interface TdPageBlock extends TdType {
  size?: number;
  text?: TdRichText; title?: TdRichText; subtitle?: TdRichText; header?: TdRichText; subheader?: TdRichText;
  kicker?: TdRichText; footer?: TdRichText; author?: TdRichText; credit?: TdRichText;
  blocks?: TdPageBlock[]; cover?: TdPageBlock; items?: { label: string; blocks: TdPageBlock[]; has_checkbox?: boolean; is_checked?: boolean; }[];
  photo?: TdPhoto; video?: TdVideo; animation?: { duration: number; width: number; height: number; thumbnail?: { file: TdFile; }; animation: TdFile; };
  caption?: { text: TdRichText; credit: TdRichText; }; has_spoiler?: boolean;
  url?: string; expression?: string; document?: { file_name: string; document: TdFile; };
  cells?: { text: TdRichText; }[][];
}
export interface TdContent extends TdType {
  message?: TdRichMessage;
  contact?: { first_name: string; last_name: string; phone_number: string; user_id: number; };
  emoji?: string;
  sticker?: { width: number; height: number; emoji: string; format: TdType; thumbnail?: { file: TdFile; }; sticker: TdFile; };
  animation?: { duration: number; width: number; height: number; thumbnail?: { file: TdFile; }; animation: TdFile; };
  document?: { file_name: string; document: TdFile; };
  voice_note?: { duration: number; };
  poll?: { question: TdText; options: { text: TdText; }[]; };
  text?: TdText; caption?: TdText; photo?: TdPhoto; video?: TdVideo; has_spoiler?: boolean; is_secret?: boolean;
  show_caption_above_media?: boolean;
  link_preview?: { url: string; title: string; description: { text: string }; site_name: string; } | null;
  member_user_ids?: number[]; user_id?: number; title?: string;
}
export interface TdMessageReply extends TdType {
  chat_id?: number; message_id?: number; quote?: { text: TdText } | null; content?: TdContent | null;
}
export interface TdMessageProperties extends TdType {
  can_be_replied: boolean; can_be_edited: boolean; can_be_deleted_only_for_self: boolean;
  can_be_deleted_for_all_users: boolean; can_be_forwarded: boolean; can_be_copied: boolean; can_be_saved: boolean;
}
export interface TdMessageTopic extends TdType {
  message_thread_id?: number; forum_topic_id?: number; direct_messages_chat_topic_id?: number; saved_messages_topic_id?: number;
}
export interface TdDraft extends TdType { date: number; content: TdContent; }
export interface TdPosition { list: TdType; order: string; is_pinned: boolean; }
export interface TdChatType extends TdType { user_id?: number; is_channel?: boolean; is_megagroup?: boolean; }
export interface TdNotification {
  '@type'?: string;
  mute_for: number; use_default_mute_for?: boolean;
  use_default_sound?: boolean; sound_id?: string;
  use_default_show_preview?: boolean; show_preview?: boolean;
  use_default_mute_stories?: boolean; mute_stories?: boolean;
  use_default_story_sound?: boolean; story_sound_id?: string;
  use_default_show_story_poster?: boolean; show_story_poster?: boolean;
  use_default_disable_pinned_message_notifications?: boolean; disable_pinned_message_notifications?: boolean;
  use_default_disable_mention_notifications?: boolean; disable_mention_notifications?: boolean;
}
export interface TdMessageSender extends TdType { user_id?: number; chat_id?: number; }
export interface TdMessage extends TdType {
  can_be_saved?: boolean;
  id: number; chat_id: number; date: number; is_outgoing: boolean; media_album_id?: string;
  sender_id?: TdMessageSender;
  forward_info?: { origin: { '@type': string; sender_user_id?: number; sender_name?: string; sender_chat_id?: number; chat_id?: number; }; } | null;
  content: TdContent; sending_state?: TdType | null;
  edit_date?: number; reply_to?: TdMessageReply | null; topic_id?: TdMessageTopic | null;
}
export interface TdChat extends TdType {
  id: number; title: string; type: TdChatType; positions: TdPosition[];
  last_read_outbox_message_id?: number;
  last_message?: TdMessage; unread_count: number; notification_settings: TdNotification;
  draft_message?: TdDraft | null;
  photo?: TdProfilePhoto | null;
}
export interface TdUser extends TdType {
  id: number; first_name: string; last_name: string; status: TdType; is_contact?: boolean;
  profile_photo?: TdProfilePhoto | null;
}
export interface TdAuthorization extends TdType {
  password_hint?: string; email_address_pattern?: string; link?: string;
  code_info?: { type?: TdType; next_type?: TdType | null; timeout?: number; };
  terms_of_service?: { text: TdText; min_user_age: number; show_popup: boolean; };
}
export interface TdEvent extends TdType {
  new_content?: TdContent;
  '@extra'?: string; '@client_id'?: number;
  authorization_state?: TdAuthorization; state?: TdType;
  chat?: TdChat; user?: TdUser; message?: TdMessage;
  messages?: (TdMessage | null)[]; user_ids?: number[];
  chat_id?: number; user_id?: number; old_message_id?: number;
  message_ids?: number[]; is_permanent?: boolean;
  last_message?: TdMessage; positions?: TdPosition[]; position?: TdPosition;
  last_read_outbox_message_id?: number;
  unread_count?: number; title?: string; notification_settings?: TdNotification;
  status?: TdType; content?: TdContent; message_id?: number;
  draft_message?: TdDraft | null; file?: TdFile;
  photo?: TdProfilePhoto | null;
  code?: number; message_text?: string;
  edit_date?: number;
}
export interface TelegramState { phase: string; error: string; connection: string; ready: boolean; submitting?: boolean; codeDelivery?: string; nextDelivery?: string; resendSeconds?: number; canResend?: boolean; termsText?: string; minAge?: number; }
export interface TelegramHistoryState { loading: boolean; hasMore: boolean; loaded: boolean; error: string; }
export interface TelegramParameters { apiId: number; apiHash: string; databaseDirectory: string; filesDirectory: string; encryptionKey: string; }
export interface TdTransport { createClient(): number; send(clientId: number, request: string): void; receive(): string; }
