import test from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
const require = createRequire(import.meta.url);
const { ChatRepository } = require('../artifacts/tests/js/data/ChatRepository.js');
const { TelegramClient } = require('../artifacts/tests/js/telegram/TelegramClient.js');

class Transport {
  requests = []; queue = []; failSend = false;
  createClient() { return 17; }
  send(id, raw) { assert.equal(id, 17); if (this.failSend) throw Error('offline'); this.requests.push(JSON.parse(raw)); }
  receive() { return this.queue.shift() || ''; }
  push(event) { this.queue.push(JSON.stringify({ '@client_id': 17, ...event })); }
  all(type) { return this.requests.filter(item => item['@type'] === type); }
  last(type) { return this.all(type).at(-1); }
}
function chat(id) {
  return { '@type': 'chat', id, title: `Fixture ${id}`, type: { '@type': 'chatTypePrivate', user_id: id },
    positions: [{ list: { '@type': 'chatListMain' }, order: '100', is_pinned: false }], unread_count: 0,
    notification_settings: { mute_for: 0 } };
}
function message(id = 50, chatId = 101, fields = {}) {
  return { '@type': 'message', id, chat_id: chatId, date: 1700000000, is_outgoing: true,
    content: { '@type': 'messageText', text: { '@type': 'formattedText', text: 'Fixture original' } }, ...fields };
}
function setup() {
  const transport = new Transport(); const repository = new ChatRepository(); const client = new TelegramClient(transport, repository); client.setMediaNetwork('wifi');
  client.start({ apiId: 12345, apiHash: '0'.repeat(32), databaseDirectory: '/fixture/db', filesDirectory: '/fixture/files', encryptionKey: 'Zml4dHVyZQ==' });
  transport.push({ '@type': 'updateAuthorizationState', authorization_state: { '@type': 'authorizationStateReady' } });
  transport.push({ '@type': 'updateNewChat', chat: chat(101) }); transport.push({ '@type': 'updateNewChat', chat: chat(202) });
  transport.push({ '@type': 'updateNewMessage', message: message() }); client.drain();
  return { transport, repository, client };
}
function deliver(f, event) { f.transport.push(event); f.client.drain(); }
function capabilities(f, fields = {}, id = '50', chatId = '101') {
  f.client.loadMessageProperties(chatId, id);
  const key = f.transport.last('getMessageProperties')['@extra'];
  deliver(f, { '@type': 'messageProperties', '@extra': key, can_be_replied: true, can_be_edited: true,
    can_be_deleted_only_for_self: true, can_be_deleted_for_all_users: true, can_be_forwarded: true,
    can_be_copied: true, can_be_saved: true, ...fields });
}
function result(f, token, fields) { deliver(f, { ...fields, '@extra': token }); }
function pending(id, chatId = 101) { return message(id, chatId, { sending_state: { '@type': 'messageSendingStatePending' } }); }

test('unknown permissions deny all mutation; loading is deduplicated and failure can be retried', () => {
  const f = setup();
  assert.equal(f.client.getMessagePermissions('101', '50').canEdit, false);
  assert.equal(f.client.editMessage('101', '50', 'new'), '');
  assert.equal(f.client.deleteMessage('101', '50', true), '');
  assert.equal(f.client.forwardMessage('101', '50', '202'), '');
  assert.equal(f.client.sendReply('101', 'reply', '50'), '');
  f.client.loadMessageProperties('101', '50'); f.client.loadMessageProperties('101', '50');
  assert.equal(f.transport.all('getMessageProperties').length, 1);
  result(f, f.transport.last('getMessageProperties')['@extra'], { '@type': 'error', code: 500, message: 'private raw server detail' });
  const denied = f.client.getMessagePermissions('101', '50');
  assert.equal(denied.loading, false); assert.equal(denied.loaded, false); assert.ok(denied.error);
  capabilities(f, { can_be_edited: false, can_be_deleted_only_for_self: false, can_be_saved: false });
  assert.equal(f.client.getMessagePermissions('101', '50').canCopy, false);
  assert.equal(f.client.editMessage('101', '50', 'new'), '');
  assert.equal(f.client.deleteMessage('101', '50', false), '');
  assert.equal(f.client.getMessagePermissions('101', '50').canDeleteForAll, true);
});

