import { fileIo } from '@kit.CoreFileKit';
import { NetworkConfig, NetworkProfile, readNetworkProfiles, saveNetworkJSON } from './NetworkProfiles';
import { readProfileRules, expandProfileRules } from './SplitTunnel';
import { ipFamily } from './WireGuardConfig';

export const MAX_MIXED_WIREGUARD: number = 16;
export const MAX_MIXED_TAILNETS: number = 16;
const SELECTION_FILE: string = '/mixed-connections.json';
const LEGACY_PROFILE_FILE: string = '/legacy-tailnet-profile.json';
const PROFILE_ID: RegExp = /^(main|[0-9a-fA-F-]{8,64})$/;

export class MixedSelection {
  disabledWireGuard: string[] = [];
  legacyEnabled: boolean = true;
}

export interface MixedWireGuardMeta { id: string; }

export function readMixedSelection(directory: string): MixedSelection {
  const result = new MixedSelection();
  try {
    const stored = JSON.parse(fileIo.readTextSync(directory + SELECTION_FILE)) as MixedSelection;
    result.legacyEnabled = stored.legacyEnabled !== false;
    if (stored.disabledWireGuard instanceof Array) {
      result.disabledWireGuard = stored.disabledWireGuard.filter((id: string): boolean =>
        typeof id === 'string' && PROFILE_ID.test(id));
    }
  } catch (_) { /* Newly imported connections participate by default. */ }
  return result;
}

export function saveMixedSelection(directory: string, value: MixedSelection): void {
  const selection = new MixedSelection();
  selection.legacyEnabled = value.legacyEnabled !== false;
  selection.disabledWireGuard = value.disabledWireGuard.filter((id: string, index: number): boolean =>
    typeof id === 'string' && PROFILE_ID.test(id) && value.disabledWireGuard.indexOf(id) === index);
  saveNetworkJSON(directory + SELECTION_FILE, JSON.stringify(selection));
}

export function isWireGuardSelected(selection: MixedSelection, id: string): boolean {
  return !selection.disabledWireGuard.includes(id);
}

export function setWireGuardSelected(directory: string, id: string, enabled: boolean): void {
  if (!PROFILE_ID.test(id)) { throw new Error('WireGuard 配置标识无效。'); }
  const selection = readMixedSelection(directory);
  selection.disabledWireGuard = selection.disabledWireGuard.filter((current: string): boolean => current !== id);
  if (!enabled) { selection.disabledWireGuard.push(id); }
  saveMixedSelection(directory, selection);
}

export function setLegacySelected(directory: string, enabled: boolean): void {
  const selection = readMixedSelection(directory); selection.legacyEnabled = enabled;
  saveMixedSelection(directory, selection);
}

export function selectedMixedWireGuardIds(directory: string, profiles: MixedWireGuardMeta[]): string[] {
  const selection = readMixedSelection(directory);
  return profiles.filter((profile: MixedWireGuardMeta): boolean => isWireGuardSelected(selection, profile.id))
    .map((profile: MixedWireGuardMeta): string => profile.id);
}

