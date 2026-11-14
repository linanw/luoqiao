import { util } from '@kit.ArkTS';
import { common, Want } from '@kit.AbilityKit';
import { router, LengthMetrics } from '@kit.ArkUI';
import { vpnExtension } from '@kit.NetworkKit';
import { WorkspaceShell } from '../components/WorkspaceShell';
import { dismissWorkspaceDrawer } from '../model/WorkspaceNavigation';
import { NetworkProfile, NetworkStatus, NetworkNodeStatus, readNetworkProfiles, saveNetworkProfiles,
  readNetworkStatus, writeNetworkStatus } from '../model/NetworkProfiles';
import { readProfileRules, deleteProfileRulesFiles } from '../model/SplitTunnel';
import { readTailnet, TailnetStatus, writeTailnet } from '../model/TailnetState';
import { listProfiles, ProfileMeta, deleteProfile, loadProfileText } from '../model/ProfileStore';
import { readTunnelState, readTunnelRequest, TunnelPhase, TunnelState, writeTunnelRequest, VPN_ABILITY, cancelTunnelRecovery } from '../model/TunnelState';
import { parseWireGuardConfig } from '../model/WireGuardConfig';
import { readMixedSelection, setWireGuardSelected, setLegacySelected, selectedMixedWireGuardIds,
  selectedMixedTailnetIds, readLegacyNetworkProfile } from '../model/MixedConnections';
import { TailnetConnectionView, readTailnetConnectionView } from '../model/TailnetConnectionView';
import { readTunnelRecoveryStatus, TunnelRecoveryStatus } from '../model/TunnelRecovery';

const INK: string = '#172033';
const MUTED: string = '#728097';
const BLUE: string = '#315EFB';
const BORDER: string = '#E4E9F2';

class ConnectionItem {
  kind: string;
  profileId: string;
  name: string;
  constructor(kind: string, id: string, name: string) { this.kind = kind; this.profileId = id; this.name = name; }
  key(): string { return this.kind + ':' + this.profileId; }
}

