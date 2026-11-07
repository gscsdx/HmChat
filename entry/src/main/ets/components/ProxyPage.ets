import { promptAction } from '@kit.ArkUI';
import { picker } from '@kit.CoreFileKit';
import { HdsPage } from './HdsPage';
import { HdsSettingsRow } from './HdsSettingsRow';
import { ProxyErrorDetail, ProxyGroupHeader, ProxyNodeRow, ProxyProfileRow, ProxyStatusCard, ProxySwitchRow,
  DelayTone, PROFILE_PENDING_TEXT, delayLabel, delayTone } from './ProxyRows';
import { describe } from '../model/ClashError';
import { DelayEntry, ProxyNode, ProxyScope } from '../model/ClashModels';
import { DerivedProxyGroup } from '../model/ClashGroupDeriver';
import { UrlValidationResult, validateUrl } from '../model/ClashSubscriptionParser';
import { ClashOperationResult, ClashService, ClashServiceListener, ClashServiceSnapshot } from
  '../services/clash/ClashService';
import { ClashProfileRecord } from '../services/clash/ClashProfileStore';

/** 配置行的只读视图；页面只消费快照字段，不读取存储层。 */
interface ProxyProfileView {
  id: string;
  name: string;
  subscription: boolean;
  nodeCount: number;
  updatedAt: number;
  lastErrorCode: string;
  active: boolean;
}

/** 节点行的只读视图；延迟与选中在快照到达时算好，build() 只渲染稳定数组。 */
interface ProxyNodeView {
  id: string;
  name: string;
  protocolLabel: string;
  delayText: string;
  delayTone: DelayTone;
  delayLoading: boolean;
  selected: boolean;
}

/** 页面内使用的只读组视图；派生在快照到达时完成，build() 不再排序或过滤。 */
interface ProxyGroupView {
  name: string;
  auto: boolean;
  now: string;
  truncated: boolean;
  cycle: boolean;
  nodes: ProxyNodeView[];
}

/** 订阅 UA 的固定预设；只提供已知客户端的 UA，不接受自由输入。 */
interface SubscriptionUserAgentPreset {
  label: string;
  value: string;
}

const UA_PRESETS: SubscriptionUserAgentPreset[] = [
  { label: 'HmChat 默认', value: 'HmChat/1.0.0 (HarmonyOS; ClashProxy)' },
  { label: 'Clash Verge', value: 'clash-verge/v2.4.5' },
  { label: 'Clash for Windows', value: 'ClashforWindows/0.20.39' },
  { label: 'ClashX', value: 'ClashX/1.118.0' },
  { label: 'mihomo', value: 'mihomo/1.19.28' },
  { label: 'Stash', value: 'Stash/2.5.0' },
  { label: 'Shadowrocket', value: 'Shadowrocket/2.2.0' },
  { label: 'Clash Meta for Android', value: 'ClashMetaForAndroid/2.11.6' }
];

/** 后端默认值与未匹配时的回退项；Clash Verge 在列表中的索引固定为 1。 */
const DEFAULT_UA_VALUE: string = 'clash-verge/v2.4.5';
const DEFAULT_UA_INDEX: number = 1;

/** Select 只展示 label；真实 UA 值仍由 UA_PRESETS 提供，用于写入设置。 */
function buildUaOptions(): SelectOption[] {
  const options: SelectOption[] = [];
  for (let index: number = 0; index < UA_PRESETS.length; index++) {
    const option: SelectOption = { value: UA_PRESETS[index].label };
    options.push(option);
  }
  return options;
}

const SHEET_SUBSCRIPTION: string = 'subscription';
const SHEET_ERROR: string = 'error';

const ACCENT: string = '#268BDE';
const DANGER: string = '#D56464';

/** 初始快照：与服务未初始化时一致，全部为非成功态。 */
function emptySnapshot(): ClashServiceSnapshot {
  const snapshot: ClashServiceSnapshot = {
    state: 'unconfigured',
    epoch: 0,
    pendingApply: false,
    stopWarning: false,
    hasValidProfile: false,
    startInFlight: false,
    stopInFlight: false,
    importInFlight: false,
    updateInFlight: false,
    applyInFlight: false,
    scopeInFlight: false,
    probeAllInFlight: false,
    loadingDelayNames: [],
    profiles: [],
    groups: [],
    delays: {}
  };
  return snapshot;
}

/**
 * 网络代理二级页。
 *
 * 页面只读取 ClashService.snapshot 并通过公开命令触发动作；不持有 RPC token、
 * 会话或已保存的订阅地址。订阅输入只在导入 sheet 内短暂存在，关闭即清空。
 * ClashService 由上层 Index 持有并传入，避免页面重建时重建代理会话。
 */
@Component
export struct ProxyPage {
  service: ClashService = ClashService.get();
  @Prop dark: boolean = false;
  onBack: () => void = () => {};

  @State private snapshot: ClashServiceSnapshot = emptySnapshot();
  @State private groups: ProxyGroupView[] = [];
  @State private profiles: ProxyProfileView[] = [];
  @State private nodeCount: number = 0;

  @State private actionError: string = '';
  @State private actionNotice: string = '';

