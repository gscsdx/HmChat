import { HdsPage } from './HdsPage';
import { HdsSettingsRow } from './HdsSettingsRow';
import { HdsListItemCard, HdsListItemCardAttribute, SuffixSwitch } from '@kit.UIDesignKit';
import { promptAction } from '@kit.ArkUI';
import { telegramService } from '../services/TelegramService';
import { StorageManager } from '../services/StorageManager';
import { CacheCategory, CacheChat, MediaPolicy, DownloadProfile, MediaNetwork, StorageSnapshot, NetworkUsage,
  defaultMediaPolicy, cloneMediaPolicy, formatStorageBytes, retentionLabel, RETENTION_DAYS, CACHE_LIMITS } from '../model/StorageModels';

@Component
struct StorageToggleRow {
  @Prop title: string = '';
  @Prop subtitle: string = '';
  @Prop checked: boolean = false;
  @Prop isEnabled: boolean = true;
  @Prop dark: boolean = false;
  action: (value: boolean) => void = () => {};
  open: () => void = () => {};
  build() {
    HdsListItemCard({ textItem: { primaryText: { text: this.title }, secondaryText: { text: this.subtitle } },
      suffixItem: new SuffixSwitch({ isCheck: this.checked, enable: this.isEnabled,
        onChange: (value: boolean) => this.action(value) }),
      cardBackgroundColor: Color.Transparent, enable: this.isEnabled, onClick: () => this.open()
    }).width('100%')
  }
}
@Component
struct StorageValueRow {
  @Prop title: string = '';
  @Prop value: string = '';
  @Prop isEnabled: boolean = true;
  @Prop dark: boolean = false;
  action: () => void = () => {};
  build() {
    HdsSettingsRow({ title: this.title, value: this.value, isEnabled: this.isEnabled, action: () => this.action() })
  }
}

