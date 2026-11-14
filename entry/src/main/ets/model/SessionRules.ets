import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { ProfileRules, readProfileRules, expandProfileRules, collectSplitRules, MAX_SPLIT_DOMAINS } from './SplitTunnel';
import { isAddressGroupId, MAX_ADDRESS_GROUPS } from './AddressGroups';
import { dedupeStrings, isDomainListName, isDomainName } from './DomainRules';
import { NetworkConfig, NetworkProfile } from './NetworkProfiles';
import { prepareMixedTailnetConfig } from './MixedConnections';
import { SubnetPreference, readSubnetPreferences, validateSubnetPreferences } from './SubnetPreferences';
import { parseIpPrefix } from './WireGuardConfig';

const SESSION_ID: RegExp = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;
const WG_ID: RegExp = /^(main|[0-9a-fA-F-]{8,64})$/;
const TN_ID: RegExp = /^(legacy|[0-9a-fA-F-]{8,64})$/;
const MAX_JSON_BYTES: number = 8 * 1024 * 1024;
const MAX_DATABASE_BYTES: number = 16 * 1024 * 1024;

export class SessionWireGuardRules {
  ID: string;
  Rules: ProfileRules;
  Domains: string[];
  Exacts: string[];
  constructor(id: string, rules: ProfileRules, domains: string[], exacts: string[]) {
    this.ID = id; this.Rules = rules; this.Domains = domains; this.Exacts = exacts;
  }
}

export class SessionRulesSnapshot {
  version: number = 1;
  session: string = '';
  createdAt: number = 0;
  mixed: boolean = false;
  useConfigRoutes: boolean = false;
  wireguardIds: string[] = [];
  tailnetIds: string[] = [];
  WireGuard: SessionWireGuardRules[] = [];
  Tailnets?: NetworkConfig;
  SubnetPreferences: SubnetPreference[] = [];
  DatabaseBytes: number = 0;
}

function sessionPath(directory: string, session: string): string {
  if (typeof session !== 'string' || !SESSION_ID.test(session)) { throw new Error('连接会话标识无效。'); }
  return directory + '/session-rules/' + session;
}

function idsMatch(actual: string[], expected: string[]): boolean {
  return actual instanceof Array && actual.length === expected.length &&
    actual.every((id: string, index: number): boolean => id === expected[index]);
}

function checkIds(ids: string[], pattern: RegExp): void {
  if (!(ids instanceof Array) || ids.length > 16) { throw new Error('会话连接数量无效。'); }
  const seen = new Set<string>();
  for (const id of ids) {
    if (typeof id !== 'string' || !pattern.test(id) || seen.has(id)) { throw new Error('会话连接标识无效或重复。'); }
    seen.add(id);
  }
}

function strings(values: string[], limit: number = 100000): string[] {
  if (!(values instanceof Array) || values.length > limit ||
    values.some((value: string): boolean => typeof value !== 'string' || value.length > 2048)) {
    throw new Error('会话规则列表损坏。');
  }
  return values.slice();
}

function hydrateRules(source: ProfileRules): ProfileRules {
  if (!source || typeof source.enabled !== 'boolean' || typeof source.isDefault !== 'boolean') {
    throw new Error('会话规则开关损坏。');
  }
  const rules = new ProfileRules(source.enabled, source.isDefault, strings(source.lists, 4096),
    strings(source.manualDomains), strings(source.manualCidrs), source.groupIds === undefined ? [] : strings(source.groupIds, MAX_ADDRESS_GROUPS));
  if (rules.lists.some((name: string): boolean => !isDomainListName(name)) ||
    rules.groupIds.some((id: string): boolean => !isAddressGroupId(id)) ||
    rules.manualDomains.some((name: string): boolean => !isDomainName(name)) ||
    rules.manualCidrs.some((cidr: string): boolean => {
      const prefix = parseIpPrefix(cidr); return !prefix || prefix.prefixLength === 0;
    })) { throw new Error('会话分流规则格式无效。'); }
  return rules;
}

function hydrateWireGuard(source: SessionWireGuardRules, id: string): SessionWireGuardRules {
  if (!source || source.ID !== id) { throw new Error('会话 WireGuard 连接不匹配。'); }
  const rules = hydrateRules(source.Rules);
  const domains = strings(source.Domains, MAX_SPLIT_DOMAINS);
  const exacts = strings(source.Exacts, MAX_SPLIT_DOMAINS);
  if (dedupeStrings(domains.concat(exacts)).length > MAX_SPLIT_DOMAINS ||
    domains.concat(exacts).some((name: string): boolean => !isDomainName(name)) ||
    (rules.isDefault && domains.length + exacts.length > 0)) {
    throw new Error('会话展开域名规则无效。');
  }
  return new SessionWireGuardRules(id, rules, domains, exacts);
}

