import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import { spawnSync } from 'node:child_process';

const checker = path.resolve(import.meta.dirname, '../scripts/ci/verify-hap.py');
// Windows Python installs are normally exposed as `python`; the Store alias
// `python3` may be a non-functional placeholder.
const python = process.env.HARLGRAM_PYTHON
  ?? (process.platform === 'win32' ? 'python' : 'python3');
const libraries = [
  'libentry.so', 'libtdjson.so', 'libc++_shared.so',
  'libclash_bridge.so', 'libclash_core.so'
];
const clashLicenses = [
  'FlClashX-GPL-3.0.txt', 'mihomo.txt', 'sing-tun.txt', 'Go.txt', 'Clash-Notices.txt'
];
const licenses = [
  'TDLib.txt', 'OpenSSL.txt', 'SQLCipher.txt', 'LLVM.txt', 'Libphonenumber.txt',
  'Unicode-CLDR.txt', 'Harlgram-GPL-3.0.txt', 'Harlgram-Notices.txt',
  ...clashLicenses
];
const exports = ['td_create_client_id', 'td_send', 'td_receive', 'td_execute'];
const clashExports = [
  'registerCallbacks', 'setEventListener', 'invokeAction', 'initClashSync',
  'startTUN', 'freeCString'
];
const privateMarker = 'SYNTHETIC_TOOL_PRIVATE_OUTPUT_DO_NOT_LOG';

function licensePath(name) {
  return clashLicenses.includes(name)
    ? `resources/rawfile/clash/licenses/${name}`
    : `resources/rawfile/licenses/${name}`;
}

// These headers and fake LLVM programs test the gate's CLI and rejection paths.
// They are not valid loadable shared objects and cannot establish real ELF or SDK compatibility.
function elfHeader() {
  const header = Buffer.alloc(64);
  Buffer.from([0x7f, 0x45, 0x4c, 0x46, 2, 1, 1]).copy(header);
  header.writeUInt16LE(3, 16); // ET_DYN
  header.writeUInt16LE(183, 18); // EM_AARCH64
  header.writeUInt32LE(1, 20);
  header.writeUInt16LE(64, 52);
  return header;
}

function completeEntries() {
  return [
    ...libraries.map(name => ({ name: `libs/arm64-v8a/${name}`, bytes: elfHeader() })),
    ...licenses.map(name => ({
      name: licensePath(name), bytes: Buffer.from(`Synthetic ${name} license fixture\n`)
    }))
  ];
}

const zipWriter = `
import base64, json, sys, warnings, zipfile
warnings.simplefilter('ignore', UserWarning)
with zipfile.ZipFile(sys.argv[1], 'w', compression=zipfile.ZIP_DEFLATED) as archive:
    for entry in json.load(sys.stdin):
        info = zipfile.ZipInfo(entry['name'], (2024, 1, 1, 0, 0, 0))
        archive.writestr(info, base64.b64decode(entry['bytes']))
`;

const fakeLlvm = `#!/usr/bin/env python3
import json, pathlib, sys
tool_dir = pathlib.Path(__file__).parent
config = json.loads((tool_dir / 'fixture.json').read_text())
tool = pathlib.Path(__file__).name.removesuffix('.exe')
with (tool_dir / 'calls.jsonl').open('a') as log:
    log.write(json.dumps({'tool': tool, 'args': sys.argv[1:]}) + '\\n')
if config.get('fail_tool') == tool:
    print(config['private_marker'])
    print(config['private_marker'] + ' ' + str(tool_dir), file=sys.stderr)
    sys.exit(9)
if config.get('warn_tool') == tool:
    print(config['private_marker'] + ' ' + str(tool_dir), file=sys.stderr)
library = pathlib.Path(sys.argv[-1]).name
dynamic = config.get('dynamic', {}).get(library, {})
if tool == 'llvm-readelf':
    if not {'--file-header', '--dynamic'}.issubset(sys.argv[1:]):
        sys.exit(10)
    header = config.get('readelf_header', {}).get(library, {})
    print('ELF Header:')
    print('  Class:                             ' + header.get('class', 'ELF64'))
    print('  Data:                              ' + header.get('data', "2's complement, little endian"))
    print('  Type:                              ' + header.get('type', 'DYN (Shared object file)'))
    print('  Machine:                           ' + header.get('machine', 'AArch64'))
    print('Dynamic section at offset 0x40 contains 1 entries:')
    if 'soname' in dynamic:
        soname = dynamic['soname']
    elif library == 'libtdjson.so':
        soname = config.get('soname', 'libtdjson.so')
    else:
        soname = library
    if soname is not None:
        print('  0x000000000000000e (SONAME) Library soname: [' + soname + ']')
    needed = dynamic.get('needed', config.get('needed', {}).get(library, []))
    for entry in needed:
        print('  0x0000000000000001 (NEEDED) Shared library: [' + entry + ']')
    if dynamic.get('runpath') is not None:
        print('  0x000000000000001d (RUNPATH) Library runpath: [' + dynamic['runpath'] + ']')
    if dynamic.get('rpath') is not None:
        print('  0x000000000000000f (RPATH) Library rpath: [' + dynamic['rpath'] + ']')
elif tool == 'llvm-nm':
    if not {'--dynamic', '--defined-only', '--extern-only', '--format=posix'}.issubset(sys.argv[1:]):
        sys.exit(11)
    library_symbols = config.get('library_symbols', {}).get(library)
    if library_symbols is None:
        if library == 'libtdjson.so' and 'symbols' in config:
            library_symbols = config['symbols']
        else:
            library_symbols = config.get('default_symbols', {}).get(library, [])
    for name, kind in library_symbols:
        print(name + ' ' + kind + ' 1000 10')
else:
    sys.exit(12)
`;