  @State private sheetVisible: boolean = false;
  @State private sheetMode: string = SHEET_SUBSCRIPTION;
  @State private subscriptionUrl: string = '';
  @State private subscriptionError: string = '';
  @State private uaIndex: number = 0;
  private uaOptions: SelectOption[] = buildUaOptions();
  @State private detailCode: string = 'internal';
  @State private submittingSubscription: boolean = false;
  @State private importingLocal: boolean = false;

  @State private updatingProfileId: string = '';
  @State private applyingProfileId: string = '';
  @State private removingProfileId: string = '';

  @State private switchingNode: string = '';

  /** 本地在途标记：服务快照更新前的连点由它合并，不乐观改变开关。 */
  @State private proxySubmitting: boolean = false;
  /** 用户已请求停止，但服务快照尚未进入 stopInFlight；用于提前撤掉成功色。 */
  @State private stoppingRequested: boolean = false;

  /**
   * 会话内的一次性全局范围确认。服务当前没有写入该偏好的公开命令，
   * 因此这里只保证本次页面存活期不重复弹窗，不伪造持久化。
   */
  @State private experimentalAck: boolean = false;

  private listener: ClashServiceListener = (snapshot: ClashServiceSnapshot): void => {
    this.applySnapshot(snapshot);
  };
  private live: boolean = true;

  aboutToAppear(): void {
    this.live = true;
    this.applySnapshot(this.service.snapshot());
    this.service.subscribe(this.listener);
  }

  aboutToDisappear(): void {
    this.live = false;
    this.service.unsubscribe(this.listener);
  }

  /** 把服务快照归并为平台稳定的只读视图；排序、延迟合并都在这里完成。 */
  private applySnapshot(snapshot: ClashServiceSnapshot): void {
    this.snapshot = snapshot;

    const delays: Record<string, DelayEntry> = {};
    const urls: string[] = Object.keys(snapshot.delays);
    for (let urlIndex: number = 0; urlIndex < urls.length; urlIndex++) {
      const bucket: Record<string, DelayEntry> = snapshot.delays[urls[urlIndex]];
      const names: string[] = Object.keys(bucket);
      for (let nameIndex: number = 0; nameIndex < names.length; nameIndex++) {
        const name: string = names[nameIndex];
        const entry: DelayEntry = bucket[name];
        const existing: DelayEntry | undefined = delays[name];
        if (existing === undefined || entry.at > existing.at) {
          delays[name] = entry;
        }
      }
    }

    let activeSelected: Record<string, string> | undefined = undefined;
    const profileViews: ProxyProfileView[] = [];
    for (let index: number = 0; index < snapshot.profiles.length; index++) {
      const record: ClashProfileRecord = snapshot.profiles[index];
      profileViews.push({
        id: record.id,
        name: record.displayName,
        subscription: record.sourceKind === 'subscription',
        nodeCount: record.nodeCount,
        updatedAt: record.updatedAt !== undefined ? record.updatedAt : 0,
        lastErrorCode: record.lastErrorCode !== undefined ? record.lastErrorCode : '',
        active: record.isActive
      });
      if (record.isActive) {
        activeSelected = record.selectedMap;
      }
    }
    this.profiles = profileViews;

    const selected: Record<string, string> = {};
    if (activeSelected !== undefined) {
      const groupNames: string[] = Object.keys(activeSelected);
      for (let index: number = 0; index < groupNames.length; index++) {
        selected[groupNames[index]] = activeSelected[groupNames[index]];
      }
    }

    const views: ProxyGroupView[] = [];
    let totalNodes: number = 0;
    for (let index: number = 0; index < snapshot.groups.length; index++) {
      const group: DerivedProxyGroup = snapshot.groups[index] as DerivedProxyGroup;
      const now: string = group.now !== undefined ? group.now : '';
      const selectedName: string | undefined = selected[group.name];
      const members: ProxyNode[] = group.all;
      const nodes: ProxyNodeView[] = [];
      for (let nodeIndex: number = 0; nodeIndex < members.length; nodeIndex++) {
        const node: ProxyNode = members[nodeIndex];
        const entry: DelayEntry | undefined = delays[node.name];
        const selectedNode: boolean = group.isAuto
          ? (now.length > 0 && now === node.name)
          : (selectedName !== undefined ? selectedName === node.name : (now.length > 0 && now === node.name));
        nodes.push({
          id: node.id,
          name: node.name,
          protocolLabel: node.protocolLabel,
          delayText: delayLabel(entry),
          delayTone: delayTone(entry),
          delayLoading: snapshot.loadingDelayNames.indexOf(node.name) >= 0,
          selected: selectedNode
        });
      }
      totalNodes += nodes.length;
      views.push({
        name: group.name,
        auto: group.isAuto,
        now: now,
        truncated: group.nowTruncated,
        cycle: group.nowCycle,
        nodes: nodes
      });
    }
    this.groups = views;
    this.nodeCount = totalNodes;

    const settings = snapshot.settings;
    if (settings !== undefined && settings.experimentalScopeAck) {
      this.experimentalAck = true;
    }
  }

  private ink(): string {
    return this.dark ? '#EEF4FC' : '#162B40';
  }

  private muted(): string {
    return this.dark ? '#94A6BA' : '#8493A5';
  }

  private pageColor(): string {
    return this.dark ? '#101A25' : '#F4F7FB';
  }

  private surface(): string {
    return this.dark ? '#182430' : '#FFFFFF';
  }

  private line(): string {
    return this.dark ? '#293A49' : '#EDF1F5';
  }

