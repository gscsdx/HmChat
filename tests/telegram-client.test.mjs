import test from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
const require = createRequire(import.meta.url);
const { ChatRepository } = require('../artifacts/tests/js/data/ChatRepository.js');
const { TelegramClient } = require('../artifacts/tests/js/telegram/TelegramClient.js');

const params = {
  apiId: 123456,
  apiHash: '0'.repeat(32),
  databaseDirectory: '/test/encrypted-database',
  filesDirectory: '/test/downloads',
  encryptionKey: 'dGVzdC1rZXk=',
};

class FakeTransport {
  clientId = 17;
  requests = [];
  queue = [];
  createError = false;
  sendError = false;
  receiveError = false;
  createClient() {
    if (this.createError) throw new Error('native library unavailable');
    return this.clientId;
  }
  send(clientId, raw) {
    if (this.sendError) throw new Error('native send failed');
    assert.equal(clientId, this.clientId);
    this.requests.push(JSON.parse(raw));
  }
  receive() {
    if (this.receiveError) throw new Error('native receive failed');
    return this.queue.shift() || '';
  }
  push(event) { this.queue.push(JSON.stringify({ '@client_id': this.clientId, ...event })); }
  last(type) { return this.requests.filter(request => request['@type'] === type).at(-1); }
}

function fixture({ ready = false } = {}) {
  const transport = new FakeTransport();
  const repository = new ChatRepository();
  const client = new TelegramClient(transport, repository); client.setMediaNetwork('wifi');
  client.start(params);
  if (ready) authorize(transport, client, 'Ready');
  return { transport, repository, client };
}
function authorize(transport, client, phase) {
  transport.push({ '@type': 'updateAuthorizationState', authorization_state: { '@type': `authorizationState${phase}` } });
  client.drain();
}
function message(id, chatId = 101, text = 'Hello Telegram', outgoing = false) {
  return {
    '@type': 'message', id, chat_id: chatId, date: 1700000000,
    is_outgoing: outgoing, content: { '@type': 'messageText', text: { '@type': 'formattedText', text, entities: [] } },
  };
}
function chat(id = 101) {
  return {
    '@type': 'chat', id, title: 'Test friend',
    type: { '@type': 'chatTypePrivate', user_id: id },
    positions: [{ list: { '@type': 'chatListMain' }, order: '9223372036854775807', is_pinned: true }],
    last_message: message(10, id, 'Preview'), unread_count: 3,
    notification_settings: { mute_for: 0 },
  };
}
function loadChat(transport, client, value = chat()) {
  transport.push({ '@type': 'updateNewChat', chat: value });
  client.drain();
}

test('startup removes demo content and supplies flat TDLib parameters when requested', () => {
  const { transport, repository, client } = fixture();
  assert.equal(client.state().phase, 'starting');
  assert.equal(client.state().ready, false);
  assert.equal(repository.isRemote(), true);
  assert.deepEqual(repository.getChats(), []);
  authorize(transport, client, 'WaitTdlibParameters');
  const request = transport.last('setTdlibParameters');
  assert.ok(request);
  assert.equal(request.api_id, params.apiId);
  assert.equal(request.api_hash, params.apiHash);
  assert.equal(request.database_directory, params.databaseDirectory);
  assert.equal(request.files_directory, params.filesDirectory);
  assert.equal(request.database_encryption_key, params.encryptionKey);
  assert.equal(request.use_test_dc, false);
  assert.equal(Object.hasOwn(request, 'parameters'), false, 'TDLib parameters are flat fields, not a nested parameters object');
});