@Entry
@Component
struct NetworksPage {
  @State private contentWidth: number = 0;
  onBackPress(): boolean { return dismissWorkspaceDrawer(); }
  @State private profiles: NetworkProfile[] = [];
  @State private state: NetworkStatus = new NetworkStatus();
  @State private legacy: TailnetStatus = new TailnetStatus();
  @State private wireguard: ProfileMeta[] = [];
  @State private wireguardActive: boolean = false;
  @State private query: string = '';
  @State private kindFilter: string = 'all';
  @State private legacyExists: boolean = false;
  @State private legacyEnabled: boolean = true;
  @State private legacyProfile: NetworkProfile = new NetworkProfile();
  @State private legacyView: TailnetConnectionView = new TailnetConnectionView();
  @State private disabledWireGuard: string[] = [];
  @State private wgState: TunnelState = new TunnelState('', TunnelPhase.Disconnected);
  @State private wgRuleCounts: string[] = [];
  @State private recovery: TunnelRecoveryStatus = new TunnelRecoveryStatus();
  @State private resumeIntent: boolean = false;
  @State private error: string = '';
  @State private busy: boolean = false;
  @State private ruleCounts: string[] = [];
  private timer: number = -1;
  private context(): common.UIAbilityContext { return this.getUIContext().getHostContext() as common.UIAbilityContext; }
  aboutToAppear(): void { this.refresh(); this.watch(); }
  onPageShow(): void { this.refresh(); this.watch(); }
  onPageHide(): void { this.unwatch(); }
  aboutToDisappear(): void { this.unwatch(); }
  private watch(): void { this.unwatch(); this.timer = setInterval(() => this.refreshStatus(), 2000); }
  private unwatch(): void { if (this.timer >= 0) { clearInterval(this.timer); this.timer = -1; } }
  private refreshStatus(): void {
    this.state = readNetworkStatus(this.context().filesDir);
    this.legacy = readTailnet(this.context().filesDir);
    this.legacyView = readTailnetConnectionView(this.context().filesDir, 'legacy');
    const wg = readTunnelState(this.context().filesDir);
    this.wgState = wg || new TunnelState('', TunnelPhase.Disconnected);
    const request = readTunnelRequest(this.context().filesDir);
    this.resumeIntent = request?.phase === TunnelPhase.Starting && request.resumeOnForeground !== false;
    this.recovery = readTunnelRecoveryStatus(this.context().filesDir);
    this.wireguardActive = wg !== undefined && Date.now() - wg.updated >= -5000 && Date.now() - wg.updated < 15000 &&
      [TunnelPhase.Starting, TunnelPhase.Connected, TunnelPhase.Waiting, TunnelPhase.Stopping].includes(wg.phase);
  }
  private refresh(): void {
    try {
      this.profiles = readNetworkProfiles(this.context().filesDir);
      this.wireguard = listProfiles(this.context());
      const legacyProfile = readLegacyNetworkProfile(this.context().filesDir);
      this.legacyExists = legacyProfile !== undefined;
      this.legacyProfile = legacyProfile || new NetworkProfile();
      const selection = readMixedSelection(this.context().filesDir);
      this.legacyEnabled = selection.legacyEnabled;
      this.disabledWireGuard = selection.disabledWireGuard;
      this.wgRuleCounts = this.wireguard.map((profile: ProfileMeta): string => {
        const rules = readProfileRules(this.context().filesDir, profile.id);
        return rules.enabled && !rules.isDefault ?
          `站点分流 · ${rules.lists.length} 个域名库 · ${rules.groupIds.length} 个地址组 · ${rules.manualDomains.length + rules.manualCidrs.length} 条单独规则` : '按配置中的 AllowedIPs 路由';
      });
      this.ruleCounts = this.profiles.map((profile: NetworkProfile): string => {
        const rules = readProfileRules(this.context().filesDir, profile.ID);
        return `${rules.lists.length} 个域名库 · ${rules.groupIds.length} 个地址组 · ${rules.manualDomains.length + rules.manualCidrs.length} 条单独规则${!rules.enabled && rules.hasContent() ? " · 规则未启用" : ""}`;
      });
      this.refreshStatus();
    } catch (e) { this.error = (e as Error).message; }
  }
  private locked(): boolean { return this.busy || this.state.active || this.otherActive(); }
  private otherActive(): boolean { return this.legacy.BackendState !== 'Stopped' || this.wireguardActive || this.resumeIntent; }
  private enabledCount(): number {
    return this.profiles.filter((p: NetworkProfile): boolean => p.Enabled !== false).length +
      this.wireguard.filter((p: ProfileMeta): boolean => this.wgEnabled(p.id)).length +
      (this.legacyExists && this.legacyEnabled ? 1 : 0);
  }
  private activeTailnets(): NetworkNodeStatus[] {
    return this.wireguardActive && this.wgState.mixed ? (this.wgState.tailnetNodes || []) : (this.state.Nodes || []);
  }
  private onlineCount(): number { return this.activeTailnets().filter((n: NetworkNodeStatus): boolean => n.BackendState === 'Running' && !n.Error).length; }
  private statusFor(id: string): NetworkNodeStatus { return id === 'legacy' ? this.legacyView.node :
    (this.activeTailnets().find((n: NetworkNodeStatus): boolean => n.ID === id) || new NetworkNodeStatus()); }
  private mixedActive(): boolean { return this.wireguardActive && this.wgState.mixed; }
  private wgEnabled(id: string): boolean { return !this.disabledWireGuard.includes(id); }
  private toggleWireGuard(id: string, enabled: boolean): void {
    this.refreshStatus(); if (this.locked()) { return; }
    try { setWireGuardSelected(this.context().filesDir, id, enabled); this.refresh(); }
    catch (e) { this.error = (e as Error).message; }
  }
  private toggleLegacy(enabled: boolean): void {
    this.refreshStatus(); if (this.locked()) { return; }
    try { setLegacySelected(this.context().filesDir, enabled); this.refresh(); }
    catch (e) { this.error = (e as Error).message; }
  }
  private overviewStatus(): string {
    if (this.recovery.phase === 'checking') { return '正在确认连接状态'; }
    if (this.recovery.phase === 'backoff' || this.recovery.phase === 'restarting' || this.recovery.phase === 'waiting') {
      return '正在恢复连接';
    }
    if (this.resumeIntent && !this.wireguardActive) { return '连接已中断或状态未确认'; }
    if (this.mixedActive()) {
      const ready = (this.wgState.wireguardNodes || []).filter(node => node.Running && node.LastHandshake > 0).length;
      return `${ready}/${this.wgState.profileIds.length} 个 WireGuard · ${this.onlineCount()}/${(this.wgState.tailnetIds || []).length} 个 Tailnet`;
    }
    return this.state.active ? `${this.onlineCount()} 个 Tailnet 已连接` : (this.wireguardActive ?
      'WireGuard · ' + this.wgRuntimeLabel() : (this.legacy.connected ? 'Tailnet 已连接' : '准备连接你的网络'));
  }
  private phase(profile: NetworkProfile): string {
    if (profile.Enabled === false) { return '未启用'; }
    const node = this.statusFor(profile.ID);
    if (node.AuthURL || node.BackendState === 'NeedsLogin') { return '待登录'; }
    if (node.BackendState === 'NeedsMachineAuth') { return '待管理员批准'; }
    if (node.BackendState === 'Reconnecting') { return '重连中'; }
    if (node.Error) { return '连接异常'; }
    if (node.BackendState === 'Running') { return '已连接'; }
    return this.state.active || (this.mixedActive() && (this.wgState.tailnetIds || []).includes(profile.ID)) ? '连接中' : '未连接';
  }
  private allConnections(): ConnectionItem[] {
    const items = this.profiles.map((profile: NetworkProfile): ConnectionItem => new ConnectionItem('tailnet', profile.ID, profile.Name));
    for (const profile of this.wireguard) { items.push(new ConnectionItem('wireguard', profile.id, profile.name)); }
    if (this.legacyExists) { items.push(new ConnectionItem('legacy', 'legacy', this.legacyProfile.Name)); }
    return items;
  }
  private visible(): ConnectionItem[] {
    const query = this.query.trim().toLowerCase();
    return this.allConnections().filter((item: ConnectionItem): boolean => {
      const kind = item.kind === 'legacy' ? 'tailnet' : item.kind;
      const profile = item.kind === 'legacy' ? this.legacyProfile : this.profiles.find((p: NetworkProfile): boolean => p.ID === item.profileId);
      const text = item.name + ' ' + kind + ' ' + (profile ? profile.ControlURL + ' ' + profile.Hostname + (profile.ControlURL ? ' headscale' : ' tailscale') : '');
      return (this.kindFilter === 'all' || this.kindFilter === kind) && text.toLowerCase().includes(query);
    });
  }
  private tailnetProfile(id: string): NetworkProfile { return this.profiles.find((p: NetworkProfile): boolean => p.ID === id) || new NetworkProfile(); }
  private wgParticipates(id: string): boolean { return this.wireguardActive && (this.wgState.profileIds || []).includes(id); }
  private wgRuntimeLabel(): string {
    if (this.wgState.phase === TunnelPhase.Starting) { return '连接中'; }
    if (this.wgState.phase === TunnelPhase.Waiting) { return '等待握手'; }
    if (this.wgState.phase === TunnelPhase.Stopping) { return '断开中'; }
    if (this.wgState.phase === TunnelPhase.Connected && this.wgState.lastHandshake > 0) {
      return (this.wgState.profileIds || []).length > 1 ? '组内已有握手' : '已握手';
    }
    return '等待握手';
  }
  private wgLabel(id: string): string {
    if (this.wgState.phase === TunnelPhase.Failed && (this.wgState.profileIds || []).includes(id)) { return '连接失败'; }
    if (!this.wgParticipates(id)) { return '未连接'; }
    if (this.wgState.mixed) {
      const node = (this.wgState.wireguardNodes || []).find(item => item.ID === id);
      return node?.Running && node.LastHandshake > 0 ? '已握手' : '等待握手';
    }
    return this.wgRuntimeLabel();
  }
  private wgBytes(bytes: number): string {
    if (!Number.isFinite(bytes) || bytes < 0) { return '0 B'; }
    if (bytes < 1024) { return Math.floor(bytes) + ' B'; }
    if (bytes < 1024 * 1024) { return (bytes / 1024).toFixed(1) + ' KB'; }
    if (bytes < 1024 * 1024 * 1024) { return (bytes / (1024 * 1024)).toFixed(1) + ' MB'; }
    return (bytes / (1024 * 1024 * 1024)).toFixed(2) + ' GB';
  }
  private wgTraffic(id: string): string {
    if (this.wgState.mixed) {
      const node = (this.wgState.wireguardNodes || []).find(item => item.ID === id);
      return '发送 ' + this.wgBytes(node?.SentBytes || 0) + ' · 接收 ' + this.wgBytes(node?.ReceivedBytes || 0);
    }
    const scope = (this.wgState.profileIds || []).length > 1 ? '多连接合计 · ' : '';
    return scope + '发送 ' + this.wgBytes(this.wgState.sentBytes) + ' · 接收 ' + this.wgBytes(this.wgState.receivedBytes);
  }
  private wgHandshake(id: string): string {
    if (this.wgState.mixed) {
      const node = (this.wgState.wireguardNodes || []).find(item => item.ID === id);
      return node && node.LastHandshake > 0 ? '最近握手 ' + new Date(node.LastHandshake).toLocaleString() : '尚无成功握手';
    }
    if (this.wgState.lastHandshake <= 0) { return '尚无成功握手'; }
    const scope = (this.wgState.profileIds || []).length > 1 ? '组内最近握手 ' : '最近握手 ';
    return scope + new Date(this.wgState.lastHandshake).toLocaleString();
  }
  private wgRules(id: string): string { return this.wgRuleCounts[this.wireguard.findIndex((p: ProfileMeta): boolean => p.id === id)] || ''; }
  private legacyLabel(): string {
    if (!this.legacyEnabled && !this.legacyView.active) { return '未启用'; }
    return this.legacyView.label + (this.legacyView.label === '已连接' && this.legacyView.mode === '组合连接' ? ' · 组合内运行' : '');
  }
  private newConnection(): void {
    if (this.locked()) { return; }
    this.getUIContext().getPromptAction().showActionMenu({ title: '新建连接', buttons: [
      { text: 'Tailnet · Tailscale / Headscale', color: BLUE }, { text: 'WireGuard · 导入或粘贴配置', color: '#148269' }
    ] }).then(result => {
      this.refreshStatus(); if (this.locked()) { return; }
      router.pushUrl({ url: result.index === 0 ? 'pages/TunnelEditorPage' : 'pages/WireGuardEditorPage' });
    }).catch(() => {});
  }
  private wgWant(session: string, ids: string[], direct: boolean = false): Want {
    return { bundleName: this.context().abilityInfo.bundleName, abilityName: VPN_ABILITY,
      parameters: { wireguardSession: session, wireguardProfiles: ids, wireguardUseConfigRoutes: direct } };
  }
  private async startWireGuard(item: ConnectionItem): Promise<void> {
    this.refreshStatus(); if (this.locked()) { this.error = '请先断开当前 VPN，再连接 WireGuard。'; return; }
    this.busy = true; this.error = '';
    const session = util.generateRandomUUID(); let requested = false;
    try {
      parseWireGuardConfig(await loadProfileText(this.context(), item.profileId));
      this.refreshStatus();
      if (this.state.active || this.legacy.BackendState !== 'Stopped' || this.wireguardActive) {
        throw new Error('连接状态已变化，请先断开当前 VPN。');
      }
      if (this.wgState.session && this.wgState.phase !== TunnelPhase.Disconnected) {
        try { await vpnExtension.stopVpnExtensionAbility(this.wgWant(this.wgState.session, [])); }
        catch (_) { /* A failed or expired extension may already have stopped. */ }
      }
      this.refreshStatus();
      if (this.state.active || this.legacy.BackendState !== 'Stopped' || this.wireguardActive) {
        throw new Error('连接状态已变化，请先断开当前 VPN。');
      }
      const rules = readProfileRules(this.context().filesDir, item.profileId);
      if (rules.enabled && !rules.isDefault && !rules.hasContent()) {
        throw new Error('此连接已选择站点分流，但尚无规则。请添加域名或 IP 规则，或在编辑页更改路由方式。');
      }
      const useConfigRoutes = !(rules.enabled && !rules.isDefault);
      const state = new TunnelState(session, TunnelPhase.Starting); state.profileIds = [item.profileId];
      state.useConfigRoutes = useConfigRoutes;
      writeTunnelRequest(this.context().filesDir, state); requested = true;
      await vpnExtension.startVpnExtensionAbility(this.wgWant(session, [item.profileId], useConfigRoutes));
    } catch (e) {
      this.error = (e as Error).message;
      if (requested && readTunnelRequest(this.context().filesDir)?.session === session) { const state = new TunnelState(session, TunnelPhase.Failed, this.error); state.profileIds = [item.profileId]; writeTunnelRequest(this.context().filesDir, state); }
    } finally { this.busy = false; this.refreshStatus(); }
  }
  private async stopWireGuard(): Promise<void> {
    this.refreshStatus(); const previous = this.wgState; this.busy = true; this.error = '';
    try {
      cancelTunnelRecovery(this.context().filesDir, previous.session);
      await vpnExtension.stopVpnExtensionAbility(this.wgWant(previous.session, []));
      if (readTunnelRequest(this.context().filesDir)?.session === previous.session) {
        writeTunnelRequest(this.context().filesDir, new TunnelState(previous.session, TunnelPhase.Disconnected));
      }
    } catch (e) { this.error = (e as Error).message; }
    finally { this.busy = false; this.refreshStatus(); }
  }
  private async stopCurrent(): Promise<void> {
    this.refreshStatus();
    if (this.state.active) { await this.stop(); }
    else if (this.wireguardActive || this.resumeIntent) { await this.stopWireGuard(); }
    else if (this.legacy.BackendState !== 'Stopped') {
      this.busy = true;
      try { await vpnExtension.stopVpnExtensionAbility({ bundleName: this.context().abilityInfo.bundleName, abilityName: 'TailnetVpnAbility' }); writeTailnet(this.context().filesDir, new TailnetStatus()); }
      catch (e) { this.error = (e as Error).message; }
      finally { this.busy = false; this.refreshStatus(); }
    }
  }
  private forgetWireGuard(item: ConnectionItem): void {
    this.getUIContext().getPromptAction().showDialog({ title: '删除 WireGuard 连接？', message: `将移除「${item.name}」及其本机配置和分流规则。`,
      buttons: [{ text: '取消', color: MUTED }, { text: '删除', color: '#BD4242' }]
    }).then(async result => {
      this.refreshStatus(); if (result.index !== 1 || this.locked()) { return; }
      this.busy = true;
      try { await deleteProfile(this.context(), item.profileId); deleteProfileRulesFiles(this.context().filesDir, item.profileId); this.refresh(); }
      catch (e) { this.error = (e as Error).message; }
      finally { this.busy = false; }
    }).catch(() => {});
  }
  private rulesFor(id: string): string { return this.ruleCounts[this.profiles.findIndex((p: NetworkProfile): boolean => p.ID === id)] || '尚未设置规则'; }
  private async toggle(profile: NetworkProfile, enabled: boolean): Promise<void> {
    this.refreshStatus(); if (this.locked()) { return; }
    try {
      const profiles = readNetworkProfiles(this.context().filesDir);
      const current = profiles.find((p: NetworkProfile): boolean => p.ID === profile.ID);
      if (current) { current.Enabled = enabled; saveNetworkProfiles(this.context().filesDir, profiles); this.refresh(); }
    } catch (e) { this.error = (e as Error).message; }
  }
  private async start(): Promise<void> {
    this.refreshStatus();
    if (this.otherActive() || this.state.active || this.busy) { return; }
    this.busy = true; this.error = '';
    const session = util.generateRandomUUID();
    let requested = false;
    let ids: string[] = [];
    let tailnets: string[] = [];
    try {
      ids = selectedMixedWireGuardIds(this.context().filesDir, listProfiles(this.context()));
      tailnets = selectedMixedTailnetIds(this.context().filesDir);
      if (ids.length + tailnets.length === 0) { throw new Error('请先启用至少一条连接。'); }
      for (const id of ids) { parseWireGuardConfig(await loadProfileText(this.context(), id)); }
      this.refreshStatus();
      if (this.otherActive() || this.state.active) { throw new Error('连接状态已变化，请先断开当前 VPN。'); }
      if (this.wgState.session && this.wgState.phase !== TunnelPhase.Disconnected) {
        try { await vpnExtension.stopVpnExtensionAbility(this.wgWant(this.wgState.session, [])); }
        catch (_) { /* An expired extension may already be absent. */ }
      }
      this.refreshStatus();
      if (this.otherActive() || this.state.active) { throw new Error('连接状态已变化，请重试。'); }
      const state = new TunnelState(session, TunnelPhase.Starting);
      state.profileIds = ids; state.tailnetIds = tailnets; state.mixed = true; state.useConfigRoutes = false;
      writeTunnelRequest(this.context().filesDir, state); requested = true;
      await vpnExtension.startVpnExtensionAbility({ bundleName: this.context().abilityInfo.bundleName, abilityName: VPN_ABILITY,
        parameters: { wireguardSession: session, wireguardProfiles: ids, mixedTailnets: tailnets, mixedMode: true } });
    } catch (e) {
      this.error = (e as Error).message;
      if (requested && readTunnelRequest(this.context().filesDir)?.session === session) {
        const failed = new TunnelState(session, TunnelPhase.Failed, this.error);
        failed.profileIds = ids; failed.tailnetIds = tailnets; failed.mixed = true;
        writeTunnelRequest(this.context().filesDir, failed);
      }
    } finally { this.busy = false; this.refreshStatus(); }
  }
  private async stop(): Promise<void> {
    this.busy = true; this.error = '';
    try {
      await vpnExtension.stopVpnExtensionAbility({ bundleName: this.context().abilityInfo.bundleName, abilityName: 'MultiNetworkVpnAbility' });
      this.state = new NetworkStatus(); writeNetworkStatus(this.context().filesDir, this.state);
    } catch (e) { this.error = (e as Error).message; } finally { this.busy = false; }
  }
  private async login(url: string): Promise<void> {
    if (!url.startsWith('https://')) { this.error = '登录地址无效'; return; }
    try { await this.context().startAbility({ action: 'ohos.want.action.viewData', uri: url, entities: ['entity.system.browsable'] }); }
    catch (e) { this.error = (e as Error).message; }
  }
  private openRules(id: string, domains: boolean, kind: string = 'tailnet'): void {
    router.replaceUrl({ url: domains ? 'pages/DomainLibraryPage' : 'pages/CustomRulesPage', params: { profileId: id, profileType: kind } });
  }
  @Builder
  private overview() {
    Column({ space: 12 }) {
      Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center,
        space: { main: LengthMetrics.vp(20), cross: LengthMetrics.vp(16) } }) {
        Column({ space: 7 }) {
          Text('连接概览').fontSize(12).fontColor('#B7C8FF')
          Text(this.overviewStatus()).fontSize(this.contentWidth < 520 ? 20 : 22)
            .fontWeight(FontWeight.Medium).fontColor(Color.White)
        }.alignItems(HorizontalAlign.Start).flexGrow(1).constraintSize({ maxWidth: '100%' })
        Button(this.busy ? '处理中…' : (this.state.active || this.otherActive() ? '断开当前连接' : '连接所选连接'), { type: ButtonType.Normal })
          .fontSize(14).fontColor(BLUE).backgroundColor(Color.White).borderRadius(12).height(44)
          .enabled(!this.busy && (this.state.active || this.otherActive() || this.enabledCount() > 0))
          .onClick(() => { if (this.state.active || this.otherActive()) { this.stopCurrent(); } else { this.start(); } })
      }.width('100%')
      Text(`已保存 ${this.profiles.length + (this.legacyExists ? 1 : 0)} 个 Tailnet · ${this.wireguard.length} 个 WireGuard，按域名与 IP 规则分配流量。`)
        .fontSize(12).lineHeight(19).fontColor('#D4DFFF').width('100%')
    }.padding(this.contentWidth < 520 ? 20 : 24).width('100%').alignItems(HorizontalAlign.Start)
      .borderRadius(22).backgroundColor('#183993')
  }
  @Builder
  private tunnelCard(profile: NetworkProfile) {
    Column({ space: 16 }) {
      Row({ space: 12 }) {
        Text(profile.ControlURL ? 'H' : 'T').fontSize(19).fontWeight(FontWeight.Bold).fontColor(profile.ControlURL ? '#7A4CCB' : BLUE)
          .width(44).height(44).textAlign(TextAlign.Center).backgroundColor(profile.ControlURL ? '#F3EDFF' : '#EDF2FF').borderRadius(14)
        Column({ space: 5 }) {
          Text(profile.Name).fontSize(18).fontWeight(FontWeight.Medium).fontColor(INK).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(profile.ControlURL ? 'Headscale' : 'Tailscale').fontSize(12).fontColor(MUTED)
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: profile.Enabled !== false }).selectedColor(BLUE)
          .enabled(!this.locked()).onChange((on: boolean) => this.toggle(profile, on)).accessibilityText('启用' + profile.Name)
      }.width('100%')
      Column({ space: 7 }) {
        Text(this.phase(profile)).fontSize(12).fontColor(this.phase(profile) === '已连接' ? '#148269' : MUTED)
          .padding({ left: 10, right: 10, top: 6, bottom: 6 }).backgroundColor(this.phase(profile) === '已连接' ? '#E9F7F0' : '#F0F3F8').borderRadius(8)

        Text(profile.Hostname + (profile.ExitNodeIP ? ' · 出口 ' + profile.ExitNodeIP : ' · 未指定公网出口'))
          .fontSize(13).fontColor(MUTED).maxLines(2)
        Text('下次连接规则 · ' + this.rulesFor(profile.ID)).fontSize(13).fontColor(INK)
        if (this.statusFor(profile.ID).TailscaleIPs.length > 0) {
          Text(this.statusFor(profile.ID).TailscaleIPs.join(' / ')).fontSize(12).fontColor(BLUE)
        }
        if (this.statusFor(profile.ID).ExitNodes.length > 0) {
          Text('可用公网出口 · 长按复制 IP，断开后在编辑中填写').fontSize(12).fontColor(MUTED)
          ForEach(this.statusFor(profile.ID).ExitNodes, (exit: string) => {
            Text(exit).fontSize(12).fontColor(BLUE).copyOption(CopyOptions.LocalDevice)
          })
        }
        if (this.statusFor(profile.ID).Error) { Text(this.statusFor(profile.ID).Error).fontSize(13).fontColor('#B84B4B') }
      }.width('100%').alignItems(HorizontalAlign.Start)
      Divider().color(BORDER)
      Flex({ wrap: FlexWrap.Wrap, space: { main: LengthMetrics.vp(8), cross: LengthMetrics.vp(8) } }) {
        Button('域名库', { type: ButtonType.Normal }).fontSize(13).height(36).backgroundColor('#F1F4FB').fontColor(BLUE).borderRadius(9)
          .onClick(() => this.openRules(profile.ID, true))
        Button('自定义规则', { type: ButtonType.Normal }).fontSize(13).height(36).backgroundColor('#F1F4FB').fontColor(BLUE).borderRadius(9)
          .onClick(() => this.openRules(profile.ID, false))
        Button('管理连接', { type: ButtonType.Normal }).fontSize(13).height(36).backgroundColor(Color.Transparent).fontColor(MUTED).borderRadius(9)
          .enabled(!this.busy).onClick(() => router.pushUrl({ url: 'pages/TunnelEditorPage', params: { profileId: profile.ID } }))
        if (this.statusFor(profile.ID).AuthURL) {
          Button('登录', { type: ButtonType.Normal }).fontSize(13).height(36).backgroundColor(BLUE).fontColor(Color.White).borderRadius(9)
            .onClick(() => this.login(this.statusFor(profile.ID).AuthURL))
        }
      }.width('100%')
    }.width('100%').alignItems(HorizontalAlign.Start).padding(20).backgroundColor(Color.White).borderRadius(20).border({ width: 1, color: BORDER })
  }
  @Builder
  private wireguardCard(item: ConnectionItem) {
    Column({ space: 16 }) {
      Row({ space: 12 }) {
        Text('W').fontSize(19).fontWeight(FontWeight.Bold).fontColor('#148269').width(44).height(44)
          .textAlign(TextAlign.Center).backgroundColor('#E9F7F0').borderRadius(14)
        Column({ space: 5 }) {
          Text(item.name).fontSize(18).fontWeight(FontWeight.Medium).fontColor(INK).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          Text('WireGuard').fontSize(12).fontColor(MUTED)
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.wgEnabled(item.profileId) }).selectedColor('#148269')
          .enabled(!this.locked()).onChange((on: boolean) => this.toggleWireGuard(item.profileId, on))
          .accessibilityText('启用' + item.name)
      }.width('100%')
      Text(this.wgLabel(item.profileId)).fontSize(12).fontColor(this.wgLabel(item.profileId) === '已握手' ? '#148269' : MUTED)
        .padding({ left: 10, right: 10, top: 6, bottom: 6 }).backgroundColor(this.wgLabel(item.profileId) === '已握手' ? '#E9F7F0' : '#F0F3F8').borderRadius(8)
      Text('下次连接规则 · ' + this.wgRules(item.profileId)).fontSize(13).fontColor(MUTED)
      if (this.wgParticipates(item.profileId)) {
        Text(this.wgTraffic(item.profileId)).fontSize(12).fontColor(MUTED).lineHeight(18)
        Text(this.wgHandshake(item.profileId)).fontSize(12).fontColor(MUTED).lineHeight(18)
      }
      if (this.wgState.phase === TunnelPhase.Failed && (this.wgState.profileIds || []).includes(item.profileId)) {
        Text(this.wgState.message).fontSize(13).fontColor('#BD4242')
      }
      Divider().color(BORDER)
      Flex({ wrap: FlexWrap.Wrap, space: { main: LengthMetrics.vp(8), cross: LengthMetrics.vp(8) } }) {
        Button(this.wgParticipates(item.profileId) ? (this.wgState.mixed ? '断开组合' : '断开 WireGuard') : '单独连接', { type: ButtonType.Normal }).height(36).fontSize(13)
          .backgroundColor(this.wgParticipates(item.profileId) ? '#E9F7F0' : BLUE).fontColor(this.wgParticipates(item.profileId) ? '#148269' : Color.White).borderRadius(9)
          .enabled(!this.busy && (this.wgParticipates(item.profileId) || !this.locked()))
          .onClick(() => { if (this.wgParticipates(item.profileId)) { this.stopWireGuard(); } else { this.startWireGuard(item); } })
        Button('编辑', { type: ButtonType.Normal }).height(36).fontSize(13).backgroundColor('#F1F4FB').fontColor(BLUE).borderRadius(9)
          .enabled(!this.locked()).onClick(() => router.pushUrl({ url: 'pages/WireGuardEditorPage', params: { profileId: item.profileId } }))
        Button('PureVPN 配置', { type: ButtonType.Normal }).height(36).fontSize(13).backgroundColor('#E9F7F0').fontColor('#148269').borderRadius(9)
          .enabled(!this.busy).onClick(() => router.pushUrl({ url: 'pages/PureVpnPage', params: { profileId: item.profileId, name: item.name } }))
        Button('域名库', { type: ButtonType.Normal }).height(36).fontSize(13).backgroundColor('#F1F4FB').fontColor(BLUE).borderRadius(9)
          .onClick(() => this.openRules(item.profileId, true, 'wireguard'))
        Button('自定义规则', { type: ButtonType.Normal }).height(36).fontSize(13).backgroundColor('#F1F4FB').fontColor(BLUE).borderRadius(9)
          .onClick(() => this.openRules(item.profileId, false, 'wireguard'))
        Button('删除', { type: ButtonType.Normal }).height(36).fontSize(13).backgroundColor(Color.Transparent).fontColor('#BD4242').borderRadius(9)
          .enabled(!this.locked()).onClick(() => this.forgetWireGuard(item))
      }.width('100%')
    }.width('100%').alignItems(HorizontalAlign.Start).padding(20).backgroundColor(Color.White).borderRadius(20).border({ width: 1, color: BORDER })
  }
  @Builder
  private legacyCard() {
    Column({ space: 14 }) {
      Row({ space: 12 }) {
        Text(this.legacyProfile.ControlURL ? 'H' : 'T').fontSize(19).fontWeight(FontWeight.Bold).fontColor(BLUE).width(44).height(44).textAlign(TextAlign.Center).backgroundColor('#EDF2FF').borderRadius(14)
        Column({ space: 5 }) {
          Text(this.legacyProfile.Name).fontSize(18).fontWeight(FontWeight.Medium).fontColor(INK)
          Text((this.legacyProfile.ControlURL ? 'Headscale' : 'Tailscale') + ' · 保留原有登录').fontSize(12).fontColor(MUTED)
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.legacyEnabled }).selectedColor(BLUE)
          .enabled(!this.locked()).onChange((on: boolean) => this.toggleLegacy(on)).accessibilityText('启用原有 Tailnet 连接')
      }.width('100%')
      Text(this.legacyLabel()).fontSize(13).fontColor(this.legacyLabel().startsWith('已连接') ? '#148269' : MUTED)
      Text(this.legacyProfile.Hostname + (this.legacyProfile.ExitNodeIP ? ' · 出口 ' + this.legacyProfile.ExitNodeIP : ' · 未指定公网出口'))
        .fontSize(13).fontColor(MUTED)
      if (this.statusFor('legacy').TailscaleIPs.length > 0) {
        Text(this.statusFor('legacy').TailscaleIPs.join(' / ')).fontSize(12).fontColor(BLUE)
      }
      if (this.statusFor('legacy').Error) { Text(this.statusFor('legacy').Error).fontSize(13).fontColor('#B84B4B') }
      if (this.statusFor('legacy').AuthURL) {
        Button('登录原有 Tailnet', { type: ButtonType.Normal }).height(36).fontSize(13).fontColor(Color.White).backgroundColor(BLUE)
          .onClick(() => this.login(this.statusFor('legacy').AuthURL))
      }
      Button('管理连接', { type: ButtonType.Normal }).height(36).fontSize(13).fontColor(BLUE).backgroundColor('#EEF2FF').borderRadius(9)
        .enabled(!this.busy).onClick(() => router.pushUrl({ url: 'pages/TunnelEditorPage', params: { profileId: 'legacy' } }))
    }.width('100%').alignItems(HorizontalAlign.Start).padding(20).backgroundColor(Color.White).borderRadius(20).border({ width: 1, color: BORDER })
  }
  @Builder
  private filterButton(label: string, key: string) {
    Button(label, { type: ButtonType.Normal }).height(36).fontSize(13).borderRadius(10)
      .backgroundColor(this.kindFilter === key ? BLUE : Color.White).fontColor(this.kindFilter === key ? Color.White : MUTED)
      .onClick(() => this.kindFilter = key)
  }
  @Builder
  private pageContent() {
    Column() {
      Scroll() {
        Column({ space: 16 }) {
          Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center, justifyContent: FlexAlign.SpaceBetween,
            space: { main: LengthMetrics.vp(12), cross: LengthMetrics.vp(12) } }) {
            Column({ space: 7 }) {
              Text('连接').fontSize(this.contentWidth < 440 ? 26 : 30).fontWeight(FontWeight.Bold).fontColor(INK)
              Text('连接、管理与分配你的网络').fontSize(14).fontColor(MUTED)
            }.alignItems(HorizontalAlign.Start)
            Button('+ 新建', { type: ButtonType.Normal }).height(42).fontSize(14).fontColor(Color.White).backgroundColor(BLUE).borderRadius(12)
              .enabled(!this.locked()).onClick(() => this.newConnection())
          }.width('100%')
          this.overview()
          if (this.recovery.message) {
            Text(this.recovery.message).fontSize(13).lineHeight(20).fontColor('#72541A').width('100%').padding(16).backgroundColor('#FFF7E6').borderRadius(14)
          }
          if (this.error || this.state.error || (this.wgState.phase === TunnelPhase.Failed && this.wgState.message)) {
            Text(this.error || this.state.error || this.wgState.message).fontSize(13).lineHeight(20).fontColor('#B84B4B').width('100%').padding(16).backgroundColor('#FFF0EF').borderRadius(14)
          }
          Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center, justifyContent: FlexAlign.SpaceBetween,
            space: { main: LengthMetrics.vp(16), cross: LengthMetrics.vp(14) } }) {
            Row({ space: 8 }) {
              Text('我的连接').fontSize(18).fontWeight(FontWeight.Medium).fontColor(INK)
              Text(this.allConnections().length.toString()).fontSize(12).fontColor(MUTED)
            }
            if (this.allConnections().length > 0) {
              Search({ value: this.query, placeholder: '搜索名称、类型或服务器' })
                .height(44).width(this.contentWidth >= 600 ? '50%' : '100%').backgroundColor(Color.White)
                .onChange((value: string) => this.query = value)
            }
          }.width('100%')
          if (this.allConnections().length > 0) {
            Row({ space: 8 }) {
              this.filterButton('全部', 'all')
              this.filterButton('Tailnet', 'tailnet')
              this.filterButton('WireGuard', 'wireguard')
            }.width('100%')
            GridRow({ columns: this.contentWidth >= 1250 ? 3 : (this.contentWidth >= 800 ? 2 : 1), gutter: 16 }) {
              ForEach(this.visible(), (item: ConnectionItem) => {
                GridCol() {
                  if (item.kind === 'wireguard') { this.wireguardCard(item) }
                  else if (item.kind === 'legacy') { this.legacyCard() }
                  else { this.tunnelCard(this.tailnetProfile(item.profileId)) }
                }
              }, (item: ConnectionItem): string => item.key())
            }.width('100%')
            if (this.visible().length === 0) { Text('没有找到匹配的连接').fontSize(14).fontColor(MUTED).padding(30) }
          } else {
            Column({ space: 14 }) {
              Image($r('app.media.ic_tunnels')).width(76).height(76).padding(16).backgroundColor('#EEF2FF').borderRadius(20)
              Text('添加第一个连接').fontSize(19).fontWeight(FontWeight.Medium).fontColor(INK)
              Text('添加 Tailscale / Headscale 网络，\n或导入 WireGuard 配置。').fontSize(14).fontColor(MUTED).textAlign(TextAlign.Center).lineHeight(22)
              Button('新建连接', { type: ButtonType.Normal }).height(42).fontSize(14).fontColor(BLUE).backgroundColor('#EEF2FF').borderRadius(12)
                .onClick(() => this.newConnection())
            }.width('100%').padding(32).backgroundColor(Color.White).border({ width: 1, color: BORDER }).borderRadius(20)
          }
          if (this.wireguard.length > 1) {
            Button('WireGuard 多配置分流', { type: ButtonType.Normal }).height(40).fontSize(13).fontColor(BLUE).backgroundColor('#EEF2FF').borderRadius(10)
              .enabled(!this.locked())
              .onClick(() => router.pushUrl({ url: 'pages/Index' }))
          }
        }.width('100%').constraintSize({ maxWidth: 1440 })
          .padding({ left: this.contentWidth < 600 ? 16 : 28, right: this.contentWidth < 600 ? 16 : 28, top: 28, bottom: 28 })
          .alignItems(HorizontalAlign.Start)
          .onAreaChange((_old: Area, area: Area) => {
            const width = Number(area.width);
            if (width > 0 && Math.abs(width - this.contentWidth) > 1) { this.contentWidth = width; }
          })
      }.layoutWeight(1).width('100%').align(Alignment.Top).scrollBar(BarState.Off)
    }.width('100%').height('100%').backgroundColor('#F4F6FA')
  }
  build() {
    Column() {
      WorkspaceShell({ active: 'tunnels', title: '连接' }) { this.pageContent() }
    }.width('100%').height('100%')
  }

}
