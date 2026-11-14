import { Want, AbilityConstant, Configuration, EnvironmentCallback } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { connection, vpnExtension, VpnExtensionAbility } from '@kit.NetworkKit';
import wireguard from 'libwireguard.so';
import { isValidProfileId, listProfiles, loadProfileText, ProfileMeta, MAX_PROFILES } from '../model/ProfileStore';
import {
  Endpoint, formatEndpoint, IpPrefix, ipFamily, parseIpPrefix, parseWireGuardConfig,
  toWireGuardUapi, WireGuardConfig,
} from '../model/WireGuardConfig';
import { MixedNodeStatus, readTunnelRequest, TunnelPhase, TunnelState, writeTunnelState,
  respondTunnelHeartbeat } from '../model/TunnelState';
import { VpnDiagnostics } from '../model/VpnDiagnostics';
import { NetworkConfig, NetworkNodeStatus } from '../model/NetworkProfiles';
import { MAX_MIXED_TAILNETS } from '../model/MixedConnections';
import { ProfileRules } from '../model/SplitTunnel';
import { dedupeStrings } from '../model/DomainRules';
import { SubnetPreference, normalizeSubnetCIDR } from '../model/SubnetPreferences';

import { SessionRulesSnapshot, readOrCreateSessionRules, cleanupSessionRules } from '../model/SessionRules';
import { RouteDecision, readRouteCheckRequest, parseRouteCheckResult, writeRouteCheckResponse } from '../model/RouteChecker';
import { observePureVpnHealth, PureVpnHealthSnapshot } from '../model/PureVpnProvider';

const MAX_SYSTEM_ROUTES: number = 10000;

interface RoutedProfile {
  ID: string;
  Addresses: string[];
  DNS: string[];
  Domains: string[];
  Exacts: string[];
  CIDRs: string[];
  Default: boolean;
  RoutesFallback: boolean;
}
interface RoutedConfig { DNS: string[]; Profiles: RoutedProfile[]; Tailnets?: NetworkConfig;
  SubnetPreferences: SubnetPreference[]; LocalPrefixes: string[]; }
interface PhysicalRoutingSnapshot { DNS: string[]; LocalPrefixes: string[]; }
interface TransportPeer { publicKey: string; endpoint?: Endpoint; }
interface TransportProfile { peers: TransportPeer[]; }
interface RouteDiagnostic {
  mode: string;
  profiles: RouteProfileDiagnostic[];
}
interface RouteProfileDiagnostic {
  id: string;
  families: number[];
  domains: number;
  exacts: number;
  cidrs: number;
}

class ProfilePlan {
  id: string;
  name: string;
  config: WireGuardConfig;
  rules: ProfileRules;
  endpoints: (string | undefined)[] = [];
  udpFd: number = -1;
  uapi: string = '';
  claimed: IpPrefix[] = [];

  constructor(id: string, name: string, config: WireGuardConfig, rules: ProfileRules) {
    this.id = id;
    this.name = name;
    this.config = config;
    this.rules = rules;
  }
}

function linkAddress(prefix: IpPrefix): connection.LinkAddress {
  return {
    address: { address: prefix.address, family: prefix.family === 6 ? 2 : 1 },
    prefixLength: prefix.prefixLength,
  };
}

function hostRoute(prefix: IpPrefix): connection.RouteInfo {
  return {
    interface: '',
    destination: linkAddress(prefix),
    gateway: { address: prefix.family === 6 ? '::' : '0.0.0.0', family: prefix.family === 6 ? 2 : 1 },
    hasGateway: false,
    isDefaultRoute: prefix.prefixLength === 0,
  };
}

function dedupePrefixes(prefixes: IpPrefix[]): IpPrefix[] {
  const seen = new Set<string>();
  const output: IpPrefix[] = [];
  for (const prefix of prefixes) {
    const key = `${prefix.family}|${prefix.address}|${prefix.prefixLength}`;
    if (!seen.has(key)) {
      seen.add(key);
      output.push(prefix);
    }
  }
  return output;
}

async function resolveEndpoint(endpoint: Endpoint): Promise<string> {
  if (endpoint.family !== 0) {
    return formatEndpoint(endpoint.host, endpoint.port);
  }
  const answers = await connection.getAddressesByName(endpoint.host);
  for (const answer of answers) {
    if (ipFamily(answer.address) !== 0) {
      return formatEndpoint(answer.address, endpoint.port);
    }
  }
  throw new Error('服务端域名没有可用的 IP 地址。');
}