test('phone, login code and password requests follow authorization phases', () => {
  const { transport, client } = fixture();
  const initialRequests = transport.requests.length;
  client.setPhone('+8613800000000');
  client.setCode('12345');
  client.setPassword('fixture password');
  assert.equal(transport.requests.length, initialRequests, 'wrong-phase credentials must not be sent');
  authorize(transport, client, 'WaitPhoneNumber');
  client.setPhone('not a number');
  assert.equal(transport.last('setAuthenticationPhoneNumber'), undefined);
  assert.ok(client.state().error);
  client.setPhone('+86 (138) 0000-0000');
  assert.equal(transport.last('setAuthenticationPhoneNumber').phone_number, '+8613800000000');
  assert.equal(client.state().error, '');
  authorize(transport, client, 'WaitCode');
  client.setCode('   ');
  assert.equal(transport.last('checkAuthenticationCode'), undefined);
  client.setCode(' 12345 ');
  assert.equal(transport.last('checkAuthenticationCode').code, '12345');
  authorize(transport, client, 'WaitPassword');
  client.setPassword('');
  assert.equal(transport.last('checkAuthenticationPassword'), undefined);
  client.setPassword('  preserve password whitespace  ');
  assert.equal(transport.last('checkAuthenticationPassword').password, '  preserve password whitespace  ');
});

test('email authorization uses the Telegram email address authentication code type', () => {
  const { transport, client } = fixture();
  authorize(transport, client, 'WaitEmailAddress');
  client.setEmail('invalid');
  assert.equal(transport.last('setAuthenticationEmailAddress'), undefined);
  client.setEmail(' user@example.com ');
  assert.equal(transport.last('setAuthenticationEmailAddress').email_address, 'user@example.com');
  authorize(transport, client, 'WaitEmailCode');
  client.setEmailCode(' 123456 ');
  assert.deepEqual(transport.last('checkAuthenticationEmailCode').code, {
    '@type': 'emailAddressAuthenticationCode', code: '123456',
  });
});

test('network connection readiness is not authentication readiness', () => {
  const { transport, client } = fixture();
  transport.push({ '@type': 'updateConnectionState', state: { '@type': 'connectionStateReady' } });
  client.drain();
  assert.equal(client.state().connection, '已连接');
  assert.equal(client.state().ready, false);
  assert.notEqual(client.state().phase, 'ready');
  assert.equal(client.sendMessage('101', 'not authenticated'), false);
  authorize(transport, client, 'Ready');
  assert.equal(client.state().ready, true);
  assert.ok(transport.last('loadChats'));
  assert.ok(transport.last('getContacts'));
  const loads = transport.requests.filter(request => request['@type'] === 'loadChats').length;
  authorize(transport, client, 'Ready');
  assert.equal(transport.requests.filter(request => request['@type'] === 'loadChats').length, loads);
});

test('chat, user, inbox, title and media preview updates map to user-visible domain data', () => {
  const { transport, repository, client } = fixture({ ready: true });
  loadChat(transport, client);
  transport.push({ '@type': 'updateUser', user: {
    '@type': 'user', id: 101, first_name: 'Ada', last_name: 'Lovelace', is_contact: true, status: { '@type': 'userStatusOnline' },
  } });
  transport.push({ '@type': 'updateChatReadInbox', chat_id: 101, unread_count: 0 });
  transport.push({ '@type': 'updateChatTitle', chat_id: 101, title: 'Updated title' });
  transport.push({ '@type': 'updateChatLastMessage', chat_id: 101,
    last_message: { ...message(11), content: { '@type': 'messagePhoto', caption: { '@type': 'formattedText', text: 'A picture' } } },
  });
  client.drain();
  const summary = repository.getChats().find(item => item.id === '101');
  assert.equal(summary.title, 'Updated title');
  assert.equal(summary.online, true);
  assert.equal(summary.unread, 0);
  assert.equal(summary.pinned, true);
  assert.equal(summary.kind, 'private');
  assert.ok(summary.subtitle.includes('A picture'));
  assert.ok(summary.subtitle.includes('图片'));
  const contact = repository.getContacts().find(item => item.id === '101');
  assert.equal(contact.name, 'Ada Lovelace');
});

test('history merges with live arrivals without losing or duplicating messages', () => {
  const { transport, repository, client } = fixture({ ready: true });
  loadChat(transport, client);
  client.openChat('101');
  const historyRequest = transport.last('getChatHistory');
  assert.equal(historyRequest.chat_id, 101);
  transport.push({ '@type': 'updateNewMessage', message: message(30, 101, 'arrived during history request') });
  client.drain();
  transport.push({ '@type': 'messages', '@extra': historyRequest['@extra'], messages: [message(20), message(10), message(30)] });
  client.drain();
  assert.deepEqual(repository.getMessages('101').map(item => item.id), ['10', '20', '30']);
  assert.equal(transport.last('viewMessages'), undefined, 'loading messages does not imply viewing them');
  client.viewVisibleMessages('101', ['20', '30']);
  assert.deepEqual(transport.last('viewMessages').message_ids, [20, 30]);
});

