import { window } from '@kit.ArkUI';
import { photoPanBounds, clampPhotoOffset, pinchPhotoTransform } from '../model/PhotoTransform';

/** Full-screen viewing stays local; opening a photo never downloads or shares it elsewhere. */
@Component
export struct PhotoViewer {
  @Prop @Watch('reset') imagePath: string = '';
  onClose: () => void = () => {};
  @Prop embedded: boolean = false;
  onNavigate: (delta: number) => void = () => {};
  @State private zoom: number = 1;
  @State private offsetX: number = 0;
  @State private offsetY: number = 0;
  @State private failed: boolean = false;
  @State private loaded: boolean = false;
  @State private retry: number = 0;
  @State private topInset: number = 0;
  private hostWindow: window.Window | undefined = undefined;
  private readonly onAvoidAreaChange: (options: window.AvoidAreaOptions) => void =
    (options: window.AvoidAreaOptions): void => {
      if (options.type === window.AvoidAreaType.TYPE_SYSTEM) { this.updateTopInset(options.area); }
    };
  private startZoom: number = 1;
  private startX: number = 0;
  private startY: number = 0;
  private panOriginX: number = 0;
  private panOriginY: number = 0;
  private panNeedsRebase: boolean = true;
  private pinching: boolean = false;
  private pinchStartX: number = 0;
  private pinchStartY: number = 0;
  private pinchFocusX: number = 0;
  private pinchFocusY: number = 0;
  private pinchStartScale: number = 1;
  private viewWidth: number = 0;
  private viewHeight: number = 0;
  private imageWidth: number = 0;
  private imageHeight: number = 0;

