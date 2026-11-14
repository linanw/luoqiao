import { dismissWorkspaceDrawer } from '../model/WorkspaceNavigation';
import { WorkspaceShell } from '../components/WorkspaceShell';
import { common } from '@kit.AbilityKit';
import { router } from '@kit.ArkUI';
import { util } from '@kit.ArkTS';
import { picker } from '@kit.CoreFileKit';
import {
  createProfile, deleteProfile, listProfiles, loadProfileText, MAX_CONFIG_BYTES, ProfileMeta,
  ProfileSaveError, readConfigDocument, renameProfile, saveProfileText,
} from '../model/ProfileStore';
import { readNetworkStatus } from '../model/NetworkProfiles';
import { clearResolvedIps, deleteProfileRulesFiles, readProfileRules, writeProfileRules } from '../model/SplitTunnel';
import { readTailnet } from '../model/TailnetState';
import { readTunnelState, TunnelPhase } from '../model/TunnelState';
import { parseWireGuardConfig } from '../model/WireGuardConfig';

interface WireGuardEditorParams { profileId?: string; }
const INK: string = '#172033';
const MUTED: string = '#728097';
const BLUE: string = '#315EFB';
const BORDER: string = '#E4E9F2';
const DANGER: string = '#BD4242';

@Entry
@Component
struct WireGuardEditorPage {
  @State private contentWidth: number = 0;
  onBackPress(): boolean { return dismissWorkspaceDrawer() || this.busy; }
  @State private profileId: string = '';
  @State private name: string = '';
  @State private draft: string = '';
  @State private showConfig: boolean = true;
  @State private locked: boolean = false;
  @State private busy: boolean = true;
  @State private invalid: boolean = false;
  @State private error: string = '';
  @State private validation: string = '';
  @State private rulesOnly: boolean = false;
  private savedRulesOnly: boolean = false;
  private timer: number = -1;
  private present: boolean = false;

