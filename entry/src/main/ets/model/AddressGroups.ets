import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { isDomainName } from './DomainRules';
import { parseIpPrefix } from './WireGuardConfig';

export const MAX_ADDRESS_GROUPS: number = 128;
export const MAX_ADDRESS_GROUP_DOMAINS: number = 1200;
export const MAX_ADDRESS_GROUP_CIDRS: number = 3000;
export const MAX_ADDRESS_GROUP_NAME_LENGTH: number = 64;
export const MAX_ADDRESS_GROUP_INPUT_LENGTH: number = 2 * 1024 * 1024;
const MAX_DOCUMENT_LENGTH: number = 32 * 1024 * 1024;
const FILE: string = '/address-groups.json';
const GROUP_ID: RegExp = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;
const RULE_FILE: RegExp = /^split-rules-(main|legacy|[0-9a-fA-F-]{8,64})\.json$/;

export class AddressGroup {
  id: string;
  name: string;
  domains: string[];
  cidrs: string[];
  constructor(id: string = '', name: string = '', domains: string[] = [], cidrs: string[] = []) {
    this.id = id; this.name = name; this.domains = domains; this.cidrs = cidrs;
  }
}

export interface AddressGroupEntries { domains: string[]; cidrs: string[]; duplicates: number; }
interface AddressGroupsDocument { version: number; groups: AddressGroup[]; }
interface GroupReferences { groupIds?: string[]; }

export function isAddressGroupId(id: string): boolean { return typeof id === 'string' && GROUP_ID.test(id); }

export function normalizeAddressGroupCidr(value: string): string {
  if (typeof value !== 'string') { throw new Error('请输入有效的 IPv4／IPv6 地址或网段。'); }
  const prefix = parseIpPrefix(value.trim());
  if (!prefix || prefix.prefixLength === 0) { throw new Error('IP 地址或网段无效，不支持 /0 默认路由。'); }
  return prefix.address + '/' + prefix.prefixLength.toString();
}

function normalizeDomain(value: string): string {
  if (typeof value !== 'string') { throw new Error('域名格式无效。'); }
  const domain = value.trim().toLowerCase().replace(/\.$/, '');
  if (!isDomainName(domain) || /^[0-9.]+$/.test(domain)) {
    throw new Error('请输入域名或 IP 地址，不支持网址、通配符或端口。');
  }
  return domain;
}

function checkCounts(domains: string[], cidrs: string[]): void {
  if (domains.length > MAX_ADDRESS_GROUP_DOMAINS) { throw new Error('每个地址组最多包含 1200 个域名。'); }
  if (cidrs.length > MAX_ADDRESS_GROUP_CIDRS) { throw new Error('每个地址组最多包含 3000 个 IP 地址或网段。'); }
}

export function parseAddressGroupEntries(text: string): AddressGroupEntries {
  if (typeof text !== 'string' || text.length > MAX_ADDRESS_GROUP_INPUT_LENGTH) { throw new Error('地址列表过大，请分批整理后导入。'); }
  const result: AddressGroupEntries = { domains: [], cidrs: [], duplicates: 0 };
  const seen = new Set<string>();
  let itemNumber = 0;
  const lines = text.split('\n');
  for (let lineIndex = 0; lineIndex < lines.length; lineIndex++) {
    for (const token of lines[lineIndex].split(/[\s,;，；、]+/)) {
      if (!token) { continue; }
      itemNumber++;
      try {
        const prefix = parseIpPrefix(token);
        const isIP = prefix !== undefined || token.includes('/') || token.includes(':') || /^[0-9.]+$/.test(token);
        const value = isIP ? normalizeAddressGroupCidr(token) : normalizeDomain(token);
        const key = (isIP ? 'ip:' : 'domain:') + value;
        if (seen.has(key)) { result.duplicates++; continue; }
        seen.add(key);
        if (isIP) { result.cidrs.push(value); } else { result.domains.push(value); }
        checkCounts(result.domains, result.cidrs);
      } catch (error) {
        throw new Error('第 ' + (lineIndex + 1).toString() + ' 行、第 ' + itemNumber.toString() +
          ' 项「' + token.slice(0, 100) + '」：' + (error as Error).message);
      }
    }
  }
  return result;
}