test('each explicit permission refresh removes stale capabilities until response', () => {
  const f = setup(); capabilities(f);
  assert.equal(f.client.getMessagePermissions('101', '50').canReply, true);
  f.client.loadMessageProperties('101', '50');
  assert.equal(f.client.getMessagePermissions('101', '50').canReply, false);
  assert.equal(f.client.sendReply('101', 'reply', '50'), '');
  result(f, f.transport.last('getMessageProperties')['@extra'], { '@type': 'messageProperties', can_be_replied: false });
  assert.equal(f.client.getMessagePermissions('101', '50').canReply, false);
});

test('observed message content changes refresh permissions once and ignore older results and errors', () => {
  const f = setup(); capabilities(f);
  f.client.loadMessageProperties('101', '50'); const old = f.transport.last('getMessageProperties');
  const before = f.transport.all('getMessageProperties').length;
  deliver(f, { '@type': 'updateMessageContent', chat_id: 101, message_id: 50,
    new_content: { '@type': 'messageText', text: { text: 'changed by another client' } } });
  const fresh = f.transport.last('getMessageProperties');
  assert.notEqual(fresh['@extra'], old['@extra']);
  assert.equal(f.transport.all('getMessageProperties').length, before + 1);
  assert.equal(f.client.getMessagePermissions('101', '50').loading, true);
  f.client.loadMessageProperties('101', '50');
  assert.equal(f.transport.all('getMessageProperties').length, before + 1);
  result(f, fresh['@extra'], { '@type': 'messageProperties', can_be_replied: false, can_be_edited: false });
  result(f, old['@extra'], { '@type': 'messageProperties', can_be_replied: true, can_be_edited: true });
  assert.equal(f.client.getMessagePermissions('101', '50').canEdit, false);
  const error = f.client.state().error;
  result(f, old['@extra'], { '@type': 'error', code: 500 });
  assert.equal(f.client.state().error, error);
  f.client.drain(); f.client.drain();
  assert.equal(f.transport.all('getMessageProperties').length, before + 1);
});

test('unobserved content updates do not fan out permission queries; submitting unknown permissions can recover', () => {
  const f = setup();
  deliver(f, { '@type': 'updateMessageContent', chat_id: 101, message_id: 50,
    new_content: { '@type': 'messageText', text: { text: 'latest fixture' } } });
  assert.equal(f.transport.all('getMessageProperties').length, 0);
  assert.equal(f.client.editMessage('101', '50', 'edited fixture'), '');
  assert.equal(f.transport.all('getMessageProperties').length, 1);
  assert.equal(f.client.editMessage('101', '50', 'edited fixture'), '');
  assert.equal(f.transport.all('getMessageProperties').length, 1);
  result(f, f.transport.last('getMessageProperties')['@extra'], { '@type': 'messageProperties', can_be_edited: true });
  assert.ok(f.client.editMessage('101', '50', 'edited fixture'));
});

test('failed permission refresh can be retried by the existing composer without canceling its text', () => {
  const f = setup(); capabilities(f);
  deliver(f, { '@type': 'updateMessageContent', chat_id: 101, message_id: 50,
    new_content: { '@type': 'messageText', text: { text: 'remote edit' } } });
  result(f, f.transport.last('getMessageProperties')['@extra'], { '@type': 'error', code: 500 });
  assert.equal(f.client.sendReply('101', 'kept reply text', '50'), '');
  const retry = f.transport.last('getMessageProperties');
  result(f, retry['@extra'], { '@type': 'messageProperties', can_be_replied: true });
  assert.ok(f.client.sendReply('101', 'kept reply text', '50'));
  assert.equal(f.transport.last('sendMessage').input_message_content.text.text, 'kept reply text');
});

