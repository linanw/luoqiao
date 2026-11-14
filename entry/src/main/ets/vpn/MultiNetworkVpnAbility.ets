import { connection, vpnExtension, VpnExtensionAbility } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import * as tailnet from 'libtailnet.so';
import { NetworkProfile, NetworkStatus, readNetworkProfiles, saveNetworkJSON, writeNetworkStatus } from '../model/NetworkProfiles';
import { SessionRulesSnapshot, readOrCreateSessionRules, cleanupSessionRules } from '../model/SessionRules';
import { VpnDiagnostics } from '../model/VpnDiagnostics';
export default class MultiNetworkVpnAbility extends VpnExtensionAbility {
  private vpn: vpnExtension.VpnConnection | undefined;
  private timer: number = -1;
  private busy: boolean = false;
  private stopped: boolean = false;
  private active: boolean = false;
  private retryAt: number = 0;
  private failures: number = 0;
  private dns: string[] = [];
  private netKey: string = '';
  private lastNetworkCheck: number = 0;
  private session: string = '';
  private snapshot: SessionRulesSnapshot | undefined;
  private diagnostics: VpnDiagnostics | undefined;
  onCreate(): void {
    this.session = util.generateRandomUUID();
    this.diagnostics = new VpnDiagnostics(this.context.filesDir, this.session, 'multi-tailnet');
    this.diagnostics.event('created');
    try {
      const ids = readNetworkProfiles(this.context.filesDir).filter((profile: NetworkProfile): boolean => profile.Enabled !== false)
        .map((profile: NetworkProfile): string => profile.ID);
      if (ids.length === 0) { throw new Error('没有已启用的 Tailnet 连接。'); }
      this.snapshot = readOrCreateSessionRules(this.context.filesDir, this.session, [], ids, true, false);
    } catch (error) {
      const status = new NetworkStatus(); status.error = (error as Error).message;
      writeNetworkStatus(this.context.filesDir, status); return;
    }
    this.timer = setInterval(() => this.poll(), 2000); this.poll();
  }
  onDestroy(): void {
    if (this.stopped) { return; }
    this.stopped = true;
    this.diagnostics?.event('destroyed');
    if (this.timer >= 0) { clearInterval(this.timer); this.timer = -1; }
    if (!this.busy) { this.finish(); }
  }
  private runtimeConfig(): string {
    const config = this.snapshot?.Tailnets;
    if (!config) { throw new Error('会话规则快照不可用，请重新连接。'); }
    config.DNS = this.dns.slice();
    const path = this.context.filesDir + '/network-runtime.json';
    saveNetworkJSON(path, JSON.stringify(config)); return path;
  }
  private async poll(): Promise<void> {
    if (this.stopped || this.busy || !this.snapshot) { return; }
    this.busy = true;
    try {
      if (Date.now() < this.retryAt) {
        const s = new NetworkStatus(); s.active = true; s.error = '正在恢复，稍后自动重试'; writeNetworkStatus(this.context.filesDir, s); return;
      }
      if (!this.active) {
        const net = await connection.getDefaultNet();
        const properties = await connection.getConnectionProperties(net);
        if (this.stopped) { return; }
        const physicalDNS = properties.dnses.map((ip: connection.NetAddress): string => ip.address)
          .filter((ip: string): boolean => ip !== '198.18.0.1' && ip !== 'fd7e:746e::1');
        if (physicalDNS.length > 0) { this.dns = physicalDNS; }
        if (this.dns.length === 0) { throw new Error('当前网络没有可用 DNS'); }
        await tailnet.call('multi', this.runtimeConfig());
        if (this.stopped) { return; }
        this.vpn = vpnExtension.createVpnConnection(this.context);
        const fd = await this.vpn.create({
          addresses: [{ address: { address: '198.19.255.254', family: 1 }, prefixLength: 32 },
            { address: { address: 'fd7e:746e::ffff:fffe', family: 2 }, prefixLength: 128 }],
          routes: [{ interface: '', destination: { address: { address: '0.0.0.0', family: 1 }, prefixLength: 0 },
            gateway: { address: '0.0.0.0', family: 1 }, hasGateway: false, isDefaultRoute: true },
            { interface: '', destination: { address: { address: '::', family: 2 }, prefixLength: 0 },
              gateway: { address: '::', family: 2 }, hasGateway: false, isDefaultRoute: true }],
          dnsAddresses: ['198.18.0.1'], mtu: 1280, isIPv4Accepted: true, isIPv6Accepted: true,
          blockedApplications: [this.context.applicationInfo.name], isBlocking: false
        });
        if (this.stopped) { return; }
        await tailnet.call('attach', fd);
        if (this.stopped) { return; }
        this.active = true;
        this.diagnostics?.event('running', this.failures);
      }
      if (Date.now() - this.lastNetworkCheck > 10000) {
        this.lastNetworkCheck = Date.now();
        try {
          const net = await connection.getDefaultNet();
          const props = await connection.getConnectionProperties(net);
          if (this.stopped) { return; }
          const servers = props.dnses.map((item: connection.NetAddress): string => item.address)
            .filter((ip: string): boolean => ip !== '198.18.0.1' && ip !== 'fd7e:746e::1');
          const key = net.netId.toString() + '|' + servers.join(',');
          if (servers.length > 0 && key !== this.netKey) {
            await tailnet.call('network', JSON.stringify(servers)); this.dns = servers; this.netKey = key;
          }
        } catch (_) { /* Offline nodes retain identity and retry on the next observation. */ }
      }
      if (this.diagnostics?.beginSample()) {
        try { this.diagnostics.sample(await tailnet.call('resources')); }
        catch (_) { this.diagnostics.event('sample-unavailable'); }
      }
      if (this.stopped) { return; }
      const s = JSON.parse(await tailnet.call('status')) as NetworkStatus;
      if (this.stopped) { return; }
      if (s.ReadError || s.WriteError) { throw new Error(s.ReadError || s.WriteError); }
      s.active = true; this.failures = 0; writeNetworkStatus(this.context.filesDir, s);
    } catch (e) {
      await this.close(); this.failures++;
      this.diagnostics?.event('recovering', this.failures);
      this.retryAt = Date.now() + Math.min(60000, 2000 * Math.pow(2, Math.min(this.failures - 1, 5)));
      if (!this.stopped) { const s = new NetworkStatus(); s.active = true; s.error = (e as Error).message; writeNetworkStatus(this.context.filesDir, s); }
    } finally { this.busy = false; if (this.stopped) { await this.finish(); } }
  }
  private async close(): Promise<void> {
    try { await tailnet.call('stop'); } catch (_) {}
    if (this.vpn) { try { await this.vpn.destroy(); } catch (_) {} this.vpn = undefined; }
    this.active = false;
  }
  private async finish(): Promise<void> {
    await this.close();
    if (this.session) {
      try { cleanupSessionRules(this.context.filesDir, this.session); } catch (_) { /* Only this ended session may remain for later cleanup. */ }
    }
    writeNetworkStatus(this.context.filesDir, new NetworkStatus());
  }
}
