import {
  formatEndpoint, ipFamily, parseIpPrefix, parseWireGuardConfig, toRuleTunnelUapi, toWireGuardUapi
} from '../entry/src/main/ets/model/WireGuardConfig';

const privateKey = 'AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA=';
const publicKey = 'ISIjJCUmJygpKissLS4vMDEyMzQ1Njc4OTo7PD0+P0A=';
const presharedKey = 'QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVpbXF1eX2A=';

const base = `[Interface]
PrivateKey = ${privateKey}
Address = 10.13.0.2/24, fd00::2/64
DNS = 10.13.0.1, 2001:db8::53, lan.example
ListenPort = 55120
Table = auto

[Peer]
PublicKey = ${publicKey}
PresharedKey = ${presharedKey}
Endpoint = VPN.Example.net:51820
AllowedIPs = 10.9.7.8/20, 2001:db8:12ab:ffff::1/52
AllowedIPs = 10.1.0.3
PersistentKeepalive = 25
`;

function equal(actual: unknown, expected: unknown): void {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(`Expected ${JSON.stringify(expected)}, received ${JSON.stringify(actual)}`);
  }
}

function rejects(run: () => void, expected: RegExp): void {
  try {
    run();
  } catch (error) {
    if (error instanceof Error && expected.test(error.message) && !error.message.includes(privateKey)) {
      return;
    }
    throw error;
  }
  throw new Error(`Expected error matching ${expected}`);
}

const config = parseWireGuardConfig(base);
equal(config.addresses, [
  { address: '10.13.0.2', prefixLength: 24, family: 4 },
  { address: 'fd00::2', prefixLength: 64, family: 6 }
]);
equal(config.dns, ['10.13.0.1', '2001:db8::53']);
equal(config.searchDomains, ['lan.example']);
equal(config.mtu, 1420);
equal(config.listenPort, 55120);
equal(config.peers[0].endpoint, { host: 'vpn.example.net', port: 51820, family: 0 });
equal(config.peers[0].allowedIps, [
  { address: '10.9.0.0', prefixLength: 20, family: 4 },
  { address: '2001:db8:12ab:f000::', prefixLength: 52, family: 6 },
  { address: '10.1.0.3', prefixLength: 32, family: 4 }
]);
equal(toWireGuardUapi(config, [formatEndpoint('2001:db8::10', 51820)]), [
  'private_key=0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20',
  'replace_peers=true',
  'public_key=2122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f40',
  'preshared_key=4142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f60',
  'endpoint=[2001:db8::10]:51820',
  'persistent_keepalive_interval=25',
  'replace_allowed_ips=true',
  'allowed_ip=10.9.0.0/20',
  'allowed_ip=2001:db8:12ab:f000::/52',
  'allowed_ip=10.1.0.3/32',
  ''
].join('\n'));

const multiple = parseWireGuardConfig('\uFEFF' + (base + `
[Peer]
PublicKey = ${presharedKey}
AllowedIPs = 255.255.255.255/0, ffff::1234/0 # Both default routes
PersistentKeepalive = off
`).replace(/\n/g, '\r\n'));
equal(multiple.peers.length, 2);
equal(multiple.peers[1].endpoint, undefined);
equal(multiple.peers[1].persistentKeepalive, 0);
equal(multiple.peers[1].allowedIps, [
  { address: '0.0.0.0', prefixLength: 0, family: 4 },
  { address: '::', prefixLength: 0, family: 6 }
]);
equal(toWireGuardUapi(multiple, ['192.0.2.1:51820', undefined]).includes('endpoint=192.0.2.1:51820'), true);
equal(parseWireGuardConfig(base.replace('VPN.Example.net', '[2001:0db8:0:0::b]')).peers[0].endpoint,
  { host: '2001:db8::b', port: 51820, family: 6 });

for (const address of ['::', '2001:db8::1', '::ffff:192.0.2.1', '1:2:3:4:5:6:7:8']) {
  equal(ipFamily(address), 6);
}
equal(ipFamily('192.0.2.1'), 4);
for (const invalid of ['1::2::3', '1:2:3:4:5:6:7:8::', '192.0.2.01', '192.0.2.256']) {
  equal(ipFamily(invalid), 0);
}