export default class WireGuardVpnAbility extends VpnExtensionAbility {
  private retryTimer: number = -1;
  private retries: number = 0;
  private recovering: boolean = false;
  private session: string = '';
  private directory: string = '';
  private profileIds: string[] = [];
  private mixed: boolean = false;
  private tailnetIds: string[] = [];
  private tailnetConfig: NetworkConfig | undefined;
  private useConfigRoutes: boolean = false;
  private vpn: vpnExtension.VpnConnection | undefined;
  private tunFd: number = -1;
  private udpFds: number[] = [];
  private handle: number = -1;
  private timer: number = -1;
  private created: boolean = false;
  private starting: boolean = true;
  private stopped: boolean = false;
  private failed: boolean = false;
  private dynamicRouting: boolean = false;
  private physicalDNSKey: string = '';
  private physicalNetworkId: number = -1;
  private lastNetworkCheck: number = 0;
  private checkingNetworkEpoch: number = -1;
  private transportProfiles: TransportProfile[] = [];
  private physicalLinkKey: string = '';
  private localPrefixes: string[] = [];
  private subnetPreferences: SubnetPreference[] | undefined;
  private networkObserver: connection.NetConnection | undefined;
  private networkEventTimer: number = -1;
  private networkEventPending: boolean = false;
  private networkChanges: number = 0;
  private lastNetworkChange: number = 0;
  private networkError: string = '';
  private transportEpoch: number = 0;
  private networkRevision: number = 0;
  private ruleSnapshot: SessionRulesSnapshot | undefined;
  private routeCheckBusy: boolean = false;
  private lastRouteCheck: string = '';
  private heartbeatTimer: number = -1;
  private environmentId: number = -1;
  private diagnostics: VpnDiagnostics | undefined;
  private connectedSince: number = 0;

  onCreate(want: Want): void {
    const session = want.parameters?.['wireguardSession'];
    if (typeof session !== 'string' || !/^[0-9a-f-]{8,64}$/.test(session)) {
      return;
    }
    const rawIds = want.parameters?.['wireguardProfiles'];
    const ids: string[] = [];
    if (rawIds instanceof Array) {
      for (const id of rawIds as string[]) {
        if (typeof id === 'string' && isValidProfileId(id) && !ids.includes(id) && ids.length < MAX_PROFILES) {
          ids.push(id);
        }
      }
    }
    this.session = session;
    this.profileIds = ids;
    this.mixed = want.parameters?.['mixedMode'] === true;
    const rawTailnets = want.parameters?.['mixedTailnets'];
    if (this.mixed && rawTailnets instanceof Array) { this.tailnetIds = (rawTailnets as string[]).slice(); }
    this.useConfigRoutes = !this.mixed && ids.length === 1 && want.parameters?.['wireguardUseConfigRoutes'] === true;
    this.directory = this.context.filesDir;
    if (this.stillCurrent()) {
      if (this.mixed && ((rawIds instanceof Array && rawIds.length !== ids.length) ||
        this.tailnetIds.length > MAX_MIXED_TAILNETS)) {
        this.starting = false;
        this.fail('连接选择无效，最多可同时启用 16 个 WireGuard 和 16 个 Tailnet。');
        return;
      }
      this.diagnostics = new VpnDiagnostics(this.directory, this.session, 'wireguard');
      this.diagnostics.event('created');
      this.watchRuntime();
      this.startTunnel();
    }
  }

  onDestroy(): void {
    this.stopped = true;
    this.diagnostics?.event('destroyed');
    if (this.heartbeatTimer >= 0) { clearInterval(this.heartbeatTimer); this.heartbeatTimer = -1; }
    if (this.environmentId >= 0) {
      this.context.getApplicationContext().off('environment', this.environmentId).catch(() => {});
      this.environmentId = -1;
    }
    if (this.retryTimer >= 0) { clearInterval(this.retryTimer); this.retryTimer = -1; }
    if (!this.starting) {
      this.release().finally(() => this.cleanupRules());
      if (!this.failed) {
        this.publish(new TunnelState(this.session, TunnelPhase.Disconnected));
      }
    }
  }

  private publish(state: TunnelState): void {
    if (this.directory && this.requested()) {
      if (state.phase === TunnelPhase.Connected) {
        if (this.connectedSince === 0 || state.updated < this.connectedSince) { this.connectedSince = state.updated; }
      } else { this.connectedSince = 0; }
      state.connectedSince = this.connectedSince;
      state.profileIds = this.profileIds.slice();
      state.mixed = this.mixed;
      state.useConfigRoutes = this.useConfigRoutes;
      state.tailnetIds = this.tailnetIds.slice();
      state.physicalNetworkId = this.physicalNetworkId;
      state.localPrefixes = this.localPrefixes.slice();
      state.networkChanges = this.networkChanges;
      state.lastNetworkChange = this.lastNetworkChange;
      state.networkError = this.networkError;
      writeTunnelState(this.directory, state);
    }
  }

  private watchRuntime(): void {
    const callback: EnvironmentCallback = {
      onConfigurationUpdated: (_config: Configuration): void => {},
      onMemoryLevel: (level: AbilityConstant.MemoryLevel): void => { this.diagnostics?.memoryPressure(level); }
    };
    try { this.environmentId = this.context.getApplicationContext().on('environment', callback); }
    catch (_) { /* The resource sampler still works if system callbacks are unavailable. */ }
    // This remains independent of startup and transport recovery so a foreground
    // coordinator can distinguish an existing extension from a dead process.
    this.heartbeatTimer = setInterval(() => this.runtimeHeartbeat(), 1000);
    this.runtimeHeartbeat();
  }

