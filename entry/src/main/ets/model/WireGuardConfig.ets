export interface IpPrefix {
  address: string;
  prefixLength: number;
  family: number;
}

export interface Endpoint {
  host: string;
  port: number;
  family: number;
}

export interface WireGuardPeer {
  publicKey: string;
  presharedKey?: string;
  endpoint?: Endpoint;
  allowedIps: IpPrefix[];
  persistentKeepalive?: number;
}

export interface WireGuardConfig {
  privateKey: string;
  addresses: IpPrefix[];
  dns: string[];
  searchDomains: string[];
  mtu: number;
  listenPort: number;
  peers: WireGuardPeer[];
}

interface ParsedIp {
  family: number;
  parts: number[];
}

const BASE64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
const ZERO_KEY = '0000000000000000000000000000000000000000000000000000000000000000';
const DECIMAL = new RegExp('^[0-9]+$');
const BASE64_KEY = new RegExp('^[A-Za-z0-9+/]{43}=$');
const IPV4_OCTET = new RegExp('^(0|[1-9][0-9]{0,2})$');
const IPV6_GROUP = new RegExp('^[0-9a-fA-F]{1,4}$');
const NUMERIC_HOST = new RegExp('^[0-9.]+$');
const HOST_LABEL = new RegExp('^[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$');

function configError(line: number, message: string): Error {
  return new Error(line > 0 ? `第 ${line} 行：${message}` : message);
}

function readInteger(value: string, min: number, max: number, line: number, name: string): number {
  const numberValue = Number(value);
  if (!DECIMAL.test(value) || numberValue < min || numberValue > max) {
    throw configError(line, `${name} 必须是 ${min} 到 ${max} 之间的整数`);
  }
  return numberValue;
}

function hexByte(value: number): string {
  return value.toString(16).padStart(2, '0');
}

function readKey(value: string, line: number, name: string): string {
  if (!BASE64_KEY.test(value) || (BASE64.indexOf(value[42]) & 3) !== 0) {
    throw configError(line, `${name} 必须是 Base64 编码的 32 字节密钥`);
  }

  let key = '';
  for (let index = 0; index < 43; index += 4) {
    const first = BASE64.indexOf(value[index]);
    const second = BASE64.indexOf(value[index + 1]);
    const third = BASE64.indexOf(value[index + 2]);
    key += hexByte((first << 2) | (second >> 4));
    key += hexByte(((second & 15) << 4) | (third >> 2));
    if (index + 3 < 43) {
      key += hexByte(((third & 3) << 6) | BASE64.indexOf(value[index + 3]));
    }
  }
  if (key === ZERO_KEY && name !== 'PresharedKey') {
    throw configError(line, `${name} 不能为全零密钥`);
  }
  return key;
}

function parseIpv4(value: string): number[] | undefined {
  const octets = value.split('.');
  if (octets.length !== 4) {
    return undefined;
  }
  const parts: number[] = [];
  for (const octet of octets) {
    if (!IPV4_OCTET.test(octet) || Number(octet) > 255) {
      return undefined;
    }
    parts.push(Number(octet));
  }
  return parts;
}

function parseHexGroups(value: string): number[] | undefined {
  const parts: number[] = [];
  if (value.length === 0) {
    return parts;
  }
  for (const group of value.split(':')) {
    if (!IPV6_GROUP.test(group)) {
      return undefined;
    }
    parts.push(parseInt(group, 16));
  }
  return parts;
}

function parseIpv6(value: string): number[] | undefined {
  const lastColon = value.lastIndexOf(':');
  if (lastColon < 0) {
    return undefined;
  }
  let expanded = value;
  if (value.includes('.')) {
    const tail = parseIpv4(value.slice(lastColon + 1));
    if (tail === undefined) {
      return undefined;
    }
    const high = ((tail[0] << 8) | tail[1]).toString(16);
    const low = ((tail[2] << 8) | tail[3]).toString(16);
    expanded = `${value.slice(0, lastColon + 1)}${high}:${low}`;
  }

  const halves = expanded.split('::');
  const left = parseHexGroups(halves[0]);
  if (left === undefined || halves.length > 2) {
    return undefined;
  }
  if (halves.length === 1) {
    return left.length === 8 ? left : undefined;
  }
  const right = parseHexGroups(halves[1]);
  if (right === undefined || left.length + right.length >= 8) {
    return undefined;
  }
  for (let index = left.length + right.length; index < 8; index++) {
    left.push(0);
  }
  return left.concat(right);
}

