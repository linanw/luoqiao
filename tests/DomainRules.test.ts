import {
  dedupeStrings, domainRuleCount, isDomainListName, mergeDomainRules, parseDomainList, sanitizeListName
} from '../entry/src/main/ets/model/DomainRules';
import {
  formatEndpoint, IpPrefix, parseWireGuardConfig, toWireGuardUapi
} from '../entry/src/main/ets/model/WireGuardConfig';

const privateKey = 'AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA=';
const publicKey = 'ISIjJCUmJygpKissLS4vMDEyMzQ1Njc4OTo7PD0+P0A=';

function equal(actual: unknown, expected: unknown): void {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(`Expected ${JSON.stringify(expected)}, received ${JSON.stringify(actual)}`);
  }
}

const sample = `# comment line
google.com
domain:example.org @cn
full:www.example.net
keyword:search
regexp:.*\\.foo\\.com
include:other-list
geolocation-!cn @ads
invalid..name

double.com
double.com
`;

const rules = parseDomainList(sample);
equal(rules.domains, ['google.com', 'example.org', 'double.com']);
equal(rules.exacts, ['www.example.net']);
equal(rules.includes, ['other-list']);
equal(rules.skipped, 4);
equal(domainRuleCount(rules), 4);

const merged = parseDomainList('domain:google.com\nfull:www.example.net\ndomain:new.site');
mergeDomainRules(rules, merged);
equal(rules.domains, ['google.com', 'example.org', 'double.com', 'new.site']);
equal(rules.exacts, ['www.example.net']);

equal(dedupeStrings(['a', 'b', 'a', '']), ['a', 'b', '']);
equal(isDomainListName('google'), true);
equal(isDomainListName('category-ads-all'), true);
equal(isDomainListName('geolocation-!cn'), true);
equal(isDomainListName('../escape'), false);
equal(isDomainListName(''), false);
equal(isDomainListName('UPPER'), false);
equal(sanitizeListName('geolocation-!cn'), 'geolocation-!cn');

const base = `[Interface]
PrivateKey = ${privateKey}
Address = 10.13.0.2/24

[Peer]
PublicKey = ${publicKey}
Endpoint = VPN.Example.net:51820
AllowedIPs = 10.9.0.0/20
`;

const config = parseWireGuardConfig(base);
const extras: IpPrefix[] = [
  { address: '93.184.216.34', prefixLength: 32, family: 4 },
  { address: '2606:2800:220:1:248:1893:25c8:1946', prefixLength: 128, family: 6 },
];
const uapiLines = toWireGuardUapi(config, [formatEndpoint('203.0.113.7', 51820)], extras).trim().split('\n');
equal(uapiLines.includes('allowed_ip=10.9.0.0/20'), true);
equal(uapiLines.includes('allowed_ip=93.184.216.34/32'), true);
equal(uapiLines.includes('allowed_ip=2606:2800:220:1:248:1893:25c8:1946/128'), true);
const withoutExtras = toWireGuardUapi(config, [formatEndpoint('203.0.113.7', 51820)]).trim().split('\n');
equal(withoutExtras.includes('allowed_ip=93.184.216.34/32'), false);
