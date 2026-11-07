import test from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
const require = createRequire(import.meta.url);
const { mediaAlbumAt, mediaTime, mediaBytes, resolveMediaNetwork } = require('../artifacts/tests/js/model/MediaModels.js');
const item = (id, extra = {}) => ({ id, chatId: '101', mediaKind: 'photo', mediaAlbumId: '9223372036854775806', outgoing: false, ...extra });
test('album grouping retains int64 identifiers and never joins across text, chats or senders', () => {
  const items = [item('1'), item('2', { mediaKind: 'video' }), item('3', { mediaKind: undefined }), item('4'), item('5', { chatId: '202' })];
  assert.deepEqual(mediaAlbumAt(items, 0).map(x => x.id), ['1', '2']);
  assert.deepEqual(mediaAlbumAt(items, 1), []); assert.deepEqual(mediaAlbumAt(items, 2), []);
  assert.deepEqual(mediaAlbumAt(items, 3).map(x => x.id), ['4']);
  assert.deepEqual(mediaAlbumAt([item('1'), item('2', { outgoing: true })], 0).map(x => x.id), ['1']);
  assert.deepEqual(mediaAlbumAt([item('1', { mediaAlbumId: '0' }), item('2', { mediaAlbumId: '0' })], 0).map(x => x.id), ['1']);
});
test('media labels tolerate absent or invalid metadata', () => {
  assert.equal(mediaTime(NaN), '0:00'); assert.equal(mediaTime(61.9), '1:01'); assert.equal(mediaTime(-5), '0:00');
  assert.equal(mediaBytes(0), ''); assert.equal(mediaBytes(1024 * 1024), '1.0 MB');
});
const link = (netId, bearers, metered = true) => ({ netId, bearers, metered });
const probe = (extra = {}) => ({ nets: [], defaultNet: null, defaultUnavailable: false, roaming: null, lastPhysical: null, ...extra });
const vpnNet = link(9, ['vpn'], false);
test('a VPN-only default reuses the last physical Wi-Fi link instead of reporting cellular roaming', () => {
  const result = resolveMediaNetwork(probe({ nets: [vpnNet], defaultNet: vpnNet, roaming: true, lastPhysical: 'wifi' }));
  assert.deepEqual(result, { network: 'wifi', viaVpn: true, networkUnknown: false });
  assert.equal(result.network === 'roaming', false);
});
test('a VPN bearer never re-derives roaming from the telephony flag', () => {
  const fromMobile = resolveMediaNetwork(probe({ nets: [vpnNet], defaultNet: vpnNet, roaming: true, lastPhysical: 'mobile' }));
  assert.deepEqual(fromMobile, { network: 'mobile', viaVpn: true, networkUnknown: false });
  // Only a previously observed physical roaming state is retained; isRoaming=true alone never yields roaming.
  const fromRoaming = resolveMediaNetwork(probe({ nets: [vpnNet], defaultNet: vpnNet, roaming: true, lastPhysical: 'roaming' }));
  assert.deepEqual(fromRoaming, { network: 'roaming', viaVpn: true, networkUnknown: false });
  const noHistory = resolveMediaNetwork(probe({ nets: [vpnNet], defaultNet: vpnNet, roaming: true }));
  assert.deepEqual(noHistory, { network: 'mobile', viaVpn: true, networkUnknown: true });
});
test('a failed network read falls back to mobile without roaming and records networkUnknown', () => {
  assert.deepEqual(resolveMediaNetwork(probe()), { network: 'mobile', viaVpn: false, networkUnknown: true });
  assert.deepEqual(resolveMediaNetwork(probe({ lastPhysical: 'wifi' })),
    { network: 'wifi', viaVpn: false, networkUnknown: true });
  assert.deepEqual(resolveMediaNetwork(probe({ defaultUnavailable: true })),
    { network: 'none', viaVpn: false, networkUnknown: false });
});
test('Wi-Fi stays Wi-Fi while a VPN tunnel is the default network', () => {
  const wifi = link(2, ['wifi'], false);
  assert.deepEqual(resolveMediaNetwork(probe({ nets: [vpnNet, wifi], defaultNet: vpnNet, roaming: true, lastPhysical: 'mobile' })),
    { network: 'wifi', viaVpn: false, networkUnknown: false });
});
test('physical selection orders Wi-Fi, then unmetered, then cellular with roaming only for cellular', () => {
  const meteredWifi = link(2, ['wifi'], true);
  const unmeteredCell = link(3, ['cellular'], false);
  const meteredCell = link(4, ['cellular'], true);
  const vpnDefault = link(9, ['vpn'], true);
  assert.equal(resolveMediaNetwork(probe({ nets: [vpnDefault, meteredCell, meteredWifi], defaultNet: vpnDefault, roaming: true })).network, 'wifi');
  assert.equal(resolveMediaNetwork(probe({ nets: [vpnDefault, meteredCell, unmeteredCell], defaultNet: vpnDefault, roaming: true })).network, 'wifi');
  assert.deepEqual(resolveMediaNetwork(probe({ nets: [vpnDefault, meteredCell], defaultNet: vpnDefault, roaming: true })),
    { network: 'roaming', viaVpn: false, networkUnknown: false });
  assert.deepEqual(resolveMediaNetwork(probe({ nets: [meteredCell], roaming: false })),
    { network: 'mobile', viaVpn: false, networkUnknown: false });
  assert.deepEqual(resolveMediaNetwork(probe({ nets: [meteredCell], roaming: null })),
    { network: 'roaming', viaVpn: false, networkUnknown: false });
});
