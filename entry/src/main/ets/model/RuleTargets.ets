import { common } from '@kit.AbilityKit';
import { readNetworkProfiles, readNetworkStatus } from './NetworkProfiles';
import { isValidProfileId, listProfiles } from './ProfileStore';
import { readProfileRules } from './SplitTunnel';
import { readTailnet } from './TailnetState';
import { readTunnelState, TunnelPhase } from './TunnelState';
import { readLegacyNetworkProfile } from './MixedConnections';

export class RuleTarget {
  ID: string;
  Name: string;
  Kind: string;
  Enabled: boolean;
  IsDefault: boolean;

  constructor(id: string, name: string, kind: string, enabled: boolean, isDefault: boolean = false) {
    this.ID = id;
    this.Name = name;
    this.Kind = kind;
    this.Enabled = enabled;
    this.IsDefault = isDefault;
  }

  key(): string { return this.Kind + ':' + this.ID; }
  label(): string { return this.Name + ' · ' + (this.Kind === 'wireguard' ? 'WireGuard' : 'Tailnet'); }
}

export function readRuleTargets(context: common.UIAbilityContext): RuleTarget[] {
  const targets: RuleTarget[] = [];
  const ids = new Set<string>();
  for (const profile of readNetworkProfiles(context.filesDir)) {
    if (!profile || !isValidProfileId(profile.ID) || typeof profile.Name !== 'string') {
      throw new Error('Tailnet 连接配置信息不完整。');
    }
    if (ids.has(profile.ID)) { throw new Error('连接标识重复，已暂停规则编辑，请重新创建重复的连接。'); }
    ids.add(profile.ID);
    targets.push(new RuleTarget(profile.ID, profile.Name, 'tailnet', profile.Enabled !== false));
  }
  const legacy = readLegacyNetworkProfile(context.filesDir);
  if (legacy !== undefined) {
    if (ids.has(legacy.ID)) { throw new Error('连接标识重复，已暂停规则编辑，请重新创建重复的连接。'); }
    ids.add(legacy.ID);
    targets.push(new RuleTarget(legacy.ID, legacy.Name, 'tailnet', legacy.Enabled !== false));
  }
  for (const profile of listProfiles(context)) {
    // The existing rules store is keyed by the raw ID. Never mutate a shared ID across protocols.
    if (ids.has(profile.id)) { throw new Error('Tailnet 与 WireGuard 连接标识冲突，已暂停规则编辑，请重新创建重复的连接。'); }
    ids.add(profile.id);
    const rules = readProfileRules(context.filesDir, profile.id);
    targets.push(new RuleTarget(profile.id, profile.name, 'wireguard', rules.enabled || rules.isDefault, rules.isDefault));
  }
  return targets;
}

export function ruleConnectionsActive(dir: string): boolean {
  const tailnet = readTailnet(dir);
  const wireguard = readTunnelState(dir);
  const wireguardActive = wireguard !== undefined && Date.now() - wireguard.updated < 90000 &&
    (wireguard.phase === TunnelPhase.Starting || wireguard.phase === TunnelPhase.Waiting ||
      wireguard.phase === TunnelPhase.Connected || wireguard.phase === TunnelPhase.Stopping);
  return readNetworkStatus(dir).active || tailnet.connected ||
    (tailnet.BackendState !== 'Stopped' && tailnet.BackendState !== 'Failed') || wireguardActive;
}
