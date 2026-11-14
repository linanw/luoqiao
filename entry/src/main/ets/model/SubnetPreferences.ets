import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { NetworkNodeStatus } from './NetworkProfiles';
import { parseIpPrefix } from './WireGuardConfig';

export type SubnetPriority = 'local' | 'tailnet';
export const MAX_SUBNET_PREFERENCES: number = 128;
const FILE: string = '/subnet-preferences.json';
const MAX_BYTES: number = 65536;
const TAILNET_ID: RegExp = /^(legacy|[0-9a-fA-F-]{8,64})$/;

export class SubnetPreference {
  CIDR: string;
  Priority: SubnetPriority;
  TailnetID?: string;
  constructor(cidr: string, priority: SubnetPriority, tailnetID?: string) {
    this.CIDR = cidr; this.Priority = priority;
    if (tailnetID) { this.TailnetID = tailnetID; }
  }
}

interface SubnetDocument { version: number; preferences: SubnetPreference[]; }

export function normalizeSubnetCIDR(value: string): string {
  if (typeof value !== 'string') { throw new Error('请输入有效的 IPv4 或 IPv6 网段。'); }
  const prefix = parseIpPrefix(value.trim());
  if (prefix === undefined || prefix.prefixLength === 0) { throw new Error('请输入有效网段，例如 192.168.72.0/24；不支持默认路由 /0。'); }
  return prefix.address + '/' + prefix.prefixLength.toString();
}

export function validateSubnetPreferences(values: SubnetPreference[]): SubnetPreference[] {
  if (!(values instanceof Array) || values.length > MAX_SUBNET_PREFERENCES) { throw new Error('最多保存 128 个网段偏好。'); }
  const normalized: SubnetPreference[] = [];
  const seen = new Set<string>();
  for (const value of values) {
    if (!value || (value.Priority !== 'local' && value.Priority !== 'tailnet')) { throw new Error('网段偏好需选择本地网络或 Tailnet。'); }
    const cidr = normalizeSubnetCIDR(value.CIDR);
    if (seen.has(cidr)) { throw new Error('网段 ' + cidr + ' 已有偏好，请修改已有条目。'); }
    if (value.TailnetID !== undefined && (typeof value.TailnetID !== 'string' ||
      (value.TailnetID && !TAILNET_ID.test(value.TailnetID)))) { throw new Error('Tailnet 连接标识无效。'); }
    if (value.Priority === 'local' && value.TailnetID) { throw new Error('本地网络偏好不能同时指定 Tailnet。'); }
    seen.add(cidr);
    normalized.push(new SubnetPreference(cidr, value.Priority, value.TailnetID));
  }
  return normalized;
}

export function readSubnetPreferences(directory: string): SubnetPreference[] {
  const path = directory + FILE;
  if (!fileIo.accessSync(path)) { return []; }
  let document: SubnetDocument;
  try {
    const text = fileIo.readTextSync(path);
    if (text.length > MAX_BYTES) { throw new Error('网段偏好文件过大。'); }
    document = JSON.parse(text) as SubnetDocument;
  } catch (_) { throw new Error('无法读取网段偏好，现有设置已保留。'); }
  if (!document || document.version !== 1) { throw new Error('网段偏好文件版本无效。'); }
  return validateSubnetPreferences(document.preferences);
}

export function saveSubnetPreferences(directory: string, values: SubnetPreference[]): void {
  const document: SubnetDocument = { version: 1, preferences: validateSubnetPreferences(values) };
  const bytes = util.TextEncoder.create().encodeInto(JSON.stringify(document));
  const path = directory + FILE;
  const temporary = path + '.' + util.generateRandomUUID() + '.tmp';
  try {
    const file = fileIo.openSync(temporary, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
    try {
      if (fileIo.writeSync(file.fd, bytes.buffer) !== bytes.length) { throw new Error('网段偏好写入不完整。'); }
      fileIo.fsyncSync(file.fd);
    } finally { fileIo.closeSync(file); }
    fileIo.renameSync(temporary, path);
  } catch (error) {
    try { fileIo.unlinkSync(temporary); } catch (_) { /* No staged file remains. */ }
    throw error as Error;
  }
}

export class SubnetSuggestion {
  CIDR: string;
  Local: boolean = false;
  OverlapsLocal: boolean = false;
  TailnetIDs: string[] = [];
  constructor(cidr: string) { this.CIDR = cidr; }
}

function overlaps(first: string, second: string): boolean {
  const a = parseIpPrefix(first); const b = parseIpPrefix(second);
  if (!a || !b || a.family !== b.family) { return false; }
  const bits = Math.min(a.prefixLength, b.prefixLength);
  return parseIpPrefix(a.address + '/' + bits)?.address === parseIpPrefix(b.address + '/' + bits)?.address;
}

export function collectSubnetSuggestions(localPrefixes: string[], nodes: NetworkNodeStatus[]): SubnetSuggestion[] {
  const entries = new Map<string, SubnetSuggestion>();
  for (const raw of localPrefixes.slice(0, 256)) {
    try { const cidr = normalizeSubnetCIDR(raw); const item = new SubnetSuggestion(cidr); item.Local = true; entries.set(cidr, item); }
    catch (_) { /* Skip unavailable or invalid discovery data. */ }
  }
  const locals = Array.from(entries.keys());
  for (const node of nodes.slice(0, 16)) {
    if (!TAILNET_ID.test(node.ID)) { continue; }
    for (const raw of (node.SubnetRoutes || []).slice(0, 4096)) {
      try {
        const cidr = normalizeSubnetCIDR(raw);
        const item = entries.get(cidr) || new SubnetSuggestion(cidr);
        if (!item.TailnetIDs.includes(node.ID)) { item.TailnetIDs.push(node.ID); }
        item.OverlapsLocal = locals.some((local: string): boolean => overlaps(local, cidr));
        entries.set(cidr, item);
      } catch (_) { /* Discovery is a suggestion, never an implicit route setting. */ }
    }
  }
  return Array.from(entries.values()).sort((a: SubnetSuggestion, b: SubnetSuggestion): number => {
    const left = a.Local ? 2 : a.OverlapsLocal ? 1 : 0;
    const right = b.Local ? 2 : b.OverlapsLocal ? 1 : 0;
    return right - left || a.CIDR.localeCompare(b.CIDR);
  });
}

export function visibleSubnetSuggestions(items: SubnetSuggestion[], query: string): SubnetSuggestion[] {
  const search = query.trim().toLowerCase();
  return items.filter((item: SubnetSuggestion): boolean => !search || item.CIDR.toLowerCase().includes(search)).slice(0, 12);
}
