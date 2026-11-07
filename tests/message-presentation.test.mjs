import test from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
const require = createRequire(import.meta.url);
const { messageRuns, messageBlocks, safeMessageLink, albumLayout, singleMediaSize, messagesGrouped } = require('../artifacts/tests/js/model/MessagePresentation.js');
const entity = (type, offset, length, extra = {}) => ({ type: 'textEntityType' + type, offset, length, ...extra });

test('UTF-16 entity ranges preserve emoji and combine nested styles without dropping text', () => {
  const text = '😀 Bold link end';
  const runs = messageRuns(text, [entity('Bold', 3, 9), entity('Italic', 3, 4), entity('TextUrl', 8, 4, { url: 'https://example.org' })]);
  assert.equal(runs.map(x => x.text).join(''), text);
  assert.ok(runs.some(x => x.text === 'Bold' && x.bold && x.italic));
  assert.ok(runs.some(x => x.text === 'link' && x.bold && x.link === 'https://example.org'));
  const invalid = messageRuns(text, [entity('Bold', 1, 2), entity('Italic', -1, 8), entity('Bold', 3, 999)]);
  assert.equal(invalid.length, 1); assert.equal(invalid[0].bold, false);
});
test('spoilers remain explicitly marked and unsupported URL schemes never become clickable', () => {
  const text = 'secret example.org';
  const runs = messageRuns(text, [entity('Spoiler', 0, 6), entity('Url', 7, 11), entity('TextUrl', 0, 6, { url: 'javascript:alert(1)' })]);
  assert.equal(runs[0].spoiler, true); assert.equal(runs[0].link, '');
  assert.equal(runs.at(-1).link, 'https://example.org');
  for (const unsafe of ['javascript:alert(1)', 'file:///private/data', 'https://example.org\nattack', 'data:text/html,test']) assert.equal(safeMessageLink(unsafe), '');
});
test('quotes and preformatted blocks preserve line breaks and keep inline styles', () => {
  const text = 'Intro\nquoted\ncode\nend';
  const blocks = messageBlocks(text, [entity('BlockQuote', 6, 6), entity('Bold', 6, 6), entity('PreCode', 13, 4)]);
  assert.equal(blocks.map(x => x.runs.map(r => r.text).join('')).join(''), text);
  assert.equal(blocks.find(x => x.kind === 'quote').runs[0].bold, true);
  assert.equal(blocks.find(x => x.kind === 'code').runs[0].mono, true);
});
test('album layout fills odd rows without gaps or overlap and preserves media order for 2–10 items', () => {
  for (let count = 2; count <= 10; count++) {
    const items = Array.from({ length: count }, (_, i) => ({ mediaWidth: i % 2 ? 480 : 640, mediaHeight: i % 2 ? 640 : 360 }));
    const layout = albumLayout(items, 400);
    assert.deepEqual(layout.frames.map(x => x.index), items.map((_, i) => i));
    for (const a of layout.frames) {
      assert.ok(a.width > 0 && a.height > 0 && a.x >= 0 && a.x + a.width <= 400.001);
      assert.ok(a.y + a.height <= layout.height + .001);
      for (const b of layout.frames) {
        if (a.index >= b.index) continue;
        assert.ok(a.x + a.width <= b.x + .001 || b.x + b.width <= a.x + .001 || a.y + a.height <= b.y + .001 || b.y + b.height <= a.y + .001);
      }
    }
  }
  const three = albumLayout([{mediaWidth:640,mediaHeight:480},{mediaWidth:480,mediaHeight:640},{mediaWidth:640,mediaHeight:360}],400);
  assert.equal(three.frames[0].width, 400); assert.equal(three.frames[1].y, three.frames[2].y);
});
test('standalone media respects portrait/landscape aspect and bounded dimensions', () => {
  const wide = singleMediaSize({ mediaWidth: 1920, mediaHeight: 1080 }, 400);
  assert.equal(wide.width, 400); assert.equal(wide.height, 225);
  const tall = singleMediaSize({ mediaWidth: 720, mediaHeight: 1280 }, 400);
  assert.ok(tall.height <= 420); assert.equal(tall.width / tall.height, 720 / 1280);
});
test('message grouping respects sender, direction, chat, time, forwarding and service boundaries', () => {
  const base = { chatId: '101', senderId: 'user:2', outgoing: false, date: 1700000000 };
  assert.equal(messagesGrouped(base, {...base,date:1700000001}), true);
  for (const extra of [{senderId:'user:3'},{outgoing:true},{chatId:'102'},{date:1700000301},{forwardName:'Other'},{service:true}]) {
    assert.equal(messagesGrouped(base,{...base,...extra}), false);
  }
});
