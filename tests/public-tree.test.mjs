import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { deflateSync } from 'node:zlib';

const checker = path.resolve(import.meta.dirname, '../scripts/check-public-tree.py');
const stripper = path.resolve(import.meta.dirname, '../scripts/strip-image-metadata.py');
const pngSignature = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);

function pngChunk(kind, payload = Buffer.alloc(0)) {
  const chunk = Buffer.alloc(payload.length + 12);
  chunk.writeUInt32BE(payload.length, 0);
  chunk.write(kind, 4, 4, 'ascii');
  payload.copy(chunk, 8);
  let crc = 0xffffffff;
  for (const byte of chunk.subarray(4, -4)) {
    crc ^= byte;
    for (let bit = 0; bit < 8; bit++) {
      crc = (crc >>> 1) ^ ((crc & 1) ? 0xedb88320 : 0);
    }
  }
  chunk.writeUInt32BE((crc ^ 0xffffffff) >>> 0, chunk.length - 4);
  return chunk;
}

const ihdrPayload = Buffer.alloc(13);
ihdrPayload.writeUInt32BE(1, 0);
ihdrPayload.writeUInt32BE(1, 4);
ihdrPayload[8] = 8;
ihdrPayload[9] = 6;
const ihdr = pngChunk('IHDR', ihdrPayload);
const compressedPixel = deflateSync(Buffer.from([0, 0, 0, 0, 255]));
const idat = pngChunk('IDAT', compressedPixel);
const iend = pngChunk('IEND');
const png = Buffer.concat([pngSignature, ihdr, idat, iend]);

function bomText(text, encoding) {
  const littleEndian = encoding.endsWith('le');
  if (encoding.startsWith('utf16')) {
    const data = Buffer.from(text, 'utf16le');
    return Buffer.concat([Buffer.from(littleEndian ? [255, 254] : [254, 255]), littleEndian ? data : data.swap16()]);
  }
  const codePoints = [...text].map(character => character.codePointAt(0));
  const data = Buffer.alloc(4 + codePoints.length * 4);
  const write = littleEndian ? data.writeUInt32LE.bind(data) : data.writeUInt32BE.bind(data);
  write(0xfeff, 0);
  codePoints.forEach((codePoint, index) => write(codePoint, 4 + index * 4));
  return data;
}

function sandbox(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'harlgram-public-test-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const run = (cmd, argv) => {
    const r = spawnSync(cmd, argv, { cwd: root, encoding: 'utf8' });
    assert.ifError(r.error);
    return { status: r.status, output: r.stdout + r.stderr };
  };
  assert.equal(run('git', ['init', '-q']).status, 0);
  const write = (name, data) => {
    fs.mkdirSync(path.dirname(path.join(root, name)), { recursive: true });
    fs.writeFileSync(path.join(root, name), data);
  };
  write('scripts/check-public-tree.py', fs.readFileSync(checker));
  const stage = (name, force = false) => assert.equal(run('git', ['add', ...(force ? ['-f'] : []), '--', name]).status, 0);
  const check = () => run('python3', ['scripts/check-public-tree.py', '--staged']);
  const manifest = (bytes, name = 'website/example.png') => write('config/public-assets.json', JSON.stringify({ sha256: { [name]: crypto.createHash('sha256').update(bytes).digest('hex') } }));
  const reviewedAsset = (bytes, name = 'website/example.png') => {
    write(name, bytes); stage(name);
    manifest(bytes, name); stage('config/public-assets.json');
  };
  return { root, run, write, stage, check, manifest, reviewedAsset };
}

test('public scanner uses indexed content and cannot be bypassed by an unstaged cleanup', t => {
  const s = sandbox(t);
  const secret = 'ghp_' + 'A'.repeat(36);
  s.write('notes.md', secret); s.stage('notes.md');
  s.write('notes.md', 'No secrets in working copy');
  const result = s.check();
  assert.notEqual(result.status, 0);
  assert.equal(result.output.includes(secret), false);
  s.stage('notes.md');
  assert.equal(s.check().status, 0);
});

test('force-tracked private files and home paths are rejected without printing contents', t => {
  const s = sandbox(t);
  s.write('.env', 'SECRET=value'); s.stage('.env');
  s.write('notes.md', '/' + 'Users/private-person/project'); s.stage('notes.md');
  const result = s.check();
  assert.notEqual(result.status, 0);
  assert.equal(result.output.includes('private-person'), false);
  assert.equal(result.output.includes('SECRET=value'), false);
});

test('local API secrets are detected even in large binary metadata', t => {
  const s = sandbox(t);
  const hash = 'c3'.repeat(16);
  s.write('config/telegram.local.json', JSON.stringify({ apiId: 0, apiHash: hash }));
  s.write('large.dat', Buffer.concat([Buffer.alloc(2_000_001), Buffer.from(hash)]));
  s.stage('large.dat');
  const result = s.check();
  assert.notEqual(result.status, 0);
  assert.equal(result.output.includes(hash), false);
});

test('new or changed images need the matching indexed public review manifest', t => {
  const s = sandbox(t);
  s.write('website/example.png', png); s.stage('website/example.png');
  assert.notEqual(s.check().status, 0);
  s.manifest(png);
  assert.notEqual(s.check().status, 0, 'an unstaged manifest cannot approve an indexed image');
  s.stage('config/public-assets.json');
  assert.equal(s.check().status, 0);
  const trailing = Buffer.concat([png, Buffer.from('private trailing content')]);
  s.reviewedAsset(trailing);
  assert.notEqual(s.check().status, 0, 'a matching manifest must not approve bytes after IEND');
});