// The old single-network screen did not persist its control URL separately. Its
// identity directory encodes that URL, so reusing it avoids creating a second node.
export function readLegacyNetworkProfile(directory: string): NetworkProfile | undefined {
  let identities: string[] = [];
  try {
    identities = fileIo.listFileSync(directory + '/tailnet').filter((name: string): boolean => {
      if (name.includes('/') || name.includes('\\')) { return false; }
      try { return fileIo.statSync(directory + '/tailnet/' + name).isDirectory(); } catch (_) { return false; }
    });
  } catch (_) { return undefined; }
  let key: string = '';
  if (identities.includes('tailscale')) { key = 'tailscale'; }
  else if (identities.length === 1) { key = identities[0]; }
  if (!key) { return undefined; }
  let control: string = '';
  if (key !== 'tailscale') {
    try { control = decodeURIComponent(key); } catch (_) { return undefined; }
    if (!/^https:\/\/[^\s/?#@]+(?:\/[^\s?#]*)?$/.test(control) || encodeURIComponent(control) !== key) {
      return undefined;
    }
  }
  const profile = new NetworkProfile();
  profile.ID = 'legacy'; profile.Name = '原有 Tailnet 连接'; profile.ControlURL = control;
  profile.LegacyState = true;
  profile.Enabled = readMixedSelection(directory).legacyEnabled;
  try {
    const saved = JSON.parse(fileIo.readTextSync(directory + LEGACY_PROFILE_FILE)) as NetworkProfile;
    // Metadata is bound to the discovered identity. Never redirect an existing
    // login to another control server or edit the identity files themselves.
    if (saved.ControlURL === control) {
      if (typeof saved.Name === 'string' && saved.Name.trim() && saved.Name.length <= 64) { profile.Name = saved.Name; }
      if (typeof saved.Hostname === 'string' && /^[a-zA-Z0-9][a-zA-Z0-9-]{0,62}$/.test(saved.Hostname)) { profile.Hostname = saved.Hostname; }
      if (typeof saved.ExitNodeIP === 'string' && (!saved.ExitNodeIP || ipFamily(saved.ExitNodeIP) !== 0)) { profile.ExitNodeIP = saved.ExitNodeIP; }
    }
  } catch (_) { /* Existing logins work before any display metadata is saved. */ }
  return profile;
}

export function saveLegacyNetworkProfile(directory: string, value: NetworkProfile): void {
  const original = readLegacyNetworkProfile(directory);
  if (original === undefined || value.ID !== 'legacy' || value.ControlURL !== original.ControlURL) {
    throw new Error('原有 Tailnet 身份已变化，请返回连接列表重新打开。');
  }
  if (!value.Name.trim() || value.Name.trim().length > 64 ||
    !/^[a-zA-Z0-9][a-zA-Z0-9-]{0,62}$/.test(value.Hostname.trim()) ||
    (value.ExitNodeIP.trim() && ipFamily(value.ExitNodeIP.trim()) === 0)) {
    throw new Error('请输入有效的连接名称、节点名称和出口 IP。');
  }
  const metadata = new NetworkProfile();
  metadata.ID = 'legacy'; metadata.Name = value.Name.trim(); metadata.Hostname = value.Hostname.trim();
  metadata.ControlURL = original.ControlURL; metadata.ExitNodeIP = value.ExitNodeIP.trim(); metadata.LegacyState = true;
  saveNetworkJSON(directory + LEGACY_PROFILE_FILE, JSON.stringify(metadata));
  setLegacySelected(directory, value.Enabled !== false);
}

export function selectedMixedTailnetIds(directory: string): string[] {
  const ids = readNetworkProfiles(directory).filter((profile: NetworkProfile): boolean => profile.Enabled !== false)
    .map((profile: NetworkProfile): string => profile.ID);
  if (readMixedSelection(directory).legacyEnabled && readLegacyNetworkProfile(directory) !== undefined) { ids.push('legacy'); }
  return ids;
}

// This is built once for a session and retained for reconnects. Profile and rule
// edits must not silently change an already running node or its identity namespace.
export function prepareMixedTailnetConfig(directory: string, dns: string[], ids: string[]): NetworkConfig {
  if (ids.length > MAX_MIXED_TAILNETS) { throw new Error('同时启用的 Tailnet 连接不能超过 16 个。'); }
  const saved = readNetworkProfiles(directory);
  const result = new NetworkConfig(); result.Directory = directory; result.DNS = dns.slice();
  const seen = new Set<string>();
  for (const id of ids) {
    if (typeof id !== 'string' || seen.has(id) || (id !== 'legacy' && !/^[0-9a-fA-F-]{8,64}$/.test(id))) {
      throw new Error('Tailnet 连接标识无效或重复。');
    }
    seen.add(id);
    const original = id === 'legacy' ? readLegacyNetworkProfile(directory) :
      saved.find((profile: NetworkProfile): boolean => profile.ID === id);
    if (original === undefined) { throw new Error('Tailnet 连接已不存在，请刷新连接列表后重试。'); }
    const profile = new NetworkProfile();
    profile.ID = original.ID; profile.Name = original.Name; profile.ControlURL = original.ControlURL;
    profile.Hostname = original.Hostname; profile.ExitNodeIP = original.ExitNodeIP;
    profile.Enabled = true; profile.LegacyState = id === 'legacy';
    const savedRules = readProfileRules(directory, id);
    const rules = savedRules.enabled ? expandProfileRules(directory, savedRules, 100000, 100000) : savedRules;
    profile.Domains = rules.enabled ? rules.manualDomains.slice() : [];
    profile.CIDRs = rules.enabled ? rules.manualCidrs.slice() : [];
    profile.Lists = rules.enabled ? rules.lists.slice() : [];
    result.Profiles.push(profile);
  }
  return result;
}