@Component
export struct StoragePage {
  manager: StorageManager = telegramService.storageManager;
  @Link @Watch('routeChanged') route: string;
  @Prop dark: boolean = false;
  onClose: () => void = () => {};
  @State private snapshot: StorageSnapshot = { categories: [], chats: [], bytes: 0, databaseBytes: 0, logBytes: 0, temporaryBytes: 0, diskTotal: 0, diskFree: 0 };
  @State private policy: MediaPolicy = defaultMediaPolicy();
  @State private traffic: NetworkUsage = { since_date: 0, entries: [] };
  @State private selected: string[] = [];
  @State private selectedNetwork: string = 'wifi';
  @State private loading: boolean = true;
  @State private saving: boolean = false;
  @State private error: string = '';
  @State private notice: string = '';
  @State private detectedNetwork: string = 'unknown';
  private networkTimer: number = -1;
  private routeChanged(): void { this.error = ''; if (this.route === 'storage') { this.loading = false; } }
  private live: boolean = true;
  private revision: number = 0;
  aboutToAppear(): void { this.live = true; this.detectedNetwork = this.manager.currentNetwork();
    this.networkTimer = setInterval(() => { this.detectedNetwork = this.manager.currentNetwork(); }, 2000);
    this.policy = this.manager.settings(); this.refresh(); }
  aboutToDisappear(): void { this.live = false; this.revision++; if (this.networkTimer >= 0) { clearInterval(this.networkTimer); this.networkTimer = -1; } }
  private ink(): string { return this.dark ? '#EEF4FC' : '#162B40'; }
  private muted(): string { return this.dark ? '#94A6BA' : '#8493A5'; }
  private pageColor(): string { return this.dark ? '#101A25' : '#F4F7FB'; }
  private surface(): string { return this.dark ? '#182430' : '#FFFFFF'; }
  private line(): string { return this.dark ? '#293A49' : '#EDF1F5'; }
  private title(): string { return this.route === 'network' ? '网络用量' : this.route === 'auto' ? this.networkLabel(this.selectedNetwork) + '自动下载' : '存储管理'; }
  private networkLabel(kind: string): string { return kind === 'wifi' ? 'Wi-Fi' : kind === 'mobile' ? '移动网络' : kind === 'roaming' ? '漫游' : kind === 'none' ? '无网络' : '未识别网络'; }
  private profile(kind: string): DownloadProfile { return kind === 'wifi' ? this.policy.wifi : kind === 'mobile' ? this.policy.mobile : this.policy.roaming; }
  private currentProfile(): DownloadProfile { return this.profile(this.selectedNetwork); }
  private selectionBytes(): number { return this.snapshot.categories.filter((c: CacheCategory) => c.cleanable && this.selected.includes(c.id)).reduce((n: number, c: CacheCategory) => n + c.bytes, 0); }
  private toggleCategory(id: string): void { this.selected = this.selected.includes(id) ? this.selected.filter((value: string) => value !== id) : this.selected.concat([id]); }
  private values(): number[] { const list = this.snapshot.categories.filter((c: CacheCategory) => c.bytes > 0); return list.length && this.snapshot.bytes > 0 ? list.map((c: CacheCategory) => c.bytes * 100 / this.snapshot.bytes) : [100]; }
  private colors(): ResourceColor[] { const list = this.snapshot.categories.filter((c: CacheCategory) => c.bytes > 0); return list.length ? list.map((c: CacheCategory): ResourceColor => c.color) : ['#D6DEE7']; }
  private async refresh(): Promise<void> {
    const revision = ++this.revision, account = this.manager.currentAccount();
    this.loading = true; this.error = '';
    try {
      const snapshot = await this.manager.read();
      if (!this.live || revision !== this.revision || account !== this.manager.currentAccount()) { return; }
      this.snapshot = snapshot;
      this.selected = snapshot.categories.filter((c: CacheCategory) => c.cleanable && c.bytes > 0).map((c: CacheCategory) => c.id);
      this.policy = this.manager.settings();
    } catch (error) { if (this.live && revision === this.revision) { this.error = (error as Error).message || '无法读取存储用量，请重试'; } }
    finally { if (this.live && revision === this.revision) { this.loading = false; } }
  }
  private async change(change: (policy: MediaPolicy) => void): Promise<void> {
    if (this.saving) { return; }
    const account = this.manager.currentAccount(), next = cloneMediaPolicy(this.policy); change(next); this.policy = next; this.saving = true; this.error = ''; this.notice = '';
    try {
      await this.manager.savePolicy(next);
      if (!this.live || account !== this.manager.currentAccount()) { return; }
      this.policy = this.manager.settings(); await this.manager.maintain(true);
    } catch (error) { if (this.live && account === this.manager.currentAccount()) { this.policy = this.manager.settings(); this.error = (error as Error).message || '设置保存失败，请重试'; } }
    finally { if (this.live) { this.saving = false; } }
  }
  private editDays(kind: string): void {
    this.getUIContext().getPromptAction().showDialog({ title: kind === 'private' ? '私聊缓存保留时间' : kind === 'group' ? '群组缓存保留时间' : '频道缓存保留时间',
      buttons: RETENTION_DAYS.map((days: number): promptAction.Button => ({ text: retentionLabel(days), color: '#268BDE' }))
    }).then((result) => {
      const days = RETENTION_DAYS[result.index]; if (days === undefined || !this.live) { return; }
      this.change((p: MediaPolicy) => { if (kind === 'private') { p.privateDays = days; } else if (kind === 'group') { p.groupDays = days; } else { p.channelDays = days; } });
    }).catch(() => {});
  }
  private editLimit(): void {
    this.getUIContext().getPromptAction().showDialog({ title: '媒体缓存上限', buttons: CACHE_LIMITS.map((bytes: number): promptAction.Button => ({ text: bytes ? formatStorageBytes(bytes) : '不限', color: '#268BDE' })) })
      .then((result) => { const bytes = CACHE_LIMITS[result.index]; if (bytes !== undefined && this.live) { this.change((p: MediaPolicy) => { p.cacheLimit = bytes; }); } }).catch(() => {});
  }
  private confirmClear(chat?: CacheChat): void {
    if (this.saving || !this.selected.length) { return; }
    const ids = this.selected.slice(), scope = chat ? [chat.id] : [], account = this.manager.currentAccount();
    this.getUIContext().getPromptAction().showDialog({ title: chat ? '清除此会话的缓存？' : '清除已选缓存？',
      message: chat ? '按已选类型清理此会话的本地缓存，不会删除云端消息。' : `将清理当前账户约 ${formatStorageBytes(this.selectionBytes())} 的本地缓存，不会删除云端消息、登录信息和待发送媒体。`,
      buttons: [{ text: '取消', color: '#8493A5' }, { text: '清除缓存', color: '#D56464' }]
    }).then(async (result) => {
      if (result.index !== 1 || !this.live || account !== this.manager.currentAccount()) { return; }
      this.saving = true; this.error = ''; this.notice = '';
      try {
        const bytes = await this.manager.clear(ids, scope);
        if (this.live && account === this.manager.currentAccount()) { this.notice = '已释放 ' + formatStorageBytes(bytes); await this.refresh(); }
      } catch (error) { if (this.live) { this.error = (error as Error).message || '缓存清理失败，请重试'; } }
      finally { if (this.live) { this.saving = false; } }
    }).catch(() => {});
  }
  private profileSummary(kind: string): string {
    const p = this.profile(kind); if (!p.enabled) { return '关闭'; }
    const values: string[] = [];
    if (p.photos) { values.push('图片 ' + formatStorageBytes(p.photoLimit)); }
    if (p.videos) { values.push('视频 ' + formatStorageBytes(p.videoLimit)); }
    if (p.animations) { values.push('动图 ' + formatStorageBytes(p.animationLimit)); }
    return values.length ? values.join('、') : '未选择媒体类型';
  }
  private setProfileEnabled(kind: string, enabled: boolean): void {
    if (this.profile(kind).enabled === enabled) { return; }
    this.change((p: MediaPolicy) => { const profile = kind === 'wifi' ? p.wifi : kind === 'mobile' ? p.mobile : p.roaming; profile.enabled = enabled; });
  }
  private setMediaEnabled(kind: string, enabled: boolean): void {
    const current = this.currentProfile();
    if ((kind === 'photo' ? current.photos : kind === 'video' ? current.videos : current.animations) === enabled) { return; }
    this.change((p: MediaPolicy) => {
      const value = this.selectedNetwork === 'wifi' ? p.wifi : this.selectedNetwork === 'mobile' ? p.mobile : p.roaming;
      if (kind === 'photo') { value.photos = enabled; } else if (kind === 'video') { value.videos = enabled; } else { value.animations = enabled; }
    });
  }
  private editMediaLimit(kind: string): void {
    const sizes: number[] = (kind === 'photo' ? [1, 5, 10, 20] : [1, 5, 10, 20, 50, 100, 500]).map((n: number) => n * 1024 ** 2);
    this.getUIContext().getPromptAction().showDialog({ title: '自动下载大小上限', buttons: sizes.map((bytes: number): promptAction.Button => ({ text: formatStorageBytes(bytes), color: '#268BDE' })) })
      .then((result) => {
        const bytes = sizes[result.index]; if (!bytes || !this.live) { return; }
        this.change((p: MediaPolicy) => { const value = this.selectedNetwork === 'wifi' ? p.wifi : this.selectedNetwork === 'mobile' ? p.mobile : p.roaming;
          if (kind === 'photo') { value.photoLimit = bytes; } else if (kind === 'video') { value.videoLimit = bytes; } else { value.animationLimit = bytes; } });
      }).catch(() => {});
  }
  private async openNetwork(): Promise<void> {
    this.route = 'network'; this.loading = true; this.error = '';
    try { const value = await this.manager.traffic(); if (this.live && this.route === 'network') { this.traffic = value; } }
    catch (error) { if (this.live && this.route === 'network') { this.error = (error as Error).message || '无法读取网络用量'; } }
    finally { if (this.live && this.route === 'network') { this.loading = false; } }
  }
  private networkBytes(kind: string, sent: boolean): number {
    const type = kind === 'wifi' ? 'networkTypeWiFi' : kind === 'mobile' ? 'networkTypeMobile' : kind === 'roaming' ? 'networkTypeMobileRoaming' : 'networkTypeOther';
    return this.traffic.entries.filter((entry) => entry.network_type['@type'] === type).reduce((total: number, entry) => total + (sent ? entry.sent_bytes : entry.received_bytes), 0);
  }
  @Builder private section(title: string) { Text(title).fontSize(13).fontColor('#268BDE').width('100%').padding({ left: 14, top: 22, bottom: 9 }) }
  @Builder private usage() {
    Column({ space: 12 }) {
      Stack() {
        DataPanel({ values: this.values(), max: 100, type: DataPanelType.Circle }).valueColors(this.colors()).strokeWidth(23).closeEffect(true).width(216).height(216)
        Column({ space: 6 }) {
          Text(formatStorageBytes(this.snapshot.bytes)).fontSize(27).fontWeight(FontWeight.Medium).fontColor(this.ink())
          Text('当前账户缓存').fontSize(13).fontColor(this.muted())
        }
      }.margin({ top: 18, bottom: 8 })
      if (this.snapshot.diskTotal > 0) {
        Text('占设备存储 ' + (this.snapshot.bytes * 100 / this.snapshot.diskTotal < 0.1 ? '<0.1%' : (this.snapshot.bytes * 100 / this.snapshot.diskTotal).toFixed(1) + '%'))
          .fontSize(12).fontColor(this.muted())
        Text('设备可用 ' + formatStorageBytes(this.snapshot.diskFree)).fontSize(12).fontColor(this.muted())
      }
      Column() {
        ForEach(this.snapshot.categories.filter((c: CacheCategory) => c.bytes > 0), (category: CacheCategory) => {
          Row({ space: 12 }) {
            if (category.cleanable) {
              Checkbox({ name: category.id }).select(this.selected.includes(category.id)).selectedColor(category.color).width(22).height(22)
                .enabled(!this.saving).onChange((checked: boolean) => { if (this.selected.includes(category.id) !== checked) { this.toggleCategory(category.id); } })
            } else { Text('•').fontSize(30).fontColor(category.color).width(22).textAlign(TextAlign.Center) }
            Text(category.label).fontSize(14).fontColor(this.ink()).layoutWeight(1).onClick(() => { if (category.cleanable && !this.saving) { this.toggleCategory(category.id); } })
            Text(Math.round(category.bytes * 100 / Math.max(1, this.snapshot.bytes)) + '%').fontSize(11).fontColor(this.muted())
            Text(formatStorageBytes(category.bytes)).fontSize(14).fontColor('#268BDE')
          }.padding({ left: 16, right: 16 }).height(54)
          Divider().color(this.line()).margin({ left: 50, right: 16 })
        }, (c: CacheCategory) => c.id)
        if (this.snapshot.bytes === 0) { Text('暂无媒体缓存').fontSize(14).fontColor(this.muted()).padding(20) }
        Button(this.saving ? '正在处理…' : '清除缓存 · ' + formatStorageBytes(this.selectionBytes()))
          .height(46).width('90%').fontSize(15).fontColor(Color.White).backgroundColor('#268BDE')
          .margin({ top: 12, bottom: 16 }).enabled(!this.saving && this.selectionBytes() > 0).onClick(() => this.confirmClear())
      }.width('100%').backgroundColor(this.surface()).borderRadius(18)
      Text('清理后可重新下载媒体。消息、登录信息与待发送文件会保留。').fontSize(12).fontColor(this.muted()).lineHeight(18).width('100%').padding({ left: 12, right: 12 })
    }.width('100%')
    this.section('自动清理缓存')
    Column() {
      StorageValueRow({ title: '私聊', value: retentionLabel(this.policy.privateDays), action: () => this.editDays('private'), isEnabled: !this.saving, dark: this.dark })
      Divider().color(this.line()).margin({ left: 16, right: 16 })
      StorageValueRow({ title: '群组', value: retentionLabel(this.policy.groupDays), action: () => this.editDays('group'), isEnabled: !this.saving, dark: this.dark })
      Divider().color(this.line()).margin({ left: 16, right: 16 })
      StorageValueRow({ title: '频道', value: retentionLabel(this.policy.channelDays), action: () => this.editDays('channel'), isEnabled: !this.saving, dark: this.dark })
      Divider().color(this.line()).margin({ left: 16, right: 16 })
      StorageValueRow({ title: '缓存上限', value: this.policy.cacheLimit ? formatStorageBytes(this.policy.cacheLimit) : '不限', action: () => this.editLimit(), isEnabled: !this.saving, dark: this.dark })
    }.width('100%').backgroundColor(this.surface()).borderRadius(18)
    Text('按上次访问时间清理；在应用运行时执行，正在使用的会话会跳过。').fontSize(12).fontColor(this.muted()).width('100%').padding({ left: 12, right: 12, top: 8 })
    this.section('自动下载媒体')
    Column() {
      ForEach(['mobile', 'wifi', 'roaming'], (kind: string) => {
        StorageToggleRow({ title: this.networkLabel(kind), subtitle: this.profileSummary(kind), checked: this.profile(kind).enabled, action: (checked: boolean) => this.setProfileEnabled(kind, checked), open: () => { this.selectedNetwork = kind; this.route = 'auto'; }, isEnabled: !this.saving, dark: this.dark })
        if (kind !== 'roaming') { Divider().color(this.line()).margin({ left: 16, right: 16 }) }
      })
    }.width('100%').backgroundColor(this.surface()).borderRadius(18)
    Text('当前网络：' + this.networkLabel(this.detectedNetwork)).fontSize(12).fontColor(this.muted()).padding({ left: 12, top: 8 }).width('100%')
    this.section('网络与本地数据')
    Column() {
      StorageValueRow({ title: '网络用量', value: '', action: () => this.openNetwork(), isEnabled: !this.saving, dark: this.dark })
      Divider().color(this.line()).margin({ left: 16, right: 16 })
      this.infoRow('消息数据库', formatStorageBytes(this.snapshot.databaseBytes))
      this.infoRow('日志', formatStorageBytes(this.snapshot.logBytes))
      this.infoRow('上传暂存（保留）', this.snapshot.temporaryBytes < 0 ? '暂不可用' : formatStorageBytes(this.snapshot.temporaryBytes))
    }.width('100%').backgroundColor(this.surface()).borderRadius(18)
    if (this.snapshot.chats.length) {
      this.section('按会话清理')
      Column() {
        ForEach(this.snapshot.chats, (chat: CacheChat) => {
          StorageValueRow({ title: chat.title, value: formatStorageBytes(chat.bytes), action: () => this.confirmClear(chat), isEnabled: !this.saving, dark: this.dark })
        }, (chat: CacheChat) => String(chat.id))
      }.width('100%').backgroundColor(this.surface()).borderRadius(18)
    }
  }
  @Builder private infoRow(title: string, value: string) {
    Row() { Text(title).fontSize(14).fontColor(this.ink()).layoutWeight(1); Text(value).fontSize(13).fontColor(this.muted()) }
      .width('100%').height(48).padding({ left: 16, right: 16 })
  }
  @Builder private automatic() {
    Column() {
      StorageToggleRow({ title: '自动下载', subtitle: this.profileSummary(this.selectedNetwork), checked: this.currentProfile().enabled, action: (checked: boolean) => this.setProfileEnabled(this.selectedNetwork, checked), open: () => {}, isEnabled: !this.saving, dark: this.dark })
      Divider().color(this.line())
      ForEach(['photo', 'video', 'animation'], (kind: string) => {
        StorageToggleRow({ title: kind === 'photo' ? '图片' : kind === 'video' ? '视频' : '动图', subtitle: formatStorageBytes(kind === 'photo' ? this.currentProfile().photoLimit : kind === 'video' ? this.currentProfile().videoLimit : this.currentProfile().animationLimit), checked: kind === 'photo' ? this.currentProfile().photos : kind === 'video' ? this.currentProfile().videos : this.currentProfile().animations, action: (checked: boolean) => this.setMediaEnabled(kind, checked), open: () => this.editMediaLimit(kind), isEnabled: !this.saving, dark: this.dark })
      })
    }.width('100%').backgroundColor(this.surface()).borderRadius(18).margin({ top: 16 })
    Text('点击大小可调整上限；手动下载不受自动下载设置限制。').fontSize(12).fontColor(this.muted()).lineHeight(18).padding(12)
  }
  @Builder private trafficPage() {
    if (this.traffic.since_date > 0) {
      Text('自 ' + new Date(this.traffic.since_date * 1000).toLocaleDateString()).fontSize(12).fontColor(this.muted()).padding(16)
    }
    ForEach(['wifi', 'mobile', 'roaming', 'other'], (kind: string) => {
      this.section(kind === 'other' ? '其他网络' : this.networkLabel(kind))
      Column() { this.infoRow('已发送', formatStorageBytes(this.networkBytes(kind, true))); this.infoRow('已接收', formatStorageBytes(this.networkBytes(kind, false))) }
        .width('100%').backgroundColor(this.surface()).borderRadius(18)
    })
  }
  @Builder
  private storageBody() {
      Scroll() {
        Column() {
          if (this.error) { Text(this.error).fontSize(13).fontColor('#D56464').width('100%').padding(12) }
          if (this.notice) { Text(this.notice).fontSize(13).fontColor('#268BDE').width('100%').padding(12) }
          if (this.loading) { LoadingProgress().width(36).height(36).margin(32) }
          else if (this.route === 'auto') { this.automatic() }
          else if (this.route === 'network') { this.trafficPage() }
          else { this.usage() }
        }.width('100%').padding({ left: 16, right: 16, bottom: 28 }).alignItems(HorizontalAlign.Start)
      }.width('100%').height('100%').scrollBar(BarState.Off).align(Alignment.Top)

  }

  build() {
    HdsPage({ title: this.title(), dark: this.dark, isEnabled: !this.saving,
      onBack: () => { if (this.route !== 'storage') this.route = 'storage'; else this.onClose(); },
      firstLabel: this.route === 'auto' ? '' : '刷新', firstEnabled: !this.loading && !this.saving, firstSymbol: $r('sys.symbol.arrow_clockwise'),
      firstAction: () => { if (!this.loading && !this.saving) { if (this.route === 'network') this.openNetwork(); else this.refresh(); } }
    , content: () => { this.storageBody() } }).width('100%').height('100%').backgroundColor(this.pageColor())
  }
}