test('remote send is a transport request and is never marked locally delivered', () => {
  const { transport, repository, client } = fixture({ ready: true });
  loadChat(transport, client);
  repository.setDraft('101', 'message draft');
  assert.equal(client.sendMessage('101', '\n  '), false);
  assert.equal(client.sendMessage('101', 'a'.repeat(4097)), false);
  assert.equal(client.sendMessage('not-a-number', 'hello'), false);
  assert.equal(client.sendMessage('101', '  send this  '), true);
  const send = transport.last('sendMessage');
  assert.equal(send.chat_id, 101);
  assert.equal(send.input_message_content['@type'], 'inputMessageText');
  assert.equal(send.input_message_content.text.text, 'send this');
  assert.equal(repository.getDraft('101'), '');
  assert.equal(repository.getMessages('101').length, 0, 'only TDLib responses determine delivery status');
});

test('pending to failed and pending to sent transitions replace temporary message IDs', () => {
  const { transport, repository, client } = fixture({ ready: true });
  const pending = { ...message(-10, 101, 'retry later', true), sending_state: { '@type': 'messageSendingStatePending' } };
  transport.push({ '@type': 'updateNewMessage', message: pending });
  client.drain();
  assert.equal(repository.getMessages('101')[0].status, 'pending');
  transport.push({ '@type': 'updateMessageSendFailed', old_message_id: -10,
    message: { ...pending, id: -11, sending_state: { '@type': 'messageSendingStateFailed' } },
  });
  client.drain();
  assert.deepEqual(repository.getMessages('101').map(item => [item.id, item.status]), [['-11', 'failed']]);
  transport.push({ '@type': 'updateMessageSendSucceeded', old_message_id: -11, message: message(50, 101, 'retry later', true) });
  client.drain();
  assert.deepEqual(repository.getMessages('101').map(item => [item.id, item.status]), [['50', 'sent']]);
});

test('deletion, content edits and archived chat positions do not leave stale entries', () => {
  const { transport, repository, client } = fixture({ ready: true });
  loadChat(transport, client);
  transport.push({ '@type': 'updateNewMessage', message: message(100) });
  transport.push({ '@type': 'updateMessageContent', chat_id: 101, message_id: 100,
    new_content: { '@type': 'messageText', text: { '@type': 'formattedText', text: 'edited' } },
  });
  client.drain();
  assert.equal(repository.getMessages('101')[0].text, 'edited');
  transport.push({ '@type': 'updateDeleteMessages', chat_id: 101, message_ids: [100], is_permanent: true });
  transport.push({ '@type': 'updateChatPosition', chat_id: 101,
    position: { list: { '@type': 'chatListMain' }, order: '0', is_pinned: false },
  });
  client.drain();
  assert.deepEqual(repository.getMessages('101'), []);
  assert.deepEqual(repository.getChats(), []);
});

test('server errors stay visible, actionable and do not echo private server payloads', () => {
  const { transport, client } = fixture();
  authorize(transport, client, 'WaitCode');
  transport.push({ '@type': 'error', code: 400, message: 'PHONE_CODE_INVALID', '@extra': 'checkAuthenticationCode:5' });
  client.drain();
  assert.ok(client.state().error.includes('验证码'));
  assert.equal(client.state().phase, 'code');
  assert.equal(client.state().ready, false);
  transport.push({ '@type': 'error', code: 500, message: 'unknown private payload should never reach UI' });
  client.drain();
  assert.equal(client.state().error.includes('private payload'), false);
});

test('foreign client updates and malformed JSON cannot falsely authenticate this client', () => {
  const { transport, client } = fixture();
  transport.push({ '@client_id': 999, '@type': 'updateAuthorizationState', authorization_state: { '@type': 'authorizationStateReady' } });
  transport.queue.push('{bad json');
  assert.doesNotThrow(() => client.drain());
  assert.equal(client.state().ready, false);
  assert.ok(client.state().error);
});