  private context(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  aboutToAppear(): void {
    this.present = true;
    const params = router.getParams() as WireGuardEditorParams;
    this.profileId = params?.profileId || '';
    this.showConfig = this.profileId.length === 0;
    this.refreshLock();
    this.watch();
    this.load();
  }

  onPageShow(): void { this.refreshLock(); this.watch(); }
  onPageHide(): void { this.unwatch(); }
  aboutToDisappear(): void {
    this.present = false;
    this.unwatch();
    this.draft = '';
  }

  private watch(): void {
    this.unwatch();
    this.timer = setInterval(() => this.refreshLock(), 1500);
  }

  private unwatch(): void {
    if (this.timer >= 0) { clearInterval(this.timer); this.timer = -1; }
  }

  private refreshLock(): void {
    try {
      const directory = this.context().filesDir;
      const wireguard = readTunnelState(directory);
      const wireguardActive = wireguard !== undefined && Date.now() - wireguard.updated < 90000 &&
        [TunnelPhase.Starting, TunnelPhase.Waiting, TunnelPhase.Connected, TunnelPhase.Stopping].includes(wireguard.phase);
      this.locked = wireguardActive || readNetworkStatus(directory).active || readTailnet(directory).BackendState !== 'Stopped';
    } catch (_) {
      this.locked = true;
      this.error = '暂时无法读取连接状态，请返回列表后重试。';
    }
  }

  private canEdit(): boolean {
    this.refreshLock();
    if (this.locked) { this.error = '请先断开正在运行的连接，再修改 WireGuard 配置。'; return false; }
    return !this.busy && !this.invalid;
  }

  private async load(): Promise<void> {
    if (!this.profileId) { this.busy = false; return; }
    try {
      const profile = listProfiles(this.context()).find((item: ProfileMeta): boolean => item.id === this.profileId);
      if (!profile) { this.invalid = true; this.error = '此连接已不存在，请返回列表。'; return; }
      this.name = profile.name;
      const rules = readProfileRules(this.context().filesDir, this.profileId);
      this.rulesOnly = rules.enabled && !rules.isDefault;
      this.savedRulesOnly = this.rulesOnly;
      const config = await loadProfileText(this.context(), this.profileId);
      if (!this.present) { return; }
      this.draft = config;
      if (!config) { this.error = '未找到配置内容，请重新导入 WireGuard 配置。'; this.showConfig = true; }
    } catch (_) {
      this.error = '无法读取已保存的配置。请在设备解锁后重试，或重新导入配置。';
    } finally {
      this.busy = false;
    }
  }

  private async importFile(): Promise<void> {
    if (!this.canEdit()) { return; }
    this.busy = true;
    this.error = '';
    try {
      const options = new picker.DocumentSelectOptions();
      options.maxSelectNumber = 1;
      options.fileSuffixFilters = ['WireGuard 配置|.conf,.txt'];
      const files = await new picker.DocumentViewPicker(this.context()).select(options);
      if (files.length === 0 || !this.present) { return; }
      const config = await readConfigDocument(files[0]);
      this.refreshLock();
      if (this.locked || !this.present) { return; }
      this.draft = config;
      this.showConfig = false;
      this.validate();
    } catch (_) {
      this.error = '无法读取所选文件。请选择 UTF-8 编码的 WireGuard 配置（最多 128 KB）。';
    } finally {
      this.busy = false;
    }
  }

  private validate(): boolean {
    this.error = '';
    this.validation = '';
    try {
      const bytes = util.TextEncoder.create().encodeInto(this.draft);
      const size = bytes.length;
      bytes.fill(0);
      if (size === 0 || size > MAX_CONFIG_BYTES) {
        this.error = '配置内容需为 1 字节到 128 KB。';
        return false;
      }
      const config = parseWireGuardConfig(this.draft);
      this.validation = `语法校验通过 · ${config.peers.length} 个对端 · ${config.addresses.length} 个本机地址`;
      return true;
    } catch (error) {
      // The parser reports field names and line numbers, never configuration values.
      this.error = (error as Error).message;
      return false;
    }
  }

  private async save(): Promise<void> {
    if (!this.canEdit()) { return; }
    const name = this.name.trim();
    if (!name || name.length > 64 || /[\u0000-\u001f\u007f]/.test(name)) {
      this.error = '名称需要 1–64 个字符，且不能含有控制字符。';
      return;
    }
    if (!this.validate()) { return; }
    this.busy = true;
    let savingRules = false;
    try {
      if (this.profileId) {
        await saveProfileText(this.context(), this.profileId, this.draft);
        await renameProfile(this.context(), this.profileId, name);
      } else {
        const profile = await createProfile(this.context(), name, this.draft);
        // Keep the saved identity if writing the routing choice fails, so retrying cannot create a duplicate.
        this.profileId = profile.id;
      }
      if (this.rulesOnly !== this.savedRulesOnly) {
        savingRules = true;
        const directory = this.context().filesDir;
        const rules = readProfileRules(directory, this.profileId);
        rules.enabled = this.rulesOnly;
        if (this.rulesOnly) { rules.isDefault = false; }
        writeProfileRules(directory, this.profileId, rules);
        clearResolvedIps(directory, this.profileId);
        this.savedRulesOnly = this.rulesOnly;
      }
      this.draft = '';
      router.back();
    } catch (error) {
      this.error = savingRules ? '连接配置已保存，但路由方式未能保存。请重试保存；不会重复创建连接。' :
        (error instanceof ProfileSaveError ? error.message : '无法保存连接，请重试。');
    } finally {
      this.busy = false;
    }
  }

  private confirmRemove(): void {
    if (!this.canEdit() || !this.profileId) { return; }
    this.getUIContext().getPromptAction().showDialog({
      title: '删除这条 WireGuard 连接？',
      message: `将删除「${this.name}」的本机配置与分流规则。服务器上的对端配置不会被修改。`,
      buttons: [{ text: '取消', color: MUTED }, { text: '删除连接', color: DANGER }],
    }).then(result => {
      if (result.index === 1) { this.remove(); }
    }).catch(() => {});
  }

  private async remove(): Promise<void> {
    if (!this.canEdit() || !this.profileId) { return; }
    this.busy = true;
    this.error = '';
    try {
      await deleteProfile(this.context(), this.profileId);
      deleteProfileRulesFiles(this.context().filesDir, this.profileId);
      this.draft = '';
      router.back();
    } catch (_) {
      this.error = '未能完全删除连接及其规则，请重试。';
    } finally {
      this.busy = false;
    }
  }

  @Builder
  private fieldLabel(title: string, detail: string) {
    Column({ space: 5 }) {
      Text(title).fontSize(14).fontWeight(FontWeight.Medium).fontColor(INK)
      if (detail) { Text(detail).fontSize(12).lineHeight(18).fontColor(MUTED) }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  private identityCard() {
    Column({ space: 18 }) {
      this.fieldLabel('连接类型', '')
      Text('WireGuard').fontSize(15).fontColor(BLUE).padding({ left: 14, right: 14, top: 10, bottom: 10 })
        .backgroundColor('#EEF2FF').borderRadius(10)
      this.fieldLabel('连接名称', '用于在连接列表和分流规则中识别此连接')
      TextInput({ text: this.name, placeholder: '例如：家庭 WireGuard' })
        .height(48).fontSize(15).backgroundColor('#F5F7FA').borderRadius(12).maxLength(64)
        .enabled(!this.busy && !this.locked && !this.invalid).onChange((value: string) => this.name = value)
    }.width(this.contentWidth >= 800 ? '49%' : '100%').alignItems(HorizontalAlign.Start).padding(this.contentWidth < 480 ? 16 : 22).backgroundColor(Color.White)
      .borderRadius(20).border({ width: 1, color: BORDER }).margin({ bottom: this.contentWidth >= 800 ? 0 : 20 })
  }
  @Builder
  private routingCard() {
    Column({ space: 16 }) {
      this.fieldLabel('路由方式', '选择哪些流量使用这条 WireGuard 连接')
      Button('按配置 AllowedIPs', { type: ButtonType.Normal }).width('100%').height(48).fontSize(15)
        .fontColor(!this.rulesOnly ? BLUE : MUTED).backgroundColor(!this.rulesOnly ? '#EEF2FF' : '#F5F7FA')
        .borderRadius(12).border({ width: 1, color: !this.rulesOnly ? BLUE : BORDER })
        .enabled(!this.busy && !this.locked && !this.invalid)
        .onClick(() => { if (this.canEdit()) { this.rulesOnly = false; } })
      Button('仅选中的站点与 IP', { type: ButtonType.Normal }).width('100%').height(48).fontSize(15)
        .fontColor(this.rulesOnly ? BLUE : MUTED).backgroundColor(this.rulesOnly ? '#EEF2FF' : '#F5F7FA')
        .borderRadius(12).border({ width: 1, color: this.rulesOnly ? BLUE : BORDER })
        .enabled(!this.busy && !this.locked && !this.invalid)
        .onClick(() => { if (this.canEdit()) { this.rulesOnly = true; } })
      Text(this.rulesOnly ?
        '分配给此连接的域名库、自定义域名或 IP 段使用此出口，其余流量按其他连接配置或正常网络处理。支持 TCP / UDP，已匹配的规则连接失败时不会改走直连。保存后可添加规则；没有规则时无法启动。' :
        '使用配置中的 AllowedIPs，不启用分配给此连接的站点规则。组合连接优先处理明确分流规则及 Tailnet 设备、子网；其余流量按 AllowedIPs 路由。0.0.0.0/0 或 ::/0 可作为对应协议的默认出口。')
        .fontSize(13).lineHeight(20).fontColor(MUTED).width('100%')
      if (this.rulesOnly) {
        Text('域名及子域名通过系统 DNS 识别。浏览器安全 DNS（DoH）或旧 DNS 缓存可能绕过识别；若结果异常，请关闭安全 DNS 并重开浏览器。')
          .fontSize(12).lineHeight(18).fontColor(MUTED).width('100%')
      }
    }.width(this.contentWidth >= 800 ? '49%' : '100%').alignItems(HorizontalAlign.Start).padding(this.contentWidth < 480 ? 16 : 22).backgroundColor(Color.White)
      .borderRadius(20).border({ width: 1, color: BORDER })
  }
  @Builder
  private pageContent() {
    Column() {
      Scroll() {
        Column({ space: 22 }) {
          Button('‹ 返回连接', { type: ButtonType.Normal }).fontSize(14).fontColor(BLUE)
            .backgroundColor(Color.Transparent).padding(0).enabled(!this.busy).onClick(() => router.back())
          Column({ space: 8 }) {
            Text(this.profileId ? '编辑 WireGuard 连接' : '新增 WireGuard 连接')
              .fontSize(this.contentWidth < 600 ? 25 : 30).fontWeight(FontWeight.Bold).fontColor(INK)
            Text('导入或粘贴配置，管理这条连接的名称与对端').fontSize(14).fontColor(MUTED)
          }.width('100%').alignItems(HorizontalAlign.Start)
          if (this.locked) {
            Text('有连接正在运行，请先断开后再修改。').fontSize(13).fontColor('#9B6517')
              .padding(16).width('100%').backgroundColor('#FFF5DF').borderRadius(14)
          }
          Button(this.contentWidth < 480 ? 'PureVPN · 获取配置' : 'PureVPN · 选择地区并获取配置', { type: ButtonType.Normal })
            .width('100%').height(48).fontSize(15).fontColor('#14735C').backgroundColor('#E6F5EE').borderRadius(12)
            .enabled(!this.busy && !this.invalid).onClick(() => router.pushUrl({ url: 'pages/PureVpnPage',
              params: { profileId: this.profileId, name: this.name || 'PureVPN' } }))
          Flex({ direction: this.contentWidth >= 800 ? FlexDirection.Row : FlexDirection.Column,
            justifyContent: FlexAlign.SpaceBetween }) {
            this.identityCard()
            this.routingCard()
          }.width('100%')
          Column({ space: 18 }) {
            this.fieldLabel('WireGuard 配置', '支持 .conf / .txt 文件或直接粘贴内容，最多 128 KB。保存时使用系统密钥加密。')
            Flex({ direction: this.contentWidth < 480 ? FlexDirection.Column : FlexDirection.Row,
              justifyContent: FlexAlign.SpaceBetween }) {
              Button('导入配置文件', { type: ButtonType.Normal }).width(this.contentWidth < 480 ? '100%' : '49%').height(44)
                .margin({ bottom: this.contentWidth < 480 ? 10 : 0 }).fontSize(14)
                .fontColor(BLUE).backgroundColor('#EEF2FF').borderRadius(12)
                .enabled(!this.busy && !this.locked && !this.invalid).onClick(() => this.importFile())
              Button(this.showConfig ? '收起配置内容' : '查看或粘贴配置', { type: ButtonType.Normal })
                .width(this.contentWidth < 480 ? '100%' : '49%').height(44).fontSize(14).fontColor(MUTED).backgroundColor('#F1F4F8').borderRadius(12)
                .enabled(!this.busy && !this.locked && !this.invalid).onClick(() => this.showConfig = !this.showConfig)
            }.width('100%')
            if (this.showConfig) {
              TextArea({ text: this.draft, placeholder: '在此粘贴完整的 WireGuard .conf 内容' })
                .fontSize(14).height(300).width('100%').fontColor(INK).backgroundColor('#F5F7FA').borderRadius(12)
                .autoCapitalizationMode(AutoCapitalizationMode.NONE).maxLength(MAX_CONFIG_BYTES)
                .enabled(!this.busy && !this.locked && !this.invalid)
                .onChange((value: string) => { this.draft = value; this.validation = ''; })
            } else {
              Text(this.draft ? '配置内容已隐藏，保存将保留当前内容。' : '尚未添加配置，请导入文件或粘贴内容。')
                .fontSize(13).fontColor(MUTED).lineHeight(20).width('100%').padding(16)
                .backgroundColor('#F5F7FA').borderRadius(12)
            }
            Button('校验配置', { type: ButtonType.Normal }).height(40).fontSize(14).fontColor(BLUE)
              .backgroundColor('#EEF2FF').borderRadius(10).enabled(!this.busy && !this.locked && !this.invalid)
              .onClick(() => { if (this.canEdit()) { this.validate(); } })
            if (this.validation) { Text(this.validation).fontSize(13).fontColor('#247D61').lineHeight(20).width('100%') }
          }.width('100%').alignItems(HorizontalAlign.Start).padding(this.contentWidth < 480 ? 16 : 22).backgroundColor(Color.White)
            .borderRadius(20).border({ width: 1, color: BORDER })
          if (this.error) { Text(this.error).fontSize(13).fontColor(DANGER).lineHeight(20).width('100%') }
          if (this.profileId) {
            Button('删除连接', { type: ButtonType.Normal }).fontSize(14).fontColor(DANGER)
              .backgroundColor('#FFF0EF').height(44).borderRadius(12)
              .enabled(!this.busy && !this.locked && !this.invalid).onClick(() => this.confirmRemove())
          }
        }.width('100%').constraintSize({ maxWidth: 1120 })
          .padding({ left: this.contentWidth < 600 ? 16 : 28, right: this.contentWidth < 600 ? 16 : 28, top: 24, bottom: 28 }).alignItems(HorizontalAlign.Start)
      }.layoutWeight(1).width('100%').scrollBar(BarState.Off).align(Alignment.Top)
      Row({ space: 12 }) {
        Button('取消', { type: ButtonType.Normal }).layoutWeight(1).height(48).fontSize(15)
          .fontColor(MUTED).backgroundColor('#F1F4F8').borderRadius(12).enabled(!this.busy).onClick(() => router.back())
        Button(this.busy ? '处理中…' : (this.profileId ? '保存修改' : '创建连接'), { type: ButtonType.Normal })
          .layoutWeight(2).height(48).fontSize(15).fontColor(Color.White).backgroundColor(BLUE).borderRadius(12)
          .enabled(!this.busy && !this.locked && !this.invalid).onClick(() => this.save())
      }.width('100%').constraintSize({ maxWidth: 1120 })
        .padding({ left: this.contentWidth < 600 ? 16 : 28, right: this.contentWidth < 600 ? 16 : 28, top: 14, bottom: 18 }).backgroundColor(Color.White)
    }.width('100%').height('100%').backgroundColor('#F4F6FA')
      .onAreaChange((_oldArea: Area, area: Area) => { this.contentWidth = Number(area.width); })
  }

  build() {
    Column() {
      WorkspaceShell({ active: 'tunnels', title: 'WireGuard 连接', navigationLocked: this.busy }) {
        this.pageContent()
      }
    }.width('100%').height('100%')
  }
}