function parseIp(value: string): ParsedIp | undefined {
  const family = value.includes(':') ? 6 : 4;
  const parts = family === 6 ? parseIpv6(value) : parseIpv4(value);
  if (parts === undefined) {
    return undefined;
  }
  const ip: ParsedIp = { family: family, parts: parts };
  return ip;
}

export function ipFamily(value: string): number {
  return parseIp(value)?.family ?? 0;
}

function formatIp(ip: ParsedIp): string {
  if (ip.family === 4) {
    return ip.parts.join('.');
  }
  const groups: string[] = [];
  let longestStart = 0;
  let longestLength = 0;
  let zeroLength = 0;
  for (let index = 0; index < ip.parts.length; index++) {
    const group = ip.parts[index];
    groups.push(group.toString(16));
    zeroLength = group === 0 ? zeroLength + 1 : 0;
    if (zeroLength > longestLength) {
      longestStart = index - zeroLength + 1;
      longestLength = zeroLength;
    }
  }
  if (longestLength < 2) {
    return groups.join(':');
  }
  const before = groups.slice(0, longestStart).join(':');
  const after = groups.slice(longestStart + longestLength).join(':');
  return `${before}::${after}`;
}

function readPrefix(value: string, line: number, name: string, maskHostBits: boolean): IpPrefix {
  const fields = value.split('/');
  const ip = parseIp(fields[0]);
  if (ip === undefined || fields.length > 2) {
    throw configError(line, `${name} 必须是 IPv4 或 IPv6 地址，可带 CIDR 前缀长度`);
  }
  const partBits = ip.family === 4 ? 8 : 16;
  const maxBits = ip.parts.length * partBits;
  const prefixLength = fields.length === 1 ? maxBits : readInteger(fields[1], 0, maxBits, line, name);
  if (maskHostBits) {
    for (let index = 0; index < ip.parts.length; index++) {
      const hostBits = Math.min(partBits, Math.max(0, (index + 1) * partBits - prefixLength));
      ip.parts[index] = (ip.parts[index] >> hostBits) << hostBits;
    }
  }
  return { address: formatIp(ip), prefixLength: prefixLength, family: ip.family };
}

function isHostname(value: string): boolean {
  const host = value.endsWith('.') ? value.slice(0, -1) : value;
  if (host.length === 0 || host.length > 253 || NUMERIC_HOST.test(host)) {
    return false;
  }
  for (const label of host.split('.')) {
    if (!HOST_LABEL.test(label)) {
      return false;
    }
  }
  return true;
}

export function formatEndpoint(host: string, port: number): string {
  return host.includes(':') ? `[${host}]:${port}` : `${host}:${port}`;
}

function readEndpoint(value: string, line: number): Endpoint {
  const separator = value.lastIndexOf(':');
  if (separator < 1) {
    throw configError(line, 'Endpoint 必须包含主机和端口');
  }
  const host = value.slice(0, separator);
  const port = readInteger(value.slice(separator + 1), 1, 65535, line, 'Endpoint 端口');
  if (host.startsWith('[') && host.endsWith(']')) {
    const ip = parseIp(host.slice(1, -1));
    if (ip?.family === 6) {
      return { host: formatIp(ip), port: port, family: 6 };
    }
  } else {
    const ipv4 = parseIpv4(host);
    if (ipv4 !== undefined) {
      return { host: ipv4.join('.'), port: port, family: 4 };
    }
    if (isHostname(host)) {
      return { host: host.toLowerCase(), port: port, family: 0 };
    }
  }
  throw configError(line, 'Endpoint 必须使用域名、IPv4 地址或方括号包裹的 IPv6 地址');
}

function readList(value: string): string[] {
  return value.split(',').map((item: string): string => item.trim());
}

function addPrefixes(output: IpPrefix[], value: string, line: number, name: string, maskHostBits: boolean): void {
  for (const item of readList(value)) {
    output.push(readPrefix(item, line, name, maskHostBits));
  }
}

function addDns(config: WireGuardConfig, value: string, line: number): void {
  for (const item of readList(value)) {
    const ip = parseIp(item);
    if (ip !== undefined) {
      config.dns.push(formatIp(ip));
    } else if (isHostname(item)) {
      config.searchDomains.push(item.toLowerCase());
    } else {
      throw configError(line, 'DNS 必须是 IPv4、IPv6 地址或搜索域名');
    }
  }
}