  private runtimeHeartbeat(): void {
    if (this.stopped) { return; }
    try { respondTunnelHeartbeat(this.directory, this.session); } catch (_) { /* Never interrupt transport. */ }
    if (this.diagnostics?.beginSample()) {
      try { this.diagnostics.sample(wireguard.resourceUsage()); }
      catch (_) { this.diagnostics.event('sample-unavailable'); }
    }
  }

  private requested(): boolean {
    const request = readTunnelRequest(this.directory);
    return request?.session === this.session && request.phase === TunnelPhase.Starting;
  }

  private stillCurrent(): boolean {
    const request = readTunnelRequest(this.directory);
    return !this.stopped && request?.session === this.session && request.phase === TunnelPhase.Starting &&
      request.resumeOnForeground !== false;
  }

  private async loadPlans(): Promise<ProfilePlan[]> {
    if (this.profileIds.length === 0 && (!this.mixed || this.tailnetIds.length === 0)) {
      throw new Error('没有可参与的隧道配置。');
    }
    const metas: ProfileMeta[] = listProfiles(this.context);
    const plans: ProfilePlan[] = [];
    let defaultCount = 0;
    const publicKeys = new Set<string>();
    const peerIdentities = new Set<string>();
    for (const id of this.profileIds) {
      const text = await loadProfileText(this.context, id);
      if (text.length === 0) {
        throw new Error('配置「' + id + '」不存在或为空。');
      }
      const config = parseWireGuardConfig(text);
      const snapshot = this.ruleSnapshot?.WireGuard.find((item): boolean => item.ID === id);
      if (!snapshot) { throw new Error('当前连接的规则快照缺失，请断开后重新连接。'); }
      const rules = snapshot.Rules;
      if (rules.isDefault) {
        const hasDefaultRoute = config.peers.some((peer): boolean => peer.allowedIps.some((prefix: IpPrefix): boolean => prefix.prefixLength === 0));
        if (!this.mixed || hasDefaultRoute) { defaultCount++; }
        if (defaultCount > 1) {
          throw new Error('存在多个使用默认路由的 WireGuard 连接。请只保留一个默认出口，或为其他连接设置域名 / IP 分流规则。');
        }
      } else if (!rules.enabled || !rules.hasContent()) {
        throw new Error('存在没有分流规则的配置，请先在“分流规则”页面补充。');
      }
      for (const peer of config.peers) {
        if (!this.mixed && publicKeys.has(peer.publicKey)) {
          throw new Error('多份配置使用了相同的对端公钥，请为每份配置使用独立的隧道。');
        }
        const identity = config.privateKey + '|' + peer.publicKey;
        if (this.mixed && peerIdentities.has(identity)) {
          throw new Error('多份 WireGuard 配置使用了相同的客户端和服务端密钥。请使用独立生成的配置，避免连接互相抢占。');
        }
        peerIdentities.add(identity);
        publicKeys.add(peer.publicKey);
      }
      const meta = metas.find((entry: ProfileMeta): boolean => entry.id === id);
      plans.push(new ProfilePlan(id, meta?.name ?? id, config, rules));
    }
    if (plans.length === 0 && this.tailnetIds.length === 0) {
      throw new Error('没有可参与的隧道配置。');
    }
    return plans;
  }

  private dnsPrefixes(plan: ProfilePlan): IpPrefix[] {
    const prefixes: IpPrefix[] = [];
    for (const dnsServer of plan.config.dns) {
      const family = ipFamily(dnsServer);
      if (family === 4 || family === 6) {
        prefixes.push({ address: dnsServer, prefixLength: family === 6 ? 128 : 32, family: family });
      }
    }
    return prefixes;
  }

  private async physicalDNS(): Promise<string[]> {
    const epoch = this.transportEpoch;
    const net = await connection.getDefaultNet();
    const properties = await connection.getConnectionProperties(net);
    const capabilities = await connection.getNetCapabilities(net);
    const prefixes: string[] = [];
    // Cellular address ranges are carrier internals, not a locally attached LAN.
    if (capabilities.bearerTypes.includes(connection.NetBearType.BEARER_WIFI) ||
      capabilities.bearerTypes.includes(connection.NetBearType.BEARER_ETHERNET)) {
      for (const address of properties.linkAddresses ?? []) {
        this.addLocalPrefix(prefixes, address.address.address, address.prefixLength);
      }
      for (const route of properties.routes ?? []) {
        if (!route.hasGateway && !route.isDefaultRoute && !route.isExcludedRoute &&
          (!route.gateway.address || route.gateway.address === '0.0.0.0' || route.gateway.address === '::')) {
          this.addLocalPrefix(prefixes, route.destination.address.address, route.destination.prefixLength);
        }
      }
    }
    const dns = properties.dnses.map((address: connection.NetAddress): string => address.address)
      .filter((address: string): boolean => ipFamily(address) !== 0 && address !== '198.18.0.1' && address !== 'fd7e:746e::1');
    if (dns.length === 0) { throw new Error('当前网络没有可用 DNS，请恢复网络后重试。'); }
    if (this.transportEpoch === epoch) {
      this.physicalNetworkId = net.netId;
      this.localPrefixes = dedupeStrings(prefixes).sort();
      this.physicalLinkKey = net.netId.toString() + '|' + properties.interfaceName + '|' +
        JSON.stringify((properties.linkAddresses ?? []).map((address: connection.LinkAddress): string => address.address.address).sort()) + '|' +
        JSON.stringify((properties.routes ?? []).map((route: connection.RouteInfo): string =>
          route.destination.address.address + '/' + route.destination.prefixLength.toString() + '@' + route.gateway.address).sort()) + '|' +
        JSON.stringify(this.localPrefixes);
    }
    return dns;
  }