test('closed authorization removes real account data and revokes the ready state', () => {
  const { transport, repository, client } = fixture({ ready: true });
  loadChat(transport, client);
  transport.push({ '@type': 'updateNewMessage', message: message(20) });
  client.drain();
  assert.ok(repository.getChats().length);
  authorize(transport, client, 'Closed');
  assert.equal(client.state().phase, 'closed');
  assert.equal(client.state().ready, false);
  assert.deepEqual(repository.getChats(), []);
  assert.deepEqual(repository.getMessages('101'), []);
});

test('missing native library surfaces an error without fake success or a thrown startup exception', () => {
  const transport = new FakeTransport();
  transport.createError = true;
  const client = new TelegramClient(transport, new ChatRepository());
  assert.doesNotThrow(() => client.start(params));
  assert.equal(client.state().phase, 'error');
  assert.equal(client.state().ready, false);
  assert.ok(client.state().error);
  assert.equal(transport.requests.length, 0);
});

test('native receive exceptions are contained and reported to the observer', () => {
  const { transport, client } = fixture({ ready: true });
  let latest = client.state();
  client.subscribe(state => latest = state);
  transport.receiveError = true;
  assert.doesNotThrow(() => client.drain());
  assert.ok(latest.error, 'a native transport failure must be visible instead of killing the polling loop');
});

test('native send exceptions preserve the draft and cannot crash the message action', () => {
  const { transport, repository, client } = fixture({ ready: true });
  loadChat(transport, client);
  repository.setDraft('101', 'keep this draft');
  transport.sendError = true;
  let accepted;
  assert.doesNotThrow(() => accepted = client.sendMessage('101', 'keep this draft'));
  assert.equal(accepted, false);
  assert.equal(repository.getDraft('101'), 'keep this draft');
  assert.ok(client.state().error);
});

test('native exceptions during credential submission stay in the recoverable login flow', () => {
  const { transport, client } = fixture();
  authorize(transport, client, 'WaitPhoneNumber');
  transport.sendError = true;
  assert.doesNotThrow(() => client.setPhone('+8613800000000'));
  assert.equal(client.state().ready, false);
  assert.ok(client.state().error);
});

test('all authentication inputs allow only one pending request and keep submitting through unrelated updates', () => {
  const cases = [
    ['WaitPhoneNumber', 'setPhone', '+12025550123', 'setAuthenticationPhoneNumber'],
    ['WaitCode', 'setCode', '12345', 'checkAuthenticationCode'],
    ['WaitPassword', 'setPassword', 'fixture password', 'checkAuthenticationPassword'],
    ['WaitEmailAddress', 'setEmail', 'fixture@example.com', 'setAuthenticationEmailAddress'],
    ['WaitEmailCode', 'setEmailCode', '123456', 'checkAuthenticationEmailCode'],
  ];
  for (const [phase, method, value, type] of cases) {
    const { transport, client } = fixture();
    const observed = []; client.subscribe(state => observed.push(state.submitting));
    authorize(transport, client, phase);
    client[method](value); client[method](value);
    assert.equal(transport.requests.filter(request => request['@type'] === type).length, 1, method);
    assert.equal(client.state().submitting, true, method);
    assert.equal(observed.at(-1), true, 'the immediate emit must keep the UI locked');
    transport.push({ '@type': 'updateConnectionState', state: { '@type': 'connectionStateReady' } });
    transport.push({ '@type': 'ok', '@extra': 'unrelated:999' });
    transport.push({ '@type': 'error', '@extra': 'unrelated:998', code: 500, message: 'fixture unrelated error' });
    client.drain();
    assert.equal(client.state().submitting, true);
    client[method](value);
    assert.equal(transport.requests.filter(request => request['@type'] === type).length, 1);
    const first = transport.last(type);
    transport.push({ '@type': 'error', '@extra': first['@extra'], code: 400, message: 'fixture rejected' });
    client.drain();
    assert.equal(client.state().submitting, false);
    client[method](value);
    assert.equal(transport.requests.filter(request => request['@type'] === type).length, 2);
    assert.equal(client.state().submitting, true);
    transport.push({ '@type': 'ok', '@extra': first['@extra'] }); client.drain();
    assert.equal(client.state().submitting, true, 'late replies to older submissions cannot unlock the current request');
    transport.push({ '@type': 'ok', '@extra': transport.last(type)['@extra'] }); client.drain();
    assert.equal(client.state().submitting, false);
  }
});