test('clipboard save permission is independent from permission to send a copy through forwarding', () => {
  const f = setup(); capabilities(f, { can_be_copied: false, can_be_saved: true });
  assert.equal(f.client.getMessagePermissions('101', '50').canCopy, true);
  capabilities(f, { can_be_copied: true, can_be_saved: false });
  assert.equal(f.client.getMessagePermissions('101', '50').canCopy, false);
});

test('editing uses service-confirmed message and failure retains original plus ordinary draft', () => {
  const f = setup(); capabilities(f); f.client.setDraft('101', 'ordinary draft');
  const token = f.client.editMessage('101', '50', 'edited fixture');
  assert.equal(f.client.getMessageAction(token).status, 'pending');
  assert.equal(f.repository.getMessages('101')[0].text, 'Fixture original');
  assert.equal(f.transport.last('editMessageText').input_message_content.clear_draft, false);
  assert.equal(f.client.editMessage('101', '50', 'duplicate tap'), '');
  result(f, token, { '@type': 'error', code: 400, message: 'MESSAGE_EDIT_TIME_EXPIRED with fixture text' });
  assert.equal(f.client.getMessageAction(token).status, 'failed');
  assert.equal(f.client.getMessageAction(token).error.includes('fixture text'), false);
  assert.equal(f.repository.getDraft('101'), 'ordinary draft');
  assert.equal(f.repository.getMessages('101')[0].text, 'Fixture original');
  const retry = f.client.editMessage('101', '50', 'edited fixture'); assert.ok(retry);
  result(f, retry, message(50, 101, { edit_date: 1700000040, content: { '@type': 'messageText', text: { text: 'edited fixture' } } }));
  assert.equal(f.client.getMessageAction(retry).status, 'succeeded');
  assert.equal(f.repository.getMessages('101')[0].text, 'edited fixture');
  assert.equal(f.repository.getMessages('101')[0].editDate, 1700000040);
});

test('photo caption can be emptied without sending the display label or changing caption position', () => {
  const f = setup();
  deliver(f, { '@type': 'updateNewMessage', message: message(51, 101, { content: { '@type': 'messagePhoto',
    photo: { sizes: [] }, caption: { text: 'caption fixture' }, show_caption_above_media: true } }) });
  capabilities(f, {}, '51');
  const token = f.client.editMessage('101', '51', '');
  const request = f.transport.last('editMessageCaption');
  assert.ok(token); assert.equal(request.caption.text, ''); assert.equal(request.show_caption_above_media, true);
  assert.equal(f.repository.getMessages('101').find(item => item.id === '51').caption, 'caption fixture');
  assert.equal(f.transport.all('editMessageText').length, 0);
});

test('unsupported content is never presented as editable despite broader TDLib capabilities', () => {
  const f = setup(); deliver(f, { '@type': 'updateNewMessage', message: message(60, 101, { content: { '@type': 'messagePoll' } }) });
  capabilities(f, {}, '60'); assert.equal(f.client.getMessagePermissions('101', '60').canEdit, false);
  assert.equal(f.client.editMessage('101', '60', 'not a poll edit'), '');
});

test('deletion preserves exact revoke scope and waits for confirmation; failed delete leaves message', () => {
  const f = setup(); capabilities(f, { can_be_deleted_for_all_users: false });
  assert.equal(f.client.deleteMessage('101', '50', true), '');
  assert.equal(f.client.deleteMessage('101', '50'), '');
  const token = f.client.deleteMessage('101', '50', false);
  assert.equal(f.transport.last('deleteMessages').revoke, false);
  assert.equal(f.repository.getMessages('101').length, 1);
  result(f, token, { '@type': 'error', code: 400 });
  assert.equal(f.repository.getMessages('101').length, 1);
  const retry = f.client.deleteMessage('101', '50', false);
  result(f, retry, { '@type': 'ok' });
  assert.equal(f.client.getMessageAction(retry).status, 'succeeded');
  assert.equal(f.repository.getMessages('101').length, 0);
});

