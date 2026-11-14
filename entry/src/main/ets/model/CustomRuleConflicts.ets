import { AddressGroup, readAddressGroups, normalizeAddressGroupCidr } from './AddressGroups';
import { RuleTarget } from './RuleTargets';
import { ProfileRules, readProfileRules, collectSplitRules, MAX_SPLIT_DOMAINS,
  MAX_SPLIT_ROUTES } from './SplitTunnel';

export class CustomRuleOverride {
  id: string;
  rules: ProfileRules;
  constructor(id: string, rules: ProfileRules) { this.id = id; this.rules = rules; }
}

class RuleOwner {
  id: string;
  name: string;
  source: string;
  constructor(id: string, name: string, source: string) {
    this.id = id; this.name = name; this.source = source;
  }
}

function claim(owners: Map<string, RuleOwner>, key: string, value: string, owner: RuleOwner): void {
  const previous = owners.get(key);
  if (previous && previous.id !== owner.id) {
    throw new Error('地址「' + value + '」同时属于「' + previous.name + '」的' + previous.source +
      '和「' + owner.name + '」的' + owner.source + '，请先调整归属。');
  }
  owners.set(key, owner);
}

// Check the proposed saved configuration before publishing either rule or group
// edits. Prefix/suffix overlaps remain legal and use the engine's longest match.
export function validateCustomRuleAssignments(directory: string, targets: RuleTarget[],
  overrides: CustomRuleOverride[] = [], replacementGroup?: AddressGroup): void {
  const groups = readAddressGroups(directory);
  const byId = new Map<string, AddressGroup>();
  for (const group of groups) { byId.set(group.id, group); }
  if (replacementGroup && replacementGroup.id) { byId.set(replacementGroup.id, replacementGroup); }
  const owners = new Map<string, RuleOwner>();
  for (const target of targets) {
    const replacement = overrides.find((item: CustomRuleOverride): boolean => item.id === target.ID);
    const rules = replacement ? replacement.rules : readProfileRules(directory, target.ID);
    const domains = new Set<string>();
    const cidrs = new Set<string>();
    const manual = new RuleOwner(target.key(), target.Name, '自定义规则');
    for (const raw of rules.manualDomains) {
      const value = raw.trim().toLowerCase().replace(/\.$/, '');
      claim(owners, 'domain:' + value, value, manual); domains.add(value);
    }
    for (const raw of rules.manualCidrs) {
      const value = normalizeAddressGroupCidr(raw);
      claim(owners, 'ip:' + value, value, manual); cidrs.add(value);
    }
    for (const id of rules.groupIds) {
      const group = byId.get(id);
      if (!group) { throw new Error('「' + target.Name + '」引用的地址组不存在，请先移除该组规则。'); }
      if (group.domains.length + group.cidrs.length === 0) {
        throw new Error('地址组「' + group.name + '」没有可用规则，请先添加域名或 IP 段，再分配给连接。');
      }
      const owner = new RuleOwner(target.key(), target.Name, '地址组「' + group.name + '」');
      for (const raw of group.domains) {
        const value = raw.trim().toLowerCase().replace(/\.$/, '');
        claim(owners, 'domain:' + value, value, owner); domains.add(value);
      }
      for (const raw of group.cidrs) {
        const value = normalizeAddressGroupCidr(raw);
        claim(owners, 'ip:' + value, value, owner); cidrs.add(value);
      }
    }
    if (target.Kind === 'wireguard' && !rules.isDefault) {
      const collected = collectSplitRules(directory, rules.lists);
      for (const value of collected.rules.domains.concat(collected.rules.exacts)) { domains.add(value); }
      if (domains.size > MAX_SPLIT_DOMAINS) {
        throw new Error('「' + target.Name + '」合并地址组与域名库后超过 ' + MAX_SPLIT_DOMAINS + ' 条域名，请减少成员或域名库。');
      }
    }
    if (target.Kind === 'tailnet' && domains.size > 100000) {
      throw new Error('「' + target.Name + '」合并地址组后超过 100000 条域名。');
    }
    const maxCidrs = target.Kind === 'wireguard' ? MAX_SPLIT_ROUTES : 100000;
    if (cidrs.size > maxCidrs) {
      throw new Error('「' + target.Name + '」合并地址组后超过 ' + maxCidrs + ' 条 IP 段。');
    }
  }
}