test('authorization transitions and closing clear authentication submission state', () => {
  const { transport, client } = fixture();
  authorize(transport, client, 'WaitPhoneNumber'); client.setPhone('+12025550123');
  assert.equal(client.state().submitting, true);
  authorize(transport, client, 'WaitCode'); assert.equal(client.state().submitting, false);
  client.setCode('12345'); assert.equal(client.state().submitting, true);
  authorize(transport, client, 'WaitPassword'); assert.equal(client.state().submitting, false);
  client.setPassword('fixture password'); assert.equal(client.state().submitting, true);
  authorize(transport, client, 'Closing'); assert.equal(client.state().submitting, false);
  authorize(transport, client, 'Closed'); assert.equal(client.state().submitting, false);
});

test('failed native authentication sends or receives do not leave submission permanently locked', () => {
  const { transport, client } = fixture();
  authorize(transport, client, 'WaitPhoneNumber');
  transport.sendError = true; client.setPhone('+12025550123');
  assert.equal(client.state().submitting, false);
  transport.sendError = false; client.setPhone('+12025550123');
  assert.equal(client.state().submitting, true);
  transport.receiveError = true; client.drain();
  assert.equal(client.state().submitting, false);
  transport.receiveError = false; client.setPhone('+12025550123');
  assert.equal(client.state().submitting, true);
  assert.equal(transport.requests.filter(request => request['@type'] === 'setAuthenticationPhoneNumber').length, 2);
});

test('an immediate server rejection retains outgoing text as a draft or failed message', () => {
  const { transport, repository, client } = fixture({ ready: true });
  loadChat(transport, client);
  repository.setDraft('101', 'must not disappear after send');
  assert.equal(client.sendMessage('101', 'must not disappear after send'), true);
  const send = transport.last('sendMessage');
  transport.push({ '@type': 'error', '@extra': send['@extra'], code: 400, message: 'CHAT_WRITE_FORBIDDEN' });
  client.drain();
  const hasRecoverableText = repository.getDraft('101') === 'must not disappear after send' ||
    repository.getMessages('101').some(item => item.text === 'must not disappear after send' && item.status === 'failed');
  assert.equal(hasRecoverableText, true, 'a server rejection cannot erase the user’s message');
  assert.ok(client.state().error);
});

test('failed requests recover text independently for each conversation', () => {
  const { transport, repository, client } = fixture({ ready: true });
  loadChat(transport, client, chat(101));
  loadChat(transport, client, chat(202));
  const recoverable = (id, text) => repository.getDraft(id) === text ||
    repository.getMessages(id).some(item => item.text === text && item.status === 'failed');
  client.sendMessage('101', 'conversation one');
  const first = transport.last('sendMessage');
  client.sendMessage('202', 'conversation two');
  const second = transport.last('sendMessage');
  assert.notEqual(first['@extra'], second['@extra']);
  transport.push({ '@type': 'error', '@extra': second['@extra'], code: 400, message: 'CHAT_WRITE_FORBIDDEN' });
  client.drain();
  assert.equal(recoverable('202', 'conversation two'), true);
  assert.equal(recoverable('101', 'conversation two'), false, 'text from another chat must never be restored here');
  transport.push({ '@type': 'error', '@extra': first['@extra'], code: 429, message: 'FLOOD_WAIT_5' });
  client.drain();
  assert.equal(recoverable('101', 'conversation one'), true);
  assert.equal(recoverable('202', 'conversation two'), true);
});