test('cache eviction does not delete visible messages but permanent deletion invalidates pending permissions', () => {
  const f = setup(); f.client.loadMessageProperties('101', '50'); const request = f.transport.last('getMessageProperties');
  deliver(f, { '@type': 'updateDeleteMessages', chat_id: 101, message_ids: [50], is_permanent: false });
  assert.equal(f.repository.getMessages('101').length, 1);
  deliver(f, { '@type': 'updateDeleteMessages', chat_id: 101, message_ids: [50], is_permanent: true });
  result(f, request['@extra'], { '@type': 'messageProperties', can_be_edited: true });
  assert.equal(f.client.getMessagePermissions('101', '50').canEdit, false);
  assert.equal(f.repository.getMessages('101').length, 0);
});

test('delete for everyone carries explicit revoke true and leaves chat preview to server updates', () => {
  const f = setup();
  deliver(f, { '@type': 'updateChatLastMessage', chat_id: 101, last_message: message() });
  capabilities(f); const token = f.client.deleteMessage('101', '50', true);
  assert.equal(f.transport.last('deleteMessages').revoke, true);
  result(f, token, { '@type': 'ok' });
  assert.equal(f.repository.getChats().find(item => item.id === '101').subtitle, 'Fixture original');
  deliver(f, { '@type': 'updateChatLastMessage', chat_id: 101, last_message: null });
  assert.equal(f.repository.getChats().find(item => item.id === '101').subtitle, '暂无消息');
});

test('reply sends exact schema/topic and keeps draft until cloud send confirmation', () => {
  const f = setup();
  deliver(f, { '@type': 'updateNewMessage', message: message(50, 101, { topic_id: { '@type': 'messageTopicForum', forum_topic_id: 7 } }) });
  capabilities(f); f.client.setDraft('101', 'reply draft');
  const token = f.client.sendReply('101', 'reply draft', '50'); const request = f.transport.last('sendMessage');
  assert.deepEqual(request.reply_to, { '@type': 'inputMessageReplyToMessage', message_id: 50, quote: null, checklist_task_id: 0, poll_option_id: '' });
  assert.equal(request.topic_id.forum_topic_id, 7); assert.equal(request.input_message_content.clear_draft, false);
  result(f, token, pending(60));
  assert.equal(f.client.getMessageAction(token).status, 'pending'); assert.equal(f.repository.getDraft('101'), 'reply draft');
  deliver(f, { '@type': 'updateMessageSendSucceeded', old_message_id: 60, message: message(70) });
  assert.equal(f.client.getMessageAction(token).status, 'succeeded'); assert.equal(f.repository.getDraft('101'), '');
  assert.equal(f.repository.getMessages('101').some(item => item.id === '60'), false);
  // The first save may still be in flight; its acknowledgement must flush the later empty draft.
  result(f, f.transport.all('setChatDraftMessage')[0]['@extra'], { '@type': 'ok' });
  assert.equal(f.transport.last('setChatDraftMessage').draft_message, null);
});

test('Saved Messages grouping is not reused as a send topic while reply reference and draft remain intact', () => {
  const f = setup();
  deliver(f, { '@type': 'updateNewMessage', message: message(50, 101, {
    topic_id: { '@type': 'messageTopicSavedMessages', saved_messages_topic_id: 101 }
  }) });
  capabilities(f); f.client.setDraft('101', 'saved reply fixture');
  const token = f.client.sendReply('101', 'saved reply fixture', '50');
  const request = f.transport.last('sendMessage');
  // Fixed TDLib MessageTopic.cpp rejects any explicit Saved Messages send topic with 400.
  assert.ok(token); assert.equal(request.topic_id, null);
  assert.equal(request.chat_id, 101); assert.equal(request.reply_to.message_id, 50);
  assert.equal(request.reply_to['@type'], 'inputMessageReplyToMessage');
  assert.equal(request.input_message_content.text.text, 'saved reply fixture');
  assert.equal(request.input_message_content.clear_draft, false);
  assert.equal(f.repository.getDraft('101'), 'saved reply fixture');
  assert.equal(f.client.getMessageAction(token).status, 'pending');
});

