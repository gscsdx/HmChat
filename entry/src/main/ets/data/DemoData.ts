import { ChatSummary, ChatMessage, Contact } from '../model/ChatModels';

// Fixtures are fictional, bundled offline, and never represent an authenticated account.
export function createDemoChats(): ChatSummary[] {
  return [
    { id: 'saved', title: '收藏夹', subtitle: '把灵感、链接和重要的事，留在这里。', avatar: '★', color: '#4098E6', kind: 'saved', time: '09:41', unread: 0, pinned: true, muted: false, online: false },
    { id: 'design', title: '设计漫游指南', subtitle: '林间：让每一次对话，都有一点新意。', avatar: '设', color: '#9A82CE', kind: 'group', time: '10:28', unread: 12, pinned: true, muted: false, online: false },
    { id: 'lin', title: '林间', subtitle: '周末一起去看新的摄影展？', avatar: '林', color: '#D7A36B', kind: 'private', time: '10:24', unread: 2, pinned: false, muted: false, online: true },
    { id: 'harmony', title: 'HarmonyOS 开发者', subtitle: '原生的体验，来自每一个细节。', avatar: 'H', color: '#5DAE99', kind: 'group', time: '09:58', unread: 36, pinned: false, muted: true, online: false },
    { id: 'daily', title: '每日灵感', subtitle: '在日常里，发现值得记录的小事。', avatar: '日', color: '#6B9CC9', kind: 'channel', time: '09:32', unread: 8, pinned: false, muted: true, online: false },
    { id: 'zhou', title: '周屿', subtitle: '照片收到了，光线特别好。', avatar: '周', color: '#6AA6AE', kind: 'private', time: '08:46', unread: 0, pinned: false, muted: false, online: false },
    { id: 'weekend', title: '周末出逃计划', subtitle: '小满：下一站，山野见。', avatar: '山', color: '#829D6B', kind: 'group', time: '昨天', unread: 0, pinned: false, muted: false, online: false },
    { id: 'man', title: '小满', subtitle: '好呀，那就周六见 ☀', avatar: '满', color: '#C68799', kind: 'private', time: '昨天', unread: 0, pinned: false, muted: false, online: true }
  ];
}

export function createDemoContacts(): Contact[] {
  return [
    { id: 'lin', name: '林间', subtitle: '示例联系人 · 在线', avatar: '林', color: '#D7A36B', online: true },
    { id: 'zhou', name: '周屿', subtitle: '示例联系人 · 最近上线', avatar: '周', color: '#6AA6AE', online: false },
    { id: 'man', name: '小满', subtitle: '示例联系人 · 在线', avatar: '满', color: '#C68799', online: true },
    { id: 'chen', name: '陈一', subtitle: '示例联系人 · 最近上线', avatar: '陈', color: '#8A8FCA', online: false },
    { id: 'xu', name: '许知远', subtitle: '示例联系人 · 最近上线', avatar: '许', color: '#A79A7A', online: false }
  ];
}

export function createDemoMessages(): ChatMessage[] {
  return [
    { id: 'seed-1', chatId: 'saved', text: '欢迎来到 HmChat。\n\n这是一个 HarmonyOS 原生 Telegram 客户端项目。当前为离线体验，所有会话均为示例。', time: '09:40', outgoing: false, status: 'received' },
    { id: 'seed-2', chatId: 'saved', text: '在这里记录一段文字，退出后也会保留。', time: '09:41', outgoing: false, status: 'received' },
    { id: 'seed-3', chatId: 'lin', text: '最近发现一家很棒的独立书店，窗边的位置刚好能晒到太阳。', time: '10:20', outgoing: false, status: 'received' },
    { id: 'seed-4', chatId: 'lin', text: '听起来很适合一个慢一点的周末。', time: '10:21', outgoing: true, status: 'local' },
    { id: 'seed-5', chatId: 'lin', text: '对了，附近还有一个摄影展。', time: '10:23', outgoing: false, status: 'received' },
    { id: 'seed-6', chatId: 'lin', text: '周末一起去看新的摄影展？', time: '10:24', outgoing: false, status: 'received' },
    { id: 'seed-7', chatId: 'design', text: '欢迎来到设计漫游指南。\n一起分享界面、字体和生活中的好设计。', time: '09:00', outgoing: false, status: 'received' },
    { id: 'seed-8', chatId: 'design', text: '林间：让每一次对话，都有一点新意。', time: '10:28', outgoing: false, status: 'received' },
    { id: 'seed-9', chatId: 'harmony', text: '原生的体验，来自每一个细节。', time: '09:58', outgoing: false, status: 'received' },
    { id: 'seed-10', chatId: 'daily', text: '在日常里，发现值得记录的小事。\n\n今天的灵感：留白，是给重要的事情一点呼吸的空间。', time: '09:32', outgoing: false, status: 'received' },
    { id: 'seed-11', chatId: 'zhou', text: '照片收到了，光线特别好。', time: '08:46', outgoing: false, status: 'received' },
    { id: 'seed-12', chatId: 'weekend', text: '小满：下一站，山野见。', time: '昨天', outgoing: false, status: 'received' },
    { id: 'seed-13', chatId: 'man', text: '好呀，那就周六见 ☀', time: '昨天', outgoing: false, status: 'received' }
  ];
}
