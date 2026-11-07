import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
const root = fileURLToPath(new URL('../', import.meta.url));

test('public progress pages match their reviewed bilingual source documents', () => {
  assert.match(execFileSync('python3', ['scripts/build-website.py', '--check'], { cwd: root, encoding: 'utf8' }), /up to date/);
});

test('documentation renderer escapes markup and rejects unsafe or escaping links', () => {
  execFileSync('python3', ['-c', `
import importlib.util, sys
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('site_build', 'scripts/build-website.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
assert m.inline('<script>alert(1)</script>', 'docs/FEATURES.md') == '&lt;script&gt;alert(1)&lt;/script&gt;'
for target in ['javascript:alert', 'data:text/html,hello', '//evil.example', '/private', '../../outside.md']:
    assert m.link_url(target, 'docs/FEATURES.md') == '#', target
assert m.link_url('ROADMAP.en.md', 'docs/FEATURES.en.md') == 'roadmap.html'
assert m.link_url('../CHANGELOG.md', 'docs/FEATURES.md') == 'changelog.html'
assert m.link_url('VIDEO_PLAYER.md', 'docs/FEATURES.md').endswith('/blob/main/docs/VIDEO_PLAYER.md')
assert '<ol>' in m.render('1. First\\n2. Second', 'docs/ROADMAP.md')
`], { cwd: root, encoding: 'utf8' });
});
