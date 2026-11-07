import { TextModifier } from '@kit.ArkUI';
import { HdsListItemCard, SuffixButton, SuffixIcon, SuffixLoadingProgress, SuffixSwitch } from '@kit.UIDesignKit';
import { describe, isRetryable } from '../model/ClashError';
import { DelayEntry } from '../model/ClashModels';

/**
 * 网络代理页的行级展示组件。
 *
 * 这些组件只接收展示数据与回调，不读取 ClashService、不持久化、不发起命令。
 * 状态与错误文案来自 ClashError.describe() 或本文件的常量表，避免页面出现第二份文案。
 */

const ACCENT: string = '#268BDE';
const SUCCESS: string = '#2E9E6A';
const WARNING: string = '#C98A2E';
const DANGER: string = '#D56464';
const NEUTRAL: string = '#8493A5';
const NEUTRAL_DARK: string = '#94A6BA';
const UNKNOWN: string = '未知';

/** 延迟徽标的语义色调；只用于展示，不代表代理整体状态。 */
export type DelayTone = 'neutral' | 'good' | 'warn' | 'bad';

/** 延迟徽标文案；与 ClashModels.DelayState 一一对应，不在页面重复拼接。 */
const DELAY_IDLE: string = '未测';
const DELAY_LOADING: string = '测速中';
const DELAY_TIMEOUT: string = '超时';
const DELAY_FAILED: string = '失败';

const SWITCH_OPEN: string = '开启';
const SWITCH_CLOSE: string = '关闭';

const PROFILE_MENU_LABEL: string = '配置操作';
/** 更新成功但未应用时的唯一文案；页面提示也引用本常量。 */
export const PROFILE_PENDING_TEXT: string = '有新版本，点击应用';

const STATUS_UNCONFIGURED_TITLE: string = '尚未导入配置';
const STATUS_UNCONFIGURED_DETAIL: string = '导入订阅或本地配置后即可开启';
const STATUS_UNAUTHORIZED_DETAIL: string = '重新开启并允许系统授权';
const STATUS_PREPARING_TITLE: string = '正在启动代理…';
const STATUS_PREPARING_DETAIL: string = '首次开启可能需要几秒';
const STATUS_APPLY_TITLE: string = '正在应用配置';
const STATUS_APPLY_DETAIL: string = '完成前不会显示已连接';
const STATUS_SCOPE_TITLE: string = '正在应用网络范围';
const STATUS_SCOPE_DETAIL: string = '完成前不会显示已连接';
const STATUS_RECONNECT_TITLE: string = '正在重新连接';
const STATUS_RECONNECT_DETAIL: string = '正在恢复代理连接';
const STATUS_STOPPING_TITLE: string = '正在停止代理…';
const STATUS_STOPPING_DETAIL: string = '完成前不会显示已停止';
const STATUS_CONNECTED_TITLE: string = '已连接';
const STATUS_STOPPED_TITLE: string = '已停止';
const STATUS_STOPPED_DETAIL: string = '开启后可继续使用';
const STATUS_STOPPED_WARNING_TITLE: string = '已停止，但存在未释放资源';
const STATUS_STOPPED_WARNING_DETAIL: string = '重试清理或重启应用';

/** 延迟结果到展示文案的唯一映射。0 不是成功，必须使用 state。 */
export function delayLabel(entry: DelayEntry | undefined): string {
  if (entry === undefined) {
    return DELAY_IDLE;
  }
  if (entry.state === 'loading') {
    return DELAY_LOADING;
  }
  if (entry.state === 'ok' && entry.value > 0) {
    return String(Math.round(entry.value)) + ' ms';
  }
  if (entry.state === 'failed') {
    return entry.value === -1 ? DELAY_FAILED : DELAY_TIMEOUT;
  }
  return DELAY_IDLE;
}

/** 延迟结果到语义色调；超时与失败使用提示色，成功按毫秒分层。 */
export function delayTone(entry: DelayEntry | undefined): DelayTone {
  if (entry === undefined || entry.state === 'idle' || entry.state === 'loading') {
    return 'neutral';
  }
  if (entry.state === 'failed') {
    return 'bad';
  }
  if (entry.state === 'ok' && entry.value > 0) {
    if (entry.value <= 200) {
      return 'good';
    }
    if (entry.value <= 500) {
      return 'warn';
    }
    return 'bad';
  }
  return 'neutral';
}

