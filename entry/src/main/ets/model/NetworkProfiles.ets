import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { readProfileRules, expandProfileRules } from './SplitTunnel';
export class NetworkProfile {
  Enabled: boolean = true;
  ID: string = '';
  Name: string = '';
  ControlURL: string = '';
  Hostname: string = 'harmony';
  ExitNodeIP: string = '';
  Domains: string[] = [];
  CIDRs: string[] = [];
  Lists: string[] = [];
  LegacyState: boolean = false;
}
export class NetworkConfig {
  Directory: string = '';
  DatabasePath: string = '';
  DNS: string[] = [];
  Profiles: NetworkProfile[] = [];
}
export class NetworkNodeStatus {
  ID: string = '';
  Name: string = '';
  BackendState: string = '';
  AuthURL: string = '';
  Error: string = '';
  DNSSuffix: string = '';
  TailscaleIPs: string[] = [];
  ExitNodes: string[] = [];
  PeerIPs: string[] = [];
  PeerNames: string[] = [];
  SubnetRoutes: string[] = [];
}
export class NetworkStatus {
  Nodes: NetworkNodeStatus[] = [];
  SentBytes: number = 0;
  ReceivedBytes: number = 0;
  ReadError: string = '';
  WriteError: string = '';
  active: boolean = false;
  error: string = '';
  updated: number = 0;
}
export function saveNetworkJSON(path: string, value: string): void {
  const tmp = path + '.' + util.generateRandomUUID() + '.tmp';
  const f = fileIo.openSync(tmp, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
  try { fileIo.writeSync(f.fd, value); } finally { fileIo.closeSync(f); }
  fileIo.renameSync(tmp, path);
}
export function readNetworkProfiles(dir: string): NetworkProfile[] {
  try { return JSON.parse(fileIo.readTextSync(dir + '/network-profiles.json')) as NetworkProfile[]; }
  catch (_) { return []; }
}
export function saveNetworkProfiles(dir: string, profiles: NetworkProfile[]): void {
  saveNetworkJSON(dir + '/network-profiles.json', JSON.stringify(profiles));
}
export function prepareNetworkConfig(dir: string, dns: string[]): string {
  const config = new NetworkConfig(); config.Directory = dir; config.DNS = dns;
  config.Profiles = readNetworkProfiles(dir).filter((profile: NetworkProfile): boolean => profile.Enabled !== false);
  for (const profile of config.Profiles) {
    const saved = readProfileRules(dir, profile.ID);
    const rules = saved.enabled ? expandProfileRules(dir, saved, 100000, 100000) : saved;
    profile.Domains = rules.enabled ? rules.manualDomains : [];
    profile.CIDRs = rules.enabled ? rules.manualCidrs : [];
    profile.Lists = rules.enabled ? rules.lists : [];
  }
  const path = dir + '/network-runtime.json'; saveNetworkJSON(path, JSON.stringify(config)); return path;
}
export function writeNetworkStatus(dir: string, state: NetworkStatus): void {
  state.updated = Date.now(); saveNetworkJSON(dir + '/network-status.json', JSON.stringify(state));
}
export function readNetworkStatus(dir: string): NetworkStatus {
  try { const s = JSON.parse(fileIo.readTextSync(dir + '/network-status.json')) as NetworkStatus;
    return Date.now() - s.updated < 15000 ? s : new NetworkStatus(); }
  catch (_) { return new NetworkStatus(); }
}
