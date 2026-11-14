import { dismissWorkspaceDrawer } from '../model/WorkspaceNavigation';
import { WorkspaceShell } from '../components/WorkspaceShell';
import { common } from '@kit.AbilityKit';
import { router } from '@kit.ArkUI';
import { connection } from '@kit.NetworkKit';
import { NetworkProfile, NetworkNodeStatus, readNetworkProfiles, readNetworkStatus } from '../model/NetworkProfiles';
import { readLegacyNetworkProfile } from '../model/MixedConnections';
import { readTunnelState } from '../model/TunnelState';
import { ruleConnectionsActive } from '../model/RuleTargets';
import { readTailnetConnectionView } from '../model/TailnetConnectionView';
import { SubnetPreference, SubnetPriority, SubnetSuggestion, normalizeSubnetCIDR, readSubnetPreferences,
  saveSubnetPreferences, collectSubnetSuggestions, visibleSubnetSuggestions } from '../model/SubnetPreferences';

const INK: string = '#172033';
const MUTED: string = '#728097';
const BLUE: string = '#315EFB';
const BORDER: string = '#E4E9F2';

@Entry
@Component
struct SubnetRoutesPage {
  @State private contentWidth: number = 0;
  onBackPress(): boolean {
    if (dismissWorkspaceDrawer()) { return true; }
    router.replaceUrl({ url: 'pages/NetworksPage' });
    return true;
  }
  @State private preferences: SubnetPreference[] = [];
  @State private tailnets: NetworkProfile[] = [];
  @State private suggestions: SubnetSuggestion[] = [];
  @State private cidr: string = '';
  @State private priority: SubnetPriority = 'local';
  @State private tailnetID: string = '';
  @State private locked: boolean = true;
  @State private connected: boolean = false;
  @State private error: string = '';
  @State private notice: string = '';
  @State private query: string = '';
  @State private showSuggestions: boolean = false;
  @State private localNote: string = '';
  private ready: boolean = false;
  private timer: number = -1;
  private localPrefixes: string[] = [];
  private nodeHints: NetworkNodeStatus[] = [];
  private checkingLocal: boolean = false;
  private lastLocalCheck: number = 0;
  private pageEpoch: number = 0;
  private hasRuntimeHints: boolean = false;
  private suggestionKey: string = '';
  private directory(): string { return (this.getUIContext().getHostContext() as common.UIAbilityContext).filesDir; }
  aboutToAppear(): void { this.resume(); }
  onPageShow(): void { this.resume(); }
  onPageHide(): void { this.pause(); }
  aboutToDisappear(): void { this.pause(); }
  private resume(): void {
    this.reload(); this.refresh();
    if (this.timer < 0) { this.timer = setInterval(() => this.refresh(), 2000); }
  }
  private pause(): void { this.pageEpoch++; if (this.timer >= 0) { clearInterval(this.timer); this.timer = -1; } }
  private reload(): void {
    this.ready = false;
    try {
      this.preferences = readSubnetPreferences(this.directory());
      this.tailnets = readNetworkProfiles(this.directory());
      const legacy = readLegacyNetworkProfile(this.directory());
      if (legacy) { this.tailnets.push(legacy); }
      this.ready = true;
    } catch (e) { this.error = (e as Error).message; }
  }
  private refresh(): void {
    try {
      this.locked = !this.ready;
      this.connected = ruleConnectionsActive(this.directory());
      const hints = readTunnelState(this.directory());
      this.hasRuntimeHints = this.connected && hints !== undefined && hints.mixed && Date.now() - hints.updated < 90000;
      if (hints && this.hasRuntimeHints) {
        this.nodeHints = hints.tailnetNodes;
        this.localPrefixes = hints.localPrefixes;
        this.localNote = this.localPrefixes.length > 0 ? '已读取当前本地网络，可从发现列表选择网段。' : '当前未发现 Wi-Fi 或以太网网段，也可手动填写。';
      }
      if (this.nodeHints.length === 0) {
        const multi = readNetworkStatus(this.directory());
        if (multi.active) { this.nodeHints = multi.Nodes || []; }
        else {
          const legacy = readTailnetConnectionView(this.directory(), 'legacy');
          if (legacy.active) { this.nodeHints = [legacy.node]; }
        }
      }
      this.rebuildSuggestions();
      if (!this.hasRuntimeHints && Date.now() - this.lastLocalCheck > 10000) { this.detectLocal(); }
    } catch (e) { this.locked = true; this.error = (e as Error).message; }
  }
  private rebuildSuggestions(): void {
    const key = this.localPrefixes.join('|') + ':' + this.nodeHints.map((node: NetworkNodeStatus): string =>
      node.ID + ':' + (node.SubnetRoutes || []).join(',')).join('|');
    if (key === this.suggestionKey) { return; }
    this.suggestionKey = key;
    this.suggestions = collectSubnetSuggestions(this.localPrefixes, this.nodeHints);
  }
  private async detectLocal(): Promise<void> {
    if (this.checkingLocal) { return; }
    this.checkingLocal = true; this.lastLocalCheck = Date.now();
    const epoch = this.pageEpoch;
    try {
      const net = await connection.getDefaultNet();
      const caps = await connection.getNetCapabilities(net);
      const prefixes: string[] = [];
      if (caps.bearerTypes.includes(connection.NetBearType.BEARER_WIFI) || caps.bearerTypes.includes(connection.NetBearType.BEARER_ETHERNET)) {
        const properties = await connection.getConnectionProperties(net);
        for (const address of properties.linkAddresses || []) {
          const ip = address.address.address;
          if (ip.startsWith('127.') || ip === '::1' || /^fe[89ab]/i.test(ip)) { continue; }
          try { const value = normalizeSubnetCIDR(ip + '/' + address.prefixLength); if (!prefixes.includes(value)) { prefixes.push(value); } }
          catch (_) { /* Some link addresses have no usable subnet prefix yet. */ }
        }
      }
      if (this.pageEpoch === epoch && !this.hasRuntimeHints) {
        this.localPrefixes = prefixes;
        this.localNote = prefixes.length > 0 ? '已读取当前本地网络，可从发现列表选择网段。' : '当前未发现 Wi-Fi 或以太网网段，也可手动填写。';
        this.rebuildSuggestions();
      }
    } catch (_) { if (this.pageEpoch === epoch) { this.localNote = '暂时无法读取本地网段，可手动填写。'; } }
    finally { this.checkingLocal = false; }
  }
  private canSave(): boolean {
    this.refresh();
    if (this.locked) { this.error = '网段偏好尚未完整读取，请刷新后修改。'; return false; }
    return true;
  }
  private save(values: SubnetPreference[]): void {
    saveSubnetPreferences(this.directory(), values);
    this.preferences = readSubnetPreferences(this.directory());
    this.error = ''; this.notice = '已保存，下次连接生效。';
  }
  private add(): void {
    if (!this.canSave()) { return; }
    try {
      const current = readSubnetPreferences(this.directory());
      current.push(new SubnetPreference(normalizeSubnetCIDR(this.cidr), this.priority, this.priority === 'tailnet' ? this.tailnetID : undefined));
      this.save(current); this.cidr = '';
    } catch (e) { this.error = (e as Error).message; }
  }
  private update(item: SubnetPreference, priority: SubnetPriority, target: string = ''): void {
    if (!this.canSave()) { return; }
    try {
      const current = readSubnetPreferences(this.directory());
      const index = current.findIndex((value: SubnetPreference): boolean => value.CIDR === item.CIDR);
      if (index < 0) { throw new Error('此网段已被移除，请刷新后重试。'); }
      current[index] = new SubnetPreference(item.CIDR, priority, priority === 'tailnet' ? target : undefined);
      this.save(current);
    } catch (e) { this.error = (e as Error).message; }
  }
  private remove(item: SubnetPreference): void {
    if (!this.canSave()) { return; }
    try { this.save(readSubnetPreferences(this.directory()).filter((value: SubnetPreference): boolean => value.CIDR !== item.CIDR)); }
    catch (e) { this.error = (e as Error).message; }
  }
  private options(): SelectOption[] {
    const result: SelectOption[] = [{ value: '自动选择匹配的 Tailnet' }];
    for (const profile of this.tailnets) { result.push({ value: profile.Name + (profile.Enabled === false ? ' · 未启用' : '') }); }
    return result;
  }
  private targetIndex(id: string): number { return id ? Math.max(0, this.tailnets.findIndex((profile: NetworkProfile): boolean => profile.ID === id) + 1) : 0; }
  private targetId(index: number): string { return index > 0 && index <= this.tailnets.length ? this.tailnets[index - 1].ID : ''; }
  private targetName(id: string): string { return id ? (this.tailnets.find((profile: NetworkProfile): boolean => profile.ID === id)?.Name || '已移除的 Tailnet') : '自动选择匹配的 Tailnet'; }
  private visibleSuggestions(): SubnetSuggestion[] { return visibleSubnetSuggestions(this.suggestions, this.query); }
  private suggestionLabel(item: SubnetSuggestion): string {
    const source = item.Local ? '本地网络' : item.OverlapsLocal ? '与本地网段重叠' : 'Tailnet 子网';
    const names = item.TailnetIDs.slice(0, 2).map((id: string): string => this.targetName(id)).join(' / ');
    return source + (names ? ' · ' + names : '');
  }
  @Builder
  private preferenceRow(item: SubnetPreference) {
    Column({ space: 14 }) {
      Row({ space: 10 }) {
        Text(item.CIDR).fontSize(17).fontWeight(FontWeight.Medium).fontColor(INK).copyOption(CopyOptions.LocalDevice).layoutWeight(1)
        Button('删除', { type: ButtonType.Normal }).height(32).fontSize(12).fontColor('#BD4242').backgroundColor(Color.Transparent)
          .enabled(!this.locked).onClick(() => this.remove(item))
      }.width('100%')
      Row({ space: 10 }) {
        Button('优先本地网络', { type: ButtonType.Normal }).layoutWeight(1).height(42).fontSize(14).borderRadius(11)
          .fontColor(item.Priority === 'local' ? BLUE : MUTED).backgroundColor(item.Priority === 'local' ? '#EEF2FF' : '#F5F7FA')
          .enabled(!this.locked).onClick(() => this.update(item, 'local'))
        Button('优先 Tailnet', { type: ButtonType.Normal }).layoutWeight(1).height(42).fontSize(14).borderRadius(11)
          .fontColor(item.Priority === 'tailnet' ? BLUE : MUTED).backgroundColor(item.Priority === 'tailnet' ? '#EEF2FF' : '#F5F7FA')
          .enabled(!this.locked).onClick(() => this.update(item, 'tailnet', item.TailnetID || ''))
      }.width('100%')
      if (item.Priority === 'tailnet') {
        Select(this.options()).selected(this.targetIndex(item.TailnetID || '')).value(this.targetName(item.TailnetID || ''))
          .width('100%').height(44).font({ size: 14 }).fontColor(INK).backgroundColor('#F5F7FA').borderRadius(11)
          .enabled(!this.locked).onSelect((index: number) => this.update(item, 'tailnet', this.targetId(index)))
        Text('指定的 Tailnet 需参与组合连接，并提供此网段的可用路由。').fontSize(12).fontColor(MUTED).lineHeight(18)
      }
    }.width(this.contentWidth >= 800 ? '49%' : '100%').alignItems(HorizontalAlign.Start).padding(this.contentWidth < 480 ? 16 : 20).backgroundColor(Color.White).borderRadius(20).border({ width: 1, color: BORDER }).margin({ bottom: 16 })
  }
  @Builder
  private pageContent() {
    Scroll() {
      Column({ space: 20 }) {
        Button('‹ 返回连接', { type: ButtonType.Normal }).fontSize(14).fontColor(BLUE).backgroundColor(Color.Transparent).padding(0).onClick(() => router.replaceUrl({ url: 'pages/NetworksPage' }))
        Column({ space: 7 }) {
          Text('重叠网段').fontSize(this.contentWidth < 600 ? 25 : 30).fontWeight(FontWeight.Bold).fontColor(INK)
          Text('已保存的域名访问优先级 · 下次连接使用').fontSize(15).fontColor(MUTED)
        }.width('100%').alignItems(HorizontalAlign.Start)
        Column({ space: 10 }) {
          Text('域名经应用 DNS 解析到重叠网段时，按下方偏好分流。MagicDNS 始终使用对应 Tailnet。')
            .fontSize(14).fontColor(INK).lineHeight(22)
          Text('直接输入本地 IP 仍可能由系统优先走 Wi-Fi；应用自带加密 DNS 可能不经过此设置。保存后重新连接生效。')
            .fontSize(13).fontColor(MUTED).lineHeight(21)
          Text('已有站点规则、默认 WireGuard 出口和 MagicDNS 优先于此设置。')
            .fontSize(13).fontColor(MUTED).lineHeight(21)
        }.width('100%').alignItems(HorizontalAlign.Start).padding(20).backgroundColor('#EEF2FF').borderRadius(20)
        if (this.connected && this.ready) {
          Text('当前连接继续使用启动时的网段偏好，可在此修改下次连接配置。保存后手动断开并连接生效，自动恢复不改变当前偏好。').fontSize(13).lineHeight(20).fontColor('#9B6517')
            .width('100%').padding(16).backgroundColor('#FFF5DF').borderRadius(14)
        }
        if (this.error) { Text(this.error).fontSize(13).fontColor('#BD4242').lineHeight(20).width('100%') }
        if (this.notice) { Text(this.notice).fontSize(13).fontColor('#148269').lineHeight(20).width('100%') }
        Column({ space: 14 }) {
          Text('添加网段').fontSize(18).fontWeight(FontWeight.Medium).fontColor(INK)
          TextInput({ text: this.cidr, placeholder: '例如：192.168.72.0/24 或 fd00:1234::/64' })
            .height(48).fontSize(14).backgroundColor('#F5F7FA').borderRadius(12).enabled(!this.locked).onChange((value: string) => this.cidr = value)
          Row({ space: 10 }) {
            Button('优先本地网络', { type: ButtonType.Normal }).layoutWeight(1).height(42).fontSize(14).borderRadius(11)
              .fontColor(this.priority === 'local' ? BLUE : MUTED).backgroundColor(this.priority === 'local' ? '#EEF2FF' : '#F5F7FA')
              .enabled(!this.locked).onClick(() => this.priority = 'local')
            Button('优先 Tailnet', { type: ButtonType.Normal }).layoutWeight(1).height(42).fontSize(14).borderRadius(11)
              .fontColor(this.priority === 'tailnet' ? BLUE : MUTED).backgroundColor(this.priority === 'tailnet' ? '#EEF2FF' : '#F5F7FA')
              .enabled(!this.locked).onClick(() => this.priority = 'tailnet')
          }.width('100%')
          if (this.priority === 'tailnet') {
            Select(this.options()).selected(this.targetIndex(this.tailnetID)).value(this.targetName(this.tailnetID))
              .height(44).width('100%').font({ size: 14 }).fontColor(INK).backgroundColor('#F5F7FA').borderRadius(11)
              .enabled(!this.locked).onSelect((index: number) => this.tailnetID = this.targetId(index))
          }
          Button('保存网段', { type: ButtonType.Normal }).height(44).fontSize(14).fontColor(Color.White).backgroundColor(BLUE).borderRadius(12)
            .enabled(!this.locked && this.cidr.trim().length > 0).onClick(() => this.add())
        }.width('100%').alignItems(HorizontalAlign.Start).padding(this.contentWidth < 480 ? 16 : 22).backgroundColor(Color.White).borderRadius(20).border({ width: 1, color: BORDER })
        Row() {
          Text('下次连接的偏好').fontSize(18).fontWeight(FontWeight.Medium).fontColor(INK).layoutWeight(1)
          Text(this.preferences.length.toString() + ' / 128').fontSize(12).fontColor(MUTED)
        }.width('100%')
        if (this.preferences.length === 0) { Text('尚未设置偏好。只添加需要区分本地与远程访问的网段。').fontSize(14).lineHeight(21).fontColor(MUTED).width('100%').padding(20) }
        Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.SpaceBetween }) {
          ForEach(this.preferences, (item: SubnetPreference) => { this.preferenceRow(item) },
            (item: SubnetPreference): string => item.CIDR + ':' + item.Priority + ':' + (item.TailnetID || ''))
        }.width('100%')
        Column({ space: 14 }) {
          Text('发现的网段').fontSize(18).fontWeight(FontWeight.Medium).fontColor(INK)
          Text(this.localNote || '正在读取本地网络…').fontSize(13).fontColor(MUTED).lineHeight(20)
          Text('Tailnet 子网在连接后可发现；发现结果不会自动保存为偏好。').fontSize(12).fontColor(MUTED).lineHeight(18)
          Button(this.showSuggestions ? '收起发现的网段' : '查看发现的网段', { type: ButtonType.Normal })
            .height(38).fontSize(13).fontColor(BLUE).backgroundColor('#EEF2FF').borderRadius(10).onClick(() => this.showSuggestions = !this.showSuggestions)
          if (this.showSuggestions) {
            Search({ value: this.query, placeholder: '搜索 IPv4 / IPv6 网段' }).height(44).backgroundColor('#F5F7FA').onChange((value: string) => this.query = value)
            Text('最多显示 12 项，本地与重叠网段优先；可搜索其他网段。').fontSize(12).fontColor(MUTED).lineHeight(18)
            ForEach(this.visibleSuggestions(), (item: SubnetSuggestion) => {
              Row({ space: 12 }) {
                Column({ space: 5 }) {
                  Text(item.CIDR).fontSize(14).fontColor(INK).copyOption(CopyOptions.LocalDevice)
                  Text(this.suggestionLabel(item)).fontSize(12).fontColor(MUTED).maxLines(2)
                }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                Button('填入', { type: ButtonType.Normal }).height(34).fontSize(12).fontColor(BLUE).backgroundColor('#EEF2FF').borderRadius(9)
                  .enabled(!this.locked).onClick(() => this.cidr = item.CIDR)
              }.width('100%').padding({ top: 8, bottom: 8 })
            }, (item: SubnetSuggestion): string => item.CIDR)
            if (this.visibleSuggestions().length === 0) { Text('没有匹配的发现结果，可手动填写网段。').fontSize(13).fontColor(MUTED) }
          }
        }.width('100%').alignItems(HorizontalAlign.Start).padding(this.contentWidth < 480 ? 16 : 22).backgroundColor(Color.White).borderRadius(20).border({ width: 1, color: BORDER })
      }.width('100%').constraintSize({ maxWidth: 1120 }).alignItems(HorizontalAlign.Start).padding({ left: this.contentWidth < 600 ? 16 : 28, right: this.contentWidth < 600 ? 16 : 28, top: 24, bottom: 28 })
    }.width('100%').height('100%').backgroundColor('#F4F6FA').scrollBar(BarState.Auto).align(Alignment.Top)
      .onAreaChange((_oldArea: Area, area: Area) => { this.contentWidth = Number(area.width); })
  }

  build() {
    Column() {
      WorkspaceShell({ active: 'subnets', title: '重叠网段' }) {
        this.pageContent()
      }
    }.width('100%').height('100%')
  }
}
