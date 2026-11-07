import test from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
const require = createRequire(import.meta.url);
const { ChatRepository } = require('../artifacts/tests/js/data/ChatRepository.js');
const { TelegramClient } = require('../artifacts/tests/js/telegram/TelegramClient.js');

class Transport {
  requests = []; queue = []; sendError = false;
  createClient() { return 9; }
  send(id, raw) { if (this.sendError) throw new Error('transport unavailable'); assert.equal(id, 9); this.requests.push(JSON.parse(raw)); }
  receive() { return this.queue.shift() || ''; }
  push(event) { this.queue.push(JSON.stringify({ '@client_id': 9, ...event })); }
  all(type) { return this.requests.filter(item => item['@type'] === type); }
  last(type) { return this.all(type).at(-1); }
}
const params = { apiId: 123456, apiHash: '0'.repeat(32), databaseDirectory: '/fixture/db', filesDirectory: '/fixture/files', encryptionKey: 'Zml4dHVyZQ==' };
function setup() {
  const transport = new Transport(); const repository = new ChatRepository();
  const client = new TelegramClient(transport, repository); client.setMediaNetwork('wifi'); client.start(params);
  transport.push({ '@type': 'updateAuthorizationState', authorization_state: { '@type': 'authorizationStateReady' } }); client.drain();
  return { transport, repository, client };
}
function chat(id, fields = {}) {
  return { '@type': 'chat', id, title: `Fixture ${id}`, type: { '@type': 'chatTypePrivate', user_id: id },
    positions: [{ list: { '@type': 'chatListMain' }, order: '100', is_pinned: false }], unread_count: 0,
    notification_settings: { mute_for: 0 }, ...fields };
}
function load(f, value) { f.transport.push({ '@type': 'updateNewChat', chat: value }); f.client.drain(); }
function message(id, chatId, fields = {}) {
  return { '@type': 'message', id, chat_id: chatId, date: 1700000000, is_outgoing: false,
    content: { '@type': 'messageText', text: { '@type': 'formattedText', text: `Fixture ${id}` } }, ...fields };
}
function reply(f, request, messages) {
  f.transport.push({ '@type': 'messages', '@extra': request['@extra'], messages }); f.client.drain();
}
function ok(f, request) { f.transport.push({ '@type': 'ok', '@extra': request['@extra'] }); f.client.drain(); }
function draft(text) {
  return { '@type': 'draftMessage', date: 1700000000, content: { '@type': 'draftMessageContentText', text: { '@type': 'formattedText', text } } };
}
function file(id, fields = {}) {
  return { '@type': 'file', id, size: 10000, expected_size: 10000,
    local: { path: '', can_be_downloaded: true, is_downloading_active: false, is_downloading_completed: false }, ...fields };
}
function completed(id, path) { return file(id, { local: { path, can_be_downloaded: true, is_downloading_active: false, is_downloading_completed: true } }); }
function photoMessage(id, chatId, sizes, fields = {}) {
  return message(id, chatId, { content: { '@type': 'messagePhoto', photo: { sizes }, caption: { '@type': 'formattedText', text: 'Photo caption' }, ...fields } });
}
function size(id, width = 100, bytes = 10000) { return { type: 'm', width, height: width, photo: file(id, { size: bytes, expected_size: bytes }) }; }

test('main chat pagination is serial, retries failures and stops only after its own 404', () => {
  const f = setup(); const first = f.transport.last('loadChats');
  f.client.loadMoreChats(); f.client.loadMoreChats();
  assert.equal(f.transport.all('loadChats').length, 1);
  ok(f, first); f.client.loadMoreChats();
  const second = f.transport.last('loadChats');
  f.transport.push({ '@type': 'error', '@extra': second['@extra'], code: 500, message: 'network failure' }); f.client.drain();
  f.client.loadMoreChats(); const third = f.transport.last('loadChats');
  assert.equal(f.transport.all('loadChats').length, 3);
  f.transport.push({ '@type': 'error', '@extra': third['@extra'], code: 404, message: 'Not Found' }); f.client.drain();
  f.client.loadMoreChats(); assert.equal(f.transport.all('loadChats').length, 3);
});

test('history paginates with exact int53 cursors, merges overlap and does not infer end from a short page', () => {
  const f = setup(); load(f, chat(101)); f.client.openChat('101');
  const first = f.transport.last('getChatHistory');
  f.client.loadOlderMessages('101'); assert.equal(f.transport.all('getChatHistory').length, 1);
  const oldest = 4503599627370000;
  reply(f, first, [message(oldest + 100, 101), message(oldest, 101)]);
  f.client.loadOlderMessages('101'); const second = f.transport.last('getChatHistory');
  assert.equal(second.from_message_id, oldest);
  f.transport.push({ '@type': 'updateNewMessage', message: message(oldest + 200, 101) }); f.client.drain();
  reply(f, second, [message(oldest, 101), message(oldest - 100, 101)]);
  assert.deepEqual(f.repository.getMessages('101').map(item => item.id), [oldest - 100, oldest, oldest + 100, oldest + 200].map(String));
  f.client.loadOlderMessages('101'); const third = f.transport.last('getChatHistory');
  assert.equal(third.from_message_id, oldest - 100);
  reply(f, third, []); f.client.loadOlderMessages('101');
  assert.equal(f.transport.all('getChatHistory').length, 3);
});

test('interleaved histories keep their own cursor and reject messages for a different chat', () => {
  const f = setup(); load(f, chat(101)); load(f, chat(202));
  f.client.openChat('101'); const first = f.transport.last('getChatHistory');
  f.client.openChat('202'); const second = f.transport.last('getChatHistory');
  reply(f, second, [message(90, 202), message(1, 101)]);
  reply(f, first, [message(40, 101)]);
  assert.deepEqual(f.repository.getMessages('101').map(item => item.id), ['40']);
  assert.deepEqual(f.repository.getMessages('202').map(item => item.id), ['90']);
  f.client.loadOlderMessages('101'); assert.equal(f.transport.last('getChatHistory').from_message_id, 40);
  f.client.loadOlderMessages('202'); assert.equal(f.transport.last('getChatHistory').from_message_id, 90);
});