function invokeChecker(root, args) {
  const result = spawnSync(python, [checker, ...args], {
    cwd: root, encoding: 'utf8', timeout: 10000
  });
  assert.ifError(result.error);
  return { status: result.status, output: result.stdout + result.stderr };
}

function sandbox(t, options = {}) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'harlgram hap private path '));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const hap = path.join(root, 'synthetic input package.hap');
  const sdk = path.join(root, 'native sdk with spaces');
  const llvm = path.join(sdk, 'llvm/bin');
  fs.mkdirSync(llvm, { recursive: true });
  fs.writeFileSync(path.join(llvm, 'fixture.json'), JSON.stringify({
    private_marker: privateMarker,
    default_symbols: {
      'libtdjson.so': exports.map(name => [name, 'T']),
      'libclash_core.so': clashExports.map(name => [name, 'T'])
    },
    needed: {
      'libentry.so': ['libtdjson.so', 'libclash_bridge.so'],
      'libtdjson.so': ['libc++_shared.so'],
      'libc++_shared.so': [],
      'libclash_bridge.so': ['libclash_core.so', 'libc++_shared.so'],
      'libclash_core.so': ['libc++_shared.so']
    },
    ...options
  }));
  for (const name of ['llvm-readelf', 'llvm-nm']) {
    fs.writeFileSync(path.join(llvm, name + (options.exeSuffix ? '.exe' : '')), fakeLlvm, { mode: 0o755 });
  }
  function write(entries = completeEntries()) {
    const result = spawnSync(python, ['-c', zipWriter, hap], {
      input: JSON.stringify(entries.map(entry => ({ name: entry.name, bytes: entry.bytes.toString('base64') }))),
      encoding: 'utf8', timeout: 10000
    });
    assert.ifError(result.error);
    assert.equal(result.status, 0, result.stderr);
  }
  write();
  return {
    root, hap, sdk, llvm, write,
    run(extra = [], useSdk = false) {
      return invokeChecker(root, [
        '--hap', hap, useSdk ? '--native-sdk' : '--llvm-bin', useSdk ? sdk : llvm, ...extra
      ]);
    },
    calls() {
      const log = path.join(llvm, 'calls.jsonl');
      return fs.existsSync(log) ? fs.readFileSync(log, 'utf8').trim().split('\n').map(line => JSON.parse(line)) : [];
    }
  };
}

function assertRejected(result, sandbox) {
  assert.equal(result.status, 1, result.output);
  assert.equal(result.output.includes(privateMarker), false, 'tool output must not expose synthetic private content');
  assert.equal(result.output.includes(sandbox.root), false, 'diagnostics must not expose private absolute paths');
}

test('HAP gate accepts its synthetic contract via SDK paths with spaces and reports the unchanged SHA-256', t => {
  const s = sandbox(t);
  const before = fs.readFileSync(s.hap);
  const sha256 = crypto.createHash('sha256').update(before).digest('hex');
  fs.chmodSync(s.hap, 0o444);
  const result = s.run([], true);
  assert.equal(result.status, 0, result.output);
  assert.match(result.output, /SHA-?256/i);
  assert.ok(result.output.includes(sha256), 'the summary must identify the exact input package');
  assert.equal(result.output.includes(s.root), false);
  assert.deepEqual(fs.readFileSync(s.hap), before, 'verification must not rewrite its read-only input');
  if (process.platform !== 'win32') assert.equal(fs.statSync(s.hap).mode & 0o777, 0o444);

  const calls = s.calls();
  const readelf = calls.filter(call => call.tool === 'llvm-readelf');
  assert.deepEqual(readelf.map(call => path.basename(call.args.at(-1))).sort(), [...libraries].sort());
  for (const call of readelf) {
    assert.ok(call.args.includes('--file-header'));
    assert.ok(call.args.includes('--dynamic'));
  }
  const nm = calls.filter(call => call.tool === 'llvm-nm');
  assert.deepEqual(nm.map(call => path.basename(call.args.at(-1))).sort(),
    ['libclash_core.so', 'libtdjson.so']);
  for (const call of nm) {
    for (const option of ['--dynamic', '--defined-only', '--extern-only', '--format=posix']) {
      assert.ok(call.args.includes(option));
    }
  }
});