function hydrateTailnets(source: NetworkConfig, directory: string, ids: string[], databasePath: string): NetworkConfig {
  if (!source || source.Directory !== directory || !(source.Profiles instanceof Array) || source.Profiles.length !== ids.length ||
    source.DatabasePath !== databasePath) { throw new Error('会话 Tailnet 目录或连接不匹配。'); }
  const result = new NetworkConfig(); result.Directory = directory; result.DatabasePath = databasePath;
  result.DNS = strings(source.DNS, 32);
  for (let index = 0; index < ids.length; index++) {
    const original = source.Profiles[index];
    if (!original || original.ID !== ids[index] || original.LegacyState !== (ids[index] === 'legacy') ||
      typeof original.Name !== 'string' || typeof original.ControlURL !== 'string' ||
      typeof original.Hostname !== 'string' || typeof original.ExitNodeIP !== 'string') {
      throw new Error('会话 Tailnet 身份信息损坏。');
    }
    const profile = new NetworkProfile();
    profile.ID = original.ID; profile.Name = original.Name; profile.ControlURL = original.ControlURL;
    profile.Hostname = original.Hostname; profile.ExitNodeIP = original.ExitNodeIP; profile.LegacyState = original.LegacyState;
    profile.Domains = strings(original.Domains); profile.CIDRs = strings(original.CIDRs); profile.Lists = strings(original.Lists, 4096);
    result.Profiles.push(profile);
  }
  return result;
}

function readSnapshot(directory: string, session: string, wgIds: string[], tnIds: string[],
  mixed: boolean, useConfigRoutes: boolean): SessionRulesSnapshot {
  const folder = sessionPath(directory, session);
  try {
    if (fileIo.statSync(folder + '/rules.json').size > MAX_JSON_BYTES) { throw new Error('规则快照过大。'); }
    const source = JSON.parse(fileIo.readTextSync(folder + '/rules.json')) as SessionRulesSnapshot;
    if (!source || source.version !== 1 || source.session !== session || source.mixed !== mixed ||
      source.useConfigRoutes !== useConfigRoutes || !Number.isFinite(source.createdAt) || source.createdAt <= 0 ||
      !idsMatch(source.wireguardIds, wgIds) || !idsMatch(source.tailnetIds, tnIds) ||
      !(source.WireGuard instanceof Array) || source.WireGuard.length !== wgIds.length ||
      !Number.isInteger(source.DatabaseBytes) || source.DatabaseBytes < 0 || source.DatabaseBytes > MAX_DATABASE_BYTES) {
      throw new Error('会话标识或请求不匹配。');
    }
    const result = new SessionRulesSnapshot();
    result.session = session; result.createdAt = source.createdAt; result.mixed = mixed; result.useConfigRoutes = useConfigRoutes;
    result.wireguardIds = wgIds.slice(); result.tailnetIds = tnIds.slice();
    result.DatabaseBytes = source.DatabaseBytes;
    for (let index = 0; index < wgIds.length; index++) { result.WireGuard.push(hydrateWireGuard(source.WireGuard[index], wgIds[index])); }
    result.SubnetPreferences = validateSubnetPreferences(source.SubnetPreferences);
    if (tnIds.length > 0) {
      if (!source.Tailnets) { throw new Error('Tailnet 快照缺失。'); }
      const databasePath = result.DatabaseBytes > 0 ? folder + '/dlc.dat' : '';
      result.Tailnets = hydrateTailnets(source.Tailnets, directory, tnIds, databasePath);
      const needsDatabase = result.Tailnets.Profiles.some((profile: NetworkProfile): boolean => profile.Lists.length > 0);
      if (needsDatabase !== (result.DatabaseBytes > 0) ||
        (needsDatabase && fileIo.statSync(databasePath).size !== result.DatabaseBytes)) {
        throw new Error('会话域名数据库缺失或不完整。');
      }
    } else if (source.Tailnets !== undefined || result.DatabaseBytes !== 0) { throw new Error('会话包含未请求的 Tailnet。'); }
    return result;
  } catch (error) { throw new Error('当前连接的规则快照无法恢复，请手动断开后重新连接：' + (error as Error).message); }
}

function writeSnapshot(path: string, snapshot: SessionRulesSnapshot): void {
  const bytes = util.TextEncoder.create().encodeInto(JSON.stringify(snapshot));
  if (bytes.length > MAX_JSON_BYTES) { throw new Error('会话规则快照过大。'); }
  const file = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
  try {
    if (fileIo.writeSync(file.fd, bytes.buffer) !== bytes.length) { throw new Error('会话规则快照写入不完整。'); }
    fileIo.fsyncSync(file.fd);
  } finally { fileIo.closeSync(file); }
}

