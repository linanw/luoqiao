export interface DomainRules {
  domains: string[];
  exacts: string[];
  includes: string[];
  skipped: number;
}

const LABEL = new RegExp('^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$');
const LIST_NAME = new RegExp('^[a-z0-9][a-z0-9_.@!-]{0,99}$');

function isDomainEntry(value: string): boolean {
  if (value.length === 0 || value.length > 253 || !value.includes('.')) {
    return false;
  }
  for (const label of value.split('.')) {
    if (!LABEL.test(label)) {
      return false;
    }
  }
  return true;
}

export function isDomainListName(name: string): boolean {
  return LIST_NAME.test(name);
}

export function isDomainName(value: string): boolean {
  return isDomainEntry(value.trim().toLowerCase());
}

export function sanitizeListName(name: string): string {
  if (!isDomainListName(name)) { throw new Error('无效列表名称'); }
  return name;
}

export function dedupeStrings(items: string[]): string[] {
  const seen = new Set<string>();
  const output: string[] = [];
  for (const item of items) {
    if (!seen.has(item)) {
      seen.add(item);
      output.push(item);
    }
  }
  return output;
}

function pushUnique(target: string[], value: string, valid: boolean, rules: DomainRules): void {
  if (!valid) {
    rules.skipped++;
    return;
  }
  if (!target.includes(value)) {
    target.push(value);
  }
}

export function parseDomainList(content: string): DomainRules {
  const rules: DomainRules = { domains: [], exacts: [], includes: [], skipped: 0 };
  for (const rawLine of content.split('\n')) {
    const line = rawLine.trim();
    if (line.length === 0 || line.startsWith('#')) {
      continue;
    }
    const token = line.split(/\s+/)[0].toLowerCase();
    if (token.startsWith('include:')) {
      const name = token.slice('include:'.length);
      pushUnique(rules.includes, name, isDomainListName(name), rules);
      continue;
    }
    if (token.startsWith('domain:')) {
      const value = token.slice('domain:'.length);
      pushUnique(rules.domains, value, isDomainEntry(value), rules);
      continue;
    }
    if (token.startsWith('full:')) {
      const value = token.slice('full:'.length);
      pushUnique(rules.exacts, value, isDomainEntry(value), rules);
      continue;
    }
    if (token.startsWith('keyword:') || token.startsWith('regexp:') || token.startsWith('regex:')) {
      rules.skipped++;
      continue;
    }
    pushUnique(rules.domains, token, isDomainEntry(token), rules);
  }
  return rules;
}

export function mergeDomainRules(target: DomainRules, source: DomainRules): void {
  for (const domain of source.domains) {
    if (!target.domains.includes(domain)) {
      target.domains.push(domain);
    }
  }
  for (const exact of source.exacts) {
    if (!target.exacts.includes(exact)) {
      target.exacts.push(exact);
    }
  }
  for (const include of source.includes) {
    if (!target.includes.includes(include)) {
      target.includes.push(include);
    }
  }
  target.skipped += source.skipped;
}

export function domainRuleCount(rules: DomainRules): number {
  return dedupeStrings(rules.domains.concat(rules.exacts)).length;
}