test('HAP gate accepts weak defined exports and an explicit LLVM directory', t => {
  const s = sandbox(t, { symbols: exports.map(name => [name, 'W']) });
  const result = s.run();
  assert.equal(result.status, 0, result.output);
});

test('HAP gate resolves executable names with the .exe suffix', t => {
  const s = sandbox(t, { exeSuffix: true });
  const result = s.run([], true);
  assert.equal(result.status, 0, result.output);
});

test('HAP gate preserves the llvm-readelf multicall symlink name', { skip: process.platform === 'win32' }, t => {
  const s = sandbox(t);
  fs.renameSync(path.join(s.llvm, 'llvm-readelf'), path.join(s.llvm, 'llvm-readobj'));
  fs.symlinkSync('llvm-readobj', path.join(s.llvm, 'llvm-readelf'));
  const result = s.run([], true);
  assert.equal(result.status, 0, result.output);
  assert.equal(s.calls().some(call => call.tool === 'llvm-readobj'), false,
    'resolving the symlink changes the multicall tool output format');
});

for (const [description, argumentsFor] of [
  ['missing explicit HAP', s => ['--llvm-bin', s.llvm]],
  ['missing tool directory', s => ['--hap', s.hap]],
  ['conflicting tool selectors', s => ['--hap', s.hap, '--llvm-bin', s.llvm, '--native-sdk', s.sdk]],
  ['unknown private argument', s => ['--hap', s.hap, '--llvm-bin', s.llvm, `--${privateMarker}`]]
]) {
  test(`HAP gate rejects ${description} without echoing argument values`, t => {
    const s = sandbox(t);
    assertRejected(invokeChecker(s.root, argumentsFor(s)), s);
  });
}

for (const name of libraries) {
  test(`HAP gate rejects a missing ${name}`, t => {
    const s = sandbox(t);
    s.write(completeEntries().filter(entry => entry.name !== `libs/arm64-v8a/${name}`));
    assertRejected(s.run(), s);
  });

  test(`HAP gate rejects duplicate archive entries for ${name}`, t => {
    const s = sandbox(t);
    s.write([...completeEntries(), { name: `libs/arm64-v8a/${name}`, bytes: elfHeader() }]);
    assertRejected(s.run(), s);
  });

  test(`HAP gate checks the AArch64 header of ${name}`, t => {
    const s = sandbox(t);
    const wrongArchitecture = elfHeader();
    wrongArchitecture.writeUInt16LE(62, 18);
    s.write(completeEntries().map(entry => entry.name === `libs/arm64-v8a/${name}`
      ? { ...entry, bytes: wrongArchitecture } : entry));
    assertRejected(s.run(), s);
  });
}

test('HAP gate does not accept TDLib under a different ABI directory', t => {
  const s = sandbox(t);
  s.write(completeEntries().map(entry => entry.name.endsWith('/libtdjson.so')
    ? { ...entry, name: 'libs/x86_64/libtdjson.so' } : entry));
  assertRejected(s.run(), s);
});

test('HAP gate rejects ambiguous native library suffixes under different prefixes', t => {
  const s = sandbox(t);
  s.write([...completeEntries(), { name: 'other/arm64-v8a/libtdjson.so', bytes: elfHeader() }]);
  const result = s.run();
  assertRejected(result, s);
  assert.match(result.output, /ambiguous required package member/i);
});

test('HAP gate rejects a sole native library under the wrong prefix', t => {
  const s = sandbox(t);
  s.write(completeEntries().map(entry => entry.name.endsWith('/libtdjson.so')
    ? { ...entry, name: 'other/arm64-v8a/libtdjson.so' } : entry));
  const result = s.run();
  assertRejected(result, s);
  assert.match(result.output, /outside the HAP native library directory/i);
});

