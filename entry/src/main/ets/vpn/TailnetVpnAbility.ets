import { Want } from '@kit.AbilityKit';
import { connection, vpnExtension, VpnExtensionAbility } from '@kit.NetworkKit';
import * as tailnet from 'libtailnet.so';
import { TailnetStatus, writeTailnet } from '../model/TailnetState';
import { VpnDiagnostics } from '../model/VpnDiagnostics';
function address(ip: string, bits: number): connection.LinkAddress {
  return { address: { address: ip, family: ip.includes(':') ? 2 : 1 }, prefixLength: bits };
}
function route(ip: string, bits: number): connection.RouteInfo {
  return { interface: '', destination: address(ip, bits), gateway: { address: ip.includes(':') ? '::' : '0.0.0.0', family: ip.includes(':') ? 2 : 1 }, hasGateway: false, isDefaultRoute: false };
}
export default class TailnetVpnAbility extends VpnExtensionAbility {
  private control: string = '';
  private hostname: string = '';
  private started: boolean = false;
  private failures: number = 0;
  private retryAt: number = 0;
  private healthySince: number = 0;
  private routeKey: string = '';
  private stopped: boolean = false;
  private busy: boolean = false;
  private active: boolean = false;
  private timer: number = -1;
  private vpn: vpnExtension.VpnConnection | undefined;
  private diagnostics: VpnDiagnostics | undefined;
  onCreate(want: Want): void {
    const control = want.parameters?.['control'];
    const hostname = want.parameters?.['hostname'];
    if (typeof control !== 'string' || typeof hostname !== 'string') {
      const state = new TailnetStatus(); state.error = '无效配置';
      writeTailnet(this.context.filesDir, state);
      return;
    }
    this.control = control;
    this.hostname = hostname;
    this.diagnostics = new VpnDiagnostics(this.context.filesDir, '', 'tailnet');
    this.diagnostics.event('created');
    this.timer = setInterval(() => this.poll(), 1500);
    this.poll();
  }
  private async start(): Promise<void> {
    const key = encodeURIComponent(this.control || 'tailscale');
    await tailnet.call('start', this.context.filesDir + '/tailnet/' + key, this.hostname, this.control);
    this.started = true;
    if (!this.stopped) { this.vpn = vpnExtension.createVpnConnection(this.context); }
  }
  private signature(state: TailnetStatus): string {
    return state.TailscaleIPs.slice().sort().join(',') + '|' + state.DNSSuffix + '|' +
      state.SubnetRoutes.slice().sort().join(',');
  }
  private async poll(): Promise<void> {
    if (this.busy || this.stopped) { return; }
    if (Date.now() < this.retryAt) { this.publishRetry(); return; }
    this.busy = true;
    try {
      if (!this.started) { await this.start(); }
      if (this.stopped) { return; }
      if (this.diagnostics?.beginSample()) {
        try { this.diagnostics.sample(await tailnet.call('resources')); }
        catch (_) { this.diagnostics.event('sample-unavailable'); }
      }
      if (this.stopped) { return; }
      const state = JSON.parse(await tailnet.call('status')) as TailnetStatus;
      if (this.stopped) { return; }
      if (state.error || !state.BackendState || state.ReadError || state.WriteError) {
        throw new Error(state.error || state.ReadError || state.WriteError || '节点状态不可用');
      }
      if (this.active && state.BackendState === 'Running' && this.routeKey !== this.signature(state)) {
        throw new Error('网络路由已更新，正在重新建立 VPN');
      }
      if (!this.active && state.BackendState === 'Running' && state.TailscaleIPs.length > 0 && this.vpn) {
        const routes: connection.RouteInfo[] = [route('100.64.0.0', 10), route('fd7a:115c:a1e0::', 48)];
        for (const peer of state.PeerList) {
          for (const ip of peer.TailscaleIPs) { routes.push(route(ip, ip.includes(':') ? 128 : 32)); }
        }
        for (const cidr of state.SubnetRoutes) {
          const parts = cidr.split('/');
          const bits = Number(parts[1]);
          if (parts.length === 2 && bits > 0) { routes.push(route(parts[0], bits)); }
        }
        const fd = await this.vpn.create({
          addresses: state.TailscaleIPs.map((ip: string): connection.LinkAddress => address(ip, ip.includes(':') ? 128 : 32)),
          routes: routes, dnsAddresses: ['100.100.100.100'],
          searchDomains: state.DNSSuffix ? [state.DNSSuffix] : [], mtu: 1280,
          blockedApplications: [this.context.applicationInfo.name],
          isIPv4Accepted: true, isIPv6Accepted: true, isBlocking: false
        });
        if (this.stopped) { return; }
        await tailnet.call('attach', fd);
        this.active = true;
        this.diagnostics?.event('running', this.failures);
        this.routeKey = this.signature(state);
      }
      state.connected = this.active && state.BackendState === 'Running';
      if (state.connected) {
        if (this.healthySince === 0) { this.healthySince = Date.now(); }
        if (Date.now() - this.healthySince >= 60000) { this.failures = 0; }
      } else { this.healthySince = 0; }
      writeTailnet(this.context.filesDir, state);
    } catch (e) {
      this.healthySince = 0;
      this.failures++;
      this.diagnostics?.event('recovering', this.failures);
      this.retryAt = Date.now() + Math.min(60000, 1500 * Math.pow(2, Math.min(this.failures - 1, 6)));
      await this.closeTunnel();
      if (!this.stopped) { this.publishRetry((e as Error).message); }
    } finally { this.busy = false; if (this.stopped) { await this.release(); } }
  }
  onDestroy(): void { this.stopped = true; this.diagnostics?.event('destroyed'); if (!this.busy) { this.release(); } }
  private publishRetry(reason: string = '等待网络恢复'): void {
    const state = new TailnetStatus();
    state.BackendState = 'Reconnecting';
    state.error = reason + '；' + Math.max(0, Math.ceil((this.retryAt - Date.now()) / 1000)).toString() + ' 秒后重试';
    writeTailnet(this.context.filesDir, state);
  }
  private async release(): Promise<void> {
    if (this.timer >= 0) { clearInterval(this.timer); this.timer = -1; }
    await this.closeTunnel();
  }
  private async closeTunnel(): Promise<void> {
    try { await tailnet.call('stop'); } catch (_) {}
    this.started = false;
    this.routeKey = '';
    if (this.vpn) { try { await this.vpn.destroy(); } catch (_) {} this.vpn = undefined; }
    this.active = false;
  }
}