  private clearFeedback(): void {
    this.actionError = '';
    this.actionNotice = '';
  }

  private describeCode(code: string | undefined): string {
    return describe(code !== undefined ? code : 'internal').title;
  }

  private busy(): boolean {
    const snapshot: ClashServiceSnapshot = this.snapshot;
    return this.proxySubmitting || snapshot.startInFlight || snapshot.stopInFlight || snapshot.state === 'preparing' ||
      snapshot.importInFlight || snapshot.updateInFlight || snapshot.applyInFlight ||
      snapshot.scopeInFlight || snapshot.probeAllInFlight;
  }

  private proxyBusy(): boolean {
    return this.proxySubmitting || this.snapshot.startInFlight || this.snapshot.stopInFlight ||
      this.snapshot.state === 'preparing';
  }

  /** 只要有有效配置即可开启；已连接时始终允许关闭，不能因节点列表为空锁死。 */
  private proxyEnabled(): boolean {
    if (this.busy()) {
      return false;
    }
    if (this.snapshot.state === 'connected') {
      return true;
    }
    return this.snapshot.hasValidProfile;
  }

  /** 只有服务确认 connected 且不在停止中才显示为开。 */
  private proxyChecked(): boolean {
    return this.snapshot.state === 'connected' && !this.snapshot.stopInFlight && !this.stoppingRequested;
  }

  private stopping(): boolean {
    return this.snapshot.stopInFlight || this.stoppingRequested;
  }

  private stateLabel(): string {
    if (this.stopping()) {
      return '正在停止';
    }
    if (this.snapshot.state === 'connected') {
      return '已连接';
    }
    if (this.snapshot.state === 'preparing') {
      return '正在启动';
    }
    if (this.snapshot.state === 'stopped') {
      return '已停止';
    }
    if (this.snapshot.state === 'unauthorized') {
      return '未授权';
    }
    if (this.snapshot.state === 'failed') {
      return '启动失败';
    }
    return '未配置';
  }

  private proxySubtitle(): string {
    if (this.stopping()) {
      return '正在停止，请稍候';
    }
    if (this.snapshot.state === 'connected') {
      return '已连接，点击可关闭';
    }
    if (this.snapshot.state === 'preparing') {
      return '正在启动，请稍候';
    }
    if (this.snapshot.state === 'stopped') {
      return '已停止，点击可开启';
    }
    if (this.snapshot.state === 'unauthorized') {
      return '重试并允许系统授权';
    }
    if (this.snapshot.state === 'failed') {
      return '代理启动失败，可重试';
    }
    return '导入配置后可开启';
  }

  private statusErrorCode(): string {
    const code: string | undefined = this.snapshot.errorCode;
    if (this.snapshot.state === 'failed') {
      return code !== undefined ? code : 'internal';
    }
    if (this.snapshot.state === 'unauthorized') {
      return code !== undefined ? code : 'tun_create_denied';
    }
    return '';
  }

  private scope(): ProxyScope {
    const settings = this.snapshot.settings;
    if (settings !== undefined) {
      return settings.scope;
    }
    return 'harlgramOnly';
  }

  private scopeChecked(): boolean {
    return this.scope() === 'harlgramOnly';
  }

  private scopeEnabled(): boolean {
    return !this.busy();
  }

  private scopeSubtitle(): string {
    return this.scopeChecked() ? '仅 HmChat（实验性）' : '所有应用';
  }

  private scopeExplanation(): string {
    return this.scopeChecked()
      ? '仅 HmChat 通过代理，其他应用不受影响。'
      : '所有应用都会通过代理，可能影响其他应用网络。';
  }

  private scopeAccessibility(): string {
    return this.scopeChecked()
      ? '切换为所有应用，当前仅 HmChat 走代理'
      : '开启仅 HmChat 走代理，当前所有应用';
  }

  private importEnabled(): boolean {
    return !this.busy() && !this.submittingSubscription && !this.importingLocal;
  }

  private testEnabled(): boolean {
    return this.snapshot.state === 'connected' && !this.snapshot.probeAllInFlight &&
      !this.snapshot.applyInFlight && !this.snapshot.scopeInFlight && !this.stopping();
  }

  private canProbeAll(): boolean {
    return this.snapshot.state === 'connected' && this.nodeCount > 0 && !this.stopping();
  }

  private nodeSelectEnabled(group: ProxyGroupView): boolean {
    return !group.auto && this.snapshot.state === 'connected' && !this.snapshot.startInFlight &&
      !this.stopping() && !this.snapshot.applyInFlight && !this.snapshot.scopeInFlight &&
      !this.snapshot.probeAllInFlight && this.switchingNode.length === 0;
  }

  private emptyNodesText(): string {
    if (this.snapshot.state === 'connected') {
      return '当前配置没有可用节点';
    }
    if (this.snapshot.hasValidProfile) {
      return '开启代理后显示节点';
    }
    return '当前配置没有可用节点';
  }

  private profileFailure(profile: ProxyProfileView): string {
    if (profile.lastErrorCode.length === 0) {
      return '';
    }
    return describe(profile.lastErrorCode).title;
  }

  private profileBusy(profile: ProxyProfileView): boolean {
    return this.updatingProfileId === profile.id || this.applyingProfileId === profile.id ||
      this.removingProfileId === profile.id;
  }