  private addLocalPrefix(prefixes: string[], address: string, bits: number): void {
    if (!Number.isInteger(bits) || bits <= 0 || address.startsWith('127.') || address === '::1' ||
      /^fe[89ab]/i.test(address) || address === '0.0.0.0' || address === '::') { return; }
    try { prefixes.push(normalizeSubnetCIDR(address + '/' + bits.toString())); }
    catch (_) { /* Ignore malformed or unsupported system link metadata. */ }
  }

  private scheduleNetworkRefresh(): void {
    if (!this.stillCurrent()) { return; }
    this.networkRevision++;
    this.networkEventPending = true;
    if (this.networkEventTimer >= 0) { clearTimeout(this.networkEventTimer); }
    this.networkEventTimer = setTimeout(() => {
      this.networkEventTimer = -1;
      this.refreshNetworkDNS();
    }, 250);
  }

  private watchNetwork(): void {
    if (this.networkObserver !== undefined || !this.stillCurrent()) { return; }
    try {
      const observer = connection.createNetConnection();
      this.networkObserver = observer;
      observer.on('netAvailable', (): void => this.scheduleNetworkRefresh());
      observer.on('netLost', (): void => this.scheduleNetworkRefresh());
      observer.on('netConnectionPropertiesChange', (): void => this.scheduleNetworkRefresh());
      observer.register((error: BusinessError): void => {
        if (error && this.networkObserver === observer) { this.networkObserver = undefined; }
        if (!error && this.networkObserver !== observer) {
          try { observer.unregister((): void => {}); } catch (_) { /* Released during registration. */ }
        }
      });
    } catch (_) { this.networkObserver = undefined; /* The periodic check remains available. */ }
  }

  private async refreshNetworkDNS(): Promise<void> {
    if (this.checkingNetworkEpoch === this.transportEpoch || this.handle < 0 || !this.stillCurrent()) { return; }
    this.checkingNetworkEpoch = this.transportEpoch; this.lastNetworkCheck = Date.now();
    this.networkEventPending = false;
    const handle = this.handle;
    const epoch = this.transportEpoch;
    const sockets: number[] = [];
    try {
      const dns = await this.physicalDNS();
      const serialized = JSON.stringify(dns);
      const key = this.physicalLinkKey + '|' + serialized;
      if (this.handle === handle && this.transportEpoch === epoch && this.stillCurrent() && key !== this.physicalDNSKey) {
        this.networkRevision++;
        if (this.dynamicRouting) {
          const snapshot: PhysicalRoutingSnapshot = { DNS: dns, LocalPrefixes: this.localPrefixes.slice() };
          wireguard.updateRoutedNetwork(handle, JSON.stringify(snapshot));
        }
        const updates: string[] = [];
        const vpn = this.vpn;
        if (vpn === undefined) { return; }
        for (const profile of this.transportProfiles) {
          let update = '';
          for (const peer of profile.peers) {
            if (peer.endpoint !== undefined) {
              const endpoint = await resolveEndpoint(peer.endpoint);
              update += 'public_key=' + peer.publicKey + '\nendpoint=' + endpoint + '\n';
            }
            if (this.handle !== handle || this.transportEpoch !== epoch || !this.stillCurrent()) { return; }
          }
          updates.push(update);
          // A fresh source port avoids colliding with the live socket during handover.
          const fd = wireguard.openSocket(0);
          sockets.push(fd);
          await vpn.protect(fd);
          if (this.handle !== handle || this.transportEpoch !== epoch || !this.stillCurrent()) { return; }
        }
        try { wireguard.rebindTransport(handle, sockets, updates); }
        catch (error) {
          // A partially applied native update must recover under the same request.
          this.recover();
          throw error as Error;
        }
        this.physicalDNSKey = key;
        this.networkChanges++;
        this.lastNetworkChange = Date.now();
      }
      if (this.transportEpoch === epoch) { this.networkError = ''; }
    } catch (_) { if (this.transportEpoch === epoch) { this.networkError = '正在恢复底层网络连接…'; } }
    finally {
      for (const fd of sockets) { wireguard.closeSocket(fd); }
      if (this.checkingNetworkEpoch === epoch) { this.checkingNetworkEpoch = -1; }
      if (this.transportEpoch === epoch && this.networkEventPending && this.stillCurrent()) { this.scheduleNetworkRefresh(); }
    }
  }