test('reply keeps sendable thread and administered direct-message topics', () => {
  const topics = [
    { '@type': 'messageTopicThread', message_thread_id: 11 },
    { '@type': 'messageTopicDirectMessages', direct_messages_chat_topic_id: 202 }
  ];
  for (const topic of topics) {
    const f = setup();
    deliver(f, { '@type': 'updateNewMessage', message: message(50, 101, { topic_id: topic }) });
    capabilities(f); assert.ok(f.client.sendReply('101', 'topic reply fixture', '50'));
    assert.deepEqual(f.transport.last('sendMessage').topic_id, topic);
  }
});

test('reply send errors do not append the draft or clear newer edits', () => {
  const f = setup(); capabilities(f); f.client.setDraft('101', 'first draft');
  const token = f.client.sendReply('101', 'first draft', '50');
  f.client.setDraft('101', 'newer draft'); result(f, token, { '@type': 'error', code: 500 });
  assert.equal(f.client.getMessageAction(token).status, 'failed');
  assert.equal(f.repository.getDraft('101'), 'newer draft'); assert.equal(f.repository.getMessages('101').length, 1);
  const retry = f.client.sendReply('101', 'first draft', '50'); result(f, retry, pending(60));
  deliver(f, { '@type': 'updateMessageSendFailed', old_message_id: 60,
    message: message(60, 101, { sending_state: { '@type': 'messageSendingStateFailed' } }) });
  assert.equal(f.client.getMessageAction(retry).status, 'failed'); assert.equal(f.repository.getDraft('101'), 'newer draft');
});

test('reply confirmation preserves a draft edited away and back while request was pending', () => {
  const f = setup(); capabilities(f); f.client.setDraft('101', 'reply draft');
  const token = f.client.sendReply('101', 'reply draft', '50'); result(f, token, pending(60));
  f.client.setDraft('101', 'newer'); f.client.setDraft('101', 'reply draft');
  deliver(f, { '@type': 'updateMessageSendSucceeded', old_message_id: 60, message: message(70) });
  assert.equal(f.repository.getDraft('101'), 'reply draft');
});

test('send completion before initial response does not regress final ID or status', () => {
  const f = setup(); capabilities(f); const token = f.client.sendReply('101', 'reply', '50');
  deliver(f, { '@type': 'updateMessageSendSucceeded', old_message_id: 60, message: message(70) });
  result(f, token, pending(60));
  assert.equal(f.client.getMessageAction(token).status, 'succeeded');
  assert.equal(f.repository.getMessages('101').some(item => item.id === '60'), false);
  assert.equal(f.client.getMessageAction(token).targetMessageId, '70');
});

test('forward uses selected chat, rejects null results, and waits for send confirmation', () => {
  const f = setup(); capabilities(f);
  assert.equal(f.client.forwardMessage('101', '50', '999'), '');
  const first = f.client.forwardMessage('101', '50', '202');
  const request = f.transport.last('forwardMessages');
  assert.equal(request.chat_id, 202); assert.equal(request.from_chat_id, 101);
  assert.equal(request.send_copy, false); assert.equal(request.remove_caption, false); assert.deepEqual(request.message_ids, [50]);
  result(f, first, { '@type': 'messages', messages: [null] });
  assert.equal(f.client.getMessageAction(first).status, 'failed'); assert.equal(f.repository.getMessages('202').length, 0);
  const token = f.client.forwardMessage('101', '50', '202');
  result(f, token, { '@type': 'messages', messages: [pending(60, 202)] });
  assert.equal(f.client.getMessageAction(token).status, 'pending');
  deliver(f, { '@type': 'updateMessageSendSucceeded', old_message_id: 60, message: message(70, 202) });
  assert.equal(f.client.getMessageAction(token).status, 'succeeded');
  assert.equal(f.repository.getMessages('101')[0].text, 'Fixture original');
});