  private profileBusyLabel(profile: ProxyProfileView): string {
    if (this.removingProfileId === profile.id) {
      return '正在删除配置';
    }
    if (this.applyingProfileId === profile.id) {
      return '正在应用配置';
    }
    if (this.updatingProfileId === profile.id) {
      return '正在更新订阅';
    }
    return '';
  }

  private profileSource(profile: ProxyProfileView): string {
    return profile.subscription ? '订阅' : '本地配置';
  }

  /** 兜底：命令正常返回失败结果；真抛异常时也必须结束忙碌态并给出提示。 */
  private reportUnexpected(): void {
    if (this.live) {
      this.actionError = '操作没有完成，请重试';
    }
  }

  private async startProxy(): Promise<void> {
    if (this.proxyBusy()) {
      return;
    }
    this.clearFeedback();
    this.proxySubmitting = true;
    try {
      const result: ClashOperationResult = await this.service.start();
      if (!this.live) {
        return;
      }
      // 失败时服务已把具体错误写入状态卡；这里只补充状态卡不覆盖的操作错误。
      if (!result.ok && this.snapshot.state !== 'failed' && this.snapshot.state !== 'unauthorized') {
        this.actionError = this.describeCode(result.code);
      }
    } catch (error) {
      this.reportUnexpected();
    } finally {
      this.proxySubmitting = false;
    }
  }

  private async stopProxy(): Promise<void> {
    if (this.proxyBusy()) {
      return;
    }
    this.clearFeedback();
    this.proxySubmitting = true;
    this.stoppingRequested = true;
    try {
      const result: ClashOperationResult = await this.service.stop();
      if (!this.live) {
        return;
      }
      if (!result.ok) {
        this.actionError = this.describeCode(result.code);
      }
    } catch (error) {
      this.reportUnexpected();
    } finally {
      this.stoppingRequested = false;
      this.proxySubmitting = false;
    }
  }

  private toggleProxy(value: boolean): void {
    if (value) {
      void this.startProxy();
    } else {
      void this.stopProxy();
    }
  }

  private retryProxy(): void {
    if (this.snapshot.stopWarning) {
      void this.stopProxy();
      return;
    }
    if (this.snapshot.state === 'connected' || this.proxyBusy()) {
      return;
    }
    void this.startProxy();
  }

  private async applyScope(scope: ProxyScope): Promise<void> {
    if (this.busy()) {
      return;
    }
    this.clearFeedback();
    try {
      const result: ClashOperationResult = await this.service.setScope(scope);
      if (!this.live) {
        return;
      }
      if (!result.ok) {
        this.actionError = this.describeCode(result.code);
      }
    } catch (error) {
      this.reportUnexpected();
    }
  }

  private experimentalAckPersisted(): boolean {
    const settings = this.snapshot.settings;
    return settings !== undefined && settings.experimentalScopeAck;
  }

  private confirmGlobalScope(): void {
    if (this.experimentalAck || this.experimentalAckPersisted()) {
      void this.applyScope('global');
      return;
    }
    this.getUIContext().getPromptAction().showDialog({
      title: '切换到所有应用？',
      message: '全局模式会影响设备上其他应用的网络。你可以随时切回仅 HmChat。',
      buttons: [
        { text: '取消', color: '#8493A5' },
        { text: '继续', color: ACCENT }
      ]
    }).then((result: promptAction.ShowDialogSuccessResponse) => {
      if (result.index === 1) {
        this.experimentalAck = true;
        void this.applyScope('global');
      }
    }).catch(() => {});
  }

  private changeScope(value: boolean): void {
    if (value) {
      void this.applyScope('harlgramOnly');
    } else {
      this.confirmGlobalScope();
    }
  }

  private openScopeInfo(): void {
    this.getUIContext().getPromptAction().showDialog({
      title: '代理范围',
      message: '仅 HmChat：只有 HmChat 使用代理，其他应用不受影响。\n所有应用：设备上的其他应用也会通过代理连接，可能影响它们的网络。',
      buttons: [{ text: '知道了', color: ACCENT }]
    }).catch(() => {});
  }

  /** 用当前设置值定位固定选项；未匹配时回退到后端默认的 Clash Verge。 */
  private uaIndexFor(value: string): number {
    for (let index: number = 0; index < UA_PRESETS.length; index++) {
      if (UA_PRESETS[index].value === value) {
        return index;
      }
    }
    return DEFAULT_UA_INDEX;
  }

  /** 读取已保存的订阅 UA；设置尚未加载时按未匹配处理。 */
  private savedSubscriptionUserAgent(): string {
    const settings = this.snapshot.settings;
    if (settings !== undefined) {
      const saved: string | undefined = settings.subscriptionUserAgent;
      return saved !== undefined ? saved : '';
    }
    return DEFAULT_UA_VALUE;
  }

  private openSubscription(): void {
    if (!this.importEnabled()) {
      return;
    }
    this.sheetMode = SHEET_SUBSCRIPTION;
    this.subscriptionUrl = '';
    this.subscriptionError = '';
    this.uaIndex = this.uaIndexFor(this.savedSubscriptionUserAgent());
    this.sheetVisible = true;
  }

  private openErrorDetail(): void {
    const code: string = this.statusErrorCode();
    this.detailCode = code.length > 0 ? code : 'internal';
    this.sheetMode = SHEET_ERROR;
    this.sheetVisible = true;
  }