rejects(() => parseWireGuardConfig(base.replace('Table = auto', 'PostUp = echo hello')), /第 6 行/);
rejects(() => parseWireGuardConfig(base.replace('Table = auto', 'Table = off')), /Table/);
rejects(() => parseWireGuardConfig(base.replace(privateKey, privateKey.replace('A=', 'B='))), /PrivateKey/);
rejects(() => parseWireGuardConfig(base.replace('10.13.0.2/24', '10.13.0.2/33')), /Address/);
rejects(() => parseWireGuardConfig(base.replace('VPN.Example.net', '2001:db8::1')), /Endpoint/);
rejects(() => parseWireGuardConfig(base.replace('VPN.Example.net', '999.0.0.1')), /Endpoint/);
rejects(() => parseWireGuardConfig(base.replace('55120', '65536')), /ListenPort/);
rejects(() => parseWireGuardConfig(base.replace('Table = auto', 'MTU = 1501')), /MTU/);
rejects(() => parseWireGuardConfig(base.replace('Table = auto', 'MTU = 1279')), /IPv6.*MTU/);
rejects(() => parseWireGuardConfig(base + `[Peer]\nPublicKey = ${publicKey}\n`), /PublicKey/);
rejects(() => parseWireGuardConfig(base.replace(', fd00::2/64', '').replace('2001:db8:12ab:ffff::1/52', '::/0')),
  /AllowedIPs.*IPv6.*Address/);
const tooManyAddresses = Array<string>(2001).fill('10.13.0.2/24').join(',');
rejects(() => parseWireGuardConfig(base.replace('10.13.0.2/24, fd00::2/64', tooManyAddresses)), /Address.*2000/);
const tooManyRoutes = Array.from({ length: 10001 }, (_, index) =>
  `10.0.${Math.floor(index / 256)}.${index % 256}/32`).join(',');
rejects(() => parseWireGuardConfig(base + `AllowedIPs = ${tooManyRoutes}\n`), /AllowedIPs.*10000/);
rejects(() => toWireGuardUapi(config, ['vpn.example.net:51820']), /解析结果/);
rejects(() => toWireGuardUapi(config, ['192.0.2.1:12345']), /解析结果/);

equal(parseIpPrefix('10.1.2.3/24'), { address: '10.1.2.0', prefixLength: 24, family: 4 });
equal(parseIpPrefix('192.0.2.1'), { address: '192.0.2.1', prefixLength: 32, family: 4 });
equal(parseIpPrefix('2001:db8:0:0:0:0:0:1/64'), { address: '2001:db8::', prefixLength: 64, family: 6 });
equal(parseIpPrefix(' 10.9.7.65/20 '), { address: '10.9.0.0', prefixLength: 20, family: 4 });
equal(parseIpPrefix('10.0.0.0/33'), undefined);
equal(parseIpPrefix('example.com/24'), undefined);
equal(parseIpPrefix(''), undefined);

const ruleConfig = parseWireGuardConfig(`[Interface]
PrivateKey = ${privateKey}
Address = 10.5.0.2/24

[Peer]
PublicKey = ${publicKey}
Endpoint = 192.0.2.9:51820
AllowedIPs = 0.0.0.0/0
`);
const claimed = [
  { address: '203.0.113.7', prefixLength: 32, family: 4 },
  { address: '198.51.100.0', prefixLength: 24, family: 4 }
];
equal(toRuleTunnelUapi(ruleConfig, ['192.0.2.9:51820'], claimed), [
  'private_key=0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20',
  'replace_peers=true',
  'public_key=2122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f40',
  'endpoint=192.0.2.9:51820',
  'replace_allowed_ips=true',
  'allowed_ip=203.0.113.7/32',
  'allowed_ip=198.51.100.0/24',
  ''
].join('\n'));
rejects(() => toRuleTunnelUapi(ruleConfig, ['192.0.2.9:51820'], []), /认领/);

const twoPeerRule = parseWireGuardConfig(`[Interface]
PrivateKey = ${privateKey}
Address = 10.5.0.2/24

[Peer]
PublicKey = ${publicKey}
AllowedIPs = 10.5.0.0/24

[Peer]
PublicKey = ${presharedKey}
Endpoint = 192.0.2.9:51820
AllowedIPs = 0.0.0.0/0
`);
const targeted = toRuleTunnelUapi(twoPeerRule, [undefined, '192.0.2.9:51820'], claimed);
equal(targeted.includes('public_key=2122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f40\n' +
  'replace_allowed_ips=true\n' +
  'public_key=4142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f60\n' +
  'endpoint=192.0.2.9:51820\n' +
  'replace_allowed_ips=true\n' +
  'allowed_ip=203.0.113.7/32\n' +
  'allowed_ip=198.51.100.0/24'), true);