test('leaving a chat prevents delayed history and new messages from being marked read', () => {
  const { transport, client } = fixture({ ready: true });
  loadChat(transport, client);
  client.openChat('101');
  const history = transport.last('getChatHistory');
  transport.push({ '@type': 'updateNewMessage', message: message(10) });
  client.drain();
  client.viewVisibleMessages('101', ['10']);
  assert.ok(transport.last('viewMessages'), 'a visible foreground conversation may be marked read');
  client.leaveChat();
  assert.equal(transport.last('closeChat').chat_id, 101);
  const views = transport.requests.filter(request => request['@type'] === 'viewMessages').length;
  transport.push({ '@type': 'updateNewMessage', message: message(20) });
  transport.push({ '@type': 'messages', '@extra': history['@extra'], messages: [message(10), message(20)] });
  client.drain();
  client.viewVisibleMessages('101', ['10', '20']);
  assert.equal(transport.requests.filter(request => request['@type'] === 'viewMessages').length, views);
});

test('background arrivals remain unread until the foreground UI reports visible messages', () => {
  const { transport, client } = fixture({ ready: true });
  loadChat(transport, client);
  client.openChat('101');
  const history = transport.last('getChatHistory');
  client.setForeground(false);
  const views = transport.requests.filter(request => request['@type'] === 'viewMessages').length;
  transport.push({ '@type': 'updateNewMessage', message: message(30) });
  transport.push({ '@type': 'messages', '@extra': history['@extra'], messages: [message(10), message(20)] });
  client.drain();
  client.viewVisibleMessages('101', ['10', '20', '30']);
  assert.equal(transport.requests.filter(request => request['@type'] === 'viewMessages').length, views);
  client.setForeground(true);
  assert.equal(transport.requests.filter(request => request['@type'] === 'viewMessages').length, views);
  client.viewVisibleMessages('101', ['30']);
  assert.deepEqual(transport.last('viewMessages').message_ids, [30]);
});

test('group members are not silently added to contacts, while real contacts still appear', () => {
  const { transport, repository, client } = fixture({ ready: true });
  transport.push({ '@type': 'updateUser', user: {
    '@type': 'user', id: 303, first_name: 'Group', last_name: 'Member', is_contact: false,
    status: { '@type': 'userStatusOnline' },
  } });
  transport.push({ '@type': 'updateUserStatus', user_id: 303, status: { '@type': 'userStatusOffline' } });
  transport.push({ '@type': 'updateUser', user: {
    '@type': 'user', id: 404, first_name: 'Actual', last_name: 'Contact', is_contact: true,
    status: { '@type': 'userStatusOffline' },
  } });
  client.drain();
  assert.equal(repository.getContacts().some(contact => contact.id === '303'), false);
  assert.equal(repository.getContacts().some(contact => contact.id === '404'), true);
  const contactsRequest = transport.last('getContacts');
  transport.push({ '@type': 'users', '@extra': contactsRequest['@extra'], user_ids: [505] });
  transport.push({ '@type': 'user', id: 505, first_name: 'Listed', last_name: 'Contact', status: { '@type': 'userStatusOffline' } });
  client.drain();
  assert.equal(repository.getContacts().some(contact => contact.id === '505'), true);
});

test('a rejected send never overwrites a newer full-length draft or truncates failed text', () => {
  const { transport, repository, client } = fixture({ ready: true });
  loadChat(transport, client);
  const previous = 'previous message must remain recoverable';
  const newer = '新'.repeat(4096);
  assert.equal(client.sendMessage('101', previous), true);
  const request = transport.last('sendMessage');
  repository.setDraft('101', newer);
  transport.push({ '@type': 'error', '@extra': request['@extra'], code: 400, message: 'CHAT_WRITE_FORBIDDEN' });
  client.drain();
  assert.equal(repository.getDraft('101'), newer);
  assert.ok(repository.getMessages('101').some(item => item.text === previous && item.status === 'failed'));
});

test('initialization timeout ends the endless connecting state', t => {
  t.mock.timers.enable({ apis: ['Date'], now: 1000 });
  const { client } = fixture();
  t.mock.timers.tick(30001); client.drain();
  assert.equal(client.state().phase, 'error');
  assert.match(client.state().error, /连接超时/);
});

test('authentication timeout releases submit protection without sending another code request', t => {
  t.mock.timers.enable({ apis: ['Date'], now: 1000 });
  const { client, transport } = fixture(); authorize(transport, client, 'WaitPhoneNumber');
  client.setPhone('+12025550123');
  assert.equal(client.state().submitting, true);
  t.mock.timers.tick(30001); client.drain();
  assert.equal(client.state().submitting, false);
  assert.match(client.state().error, /请求超时/);
  assert.equal(transport.requests.filter(r => r['@type'] === 'setAuthenticationPhoneNumber').length, 1);
  client.setPhone('+12025550123');
  assert.equal(client.state().submitting, true);
});