/** 更新时间只显示到分钟，避免列表被长文本撑开；缺失时如实标注。 */
export function formatUpdatedAt(value: number | undefined): string {
  if (value === undefined || value <= 0) {
    return '尚未更新';
  }
  const date: Date = new Date(value);
  const month: string = date.getMonth() + 1 < 10 ? '0' + String(date.getMonth() + 1) : String(date.getMonth() + 1);
  const day: string = date.getDate() < 10 ? '0' + String(date.getDate()) : String(date.getDate());
  const hour: string = date.getHours() < 10 ? '0' + String(date.getHours()) : String(date.getHours());
  const minute: string = date.getMinutes() < 10 ? '0' + String(date.getMinutes()) : String(date.getMinutes());
  return String(date.getFullYear()) + '/' + month + '/' + day + ' ' + hour + ':' + minute;
}

/** 把语义色调映射为具体颜色；深色下提高中性色亮度。接受字符串以便组件属性复用。 */
function toneColor(tone: string, dark: boolean): ResourceColor {
  if (tone === 'good') {
    return SUCCESS;
  }
  if (tone === 'warn') {
    return WARNING;
  }
  if (tone === 'bad') {
    return DANGER;
  }
  return dark ? NEUTRAL_DARK : NEUTRAL;
}

/** HDS 只允许 Text 修饰器改颜色；这里把延迟色调应用到整行副文案。 */
class ToneTextModifier extends TextModifier {
  private tone: ResourceColor;

  constructor(color: ResourceColor) {
    super();
    this.tone = color;
  }

  applyNormalAttribute(instance: TextAttribute): void {
    instance.fontColor(this.tone);
  }
}

/** 状态卡：状态点 + 主副文案 + 节点/内核版本 + 错误摘要与动作。 */
@Component
export struct ProxyStatusCard {
  @Prop state: string = 'unconfigured';
  @Prop preparingReason: string = '';
  /** 停止流程进行中；此时不得显示已连接的成功色。 */
  @Prop stopping: boolean = false;
  @Prop coreVersion: string = '';
  @Prop currentNode: string = '';
  @Prop errorCode: string = '';
  @Prop stopWarning: boolean = false;
  @Prop dark: boolean = false;
  onRetry: () => void = () => {};
  onDetail: () => void = () => {};

  private ink(): string {
    return this.dark ? '#EEF4FC' : '#162B40';
  }

  private muted(): string {
    return this.dark ? NEUTRAL_DARK : NEUTRAL;
  }

  private surface(): string {
    return this.dark ? '#182430' : '#FFFFFF';
  }

  private line(): string {
    return this.dark ? '#293A49' : '#EDF1F5';
  }

  private effectiveErrorCode(): string {
    if (this.errorCode.length > 0) {
      return this.errorCode;
    }
    if (this.state === 'failed') {
      return 'internal';
    }
    if (this.state === 'unauthorized') {
      return 'tun_create_denied';
    }
    return '';
  }

  private errorVisible(): boolean {
    return !this.stopping && (this.state === 'failed' || this.state === 'unauthorized') &&
      this.effectiveErrorCode().length > 0;
  }

  private showRetry(): boolean {
    if (this.stopping) {
      return false;
    }
    if (this.stopWarning) {
      return true;
    }
    const code: string = this.effectiveErrorCode();
    return this.errorVisible() && code.length > 0 && isRetryable(code);
  }

  private statusTitle(): string {
    if (this.stopping) {
      return STATUS_STOPPING_TITLE;
    }
    if (this.state === 'connected') {
      return STATUS_CONNECTED_TITLE;
    }
    if (this.state === 'preparing') {
      if (this.preparingReason === 'apply') {
        return STATUS_APPLY_TITLE;
      }
      if (this.preparingReason === 'scope') {
        return STATUS_SCOPE_TITLE;
      }
      if (this.preparingReason === 'reconnect') {
        return STATUS_RECONNECT_TITLE;
      }
      return STATUS_PREPARING_TITLE;
    }
    if (this.state === 'stopped') {
      return this.stopWarning ? STATUS_STOPPED_WARNING_TITLE : STATUS_STOPPED_TITLE;
    }
    if (this.state === 'failed' || this.state === 'unauthorized') {
      return describe(this.effectiveErrorCode()).title;
    }
    return STATUS_UNCONFIGURED_TITLE;
  }