test('history transport/server errors release the in-flight gate for a retry', () => {
  const f = setup(); load(f, chat(101)); f.client.openChat('101');
  const first = f.transport.last('getChatHistory');
  f.transport.push({ '@type': 'error', '@extra': first['@extra'], code: 500, message: 'temporary' }); f.client.drain();
  f.client.loadOlderMessages('101'); assert.equal(f.transport.all('getChatHistory').length, 2);
});

test('server drafts initialize the composer and current schema writes are serialized with latest edit winning', () => {
  const f = setup(); load(f, chat(101, { draft_message: draft('server draft') }));
  assert.equal(f.repository.getDraft('101'), 'server draft');
  f.client.setDraft('101', 'first local'); const first = f.transport.last('setChatDraftMessage');
  assert.equal(first.draft_message.content['@type'], 'draftMessageContentText');
  assert.equal(first.draft_message.content.text.text, 'first local');
  assert.equal(first.topic_id, null);
  f.client.setDraft('101', 'newest local');
  assert.equal(f.transport.all('setChatDraftMessage').length, 1);
  f.transport.push({ '@type': 'updateChatDraftMessage', chat_id: 101, draft_message: draft('first local'), positions: chat(101).positions }); f.client.drain();
  assert.equal(f.repository.getDraft('101'), 'newest local');
  ok(f, first); const second = f.transport.last('setChatDraftMessage');
  assert.equal(second.draft_message.content.text.text, 'newest local');
  ok(f, second);
  f.transport.push({ '@type': 'updateChatDraftMessage', chat_id: 101, draft_message: draft('stale server echo') }); f.client.drain();
  assert.equal(f.repository.getDraft('101'), 'newest local');
  f.client.setDraft('101', ''); assert.equal(f.transport.last('setChatDraftMessage').draft_message, null);
  assert.equal(f.repository.getDraft('101'), '');
});

test('a failed draft save retains local text and can be retried without another edit', () => {
  const f = setup(); load(f, chat(101)); f.client.setDraft('101', 'retain this');
  const first = f.transport.last('setChatDraftMessage');
  f.transport.push({ '@type': 'error', '@extra': first['@extra'], code: 500, message: 'temporary' }); f.client.drain();
  assert.equal(f.repository.getDraft('101'), 'retain this');
  f.client.setDraft('101', 'retain this');
  assert.equal(f.transport.all('setChatDraftMessage').length, 2);
});

test('opening and leaving an unchanged rich text draft never replaces its reply, entities or preview metadata', () => {
  const f = setup();
  const remote = { ...draft('formatted server draft'),
    reply_to: { '@type': 'inputMessageReplyToMessage', message_id: 123, quote: null }, effect_id: '555',
    content: { '@type': 'draftMessageContentText',
      text: { '@type': 'formattedText', text: 'formatted server draft', entities: [
        { '@type': 'textEntity', offset: 0, length: 9, type: { '@type': 'textEntityTypeBold' } }
      ] },
      link_preview_options: { '@type': 'linkPreviewOptions', is_disabled: true, url: '', force_small_media: false,
        force_large_media: false, show_above_text: false } } };
  const original = structuredClone(remote);
  load(f, chat(101, { draft_message: remote }));
  f.client.openChat('101');
  f.client.setDraft('101', f.repository.getDraft('101')); f.client.leaveChat();
  f.client.openChat('101');
  f.client.setDraft('101', f.repository.getDraft('101')); f.client.leaveChat();
  assert.equal(f.transport.all('setChatDraftMessage').length, 0, 'unchanged navigation must not write a plain-text replacement');
  assert.deepEqual(remote, original);
  f.transport.push({ '@type': 'updateChatDraftMessage', chat_id: 101, draft_message: draft('later server update') }); f.client.drain();
  assert.equal(f.repository.getDraft('101'), 'later server update', 'no-op navigation must not claim local ownership');
  f.client.setDraft('101', 'actual local edit');
  assert.equal(f.transport.all('setChatDraftMessage').length, 1, 'actual edits still save');
  assert.equal(f.transport.last('setChatDraftMessage').draft_message.content.text.text, 'actual local edit');
});

test('unchanged empty composers do not erase an unsupported remote draft or issue a needless clear', () => {
  const f = setup(); load(f, chat(101, { draft_message: { '@type': 'draftMessage', date: 1700000000,
    content: { '@type': 'draftMessageContentVideoNote', video_note: {} } } }));
  f.client.setDraft('101', '');
  load(f, chat(202)); f.client.setDraft('202', '');
  assert.equal(f.transport.all('setChatDraftMessage').length, 0);
});

test('a failed old draft request flushes only the latest queued edit without retrying a failed current version forever', () => {
  const f = setup(); load(f, chat(101));
  f.client.setDraft('101', 'first edit'); const first = f.transport.last('setChatDraftMessage');
  f.client.setDraft('101', 'intermediate edit'); f.client.setDraft('101', 'latest edit');
  assert.equal(f.transport.all('setChatDraftMessage').length, 1);
  f.transport.push({ '@type': 'error', '@extra': first['@extra'], code: 500, message: 'temporary' }); f.client.drain();
  assert.equal(f.transport.all('setChatDraftMessage').length, 2);
  const latest = f.transport.last('setChatDraftMessage');
  assert.equal(latest.draft_message.content.text.text, 'latest edit');
  f.transport.push({ '@type': 'error', '@extra': latest['@extra'], code: 500, message: 'temporary' }); f.client.drain();
  f.client.drain(); f.client.drain();
  assert.equal(f.transport.all('setChatDraftMessage').length, 2, 'no newer edit means no automatic retry loop');
  assert.equal(f.repository.getDraft('101'), 'latest edit');
  f.client.setDraft('101', 'latest edit');
  assert.equal(f.transport.all('setChatDraftMessage').length, 3, 'an explicit save action may retry the failed latest version');
  ok(f, f.transport.last('setChatDraftMessage'));
  f.client.setDraft('101', 'latest edit');
  assert.equal(f.transport.all('setChatDraftMessage').length, 3, 'a successful version is not needlessly resent');
});