function applyInterface(config: WireGuardConfig, key: string, value: string, line: number): void {
  switch (key) {
    case 'privatekey':
      config.privateKey = readKey(value, line, 'PrivateKey');
      break;
    case 'address':
      addPrefixes(config.addresses, value, line, 'Address', false);
      break;
    case 'dns':
      addDns(config, value, line);
      break;
    case 'mtu':
      config.mtu = readInteger(value, 576, 1500, line, 'MTU');
      break;
    case 'listenport':
      config.listenPort = readInteger(value, 0, 65535, line, 'ListenPort');
      break;
    case 'table':
      if (value.toLowerCase() !== 'auto') {
        throw configError(line, 'Table 只支持 auto');
      }
      break;
    default:
      throw configError(line, '存在不支持的 [Interface] 字段');
  }
}

function applyPeer(peer: WireGuardPeer, key: string, value: string, line: number): void {
  switch (key) {
    case 'publickey':
      peer.publicKey = readKey(value, line, 'PublicKey');
      break;
    case 'presharedkey':
      peer.presharedKey = readKey(value, line, 'PresharedKey');
      break;
    case 'endpoint':
      peer.endpoint = readEndpoint(value, line);
      break;
    case 'allowedips':
      if (value.length > 0) {
        addPrefixes(peer.allowedIps, value, line, 'AllowedIPs', true);
      }
      break;
    case 'persistentkeepalive':
      peer.persistentKeepalive = value.toLowerCase() === 'off' ?
        0 : readInteger(value, 0, 65535, line, 'PersistentKeepalive');
      break;
    default:
      throw configError(line, '存在不支持的 [Peer] 字段');
  }
}

function validateConfig(config: WireGuardConfig): void {
  if (config.privateKey.length === 0 || config.addresses.length === 0) {
    throw configError(0, '[Interface] 需要 PrivateKey 和 Address');
  }
  if (config.addresses.length > 2000) {
    throw configError(0, 'Address 不能超过 2000 项');
  }
  if (config.dns.length > 64) {
    throw configError(0, 'DNS 服务器地址不能超过 64 个');
  }
  if (config.peers.length === 0) {
    throw configError(0, '配置需要至少一个 [Peer]');
  }
  const families = new Set<number>();
  for (const address of config.addresses) {
    families.add(address.family);
  }
  if (families.has(6) && config.mtu < 1280) {
    throw configError(0, '配置 IPv6 隧道地址时，MTU 不能低于 1280');
  }
  const publicKeys = new Set<string>();
  const routes = new Set<string>();
  for (const peer of config.peers) {
    if (peer.publicKey.length === 0) {
      throw configError(0, '每个 [Peer] 都需要 PublicKey');
    }
    if (publicKeys.has(peer.publicKey)) {
      throw configError(0, '多个 [Peer] 使用了相同的 PublicKey');
    }
    publicKeys.add(peer.publicKey);
    for (const prefix of peer.allowedIps) {
      if (!families.has(prefix.family)) {
        throw configError(0, `AllowedIPs 包含 IPv${prefix.family} 路由，Address 需要同协议的隧道地址`);
      }
      routes.add(`${prefix.address}/${prefix.prefixLength}`);
    }
  }
  if (routes.size === 0) {
    throw configError(0, '至少一个 [Peer] 需要设置 AllowedIPs');
  }
  if (routes.size > 10000) {
    throw configError(0, 'AllowedIPs 产生的不同路由不能超过 10000 条');
  }
}

export function parseWireGuardConfig(text: string): WireGuardConfig {
  const config: WireGuardConfig = {
    privateKey: '',
    addresses: [],
    dns: [],
    searchDomains: [],
    mtu: 1420,
    listenPort: 0,
    peers: []
  };
  const lines = text.split('\n');
  const seenFields = new Set<string>();
  let interfaceSeen = false;
  let peer: WireGuardPeer | undefined;
  for (let index = 0; index < lines.length; index++) {
    const line = lines[index].split('#', 1)[0].trim();
    const lineNumber = index + 1;
    if (line.length === 0) {
      continue;
    }
    const lower = line.toLowerCase();
    if (lower === '[interface]') {
      if (interfaceSeen) {
        throw configError(lineNumber, '[Interface] 只能出现一次');
      }
      interfaceSeen = true;
      continue;
    }
    if (!interfaceSeen) {
      throw configError(lineNumber, '配置必须以 [Interface] 开始');
    }
    if (lower === '[peer]') {
      const newPeer: WireGuardPeer = { publicKey: '', allowedIps: [] };
      config.peers.push(newPeer);
      peer = newPeer;
      seenFields.clear();
      continue;
    }
    const separator = line.indexOf('=');
    if (separator < 1) {
      throw configError(lineNumber, '应填写 [Peer] 或使用“字段 = 值”格式');
    }
    const key = line.slice(0, separator).trim().toLowerCase();
    const value = line.slice(separator + 1).trim();
    if (seenFields.has(key) && key !== 'address' && key !== 'dns' && key !== 'allowedips') {
      throw configError(lineNumber, '配置字段重复');
    }
    seenFields.add(key);
    if (peer === undefined) {
      applyInterface(config, key, value, lineNumber);
    } else {
      applyPeer(peer, key, value, lineNumber);
    }
  }

  validateConfig(config);
  return config;
}

