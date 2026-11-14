import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { connection } from '@kit.NetworkKit';
import { fileIo } from '@kit.CoreFileKit';
import { ipFamily } from './WireGuardConfig';
import { DomainListContent, readCachedDomainList, writeCachedDomainLists } from './DomainListCache';
import { readAddressGroups, isAddressGroupId, normalizeAddressGroupCidr, MAX_ADDRESS_GROUPS } from './AddressGroups';
import {
  DomainRules, domainRuleCount, isDomainListName, isDomainName, mergeDomainRules, parseDomainList, dedupeStrings
} from './DomainRules';

export const RESOLVED_TTL_MS: number = 12 * 60 * 60 * 1000;
export const RESOLVE_BUDGET_MS: number = 25000;
export const MAX_SPLIT_DOMAINS: number = 1200;
export const MAX_SPLIT_ROUTES: number = 3000;
export const MAX_INCLUDE_FILES: number = 48;

const RULES_FILE_PREFIX: string = '/split-rules-';
const RESOLVED_FILE_PREFIX: string = '/split-resolved-';
const CATALOG_FILE: string = '/domain-catalog.json';
const LEGACY_SPLIT_CONFIG_FILE: string = '/split-tunnel-config.json';
const LEGACY_SPLIT_RESOLVED_FILE: string = '/split-tunnel-resolved.json';
const LEGACY_PROFILE_ID: string = 'main';
const PROFILE_ID_PATTERN: RegExp = /^(main|legacy|[0-9a-fA-F-]{8,64})$/;

interface RulesDocument {
  enabled?: boolean;
  isDefault?: boolean;
  lists?: string[];
  manualDomains?: string[];
  manualCidrs?: string[];
  groupIds?: string[];
}

interface ResolvedDocument {
  updatedAt?: number;
  ipv4?: string[];
  ipv6?: string[];
}

interface CatalogDocument {
  names?: string[];
}

interface LegacySplitDocument {
  enabled?: boolean;
  selected?: string[];
}

export class ProfileRules {
  enabled: boolean;
  isDefault: boolean;
  lists: string[];
  manualDomains: string[];
  manualCidrs: string[];
  groupIds: string[];

  constructor(enabled: boolean = false, isDefault: boolean = false, lists: string[] = [],
    manualDomains: string[] = [], manualCidrs: string[] = [], groupIds: string[] = []) {
    this.enabled = enabled;
    this.isDefault = isDefault;
    this.lists = lists;
    this.manualDomains = manualDomains;
    this.manualCidrs = manualCidrs;
    this.groupIds = groupIds;
  }

  hasContent(): boolean {
    return this.lists.length > 0 || this.manualDomains.length > 0 || this.manualCidrs.length > 0 || this.groupIds.length > 0;
  }
}

export class ResolvedSplitIps {
  updatedAt: number;
  ipv4: string[];
  ipv6: string[];

  constructor(updatedAt: number = 0, ipv4: string[] = [], ipv6: string[] = []) {
    this.updatedAt = updatedAt;
    this.ipv4 = ipv4;
    this.ipv6 = ipv6;
  }
}

export class CollectedSplitRules {
  rules: DomainRules;
  missing: string[];

  constructor(rules: DomainRules, missing: string[]) {
    this.rules = rules;
    this.missing = missing;
  }
}

function checkProfileId(profileId: string): void {
  if (typeof profileId !== 'string' || !PROFILE_ID_PATTERN.test(profileId)) {
    throw new Error('配置标识无效。');
  }
}

function readText(path: string): string | undefined {
  try {
    return fileIo.readTextSync(path);
  } catch (_) {
    return undefined;
  }
}