test('a queued draft clear still follows a failed earlier write and cannot be blocked by a late older response', () => {
  const f = setup(); load(f, chat(101, { draft_message: draft('server draft') }));
  f.client.setDraft('101', 'new draft'); const first = f.transport.last('setChatDraftMessage');
  f.client.setDraft('101', '');
  f.transport.push({ '@type': 'error', '@extra': first['@extra'], code: 500, message: 'temporary' }); f.client.drain();
  const clear = f.transport.last('setChatDraftMessage');
  assert.equal(clear.draft_message, null);
  assert.equal(f.transport.all('setChatDraftMessage').length, 2);
  ok(f, first);
  assert.equal(f.transport.all('setChatDraftMessage').length, 2);
  ok(f, clear);
  assert.equal(f.repository.getDraft('101'), '');
});

test('drafts restore when a chat becomes visible after its initial updateNewChat', () => {
  const f = setup(); load(f, chat(101, { positions: [], draft_message: draft('restore after position') }));
  assert.deepEqual(f.repository.getChats(), []);
  f.transport.push({ '@type': 'updateChatPosition', chat_id: 101, position: chat(101).positions[0] }); f.client.drain();
  assert.equal(f.repository.getDraft('101'), 'restore after position');
});

test('small chat and contact avatars are downloaded once and updateFile fills their visible paths', () => {
  const f = setup(); const avatar = file(500);
  load(f, chat(101, { photo: { small: avatar } }));
  f.transport.push({ '@type': 'updateUser', user: { '@type': 'user', id: 101, first_name: 'Fixture', last_name: '', is_contact: true,
    status: { '@type': 'userStatusOnline' }, profile_photo: { small: avatar } } }); f.client.drain();
  const downloads = f.transport.all('downloadFile');
  assert.equal(downloads.length, 1); assert.equal(downloads[0].file_id, 500); assert.equal(downloads[0].limit, 512 * 1024);
  f.transport.push({ '@type': 'updateFile', file: completed(500, '/fixture/avatar.jpg') }); f.client.drain();
  assert.equal(f.repository.getChats()[0].avatarPath, '/fixture/avatar.jpg');
  assert.equal(f.repository.getContacts()[0].avatarPath, '/fixture/avatar.jpg');
  f.transport.push({ '@type': 'updateChatPhoto', chat_id: 101, photo: null });
  f.transport.push({ '@type': 'updateUser', user: { '@type': 'user', id: 101, first_name: 'Fixture', last_name: '', is_contact: true,
    status: { '@type': 'userStatusOnline' }, profile_photo: null } }); f.client.drain();
  assert.equal(f.repository.getChats()[0].avatarPath, undefined);
});

test('oversized avatar files are not downloaded', () => {
  const f = setup(); load(f, chat(101, { photo: { small: file(501, { size: 600000, expected_size: 600000 }) } }));
  assert.equal(f.transport.last('downloadFile'), undefined);
});

test('photos download only in the active chat, choose the largest allowed variant and receive file completion', () => {
  const f = setup(); load(f, chat(101)); load(f, chat(202)); f.client.openChat('101');
  f.transport.push({ '@type': 'updateNewMessage', message: photoMessage(10, 202, [size(600)]) });
  f.transport.push({ '@type': 'updateNewMessage', message: photoMessage(20, 101, [size(601, 100), size(602, 800), size(603, 2000, 21 * 1024 * 1024)]) });
  f.client.drain();
  const downloads = f.transport.all('downloadFile');
  assert.deepEqual(downloads.map(item => item.file_id), [602]);
  assert.equal(downloads[0].limit, 20 * 1024 * 1024);
  f.transport.push({ '@type': 'updateFile', file: completed(602, '/fixture/photo.jpg') }); f.client.drain();
  assert.equal(f.repository.getMessages('101')[0].mediaPath, '/fixture/photo.jpg');
  f.client.openChat('202');
  assert.equal(f.transport.last('downloadFile').file_id, 600);
});

test('secret or spoiler photos never get automatically revealed or downloaded', () => {
  const f = setup(); load(f, chat(101)); f.client.openChat('101');
  f.transport.push({ '@type': 'updateNewMessage', message: photoMessage(10, 101, [size(700)], { is_secret: true }) });
  f.transport.push({ '@type': 'updateNewMessage', message: photoMessage(20, 101, [size(701)], { has_spoiler: true }) }); f.client.drain();
  assert.equal(f.transport.last('downloadFile'), undefined);
  assert.ok(f.repository.getMessages('101').every(item => !item.mediaPath && !item.mediaFileId));
});

test('photo sends use inputPhoto nesting and immediate failure preserves the selected file and caption', () => {
  const f = setup(); load(f, chat(101));
  assert.equal(f.client.sendPhoto('101', 'file://unresolved', 'caption'), false);
  assert.equal(f.client.sendPhoto('101', '/fixture/photo.jpg', 'caption'), true);
  const send = f.transport.last('sendMessage');
  assert.equal(send.input_message_content['@type'], 'inputMessagePhoto');
  assert.equal(send.input_message_content.photo['@type'], 'inputPhoto');
  assert.deepEqual(send.input_message_content.photo.photo, { '@type': 'inputFileLocal', path: '/fixture/photo.jpg' });
  assert.equal(send.input_message_content.caption.text, 'caption');
  f.transport.push({ '@type': 'error', '@extra': send['@extra'], code: 400, message: 'CHAT_WRITE_FORBIDDEN' }); f.client.drain();
  const failed = f.repository.getMessages('101')[0];
  assert.equal(failed.status, 'failed'); assert.equal(failed.mediaKind, 'photo');
  assert.equal(failed.mediaPath, '/fixture/photo.jpg'); assert.equal(failed.text, 'caption');
  assert.equal(f.repository.getDraft('101'), '', 'photo caption is not the independent text draft');
});

