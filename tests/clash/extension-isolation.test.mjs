import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

// S4-08：扩展进程 import 隔离门禁的宿主侧验收。
// 所有夹具都建在系统临时目录，只用虚构模块名，不接触真实配置或账号数据。

const repoRoot = path.resolve(import.meta.dirname, '../..');
const checker = path.join(repoRoot, 'scripts', 'ci', 'check-clash-imports.py');

/**
 * 选择可用的 Python 3：优先 `python`；Windows 商店的 `python3` 占位符会以
 * 非零退出而不是 ENOENT 失败，因此这里用真实解释器探测而不是只看 spawn 结果。
 */
function findPython() {
  for (const candidate of ['python', 'python3']) {
    const probe = spawnSync(candidate, ['-c', 'import sys; print(sys.version_info[0])'], {
      encoding: 'utf8',
      timeout: 30000,
      windowsHide: true,
    });
    if (!probe.error && probe.status === 0 && probe.stdout.trim() === '3') {
      return candidate;
    }
  }
  return null;
}

const python = findPython();

function runChecker(root) {
  const args = [checker];
  if (root) {
    args.push('--root', root);
  }
  return spawnSync(python, args, {
    cwd: repoRoot,
    encoding: 'utf8',
    timeout: 120000,
    windowsHide: true,
    env: { ...process.env, PYTHONIOENCODING: 'utf-8' },
  });
}

function describe(run) {
  return `exit=${run.status}, stdout=${JSON.stringify(run.stdout)}, stderr=${JSON.stringify(run.stderr)}`;
}

function isInside(child, parent) {
  const relative = path.relative(parent, child);
  return relative === '' || (!relative.startsWith('..') && !path.isAbsolute(relative));
}

/**
 * 在仓库之外的临时目录写入夹具并执行门禁，无论断言结果如何都删除夹具。
 * `files` 的键是相对仓库根目录的路径。
 */
function runFixture(files) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'harlgram-clash-imports-'));
  try {
    assert.equal(isInside(dir, repoRoot), false, '夹具必须位于仓库之外');
    for (const [relative, content] of Object.entries(files)) {
      const target = path.join(dir, relative);
      fs.mkdirSync(path.dirname(target), { recursive: true });
      fs.writeFileSync(target, content, 'utf8');
    }
    return runChecker(dir);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

test('扩展进程 import 门禁在当前源码上通过', (t) => {
  if (!python) {
    t.skip('未找到可用的 Python 3 解释器');
    return;
  }
  const run = runChecker();
  assert.equal(run.status, 0, `门禁应通过：${describe(run)}`);
  assert.equal(run.stdout.includes('forbidden import'), false, `不应出现违规行：${describe(run)}`);
  assert.equal(run.stdout.includes('0 violations'), true, `应报告 0 违规：${describe(run)}`);
});

test('临时插入 @kit.TelephonyKit 的夹具被拒绝并定位到确切行', (t) => {
  if (!python) {
    t.skip('未找到可用的 Python 3 解释器');
    return;
  }
  const fixture = [
    "import { Want } from '@kit.AbilityKit';",
    "import { telephony } from '@kit.TelephonyKit';",
    '',
    'export const sample: Want | null = null;',
    '',
  ].join('\n');
  const run = runFixture({
    'entry/src/main/ets/vpn/ClashVpnExtensionAbility.ets': fixture,
  });

  assert.equal(run.status, 1, `门禁应拒绝违规夹具：${describe(run)}`);
  const lines = run.stdout.trim().split('\n');
  assert.equal(lines.length, 1, `应只报告一条违规：${describe(run)}`);
  assert.equal(
    lines[0],
    'entry/src/main/ets/vpn/ClashVpnExtensionAbility.ets:2: forbidden import: @kit.TelephonyKit',
    `应定位到文件与行号：${describe(run)}`,
  );
  // 门禁只输出文件与行号，不泄露源码内容。
  assert.equal(run.stdout.includes("from '@kit.TelephonyKit'"), false, `不应回显源码：${describe(run)}`);
});

test('注释、字符串与正则中的禁用字样不触发门禁', (t) => {
  if (!python) {
    t.skip('未找到可用的 Python 3 解释器');
    return;
  }
  const fixture = [
    '// import { telephony } from \'@kit.TelephonyKit\';',
    '/* import { sim } from \'@ohos.telephony.sim\'; */',
    "const NOTE: string = \"import { TelegramService } from '../../services/TelegramService'\";",
    "const PATH_LIKE: string = '../data/ClashProfileStore';",
    'const SLASH: RegExp = /@kit\\.TelephonyKit/;',
    'const AIRPLANE: string = \'data/\';',
    '',
  ].join('\n');
  const run = runFixture({
    'entry/src/main/ets/services/clash/ClashCommentFixture.ets': fixture,
  });

  assert.equal(run.status, 0, `注释与字符串不应误伤：${describe(run)}`);
  assert.equal(run.stdout.includes('0 violations'), true, `应报告 0 违规：${describe(run)}`);
});

test('UI 侧 import libclash_bridge.so 被拒绝并定位到行', (t) => {
  if (!python) {
    t.skip('未找到可用的 Python 3 解释器');
    return;
  }
  const run = runFixture({
    'entry/src/main/ets/vpn/ClashVpnExtensionAbility.ets': [
      "import { Want } from '@kit.AbilityKit';",
      '',
    ].join('\n'),
    'entry/src/main/ets/pages/Index.ets': [
      '// 夹具：UI 页面不得加载扩展桥库',
      "import clashBridge from 'libclash_bridge.so';",
      '',
    ].join('\n'),
  });

  assert.equal(run.status, 1, `UI 侧桥库引用应被拒绝：${describe(run)}`);
  assert.equal(
    run.stdout.includes('entry/src/main/ets/pages/Index.ets:2: forbidden import: libclash_bridge.so'),
    true,
    `应定位到文件与行号：${describe(run)}`,
  );
});

test('缺少扩展源码时门禁不静默通过', (t) => {
  if (!python) {
    t.skip('未找到可用的 Python 3 解释器');
    return;
  }
  const run = runFixture({
    'entry/src/main/ets/pages/Index.ets': 'export const placeholder: string = \'fixture\';\n',
  });

  assert.equal(run.status, 1, `缺少扩展源码应报错而不是通过：${describe(run)}`);
  assert.equal(run.stdout.includes('0 violations'), false, `不应报告通过：${describe(run)}`);
});