test('wrong-chat forward/edit responses cannot mutate unrelated messages or claim success', () => {
  const f = setup(); capabilities(f);
  const forward = f.client.forwardMessage('101', '50', '202');
  result(f, forward, { '@type': 'messages', messages: [message(70, 303)] });
  assert.equal(f.client.getMessageAction(forward).status, 'failed'); assert.equal(f.repository.getMessages('303').length, 0);
  const edit = f.client.editMessage('101', '50', 'new'); result(f, edit, message(51));
  assert.equal(f.client.getMessageAction(edit).status, 'failed'); assert.equal(f.repository.getMessages('101').length, 1);
});

test('reply metadata survives content updates and click lazily resolves unavailable originals', () => {
  const f = setup();
  deliver(f, { '@type': 'updateNewMessage', message: message(80, 101, {
    reply_to: { '@type': 'messageReplyToMessage', chat_id: 0, message_id: 0, quote: { text: { text: 'quoted fixture' } } } }) });
  let reply = f.repository.getMessages('101').find(item => item.id === '80');
  assert.equal(reply.replyToChatId, undefined); assert.equal(reply.replyPreview, 'quoted fixture');
  assert.equal(f.transport.all('getRepliedMessage').length, 0);
  deliver(f, { '@type': 'updateMessageContent', chat_id: 101, message_id: 80, new_content: { '@type': 'messageText', text: { text: 'changed reply' } } });
  reply = f.repository.getMessages('101').find(item => item.id === '80'); assert.equal(reply.replyPreview, 'quoted fixture');
  const token = f.client.loadReplyTarget('101', '80');
  assert.equal(f.transport.last('getRepliedMessage').message_id, 80);
  result(f, token, message(40, 202));
  assert.equal(f.client.getMessageAction(token).targetChatId, '202'); assert.equal(f.client.getMessageAction(token).targetMessageId, '40');
  assert.equal(f.repository.getMessages('202')[0].id, '40');
  assert.equal(f.repository.getMessages('101').find(item => item.id === '80').replyPreview, 'quoted fixture');
  deliver(f, { '@type': 'updateMessageContent', chat_id: 101, message_id: 80,
    new_content: { '@type': 'messageText', text: { text: 'changed after locate' } } });
  assert.equal(f.repository.getMessages('101').find(item => item.id === '80').replyToMessageId, '40');
});

test('deleted reply target reports bounded failure and does not issue retry loops', () => {
  const f = setup();
  deliver(f, { '@type': 'updateNewMessage', message: message(80, 101, { reply_to: { '@type': 'messageReplyToMessage', chat_id: 101, message_id: 2 } }) });
  const token = f.client.loadReplyTarget('101', '80'); result(f, token, { '@type': 'error', code: 404 });
  assert.equal(f.client.getMessageAction(token).status, 'failed'); f.client.drain(); f.client.drain();
  assert.equal(f.transport.all('getRepliedMessage').length, 1);
});

test('transport failure and closed session do not expose successful actions or stale permissions', () => {
  const f = setup(); capabilities(f); f.transport.failSend = true;
  assert.equal(f.client.editMessage('101', '50', 'new'), ''); assert.equal(f.repository.getMessages('101')[0].text, 'Fixture original');
  f.transport.failSend = false; const token = f.client.editMessage('101', '50', 'new');
  deliver(f, { '@type': 'updateAuthorizationState', authorization_state: { '@type': 'authorizationStateClosed' } });
  assert.equal(f.client.getMessageAction(token), undefined); assert.equal(f.client.getMessagePermissions('101', '50').loaded, false);
});

test('long-running sessions retain recent action results without retaining all historical edits', () => {
  const f = setup(); let first = ''; let last = '';
  for (let index = 0; index < 270; index++) {
    capabilities(f);
    last = f.client.editMessage('101', '50', `fixture edit ${index}`); if (!first) first = last;
    result(f, last, message(50, 101, { content: { '@type': 'messageText', text: { text: `fixture edit ${index}` } } }));
  }
  assert.equal(f.client.getMessageAction(first), undefined);
  assert.equal(f.client.getMessageAction(last).status, 'succeeded');
});