test('content updates use the real new_content schema and remove stale media', () => {
  const f = setup(); load(f, chat(101)); f.client.openChat('101');
  const original = photoMessage(25, 101, [{ type: 'm', width: 200, height: 200, photo: completed(301, '/fixture/old.jpg') }]);
  f.transport.push({ '@type': 'updateNewMessage', message: original }); f.client.drain();
  const previous = f.repository.getMessages('101')[0];
  assert.equal(previous.mediaPath, '/fixture/old.jpg');
  f.transport.push({ '@type': 'updateMessageContent', chat_id: 101, message_id: 25,
    new_content: { '@type': 'messageText', text: { '@type': 'formattedText', text: 'new content' } } });
  f.client.drain();
  const updated = f.repository.getMessages('101')[0];
  assert.equal(updated.text, 'new content');
  assert.equal(updated.mediaPath, undefined);
  assert.equal(updated.mediaFileId, undefined);
  assert.equal(updated.mediaKind, undefined);
  assert.equal(updated.time, previous.time);
  assert.equal(updated.status, previous.status);
});

test('sending or failing a photo preserves an unrelated text draft', () => {
  const f = setup(); load(f, chat(101));
  f.client.setDraft('101', 'separate body text');
  const before = f.transport.all('setChatDraftMessage').length;
  assert.equal(f.client.sendPhoto('101', '/fixture/pic.jpg', 'image caption'), true);
  const send = f.transport.last('sendMessage');
  assert.equal(f.repository.getDraft('101'), 'separate body text');
  assert.equal(f.transport.all('setChatDraftMessage').length, before);
  f.transport.push({ '@type': 'error', '@extra': send['@extra'], code: 400, message: 'CHAT_WRITE_FORBIDDEN' }); f.client.drain();
  assert.equal(f.repository.getDraft('101'), 'separate body text');
  assert.ok(f.repository.getMessages('101').some(item => item.mediaPath === '/fixture/pic.jpg' && item.text === 'image caption'));
});

test('invalidated avatar files clear stale paths and can be downloaded again', () => {
  const f = setup();
  load(f, chat(101, { photo: { small: completed(301, '/fixture/old.jpg') } }));
  assert.equal(f.repository.getChats()[0].avatarPath, '/fixture/old.jpg');
  f.transport.push({ '@type': 'updateFile', file: file(301) }); f.client.drain();
  assert.equal(f.repository.getChats()[0].avatarPath, '');
  f.transport.push({ '@type': 'updateChatTitle', chat_id: 101, title: 'refresh' }); f.client.drain();
  assert.notEqual(f.repository.getChats()[0].avatarPath, '/fixture/old.jpg');
  assert.equal(f.transport.last('downloadFile').file_id, 301);
});

test('saved messages uses the authenticated getMe identity and waits for chat creation', () => {
  const f = setup();
  const me = f.transport.last('getMe');
  f.transport.push({ '@type': 'user', '@extra': me['@extra'], id: 909, first_name: 'Fixture', last_name: 'Self', status: { '@type': 'userStatusOnline' } }); f.client.drain();
  assert.equal(f.client.getCurrentUser().name, 'Fixture Self');
  assert.equal(f.client.openSavedMessages(), '909');
  assert.equal(f.repository.getChats().find(item => item.id === '909').kind, 'saved');
  const create = f.transport.last('createPrivateChat');
  assert.equal(create.user_id, 909);
  f.client.openChat('909');
  f.transport.push({ ...chat(909), '@extra': create['@extra'] }); f.client.drain();
  assert.equal(f.transport.last('openChat').chat_id, 909);
  assert.equal(f.repository.getChats().find(item => item.id === '909').title, '收藏夹');
});

test('visible read reports filter invalid, outgoing, unknown and duplicate ids without reading unseen arrivals', () => {
  const f = setup(); load(f, chat(101)); load(f, chat(202)); f.client.openChat('101');
  reply(f, f.transport.last('getChatHistory'), [message(10, 101), message(20, 101), message(30, 101, { is_outgoing: true })]);
  f.transport.push({ '@type': 'updateNewMessage', message: message(40, 101) }); f.client.drain();
  assert.equal(f.transport.last('viewMessages'), undefined);
  f.client.viewVisibleMessages('202', ['10']);
  assert.equal(f.transport.last('viewMessages'), undefined);
  f.client.viewVisibleMessages('101', ['20', '20', '30', '999', '-1', 'NaN', '9007199254740992', 'failed:sendMessage:1']);
  const request = f.transport.last('viewMessages');
  assert.deepEqual(request.message_ids, [20]);
  assert.equal(request.force_read, false);
  f.client.viewVisibleMessages('101', ['20']);
  assert.equal(f.transport.all('viewMessages').length, 1);
  ok(f, request);
  f.client.viewVisibleMessages('101', ['10', '20']);
  assert.deepEqual(f.transport.last('viewMessages').message_ids, [10]);
  assert.equal(f.transport.all('viewMessages').some(item => item.message_ids.includes(40)), false);
});

test('read failures are retryable and visibility deduplication resets on leave and background', () => {
  const f = setup(); load(f, chat(101)); f.client.openChat('101');
  reply(f, f.transport.last('getChatHistory'), [message(10, 101)]);
  f.transport.sendError = true; f.client.viewVisibleMessages('101', ['10']); f.transport.sendError = false;
  f.client.viewVisibleMessages('101', ['10']);
  const first = f.transport.last('viewMessages');
  f.transport.push({ '@type': 'error', '@extra': first['@extra'], code: 500, message: 'temporary' }); f.client.drain();
  f.client.viewVisibleMessages('101', ['10']);
  assert.equal(f.transport.all('viewMessages').length, 2);
  f.client.setForeground(false); f.client.viewVisibleMessages('101', ['10']);
  assert.equal(f.transport.all('viewMessages').length, 2);
  f.client.setForeground(true);
  assert.equal(f.transport.all('viewMessages').length, 2, 'foreground alone must not mark cached messages read');
  f.client.viewVisibleMessages('101', ['10']);
  assert.equal(f.transport.all('viewMessages').length, 3);
  f.client.leaveChat(); f.client.viewVisibleMessages('101', ['10']);
  assert.equal(f.transport.all('viewMessages').length, 3);
  f.client.openChat('101'); f.client.viewVisibleMessages('101', ['10']);
  assert.equal(f.transport.all('viewMessages').length, 4);
});

