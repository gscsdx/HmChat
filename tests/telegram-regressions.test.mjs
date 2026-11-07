import test from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
const require = createRequire(import.meta.url);
const { ChatRepository } = require('../artifacts/tests/js/data/ChatRepository.js');
const { TelegramClient } = require('../artifacts/tests/js/telegram/TelegramClient.js');

const parameters = {
  apiId: 123456, apiHash: '0'.repeat(32),
  databaseDirectory: '/fixture/database', filesDirectory: '/fixture/files', encryptionKey: 'Zml4dHVyZQ==',
};
class Transport {
  requests = [];
  queue = [];
  createClient() { return 7; }
  send(id, raw) { assert.equal(id, 7); this.requests.push(JSON.parse(raw)); }
  receive() { return this.queue.shift() || ''; }
  push(event) { this.queue.push(JSON.stringify({ '@client_id': 7, ...event })); }
  all(type) { return this.requests.filter(item => item['@type'] === type); }
  last(type) { return this.all(type).at(-1); }
}
function fixture(ready = true) {
  const transport = new Transport();
  const repository = new ChatRepository();
  const client = new TelegramClient(transport, repository); client.setMediaNetwork('wifi');
  client.start(parameters);
  if (ready) authorize(transport, client, 'Ready');
  return { transport, repository, client };
}
function authorize(transport, client, name, fields = {}) {
  transport.push({ '@type': 'updateAuthorizationState', authorization_state: { '@type': `authorizationState${name}`, ...fields } });
  client.drain();
}
function chat(id, settings = { '@type': 'chatNotificationSettings', mute_for: 0 }) {
  return {
    '@type': 'chat', id, title: `Contact ${id}`, type: { '@type': 'chatTypePrivate', user_id: id },
    positions: [{ list: { '@type': 'chatListMain' }, order: '100', is_pinned: false }],
    unread_count: 0, notification_settings: settings,
  };
}
function contact(transport, client, id) {
  transport.push({ '@type': 'updateUser', user: {
    '@type': 'user', id, first_name: `Contact ${id}`, last_name: '', is_contact: true,
    status: { '@type': 'userStatusOffline' },
  } });
  client.drain();
}

test('SMS words and phrases reach TDLib while empty and oversized codes remain local', () => {
  const { transport, client } = fixture(false);
  for (const [type, code] of [
    ['authenticationCodeTypeSmsWord', 'maple'],
    ['authenticationCodeTypeSmsPhrase', 'silver mountain'],
    ['authenticationCodeTypeTelegramMessage', '12345'],
  ]) {
    authorize(transport, client, 'WaitCode', { code_info: { type: { '@type': type } } });
    client.setCode(` ${code} `);
    assert.equal(transport.last('checkAuthenticationCode').code, code);
  }
  const count = transport.all('checkAuthenticationCode').length;
  transport.push({ '@type': 'ok', '@extra': transport.last('checkAuthenticationCode')['@extra'] });
  client.drain();
  client.setCode(' \n ');
  client.setCode('a'.repeat(257));
  assert.equal(transport.all('checkAuthenticationCode').length, count);
  client.setCode('a'.repeat(256));
  assert.equal(transport.last('checkAuthenticationCode').code.length, 256);
});

test('mute and unmute preserve every remote notification preference without mutating the cache', () => {
  const { transport, client } = fixture();
  const settings = {
    '@type': 'chatNotificationSettings', use_default_mute_for: true, mute_for: 0,
    use_default_sound: false, sound_id: '9223372036854775806',
    use_default_show_preview: false, show_preview: false,
    use_default_mute_stories: false, mute_stories: true,
    use_default_story_sound: false, story_sound_id: '9223372036854775805',
    use_default_show_story_poster: false, show_story_poster: false,
    use_default_disable_pinned_message_notifications: false, disable_pinned_message_notifications: true,
    use_default_disable_mention_notifications: false, disable_mention_notifications: true,
  };
  transport.push({ '@type': 'updateNewChat', chat: chat(101, settings) });
  client.drain();
  client.toggleMuted('101');
  const muted = transport.last('setChatNotificationSettings').notification_settings;
  assert.deepEqual(muted, { ...settings, use_default_mute_for: false, mute_for: 2147483647 });
  client.toggleMuted('101');
  assert.deepEqual(transport.last('setChatNotificationSettings').notification_settings, muted,
    'without a server update the cached preferences must remain unchanged');
  transport.push({ '@type': 'updateChatNotificationSettings', chat_id: 101, notification_settings: muted });
  client.drain();
  client.toggleMuted('101');
  assert.deepEqual(transport.last('setChatNotificationSettings').notification_settings,
    { ...settings, use_default_mute_for: false, mute_for: 0 });
});