  private statusDetail(): string {
    if (this.stopping) {
      return STATUS_STOPPING_DETAIL;
    }
    if (this.state === 'connected') {
      return '当前节点：' + (this.currentNode.length > 0 ? this.currentNode : UNKNOWN);
    }
    if (this.state === 'preparing') {
      if (this.preparingReason === 'apply') {
        return STATUS_APPLY_DETAIL;
      }
      if (this.preparingReason === 'scope') {
        return STATUS_SCOPE_DETAIL;
      }
      if (this.preparingReason === 'reconnect') {
        return STATUS_RECONNECT_DETAIL;
      }
      return STATUS_PREPARING_DETAIL;
    }
    if (this.state === 'stopped') {
      return this.stopWarning ? STATUS_STOPPED_WARNING_DETAIL : STATUS_STOPPED_DETAIL;
    }
    if (this.state === 'unauthorized') {
      return STATUS_UNAUTHORIZED_DETAIL;
    }
    if (this.state === 'failed') {
      return describe(this.effectiveErrorCode()).nextAction;
    }
    return STATUS_UNCONFIGURED_DETAIL;
  }

  private dotColor(): string {
    if (this.stopping) {
      return ACCENT;
    }
    if (this.state === 'connected') {
      return SUCCESS;
    }
    if (this.state === 'failed') {
      return DANGER;
    }
    if (this.state === 'unauthorized') {
      return WARNING;
    }
    if (this.state === 'preparing') {
      return ACCENT;
    }
    return this.dark ? NEUTRAL_DARK : NEUTRAL;
  }

  private nodeText(): string {
    return this.currentNode.length > 0 ? this.currentNode : UNKNOWN;
  }

  private coreText(): string {
    return this.coreVersion.length > 0 ? this.coreVersion : UNKNOWN;
  }

  build() {
    Column({ space: 12 }) {
      Row({ space: 9 }) {
        Row()
          .width(10)
          .height(10)
          .borderRadius(5)
          .backgroundColor(this.dotColor())
        Text(this.statusTitle()).fontSize(17).fontWeight(FontWeight.Medium).fontColor(this.ink())
          .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
      }.width('100%').alignItems(VerticalAlign.Center)

      Text(this.statusDetail()).fontSize(13).fontColor(this.muted()).lineHeight(19)
        .width('100%').maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })

      Row({ space: 22 }) {
        Column({ space: 3 }) {
          Text('生效节点').fontSize(11).fontColor(this.muted()).width('100%')
          Text(this.nodeText()).fontSize(14).fontColor(this.ink()).width('100%')
            .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        Column({ space: 3 }) {
          Text('内核版本').fontSize(11).fontColor(this.muted()).width('100%')
          Text(this.coreText()).fontSize(14).fontColor(this.ink()).width('100%')
            .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      }.width('100%').alignItems(VerticalAlign.Top)

      if (this.errorVisible()) {
        Divider().color(this.line())
        Column({ space: 4 }) {
          Text(describe(this.effectiveErrorCode()).title).fontSize(13).fontWeight(FontWeight.Medium)
            .fontColor(DANGER).width('100%').maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(describe(this.effectiveErrorCode()).nextAction).fontSize(12).fontColor(this.muted())
            .width('100%').maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
        }.width('100%').alignItems(HorizontalAlign.Start)
      }

      if (this.showRetry() || this.errorVisible()) {
        Row({ space: 10 }) {
          if (this.errorVisible()) {
            Button('查看详情').buttonStyle(ButtonStyleMode.TEXTUAL).fontColor(ACCENT)
              .height(44).layoutWeight(1).onClick(() => this.onDetail())
              .accessibilityText('查看代理错误详情')
          }
          if (this.showRetry()) {
            Button('重试').buttonStyle(ButtonStyleMode.EMPHASIZED)
              .height(44).layoutWeight(1).onClick(() => this.onRetry())
              .accessibilityText('重试代理操作')
          }
        }.width('100%')
      }
    }
    .width('100%')
    .padding(16)
    .backgroundColor(this.surface())
    .borderRadius(16)
    .alignItems(HorizontalAlign.Start)
  }
}

/** 主开关/范围开关行：HDS 原生列表卡与开关，忙碌时只显示进度。 */
@Component
export struct ProxySwitchRow {
  @Prop title: string = '';
  @Prop subtitle: string = '';
  @Prop checked: boolean = false;
  @Prop isEnabled: boolean = true;
  @Prop busy: boolean = false;
  @Prop stateLabel: string = '';
  /** 自定义读屏文案；不能命名为 accessibilityText，会与组件基类同名方法冲突。 */
  @Prop a11yLabel: string = '';
  @Prop dark: boolean = false;
  onChange: (value: boolean) => void = () => {};