test('history state distinguishes initial loading, a genuinely empty response and pagination completion', () => {
  const f = setup(); load(f, chat(101));
  assert.deepEqual(f.client.getHistoryState('101'), { loading: false, hasMore: true, loaded: false, error: '' });
  const snapshots = []; f.client.subscribe(() => snapshots.push(f.client.getHistoryState('101')));
  f.client.openChat('101');
  assert.deepEqual(f.client.getHistoryState('101'), { loading: true, hasMore: true, loaded: false, error: '' });
  assert.equal(snapshots.at(-1).loading, true);
  const request = f.transport.last('getChatHistory'); reply(f, request, []);
  assert.deepEqual(f.client.getHistoryState('101'), { loading: false, hasMore: false, loaded: true, error: '' });
  f.client.loadOlderMessages('101');
  assert.equal(f.transport.all('getChatHistory').length, 1);
  const state = f.client.getHistoryState('101'); state.loaded = false;
  assert.equal(f.client.getHistoryState('101').loaded, true, 'state returned to UI is a copy');
});

test('initial and older-page history failures expose errors and retry via the same loadOlderMessages API', () => {
  const f = setup(); load(f, chat(101)); load(f, chat(202)); f.client.openChat('101');
  const first = f.transport.last('getChatHistory');
  f.transport.push({ '@type': 'error', '@extra': first['@extra'], code: 500, message: 'temporary' }); f.client.drain();
  assert.equal(f.client.getHistoryState('101').loading, false);
  assert.equal(f.client.getHistoryState('101').loaded, false);
  assert.ok(f.client.getHistoryState('101').error);
  assert.equal(f.client.getHistoryState('202').error, '');
  f.client.loadOlderMessages('101');
  assert.equal(f.client.getHistoryState('101').error, '');
  assert.equal(f.client.getHistoryState('101').loading, true);
  reply(f, f.transport.last('getChatHistory'), [message(50, 101)]);
  assert.equal(f.client.getHistoryState('101').loaded, true);
  assert.equal(f.client.getHistoryState('101').hasMore, true);
  f.transport.sendError = true; f.client.loadOlderMessages('101'); f.transport.sendError = false;
  assert.equal(f.client.getHistoryState('101').loading, false);
  assert.ok(f.client.getHistoryState('101').error);
  f.client.loadOlderMessages('101');
  assert.equal(f.transport.last('getChatHistory').from_message_id, 50);
  reply(f, f.transport.last('getChatHistory'), []);
  assert.deepEqual(f.client.getHistoryState('101'), { loading: false, hasMore: false, loaded: true, error: '' });
});

test('private chat preparation appears as loading and a failed creation can retry from history UI', () => {
  const f = setup(); f.client.openChat('101');
  assert.equal(f.client.getHistoryState('101').loading, true);
  const create = f.transport.last('createPrivateChat');
  f.transport.push({ '@type': 'error', '@extra': create['@extra'], code: 500, message: 'temporary' }); f.client.drain();
  assert.equal(f.client.getHistoryState('101').loading, false);
  assert.ok(f.client.getHistoryState('101').error);
  f.client.loadOlderMessages('101');
  const retry = f.transport.last('createPrivateChat');
  assert.notEqual(retry['@extra'], create['@extra']);
  assert.equal(f.client.getHistoryState('101').error, '');
  f.transport.push({ ...chat(101), '@extra': retry['@extra'] }); f.client.drain();
  assert.equal(f.client.getHistoryState('101').loading, true);
  reply(f, f.transport.last('getChatHistory'), []);
  assert.equal(f.client.getHistoryState('101').loaded, true);
});

test('group messages retain their sender and date across late profile and content updates', () => {
  const f = setup(); load(f, chat(-101, { type: { '@type': 'chatTypeBasicGroup' } }));
  const incoming = message(700, -101, { sender_id: { '@type': 'messageSenderUser', user_id: 99 } });
  f.transport.push({ '@type': 'updateNewMessage', message: incoming }); f.client.drain();
  let mapped = f.repository.getMessages('-101')[0];
  assert.equal(mapped.senderId, 'user:99'); assert.equal(mapped.date, incoming.date);
  assert.match(mapped.time, /^\d{2}:\d{2}$/);
  f.transport.push({ '@type': 'updateUser', user: { '@type': 'user', id: 99, first_name: 'Fixture', last_name: 'Sender', status: { '@type': 'userStatusOffline' } } }); f.client.drain();
  assert.equal(mapped.senderName, 'Fixture Sender');
  f.transport.push({ '@type': 'updateMessageContent', chat_id: -101, message_id: 700,
    new_content: { '@type': 'messageText', text: { '@type': 'formattedText', text: 'Edited fixture' } } }); f.client.drain();
  mapped = f.repository.getMessages('-101')[0];
  assert.equal(mapped.senderName, 'Fixture Sender'); assert.equal(mapped.senderId, 'user:99');
  assert.equal(mapped.date, incoming.date); assert.equal(mapped.text, 'Edited fixture');
});

test('anonymous channel senders resolve independently from user IDs and receive title changes', () => {
  const f = setup(); load(f, chat(-101, { type: { '@type': 'chatTypeSupergroup', is_channel: false } }));
  load(f, chat(-202, { title: 'Fixture Channel', type: { '@type': 'chatTypeSupergroup', is_channel: true } }));
  f.transport.push({ '@type': 'updateNewMessage', message: message(800, -101, { sender_id: { '@type': 'messageSenderChat', chat_id: -202 } }) }); f.client.drain();
  assert.equal(f.repository.getMessages('-101')[0].senderName, 'Fixture Channel');
  f.transport.push({ '@type': 'updateChatTitle', chat_id: -202, title: 'Renamed Fixture' }); f.client.drain();
  assert.equal(f.repository.getMessages('-101')[0].senderName, 'Renamed Fixture');
});