  private closeSheet(): void {
    this.sheetVisible = false;
    // 输入内容只在导入期间存在，关闭即丢弃，避免明文地址留在页面状态里。
    this.subscriptionUrl = '';
    this.subscriptionError = '';
  }

  private subscriptionHint(): string {
    const url: string = this.subscriptionUrl.trim();
    if (url.length === 0) {
      return '请输入订阅地址';
    }
    const validation: UrlValidationResult = validateUrl(url);
    if (validation.ok) {
      return '';
    }
    if (validation.hint !== undefined && validation.hint.length > 0) {
      return validation.hint;
    }
    if (validation.code === 'unsupported') {
      return describe('unsupported').title;
    }
    return '订阅地址无效，请检查后重试';
  }

  private async importSubscription(): Promise<void> {
    if (this.submittingSubscription || this.snapshot.importInFlight) {
      return;
    }
    const url: string = this.subscriptionUrl.trim();
    const hint: string = this.subscriptionHint();
    if (hint.length > 0) {
      this.subscriptionError = hint;
      return;
    }
    this.submittingSubscription = true;
    this.subscriptionError = '';
    try {
      // 先持久化 UA，拉取订阅时才能带上用户选择的客户端标识；失败则不发起导入。
      const uaResult: ClashOperationResult =
        await this.service.setSubscriptionUserAgent(UA_PRESETS[this.uaIndex].value);
      if (!this.live) {
        return;
      }
      if (!uaResult.ok) {
        const uaDescription = describe(uaResult.code !== undefined ? uaResult.code : 'internal');
        this.subscriptionError = uaDescription.title + '，' + uaDescription.nextAction;
        return;
      }
      const result: ClashOperationResult = await this.service.importSubscription(url);
      if (!this.live) {
        return;
      }
      if (!result.ok) {
        const description = describe(result.code !== undefined ? result.code : 'internal');
        this.subscriptionError = description.title + '，' + description.nextAction;
        return;
      }
      this.subscriptionUrl = '';
      this.sheetVisible = false;
      this.actionError = '';
      this.actionNotice = '订阅已导入';
    } catch (error) {
      if (this.live) {
        this.subscriptionError = '订阅导入没有完成，请重试';
      }
    } finally {
      this.submittingSubscription = false;
    }
  }

  private async pickLocalYaml(): Promise<void> {
    if (!this.importEnabled()) {
      return;
    }
    this.clearFeedback();
    const host = this.getUIContext().getHostContext();
    if (host === undefined) {
      this.actionError = '无法打开文件选择器，请重试';
      return;
    }
    this.importingLocal = true;
    try {
      const documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(host);
      const options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
      options.maxSelectNumber = 1;
      options.fileSuffixFilters = ['YAML 配置|.yaml,.yml'];
      const uris: string[] = await documentPicker.select(options);
      if (!this.live || uris.length === 0) {
        return;
      }
      // Picker 授权只在当前进程有效，选择后立刻读取，避免授权过期。
      const result: ClashOperationResult = await this.service.importLocalYaml(uris[0]);
      if (!this.live) {
        return;
      }
      if (!result.ok) {
        const description = describe(result.code !== undefined ? result.code : 'internal');
        this.actionError = description.title + '，' + description.nextAction;
        return;
      }
      this.actionNotice = '本地配置已导入';
    } catch (error) {
      this.actionError = '无法读取所选配置，请重试';
    } finally {
      this.importingLocal = false;
    }
  }

  private async applyProfile(profile: ProxyProfileView): Promise<void> {
    if (this.busy()) {
      return;
    }
    this.clearFeedback();
    this.applyingProfileId = profile.id;
    try {
      const result: ClashOperationResult = await this.service.applyProfile(profile.id);
      if (!this.live) {
        return;
      }
      if (!result.ok) {
        this.actionError = this.describeCode(result.code);
        return;
      }
      this.actionNotice = '配置已应用';
    } catch (error) {
      this.reportUnexpected();
    } finally {
      this.applyingProfileId = '';
    }
  }

  private async updateProfile(profile: ProxyProfileView): Promise<void> {
    if (this.busy()) {
      return;
    }
    this.clearFeedback();
    this.updatingProfileId = profile.id;
    try {
      const result: ClashOperationResult = await this.service.updateProfile(profile.id);
      if (!this.live) {
        return;
      }
      if (!result.ok) {
        this.actionError = this.describeCode(result.code);
        return;
      }
      if (result.unchanged === true) {
        this.actionNotice = '订阅内容与当前配置一致';
      } else if (profile.active) {
        // 更新成功不自动应用，保留用户确认步骤。
        this.actionNotice = PROFILE_PENDING_TEXT;
      } else {
        this.actionNotice = '订阅已更新';
      }
    } catch (error) {
      this.reportUnexpected();
    } finally {
      this.updatingProfileId = '';
    }
  }

  private async removeProfile(profile: ProxyProfileView): Promise<void> {
    if (this.busy()) {
      return;
    }
    this.clearFeedback();
    this.removingProfileId = profile.id;
    try {
      const result: ClashOperationResult = await this.service.removeProfile(profile.id);
      if (!this.live) {
        return;
      }
      if (!result.ok) {
        this.actionError = this.describeCode(result.code);
        return;
      }
      this.actionNotice = '配置已删除';
    } catch (error) {
      this.reportUnexpected();
    } finally {
      this.removingProfileId = '';
    }
  }

