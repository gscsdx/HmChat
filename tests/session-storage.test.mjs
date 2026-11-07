import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const ts = require(process.env.HARLGRAM_TYPESCRIPT);
const filename = new URL('../entry/src/main/ets/model/SessionStorage.ts', import.meta.url);
const result = ts.transpileModule(fs.readFileSync(filename, 'utf8'), {
  compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }
});
const model = { exports: {} };
new Function('exports', 'module', result.outputText)(model.exports, model);
const { selectSessionStorage, sessionStorageDirectory } = model.exports;
const unused = () => { throw new Error('must not generate new identity'); };

test('existing legacy credentials retain their key and original directory', () => {
  const previous = { encryptionKey: 'fixture-existing-key' };
  const current = selectSessionStorage(previous, false, unused, unused);
  assert.equal(current.encryptionKey, previous.encryptionKey);
  assert.equal(current.databaseNamespace, undefined);
  assert.equal(sessionStorageDirectory('/fixture/files', current.databaseNamespace), '/fixture/files/telegram');
  assert.equal(previous.databaseNamespace, undefined);
});

test('missing credentials get a new key and namespace instead of reusing the legacy database', () => {
  const namespace = 'a1'.repeat(16);
  const current = selectSessionStorage(undefined, false, () => 'fixture-new-key', () => namespace);
  assert.equal(current.encryptionKey, 'fixture-new-key');
  assert.equal(current.databaseNamespace, namespace);
  assert.equal(sessionStorageDirectory('/fixture/files/', current.databaseNamespace), '/fixture/files/telegram/session-' + namespace);
});

test('storage recovery preserves the key, changes namespace, and rejects invalid or repeated destinations', () => {
  const previous = { encryptionKey: 'fixture-existing-key', databaseNamespace: 'b2'.repeat(16) };
  const namespace = 'c3'.repeat(16);
  const current = selectSessionStorage(previous, true, unused, () => namespace);
  assert.equal(current.encryptionKey, previous.encryptionKey);
  assert.equal(current.databaseNamespace, namespace);
  assert.equal(previous.databaseNamespace, 'b2'.repeat(16));
  assert.throws(() => selectSessionStorage(previous, true, unused, () => previous.databaseNamespace));
  for (const invalid of ['', '../legacy', null, 'g'.repeat(32)]) {
    assert.throws(() => sessionStorageDirectory('/fixture/files', invalid));
    assert.throws(() => selectSessionStorage({ ...previous, databaseNamespace: invalid }, false, unused, unused));
  }
});
