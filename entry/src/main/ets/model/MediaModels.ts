import { ChatMessage } from './ChatModels';
import { MediaNetwork } from './StorageModels';

export interface MediaAttachment {
  path: string;
  kind: 'photo' | 'video';
  width: number;
  height: number;
  duration: number;
  size: number;
}

/**
 * Physical link kinds derived from the platform bearer enum. The Kit enum never
 * reaches this module so the classification stays host-testable.
 */
export type MediaBearerKind = 'wifi' | 'cellular' | 'ethernet' | 'bluetooth' | 'vpn' | 'other';

export interface MediaNetworkCandidate {
  netId: number;
  bearers: MediaBearerKind[];
  /** True unless the platform reports NET_CAPABILITY_NOT_METERED. */
  metered: boolean;
}

export interface MediaNetworkProbe {
  /** Networks reported by the platform, including VPN tunnels. */
  nets: MediaNetworkCandidate[];
  /** Platform default network; null when it was not read or did not exist. */
  defaultNet: MediaNetworkCandidate | null;
  /** True when the platform explicitly reported that no default network exists. */
  defaultUnavailable: boolean;
  /** Cellular roaming flag; null when telephony could not be read. */
  roaming: boolean | null;
  /** Last physical network observed by this process, if any. */
  lastPhysical: MediaNetwork | null;
}

export interface MediaNetworkResolution {
  network: MediaNetwork;
  /** True only when classification reused `lastPhysical` because just a VPN was visible. */
  viaVpn: boolean;
  /** True when no concrete physical link could be observed and a fallback was used. */
  networkUnknown: boolean;
}

/** VPN tunnels are never physical links: they hide the transport underneath. */
export function mediaBearerIsVpn(candidate: MediaNetworkCandidate): boolean {
  return candidate.bearers.includes('vpn');
}

/** A candidate carries a physical link only when a non-VPN bearer is present. */
export function mediaCandidateIsPhysical(candidate: MediaNetworkCandidate): boolean {
  return candidate.bearers.some((bearer: MediaBearerKind) => bearer !== 'vpn');
}

function hasBearer(candidate: MediaNetworkCandidate, bearer: MediaBearerKind): boolean {
  return candidate.bearers.includes(bearer);
}

function usablePhysical(network: MediaNetwork | null): MediaNetwork | null {
  return network === 'wifi' || network === 'mobile' || network === 'roaming' ? network : null;
}

/**
 * Selection order required by the S2-18 task: Wi-Fi (or Ethernet) first, then any
 * unmetered link, then cellular/other metered links. A VPN bearer never decides the
 * result, and roaming is consulted only for a physical cellular link.
 */
function selectPhysicalNetwork(candidates: MediaNetworkCandidate[], roaming: boolean | null): MediaNetwork {
  const wifiClass = candidates.some((candidate: MediaNetworkCandidate) =>
    hasBearer(candidate, 'wifi') || hasBearer(candidate, 'ethernet'));
  if (wifiClass) { return 'wifi'; }
  if (candidates.some((candidate: MediaNetworkCandidate) => !candidate.metered)) { return 'wifi'; }
  const cellular = candidates.some((candidate: MediaNetworkCandidate) => hasBearer(candidate, 'cellular'));
  // Unknown roaming on a real cellular link stays conservative, as before. VPN never reaches this branch.
  if (cellular) { return roaming === false ? 'mobile' : 'roaming'; }
  return 'mobile';
}

/**
 * Resolves the media network from an already-probed snapshot. Pure and synchronous so
 * host tests can cover the VPN, roaming and unknown-fallback rules without NetworkKit.
 */
export function resolveMediaNetwork(probe: MediaNetworkProbe): MediaNetworkResolution {
  const physical = probe.nets.filter((candidate: MediaNetworkCandidate) => mediaCandidateIsPhysical(candidate));
  const lastPhysical = usablePhysical(probe.lastPhysical);
  if (physical.length > 0) {
    return { network: selectPhysicalNetwork(physical, probe.roaming), viaVpn: false, networkUnknown: false };
  }
  const defaultBearer = probe.defaultNet;
  const hasVpn = probe.nets.some((candidate: MediaNetworkCandidate) => mediaBearerIsVpn(candidate)) ||
    (defaultBearer !== null && mediaBearerIsVpn(defaultBearer));
  if (hasVpn) {
    return lastPhysical
      ? { network: lastPhysical, viaVpn: true, networkUnknown: false }
      : { network: 'mobile', viaVpn: true, networkUnknown: true };
  }
  if (probe.defaultUnavailable) { return { network: 'none', viaVpn: false, networkUnknown: false }; }
  return lastPhysical
    ? { network: lastPhysical, viaVpn: false, networkUnknown: true }
    : { network: 'mobile', viaVpn: false, networkUnknown: true };
}

export function mediaAlbumAt(messages: ChatMessage[], index: number): ChatMessage[] {
  const item = messages[index];
  if (!item || !item.mediaKind) { return []; }
  const id = item.mediaAlbumId;
  if (!id || id === '0') { return [item]; }
  let start = index, end = index + 1;
  const same = (candidate: ChatMessage): boolean => !!candidate.mediaKind && candidate.mediaAlbumId === id &&
    candidate.chatId === item.chatId && candidate.outgoing === item.outgoing;
  while (start > 0 && same(messages[start - 1])) { start--; }
  while (end < messages.length && same(messages[end])) { end++; }
  return start === index ? messages.slice(start, end) : [];
}

export function mediaTime(seconds: number): string {
  const total = Math.max(0, Math.floor(Number.isFinite(seconds) ? seconds : 0));
  const minutes = Math.floor(total / 60);
  return `${minutes}:${(total % 60).toString().padStart(2, '0')}`;
}
export function mediaBytes(bytes: number): string {
  if (!Number.isFinite(bytes) || bytes <= 0) { return ''; }
  if (bytes >= 1024 * 1024 * 1024) { return `${(bytes / (1024 * 1024 * 1024)).toFixed(1)} GB`; }
  if (bytes >= 1024 * 1024) { return `${(bytes / (1024 * 1024)).toFixed(1)} MB`; }
  return `${Math.ceil(bytes / 1024)} KB`;
}