  private confirmRemove(profile: ProxyProfileView): void {
    const running: boolean = profile.active &&
      (this.snapshot.state === 'connected' || this.snapshot.state === 'preparing' ||
        this.snapshot.startInFlight);
    const message: string = running
      ? '此配置正在使用，删除前会先断开代理。只删除本地配置，不影响云端。'
      : '只删除本地配置，不影响云端。';
    this.getUIContext().getPromptAction().showDialog({
      title: '删除「' + profile.name + '」？',
      message: message,
      buttons: [
        { text: '取消', color: '#8493A5' },
        { text: '删除', color: DANGER }
      ]
    }).then((result: promptAction.ShowDialogSuccessResponse) => {
      if (result.index === 1) {
        void this.removeProfile(profile);
      }
    }).catch(() => {});
  }

  private openProfileMenu(profile: ProxyProfileView): void {
    if (this.busy()) {
      return;
    }
    // ActionMenuOptions.buttons 是定长元组，按实际动作分支直接构造，不用动态数组拼接。
    const canApply: boolean = !profile.active || this.snapshot.pendingApply;
    const applyText: string = profile.active ? '应用更新' : '应用配置';
    const kinds: string[] = [];
    let options: promptAction.ActionMenuOptions;
    if (canApply && profile.subscription) {
      kinds.push('apply');
      kinds.push('update');
      kinds.push('remove');
      options = {
        title: profile.name,
        buttons: [
          { text: applyText, color: ACCENT },
          { text: '更新订阅', color: ACCENT },
          { text: '删除', color: DANGER }
        ]
      };
    } else if (canApply) {
      kinds.push('apply');
      kinds.push('remove');
      options = {
        title: profile.name,
        buttons: [
          { text: applyText, color: ACCENT },
          { text: '删除', color: DANGER }
        ]
      };
    } else if (profile.subscription) {
      kinds.push('update');
      kinds.push('remove');
      options = {
        title: profile.name,
        buttons: [
          { text: '更新订阅', color: ACCENT },
          { text: '删除', color: DANGER }
        ]
      };
    } else {
      kinds.push('remove');
      options = {
        title: profile.name,
        buttons: [
          { text: '删除', color: DANGER }
        ]
      };
    }
    this.getUIContext().getPromptAction().showActionMenu(options)
      .then((result: promptAction.ActionMenuSuccessResponse) => {
        if (result.index < 0 || result.index >= kinds.length) {
          return;
        }
        const kind: string = kinds[result.index];
        if (kind === 'apply') {
          void this.applyProfile(profile);
        } else if (kind === 'update') {
          void this.updateProfile(profile);
        } else if (kind === 'remove') {
          this.confirmRemove(profile);
        }
      }).catch(() => {});
  }

  /** 配置行点击：待应用的配置直接应用，其余情况打开同一份行菜单。 */
  private openProfile(profile: ProxyProfileView): void {
    if (!profile.active || this.snapshot.pendingApply) {
      void this.applyProfile(profile);
      return;
    }
    this.openProfileMenu(profile);
  }

  private async selectNode(group: string, node: string): Promise<void> {
    if (this.snapshot.state !== 'connected' || this.switchingNode.length > 0 || this.busy()) {
      return;
    }
    this.clearFeedback();
    const key: string = group + '/' + node;
    this.switchingNode = key;
    try {
      const result: ClashOperationResult = await this.service.selectNode(group, node);
      if (!this.live) {
        return;
      }
      if (!result.ok) {
        this.actionError = this.describeCode(result.code);
      }
    } catch (error) {
      this.reportUnexpected();
    } finally {
      this.switchingNode = '';
    }
  }

  private async probeNode(name: string): Promise<void> {
    if (!this.testEnabled()) {
      return;
    }
    this.clearFeedback();
    try {
      const result: ClashOperationResult = await this.service.probeDelay(name);
      if (!this.live) {
        return;
      }
      if (!result.ok) {
        this.actionError = this.describeCode(result.code);
      }
    } catch (error) {
      this.reportUnexpected();
    }
  }

  private toggleProbeAll(): void {
    if (this.snapshot.probeAllInFlight) {
      this.service.cancelProbeAll();
      return;
    }
    if (!this.canProbeAll()) {
      return;
    }
    this.clearFeedback();
    void this.runProbeAll();
  }

  private async runProbeAll(): Promise<void> {
    try {
      const result: ClashOperationResult = await this.service.probeAll();
      if (!this.live) {
        return;
      }
      if (!result.ok) {
        this.actionError = this.describeCode(result.code);
      }
    } catch (error) {
      this.reportUnexpected();
    }
  }

  @Builder
  private sectionLabel(title: string) {
    Text(title).fontSize(13).fontColor(ACCENT).width('100%').padding({ left: 4 })
  }

  @Builder
  private switchCard() {
    Column() {
      ProxySwitchRow({
        title: '网络代理',
        subtitle: this.proxySubtitle(),
        checked: this.proxyChecked(),
        isEnabled: this.proxyEnabled(),
        busy: this.proxyBusy(),
        stateLabel: this.stateLabel(),
        dark: this.dark,
        onChange: (value: boolean) => this.toggleProxy(value)
      })
    }.width('100%').backgroundColor(this.surface()).borderRadius(16)
  }

