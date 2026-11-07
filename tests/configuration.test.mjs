import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

const generator = path.resolve(import.meta.dirname, '../scripts/configure-telegram.mjs');
// Synthetic values are assembled at runtime; no real application identity belongs here.
const fixture = { apiId: 7310923, apiHash: 'a1'.repeat(16) };

function sandbox(t, config) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'harlgram-config-test-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const local = path.join(root, 'config/telegram.local.json');
  const generated = path.join(root, 'entry/src/main/ets/config/TelegramBuildConfig.ets');
  if (config !== undefined) {
    fs.mkdirSync(path.dirname(local), { recursive: true });
    fs.writeFileSync(local, JSON.stringify(config), { mode: 0o600 });
  }
  return {
    root, local, generated,
    run(mode = 'debug') {
      const result = spawnSync(process.execPath, [generator, mode], {
        env: { ...process.env, HARLGRAM_ROOT: root }, encoding: 'utf8', timeout: 10000
      });
      assert.ifError(result.error);
      return { status: result.status, output: result.stdout + result.stderr };
    }
  };
}

function assertNoCredentials(output, config = fixture) {
  assert.equal(output.includes(String(config.apiId)), false, 'stdout/stderr must not expose the application ID');
  assert.equal(output.includes(config.apiHash), false, 'stdout/stderr must not expose the application hash');
}

const presetMarker = 'export const TELEGRAM_API_PRESETS: TelegramApiPreset[] = ';

/**
 * Reads the preset array back from the generated ArkTS source. The generated file is not a module
 * the test can import, so the literal after the declaration marker is evaluated as data.
 */
function generatedPresets(source) {
  const start = source.indexOf(presetMarker);
  assert.notEqual(start, -1, 'the generated file must declare TELEGRAM_API_PRESETS');
  const rest = source.slice(start + presetMarker.length);
  const end = rest.indexOf(';\nexport const TELEGRAM_API_ID');
  assert.notEqual(end, -1, 'the preset array must be followed by the derived application ID');
  return new Function(`return (${rest.slice(0, end)});`)();
}

/** The legacy constants must stay derived from the first preset instead of being literals. */
function assertDerivedFromFirstPreset(source) {
  assert.match(source, /export const TELEGRAM_API_ID: number = TELEGRAM_API_PRESETS\.length > 0 \? TELEGRAM_API_PRESETS\[0\]\.id : 0;/);
  assert.match(source, /export const TELEGRAM_API_HASH: string = TELEGRAM_API_PRESETS\.length > 0 \? TELEGRAM_API_PRESETS\[0\]\.hash : '';/);
}

test('missing local configuration generates an inert debug configuration', t => {
  const env = sandbox(t);
  const result = env.run();
  assert.equal(result.status, 0);
  const source = fs.readFileSync(env.generated, 'utf8');
  assert.deepEqual(generatedPresets(source), [], 'an unconfigured build must not ship API presets');
  assertDerivedFromFirstPreset(source);
  assert.equal(fs.existsSync(env.local), false, 'the generator must not create a private input file');
});

test('empty example configuration is allowed for debug but rejected for release', t => {
  const env = sandbox(t, { apiId: 0, apiHash: '' });
  assert.equal(env.run('debug').status, 0);
  assert.deepEqual(generatedPresets(fs.readFileSync(env.generated, 'utf8')), [], 'an empty identity is not a preset');
  assert.notEqual(env.run('release').status, 0);
});

test('missing local configuration cannot produce a release configuration', t => {
  const env = sandbox(t);
  assert.notEqual(env.run('release').status, 0);
  assert.equal(fs.existsSync(env.generated), false);
});

test('valid private configuration generates correct constants without logging credentials', t => {
  const env = sandbox(t, fixture);
  const input = fs.readFileSync(env.local, 'utf8');
  const result = env.run();
  assert.equal(result.status, 0);
  assertNoCredentials(result.output);
  const source = fs.readFileSync(env.generated, 'utf8');
  assert.deepEqual(generatedPresets(source), [{ id: fixture.apiId, hash: fixture.apiHash, label: '' }],
    'a legacy apiId/apiHash pair becomes the only preset');
  assertDerivedFromFirstPreset(source);
  assert.equal(fs.readFileSync(env.local, 'utf8'), input, 'the private input file must remain unchanged');
  if (process.platform !== 'win32') {
    assert.equal(fs.statSync(env.generated).mode & 0o077, 0, 'newly generated config must not be readable by other users');
  }
});

test('multiple API presets keep their configured order and derive constants from the first one', t => {
  // The legacy pair must be ignored once an explicit preset list is present.
  const legacy = { apiId: 900001, apiHash: 'f'.repeat(32) };
  const presets = [
    { id: 1000001, hash: 'c'.repeat(32) },
    { id: 2000002, hash: 'd'.repeat(32), label: '第二组' },
    { id: 3000003, hash: 'e'.repeat(32), label: '第三组' }
  ];
  const env = sandbox(t, { ...legacy, presets });
  const result = env.run();
  assert.equal(result.status, 0);
  for (const preset of presets) {
    assert.equal(result.output.includes(preset.hash), false, 'diagnostics must not expose preset hashes');
  }
  assert.equal(result.output.includes(String(legacy.apiId)), false, 'an ignored legacy ID must not be reported');
  assert.equal(result.output.includes(legacy.apiHash), false, 'an ignored legacy hash must not be reported');
  assert.ok(result.output.includes(`共 ${presets.length} 组`), 'the summary may report the preset count');
  const source = fs.readFileSync(env.generated, 'utf8');
  assert.deepEqual(generatedPresets(source), [
    { id: presets[0].id, hash: presets[0].hash, label: '' },
    { id: presets[1].id, hash: presets[1].hash, label: presets[1].label },
    { id: presets[2].id, hash: presets[2].hash, label: presets[2].label }
  ], 'presets must be generated in the configured order with sanitized labels');
  assertDerivedFromFirstPreset(source);
  assert.equal(source.includes(`id: ${presets[1].id}`), true, 'later presets must be part of the generated file');
});

