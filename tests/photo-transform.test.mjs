import test from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
const require = createRequire(import.meta.url);
const { photoPanBounds, clampPhotoOffset, pinchPhotoTransform } = require('../artifacts/tests/js/model/PhotoTransform.js');

const viewport = { width: 400, height: 800, imageWidth: 400, imageHeight: 800 };

function imagePointAtFocus(transform, focus) {
  return {
    x: (focus.x - viewport.width / 2 - transform.x) / transform.scale,
    y: (focus.y - viewport.height / 2 - transform.y) / transform.scale
  };
}

function assertSamePoint(actual, expected) {
  assert.ok(Math.abs(actual.x - expected.x) < 1e-9, 'horizontal subject position stays under fingers');
  assert.ok(Math.abs(actual.y - expected.y) < 1e-9, 'vertical subject position stays under fingers');
}

test('portrait photo cannot pan horizontally into its letterbox at modest zoom', () => {
  assert.deepEqual(photoPanBounds(400, 800, 100, 400, 1), { x: 0, y: 0 });
  assert.deepEqual(photoPanBounds(400, 800, 100, 400, 2), { x: 0, y: 400 });
  assert.deepEqual(photoPanBounds(400, 800, 100, 400, 4), { x: 200, y: 1200 });
});

test('landscape photo uses actual contained image height and clamps drag to visible edges', () => {
  assert.deepEqual(photoPanBounds(400, 800, 800, 400, 2), { x: 200, y: 0 });
  assert.equal(clampPhotoOffset(300, 200), 200);
  assert.equal(clampPhotoOffset(-300, 200), -200);
  assert.equal(clampPhotoOffset(12, 200), 12);
});

test('unloaded and malformed image dimensions never create non-finite transforms', () => {
  for (const size of [0, -1, NaN, Infinity]) {
    assert.deepEqual(photoPanBounds(400, 800, size, 400, 2), { x: 0, y: 0 });
  }
  assert.equal(clampPhotoOffset(NaN, 200), 0);
  assert.equal(clampPhotoOffset(200, 0), 0);
  assert.deepEqual(photoPanBounds(400, 800, 400, 800, 100), { x: 600, y: 1200 });
});

test('off-center pinch preserves the image point under stationary fingers', () => {
  const start = { scale: 1, x: 0, y: 0 };
  const focus = { x: 300, y: 200 };
  const next = pinchPhotoTransform(viewport, start, focus, focus, 2);
  assert.equal(next.scale, 2);
  assertSamePoint(imagePointAtFocus(next, focus), imagePointAtFocus(start, focus));
  assert.deepEqual(next, { scale: 2, x: -100, y: 200 });
});

test('moving pinch center carries the same image subject with both fingers', () => {
  const start = { scale: 2, x: 50, y: -70 };
  const initialFocus = { x: 260, y: 350 };
  const movedFocus = { x: 280, y: 370 };
  const next = pinchPhotoTransform(viewport, start, initialFocus, movedFocus, 1.5);
  assert.equal(next.scale, 3);
  assertSamePoint(imagePointAtFocus(next, movedFocus), imagePointAtFocus(start, initialFocus));
});

test('pinch beginning after an existing pan does not reset or jump the transform', () => {
  const panned = { scale: 2.5, x: 135, y: -204 };
  const focus = { x: 240, y: 300 };
  assert.deepEqual(pinchPhotoTransform(viewport, panned, focus, focus, 1), panned);
  const firstPinch = pinchPhotoTransform(viewport, panned, focus, focus, 1.2);
  const nextFocus = { x: 280, y: 350 };
  assert.deepEqual(pinchPhotoTransform(viewport, firstPinch, nextFocus, nextFocus, 1), firstPinch);
  const secondPinch = pinchPhotoTransform(viewport, firstPinch, nextFocus, nextFocus, 1.1);
  assertSamePoint(imagePointAtFocus(secondPinch, nextFocus), imagePointAtFocus(firstPinch, nextFocus));
});

test('pinch uses bounded scale for focus compensation and returns to fit without overscroll', () => {
  const start = { scale: 3, x: 40, y: -90 };
  const focus = { x: 250, y: 320 };
  const maximum = pinchPhotoTransform(viewport, start, focus, focus, 100);
  assert.equal(maximum.scale, 4);
  assertSamePoint(imagePointAtFocus(maximum, focus), imagePointAtFocus(start, focus));
  assert.deepEqual(pinchPhotoTransform(viewport, maximum, focus, focus, 0.01), { scale: 1, x: 0, y: 0 });
});

test('focus compensation respects letterboxing and clamps at image edges', () => {
  const narrowImage = { ...viewport, imageWidth: 100, imageHeight: 400 };
  const next = pinchPhotoTransform(narrowImage, { scale: 1, x: 0, y: 0 },
    { x: 300, y: 200 }, { x: 320, y: 230 }, 2);
  assert.deepEqual(next, { scale: 2, x: 0, y: 230 });
  const outside = pinchPhotoTransform(viewport, { scale: 1, x: 0, y: 0 },
    { x: 200, y: 400 }, { x: 10000, y: -10000 }, 2);
  assert.deepEqual(outside, { scale: 2, x: 200, y: -400 });
});

test('invalid pinch samples preserve a valid starting transform', () => {
  const start = { scale: 2, x: 50, y: -100 };
  const focus = { x: 250, y: 350 };
  for (const factor of [0, -1, NaN, Infinity]) {
    assert.deepEqual(pinchPhotoTransform(viewport, start, focus, focus, factor), start);
  }
  assert.deepEqual(pinchPhotoTransform(viewport, start, focus, { x: NaN, y: 350 }, 2), start);
  const unloaded = pinchPhotoTransform({ ...viewport, imageWidth: 0 }, start, focus, focus, 2);
  assert.deepEqual(unloaded, { scale: 2, x: 0, y: 0 });
});