  @Builder
  private scopeSection() {
    this.sectionLabel('代理范围')
    Column() {
      ProxySwitchRow({
        title: '仅 HmChat 走代理',
        subtitle: this.scopeSubtitle(),
        checked: this.scopeChecked(),
        isEnabled: this.scopeEnabled(),
        busy: this.snapshot.scopeInFlight,
        stateLabel: this.scopeChecked() ? '仅 HmChat' : '所有应用',
        a11yLabel: this.scopeAccessibility(),
        dark: this.dark,
        onChange: (value: boolean) => this.changeScope(value)
      })
      Divider().color(this.line()).margin({ left: 16, right: 16 })
      Column({ space: 4 }) {
        Text(this.scopeExplanation()).fontSize(12).fontColor(this.muted()).lineHeight(18).width('100%')
        Button('了解代理范围').buttonStyle(ButtonStyleMode.TEXTUAL).fontColor(ACCENT)
          .height(40).padding({ left: 0, right: 0 }).onClick(() => this.openScopeInfo())
          .accessibilityText('了解代理范围说明')
      }
      .width('100%')
      .padding({ left: 16, right: 16, bottom: 8 })
      .alignItems(HorizontalAlign.Start)
    }.width('100%').backgroundColor(this.surface()).borderRadius(16)
  }

  @Builder
  private profileRow(profile: ProxyProfileView) {
    ProxyProfileRow({
      name: profile.name,
      sourceLabel: this.profileSource(profile),
      nodeCount: profile.nodeCount,
      updatedAt: profile.updatedAt,
      active: profile.active,
      pending: profile.active && this.snapshot.pendingApply,
      failureText: this.profileFailure(profile),
      busy: this.profileBusy(profile),
      busyLabel: this.profileBusyLabel(profile),
      dark: this.dark,
      isEnabled: !this.busy(),
      onOpen: () => this.openProfile(profile),
      onMenu: () => this.openProfileMenu(profile)
    })
  }

  @Builder
  private configSection() {
    this.sectionLabel('配置与订阅')
    Column() {
      if (this.profiles.length === 0) {
        Text('导入订阅或本地配置后即可开启代理。').fontSize(13).fontColor(this.muted())
          .padding({ left: 16, right: 16, top: 16, bottom: 10 }).width('100%')
      } else {
        ForEach(this.profiles, (profile: ProxyProfileView, index: number) => {
          this.profileRow(profile)
          if (index < this.profiles.length - 1) {
            Divider().color(this.line()).margin({ left: 16, right: 16 })
          }
        }, (profile: ProxyProfileView) => profile.id)
      }
      Divider().color(this.line()).margin({ left: 16, right: 16 })
      HdsSettingsRow({
        title: '导入订阅',
        icon: $r('app.media.hg_globe_blue'),
        isEnabled: this.importEnabled(),
        action: () => this.openSubscription()
      })
      Divider().color(this.line()).margin({ left: 16, right: 16 })
      HdsSettingsRow({
        title: '导入本地配置',
        icon: $r('app.media.hg_attach'),
        isEnabled: this.importEnabled(),
        action: () => { void this.pickLocalYaml(); }
      })
    }.width('100%').backgroundColor(this.surface()).borderRadius(16)
  }

  @Builder
  private nodesSection() {
    // 节点行高会随字号与两行名称变化；≤500 节点时用稳定键 ForEach，
    // 避免 LazyForEach 缺少 getData 通知或固定行高造成裁切。
    this.sectionLabel('节点与测速')
    if (this.snapshot.probeAllInFlight) {
      Text('正在测速，可在右上角取消').fontSize(12).fontColor(ACCENT).width('100%').padding({ left: 4 })
    }
    if (this.groups.length === 0) {
      Column() {
        Text(this.emptyNodesText()).fontSize(14).fontColor(this.muted()).width('100%').padding(16)
      }.width('100%').backgroundColor(this.surface()).borderRadius(16)
    } else {
      ForEach(this.groups, (group: ProxyGroupView) => {
        Column() {
          ProxyGroupHeader({
            name: group.name,
            auto: group.auto,
            now: group.now,
            truncated: group.truncated,
            cycle: group.cycle,
            dark: this.dark
          })
          Divider().color(this.line()).margin({ left: 16, right: 16 })
          ForEach(group.nodes, (node: ProxyNodeView, index: number) => {
            ProxyNodeRow({
              name: node.name,
              protocolLabel: node.protocolLabel,
              delayText: node.delayText,
              delayTone: node.delayTone,
              delayLoading: node.delayLoading,
              selected: node.selected,
              switching: this.switchingNode === node.id,
              selectable: this.nodeSelectEnabled(group),
              testEnabled: this.testEnabled(),
              dark: this.dark,
              onSelect: () => { void this.selectNode(group.name, node.name); },
              onTest: () => { void this.probeNode(node.name); }
            })
            if (index < group.nodes.length - 1) {
              Divider().color(this.line()).margin({ left: 16, right: 16 })
            }
          }, (node: ProxyNodeView) => node.id)
        }.width('100%').backgroundColor(this.surface()).borderRadius(16)
      }, (group: ProxyGroupView) => group.name)
    }
  }