test('chat kinds keep supergroups out of channels so each list filter sees its own entries', () => {
  const f = setup();
  load(f, chat(101));
  load(f, chat(-101, { title: 'Fixture Supergroup', type: { '@type': 'chatTypeSupergroup', is_channel: true, is_megagroup: true } }));
  load(f, chat(-202, { title: 'Fixture Channel', type: { '@type': 'chatTypeSupergroup', is_channel: true, is_megagroup: false } }));
  const kinds = new Map(f.repository.getChats().map(item => [item.id, item.kind]));
  assert.equal(kinds.get('101'), 'private');
  assert.equal(kinds.get('-101'), 'group');
  assert.equal(kinds.get('-202'), 'channel');
  const idsOf = kind => f.repository.getChats().filter(item => item.kind === kind).map(item => item.id);
  assert.deepEqual(idsOf('private'), ['101']);
  assert.deepEqual(idsOf('group'), ['-101']);
  assert.deepEqual(idsOf('channel'), ['-202']);
  // 「全部」筛选不按 kind 过滤，仍包含所有已加载的主列表会话。
  assert.equal(f.repository.getChats().length, 3);
});

test('initialization key mismatch becomes actionable without exposing the TDLib error payload', () => {
  const transport = new Transport(); const repository = new ChatRepository();
  const client = new TelegramClient(transport, repository); client.setMediaNetwork('wifi'); client.start(params);
  transport.push({ '@type': 'updateAuthorizationState', authorization_state: { '@type': 'authorizationStateWaitTdlibParameters' } }); client.drain();
  transport.push({ '@type': 'error', '@extra': transport.last('setTdlibParameters')['@extra'], code: 401,
    message: 'Wrong database encryption key' }); client.drain();
  assert.equal(client.state().phase, 'storageRecovery'); assert.equal(client.state().ready, false);
  assert.equal(client.state().error, '本机登录数据无法解锁。原有缓存会保留，请重新登录。');
});

test('initialization errors leave the indefinite starting spinner and remain private', () => {
  const transport = new Transport(); const client = new TelegramClient(transport, new ChatRepository()); client.start(params);
  transport.push({ '@type': 'updateAuthorizationState', authorization_state: { '@type': 'authorizationStateWaitTdlibParameters' } }); client.drain();
  transport.push({ '@type': 'error', '@extra': transport.last('setTdlibParameters')['@extra'], code: 500,
    message: 'private internal filesystem details' }); client.drain();
  assert.equal(client.state().phase, 'error'); assert.equal(client.state().error.includes('private'), false);
});

test('video previews download only thumbnails; full video is user driven with progress, cancellation and retry', () => {
  const f = setup(); load(f, chat(101)); f.client.openChat('101');
  const video = message(300, 101, { media_album_id: '9223372036854775806', content: {
    '@type': 'messageVideo', caption: { text: 'Fixture clip' }, video: {
      duration: 8, width: 640, height: 360, video: file(900), thumbnail: { width: 160, height: 90, file: file(901) }
    }
  } });
  f.transport.push({ '@type': 'updateNewMessage', message: video }); f.client.drain();
  assert.equal(f.transport.last('downloadFile').file_id, 901);
  assert.equal(f.transport.all('downloadFile').some(x => x.file_id === 900), false);
  let item = f.repository.getMessages('101').find(x => x.id === '300');
  assert.equal(item.mediaKind, 'video'); assert.equal(item.mediaAlbumId, '9223372036854775806');
  assert.equal(item.mediaDuration, 8); assert.equal(item.mediaPath, undefined);
  f.client.downloadMedia('101', '300'); const download = f.transport.last('downloadFile');
  assert.equal(download.file_id, 900);
  f.transport.push({ '@type': 'updateFile', file: file(900, { local: {
    path: '', can_be_downloaded: true, is_downloading_active: true, is_downloading_completed: false, downloaded_size: 5000
  } }) }); f.client.drain();
  item = f.repository.getMessages('101').find(x => x.id === '300');
  assert.equal(item.mediaProgress, 50); assert.equal(item.mediaDownloading, true);
  f.client.cancelMedia('101', '300'); assert.equal(f.transport.last('cancelDownloadFile').file_id, 900);
  f.transport.push({ '@type': 'error', '@extra': download['@extra'], code: 500, message: 'network unavailable' }); f.client.drain();
  assert.match(f.repository.getMessages('101').find(x => x.id === '300').mediaError, /下载失败/);
  f.transport.push({ '@type': 'updateFile', file: file(900) }); f.client.drain();
  f.client.downloadMedia('101', '300');
  assert.equal(f.transport.all('downloadFile').filter(x => x.file_id === 900).length, 2);
  f.transport.push({ '@type': 'updateFile', file: completed(900, '/fixture/clip.mp4') }); f.client.drain();
  item = f.repository.getMessages('101').find(x => x.id === '300');
  assert.equal(item.mediaPath, '/fixture/clip.mp4'); assert.equal(item.mediaProgress, 100);
});