test('late error from an expired authentication request cannot unlock or overwrite its retry', t => {
  t.mock.timers.enable({ apis: ['Date'], now: 1000 });
  const { client, transport } = fixture(); authorize(transport, client, 'WaitPhoneNumber');
  client.setPhone('+12025550123'); const old = transport.last('setAuthenticationPhoneNumber')['@extra'];
  t.mock.timers.tick(30001); client.drain(); client.setPhone('+12025550123');
  transport.push({ '@type': 'error', '@extra': old, code: 400, message: 'PHONE_NUMBER_INVALID' }); client.drain();
  assert.equal(client.state().submitting, true); assert.equal(client.state().error, '');
});

test('authentication server failures immediately release the submit button and expose a readable error', () => {
  const { client, transport } = fixture(); authorize(transport, client, 'WaitCode');
  client.setCode('12345');
  transport.push({ '@type': 'error', '@extra': transport.last('checkAuthenticationCode')['@extra'], code: 400, message: 'PHONE_CODE_INVALID' }); client.drain();
  assert.equal(client.state().submitting, false); assert.match(client.state().error, /验证码不正确/);
});

test('registration is offered only after Telegram requests it and requires explicit terms acceptance', () => {
  const { client, transport } = fixture();
  client.register('Example', '', true);
  assert.equal(transport.last('registerUser'), undefined);
  transport.push({ '@type': 'updateAuthorizationState', authorization_state: { '@type': 'authorizationStateWaitRegistration', terms_of_service: { text: { '@type': 'formattedText', text: 'Synthetic terms', entities: [] }, min_user_age: 18, show_popup: true } } }); client.drain();
  assert.equal(client.state().phase, 'registration');assert.equal(client.state().minAge,18);assert.equal(client.state().termsText,'Synthetic terms');
  client.register('Example', '', false); assert.equal(transport.last('registerUser'), undefined);
  client.register('', '', true); assert.equal(transport.last('registerUser'), undefined);
  client.register('Example', '', true);
  assert.equal(transport.last('registerUser').disable_notification, true);
  assert.equal(transport.last('registerUser').first_name, 'Example');
  const count=transport.requests.length;client.register('Example','',true);assert.equal(transport.requests.length,count);
  assert.equal(client.state().ready,false);
});

test('resending follows server next_type and timeout without automatic requests', t => {
  t.mock.timers.enable({apis:['Date'],now:1000});
  const { client,transport }=fixture();
  transport.push({'@type':'updateAuthorizationState',authorization_state:{'@type':'authorizationStateWaitCode',code_info:{type:{'@type':'authenticationCodeTypeTelegramMessage'},next_type:{'@type':'authenticationCodeTypeSms'},timeout:45}}});client.drain();
  assert.equal(client.state().resendSeconds,45);client.resendCode();assert.equal(transport.last('resendAuthenticationCode'),undefined);
  t.mock.timers.tick(45000);client.drain();assert.equal(client.state().canResend,true);
  assert.equal(transport.last('resendAuthenticationCode'),undefined);
  client.resendCode();assert.equal(transport.last('resendAuthenticationCode').reason,null);
  const count=transport.requests.length;client.resendCode();assert.equal(transport.requests.length,count);
});

test('a code step without a server fallback never offers a resend',()=>{
  const {client,transport}=fixture();authorize(transport,client,'WaitCode');
  client.resendCode();assert.equal(client.state().canResend,false);assert.equal(transport.last('resendAuthenticationCode'),undefined);
});

test('changing phone returns to entry without automatically requesting another code',()=>{
  const {client,transport}=fixture();authorize(transport,client,'WaitCode');const count=transport.requests.length;
  client.editPhone();assert.equal(client.state().phase,'phone');assert.equal(transport.requests.length,count);
  client.setPhone('+12025550123');assert.ok(transport.last('setAuthenticationPhoneNumber'));
});