  @Builder
  private subscriptionSheet() {
    Column({ space: 14 }) {
      Text('订阅地址只在导入时使用，关闭后清空，不会显示在配置列表中。')
        .fontSize(12).fontColor(this.muted()).lineHeight(18).width('100%')
      TextInput({ text: this.subscriptionUrl, placeholder: '粘贴订阅地址' })
        .type(InputType.Normal)
        .maxLength(2048)
        .height(50)
        .width('100%')
        .fontSize(15)
        .fontColor(this.ink())
        .placeholderColor(this.muted())
        .backgroundColor(this.pageColor())
        .borderRadius(12)
        .padding({ left: 14, right: 14 })
        .caretColor(ACCENT)
        .enterKeyType(EnterKeyType.Done)
        .onChange((value: string) => {
          this.subscriptionUrl = value;
          if (this.subscriptionError.length > 0) {
            this.subscriptionError = '';
          }
        })
        .onSubmit(() => { void this.importSubscription(); })
        .accessibilityText('订阅地址')
      Row({ space: 12 }) {
        Text('订阅 UA').fontSize(14).fontColor(this.muted()).layoutWeight(1)
          .textAlign(TextAlign.Start)
        Select(this.uaOptions)
          .selected(this.uaIndex)
          .value(UA_PRESETS[this.uaIndex].label)
          .font({ size: 14, weight: FontWeight.Medium })
          .fontColor(this.ink())
          .optionWidth(OptionWidthMode.FIT_CONTENT)
          .enabled(!this.submittingSubscription)
          .onSelect((index: number) => { this.uaIndex = index; })
          .accessibilityText('订阅 UA')
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      if (this.submittingSubscription) {
        Text('正在校验配置…').fontSize(12).fontColor(this.muted()).lineHeight(18).width('100%')
      }
      if (this.subscriptionError.length > 0) {
        Text(this.subscriptionError).fontSize(12).fontColor(DANGER).lineHeight(18).width('100%')
      }
      Row({ space: 12 }) {
        Button('取消').buttonStyle(ButtonStyleMode.NORMAL).height(44).layoutWeight(1)
          .onClick(() => this.closeSheet())
        Button(this.submittingSubscription ? '正在校验配置…' : '导入')
          .buttonStyle(ButtonStyleMode.EMPHASIZED).height(44).layoutWeight(1)
          .enabled(!this.submittingSubscription && this.subscriptionUrl.trim().length > 0)
          .onClick(() => { void this.importSubscription(); })
      }.width('100%')
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 8, bottom: 24 })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private errorSheet() {
    Column({ space: 16 }) {
      ProxyErrorDetail({ errorCode: this.detailCode, dark: this.dark })
      Button('关闭').buttonStyle(ButtonStyleMode.NORMAL).height(44).width('100%')
        .onClick(() => this.closeSheet())
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 8, bottom: 24 })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private sheetContent() {
    if (this.sheetMode === SHEET_ERROR) {
      this.errorSheet()
    } else {
      this.subscriptionSheet()
    }
  }

  @Builder
  private proxyBody() {
    Scroll() {
      Column() {
        Column({ space: 16 }) {
          ProxyStatusCard({
            state: this.snapshot.state,
            preparingReason: this.snapshot.preparingReason !== undefined ? this.snapshot.preparingReason : '',
            stopping: this.stopping(),
            coreVersion: this.snapshot.coreVersion !== undefined ? this.snapshot.coreVersion : '',
            currentNode: this.snapshot.currentNode !== undefined ? this.snapshot.currentNode : '',
            errorCode: this.statusErrorCode(),
            stopWarning: this.snapshot.stopWarning,
            dark: this.dark,
            onRetry: () => this.retryProxy(),
            onDetail: () => this.openErrorDetail()
          })
          if (this.actionError.length > 0) {
            Text(this.actionError).fontSize(13).fontColor(DANGER).lineHeight(19)
              .width('100%').padding({ left: 4, right: 4 })
          }
          if (this.actionNotice.length > 0) {
            Text(this.actionNotice).fontSize(13).fontColor(ACCENT).lineHeight(19)
              .width('100%').padding({ left: 4, right: 4 })
          }
          this.switchCard()
          this.scopeSection()
          this.configSection()
          this.nodesSection()
        }
        .width('100%')
        .constraintSize({ maxWidth: 720 })
        .padding({ left: 16, right: 16, bottom: 24 })
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .align(Alignment.Top)
    .bindSheet($$this.sheetVisible, this.sheetContent(), {
      height: SheetSize.MEDIUM,
      preferType: SheetType.BOTTOM,
      showClose: true,
      title: { title: this.sheetMode === SHEET_ERROR ? '错误详情' : '导入订阅' },
      backgroundColor: this.surface(),
      keyboardAvoidMode: SheetKeyboardAvoidMode.RESIZE_ONLY,
      onDisappear: () => {
        this.subscriptionUrl = '';
        this.subscriptionError = '';
      }
    })
  }

  build() {
    HdsPage({
      title: '网络代理',
      dark: this.dark,
      onBack: () => this.onBack(),
      firstLabel: this.snapshot.probeAllInFlight ? '取消' : '测速',
      firstSymbol: this.snapshot.probeAllInFlight ? $r('sys.symbol.xmark') : $r('sys.symbol.arrow_clockwise'),
      firstEnabled: this.snapshot.probeAllInFlight || this.canProbeAll(),
      firstAction: () => this.toggleProbeAll(),
      content: () => { this.proxyBody() }
    })
      .width('100%')
      .height('100%')
      .backgroundColor(this.pageColor())
  }
}