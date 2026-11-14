import { dismissWorkspaceDrawer } from '../model/WorkspaceNavigation';
import { WorkspaceShell } from '../components/WorkspaceShell';
import { common } from '@kit.AbilityKit';
import { router } from '@kit.ArkUI';
import { util } from '@kit.ArkTS';
import { fileIo } from '@kit.CoreFileKit';
import { NetworkProfile, readNetworkProfiles, saveNetworkProfiles } from '../model/NetworkProfiles';
import { deleteProfileRulesFiles } from '../model/SplitTunnel';
import { ipFamily } from '../model/WireGuardConfig';
import { ruleConnectionsActive } from '../model/RuleTargets';
import { readLegacyNetworkProfile, saveLegacyNetworkProfile } from '../model/MixedConnections';
import { TailnetConnectionView, readTailnetConnectionView } from '../model/TailnetConnectionView';

interface EditorParams { profileId?: string; }
const INK: string = '#172033';
const MUTED: string = '#728097';
const BLUE: string = '#315EFB';
const BORDER: string = '#E4E9F2';

@Entry
@Component
struct TunnelEditorPage {
  @State private contentWidth: number = 0;
  onBackPress(): boolean { return dismissWorkspaceDrawer(); }
  @State private profileId: string = '';
  @State private name: string = '';
  @State private control: string = '';
  @State private hostname: string = 'harmony';
  @State private exitIP: string = '';
  @State private headscale: boolean = false;
  @State private participates: boolean = true;
  @State private locked: boolean = false;
  @State private error: string = '';
  @State private exits: string[] = [];
  @State private invalid: boolean = false;
  @State private runtime: TailnetConnectionView = new TailnetConnectionView();
  @State private showDevices: boolean = false;
  private timer: number = -1;
  private context(): common.UIAbilityContext { return this.getUIContext().getHostContext() as common.UIAbilityContext; }
  aboutToAppear(): void {
    const params = router.getParams() as EditorParams;
    this.profileId = params?.profileId || '';
    if (this.profileId) {
      const profile = this.profileId === 'legacy' ? readLegacyNetworkProfile(this.context().filesDir) :
        readNetworkProfiles(this.context().filesDir).find((p: NetworkProfile): boolean => p.ID === this.profileId);
      if (!profile) { this.error = '此连接已不存在，请返回列表。'; this.invalid = true; return; }
      this.name = profile.Name; this.control = profile.ControlURL; this.hostname = profile.Hostname;
      this.exitIP = profile.ExitNodeIP; this.participates = profile.Enabled !== false; this.headscale = this.control.length > 0;
    }
    this.refresh(); this.watch();
  }
  onPageShow(): void { this.refresh(); this.watch(); }
  onPageHide(): void { this.unwatch(); }
  aboutToDisappear(): void { this.unwatch(); }
  private watch(): void { this.unwatch(); this.timer = setInterval(() => this.refresh(), 2000); }
  private unwatch(): void { if (this.timer >= 0) { clearInterval(this.timer); this.timer = -1; } }
  private refresh(): void {
    this.locked = ruleConnectionsActive(this.context().filesDir);
    this.runtime = readTailnetConnectionView(this.context().filesDir, this.profileId);
    if (this.runtime.node.ExitNodes.length > 0) { this.exits = this.runtime.node.ExitNodes.slice(); }
  }
  private async login(): Promise<void> {
    this.refresh(); this.error = '';
    const url = this.runtime.node.AuthURL;
    if (!this.runtime.active || !url.startsWith('https://')) { this.error = '当前没有可用的登录地址，请先在连接列表启动此连接。'; return; }
    try { await this.context().startAbility({ action: 'ohos.want.action.viewData', uri: url, entities: ['entity.system.browsable'] }); }
    catch (e) { this.error = (e as Error).message; }
  }
  private save(): void {
    this.refresh(); if (this.locked || this.invalid) { this.error = '请先断开连接再编辑连接。'; return; }
    this.error = '';
    if (!this.name.trim() || this.name.trim().length > 64) { this.error = '名称需要 1–64 个字符。'; return; }
    if (!/^[a-zA-Z0-9][a-zA-Z0-9-]{0,62}$/.test(this.hostname.trim())) { this.error = '节点名称需为 1–63 位字母、数字或连字符，以字母或数字开头。'; return; }
    if (this.headscale && !/^https:\/\/[^\s/?#@]+(?:\/[^\s?#]*)?$/.test(this.control.trim())) { this.error = '请输入不含账号密码的 HTTPS 控制服务器地址。'; return; }
    if (this.exitIP.trim() && ipFamily(this.exitIP.trim()) === 0) { this.error = '出口节点地址需为有效 IPv4 或 IPv6。'; return; }
    try {
      const profiles = readNetworkProfiles(this.context().filesDir);
      if (!this.profileId && profiles.length >= 16) { throw new Error('最多保存 16 条连接。'); }
      if (profiles.some((p: NetworkProfile): boolean => p.ID !== this.profileId && p.Name === this.name.trim())) { throw new Error('已有同名连接，请换一个名称。'); }
      const current = this.profileId === 'legacy' ? readLegacyNetworkProfile(this.context().filesDir) :
        (this.profileId ? profiles.find((p: NetworkProfile): boolean => p.ID === this.profileId) : new NetworkProfile());
      if (!current) { throw new Error('连接已被删除，请返回列表。'); }
      if (this.profileId && current.ControlURL !== this.control) { throw new Error('连接身份已变化，请返回列表重新打开。'); }
      current.ID = this.profileId || util.generateRandomUUID(); current.Name = this.name.trim(); current.Hostname = this.hostname.trim();
      // Editing retains the original identity namespace and control server.
      if (!this.profileId) { current.ControlURL = this.headscale ? this.control.trim().replace(/\/$/, '') : ''; }
      current.ExitNodeIP = this.exitIP.trim(); current.Enabled = this.participates;
      if (this.profileId === 'legacy') { saveLegacyNetworkProfile(this.context().filesDir, current); }
      else {
        if (!this.profileId) { profiles.push(current); }
        saveNetworkProfiles(this.context().filesDir, profiles);
      }
      router.back();
    } catch (e) { this.error = (e as Error).message; }
  }
  private remove(): void {
    this.getUIContext().getPromptAction().showDialog({ title: '删除这条连接？',
      message: `将删除「${this.name}」的本机配置、分流规则与登录状态。服务器管理后台的设备记录不会被删除。`,
      buttons: [{ text: '取消', color: MUTED }, { text: '删除连接', color: '#BD4242' }]
    }).then(result => {
      if (result.index !== 1) { return; }
      this.refresh(); if (this.locked) { this.error = '连接期间不能删除连接。'; return; }
      if (!/^[a-fA-F0-9-]{8,64}$/.test(this.profileId)) { this.error = '无效的连接标识。'; return; }
      try {
        const profiles = readNetworkProfiles(this.context().filesDir).filter((p: NetworkProfile): boolean => p.ID !== this.profileId);
        saveNetworkProfiles(this.context().filesDir, profiles); deleteProfileRulesFiles(this.context().filesDir, this.profileId);
        const path = this.context().filesDir + '/networks/' + this.profileId;
        if (fileIo.accessSync(path)) { fileIo.rmdirSync(path); }
        router.back();
      } catch (e) { this.error = '删除未完全完成：' + (e as Error).message; }
    }).catch(() => {});
  }
  @Builder
  private fieldLabel(title: string, detail: string) {
    Column({ space: 5 }) {
      Text(title).fontSize(14).fontWeight(FontWeight.Medium).fontColor(INK)
      if (detail) { Text(detail).fontSize(12).lineHeight(18).fontColor(MUTED) }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
  @Builder
  private statusCard() {
    Column({ space: 14 }) {
      Row({ space: 12 }) {
        Text('连接状态').fontSize(15).fontWeight(FontWeight.Medium).fontColor(INK).layoutWeight(1)
        Text(this.runtime.label).fontSize(13).fontColor(this.runtime.label === '已连接' ? '#148269' : MUTED)
          .padding({ left: 10, right: 10, top: 6, bottom: 6 }).backgroundColor(this.runtime.label === '已连接' ? '#E9F7F0' : '#F0F3F8').borderRadius(8)
      }.width('100%')
      Text(this.runtime.active ? this.runtime.mode + ' · 在连接列表统一启停' : '保存后，返回连接列表启用此连接并连接。')
        .fontSize(13).fontColor(MUTED).lineHeight(20)
      if (this.runtime.node.TailscaleIPs.length > 0) {
        this.fieldLabel('设备地址', '')
        Text(this.runtime.node.TailscaleIPs.join(' / ')).fontSize(13).fontColor(BLUE).copyOption(CopyOptions.LocalDevice)
      }
      if (this.runtime.node.DNSSuffix) {
        this.fieldLabel('MagicDNS', '')
        Text(this.runtime.node.DNSSuffix).fontSize(13).fontColor(BLUE).copyOption(CopyOptions.LocalDevice)
      }
      if (this.runtime.node.AuthURL) {
        Button('打开浏览器登录', { type: ButtonType.Normal }).fontSize(14).height(42).fontColor(Color.White).backgroundColor(BLUE).borderRadius(12)
          .onClick(() => this.login())
      }
      if (this.runtime.node.Error) { Text(this.runtime.node.Error).fontSize(13).fontColor('#BD4242').lineHeight(20) }
      if (this.runtime.node.PeerNames.length > 0 || this.runtime.node.SubnetRoutes.length > 0) {
        Divider().color(BORDER)
        Text(`${this.runtime.node.PeerNames.length} 个已知设备 · ${this.runtime.node.SubnetRoutes.length} 条子网路由`)
          .fontSize(13).fontColor(MUTED)
        Button(this.showDevices ? '收起设备与路由' : '查看设备与路由', { type: ButtonType.Normal })
          .height(36).fontSize(13).fontColor(BLUE).backgroundColor('#EEF2FF').borderRadius(10)
          .onClick(() => this.showDevices = !this.showDevices)
        if (this.showDevices) {
          ForEach(this.runtime.node.PeerNames, (peer: string) => {
            Text(peer).fontSize(12).fontColor(INK).copyOption(CopyOptions.LocalDevice).maxLines(2)
          })
          ForEach(this.runtime.node.SubnetRoutes, (route: string) => {
            Text(route).fontSize(12).fontColor(INK).copyOption(CopyOptions.LocalDevice)
          })
        }
      }
    }.width('100%').alignItems(HorizontalAlign.Start).padding(this.contentWidth < 480 ? 16 : 22).backgroundColor(Color.White).borderRadius(20).border({ width: 1, color: BORDER })
  }
  @Builder
  private identityCard() {
    Column({ space: 18 }) {
      this.fieldLabel('网络类型', this.profileId ? '已有连接保留原服务器；更换服务器请新建连接。' : '')
      Row({ space: 12 }) {
        Button('Tailscale', { type: ButtonType.Normal }).layoutWeight(1).height(48).borderRadius(12).fontSize(15)
          .backgroundColor(!this.headscale ? '#EEF2FF' : '#F5F7FA').fontColor(!this.headscale ? BLUE : MUTED)
          .border({ width: 1, color: !this.headscale ? BLUE : BORDER }).onClick(() => this.headscale = false)
        Button('Headscale', { type: ButtonType.Normal }).layoutWeight(1).height(48).borderRadius(12).fontSize(15)
          .backgroundColor(this.headscale ? '#EEF2FF' : '#F5F7FA').fontColor(this.headscale ? BLUE : MUTED)
          .border({ width: 1, color: this.headscale ? BLUE : BORDER }).onClick(() => this.headscale = true)
      }.width('100%').enabled(!this.profileId && !this.locked && !this.invalid)
      this.fieldLabel('连接名称', '用于在列表和分流规则中识别此连接')
      TextInput({ text: this.name, placeholder: '例如：工作网络' }).height(48).fontSize(15).backgroundColor('#F5F7FA').borderRadius(12)
        .maxLength(64).enabled(!this.locked && !this.invalid).onChange((value: string) => this.name = value)
      if (this.headscale) {
        this.fieldLabel('控制服务器', '')
        TextInput({ text: this.control, placeholder: 'https://headscale.example.com' }).height(48).fontSize(15).backgroundColor('#F5F7FA').borderRadius(12)
          .enabled(!this.profileId && !this.locked && !this.invalid).onChange((value: string) => this.control = value)
      }
      this.fieldLabel('节点名称', '这台设备在网络中显示的名称')
      TextInput({ text: this.hostname, placeholder: 'harmony' }).height(48).fontSize(15).backgroundColor('#F5F7FA').borderRadius(12)
        .maxLength(63).enabled(!this.locked && !this.invalid).onChange((value: string) => this.hostname = value)
    }.width(this.contentWidth >= 800 ? '49%' : '100%').alignItems(HorizontalAlign.Start).padding(this.contentWidth < 480 ? 16 : 22).backgroundColor(Color.White).borderRadius(20).border({ width: 1, color: BORDER }).margin({ bottom: this.contentWidth >= 800 ? 0 : 20 })
  }
  @Builder
  private routingCard() {
    Column({ space: 16 }) {
      this.fieldLabel('公网出口 · 可选', '需要通过此连接访问公网网站时，填写出口节点的 Tailnet IP。首次登录后可在网络状态中查看可用出口。')
      TextInput({ text: this.exitIP, placeholder: '例如：100.64.0.10' }).height(48).fontSize(15).backgroundColor('#F5F7FA').borderRadius(12)
        .enabled(!this.locked && !this.invalid).onChange((value: string) => this.exitIP = value)
      ForEach(this.exits, (exit: string) => {
        Button(exit, { type: ButtonType.Normal }).fontSize(13).fontColor(BLUE).backgroundColor('#EEF2FF').borderRadius(10)
          .enabled(!this.locked).onClick(() => this.exitIP = exit.split(' ')[0])
      })
      Divider().color(BORDER)
      Row({ space: 12 }) {
        Column({ space: 5 }) {
          Text('参与连接').fontSize(15).fontColor(INK)
          Text('点击首页连接按钮时启用此连接').fontSize(12).fontColor(MUTED)
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.participates }).selectedColor(BLUE).enabled(!this.locked && !this.invalid)
          .onChange((on: boolean) => this.participates = on)
      }.width('100%')
    }.width(this.contentWidth >= 800 ? '49%' : '100%').alignItems(HorizontalAlign.Start).padding(this.contentWidth < 480 ? 16 : 22).backgroundColor(Color.White).borderRadius(20).border({ width: 1, color: BORDER })
  }
  @Builder
  private pageContent() {
    Column() {
      Scroll() {
        Column({ space: 22 }) {
          Button('‹ 返回连接', { type: ButtonType.Normal }).fontSize(14).fontColor(BLUE).backgroundColor(Color.Transparent).padding(0)
            .onClick(() => router.back())
          Column({ space: 8 }) {
            Text(this.profileId ? 'Tailnet 连接' : '新增 Tailnet 连接').fontSize(this.contentWidth < 600 ? 25 : 30).fontWeight(FontWeight.Bold).fontColor(INK)
            Text(this.profileId ? '管理连接、登录与公网出口' : '选择网络类型，添加一条独立连接').fontSize(14).fontColor(MUTED)
          }.width('100%').alignItems(HorizontalAlign.Start)
          if (this.profileId && !this.invalid) { this.statusCard() }
          if (this.locked) { Text('连接运行中，可查看状态与登录；在连接列表断开后可修改配置。').fontSize(13).fontColor('#9B6517').padding(16).width('100%').backgroundColor('#FFF5DF').borderRadius(14) }
          if (this.profileId === 'legacy') {
            Text('沿用原有登录身份。修改名称或公网出口后，下次组合连接生效。').fontSize(13).fontColor(MUTED).lineHeight(20).width('100%')
          }
          Flex({ direction: this.contentWidth >= 800 ? FlexDirection.Row : FlexDirection.Column,
            justifyContent: FlexAlign.SpaceBetween }) {
            this.identityCard()
            this.routingCard()
          }.width('100%')
          if (this.error) { Text(this.error).fontSize(13).fontColor('#BD4242').lineHeight(20).width('100%') }
          if (this.profileId && this.profileId !== 'legacy') {
            Button('删除连接', { type: ButtonType.Normal }).fontSize(14).fontColor('#BD4242').backgroundColor('#FFF0EF').height(44).borderRadius(12)
              .enabled(!this.locked && !this.invalid).onClick(() => this.remove())
          }
        }.width('100%').constraintSize({ maxWidth: 1120 }).padding({ left: this.contentWidth < 600 ? 16 : 28, right: this.contentWidth < 600 ? 16 : 28, top: 24, bottom: 28 }).alignItems(HorizontalAlign.Start)
      }.layoutWeight(1).width('100%').scrollBar(BarState.Off).align(Alignment.Top)
      Row({ space: 12 }) {
        Button(this.locked ? '返回连接' : '取消', { type: ButtonType.Normal }).layoutWeight(1).height(48).fontSize(15).fontColor(MUTED).backgroundColor('#F1F4F8').borderRadius(12).onClick(() => router.back())
        Button(this.profileId ? '保存修改' : '创建连接', { type: ButtonType.Normal }).layoutWeight(2).height(48).fontSize(15).fontColor(Color.White).backgroundColor(BLUE).borderRadius(12)
          .enabled(!this.locked && !this.invalid).onClick(() => this.save())
      }.width('100%').constraintSize({ maxWidth: 1120 }).padding({ left: this.contentWidth < 600 ? 16 : 28, right: this.contentWidth < 600 ? 16 : 28, top: 14, bottom: 18 }).backgroundColor(Color.White)
    }.width('100%').height('100%').backgroundColor('#F4F6FA')
      .onAreaChange((_oldArea: Area, area: Area) => { this.contentWidth = Number(area.width); })
  }

  build() {
    Column() {
      WorkspaceShell({ active: 'tunnels', title: 'Tailnet 连接' }) {
        this.pageContent()
      }
    }.width('100%').height('100%')
  }
}