export function parseIpPrefix(value: string): IpPrefix | undefined {
  try {
    return readPrefix(value.trim(), 0, 'IP 段', true);
  } catch (_) {
    return undefined;
  }
}

export function toWireGuardUapi(config: WireGuardConfig, endpoints: (string | undefined)[],
  extraAllowedIps?: IpPrefix[]): string {
  if (endpoints.length !== config.peers.length) {
    throw configError(0, '端点列表与 [Peer] 数量不符');
  }
  let targetPeer = 0;
  for (let index = 0; index < config.peers.length; index++) {
    if (config.peers[index].allowedIps.some((prefix: IpPrefix): boolean => prefix.prefixLength === 0)) {
      targetPeer = index;
      break;
    }
  }
  const lines = [`private_key=${config.privateKey}`, 'replace_peers=true'];
  for (let index = 0; index < config.peers.length; index++) {
    const peer = config.peers[index];
    lines.push(`public_key=${peer.publicKey}`);
    if (peer.presharedKey !== undefined) {
      lines.push(`preshared_key=${peer.presharedKey}`);
    }
    const resolved = endpoints[index];
    if (peer.endpoint !== undefined) {
      if (resolved === undefined) {
        throw configError(0, `第 ${index + 1} 个 [Peer] 缺少解析后的端点地址`);
      }
      const endpoint = readEndpoint(resolved, 0);
      if (endpoint.family === 0 || endpoint.port !== peer.endpoint.port) {
        throw configError(0, `第 ${index + 1} 个 [Peer] 的解析结果无效`);
      }
      lines.push(`endpoint=${formatEndpoint(endpoint.host, endpoint.port)}`);
    }
    if (peer.persistentKeepalive !== undefined) {
      lines.push(`persistent_keepalive_interval=${peer.persistentKeepalive}`);
    }
    lines.push('replace_allowed_ips=true');
    for (const prefix of peer.allowedIps) {
      lines.push(`allowed_ip=${prefix.address}/${prefix.prefixLength}`);
    }
    if (index === targetPeer && extraAllowedIps !== undefined) {
      for (const prefix of extraAllowedIps) {
        lines.push(`allowed_ip=${prefix.address}/${prefix.prefixLength}`);
      }
    }
  }
  return lines.join('\n') + '\n';
}

export function toRuleTunnelUapi(config: WireGuardConfig, endpoints: (string | undefined)[],
  claimed: IpPrefix[]): string {
  if (claimed.length === 0) {
    throw configError(0, '分流配置没有可认领的路由');
  }
  let targetPeer = 0;
  for (let index = 0; index < config.peers.length; index++) {
    if (config.peers[index].allowedIps.some((prefix: IpPrefix): boolean => prefix.prefixLength === 0)) {
      targetPeer = index;
      break;
    }
  }
  const peers: WireGuardPeer[] = config.peers.map((peer: WireGuardPeer, index: number): WireGuardPeer => {
    const adapted: WireGuardPeer = {
      publicKey: peer.publicKey,
      allowedIps: index === targetPeer ? claimed : [],
    };
    if (peer.presharedKey !== undefined) {
      adapted.presharedKey = peer.presharedKey;
    }
    if (peer.endpoint !== undefined) {
      adapted.endpoint = peer.endpoint;
    }
    if (peer.persistentKeepalive !== undefined) {
      adapted.persistentKeepalive = peer.persistentKeepalive;
    }
    return adapted;
  });
  const adaptedConfig: WireGuardConfig = {
    privateKey: config.privateKey,
    addresses: config.addresses,
    dns: config.dns,
    searchDomains: config.searchDomains,
    mtu: config.mtu,
    listenPort: config.listenPort,
    peers: peers,
  };
  return toWireGuardUapi(adaptedConfig, endpoints);
}