  aboutToAppear(): void {
    try {
      const name = this.getUIContext().getWindowName();
      if (!name) { return; }
      const host = window.findWindow(name);
      this.hostWindow = host;
      this.updateTopInset(host.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM));
      host.on('avoidAreaChange', this.onAvoidAreaChange);
    } catch (_) {}
  }

  aboutToDisappear(): void {
    try { this.hostWindow?.off('avoidAreaChange', this.onAvoidAreaChange); } catch (_) {}
    this.hostWindow = undefined;
  }

  private updateTopInset(area: window.AvoidArea): void {
    // ContentCover starts at window y=0 but its bottom is already constrained by the modal host.
    const height = this.getUIContext().px2vp(area.topRect.height);
    this.topInset = Number.isFinite(height) && height > 0 ? height : 0;
  }

  private reset(): void {
    this.zoom = 1;
    this.offsetX = 0;
    this.offsetY = 0;
    this.startZoom = 1;
    this.startX = 0;
    this.startY = 0;
    this.panOriginX = 0;
    this.panOriginY = 0;
    this.panNeedsRebase = true;
    this.pinching = false;
    this.pinchStartX = 0;
    this.pinchStartY = 0;
    this.pinchFocusX = 0;
    this.pinchFocusY = 0;
    this.pinchStartScale = 1;
    this.failed = false;
    this.loaded = false;
  }

  private source(): string { return this.imagePath.startsWith('/') ? `file://${this.imagePath}` : this.imagePath; }
  private clampPosition(): void {
    const bounds = photoPanBounds(this.viewWidth, this.viewHeight, this.imageWidth, this.imageHeight, this.zoom);
    this.offsetX = clampPhotoOffset(this.offsetX, bounds.x);
    this.offsetY = clampPhotoOffset(this.offsetY, bounds.y);
  }

  private fingerCount(event: GestureEvent): number {
    // SDK 20+ fingerInfos contains only effective fingers; fingerList may contain sparse slots.
    if (event.fingerInfos && event.fingerInfos.length > 0) { return event.fingerInfos.length; }
    return event.fingerList.filter((finger: FingerInfo) => !!finger).length;
  }

  private beginPinch(event: GestureEvent): void {
    if (!this.loaded || !Number.isFinite(event.scale) || event.scale <= 0 ||
      !Number.isFinite(event.pinchCenterX) || !Number.isFinite(event.pinchCenterY)) { return; }
    this.pinching = true;
    this.panNeedsRebase = true;
    this.startZoom = this.zoom;
    this.pinchStartX = this.offsetX;
    this.pinchStartY = this.offsetY;
    this.pinchFocusX = event.pinchCenterX;
    this.pinchFocusY = event.pinchCenterY;
    // Recognition may start after a distance threshold, when scale is already different from 1.
    this.pinchStartScale = event.scale;
  }

  private updatePinch(event: GestureEvent): void {
    if (!this.loaded || !this.pinching || !Number.isFinite(event.scale) || event.scale <= 0 ||
      !Number.isFinite(event.pinchCenterX) || !Number.isFinite(event.pinchCenterY)) { return; }
    const next = pinchPhotoTransform({ width: this.viewWidth, height: this.viewHeight,
      imageWidth: this.imageWidth, imageHeight: this.imageHeight },
      { scale: this.startZoom, x: this.pinchStartX, y: this.pinchStartY },
      { x: this.pinchFocusX, y: this.pinchFocusY }, { x: event.pinchCenterX, y: event.pinchCenterY },
      event.scale / this.pinchStartScale);
    this.zoom = next.scale;
    this.offsetX = next.x;
    this.offsetY = next.y;
  }

  private endPinch(): void {
    this.pinching = false;
    // A still-recognized pan reports cumulative offsets from before the second finger arrived.
    this.panNeedsRebase = true;
    this.clampPosition();
  }

  private rebasePan(event: GestureEvent): void {
    this.startX = this.offsetX;
    this.startY = this.offsetY;
    this.panOriginX = event.offsetX;
    this.panOriginY = event.offsetY;
    this.panNeedsRebase = false;
  }

  private updatePan(event: GestureEvent): void {
    if (!this.loaded || this.zoom <= 1 || this.pinching || this.fingerCount(event) !== 1) {
      this.panNeedsRebase = true;
      return;
    }
    if (!Number.isFinite(event.offsetX) || !Number.isFinite(event.offsetY)) { return; }
    if (this.panNeedsRebase) { this.rebasePan(event); return; }
    this.offsetX = this.startX + event.offsetX - this.panOriginX;
    this.offsetY = this.startY + event.offsetY - this.panOriginY;
    this.clampPosition();
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Stack() {
        if (!this.failed) {
          // Recreate only for an explicit retry; do not restart decoding during gestures.
          ForEach([this.retry], (_retry: number) => {
            Image(this.source()).width('100%').height('100%').objectFit(ImageFit.Contain)
              .draggable(false).scale({ x: this.zoom, y: this.zoom })
              .translate({ x: this.offsetX, y: this.offsetY })
              .onComplete((event) => {
                if (event && event.width > 0 && event.height > 0) {
                  this.imageWidth = event.width;
                  this.imageHeight = event.height;
                  this.loaded = true;
                  this.clampPosition();
                }
              }).onError(() => { this.failed = true; this.loaded = false; })
              .accessibilityText('图片，双指缩放或双击放大')
          }, (retry: number) => `${this.imagePath}:${retry}`)
          if (!this.loaded) { LoadingProgress().width(36).height(36).color('#FFFFFF') }
        } else {
          Column({ space: 12 }) {
            Text('图片无法打开').fontSize(15).fontColor('#FFFFFF')
            Button('重试').backgroundColor('#304258').fontColor('#FFFFFF')
              .onClick(() => { this.reset(); this.retry++; })
          }
        }
      }.width('100%').height('100%').clip(true)
        .onAreaChange((_oldArea: Area, area: Area) => {
          this.viewWidth = Number(area.width);
          this.viewHeight = Number(area.height);
          this.clampPosition();
        })
        .gesture(GestureGroup(GestureMode.Parallel,
          PinchGesture({ fingers: 2 })
            .onActionStart((event: GestureEvent) => { this.beginPinch(event); })
            .onActionUpdate((event: GestureEvent) => { this.updatePinch(event); })
            .onActionEnd(() => { this.endPinch(); })
            .onActionCancel(() => { this.endPinch(); }),
          PanGesture({ direction: PanDirection.All, distance: 10 })
            .onActionStart((event: GestureEvent) => {
              this.rebasePan(event);
              if (this.pinching || this.fingerCount(event) !== 1) { this.panNeedsRebase = true; }
            })
            .onActionUpdate((event: GestureEvent) => { this.updatePan(event); })
            .onActionEnd((event: GestureEvent) => {
              this.panNeedsRebase = true;
              if (this.zoom === 1 && !this.pinching && Math.abs(event.offsetX) > 70 && Math.abs(event.offsetX) > Math.abs(event.offsetY) * 1.5) {
                this.onNavigate(event.offsetX < 0 ? 1 : -1);
              }
            })
            .onActionCancel(() => { this.panNeedsRebase = true; }),
          TapGesture({ count: 2, fingers: 1, isFingerCountLimited: true, distanceThreshold: 8 })
            .onAction((event: GestureEvent) => {
            if (!this.loaded || this.pinching || this.fingerCount(event) > 1) { return; }
            this.zoom = this.zoom > 1 ? 1 : 2.5;
            this.offsetX = 0;
            this.offsetY = 0;
            this.panNeedsRebase = true;
          })
        ))
      if (!this.embedded) {
      Button({ type: ButtonType.Circle }) {
        Image($r('app.media.hg_close_white')).width(22).height(22)
      }.width(44).height(44).margin({ left: 16, top: 16 }).backgroundColor('#99303A44')
        .onClick(() => this.onClose()).accessibilityText('关闭图片预览')
      }
    }.width('100%').height('100%').padding({ top: this.embedded ? 0 : this.topInset }).backgroundColor('#101418')
  }
}