function writeText(path: string, text: string): void {
  const temporary = path + '.' + util.generateRandomUUID() + '.tmp';
  const bytes = util.TextEncoder.create().encodeInto(text);
  try {
    const file = fileIo.openSync(temporary,
      fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    try {
      if (fileIo.writeSync(file.fd, bytes.buffer) !== bytes.length) {
        throw new Error('无法写入文件。');
      }
    } finally {
      fileIo.closeSync(file);
    }
    fileIo.renameSync(temporary, path);
  } catch (error) {
    try {
      fileIo.unlinkSync(temporary);
    } catch (_) {
      // The temporary file may not have been created.
    }
    throw error as Error;
  }
}

function rulesPath(directory: string, profileId: string): string {
  return directory + RULES_FILE_PREFIX + profileId + '.json';
}

function resolvedPath(directory: string, profileId: string): string {
  return directory + RESOLVED_FILE_PREFIX + profileId + '.json';
}

export function readProfileRules(directory: string, profileId: string): ProfileRules {
  checkProfileId(profileId);
  const rules = new ProfileRules();
  const raw = readText(rulesPath(directory, profileId));
  if (raw === undefined) {
    return rules;
  }
  let groupIds: string[] | undefined;
  try {
    const parsed = JSON.parse(raw) as RulesDocument;
    groupIds = parsed.groupIds;
    if (parsed.enabled === true) {
      rules.enabled = true;
    }
    if (parsed.isDefault === true) {
      rules.isDefault = true;
    }
    if (Array.isArray(parsed.lists)) {
      for (const name of parsed.lists) {
        if (typeof name === 'string' && isDomainListName(name) && !rules.lists.includes(name)) {
          rules.lists.push(name);
        }
      }
    }
    if (Array.isArray(parsed.manualDomains)) {
      for (const domain of parsed.manualDomains) {
        if (typeof domain === 'string' && !rules.manualDomains.includes(domain)) {
          rules.manualDomains.push(domain);
        }
      }
    }
    if (Array.isArray(parsed.manualCidrs)) {
      for (const cidr of parsed.manualCidrs) {
        if (typeof cidr === 'string' && !rules.manualCidrs.includes(cidr)) {
          rules.manualCidrs.push(cidr);
        }
      }
    }
  } catch (_) {
    // Fall back to defaults for a corrupted document.
  }
  if (groupIds !== undefined) { rules.groupIds = checkedGroupIds(groupIds); }
  return rules;
}

function checkedGroupIds(values: string[]): string[] {
  if (!(values instanceof Array) || values.length > MAX_ADDRESS_GROUPS ||
    values.some((id: string): boolean => !isAddressGroupId(id))) { throw new Error('规则中的地址组引用无效。'); }
  return dedupeStrings(values.map((id: string): string => id.toLowerCase()));
}

// Expand only when constructing a new session (or validating an edit). Recovery
// hydrates the already expanded snapshot and never reads the live address groups.
export function expandProfileRules(directory: string, source: ProfileRules,
  maxDomains: number = MAX_SPLIT_DOMAINS, maxCidrs: number = MAX_SPLIT_ROUTES): ProfileRules {
  const ids = checkedGroupIds(source.groupIds || []);
  const rules = new ProfileRules(source.enabled, source.isDefault, source.lists.slice(),
    source.manualDomains.slice(), source.manualCidrs.slice(), ids);
  if (ids.length > 0) {
    const groups = readAddressGroups(directory);
    for (const id of ids) {
      const group = groups.find((item): boolean => item.id === id);
      if (!group) { throw new Error('规则引用的地址组不存在，请重新选择：' + id); }
      rules.manualDomains = rules.manualDomains.concat(group.domains);
      rules.manualCidrs = rules.manualCidrs.concat(group.cidrs);
    }
  }
  rules.manualDomains = dedupeStrings(rules.manualDomains.map((value: string): string => {
    const domain = value.trim().toLowerCase().replace(/\.$/, '');
    if (!isDomainName(domain)) { throw new Error('规则中的域名无效：' + value); }
    return domain;
  }));
  rules.manualCidrs = dedupeStrings(rules.manualCidrs.map((value: string): string => normalizeAddressGroupCidr(value)));
  if (rules.manualDomains.length > maxDomains) { throw new Error('手动规则与地址组展开后超过 ' + maxDomains.toString() + ' 个域名，请减少成员。'); }
  if (rules.manualCidrs.length > maxCidrs) { throw new Error('手动规则与地址组展开后超过 ' + maxCidrs.toString() + ' 个 IP 段，请减少成员。'); }
  return rules;
}

export function writeProfileRules(directory: string, profileId: string, rules: ProfileRules): void {
  checkProfileId(profileId);
  const document: RulesDocument = {
    enabled: rules.enabled,
    isDefault: rules.isDefault,
    lists: rules.lists,
    manualDomains: rules.manualDomains,
    manualCidrs: rules.manualCidrs,
    groupIds: checkedGroupIds(rules.groupIds || []),
  };
  writeText(rulesPath(directory, profileId), JSON.stringify(document));
}

export function deleteProfileRulesFiles(directory: string, profileId: string): void {
  checkProfileId(profileId);
  for (const path of [rulesPath(directory, profileId), resolvedPath(directory, profileId)]) {
    try {
      fileIo.unlinkSync(path);
    } catch (_) {
      // The file may not exist.
    }
  }
}

// Copies pre-multi-profile split settings into the rules of the legacy main
// profile: a legacy split tunnel keeps routing only the selected sites, while
// a disabled split configuration becomes the default tunnel.
export function migrateLegacySplitRules(directory: string): void {
  const legacyConfig = readText(directory + LEGACY_SPLIT_CONFIG_FILE);
  if (legacyConfig !== undefined && !fileIo.accessSync(rulesPath(directory, LEGACY_PROFILE_ID))) {
    try {
      const parsed = JSON.parse(legacyConfig) as LegacySplitDocument;
      const selected: string[] = [];
      if (Array.isArray(parsed.selected)) {
        for (const name of parsed.selected) {
          if (typeof name === 'string' && isDomainListName(name) && !selected.includes(name)) {
            selected.push(name);
          }
        }
      }
      const splitEnabled = parsed.enabled === true && selected.length > 0;
      writeProfileRules(directory, LEGACY_PROFILE_ID,
        new ProfileRules(splitEnabled, !splitEnabled, splitEnabled ? selected : []));
    } catch (_) {
      // Keep the legacy document for a later retry.
      return;
    }
  }
  const legacyResolved = readText(directory + LEGACY_SPLIT_RESOLVED_FILE);
  if (legacyResolved !== undefined && !fileIo.accessSync(resolvedPath(directory, LEGACY_PROFILE_ID))) {
    writeText(resolvedPath(directory, LEGACY_PROFILE_ID), legacyResolved);
  }
  try {
    fileIo.unlinkSync(directory + LEGACY_SPLIT_CONFIG_FILE);
  } catch (_) {
    // The file may not exist.
  }
  try {
    fileIo.unlinkSync(directory + LEGACY_SPLIT_RESOLVED_FILE);
  } catch (_) {
    // The file may not exist.
  }
}

export function readCatalogCache(directory: string): string[] | undefined {
  const raw = readText(directory + CATALOG_FILE);
  if (raw === undefined) {
    return undefined;
  }
  try {
    const parsed = JSON.parse(raw) as CatalogDocument;
    if (!Array.isArray(parsed.names)) {
      return undefined;
    }
    const names: string[] = [];
    for (const name of parsed.names) {
      if (typeof name === 'string' && isDomainListName(name) && !names.includes(name)) {
        names.push(name);
      }
    }
    return names;
  } catch (_) {
    return undefined;
  }
}

export function writeCatalogCache(directory: string, names: string[]): void {
  const document: CatalogDocument = { names: names };
  writeText(directory + CATALOG_FILE, JSON.stringify(document));
}

export function hasDomainListCache(directory: string, name: string): boolean {
  return readCachedDomainList(directory, name) !== undefined;
}

export function readDomainListCache(directory: string, name: string): string | undefined {
  return readCachedDomainList(directory, name);
}

export function writeDomainListCache(directory: string, name: string, content: string): void {
  writeCachedDomainLists(directory, [new DomainListContent(name, content)]);
}

export function readResolvedIps(directory: string, profileId: string): ResolvedSplitIps | undefined {
  checkProfileId(profileId);
  const raw = readText(resolvedPath(directory, profileId));
  if (raw === undefined) {
    return undefined;
  }
  try {
    const parsed = JSON.parse(raw) as ResolvedDocument;
    const updatedAt = typeof parsed.updatedAt === 'number' ? parsed.updatedAt : 0;
    const ipv4: string[] = [];
    const ipv6: string[] = [];
    if (Array.isArray(parsed.ipv4)) {
      for (const address of parsed.ipv4) {
        if (typeof address === 'string' && ipFamily(address) === 4 && !ipv4.includes(address)) {
          ipv4.push(address);
        }
      }
    }
    if (Array.isArray(parsed.ipv6)) {
      for (const address of parsed.ipv6) {
        if (typeof address === 'string' && ipFamily(address) === 6 && !ipv6.includes(address)) {
          ipv6.push(address);
        }
      }
    }
    return new ResolvedSplitIps(updatedAt, ipv4, ipv6);
  } catch (_) {
    return undefined;
  }
}

export function writeResolvedIps(directory: string, profileId: string, resolved: ResolvedSplitIps): void {
  checkProfileId(profileId);
  const document: ResolvedDocument = { updatedAt: resolved.updatedAt, ipv4: resolved.ipv4, ipv6: resolved.ipv6 };
  writeText(resolvedPath(directory, profileId), JSON.stringify(document));
}

export function clearResolvedIps(directory: string, profileId: string): void {
  checkProfileId(profileId);
  try {
    fileIo.unlinkSync(resolvedPath(directory, profileId));
  } catch (_) {
    // The file may not exist yet.
  }
}

export function collectSplitRules(directory: string, selected: string[]): CollectedSplitRules {
  const rules: DomainRules = { domains: [], exacts: [], includes: [], skipped: 0 };
  const missing: string[] = [];
  const visited = new Set<string>();
  const queue: string[] = [];
  for (const name of selected) {
    if (isDomainListName(name) && !queue.includes(name)) {
      queue.push(name);
    }
  }
  while (queue.length > 0 && visited.size < MAX_INCLUDE_FILES) {
    const name = queue[0];
    queue.splice(0, 1);
    if (visited.has(name)) {
      continue;
    }
    visited.add(name);
    const content = readDomainListCache(directory, name);
    if (content === undefined) {
      missing.push(name);
      continue;
    }
    const parsed = parseDomainList(content);
    mergeDomainRules(rules, parsed);
    for (const include of parsed.includes) {
      if (!visited.has(include) && !queue.includes(include)) {
        queue.push(include);
      }
    }
  }
  for (const name of queue) { if (!visited.has(name) && !missing.includes(name)) { missing.push(name); } }
  return new CollectedSplitRules(rules, missing);
}

export function selectedDomainCount(directory: string, selected: string[]): number {
  return domainRuleCount(collectSplitRules(directory, selected).rules);
}

export async function resolveSplitDomains(domains: string[], wantFamilies: number[], budgetMs: number,
  onProgress?: (done: number, total: number) => void): Promise<ResolvedSplitIps> {
  const result = new ResolvedSplitIps();
  result.updatedAt = Date.now();
  const ipv4 = new Set<string>();
  const ipv6 = new Set<string>();
  const deadline = Date.now() + budgetMs;
  const batch = 20;
  let done = 0;
  for (let start = 0; start < domains.length; start += batch) {
    if (Date.now() >= deadline) {
      break;
    }
    const group = domains.slice(start, Math.min(start + batch, domains.length));
    const answers = await Promise.all(group.map((domain: string): Promise<connection.NetAddress[]> =>
      connection.getAddressesByName(domain).catch((error: BusinessError): connection.NetAddress[] => [])));
    for (const answer of answers) {
      for (const netAddress of answer) {
        if (typeof netAddress.address !== 'string') {
          continue;
        }
        const family = ipFamily(netAddress.address);
        if (family === 4 && wantFamilies.includes(4)) {
          ipv4.add(netAddress.address);
        } else if (family === 6 && wantFamilies.includes(6)) {
          ipv6.add(netAddress.address);
        }
      }
    }
    done += group.length;
    if (onProgress !== undefined) {
      onProgress(done, domains.length);
    }
  }
  for (const address of ipv4) {
    result.ipv4.push(address);
  }
  for (const address of ipv6) {
    result.ipv6.push(address);
  }
  return result;
}