for (const name of licenses) {
  test(`HAP gate rejects a missing ${name} license`, t => {
    const s = sandbox(t);
    s.write(completeEntries().filter(entry => !entry.name.endsWith(`/${name}`)));
    assertRejected(s.run(), s);
  });
}

for (const name of ['resources/rawfile/licenses/TDLib.txt', 'other/rawfile/licenses/TDLib.txt']) {
  test(`HAP gate rejects an ambiguous license at ${name}`, t => {
    const s = sandbox(t);
    s.write([...completeEntries(), { name, bytes: Buffer.from('Synthetic duplicate license\n') }]);
    assertRejected(s.run(), s);
  });
}

for (const name of ['TDLib.txt', 'mihomo.txt']) {
  test(`HAP gate rejects an empty required ${name} license`, t => {
    const s = sandbox(t);
    s.write(completeEntries().map(entry => entry.name.endsWith(`/${name}`)
      ? { ...entry, bytes: Buffer.alloc(0) } : entry));
    assertRejected(s.run(), s);
  });
}

test('HAP gate reads required member bytes and rejects CRC corruption without exposing their content', t => {
  const s = sandbox(t);
  const member = 'resources/rawfile/licenses/TDLib.txt';
  const content = Buffer.from(privateMarker);
  s.write(completeEntries().map(entry => entry.name === member ? { ...entry, bytes: content } : entry));
  const archive = fs.readFileSync(s.hap);
  const localHeader = archive.indexOf(Buffer.from(member)) - 30;
  assert.ok(localHeader >= 0);
  assert.equal(archive.readUInt32LE(localHeader), 0x04034b50);
  assert.equal(archive.readUInt16LE(localHeader + 8), 0, 'fixture member must use ZIP_STORED');
  const contentOffset = localHeader + 30 + archive.readUInt16LE(localHeader + 26)
    + archive.readUInt16LE(localHeader + 28);
  assert.deepEqual(archive.subarray(contentOffset, contentOffset + content.length), content);
  // Leave the ZIP metadata and its recorded CRC intact while changing license data.
  // The package remains readable as an archive; only reading this member detects corruption.
  archive[contentOffset + content.length - 1] ^= 1;
  fs.writeFileSync(s.hap, archive);
  const result = s.run();
  assertRejected(result, s);
  assert.match(result.output, /required package member is corrupt or unreadable/i);
  assert.equal(result.output.includes('SYNTHETIC_TOOL_PRIVATE_OUTPUT'), false);
});

const invalidElfHeaders = [
  ['non-ELF bytes', () => Buffer.from('Synthetic non-ELF library')],
  ['empty library', () => Buffer.alloc(0)],
  ['truncated header', () => elfHeader().subarray(0, 20)],
  ['ELF32', () => { const header = elfHeader(); header[4] = 1; return header; }],
  ['big endian', () => { const header = elfHeader(); header[5] = 2; return header; }],
  ['non-DYN type', () => { const header = elfHeader(); header.writeUInt16LE(2, 16); return header; }]
];

for (const [description, bytes] of invalidElfHeaders) {
  test(`HAP gate rejects ${description} before trusting fake LLVM success`, t => {
    const s = sandbox(t);
    s.write(completeEntries().map(entry => entry.name.endsWith('/libtdjson.so')
      ? { ...entry, bytes: bytes() } : entry));
    assertRejected(s.run(), s);
  });
}

test('HAP gate also requires LLVM to confirm the architecture', t => {
  const s = sandbox(t, { readelf_header: { 'libentry.so': { machine: 'Advanced Micro Devices X86-64' } } });
  assertRejected(s.run(), s);
});

for (const [description, bytes] of [
  ['not a ZIP', Buffer.from('Synthetic broken package')],
  ['empty file', Buffer.alloc(0)]
]) {
  test(`HAP gate rejects ${description}`, t => {
    const s = sandbox(t);
    fs.writeFileSync(s.hap, bytes);
    assertRejected(s.run(), s);
  });
}

test('HAP gate rejects an empty ZIP archive', t => {
  const s = sandbox(t);
  s.write([]);
  assertRejected(s.run(), s);
});

test('HAP gate rejects a nonexistent input without leaking its path', t => {
  const s = sandbox(t);
  fs.unlinkSync(s.hap);
  assertRejected(s.run(), s);
});

for (const soname of ['libtdjson.so.1', 'libother.so', null]) {
  test(`HAP gate rejects TDLib SONAME ${soname === null ? 'absence' : soname}`, t => {
    const s = sandbox(t, { soname });
    assertRejected(s.run(), s);
  });
}

for (const missing of exports) {
  test(`HAP gate rejects missing modern TDLib export ${missing}`, t => {
    const s = sandbox(t, { symbols: exports.filter(name => name !== missing).map(name => [name, 'T']) });
    assertRejected(s.run(), s);
  });
}