  private label(): string {
    if (this.a11yLabel.length > 0) {
      return this.a11yLabel;
    }
    const action: string = this.checked ? SWITCH_CLOSE : SWITCH_OPEN;
    const current: string = this.stateLabel.length > 0 ? this.stateLabel : (this.checked ? '已连接' : '未开启');
    return action + this.title + '，当前' + current;
  }

  build() {
    HdsListItemCard({
      textItem: {
        primaryText: { text: this.title },
        secondaryText: { text: this.subtitle }
      },
      suffixItem: this.busy
        ? new SuffixLoadingProgress({ color: ACCENT })
        : new SuffixSwitch({
          isCheck: this.checked,
          enable: this.isEnabled && !this.busy,
          onChange: (value: boolean) => this.onChange(value),
          accessibilityOptions: { accessibilityText: this.label() }
        }),
      cardBackgroundColor: Color.Transparent,
      enable: this.isEnabled && !this.busy,
      accessibilityOptions: { accessibilityText: this.label() }
    }).width('100%')
  }
}

/** 配置/订阅行：名称、来源、节点数、更新时间、生效标记与行菜单。 */
@Component
export struct ProxyProfileRow {
  @Prop name: string = '';
  @Prop sourceLabel: string = '';
  @Prop nodeCount: number = 0;
  @Prop updatedAt: number = 0;
  @Prop active: boolean = false;
  @Prop pending: boolean = false;
  @Prop failureText: string = '';
  @Prop busy: boolean = false;
  @Prop busyLabel: string = '';
  @Prop dark: boolean = false;
  @Prop isEnabled: boolean = true;
  onOpen: () => void = () => {};
  onMenu: () => void = () => {};

  private muted(): string {
    return this.dark ? NEUTRAL_DARK : NEUTRAL;
  }

  private secondary(): string {
    const parts: string[] = [];
    if (this.active) {
      parts.push('使用中');
    }
    if (this.sourceLabel.length > 0) {
      parts.push(this.sourceLabel);
    }
    parts.push(String(this.nodeCount) + ' 个节点');
    parts.push('更新 ' + formatUpdatedAt(this.updatedAt));
    return parts.join(' · ');
  }

  private description(): string {
    if (this.busy) {
      return this.busyLabel;
    }
    if (this.pending) {
      return PROFILE_PENDING_TEXT;
    }
    return this.failureText;
  }

  private descriptionModifier(): TextModifier {
    const modifier: ToneTextModifier = new ToneTextModifier(
      this.failureText.length > 0 && !this.pending && !this.busy ? DANGER : (this.pending ? ACCENT : this.muted())
    );
    return modifier;
  }

  private accessibilityLabel(): string {
    const state: string = this.active ? '，使用中' : '';
    const pending: string = this.pending ? '，有新版本待应用' : '';
    return this.name + '，' + this.sourceLabel + '，' + String(this.nodeCount) + ' 个节点' + state + pending;
  }

  build() {
    HdsListItemCard({
      textItem: {
        primaryText: { text: this.name },
        primarySuffixSymbol: this.active ? { symbol: $r('sys.symbol.checkmark') } : undefined,
        secondaryText: { text: this.secondary() },
        description: this.description().length > 0
          ? { text: this.description(), modifier: this.descriptionModifier() }
          : undefined
      },
      suffixItem: this.busy
        ? new SuffixLoadingProgress({ color: ACCENT })
        : new SuffixIcon({
          iconValue: { symbol: $r('sys.symbol.ellipsis_circle') },
          enable: this.isEnabled && !this.busy,
          onClick: () => this.onMenu(),
          accessibilityOptions: { accessibilityText: PROFILE_MENU_LABEL + '：' + this.name }
        }),
      cardBackgroundColor: Color.Transparent,
      enable: this.isEnabled && !this.busy,
      onClick: () => this.onOpen(),
      accessibilityOptions: { accessibilityText: this.accessibilityLabel() }
    }).width('100%')
  }
}

/**
 * 节点行：协议、延迟徽标、选中标记与单点测速。
 * HDS 没有前景单选组件，选中态用 primarySuffixSymbol 的对勾表达；
 * 整行点击选择，自动组由 selectable=false 关闭入口。
 */
@Component
export struct ProxyNodeRow {
  @Prop name: string = '';
  @Prop protocolLabel: string = '';
  @Prop delayText: string = DELAY_IDLE;
  @Prop delayTone: string = 'neutral';
  @Prop delayLoading: boolean = false;
  @Prop selected: boolean = false;
  @Prop switching: boolean = false;
  @Prop selectable: boolean = true;
  @Prop testEnabled: boolean = true;
  @Prop dark: boolean = false;
  onSelect: () => void = () => {};
  onTest: () => void = () => {};