test('mixed albums use the fixed TDLib input schema, preserve attachment order and retain all failed media', () => {
  const f = setup(); load(f, chat(101));
  const attachments = [
    { path: '/fixture/one.jpg', kind: 'photo', width: 640, height: 480, duration: 0, size: 4000 },
    { path: '/fixture/two.mp4', kind: 'video', width: 640, height: 360, duration: 8, size: 10000 }
  ];
  assert.equal(f.client.sendMedia('101', attachments, 'Fixture album'), true);
  const request = f.transport.last('sendMessageAlbum');
  assert.equal(request.chat_id, 101); assert.equal(request.input_message_contents.length, 2);
  assert.equal(request.input_message_contents[0].photo.photo.path, '/fixture/one.jpg');
  assert.equal(request.input_message_contents[1].video.video.path, '/fixture/two.mp4');
  assert.equal(request.input_message_contents[1].video.duration, 8);
  assert.equal(request.input_message_contents[1].video.supports_streaming, false);
  assert.equal(request.input_message_contents[0].caption.text, 'Fixture album');
  assert.equal(request.input_message_contents[1].caption.text, '');
  f.transport.push({ '@type': 'error', '@extra': request['@extra'], code: 400, message: 'MEDIA_INVALID' }); f.client.drain();
  const failed = f.repository.getMessages('101').filter(x => x.status === 'failed');
  assert.equal(failed.length, 2); assert.equal(failed[0].mediaAlbumId, failed[1].mediaAlbumId);
  assert.deepEqual(failed.map(x => x.mediaPath), attachments.map(x => x.path));
  assert.equal(failed[1].mediaSize, 10000); assert.equal(failed[1].mediaKind, 'video');
});

test('media rejects invalid metadata, limits and attachment counts without sending a request', () => {
  const f = setup(); load(f, chat(101));
  const photo = { path: '/fixture/one.jpg', kind: 'photo', width: 0, height: 0, duration: 0, size: 4000 };
  for (const items of [[], Array(11).fill(photo), [{ ...photo, size: NaN }], [{ ...photo, width: Infinity }],
    [{ ...photo, size: 10000001 }], [{ ...photo, path: 'relative.jpg' }], [{ ...photo, kind: 'video', size: 2000000001 }]]) {
    assert.equal(f.client.sendMedia('101', items), false);
  }
  assert.equal(f.transport.all('sendMessageAlbum').length, 0); assert.equal(f.transport.all('sendMessage').length, 0);
});

test('secret and spoiler videos are never revealed or downloaded', () => {
  const f = setup(); load(f, chat(101)); f.client.openChat('101');
  for (const [id, flags] of [[320, { has_spoiler: true }], [321, { is_secret: true }]]) {
    f.transport.push({ '@type': 'updateNewMessage', message: message(id, 101, { content: {
      '@type': 'messageVideo', ...flags, video: { duration: 1, width: 100, height: 100, video: file(id + 1000) }
    } }) });
  }
  f.client.drain();
  assert.equal(f.transport.all('downloadFile').length, 0);
  assert.equal(f.repository.getMessages('101').every(x => !x.mediaKind && !x.mediaPath), true);
});

test('album responses retain missing attachments and never fabricate their cloud confirmation', () => {
  const f = setup(); load(f, chat(101));
  const photo = { path: '/fixture/one.jpg', kind: 'photo', width: 640, height: 480, duration: 0, size: 4000 };
  assert.equal(f.client.sendMedia('101', [photo, { ...photo, path: '/fixture/two.jpg' }], 'Fixture album'), true);
  const request = f.transport.last('sendMessageAlbum'); photo.path = '/fixture/mutated.jpg';
  reply(f, request, [photoMessage(500, 101, [size(950)], {}), null]);
  const items = f.repository.getMessages('101');
  assert.equal(items.find(x => x.id === '500').status, 'received');
  assert.equal(items.filter(x => x.status === 'failed').length, 1);
  assert.equal(items.find(x => x.status === 'failed').mediaPath, '/fixture/two.jpg');
});

test('rich text, link previews, forwarding and group sender avatars survive protocol mapping', () => {
  const f = setup(); load(f, chat(101)); f.client.openChat('101');
  f.transport.push({ '@type': 'updateUser', user: { id: 5, first_name: 'Fixture sender', last_name: '', status: { '@type': 'userStatusOffline' },
    profile_photo: { small: file(990) } } });
  const rich = message(600, 101, { sender_id: { '@type': 'messageSenderUser', user_id: 5 },
    forward_info: { origin: { '@type': 'messageOriginHiddenUser', sender_name: 'Fixture source' } }, content: {
      '@type': 'messageText', text: { '@type': 'formattedText', text: 'Hello link', entities: [
        { offset: 0, length: 5, type: { '@type': 'textEntityTypeBold' } },
        { offset: 6, length: 4, type: { '@type': 'textEntityTypeTextUrl', url: 'https://example.org' } }
      ] }, link_preview: { url: 'https://example.org', title: 'Fixture title', site_name: 'Fixture', description: { text: 'Fixture preview' } }
    } });
  f.transport.push({ '@type': 'updateNewMessage', message: rich }); f.client.drain();
  const item = f.repository.getMessages('101').find(x=>x.id==='600');
  assert.equal(item.entities[0].type,'textEntityTypeBold'); assert.equal(item.entities[1].url,'https://example.org');
  assert.equal(item.forwardName,'Fixture source'); assert.equal(item.linkPreview.description,'Fixture preview');
  assert.equal(item.senderAvatarFileId,990);
  f.transport.push({ '@type': 'updateFile', file: completed(990,'/fixture/avatar.jpg') }); f.client.drain();
  assert.equal(item.senderAvatarPath,'/fixture/avatar.jpg');
});
test('service messages and server outbox read updates keep distinct presentation semantics', () => {
  const f=setup(); load(f,chat(101));
  f.transport.push({ '@type':'updateNewMessage', message:message(610,101,{sender_id:{'@type':'messageSenderUser',user_id:5},content:{'@type':'messageChatJoinByLink'}}) });
  f.transport.push({ '@type':'updateNewMessage', message:message(611,101,{is_outgoing:true}) }); f.client.drain();
  assert.equal(f.repository.getMessages('101').find(x=>x.id==='610').service,true);
  assert.equal(f.repository.getMessages('101').find(x=>x.id==='611').read,false);
  f.transport.push({ '@type':'updateChatReadOutbox',chat_id:101,last_read_outbox_message_id:611 }); f.client.drain();
  assert.equal(f.repository.getMessages('101').find(x=>x.id==='611').read,true);
});