// No asynchronous gaps: freeze editable rules before transport setup begins.
// Recreating the same extension session must reuse this document, never live rules.
export function readOrCreateSessionRules(directory: string, session: string, wgIds: string[], tnIds: string[],
  mixed: boolean, useConfigRoutes: boolean): SessionRulesSnapshot {
  const folder = sessionPath(directory, session);
  checkIds(wgIds, WG_ID); checkIds(tnIds, TN_ID);
  if (fileIo.accessSync(folder)) { return readSnapshot(directory, session, wgIds, tnIds, mixed, useConfigRoutes); }
  const snapshot = new SessionRulesSnapshot(); snapshot.session = session; snapshot.createdAt = Date.now();
  snapshot.mixed = mixed; snapshot.useConfigRoutes = useConfigRoutes;
  snapshot.wireguardIds = wgIds.slice(); snapshot.tailnetIds = tnIds.slice();
  for (const id of wgIds) {
    let rules = useConfigRoutes ? new ProfileRules(false, true) : readProfileRules(directory, id);
    if (mixed && !rules.enabled && !rules.isDefault) { rules = new ProfileRules(false, true); }
    if (!rules.isDefault) { rules = expandProfileRules(directory, rules); }
    rules = hydrateRules(rules);
    const collected = collectSplitRules(directory, rules.isDefault ? [] : rules.lists);
    if (collected.missing.length > 0) { throw new Error('域名列表未完整下载，请更新后重试：' + collected.missing.join(', ')); }
    const domains = rules.isDefault ? [] : dedupeStrings(collected.rules.domains.concat(rules.manualDomains));
    const exacts = rules.isDefault ? [] : dedupeStrings(collected.rules.exacts);
    snapshot.WireGuard.push(hydrateWireGuard(new SessionWireGuardRules(id, rules, domains, exacts), id));
  }
  snapshot.SubnetPreferences = readSubnetPreferences(directory);
  if (tnIds.length > 0) { snapshot.Tailnets = prepareMixedTailnetConfig(directory, [], tnIds); }
  const temporary = folder + '.tmp-' + util.generateRandomUUID();
  try {
    fileIo.mkdirSync(temporary, true);
    if (snapshot.Tailnets && snapshot.Tailnets.Profiles.some((profile: NetworkProfile): boolean => profile.Lists.length > 0)) {
      const source = directory + '/dlc.dat'; const target = temporary + '/dlc.dat';
      fileIo.copyFileSync(source, target);
      const size = fileIo.statSync(target).size;
      if (size <= 0 || size > MAX_DATABASE_BYTES) { throw new Error('域名数据库快照大小无效，请更新后重试。'); }
      const file = fileIo.openSync(target, fileIo.OpenMode.READ_ONLY);
      try { fileIo.fsyncSync(file.fd); } finally { fileIo.closeSync(file); }
      snapshot.DatabaseBytes = size;
      snapshot.Tailnets.DatabasePath = folder + '/dlc.dat';
    }
    writeSnapshot(temporary + '/rules.json', snapshot);
    fileIo.renameSync(temporary, folder);
    return readSnapshot(directory, session, wgIds, tnIds, mixed, useConfigRoutes);
  } catch (error) {
    try { fileIo.rmdirSync(temporary); } catch (_) { /* Preserve any already published session snapshot. */ }
    if (fileIo.accessSync(folder)) { return readSnapshot(directory, session, wgIds, tnIds, mixed, useConfigRoutes); }
    throw error as Error;
  }
}

// Call only when the user ends this session, never during automatic recovery.
export function cleanupSessionRules(directory: string, session: string): void {
  const folder = sessionPath(directory, session);
  if (fileIo.accessSync(folder)) { fileIo.rmdirSync(folder); }
}

// Recovery must never create a fresh snapshot from rules edited while connected.
// Older request files did not persist route mode; recover it only from their
// existing validated snapshot instead of guessing from current editable rules.
export function readRecoverySessionRules(directory: string, session: string, wgIds: string[], tnIds: string[],
  mixed: boolean, useConfigRoutes: boolean | undefined): SessionRulesSnapshot {
  const folder = sessionPath(directory, session);
  checkIds(wgIds, WG_ID); checkIds(tnIds, TN_ID);
  if (!fileIo.accessSync(folder + '/rules.json')) {
    throw new Error('上次连接的规则快照缺失，请手动重新连接。');
  }
  let mode = useConfigRoutes;
  if (mode === undefined) {
    if (fileIo.statSync(folder + '/rules.json').size > MAX_JSON_BYTES) { throw new Error('会话规则快照过大。'); }
    const source = JSON.parse(fileIo.readTextSync(folder + '/rules.json')) as SessionRulesSnapshot;
    if (typeof source.useConfigRoutes !== 'boolean') { throw new Error('上次连接的路由方式无法确认，请手动重新连接。'); }
    mode = source.useConfigRoutes;
  }
  return readSnapshot(directory, session, wgIds, tnIds, mixed, mode);
}