for (const kind of ['U', 'w', 't', 'D']) {
  test(`HAP gate does not treat nm symbol kind ${kind} as a defined public TDLib function`, t => {
    const s = sandbox(t, { symbols: exports.map(name => [name, name === 'td_send' ? kind : 'T']) });
    assertRejected(s.run(), s);
  });
}

test('HAP gate accepts Clash licenses from the shared rawfile/licenses fallback', t => {
  const s = sandbox(t);
  s.write(completeEntries().map(entry => entry.name.includes('/rawfile/clash/licenses/')
    ? { ...entry, name: entry.name.replace('/rawfile/clash/licenses/', '/rawfile/licenses/') }
    : entry));
  assert.equal(s.run().status, 0);
});

for (const soname of ['libclash_bridge.so.1', 'libother.so', null]) {
  test(`HAP gate rejects Clash bridge SONAME ${soname === null ? 'absence' : soname}`, t => {
    const s = sandbox(t, { dynamic: { 'libclash_bridge.so': { soname } } });
    assertRejected(s.run(), s);
  });
}

for (const soname of ['libclash_core.so.1', 'libother.so', null]) {
  test(`HAP gate rejects Clash core SONAME ${soname === null ? 'absence' : soname}`, t => {
    const s = sandbox(t, { dynamic: { 'libclash_core.so': { soname } } });
    assertRejected(s.run(), s);
  });
}

test('HAP gate rejects a Clash bridge without DT_NEEDED libclash_core.so', t => {
  const s = sandbox(t, { dynamic: { 'libclash_bridge.so': { needed: ['libc++_shared.so'] } } });
  const result = s.run();
  assertRejected(result, s);
  assert.match(result.output, /DT_NEEDED libclash_core\.so/i);
});

for (const [description, runpath] of [
  ['Windows drive', 'D:\\build\\libs'],
  ['POSIX home', '/home/builder/libs'],
  ['macOS home', '/' + 'Users/builder/libs'],
  ['source-refs output', '/work/source-refs/libs'],
  ['generic absolute path', '/opt/build/libs']
]) {
  for (const library of ['libclash_bridge.so', 'libclash_core.so']) {
    test(`HAP gate rejects a build-host RUNPATH (${description}) in ${library}`, t => {
      const s = sandbox(t, { dynamic: { [library]: { runpath } } });
      assertRejected(s.run(), s);
    });
  }
}

test('HAP gate rejects a build-host RPATH in libclash_core.so', t => {
  const s = sandbox(t, { dynamic: { 'libclash_core.so': { rpath: '/home/builder/libs' } } });
  assertRejected(s.run(), s);
});

test('HAP gate accepts portable $ORIGIN RUNPATH entries in both Clash libraries', t => {
  const s = sandbox(t, { dynamic: {
    'libclash_bridge.so': { runpath: '$ORIGIN' },
    'libclash_core.so': { runpath: '$ORIGIN/../lib' }
  } });
  const result = s.run();
  assert.equal(result.status, 0, result.output);
});

for (const missing of clashExports) {
  test(`HAP gate rejects missing Clash core export ${missing}`, t => {
    const s = sandbox(t, { library_symbols: {
      'libclash_core.so': clashExports.filter(name => name !== missing).map(name => [name, 'T'])
    } });
    assertRejected(s.run(), s);
  });
}

for (const kind of ['U', 'w', 'D']) {
  test(`HAP gate does not treat nm symbol kind ${kind} as a defined public Clash core function`, t => {
    const s = sandbox(t, { library_symbols: {
      'libclash_core.so': clashExports.map(name => [name, name === 'startTUN' ? kind : 'T'])
    } });
    assertRejected(s.run(), s);
  });
}

for (const tool of ['llvm-readelf', 'llvm-nm']) {
  test(`HAP gate handles ${tool} failure without echoing synthetic tool stdout, stderr or private paths`, t => {
    const s = sandbox(t, { fail_tool: tool });
    assertRejected(s.run(), s);
    assert.ok(s.calls().some(call => call.tool === tool), 'the failing tool must actually have been invoked');
  });

  test(`HAP gate rejects ${tool} warnings even with exit code zero without echoing private text`, t => {
    const s = sandbox(t, { warn_tool: tool });
    assertRejected(s.run(), s);
  });

  test(`HAP gate rejects a missing ${tool} without leaking its path`, t => {
    const s = sandbox(t);
    fs.unlinkSync(path.join(s.llvm, tool));
    assertRejected(s.run(), s);
  });
}