test('reply previews fetch missing originals without inserting history or revealing spoilers', () => {
  const f=setup();load(f,chat(101));f.client.openChat('101');
  f.transport.push({'@type':'updateNewMessage',message:message(620,101,{reply_to:{'@type':'messageReplyToMessage',chat_id:101,message_id:10}})});f.client.drain();
  const request=f.transport.last('getRepliedMessage');assert.equal(request.message_id,620);
  f.transport.push({'@type':'message','@extra':request['@extra'],...message(10,101,{sender_id:{'@type':'messageSenderUser',user_id:5},content:{'@type':'messageText',text:{text:'secret original',entities:[{offset:0,length:6,type:{'@type':'textEntityTypeSpoiler'}}]}}})});f.client.drain();
  const items=f.repository.getMessages('101');assert.equal(items.length,1);
  assert.equal(items[0].replyPreview,'•••••• original');assert.equal(items[0].replyToMessageId,'10');
  assert.equal(f.transport.all('getRepliedMessage').length,1);
});
test('static stickers use bounded previews and animated emoji retain readable content', () => {
  const f=setup();load(f,chat(101));f.client.openChat('101');
  f.transport.push({'@type':'updateNewMessage',message:message(630,101,{content:{'@type':'messageSticker',sticker:{width:512,height:512,emoji:'🙂',format:{'@type':'stickerFormatWebp'},sticker:file(995)}}})});
  f.transport.push({'@type':'updateNewMessage',message:message(631,101,{content:{'@type':'messageAnimatedEmoji',emoji:'🙂'}})});f.client.drain();
  assert.equal(f.transport.last('downloadFile').file_id,995);
  f.transport.push({'@type':'updateFile',file:completed(995,'/fixture/sticker.webp')});f.client.drain();
  assert.equal(f.repository.getMessages('101').find(x=>x.id==='630').stickerPath,'/fixture/sticker.webp');
  assert.equal(f.repository.getMessages('101').find(x=>x.id==='631').text,'🙂');
  assert.equal(f.repository.getMessages('101').find(x=>x.id==='631').largeEmoji,true);
});

test('rich-message blocks map text and embedded media, and embedded downloads validate the owning message',()=>{
 const f=setup();load(f,chat(101));f.client.openChat('101');
 f.transport.push({'@type':'updateNewMessage',message:message(640,101,{content:{'@type':'messageRichMessage',message:{is_full:true,is_rtl:false,blocks:[
  {'@type':'pageBlockParagraph',text:{'@type':'richTextSpoiler',text:{'@type':'richTextPlain',text:'secret'}}},
  {'@type':'pageBlockVideo',video:{duration:8,width:640,height:360,video:file(998)},caption:{text:{'@type':'richTextPlain',text:'Fixture video'}}}
 ]}}})});f.client.drain();
 const item=f.repository.getMessages('101').find(x=>x.id==='640');
 assert.equal(item.richBlocks.length,2);assert.equal(item.richBlocks[1].media.sourceMessageId,'640');
 assert.equal(item.entities[0].type,'textEntityTypeSpoiler');
 const before=f.transport.all('downloadFile').length;
 f.client.downloadRichMedia('101','640',999);assert.equal(f.transport.all('downloadFile').length,before);
 f.client.downloadRichMedia('101','640',998);assert.equal(f.transport.last('downloadFile').file_id,998);
 f.transport.push({'@type':'updateFile',file:completed(998,'/fixture/rich.mp4')});f.client.drain();
 assert.equal(item.richBlocks[1].media.mediaPath,'/fixture/rich.mp4');
});

test('truncated rich messages load their full server version with deduplication and retry',()=>{
 const f=setup();load(f,chat(101));f.client.openChat('101');
 const paragraph=text=>({'@type':'pageBlockParagraph',text:{'@type':'richTextPlain',text}});
 f.transport.push({'@type':'updateNewMessage',message:message(650,101,{content:{'@type':'messageRichMessage',message:{'@type':'richMessage',is_full:false,is_rtl:false,blocks:[paragraph('Preview')]}}})});f.client.drain();
 f.client.loadFullRichMessage('101','650');f.client.loadFullRichMessage('101','650');
 assert.equal(f.transport.all('getFullRichMessage').length,1);const request=f.transport.last('getFullRichMessage');
 f.transport.push({'@type':'error','@extra':request['@extra'],code:500,message:'fixture failure'});f.client.drain();
 assert.equal(f.repository.getMessages('101').find(x=>x.id==='650').richLoading,false);
 f.client.loadFullRichMessage('101','650');const retry=f.transport.last('getFullRichMessage');
 f.transport.push({'@type':'richMessage','@extra':retry['@extra'],is_full:true,is_rtl:false,blocks:[paragraph('Preview'),paragraph('Full content')]});f.client.drain();
 const items=f.repository.getMessages('101');assert.equal(items.length,1);assert.equal(items[0].richTruncated,false);
 assert.equal(items[0].text,'Preview\nFull content');
});

test('full-rich-message timeout releases retry and late responses cannot overwrite it',()=>{
 const f=setup();load(f,chat(101));f.client.openChat('101');
 f.transport.push({'@type':'updateNewMessage',message:message(660,101,{content:{'@type':'messageRichMessage',message:{'@type':'richMessage',is_full:false,is_rtl:false,blocks:[{'@type':'pageBlockParagraph',text:{'@type':'richTextPlain',text:'Preview'}}]}}})});f.client.drain();
 const originalNow=Date.now;let now=originalNow();Date.now=()=>now;
 try {
  f.client.loadFullRichMessage('101','660');const request=f.transport.last('getFullRichMessage');now+=30001;f.client.drain();
  const current=f.repository.getMessages('101').find(x=>x.id==='660');assert.equal(current.richLoading,false);assert.match(current.richError,/超时/);
  f.transport.push({'@type':'richMessage','@extra':request['@extra'],is_full:true,is_rtl:false,blocks:[]});f.client.drain();
  assert.equal(f.repository.getMessages('101').find(x=>x.id==='660').richTruncated,true);
  f.client.loadFullRichMessage('101','660');assert.equal(f.transport.all('getFullRichMessage').length,2);
 } finally {Date.now=originalNow;}
});
