import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const ts = require(process.env.HARLGRAM_TYPESCRIPT);
const source = fs.readFileSync(new URL('../entry/src/main/ets/model/Appearance.ts', import.meta.url), 'utf8');
const result = ts.transpileModule(source, {
  compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }
});
const module = { exports: {} };
new Function('exports', 'module', result.outputText)(module.exports, module);
const { migrateAppearanceMode, AppearanceState } = module.exports;

test('fresh installs follow system while legacy explicit light and dark choices remain intact', () => {
  assert.equal(migrateAppearanceMode('', ''), 'system');
  assert.equal(migrateAppearanceMode('', JSON.stringify({ darkMode: true, messages: [{ text: 'fictional fixture' }] })), 'dark');
  assert.equal(migrateAppearanceMode('', JSON.stringify({ darkMode: false })), 'light');
  for (const legacy of ['{', 'null', '[]', 'true', '{"darkMode":"true"}', '{}']) {
    assert.equal(migrateAppearanceMode('', legacy), 'system');
  }
});

test('independent appearance preference takes precedence over stale demo snapshot flags', () => {
  for (const mode of ['system', 'light', 'dark']) {
    assert.equal(migrateAppearanceMode(mode, '{"darkMode":true}'), mode);
    assert.equal(migrateAppearanceMode(mode, '{"darkMode":false}'), mode);
  }
  assert.equal(migrateAppearanceMode('unsupported', '{"darkMode":true}'), 'dark');
  assert.equal(migrateAppearanceMode('unsupported', ''), 'system');
});

test('system changes never replace a fixed choice and switching to system uses the latest observed value', () => {
  const state = new AppearanceState();
  state.updateSystemDark(true); assert.equal(state.isDark(), true);
  state.select('light'); state.updateSystemDark(true);
  assert.equal(state.getMode(), 'light'); assert.equal(state.isDark(), false);
  state.select('dark'); state.updateSystemDark(false);
  assert.equal(state.getMode(), 'dark'); assert.equal(state.isDark(), true);
  state.select('system'); assert.equal(state.isDark(), false);
  state.updateSystemDark(true); assert.equal(state.isDark(), true); assert.equal(state.getMode(), 'system');
});

test('late preference restoration cannot overwrite a newer selection, including explicit system', () => {
  const state = new AppearanceState();
  const initialRevision = state.selectionRevision();
  state.restore('dark', initialRevision); assert.equal(state.getMode(), 'dark');
  const pendingReadRevision = state.selectionRevision();
  state.select('light'); state.select('system');
  state.restore('dark', pendingReadRevision);
  assert.equal(state.getMode(), 'system');
});
