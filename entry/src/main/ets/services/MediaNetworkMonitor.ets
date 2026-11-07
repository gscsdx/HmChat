import { connection } from '@kit.NetworkKit';
import { radio } from '@kit.TelephonyKit';
import { MediaNetwork } from '../model/StorageModels';
import { MediaBearerKind, MediaNetworkCandidate, MediaNetworkProbe, MediaNetworkResolution,
  resolveMediaNetwork } from '../model/MediaModels';

function bearerKind(type: connection.NetBearType): MediaBearerKind {
  if (type === connection.NetBearType.BEARER_WIFI) { return 'wifi'; }
  if (type === connection.NetBearType.BEARER_CELLULAR) { return 'cellular'; }
  if (type === connection.NetBearType.BEARER_ETHERNET) { return 'ethernet'; }
  if (type === connection.NetBearType.BEARER_BLUETOOTH) { return 'bluetooth'; }
  if (type === connection.NetBearType.BEARER_VPN) { return 'vpn'; }
  return 'other';
}

function carriesCellular(candidate: MediaNetworkCandidate): boolean {
  return !candidate.bearers.includes('vpn') && candidate.bearers.includes('cellular');
}

/**
 * Network identity stays local; no SSID, operator or address is persisted.
 * Classification is delegated to the pure `resolveMediaNetwork` model so VPN tunnels
 * and roaming are handled without NetworkKit in host tests.
 */
export class MediaNetworkMonitor {
  private subscription: connection.NetConnection | undefined = undefined;
  private revision: number = 0;
  private onChange: (network: MediaNetwork) => void;
  private lastPhysicalNetwork: MediaNetwork | null = null;
  private viaVpn: boolean = false;
  private networkUnknown: boolean = false;
  constructor(onChange: (network: MediaNetwork) => void) { this.onChange = onChange; }
  start(): void {
    if (this.subscription) { this.refresh(); return; }
    try {
      const subscriber = connection.createNetConnection(); this.subscription = subscriber;
      subscriber.on('netAvailable', () => this.refresh());
      subscriber.on('netCapabilitiesChange', () => this.refresh());
      subscriber.on('netLost', () => this.refresh());
      subscriber.on('netUnavailable', () => this.refresh());
      subscriber.register(() => this.refresh());
    } catch (_) { this.refresh(); }
  }
  /** True when the last classification reused the previous physical link behind a VPN default. */
  isViaVpn(): boolean { return this.viaVpn; }
  /** True when the last classification had to fall back instead of observing a link. */
  isNetworkUnknown(): boolean { return this.networkUnknown; }
  /**
   * Re-reads the system network. Only lifecycle and NetConnection events call this:
   * toggling the in-app proxy never changes the physical network, so it must not refresh.
   */
  refresh(): void {
    const revision = ++this.revision;
    this.read(revision).catch(() => { this.publish(revision, this.failureResolution()); });
  }
  private async read(revision: number): Promise<void> {
    const probe = await this.probe();
    this.publish(revision, resolveMediaNetwork(probe));
  }
  private publish(revision: number, resolution: MediaNetworkResolution): void {
    if (revision !== this.revision) { return; }
    this.viaVpn = resolution.viaVpn;
    this.networkUnknown = resolution.networkUnknown;
    if (resolution.network === 'wifi' || resolution.network === 'mobile' || resolution.network === 'roaming') {
      this.lastPhysicalNetwork = resolution.network;
    }
    this.onChange(resolution.network);
  }
  private failureResolution(): MediaNetworkResolution {
    const last = this.lastPhysicalNetwork;
    return last ? { network: last, viaVpn: false, networkUnknown: true }
      : { network: 'mobile', viaVpn: false, networkUnknown: true };
  }
  /** Never throws: every platform read is optional and degrades to an empty probe. */
  private async probe(): Promise<MediaNetworkProbe> {
    const nets: MediaNetworkCandidate[] = [];
    let handles: connection.NetHandle[] = [];
    try { handles = await connection.getAllNets(); } catch (_) { handles = []; }
    for (let index = 0; index < handles.length; index++) {
      const candidate = await this.candidate(handles[index]);
      if (candidate) { nets.push(candidate); }
    }
    let defaultNet: MediaNetworkCandidate | null = null;
    let defaultUnavailable = false;
    try {
      const handle = await connection.getDefaultNet();
      if (handle.netId === 0) { defaultUnavailable = true; }
      else {
        defaultNet = await this.candidate(handle);
        if (defaultNet) {
          const netId = defaultNet.netId;
          if (!nets.some((item: MediaNetworkCandidate) => item.netId === netId)) { nets.push(defaultNet); }
        }
      }
    } catch (_) {}
    const roaming = nets.some((item: MediaNetworkCandidate) => carriesCellular(item))
      ? await this.roaming() : null;
    return { nets: nets, defaultNet: defaultNet, defaultUnavailable: defaultUnavailable,
      roaming: roaming, lastPhysical: this.lastPhysicalNetwork };
  }
  /** Reads one bearer snapshot; a failed read is skipped so the probe degrades to a fallback. */
  private async candidate(handle: connection.NetHandle): Promise<MediaNetworkCandidate | null> {
    try {
      const caps = await connection.getNetCapabilities(handle);
      const bearers = (caps.bearerTypes || []).map((type: connection.NetBearType) => bearerKind(type));
      const capabilities = caps.networkCap || [];
      const metered = !capabilities.includes(connection.NetCap.NET_CAPABILITY_NOT_METERED);
      return { netId: handle.netId, bearers: bearers, metered: metered };
    } catch (_) { return null; }
  }
  /** Cellular roaming is consulted only for a physical cellular link, never for a VPN bearer. */
  private async roaming(): Promise<boolean | null> {
    try { return (await radio.getNetworkState()).isRoaming; } catch (_) { return null; }
  }
  stop(): void {
    this.revision++; try { this.subscription?.unregister(() => {}); } catch (_) {}
    this.subscription = undefined;
  }
}