function normalizeGroup(group: AddressGroup): AddressGroup {
  if (!group || !isAddressGroupId(group.id)) { throw new Error('地址组标识无效。'); }
  if (typeof group.name !== 'string' || !group.name.trim() || group.name.trim().length > MAX_ADDRESS_GROUP_NAME_LENGTH ||
    /[\u0000-\u001f\u007f]/.test(group.name)) { throw new Error('地址组名称需要 1–64 个字符，且不能含有控制字符。'); }
  if (!(group.domains instanceof Array) || !(group.cidrs instanceof Array)) { throw new Error('地址组成员格式无效。'); }
  checkCounts(group.domains, group.cidrs);
  const domains = new Set<string>(); const cidrs = new Set<string>();
  for (const domain of group.domains) { domains.add(normalizeDomain(domain)); }
  for (const cidr of group.cidrs) { cidrs.add(normalizeAddressGroupCidr(cidr)); }
  return new AddressGroup(group.id.toLowerCase(), group.name.trim(), Array.from(domains), Array.from(cidrs));
}

export function readAddressGroups(directory: string): AddressGroup[] {
  const path = directory + FILE;
  if (!fileIo.accessSync(path)) { return []; }
  let document: AddressGroupsDocument;
  try {
    const text = fileIo.readTextSync(path);
    if (text.length > MAX_DOCUMENT_LENGTH) { throw new Error('地址组文件过大。'); }
    document = JSON.parse(text) as AddressGroupsDocument;
  } catch (_) { throw new Error('地址组文件无法读取或已损坏，原文件已保留。'); }
  if (!document || document.version !== 1 || !(document.groups instanceof Array) || document.groups.length > MAX_ADDRESS_GROUPS) {
    throw new Error('地址组文件格式无效，最多保存 128 个地址组。');
  }
  const groups: AddressGroup[] = []; const seen = new Set<string>();
  for (const source of document.groups) {
    const group = normalizeGroup(source);
    if (seen.has(group.id)) { throw new Error('地址组文件包含重复标识，原文件已保留。'); }
    seen.add(group.id); groups.push(group);
  }
  return groups;
}

function writeAddressGroups(directory: string, groups: AddressGroup[]): void {
  const document: AddressGroupsDocument = { version: 1, groups: groups };
  const bytes = util.TextEncoder.create().encodeInto(JSON.stringify(document));
  if (bytes.length > MAX_DOCUMENT_LENGTH) { throw new Error('地址组文件过大，请减少成员数量。'); }
  const path = directory + FILE; const temporary = path + '.' + util.generateRandomUUID() + '.tmp';
  try {
    const file = fileIo.openSync(temporary, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
    try {
      if (fileIo.writeSync(file.fd, bytes.buffer) !== bytes.length) { throw new Error('地址组写入不完整。'); }
      fileIo.fsyncSync(file.fd);
    } finally { fileIo.closeSync(file); }
    fileIo.renameSync(temporary, path);
  } catch (error) {
    try { fileIo.unlinkSync(temporary); } catch (_) { /* The previous complete document is preserved. */ }
    throw error as Error;
  }
}

export function saveAddressGroup(directory: string, source: AddressGroup): AddressGroup {
  const groups = readAddressGroups(directory);
  if (!source || typeof source.id !== 'string') { throw new Error('地址组内容或标识无效。'); }
  const group = normalizeGroup(new AddressGroup(source.id || util.generateRandomUUID(), source.name, source.domains, source.cidrs));
  const index = groups.findIndex((item: AddressGroup): boolean => item.id === group.id);
  if (index < 0) {
    if (source.id) { throw new Error('此地址组已不存在，请返回列表后重新创建。'); }
    if (groups.length >= MAX_ADDRESS_GROUPS) { throw new Error('最多保存 128 个地址组。'); }
    groups.push(group);
  } else { groups[index] = group; }
  writeAddressGroups(directory, groups);
  return group;
}

export function deleteAddressGroup(directory: string, id: string): void {
  if (!isAddressGroupId(id)) { throw new Error('地址组标识无效。'); }
  const groups = readAddressGroups(directory); const canonical = id.toLowerCase();
  if (!groups.some((group: AddressGroup): boolean => group.id === canonical)) { return; }
  for (const name of fileIo.listFileSync(directory)) {
    if (!RULE_FILE.test(name)) { continue; }
    let references: GroupReferences;
    try { references = JSON.parse(fileIo.readTextSync(directory + '/' + name)) as GroupReferences; }
    catch (_) { throw new Error('无法确认现有规则是否使用此地址组，请修复规则文件后再删除。'); }
    if (!references || typeof references !== 'object' || references instanceof Array ||
      (references.groupIds !== undefined && (!(references.groupIds instanceof Array) ||
      references.groupIds.some((value: string): boolean => !isAddressGroupId(value))))) {
      throw new Error('现有规则的地址组引用无效，请修复后再删除。');
    }
    if ((references.groupIds || []).some((value: string): boolean => value.toLowerCase() === canonical)) {
      throw new Error('此地址组仍被连接规则使用，请先在自定义规则中取消分配，再删除地址组。');
    }
  }
  writeAddressGroups(directory, groups.filter((group: AddressGroup): boolean => group.id !== canonical));
}