test('developer-owned configuration is accepted for release', t => {
  const env = sandbox(t, fixture);
  const result = env.run('release');
  assert.equal(result.status, 0);
  assertNoCredentials(result.output);
});

test('the upstream application ID is rejected by the release guard', t => {
  const env = sandbox(t, { apiId: 4, apiHash: fixture.apiHash });
  const result = env.run('release');
  assert.notEqual(result.status, 0);
  assert.equal(result.output.includes(fixture.apiHash), false);
  assert.equal(fs.existsSync(env.generated), false);
});

test('invalid configuration shapes and values are rejected without generating code', async t => {
  const invalid = [
    ['null', null],
    ['array', []],
    ['missing properties', {}],
    ['string ID', { apiId: String(fixture.apiId), apiHash: fixture.apiHash }],
    ['negative ID', { apiId: -1, apiHash: fixture.apiHash }],
    ['fractional ID', { apiId: 1.5, apiHash: fixture.apiHash }],
    ['out-of-range ID', { apiId: 2147483648, apiHash: fixture.apiHash }],
    ['short hash', { apiId: fixture.apiId, apiHash: 'ab' }],
    ['non-hex hash', { apiId: fixture.apiId, apiHash: 'z'.repeat(32) }],
    ['array hash', { apiId: fixture.apiId, apiHash: [fixture.apiHash] }],
    ['object hash', { apiId: fixture.apiId, apiHash: { value: fixture.apiHash } }]
  ];
  for (const [name, value] of invalid) {
    await t.test(name, child => {
      const env = sandbox(child, value);
      const result = env.run();
      assert.notEqual(result.status, 0);
      assert.equal(result.output.includes(fixture.apiHash), false);
      assert.equal(fs.existsSync(env.generated), false);
    });
  }
});

test('invalid preset lists are rejected without echoing preset values', async t => {
  const rejectedHash = 'z'.repeat(32);
  const invalid = [
    ['presets is not an array', /presets 字段应为数组/, { apiId: 0, apiHash: '', presets: 'not-an-array' }],
    ['preset entry is not an object', /第 1 组预设应为对象/, { apiId: 0, apiHash: '', presets: ['entry'] }],
    ['preset ID out of range', /第 1 组预设的 id 应为/, { apiId: 0, apiHash: '', presets: [{ id: 0, hash: fixture.apiHash }] }],
    ['preset hash is not hex', /第 1 组预设的 hash 应为/, { apiId: 0, apiHash: '', presets: [{ id: fixture.apiId, hash: rejectedHash }] }],
    ['preset label has a wrong type', /第 1 组预设的 label 类型不正确/,
      { apiId: 0, apiHash: '', presets: [{ id: fixture.apiId, hash: fixture.apiHash, label: { value: 'x' } }] }],
    ['too many presets', /presets 最多支持 20 组/,
      { apiId: 0, apiHash: '', presets: Array.from({ length: 21 }, (_, index) => ({ id: fixture.apiId + index, hash: fixture.apiHash })) }]
  ];
  for (const [name, message, value] of invalid) {
    await t.test(name, child => {
      const env = sandbox(child, value);
      const result = env.run();
      assert.notEqual(result.status, 0);
      assert.match(result.output, message);
      assert.equal(result.output.includes(fixture.apiHash), false, 'diagnostics must not echo the preset hash');
      assert.equal(result.output.includes(rejectedHash), false, 'diagnostics must not echo the rejected hash');
      assert.equal(fs.existsSync(env.generated), false);
    });
  }
});

test('malformed private JSON cannot leak source snippets into diagnostics', t => {
  const env = sandbox(t, fixture);
  const privateMarker = 'SENSITIVE_TOKEN_FIXTURE_DO_NOT_LOG';
  fs.writeFileSync(env.local, `${privateMarker} invalid json`);
  const result = env.run();
  assert.notEqual(result.status, 0);
  assert.equal(result.output.includes('SENSITIVE_TOKEN'), false);
  assert.equal(fs.existsSync(env.generated), false);
});

test('invalid input leaves an existing generated configuration unchanged', t => {
  const env = sandbox(t, fixture);
  assert.equal(env.run().status, 0);
  const previous = fs.readFileSync(env.generated, 'utf8');
  fs.writeFileSync(env.local, JSON.stringify({ apiId: -1, apiHash: fixture.apiHash }));
  const result = env.run();
  assert.notEqual(result.status, 0);
  assertNoCredentials(result.output);
  assert.equal(fs.readFileSync(env.generated, 'utf8'), previous);
});