test('PNG metadata is forbidden even when its image hash was added to the manifest', t => {
  const s = sandbox(t);
  const chunk = pngChunk('tEXt', Buffer.from('Comment\0synthetic metadata'));
  const annotated = Buffer.concat([png.subarray(0, -12), chunk, png.subarray(-12)]);
  s.reviewedAsset(annotated);
  assert.notEqual(s.check().status, 0);
});

const malformedPngs = [
  ['bad chunk CRC', () => {
    const damaged = Buffer.from(png);
    damaged[pngSignature.length + ihdr.length - 1] ^= 1;
    return damaged;
  }],
  ['missing IEND', () => png.subarray(0, -iend.length)],
  ['nonempty IEND', () => Buffer.concat([pngSignature, ihdr, idat, pngChunk('IEND', Buffer.from([0]))])],
  ['oversized sRGB payload', () => Buffer.concat([pngSignature, ihdr, pngChunk('sRGB', Buffer.from([0, 1])), idat, iend])],
  ['bytes after the IDAT zlib stream', () => Buffer.concat([
    pngSignature, ihdr, pngChunk('IDAT', Buffer.concat([compressedPixel, Buffer.from('synthetic trailing bytes')])), iend
  ])]
];

for (const [name, bytes] of malformedPngs) {
  test(`PNG ${name} is rejected despite a matching indexed manifest`, t => {
    const s = sandbox(t);
    s.reviewedAsset(bytes());
    const result = s.check();
    assert.notEqual(result.status, 0, result.output);
    assert.doesNotMatch(result.output, /image is not in the reviewed public asset manifest/);
  });
}

for (const filename of ['website/disguised.txt', 'website/disguised', 'website/disguised.jpg']) {
  test(`PNG magic is rejected under the non-PNG filename ${filename}`, t => {
    const s = sandbox(t);
    s.reviewedAsset(png, filename);
    assert.notEqual(s.check().status, 0);
  });
}

const forbiddenBinaryAssets = [
  ['JPEG', 'website/example.jpg', Buffer.from([255, 216, 255, 224, 0, 16, 74, 70, 73, 70, 0, 255, 217])],
  ['GIF', 'website/example.gif', Buffer.from('47494638396101000100800000000000ffffff2c00000000010001000002024401003b', 'hex')],
  ['WebP', 'website/example.webp', Buffer.from('5249464614000000574542505650384c070000002f00000000000700', 'hex')],
  ['opaque binary', 'notes.dat', Buffer.from([0, 129, 254, 0, 255, 128])],
  ['ZIP', 'notes.zip', Buffer.concat([Buffer.from([80, 75, 5, 6]), Buffer.alloc(18)])],
  ['disguised ZIP', 'notes.txt', Buffer.concat([Buffer.from([80, 75, 5, 6]), Buffer.alloc(18)])]
];

for (const [name, filename, bytes] of forbiddenBinaryAssets) {
  test(`${name} is rejected even with a matching indexed asset manifest`, t => {
    const s = sandbox(t);
    s.reviewedAsset(bytes, filename);
    assert.notEqual(s.check().status, 0);
  });
}

test('force-tracked .DS_Store is rejected even when its contents look like harmless text', t => {
  const s = sandbox(t);
  s.write('.gitignore', '.DS_Store\n'); s.stage('.gitignore');
  s.write('website/.DS_Store', 'synthetic finder metadata'); s.stage('website/.DS_Store', true);
  assert.notEqual(s.check().status, 0);
});

for (const encoding of ['utf16le', 'utf16be', 'utf32le', 'utf32be']) {
  for (const field of ['apiHash', 'api_hash', 'TELEGRAM_API_HASH']) {
    test(`${encoding} BOM text is inspected for ${field} without printing its value`, t => {
      const s = sandbox(t);
      const syntheticSecret = 'd4'.repeat(16);
      s.write('notes.txt', bomText(JSON.stringify({ [field]: syntheticSecret }), encoding)); s.stage('notes.txt');
      const result = s.check();
      assert.notEqual(result.status, 0);
      assert.match(result.output, /Telegram application secret/);
      assert.equal(result.output.includes(syntheticSecret), false);
    });
  }

  test(`clean ${encoding} BOM text remains publishable`, t => {
    const s = sandbox(t);
    s.write('notes.txt', bomText('公开说明：synthetic clean text\n', encoding)); s.stage('notes.txt');
    const result = s.check();
    assert.equal(result.status, 0, result.output);
  });
}

for (const keyType of ['ENCRYPTED PRIVATE KEY', 'DSA PRIVATE KEY', 'PGP PRIVATE KEY BLOCK']) {
  test(`${keyType} header is rejected without printing its synthetic body`, t => {
    const s = sandbox(t);
    const syntheticSecret = 'synthetic-private-material';
    s.write('notes.txt', `-----BEGIN ${keyType}-----\n${syntheticSecret}\n-----END ${keyType}-----\n`); s.stage('notes.txt');
    const result = s.check();
    assert.notEqual(result.status, 0);
    assert.match(result.output, /private key/);
    assert.equal(result.output.includes(syntheticSecret), false);
  });
}

test('PNG sanitation leaves already clean compressed image bytes unchanged', t => {
  const s = sandbox(t);
  s.write('clean.png', png);
  const result = s.run('python3', [stripper, 'clean.png']);
  assert.equal(result.status, 0, result.output);
  assert.deepEqual(fs.readFileSync(path.join(s.root, 'clean.png')), png);
});