  private secondary(): string {
    if (this.switching) {
      return this.protocolLabel + ' · 正在切换';
    }
    if (this.delayLoading) {
      return this.protocolLabel + ' · ' + DELAY_LOADING;
    }
    return this.protocolLabel + ' · ' + this.delayText;
  }

  private secondaryModifier(): TextModifier {
    const tone: ResourceColor = this.switching || this.delayLoading
      ? ACCENT
      : toneColor(this.delayTone, this.dark);
    const modifier: ToneTextModifier = new ToneTextModifier(tone);
    return modifier;
  }

  private accessibilityLabel(): string {
    const selected: string = this.selected ? '，已选中' : '';
    return this.name + '，' + this.protocolLabel + '，延迟' + this.delayText + selected;
  }

  private select(): void {
    if (this.selectable && !this.switching) {
      this.onSelect();
    }
  }

  build() {
    HdsListItemCard({
      textItem: {
        primaryText: { text: this.name },
        primarySuffixSymbol: this.selectable && this.selected ? { symbol: $r('sys.symbol.checkmark') } : undefined,
        secondaryText: { text: this.secondary(), modifier: this.secondaryModifier() }
      },
      suffixItem: this.switching || this.delayLoading
        ? new SuffixLoadingProgress({ color: ACCENT })
        : new SuffixButton({
          text: '测速',
          textColor: ACCENT,
          enable: this.testEnabled && !this.switching,
          onClick: () => this.onTest(),
          accessibilityOptions: { accessibilityText: '测试 ' + this.name + ' 的延迟' }
        }),
      cardBackgroundColor: Color.Transparent,
      enable: !this.switching,
      onClick: () => this.select(),
      accessibilityOptions: {
        accessibilityText: this.accessibilityLabel(),
        accessibilityChecked: this.selected
      }
    }).width('100%')
  }
}

/** 错误详情：只渲染 ClashError.describe()，可聚焦、可整块朗读。 */
@Component
export struct ProxyErrorDetail {
  @Prop errorCode: string = 'internal';
  @Prop dark: boolean = false;

  private ink(): string {
    return this.dark ? '#EEF4FC' : '#162B40';
  }

  private title(): string {
    return describe(this.errorCode).title;
  }

  private detail(): string {
    return describe(this.errorCode).detail;
  }

  private nextAction(): string {
    return describe(this.errorCode).nextAction;
  }

  private spoken(): string {
    return this.title() + '。' + this.detail() + '。下一步：' + this.nextAction();
  }

  build() {
    Column({ space: 10 }) {
      Text(this.title()).fontSize(17).fontWeight(FontWeight.Medium).fontColor(this.ink())
        .width('100%').maxLines(3).textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(this.detail()).fontSize(14).fontColor(this.ink()).lineHeight(21)
        .width('100%').maxLines(4).textOverflow({ overflow: TextOverflow.Ellipsis })
      Text('下一步：' + this.nextAction()).fontSize(13).fontColor(ACCENT).lineHeight(20)
        .width('100%').maxLines(3).textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .focusable(true)
    .accessibilityGroup(true)
    .accessibilityText(this.spoken())
  }
}

/** 组标题：组名、自动/手动、当前出口；截断/循环时明确标注。 */
@Component
export struct ProxyGroupHeader {
  @Prop name: string = '';
  @Prop auto: boolean = false;
  @Prop now: string = '';
  @Prop truncated: boolean = false;
  @Prop cycle: boolean = false;
  @Prop dark: boolean = false;

  private ink(): string {
    return this.dark ? '#EEF4FC' : '#162B40';
  }

  private muted(): string {
    return this.dark ? NEUTRAL_DARK : NEUTRAL;
  }

  private nowText(): string {
    if (this.truncated) {
      const reason: string = this.cycle ? '存在循环' : '嵌套过深';
      return '当前出口：' + this.name + '（' + reason + '）';
    }
    return '当前出口：' + (this.now.length > 0 ? this.now : UNKNOWN);
  }

  build() {
    Column({ space: 5 }) {
      Row({ space: 8 }) {
        Text(this.name).fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.ink())
          .layoutWeight(1).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.auto ? '自动' : '手动').fontSize(11).fontColor(this.auto ? this.muted() : ACCENT)
      }.width('100%').alignItems(VerticalAlign.Center)
      Text(this.nowText()).fontSize(12).fontColor(this.muted()).width('100%')
        .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 10 })
    .alignItems(HorizontalAlign.Start)
  }
}