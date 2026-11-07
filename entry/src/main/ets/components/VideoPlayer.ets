import { media } from '@kit.MediaKit';
import { audio } from '@kit.AudioKit';
import { fileIo } from '@kit.CoreFileKit';
import { window, promptAction } from '@kit.ArkUI';
import { mediaTime } from '../model/MediaModels';
import { seekPosition, VIDEO_SPEEDS, VideoSeekQueue } from '../model/VideoPlayback';
import { telegramService } from '../services/TelegramService';
import { VideoHttpStream } from '../services/VideoHttpStream';

/** One native decoder per viewer. Completed files use fdSrc; partial files use the asynchronous SDK resource loader. */
@Component
export struct VideoPlayer {
  @Prop @Watch('sourceChanged') path: string = '';
  @Prop @Watch('sourceChanged') fileId: number = 0;
  @Prop @Watch('sourceChanged') chatId: string = '';
  @Prop @Watch('sourceChanged') messageId: string = '';
  @Prop downloadProgress: number = 0;
  @Prop downloading: boolean = false;
  onDownload: () => void = () => {};
  @StorageProp('mediaForeground') @Watch('foregroundChanged') foreground: boolean = true;
  @State private canControl: boolean = false;
  @State private playing: boolean = false;
  @State private loading: boolean = true;
  @State private buffering: boolean = false;
  @State private error: string = '';
  @State private playbackPosition: number = 0;
  @State private duration: number = 0;
  @State private muted: boolean = false;
  @State private speed: number = 1;
  @State private holding: boolean = false;
  @State private controls: boolean = true;
  @State private videoRatio: number = 16 / 9;
  @State private availableWidth: number = 1;
  @State private availableHeight: number = 1;
  private surface: XComponentController = new XComponentController();
  private player: media.AVPlayer | undefined = undefined;
  private file: fileIo.File | undefined = undefined;
  private stream: VideoHttpStream | undefined = undefined;
  private generation: number = 0;
  private surfaceReady: boolean = false;
  @State private dragging: boolean = false;
  @State private seeking: boolean = false;
  private seekQueue: VideoSeekQueue = new VideoSeekQueue();
  private seekTimer: number = -1;
  private wantPlaying: boolean = true;
  private playbackOperation: boolean = false;
  private gestureStart: number = 0;
  private loadTimer: number = -1;
  private hideTimer: number = -1;
  private sourceTimer: number = -1;
  private loadedKey: string = '';
  private resumeAt: number = 0;
  private sourceKey(): string { return this.fileId ? this.chatId + ':' + this.messageId + ':' + this.fileId : this.path; }
  aboutToDisappear(): void { this.surfaceReady = false; this.dispose(); }
  private sourceChanged(): void {
    if (this.sourceTimer >= 0) { clearTimeout(this.sourceTimer); }
    this.sourceTimer = setTimeout(() => { this.sourceTimer = -1; if (this.surfaceReady && (this.sourceKey() !== this.loadedKey || (!!this.error && !!this.path))) { this.start(this.sourceKey() === this.loadedKey ? this.playbackPosition : 0); } }, 0);
  }
  private foregroundChanged(): void {
    if (!this.foreground) { this.wantPlaying = false; this.endHold(); this.controls = true; this.awake(false); this.reconcilePlayback(); }
  }
  private awake(value: boolean): void {
    try { window.findWindow(this.getUIContext().getWindowName()).setWindowKeepScreenOn(value).catch(() => {}); } catch (_) {}
  }
  private dispose(): void {
    this.generation++;
    if (this.loadTimer >= 0) { clearTimeout(this.loadTimer); this.loadTimer = -1; }
    if (this.hideTimer >= 0) { clearTimeout(this.hideTimer); this.hideTimer = -1; }
    if (this.sourceTimer >= 0) { clearTimeout(this.sourceTimer); this.sourceTimer = -1; }
    if (this.seekTimer >= 0) { clearTimeout(this.seekTimer); this.seekTimer = -1; }
    this.seekQueue.reset(); this.seeking = false; this.playbackOperation = false;
    this.holding = false; this.dragging = false; this.awake(false);
    const player = this.player, file = this.file, stream = this.stream;
    this.player = undefined; this.file = undefined; this.stream = undefined; this.playing = false; this.canControl = false;
    stream?.close();
    // The descriptor must stay open until the native decoder releases it.
    if (player) { player.release().catch(() => {}).finally(() => { if (file) { fileIo.close(file).catch(() => {}); } }); }
    else if (file) { fileIo.close(file).catch(() => {}); }
  }
  private start(resume: number = 0): void {
    this.dispose(); this.loadedKey = this.sourceKey();
    const token = this.generation;
    this.wantPlaying = this.foreground; this.awake(this.foreground);
    this.loading = true; this.buffering = false; this.error = ''; this.controls = true;
    this.playbackPosition = resume; this.duration = 0; this.resumeAt = resume;
    this.muted = false; this.speed = 1;
    this.loadTimer = setTimeout(() => { if (token === this.generation && this.loading) { this.fail('视频加载超时，请重试'); } }, 45000);
    this.initialize(token).catch(() => { if (token === this.generation) { this.fail('无法播放此视频，请重试'); } });
  }
  private async initialize(token: number): Promise<void> {
    const player = await media.createAVPlayer();
    if (token !== this.generation || !this.surfaceReady) { await player.release(); return; }
    this.player = player;
    player.on('stateChange', (state: string) => {
      if (token !== this.generation) { return; }
      console.info('HarlgramVideo state=' + state);
      this.playing = state === 'playing'; this.awake(this.playing && this.foreground);
      if (state === 'initialized') {
        player.surfaceId = this.surface.getXComponentSurfaceId();
        player.prepare().catch(() => { if (token === this.generation) { this.fail('视频格式暂不支持或缓冲失败'); } });
      } else if (state === 'prepared') {
        if (this.loadTimer >= 0) { clearTimeout(this.loadTimer); this.loadTimer = -1; }
        this.canControl = true; this.loading = false; this.duration = player.duration;
        try { if (this.stream) { console.info('HarlgramVideo prepared downloaded=' + this.stream.downloaded() + ' total=' + this.stream.size()); } } catch (_) {}
        if (this.resumeAt > 0) { this.seek(this.resumeAt); }
        this.reconcilePlayback();
      } else if (state === 'playing') {
        this.reconcilePlayback(); this.scheduleHide();
      }
      else if (state === 'paused' || state === 'completed') {
        this.endHold(); this.controls = true;
        if (state === 'completed') { this.wantPlaying = false; this.playbackPosition = this.duration; }
        else { this.reconcilePlayback(); }
      } else if (state === 'error') { setTimeout(() => { if (token === this.generation) { this.fail(); } }, 100); }
    });
    player.on('timeUpdate', (time: number) => { if (token === this.generation && !this.dragging && !this.seeking) { this.playbackPosition = time; } });
    player.on('durationUpdate', (time: number) => { if (token === this.generation) { this.duration = time; } });
    player.on('seekDone', (time: number) => {
      if (token !== this.generation) { return; }
      console.info('HarlgramVideo seekDone=' + time);
      const next = this.seekQueue.complete();
      if (next !== undefined) { this.performSeek(next); return; }
      this.seeking = false; this.buffering = false;
      if (this.seekTimer >= 0) { clearTimeout(this.seekTimer); this.seekTimer = -1; }
      if (!this.dragging) { this.playbackPosition = time; }
      this.reconcilePlayback();
      this.scheduleHide();
    });
    player.on('speedDone', (rate: number) => { if (token === this.generation) { console.info('HarlgramVideo speed=' + rate + ' hold=' + this.holding); } });
    player.on('bufferingUpdate', (kind: media.BufferingInfoType, _value: number) => {
      if (token !== this.generation) { return; }
      if (kind === media.BufferingInfoType.BUFFERING_START) { this.buffering = true; }
      else if (kind === media.BufferingInfoType.BUFFERING_END) { this.buffering = false; }
    });
    player.on('videoSizeChange', (width: number, height: number) => {
      if (token === this.generation && width > 0 && height > 0) { this.videoRatio = width / height; }
    });
    player.on('audioInterrupt', (event: audio.InterruptEvent) => {
      if (token === this.generation && event.hintType !== audio.InterruptHint.INTERRUPT_HINT_RESUME) {
        this.wantPlaying = false; this.endHold(); this.reconcilePlayback();
      }
    });
    player.on('error', (error) => { if (token === this.generation) { console.info('HarlgramVideo playerError code=' + error.code); this.fail(); } });
    let localReadable: boolean = false;
    try { localReadable = !!this.path && await fileIo.access(this.path); } catch (_) {}
    if (token !== this.generation) { return; }
    if (localReadable) {
      const file = await fileIo.open(this.path, fileIo.OpenMode.READ_ONLY);
      if (token !== this.generation) { await fileIo.close(file); return; }
      this.file = file;
      const stat = await fileIo.stat(file.fd); if (token !== this.generation) { return; }
      player.fdSrc = { fd: file.fd, offset: 0, length: stat.size };
    } else {
      const reader = await telegramService.createVideoReader(this.chatId, this.messageId, this.fileId);
      if (token !== this.generation) { reader.close(); return; }
      const loader = new VideoHttpStream(reader, (message: string) => { if (token === this.generation) { this.fail(message); } });
      this.stream = loader; const url = await loader.open();
      if (token !== this.generation) { loader.close(); return; }
      player.url = url;
    }
  }
  private fail(message: string = '视频播放失败，请重试'): void { this.loading = false; this.buffering = false; this.error = message; this.controls = true; this.dispose(); }
  private scheduleHide(): void {
    if (this.hideTimer >= 0) { clearTimeout(this.hideTimer); }
    this.hideTimer = setTimeout(() => { this.hideTimer = -1; if (this.playing && !this.dragging && !this.holding && !this.seeking && !this.buffering) { this.controls = false; } }, 3500);
  }
  private toggleControls(): void { this.controls = !this.controls; if (this.controls) { this.scheduleHide(); } }
  private reconcilePlayback(): void {
    const player = this.player, token = this.generation;
    if (!player || !this.canControl || this.playbackOperation) { return; }
    const play = this.wantPlaying && this.foreground && !this.seeking;
    let action: Promise<void>;
    if (play && (player.state === 'prepared' || player.state === 'paused')) { action = player.play(); }
    else if ((!this.wantPlaying || !this.foreground) && player.state === 'playing') { action = player.pause(); }
    else { return; }
    this.playbackOperation = true;
    action.catch(() => { if (token === this.generation) { this.fail(); } }).finally(() => {
      if (token === this.generation) { this.playbackOperation = false; this.reconcilePlayback(); }
    });
  }
  private toggle(): void {
    const player = this.player; this.controls = true;
    if (!player || !this.canControl) { return; }
    this.endHold();
    this.wantPlaying = player.state === 'completed' ? true : !this.wantPlaying;
    if (player.state === 'completed' && this.wantPlaying) { this.seek(0); } else { this.reconcilePlayback(); }
    this.scheduleHide();
  }
  private seek(value: number): void {
    if (!this.canControl) { return; }
    this.endHold(); const position = seekPosition(value, this.duration); this.playbackPosition = position;
    this.seeking = true; this.buffering = true; this.controls = true;
    const next = this.seekQueue.request(position); if (next !== undefined) { this.performSeek(next); }
  }
  private performSeek(position: number): void {
    if (this.seekTimer >= 0) { clearTimeout(this.seekTimer); }
    const token = this.generation;
    this.seekTimer = setTimeout(() => { if (token === this.generation && this.seeking) { this.fail('视频定位超时，请重试'); } }, 35000);
    try { this.player?.seek(position, media.SeekMode.SEEK_CLOSEST); } catch (_) { this.fail(); }
  }
  private startPan(): void { if (this.canControl) { this.endHold(); this.gestureStart = this.playbackPosition; this.dragging = true; this.controls = true; } }
  private movePan(event: GestureEvent): void {
    if (this.dragging) { this.playbackPosition = seekPosition(this.gestureStart + event.offsetX / Math.max(1, this.availableWidth) * Math.min(this.duration, 120000), this.duration); }
  }
  private finishPan(cancel: boolean): void {
    if (!this.dragging) { return; } this.dragging = false;
    if (cancel) { this.playbackPosition = this.gestureStart; } else { this.seek(this.playbackPosition); }
  }
  private nativeSpeed(rate: number): media.PlaybackSpeed {
    if (rate === 0.5) { return media.PlaybackSpeed.SPEED_FORWARD_0_50_X; }
    if (rate === 0.75) { return media.PlaybackSpeed.SPEED_FORWARD_0_75_X; }
    if (rate === 1.25) { return media.PlaybackSpeed.SPEED_FORWARD_1_25_X; }
    if (rate === 1.5) { return media.PlaybackSpeed.SPEED_FORWARD_1_50_X; }
    if (rate === 1.75) { return media.PlaybackSpeed.SPEED_FORWARD_1_75_X; }
    if (rate === 2) { return media.PlaybackSpeed.SPEED_FORWARD_2_00_X; }
    return media.PlaybackSpeed.SPEED_FORWARD_1_00_X;
  }
  private applySpeed(rate: number): void { try { this.player?.setSpeed(this.nativeSpeed(rate)); } catch (_) { this.fail('此视频暂不支持倍速'); } }
  private beginHold(): void { if (this.playing && this.canControl && this.foreground) { this.holding = true; this.applySpeed(2); } }
  private endHold(): void { if (this.holding) { this.holding = false; if (this.canControl) { this.applySpeed(this.speed); } this.scheduleHide(); } }
  private chooseSpeed(): void {
    this.endHold(); const token = this.generation;
    this.getUIContext().getPromptAction().showDialog({ title: '播放速度', buttons: VIDEO_SPEEDS.map((rate: number): promptAction.Button => ({ text: rate + '×', color: '#268BDE' })) })
      .then(result => { const rate = VIDEO_SPEEDS[result.index]; if (rate && token === this.generation && this.canControl) { this.speed = rate; this.applySpeed(rate); this.scheduleHide(); } }).catch(() => {});
  }
  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Stack() {
        XComponent({ id: 'harlgram-video', type: XComponentType.SURFACE, controller: this.surface })
          .width(Math.min(this.availableWidth, this.availableHeight * this.videoRatio))
          .height(Math.min(this.availableHeight, this.availableWidth / this.videoRatio))
          .onLoad(() => { this.surfaceReady = true; this.start(); })
          .onDestroy(() => { this.surfaceReady = false; this.dispose(); })
      }.width('100%').height('100%').id('video-gesture-area')
        .gesture(GestureGroup(GestureMode.Exclusive,
          LongPressGesture({ repeat: false, duration: 350 }).onAction(() => this.beginHold()).onActionEnd(() => this.endHold()).onActionCancel(() => this.endHold()),
          PanGesture({ direction: PanDirection.Horizontal, distance: 12 }).onActionStart(() => this.startPan()).onActionUpdate((event: GestureEvent) => this.movePan(event))
            .onActionEnd(() => this.finishPan(false)).onActionCancel(() => this.finishPan(true)),
          TapGesture({ count: 2 }).onAction(() => this.toggle()),
          TapGesture().onAction(() => this.toggleControls())))
        .onTouch((event: TouchEvent) => { if (event.type === TouchType.Up || event.type === TouchType.Cancel) { this.endHold(); } })
      if (this.loading || this.buffering || this.seeking) {
        Column({ space: 10 }) { LoadingProgress().width(38).height(38).color(Color.White); Text('正在缓冲…').fontSize(12).fontColor(Color.White) }
          .width('100%').height('100%').justifyContent(FlexAlign.Center).hitTestBehavior(HitTestMode.None)
      }
      if (this.dragging) {
        Column() { Text(mediaTime(this.playbackPosition / 1000) + ' / ' + mediaTime(this.duration / 1000)).fontSize(20).fontColor(Color.White).padding(16).backgroundColor('#B0000000').borderRadius(12).id('video-seek-preview') }
          .width('100%').height('100%').justifyContent(FlexAlign.Center).hitTestBehavior(HitTestMode.None)
      }
      if (this.holding) {
        Column() { Text('2× 快进中').fontSize(13).fontColor(Color.White).padding(12).backgroundColor('#B0000000').borderRadius(16).id('video-hold-speed') }
          .width('100%').height('100%').padding({ top: 16 }).justifyContent(FlexAlign.Start).hitTestBehavior(HitTestMode.None)
      }
      if (this.error.length > 0) {
        Column({ space: 16 }) {
          Text(this.error).fontColor(Color.White)
          Button('重试').onClick(() => this.start(this.playbackPosition))
          if (!this.path && this.fileId) {
            Button(this.downloading ? '下载中 ' + this.downloadProgress + '%' : '完整下载').enabled(!this.downloading).onClick(() => this.onDownload())
          }
        }.width('100%').height('100%').justifyContent(FlexAlign.Center)
      }
      if (this.controls && this.canControl && !this.error) {
        Column({ space: 8 }) {
          Row({ space: 10 }) {
            Text(mediaTime(this.playbackPosition / 1000)).fontColor(Color.White).fontSize(12).id('video-position')
            Slider({ value: this.playbackPosition, min: 0, max: Math.max(1, this.duration), step: 100 }).layoutWeight(1).trackColor('#66FFFFFF').selectedColor(Color.White).blockColor(Color.White).trackThickness(3).enabled(this.canControl).id('video-seek')
              .onChange((value: number, mode: SliderChangeMode) => {
                this.playbackPosition = value; this.dragging = mode === SliderChangeMode.Begin || mode === SliderChangeMode.Moving;
                if (!this.dragging && this.canControl) { this.seek(value); }
              })
            Text(mediaTime(this.duration / 1000)).fontColor(Color.White).fontSize(12).id('video-duration')
          }
          Row({ space: 12 }) {
            Button({ type: ButtonType.Circle }) { SymbolGlyph($r('sys.symbol.gobackward_30')).fontSize(26).fontColor([Color.White]) }
              .width(44).height(44).backgroundColor(Color.Transparent).enabled(this.canControl).onClick(() => this.seek(this.playbackPosition - 30000)).id('video-back-30').accessibilityText('后退 30 秒')
            Button({ type: ButtonType.Circle }) { SymbolGlyph(this.playing ? $r('sys.symbol.pause_fill') : $r('sys.symbol.play_fill')).fontSize(26).fontColor([Color.White]) }
              .width(44).height(44).backgroundColor(Color.Transparent).enabled(this.canControl).onClick(() => this.toggle()).id('video-toggle-playback').accessibilityText(this.playing ? '暂停视频' : '播放视频')
            Button({ type: ButtonType.Circle }) { SymbolGlyph($r('sys.symbol.goforward_30')).fontSize(26).fontColor([Color.White]) }
              .width(44).height(44).backgroundColor(Color.Transparent).enabled(this.canControl).onClick(() => this.seek(this.playbackPosition + 30000)).id('video-forward-30').accessibilityText('快进 30 秒')
            Blank()
            Button({ type: ButtonType.Circle }) { SymbolGlyph(this.muted ? $r('sys.symbol.speaker_slash_fill') : $r('sys.symbol.speaker_wave_2_fill')).fontSize(21).fontColor([Color.White]) }
              .width(40).height(40).backgroundColor(Color.Transparent).enabled(this.canControl).id('video-mute').accessibilityText(this.muted ? '开启声音' : '静音').onClick(() => {
              try { this.muted = !this.muted; this.player?.setVolume(this.muted ? 0 : 1); this.scheduleHide(); } catch (_) { this.fail(); }
            })
            Button(this.speed + '×').fontSize(12).height(36).fontColor(Color.White).backgroundColor('#30343A').enabled(this.canControl).onClick(() => this.chooseSpeed()).id('video-speed')
          }
        }.width('100%').padding({ left: 14, right: 14, top: 8, bottom: 12 }).linearGradient({ direction: GradientDirection.Bottom, colors: [['#00000000', 0], ['#C0000000', 1]] })
      }
    }.width('100%').height('100%').backgroundColor(Color.Black).onAreaChange((_old: Area, area: Area) => {
      this.availableWidth = Number(area.width); this.availableHeight = Number(area.height);
    })
  }
}