  private routedConfig(plans: ProfilePlan[], dns: string[]): string {
    const profiles: RoutedProfile[] = [];
    const diagnostics: RouteProfileDiagnostic[] = [];
    for (const plan of plans) {
      const snapshot = this.ruleSnapshot?.WireGuard.find((item): boolean => item.ID === plan.id);
      if (!snapshot) { throw new Error('当前连接的域名快照缺失，请断开后重新连接。'); }
      const domains = snapshot.Domains.slice();
      const exacts = snapshot.Exacts.slice();
      const cidrs: string[] = [];
      if (plan.rules.isDefault) {
        for (const peer of plan.config.peers) {
          for (const prefix of peer.allowedIps) { cidrs.push(prefix.address + '/' + prefix.prefixLength); }
        }
      } else {
        for (const value of plan.rules.manualCidrs) {
          const prefix = parseIpPrefix(value);
          if (prefix === undefined || prefix.prefixLength === 0) { throw new Error('手动 IP 段无效：' + value); }
          cidrs.push(prefix.address + '/' + prefix.prefixLength);
        }
        if (domains.length + exacts.length + cidrs.length === 0) {
          throw new Error('「' + plan.name + '」没有可用规则；关键词或正则条目目前不支持。');
        }
      }
      profiles.push({ ID: plan.id, Addresses: plan.config.addresses.map((prefix: IpPrefix): string => prefix.address),
        DNS: plan.config.dns, Domains: domains, Exacts: exacts, CIDRs: cidrs,
        RoutesFallback: plan.rules.isDefault,
        Default: plan.rules.isDefault && plan.config.peers.some((peer): boolean => peer.allowedIps.some((prefix: IpPrefix): boolean => prefix.prefixLength === 0)) });
      diagnostics.push({ id: plan.id, families: plan.config.addresses.map((prefix: IpPrefix): number => prefix.family),
        domains: domains.length, exacts: exacts.length, cidrs: cidrs.length });
    }
    // Only non-secret routing metadata is written for on-device diagnosis.
    const diagnostic: RouteDiagnostic = { mode: 'dynamic-domain', profiles: diagnostics };
    const bytes = util.TextEncoder.create().encodeInto(JSON.stringify(diagnostic));
    const file = fileIo.openSync(this.directory + '/wireguard-routing-diagnostic.json', fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
    try { fileIo.writeSync(file.fd, bytes.buffer); } finally { fileIo.closeSync(file); }
    const config: RoutedConfig = { DNS: dns, Profiles: profiles,
      SubnetPreferences: this.subnetPreferences || [], LocalPrefixes: this.localPrefixes.slice() };
    if (this.mixed && this.tailnetConfig !== undefined) {
      this.tailnetConfig.DNS = dns.slice();
      config.Tailnets = this.tailnetConfig;
    }
    return JSON.stringify(config);
  }

  private dynamicSystemConfig(): vpnExtension.VpnConfig {
    const routes: connection.RouteInfo[] = [hostRoute({ address: '0.0.0.0', prefixLength: 0, family: 4 }),
      hostRoute({ address: '::', prefixLength: 0, family: 6 })];
    // Declare precise routes as well as the default. Public APIs cannot change
    // the OS local-table precedence; DNS aliases provide capture on those systems.
    for (const preference of this.subnetPreferences || []) {
      if (preference.Priority === 'tailnet') {
        const prefix = parseIpPrefix(preference.CIDR);
        if (prefix !== undefined) { routes.push(hostRoute(prefix)); }
      }
    }
    return {
      // The OS-side local addresses must differ from DNS servers and the fake-address pool.
      addresses: [linkAddress({ address: '198.19.255.254', prefixLength: 32, family: 4 }),
        linkAddress({ address: 'fd7e:746e::ffff:fffe', prefixLength: 128, family: 6 })],
      routes: routes,
      dnsAddresses: ['198.18.0.1'], mtu: 1280, isIPv4Accepted: true, isIPv6Accepted: true,
      blockedApplications: [this.context.applicationInfo.name], isBlocking: false
    };
  }

  private buildSystemConfig(plans: ProfilePlan[], dnsPlan: ProfilePlan | undefined,
    mtu: number): vpnExtension.VpnConfig {
    const addresses: connection.LinkAddress[] = [];
    const routes: connection.RouteInfo[] = [];
    const seenAddresses = new Set<string>();
    const seenRoutes = new Set<string>();
    for (const plan of plans) {
      for (const prefix of dedupePrefixes(plan.config.addresses)) {
        const key = `${prefix.family}|${prefix.address}|${prefix.prefixLength}`;
        if (!seenAddresses.has(key)) {
          seenAddresses.add(key);
          addresses.push(linkAddress(prefix));
        }
      }
      for (const prefix of dedupePrefixes(plan.claimed)) {
        const key = `${prefix.family}|${prefix.address}|${prefix.prefixLength}`;
        if (!seenRoutes.has(key)) {
          seenRoutes.add(key);
          routes.push(hostRoute(prefix));
        }
      }
    }
    if (routes.length > MAX_SYSTEM_ROUTES) {
      throw new Error('系统路由总数不能超过 ' + MAX_SYSTEM_ROUTES.toString() + ' 条。');
    }
    const searchDomains: string[] = [];
    for (const plan of plans) {
      for (const domain of plan.config.searchDomains) {
        if (!searchDomains.includes(domain)) {
          searchDomains.push(domain);
        }
      }
    }
    return {
      addresses: addresses,
      routes: routes,
      dnsAddresses: dnsPlan?.config.dns ?? [],
      searchDomains: searchDomains,
      mtu: mtu,
      isIPv4Accepted: addresses.some((address: connection.LinkAddress): boolean => address.address.family === 1),
      isIPv6Accepted: addresses.some((address: connection.LinkAddress): boolean => address.address.family === 2),
      isBlocking: false,
    };
  }

  private async startTunnel(recoveryAttempt: boolean = false): Promise<void> {
    this.diagnostics?.event('starting', this.retries);
    let action = '读取配置';
    let transientStep = false;
    let retryStartup = false;
    try {
      if (this.ruleSnapshot === undefined) {
        this.ruleSnapshot = readOrCreateSessionRules(this.directory, this.session, this.profileIds,
          this.tailnetIds, this.mixed, this.useConfigRoutes);
        this.tailnetConfig = this.ruleSnapshot.Tailnets;
        this.subnetPreferences = this.ruleSnapshot.SubnetPreferences;
      }
      const plans = await this.loadPlans();
      if (!this.stillCurrent()) {
        return;
      }
      const dynamic = this.mixed || plans.some((plan: ProfilePlan): boolean => !plan.rules.isDefault);
      this.dynamicRouting = dynamic;
      action = '读取底层网络';
      transientStep = true;
      const dns = await this.physicalDNS();
      transientStep = false;
      if (!this.stillCurrent()) { return; }
      this.physicalDNSKey = this.physicalLinkKey + '|' + JSON.stringify(dns);
      const routing = dynamic ? this.routedConfig(plans, dns) : '';
      this.transportProfiles = plans.map((plan: ProfilePlan): TransportProfile => ({
        peers: plan.config.peers.map((peer): TransportPeer => ({ publicKey: peer.publicKey, endpoint: peer.endpoint }))
      }));
      if (!this.stillCurrent()) { return; }
      let dnsPlan: ProfilePlan | undefined;
      for (const plan of plans) {
        if (plan.rules.isDefault && plan.config.dns.length > 0) {
          dnsPlan = plan;
          break;
        }
      }
      for (const plan of plans) {
        action = `解析「${plan.name}」服务端地址`;
        transientStep = true;
        for (const peer of plan.config.peers) {
          plan.endpoints.push(peer.endpoint === undefined ? undefined : await resolveEndpoint(peer.endpoint));
          if (!this.stillCurrent()) {
            return;
          }
        }
      }
      transientStep = false;
      action = '保护 WireGuard UDP 套接字';
      this.vpn = vpnExtension.createVpnConnection(this.context);
      transientStep = true;
      for (const plan of plans) {
        plan.udpFd = wireguard.openSocket(plan.config.listenPort);
        this.udpFds.push(plan.udpFd);
        await this.vpn.protect(plan.udpFd);
        if (!this.stillCurrent()) {
          return;
        }
      }
      transientStep = false;
      let mtu = plans.length > 0 ? plans[0].config.mtu : 1280;
      for (const plan of plans) {
        if (plan.config.mtu < mtu) {
          mtu = plan.config.mtu;
        }
        if (plan.rules.isDefault) {
          for (const peer of plan.config.peers) {
            plan.claimed = plan.claimed.concat(peer.allowedIps);
          }
        }
      }
      if (dynamic && mtu < 1280) {
        throw new Error('动态域名分流需要 MTU 至少 1280，请修改 WireGuard 配置后重试。');
      }
      if (dnsPlan !== undefined) {
        dnsPlan.claimed = dnsPlan.claimed.concat(this.dnsPrefixes(dnsPlan));
      }
      for (const plan of plans) {
        plan.uapi = toWireGuardUapi(plan.config, plan.endpoints);
      }
      action = '创建系统 VPN';
      const systemConfig = dynamic ? this.dynamicSystemConfig() : this.buildSystemConfig(plans, dnsPlan, mtu);
      transientStep = true;
      this.tunFd = await this.vpn.create(systemConfig);
      transientStep = false;
      this.created = true;
      if (!this.stillCurrent()) {
        return;
      }
      action = this.mixed ? '启动 WireGuard 和 Tailnet 连接' : '启动 WireGuard';
      const udpFds: number[] = plans.map((plan: ProfilePlan): number => plan.udpFd);
      const configs: string[] = plans.map((plan: ProfilePlan): string => plan.uapi);
      this.handle = dynamic ? wireguard.startRouted(this.tunFd, udpFds, configs, mtu, routing) :
        wireguard.startMany(this.tunFd, udpFds, configs, mtu);
      for (const fd of this.udpFds) {
        wireguard.closeSocket(fd);
      }
      this.udpFds = [];
      this.networkError = '';
      this.diagnostics?.event('running', this.retries);
      this.watchNetwork();
      this.report();
      if (!this.failed && !this.recovering && this.handle >= 0 && this.stillCurrent()) {
        this.timer = setInterval(() => this.report(), 1500);
      }
    } catch (error) {
      if (!this.stopped) {
        const code = (error as BusinessError).code;
        const message = error instanceof Error && error.message.length > 0 ? error.message :
          action + '失败' + (typeof code === 'number' ? '（' + code.toString() + '）' : '') + '。';
        const permanent = [201, 401, 2200001, 2203001, 2203004].includes(code);
        if (recoveryAttempt && transientStep && !permanent && this.stillCurrent()) {
          this.networkError = '正在恢复底层网络连接…';
          retryStartup = true;
        } else { this.fail(message); }
      }
    } finally {
      this.starting = false;
      if (this.stopped || this.failed || this.handle < 0) {
        await this.release();
        if (this.stopped && !this.failed) {
          this.publish(new TunnelState(this.session, TunnelPhase.Disconnected));
        }
      }
      if (this.stopped) { this.cleanupRules(); }
      if (retryStartup && this.stillCurrent()) { await this.recover(); }
    }
  }

  private report(): void {
    try {
      if (!this.stillCurrent()) {
        this.release();
        return;
      }
      const stats = wireguard.status(this.handle);
      if (stats.running) {
        let phase = stats.lastHandshake > 0 ? TunnelPhase.Connected : TunnelPhase.Waiting;
        let message = '';
        let details = new MixedNodeStatus();
        if (this.mixed) {
          details = JSON.parse(wireguard.detailStatus(this.handle)) as MixedNodeStatus;
          if (!(details.WireGuard instanceof Array) || !(details.Tailnets instanceof Array)) {
            throw new Error('连接运行状态无效。');
          }
          const wireguardReady = details.WireGuard.filter((node): boolean =>
            this.profileIds.includes(node.ID) && node.Running && node.LastHandshake > 0).length;
          const tailnetReady = details.Tailnets.filter((node: NetworkNodeStatus): boolean =>
            this.tailnetIds.includes(node.ID) && node.BackendState === 'Running' && !node.Error).length;
          phase = wireguardReady === this.profileIds.length && tailnetReady === this.tailnetIds.length ?
            TunnelPhase.Connected : TunnelPhase.Waiting;
          message = `${wireguardReady}/${this.profileIds.length} 个 WireGuard、${tailnetReady}/${this.tailnetIds.length} 个 Tailnet 已连接`;
        }
        if (this.networkError) { phase = TunnelPhase.Waiting; message = this.networkError; }
        const state = new TunnelState(this.session, phase, message, stats.sentBytes, stats.receivedBytes, stats.lastHandshake);
        state.wireguardNodes = details.WireGuard; state.tailnetNodes = details.Tailnets;
        state.flowError = typeof details.FlowError === 'string' ? details.FlowError.slice(0, 2048) : '';
        state.routeEvents = details.RouteEvents instanceof Array ? details.RouteEvents.slice(-16) : [];
        state.transportRebinds = details.Rebinds ?? 0;
        state.lastTransportRebind = details.LastRebind ?? 0;
        state.selectedDNS = stats.selectedDNS; state.selectedFlows = stats.selectedFlows; state.directFlows = stats.directFlows;
        this.publish(state);
        this.observeProviderHealth(state);
        this.serviceRouteCheck();
        if (Date.now() - this.lastNetworkCheck >= 3000) { this.refreshNetworkDNS(); }
        return;
      }
    } catch (_) {
      // The worker or its status channel failed.
    }
    this.recover();
  }

  private cleanupRules(): void {
    if (this.requested()) { return; } // System destruction can restart the same requested session.
    try { cleanupSessionRules(this.directory, this.session); } catch (_) { /* Stale non-secret snapshots are safe to retain. */ }
  }

  private observeProviderHealth(state: TunnelState): void {
    for (const id of this.profileIds) {
      const node = state.wireguardNodes.find((item): boolean => item.ID === id);
      // Aggregate multi-WG counters cannot identify the failing member.
      if (!node && this.profileIds.length !== 1) { continue; }
      let lastFailed = 0;
      for (const event of state.routeEvents) {
        if (event.Owner === 'wg:' + id && !event.Success && event.Time > lastFailed) { lastFailed = event.Time; }
      }
      const health: PureVpnHealthSnapshot = {
        now: Date.now(), profileId: id, session: this.session, phase: state.phase,
        physicalNetworkAvailable: !this.networkError && this.physicalNetworkId >= 0,
        networkError: !!this.networkError, running: node ? node.Running : this.handle >= 0,
        lastHandshake: node ? node.LastHandshake : state.lastHandshake,
        sentBytes: node ? node.SentBytes : state.sentBytes,
        receivedBytes: node ? node.ReceivedBytes : state.receivedBytes,
        lastFailedRequestAt: lastFailed
      };
      try { observePureVpnHealth(this.directory, health); } catch (_) { /* Health notes must never interrupt transport. */ }
    }
  }

  private mapRouteProfile(decision: RouteDecision): void {
    if (decision.Kind === 'wireguard' && decision.NetworkID.startsWith('index:') &&
      Number.isInteger(decision.DeviceIndex) && decision.DeviceIndex >= 0 && decision.DeviceIndex < this.profileIds.length) {
      decision.NetworkID = this.profileIds[decision.DeviceIndex]; decision.Owner = 'wg:' + decision.NetworkID;
    }
  }

  private async serviceRouteCheck(): Promise<void> {
    if (this.routeCheckBusy || !this.stillCurrent() || this.handle < 0 || this.networkEventPending ||
      this.checkingNetworkEpoch === this.transportEpoch) { return; }
    const request = readRouteCheckRequest(this.directory, this.session);
    if (!request || request.id === this.lastRouteCheck) { return; }
    this.routeCheckBusy = true;
    const handle = this.handle; const epoch = this.transportEpoch; const networkKey = this.physicalDNSKey;
    const revision = this.networkRevision;
    try {
      const result = parseRouteCheckResult(await wireguard.checkRoute(handle,
        JSON.stringify({ Target: request.Target, ResolveDNS: request.ResolveDNS })));
      if (this.handle === handle && this.transportEpoch === epoch && this.stillCurrent() && this.physicalDNSKey === networkKey &&
        this.networkRevision === revision && !this.networkEventPending && this.checkingNetworkEpoch !== epoch) {
        this.mapRouteProfile(result.Decision);
        for (const address of result.Addresses) { this.mapRouteProfile(address.Decision); }
        writeRouteCheckResponse(this.directory, request, result); this.lastRouteCheck = request.id;
      }
    } catch (error) {
      if (this.handle === handle && this.transportEpoch === epoch && this.stillCurrent() && this.physicalDNSKey === networkKey &&
        this.networkRevision === revision && !this.networkEventPending && this.checkingNetworkEpoch !== epoch) {
        try {
          writeRouteCheckResponse(this.directory, request, undefined, (error as Error).message || '路由检查失败，请稍后重试。');
          this.lastRouteCheck = request.id;
        } catch (_) { /* Keep the request retryable when response storage is unavailable. */ }
      }
    } finally { this.routeCheckBusy = false; }
  }

  private async recover(): Promise<void> {
    if (this.recovering || !this.stillCurrent()) { return; }
    this.recovering = true;
    await this.release();
    if (!this.stillCurrent()) { this.recovering = false; return; }
    this.retries++;
    this.diagnostics?.event('recovering', this.retries);
    const deadline = Date.now() + Math.min(60000, 2000 * Math.pow(2, Math.min(this.retries - 1, 5)));
    this.retryTimer = setInterval(() => {
      if (!this.stillCurrent()) {
        clearInterval(this.retryTimer); this.retryTimer = -1; this.recovering = false; return;
      }
      this.publish(new TunnelState(this.session, TunnelPhase.Starting, '隧道恢复中，等待重试…'));
      if (Date.now() >= deadline) {
        clearInterval(this.retryTimer); this.retryTimer = -1;
        this.recovering = false; this.starting = true; this.failed = false; this.startTunnel(true);
      }
    }, 1500);
  }

  private fail(message: string): void {
    this.failed = true;
    this.diagnostics?.event('failed', this.retries);
    try {
      this.publish(new TunnelState(this.session, TunnelPhase.Failed, message));
    } catch (_) {
      // Cleanup is still required if status storage is unavailable.
    } finally {
      if (!this.starting) {
        this.release();
      }
    }
  }

  private async release(): Promise<void> {
    this.transportEpoch++;
    this.checkingNetworkEpoch = -1;
    if (this.networkEventTimer >= 0) { clearTimeout(this.networkEventTimer); this.networkEventTimer = -1; }
    this.networkEventPending = false;
    const observer = this.networkObserver;
    this.networkObserver = undefined;
    if (observer !== undefined) {
      try { observer.unregister((): void => {}); } catch (_) { /* Already unregistered. */ }
    }
    if (this.timer >= 0) {
      clearInterval(this.timer);
      this.timer = -1;
    }
    if (this.handle >= 0) {
      const handle = this.handle;
      this.handle = -1;
      wireguard.stop(handle);
    }
    for (const fd of this.udpFds) {
      wireguard.closeSocket(fd);
    }
    this.udpFds = [];
    this.tunFd = -1;
    const vpn = this.vpn;
    this.vpn = undefined;
    if (vpn !== undefined && this.created) {
      this.created = false;
      try {
        await vpn.destroy();
      } catch (_) {
        // HarmonyOS also destroys the VPN when its extension exits.
      }
    }
  }
}