test('contact opening waits for its correlated chat reply, not an earlier updateNewChat', () => {
  const { transport, repository, client } = fixture();
  contact(transport, client, 101);
  assert.equal(client.openContact('101'), '101', 'UI navigation retains its synchronous contact id');
  client.openChat('101');
  client.openChat('101');
  assert.equal(transport.all('createPrivateChat').length, 1);
  const create = transport.last('createPrivateChat');
  assert.equal(transport.last('openChat'), undefined);
  assert.equal(transport.last('getChatHistory'), undefined);
  repository.setDraft('101', 'keep until the chat is ready');
  assert.equal(client.sendMessage('101', 'keep until the chat is ready'), false);
  assert.equal(repository.getDraft('101'), 'keep until the chat is ready');
  transport.push({ '@type': 'updateNewChat', chat: chat(101) });
  client.drain();
  client.openChat('101');
  assert.equal(transport.last('openChat'), undefined);
  transport.push({ ...chat(101), '@extra': create['@extra'] });
  client.drain();
  assert.equal(transport.all('openChat').length, 1);
  assert.equal(transport.last('openChat').chat_id, 101);
  assert.equal(transport.last('getChatHistory').chat_id, 101);
});

test('a delayed private-chat reply cannot reopen a conversation after navigating elsewhere', () => {
  const { transport, client } = fixture();
  contact(transport, client, 101);
  client.openContact('101');
  client.openChat('101');
  const first = transport.last('createPrivateChat');
  contact(transport, client, 202);
  client.openContact('202');
  client.openChat('202');
  const second = transport.last('createPrivateChat');
  transport.push({ ...chat(101), '@extra': first['@extra'] });
  client.drain();
  assert.equal(transport.last('openChat'), undefined);
  transport.push({ ...chat(202), '@extra': second['@extra'] });
  client.drain();
  assert.deepEqual(transport.all('openChat').map(item => item.chat_id), [202]);
  assert.deepEqual(transport.all('getChatHistory').map(item => item.chat_id), [202]);
});

test('leaving while a contact is being created never opens or reads that chat later', () => {
  const { transport, client } = fixture();
  client.openChat('101');
  const create = transport.last('createPrivateChat');
  client.leaveChat();
  assert.equal(transport.last('closeChat'), undefined, 'pending creation never opened a server chat');
  transport.push({ ...chat(101), '@extra': create['@extra'] });
  client.drain();
  assert.equal(transport.last('openChat'), undefined);
  assert.equal(transport.last('getChatHistory'), undefined);
  assert.equal(transport.last('viewMessages'), undefined);
});

test('private-chat creation errors release the pending request so a user can retry', () => {
  const { transport, client } = fixture();
  client.openChat('101');
  const first = transport.last('createPrivateChat');
  transport.push({ '@type': 'error', '@extra': first['@extra'], code: 400, message: 'Chat info not found' });
  client.drain();
  assert.ok(client.state().error);
  client.openChat('101');
  const retry = transport.last('createPrivateChat');
  assert.notEqual(retry['@extra'], first['@extra']);
  assert.equal(transport.last('openChat'), undefined);
  transport.push({ ...chat(101), '@extra': retry['@extra'] });
  client.drain();
  assert.equal(transport.last('openChat').chat_id, 101);
});

test('initialization uses the production data center and only current TDLib parameter fields', () => {
  const { transport, client } = fixture(false);
  authorize(transport, client, 'WaitTdlibParameters');
  const request = transport.last('setTdlibParameters');
  assert.equal(request.use_test_dc, false);
  assert.equal(Object.hasOwn(request, 'enable_storage_optimizer'), false);
  assert.equal(request.database_encryption_key, parameters.encryptionKey);
});
