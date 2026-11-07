import test from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
const require = createRequire(import.meta.url);
const { ChatRepository } = require('../artifacts/tests/js/data/ChatRepository.js');

function writable(repo) {
  return repo.getChats().find(chat => chat.kind === 'private');
}

test('local send validates content and reports only local delivery', () => {
  const repo = new ChatRepository();
  const chat = writable(repo);
  const before = repo.getMessages(chat.id).length;
  for (const text of ['', '  \n\t ', 'x'.repeat(4097)]) {
    assert.equal(repo.sendMessage(chat.id, text), false);
  }
  assert.equal(repo.sendMessage('nonexistent-chat', 'hello'), false);
  assert.equal(repo.getMessages(chat.id).length, before);
  repo.setDraft(chat.id, '  hello  ');
  assert.equal(repo.sendMessage(chat.id, '  hello  '), true);
  const message = repo.getMessages(chat.id).at(-1);
  assert.equal(message.text, 'hello');
  assert.equal(message.outgoing, true);
  assert.equal(message.status, 'local');
  assert.equal(repo.getDraft(chat.id), '');
  assert.equal(repo.getChats().find(item => item.id === chat.id).subtitle, 'hello');
  assert.equal(repo.sendMessage(chat.id, 'x'.repeat(4096)), true);
});

test('read-only channels cannot get a locally fabricated outgoing message', () => {
  const repo = new ChatRepository();
  const channel = repo.getChats().find(chat => chat.kind === 'channel');
  const before = repo.getMessages(channel.id);
  assert.equal(repo.sendMessage(channel.id, 'should not send'), false);
  assert.deepEqual(repo.getMessages(channel.id), before);
});

test('remote mode clears demo data and blocks local delivery bypass', () => {
  const repo = new ChatRepository();
  const chat = writable(repo);
  repo.useRemoteData();
  assert.equal(repo.isRemote(), true);
  assert.deepEqual(repo.getChats(), []);
  assert.deepEqual(repo.getContacts(), []);
  assert.deepEqual(repo.getMessages(chat.id), []);
  repo.upsertChat(chat);
  assert.equal(repo.sendMessage(chat.id, 'never claim remote success'), false);
  assert.deepEqual(repo.getMessages(chat.id), []);
});

test('drafts, sent text and preferences survive a valid snapshot round-trip', () => {
  const repo = new ChatRepository();
  const chat = writable(repo);
  repo.sendMessage(chat.id, 'persisted local message');
  repo.setDraft(chat.id, 'unfinished\n草稿');
  repo.setDarkMode(true);
  repo.togglePinned(chat.id);
  repo.toggleMuted(chat.id);
  const restored = new ChatRepository();
  assert.equal(restored.restore(repo.serialize()), true);
  assert.equal(restored.getDraft(chat.id), 'unfinished\n草稿');
  assert.equal(restored.getDarkMode(), true);
  assert.deepEqual(restored.getMessages(chat.id), repo.getMessages(chat.id));
  assert.deepEqual(restored.getChats(), repo.getChats());
});

test('corrupt snapshots are rejected atomically without erasing current work', () => {
  const repo = new ChatRepository();
  const chat = writable(repo);
  repo.setDraft(chat.id, 'must remain');
  const original = repo.serialize();
  const invalid = [
    'invalid json', 'null', '{}',
    JSON.stringify({ ...JSON.parse(original), version: 900 }),
    JSON.stringify({ ...JSON.parse(original), sequence: -1 }),
    JSON.stringify({ ...JSON.parse(original), drafts: [{ chatId: 'unknown', text: 'bad' }] }),
    JSON.stringify({ ...JSON.parse(original), chats: [null] }),
  ];
  const duplicate = JSON.parse(original);
  duplicate.chats.push(duplicate.chats[0]);
  invalid.push(JSON.stringify(duplicate));
  const missingChat = JSON.parse(original);
  missingChat.messages[0].chatId = 'unknown';
  invalid.push(JSON.stringify(missingChat));
  for (const raw of invalid) {
    assert.equal(repo.restore(raw), false);
    assert.equal(repo.serialize(), original);
  }
});

test('draft input is bounded and unknown conversations do not create draft records', () => {
  const repo = new ChatRepository();
  const chat = writable(repo);
  repo.setDraft(chat.id, 'a'.repeat(5000));
  assert.equal(repo.getDraft(chat.id).length, 4096);
  repo.setDraft('unknown', 'private draft');
  assert.equal(repo.getDraft('unknown'), '');
  repo.setDraft(chat.id, '');
  assert.equal(repo.getDraft(chat.id), '');
});

test('contact navigation reuses existing conversations and handles missing contacts', () => {
  const repo = new ChatRepository();
  const contact = repo.getContacts()[0];
  const id = repo.openContact(contact.id);
  assert.ok(id);
  assert.equal(repo.openContact(contact.id), id);
  assert.equal(repo.getChats().filter(chat => chat.id === id).length, 1);
  assert.equal(repo.openContact('not-a-contact'), '');
});

test('TDLib ordering preserves 64-bit position strings without numeric precision loss', () => {
  const repo = new ChatRepository();
  const template = writable(repo);
  repo.useRemoteData();
  repo.upsertChat({ ...template, id: '1', order: '9223372036854775806' });
  repo.upsertChat({ ...template, id: '2', order: '9223372036854775807' });
  repo.upsertChat({ ...template, id: '3', order: '999' });
  assert.deepEqual(repo.getChats().map(chat => chat.id), ['2', '1', '3']);
});

test('replacing a temporary message is scoped to its chat', () => {
  const repo = new ChatRepository();
  repo.useRemoteData();
  const pending = { id: '-1', chatId: '100', text: 'one', time: '10:00', outgoing: true, status: 'pending' };
  repo.upsertMessage(pending);
  repo.upsertMessage({ ...pending, chatId: '200', text: 'two' });
  repo.upsertMessage({ ...pending, id: '10', status: 'sent' }, '-1');
  assert.deepEqual(repo.getMessages('100').map(message => [message.id, message.status]), [['10', 'sent']]);
  assert.deepEqual(repo.getMessages('200').map(message => message.text), ['two']);
});
