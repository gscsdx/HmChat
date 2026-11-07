export interface PhotoBounds {
  x: number;
  y: number;
}

export interface PhotoViewport {
  width: number;
  height: number;
  imageWidth: number;
  imageHeight: number;
}

export interface PhotoTransform {
  scale: number;
  x: number;
  y: number;
}

export interface PhotoPoint {
  x: number;
  y: number;
}

/** Pan only the overflow of the contained image, not its letterboxed viewport. */
export function photoPanBounds(viewWidth: number, viewHeight: number, imageWidth: number,
  imageHeight: number, scale: number): PhotoBounds {
  if (![viewWidth, viewHeight, imageWidth, imageHeight, scale].every((value: number) => Number.isFinite(value) && value > 0)) {
    return { x: 0, y: 0 };
  }
  const fit = Math.min(viewWidth / imageWidth, viewHeight / imageHeight);
  const zoom = Math.max(1, Math.min(4, scale));
  return {
    x: Math.max(0, (imageWidth * fit * zoom - viewWidth) / 2),
    y: Math.max(0, (imageHeight * fit * zoom - viewHeight) / 2)
  };
}

export function clampPhotoOffset(offset: number, bound: number): number {
  if (!Number.isFinite(offset) || !Number.isFinite(bound) || bound <= 0) { return 0; }
  return Math.max(-bound, Math.min(bound, offset));
}

/** Keep the image point under the initial fingers under the current pinch center (all points are viewport vp). */
export function pinchPhotoTransform(viewport: PhotoViewport, start: PhotoTransform,
  startFocus: PhotoPoint, focus: PhotoPoint, scaleFactor: number): PhotoTransform {
  const startScale = Number.isFinite(start.scale) && start.scale > 0 ? Math.max(1, Math.min(4, start.scale)) : 1;
  const startX = Number.isFinite(start.x) ? start.x : 0;
  const startY = Number.isFinite(start.y) ? start.y : 0;
  const bounds = photoPanBounds(viewport.width, viewport.height, viewport.imageWidth, viewport.imageHeight, startScale);
  const unchanged: PhotoTransform = { scale: startScale, x: clampPhotoOffset(startX, bounds.x),
    y: clampPhotoOffset(startY, bounds.y) };
  if (![viewport.width, viewport.height, viewport.imageWidth, viewport.imageHeight, scaleFactor]
    .every((value: number) => Number.isFinite(value) && value > 0) ||
    ![startFocus.x, startFocus.y, focus.x, focus.y].every((value: number) => Number.isFinite(value))) {
    return unchanged;
  }
  const scale = Math.max(1, Math.min(4, startScale * scaleFactor));
  const ratio = scale / startScale;
  const centerX = viewport.width / 2;
  const centerY = viewport.height / 2;
  const nextBounds = photoPanBounds(viewport.width, viewport.height, viewport.imageWidth, viewport.imageHeight, scale);
  return {
    scale: scale,
    x: clampPhotoOffset(focus.x - centerX - (startFocus.x - centerX - unchanged.x) * ratio, nextBounds.x),
    y: clampPhotoOffset(focus.y - centerY - (startFocus.y - centerY - unchanged.y) * ratio, nextBounds.y)
  };
}
