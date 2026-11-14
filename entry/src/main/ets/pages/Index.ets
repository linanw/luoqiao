import { WorkspaceShell } from '../components/WorkspaceShell';
import { dismissWorkspaceDrawer } from '../model/WorkspaceNavigation';
import { readNetworkStatus } from '../model/NetworkProfiles';
import { readTailnet } from '../model/TailnetState';
import { common, Want } from '@kit.AbilityKit';
import { router } from '@kit.ArkUI';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { picker } from '@kit.CoreFileKit';
import { vpnExtension } from '@kit.NetworkKit';
import {
  createProfile, deleteProfile, listProfiles, loadProfileText, ProfileMeta, ProfileSaveError, readConfigDocument,
  renameProfile, saveProfileText,
} from '../model/ProfileStore';
import { formatEndpoint, parseWireGuardConfig, WireGuardConfig } from '../model/WireGuardConfig';
import { readTunnelState, readTunnelRequest, TunnelPhase, TunnelState, VPN_ABILITY,
  writeTunnelRequest, cancelTunnelRecovery } from '../model/TunnelState';
import {
  collectSplitRules, deleteProfileRulesFiles, ProfileRules, readProfileRules, writeProfileRules
} from '../model/SplitTunnel';
import { dedupeStrings } from '../model/DomainRules';

const INK: string = '#172033';
const MUTED: string = '#728097';
const CANVAS: string = '#F4F6FA';
const ACCENT: string = '#315EFB';
const PAPER: string = '#FFFFFF';
const DANGER: string = '#9E392B';
const STARTUP_TIMEOUT: number = 45000;
const HEARTBEAT_TIMEOUT: number = 12000;

class ProfileSummary {
  id: string;
  name: string;
  role: string;
  peerCount: number;
  endpoints: string;
  addresses: string;
  dns: string;
  siteCount: number;
  invalid: boolean;

  constructor(meta: ProfileMeta, role: string) {
    this.id = meta.id;
    this.name = meta.name;
    this.role = role;
    this.peerCount = 0;
    this.endpoints = '';
    this.addresses = '';
    this.dns = '';
    this.siteCount = 0;
    this.invalid = false;
  }

  roleLabel(): string {
    if (this.role === 'default') {
      return '默认连接 · 未匹配分流规则的流量走此配置';
    }
    if (this.role === 'rule') {
      return `分流连接 · ${this.siteCount.toString()} 个站点`;
    }
    return '未参与 · 连接时不使用此配置';
  }
}

function formatBytes(bytes: number): string {
  if (bytes < 1024) {
    return bytes.toString() + ' B';
  }
  if (bytes < 1048576) {
    return (bytes / 1024).toFixed(1) + ' KB';
  }
  if (bytes < 1073741824) {
    return (bytes / 1048576).toFixed(1) + ' MB';
  }
  return (bytes / 1073741824).toFixed(1) + ' GB';
}

@Entry
@Component
struct Index {
  @State private contentWidth: number = 0;
  onBackPress(): boolean { return dismissWorkspaceDrawer() || this.busy; }
  @State private tunnel: TunnelState = new TunnelState('', TunnelPhase.Disconnected);
  @State private profiles: ProfileSummary[] = [];
  @State private busy: boolean = true;
  @State private editing: boolean = false;
  @State private editingId: string = '';
  @State private draftName: string = '';
  @State private draft: string = '';
  @State private notice: string = '';
  @State private otherVpnActive: boolean = false;

  private timer: number = -1;
  private authorizedAt: number = 0;

  aboutToAppear(): void {
    this.refresh();
    this.loadProfiles();
  }

  aboutToDisappear(): void {
    this.pauseUpdates();
  }

  onPageShow(): void {
    this.refresh();
    this.loadProfiles();
    if (this.timer < 0) {
      this.timer = setInterval(() => this.refresh(), 1000);
    }
  }

  onPageHide(): void {
    this.pauseUpdates();
  }

  private pauseUpdates(): void {
    if (this.timer >= 0) {
      clearInterval(this.timer);
      this.timer = -1;
    }
  }

  private abilityContext(): common.UIAbilityContext {
    const host = this.getUIContext().getHostContext();
    if (host === undefined) {
      throw new Error('无法获取应用上下文。');
    }
    return host as common.UIAbilityContext;
  }

  private sandboxDir(): string {
    return this.abilityContext().filesDir;
  }

  private roleOf(rules: ProfileRules): string {
    if (rules.isDefault) {
      return 'default';
    }
    if (rules.enabled && rules.hasContent()) {
      return 'rule';
    }
    return 'idle';
  }

  private async loadProfiles(): Promise<void> {
    let summaries: ProfileSummary[] = [];
    let failure = '';
    try {
      const directory = this.sandboxDir();
      const metas = listProfiles(this.abilityContext());
      for (const meta of metas) {
        const summary = new ProfileSummary(meta, 'idle');
        const rules = readProfileRules(directory, meta.id);
        summary.role = this.roleOf(rules);
        if (summary.role === 'rule') {
          const collected = collectSplitRules(directory, rules.lists);
          const count = dedupeStrings(collected.rules.domains.concat(collected.rules.exacts)
            .concat(rules.manualDomains)).length;
          summary.siteCount = count + rules.manualCidrs.length;
        }
        try {
          const text = await loadProfileText(this.abilityContext(), meta.id);
          if (text.length === 0) {
            summary.invalid = true;
          } else {
            const config = parseWireGuardConfig(text);
            const endpoints: string[] = [];
            for (const peer of config.peers) {
              if (peer.endpoint !== undefined) {
                endpoints.push(formatEndpoint(peer.endpoint.host, peer.endpoint.port));
              }
            }
            summary.peerCount = config.peers.length;
            summary.endpoints = endpoints.length === 0 ? '等待对端发起连接' : endpoints.join('\n');
            summary.addresses = config.addresses.map(item => item.address + '/' + item.prefixLength).join(' · ');
            summary.dns = config.dns.length > 0 ? config.dns.join(' · ') : '使用系统设置';
          }
        } catch (_) {
          summary.invalid = true;
        }
        summaries.push(summary);
      }
    } catch (_) {
      failure = '无法读取配置列表。';
    }
    this.profiles = summaries;
    this.busy = false;
    if (failure.length > 0) {
      this.notice = failure;
    }
  }

  private refresh(): void {
    this.otherVpnActive = readNetworkStatus(this.sandboxDir()).active ||
      readTailnet(this.sandboxDir()).BackendState !== 'Stopped';
    const state = readTunnelState(this.sandboxDir());
    if (state === undefined) {
      return;
    }
    if (state.session !== this.tunnel.session) {
      this.authorizedAt = 0;
    } else if (this.busy && this.tunnel.phase === TunnelPhase.Stopping) {
      return;
    }
    const now = Date.now();
    if (state.phase === TunnelPhase.Starting) {
      const started = this.authorizedAt || state.updated;
      if (!this.busy && now - started > STARTUP_TIMEOUT) {
        this.tunnel = new TunnelState(state.session, TunnelPhase.Failed, '系统 VPN 启动超时，可以重试。');
        this.tunnel.profileIds = state.profileIds.slice();
        return;
      }
    }
    if ((state.phase === TunnelPhase.Waiting || state.phase === TunnelPhase.Connected) &&
      now - state.updated > HEARTBEAT_TIMEOUT) {
      this.tunnel = new TunnelState(state.session, TunnelPhase.Failed, 'VPN 扩展未响应，可以重试。');
      this.tunnel.profileIds = state.profileIds.slice();
      return;
    }
    this.tunnel = state;
  }

  private participatingIds(): string[] {
    const ids: string[] = [];
    for (const summary of this.profiles) {
      if (summary.role === 'default') {
        ids.push(summary.id);
      }
    }
    for (const summary of this.profiles) {
      if (summary.role === 'rule') {
        ids.push(summary.id);
      }
    }
    return ids;
  }

  private want(session: string, profileIds: string[]): Want {
    return {
      bundleName: this.abilityContext().abilityInfo.bundleName,
      abilityName: VPN_ABILITY,
      parameters: { wireguardSession: session, wireguardProfiles: profileIds },
    };
  }

  private isActive(): boolean {
    return this.tunnel.phase === TunnelPhase.Starting || this.tunnel.phase === TunnelPhase.Waiting ||
      this.tunnel.phase === TunnelPhase.Connected || this.tunnel.phase === TunnelPhase.Stopping;
  }

  private managementLocked(): boolean {
    return this.busy || this.isActive() || this.otherVpnActive;
  }

  private async connect(): Promise<void> {
    this.refresh();
    if (this.busy || this.isActive()) { return; }
    if (this.otherVpnActive) { this.notice = '此页单独运行 WireGuard。需要与 Tailnet 同时使用时，请在连接列表启用所需连接并启动组合。'; return; }
    const profileIds = this.participatingIds();
    if (profileIds.length === 0) {
      this.notice = '请先将一份配置设为默认连接，或在“分流规则”中启用站点。';
      return;
    }
    this.busy = true;
    this.notice = '';
    const previousSession = this.tunnel.session;
    const session = util.generateRandomUUID();
    let startingWritten = false;
    try {
      if (this.tunnel.phase === TunnelPhase.Failed && this.tunnel.session.length > 0) {
        try {
          cancelTunnelRecovery(this.sandboxDir(), this.tunnel.session);
          await vpnExtension.stopVpnExtensionAbility(this.want(this.tunnel.session, []));
        } catch (_) {
          // A stopped or unapproved extension has no active connection.
        }
      }
      this.otherVpnActive = readNetworkStatus(this.sandboxDir()).active ||
        readTailnet(this.sandboxDir()).BackendState !== 'Stopped';
      const current = readTunnelState(this.sandboxDir());
      const anotherSessionActive = current !== undefined && current.session !== previousSession &&
        [TunnelPhase.Starting, TunnelPhase.Waiting, TunnelPhase.Connected, TunnelPhase.Stopping].includes(current.phase);
      if (this.otherVpnActive || anotherSessionActive) {
        if (anotherSessionActive && current !== undefined) { this.tunnel = current; }
        this.notice = '请先在连接列表断开当前 VPN。';
        return;
      }
      this.authorizedAt = 0;
      const state = new TunnelState(session, TunnelPhase.Starting);
      state.profileIds = profileIds.slice(); state.useConfigRoutes = false;
      writeTunnelRequest(this.sandboxDir(), state);
      startingWritten = true;
      this.tunnel = state;
      await vpnExtension.startVpnExtensionAbility(this.want(session, profileIds));
      this.authorizedAt = Date.now();
    } catch (error) {
      const code = (error as BusinessError).code;
      const suffix = typeof code === 'number' ? '（' + code.toString() + '）' : '';
      const state = new TunnelState(session, TunnelPhase.Failed, '无法启动系统 VPN' + suffix + '。');
      state.profileIds = profileIds.slice();
      this.tunnel = state;
      if (startingWritten && readTunnelRequest(this.sandboxDir())?.session === session) {
        try {
          writeTunnelRequest(this.sandboxDir(), state);
        } catch (_) {
          this.notice = '无法保存连接状态。';
        }
      }
    } finally {
      this.busy = false;
    }
  }

  private async disconnect(): Promise<void> {
    this.refresh();
    if (this.busy || !this.isActive()) { return; }
    const previous = this.tunnel;
    const session = previous.session;
    this.busy = true;
    this.notice = '';
    this.tunnel = new TunnelState(session, TunnelPhase.Stopping);
    this.tunnel.profileIds = previous.profileIds.slice();
    try {
      cancelTunnelRecovery(this.sandboxDir(), session);
      await vpnExtension.stopVpnExtensionAbility(this.want(session, []));
      const state = new TunnelState(session, TunnelPhase.Disconnected);
      this.tunnel = state;
      writeTunnelRequest(this.sandboxDir(), state);
    } catch (error) {
      const current = readTunnelState(this.sandboxDir());
      this.tunnel = current?.session === session ? current : previous;
      if (this.tunnel.phase !== TunnelPhase.Disconnected) {
        const code = (error as BusinessError).code;
        this.notice = '无法断开系统 VPN' + (typeof code === 'number' ? '（' + code.toString() + '）' : '') + '。';
      }
    } finally {
      this.busy = false;
    }
  }

  private async openEditor(id: string): Promise<void> {
    this.refresh();
    if (this.managementLocked()) { return; }
    this.busy = true;
    this.notice = '';
    try {
      if (id === '') {
        this.editingId = '';
        this.draftName = '';
        this.draft = '';
      } else {
        this.draft = await loadProfileText(this.abilityContext(), id);
        const summary = this.profiles.find((entry: ProfileSummary): boolean => entry.id === id);
        this.editingId = id;
        this.draftName = summary?.name ?? '';
      }
      this.editing = true;
    } catch (_) {
      this.notice = '无法打开已保存的配置。请重新导入。';
    } finally {
      this.busy = false;
    }
  }

  private closeEditor(): void {
    this.notice = '';
    this.draft = '';
    this.draftName = '';
    this.editingId = '';
    this.editing = false;
  }

  private async chooseFile(): Promise<void> {
    this.refresh();
    if (this.managementLocked()) { return; }
    this.busy = true;
    this.notice = '';
    try {
      const options = new picker.DocumentSelectOptions();
      options.maxSelectNumber = 1;
      options.fileSuffixFilters = ['WireGuard 配置|.conf,.txt'];
      const files = await new picker.DocumentViewPicker(this.abilityContext()).select(options);
      if (files.length > 0) {
        this.draft = await readConfigDocument(files[0]);
        this.editingId = '';
        this.editing = true;
      }
    } catch (_) {
      this.notice = '无法读取所选文件。请选择 UTF-8 编码的 WireGuard 配置（最多 128 KB）。';
    } finally {
      this.busy = false;
    }
  }

  private async saveDraft(): Promise<void> {
    this.refresh();
    if (this.managementLocked()) { this.notice = '请先断开当前 VPN，再保存配置。'; return; }
    this.notice = '';
    const name = this.draftName.trim();
    if (name.length === 0) {
      this.notice = '请填写配置名称。';
      return;
    }
    try {
      parseWireGuardConfig(this.draft);
    } catch (error) {
      this.notice = (error as Error).message;
      return;
    }
    this.busy = true;
    try {
      if (this.editingId === '') {
        const meta = await createProfile(this.abilityContext(), name, this.draft);
        if (!this.profiles.some((summary: ProfileSummary): boolean => summary.role === 'default')) {
          writeProfileRules(this.sandboxDir(), meta.id, new ProfileRules(false, true));
        }
      } else {
        await saveProfileText(this.abilityContext(), this.editingId, this.draft);
        const summary = this.profiles.find((entry: ProfileSummary): boolean => entry.id === this.editingId);
        if (summary === undefined || summary.name !== name) {
          await renameProfile(this.abilityContext(), this.editingId, name);
        }
      }
      this.closeEditor();
      await this.loadProfiles();
    } catch (error) {
      this.notice = error instanceof ProfileSaveError ? error.message : '无法保存配置。';
    } finally {
      this.busy = false;
    }
  }

  private async forgetProfile(id: string): Promise<void> {
    this.refresh();
    if (this.managementLocked()) { return; }
    this.busy = true;
    this.notice = '';
    try {
      await deleteProfile(this.abilityContext(), id);
      deleteProfileRulesFiles(this.sandboxDir(), id);
      await this.loadProfiles();
    } catch (_) {
      this.notice = '无法删除已保存的配置。';
    } finally {
      this.busy = false;
    }
  }

  private confirmForget(summary: ProfileSummary): void {
    this.refresh();
    if (this.managementLocked()) { return; }
    this.getUIContext().getPromptAction().showDialog({
      title: '删除配置？',
      message: `此操作会移除「${summary.name}」及其分流规则。`,
      buttons: [
        { text: '取消', color: MUTED },
        { text: '删除', color: DANGER },
      ],
    }).then(result => {
      this.refresh();
      if (result.index === 1 && !this.managementLocked()) {
        this.forgetProfile(summary.id);
      }
    }).catch(() => {});
  }

  private phaseLabel(): string {
    switch (this.tunnel.phase) {
      case TunnelPhase.Starting: return '正在启动';
      case TunnelPhase.Waiting: return '等待握手';
      case TunnelPhase.Connected: return '连接已启用';
      case TunnelPhase.Stopping: return '正在断开';
      case TunnelPhase.Failed: return '连接异常';
      default: return '未连接';
    }
  }

  private phaseDescription(): string {
    switch (this.tunnel.phase) {
      case TunnelPhase.Starting:
        return this.tunnel.message.length > 0 ? this.tunnel.message : '首次连接时，请在系统提示中授权 VPN。';
      case TunnelPhase.Waiting: return '访问 AllowedIPs 中的目标地址以触发握手。';
      case TunnelPhase.Connected: return '最近握手 ' + new Date(this.tunnel.lastHandshake).toLocaleString();
      case TunnelPhase.Stopping: return '正在释放系统 VPN。';
      case TunnelPhase.Failed: return this.tunnel.message;
      default: return this.profiles.length === 0 ? '导入或粘贴现有 WireGuard 配置。' : '配置已就绪。';
    }
  }

  private actionLabel(): string {
    if (this.tunnel.phase === TunnelPhase.Starting && this.busy) {
      return '正在启动…';
    }
    if (this.tunnel.phase === TunnelPhase.Stopping) {
      return '正在断开…';
    }
    if (this.isActive()) {
      return '断开连接';
    }
    return this.tunnel.phase === TunnelPhase.Failed ? '重新连接' : '连接';
  }

  @Builder
  private heading() {
    Row({ space: 13 }) {
      Stack() {
        Image($r('app.media.app_icon'))
          .width(46)
          .height(46)
          .borderRadius(14)
          .accessibilityLevel('no')
      }
      Column({ space: 1 }) {
        Text('WireGuard').fontSize(this.contentWidth < 480 ? 25 : 28).fontWeight(FontWeight.Bold).fontColor(INK)
        Text('多配置分流').fontSize(13).fontColor(MUTED)
      }.alignItems(HorizontalAlign.Start)
    }.width('100%')
  }

  @Builder
  private tunnelCard() {
    Column({ space: 16 }) {
      Row({ space: 8 }) {
        Row()
          .width(8)
          .height(8)
          .borderRadius(4)
          .backgroundColor(this.tunnel.phase === TunnelPhase.Connected ? '#82E1B1' :
            (this.tunnel.phase === TunnelPhase.Failed ? '#F3AB94' : '#A9C4C0'))
        Text('连接状态').fontSize(13).fontWeight(FontWeight.Medium).fontColor('#C1D9D4')
      }
      Column({ space: 7 }) {
        Text(this.phaseLabel()).fontSize(32).fontWeight(FontWeight.Bold).fontColor(PAPER)
        Text(this.phaseDescription()).fontSize(14).lineHeight(21).fontColor('#C1D9D4')
      }.alignItems(HorizontalAlign.Start).width('100%')
      Divider().color('#3D625D')
      Row() {
        Column({ space: 5 }) {
          Text('发送').fontSize(12).fontColor('#A8C7C0')
          Text(formatBytes(this.tunnel.sentBytes)).fontSize(17).fontWeight(FontWeight.Medium).fontColor(PAPER)
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Column({ space: 5 }) {
          Text('接收').fontSize(12).fontColor('#A8C7C0')
          Text(formatBytes(this.tunnel.receivedBytes)).fontSize(17).fontWeight(FontWeight.Medium).fontColor(PAPER)
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      }.width('100%')
      Button(this.actionLabel(), { type: ButtonType.Normal })
        .borderRadius(15)
        .backgroundColor('#B9F2DA')
        .fontColor('#114237')
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .width('100%')
        .height(49)
        .enabled(!this.busy && (this.isActive() || (!this.otherVpnActive && this.participatingIds().length > 0)))
        .onClick(() => {
          if (this.isActive()) {
            this.disconnect();
          } else {
            this.connect();
          }
        })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(22)
    .backgroundColor('#173E3A')
    .borderRadius(23)
  }

  @Builder
  private detail(label: string, value: string) {
    Column({ space: 4 }) {
      Text(label).fontSize(12).fontColor(MUTED)
      Text(value).fontSize(14).fontColor(INK).lineHeight(20).wordBreak(WordBreak.BREAK_ALL)
    }.alignItems(HorizontalAlign.Start).width('100%')
  }

  @Builder
  private profilesCard() {
    Column({ space: 14 }) {
      Row() {
        Text('连接配置').fontSize(20).fontWeight(FontWeight.Bold).fontColor(INK)
        Blank()
        Button('新增配置', { type: ButtonType.Normal })
          .height(34)
          .borderRadius(11)
          .backgroundColor('#EEF2FF')
          .fontColor(ACCENT)
          .fontSize(13)
          .enabled(!this.managementLocked())
          .onClick(() => this.openEditor(''))
      }.width('100%')
      if (this.profiles.length === 0) {
        Text('可保存多份配置：一份作为默认连接，其余按站点分流。')
          .fontSize(14).lineHeight(21).fontColor(MUTED)
        Row({ space: 10 }) {
          Button('导入文件', { type: ButtonType.Normal })
            .layoutWeight(1).height(43).borderRadius(12).backgroundColor('#EEF2FF').fontColor(ACCENT)
            .enabled(!this.managementLocked())
            .onClick(() => this.chooseFile())
          Button('粘贴配置', { type: ButtonType.Normal })
            .layoutWeight(1).height(43).borderRadius(12).backgroundColor('#EEF2FF').fontColor(ACCENT)
            .enabled(!this.managementLocked())
            .onClick(() => this.openEditor(''))
        }.width('100%')
      }
      ForEach(this.profiles, (summary: ProfileSummary) => {
        Column({ space: 11 }) {
          Text(summary.name).fontSize(16).fontWeight(FontWeight.Bold).fontColor(INK)
          Text(summary.roleLabel()).fontSize(12).lineHeight(17)
            .fontColor(summary.role === 'idle' ? MUTED : ACCENT)
          if (summary.invalid) {
            Text('配置无法解析，请重新编辑或导入。').fontSize(13).fontColor(DANGER)
          } else {
            this.detail('对端（' + summary.peerCount.toString() + '）', summary.endpoints)
            this.detail('本地地址', summary.addresses)
            this.detail('DNS', summary.dns)
          }
          Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.SpaceBetween }) {
            Button('编辑', { type: ButtonType.Normal })
              .width(this.contentWidth < 480 ? '48%' : '31%').height(38).margin({ bottom: 8 }).borderRadius(11).backgroundColor('#EEF2FF')
              .fontColor(ACCENT).fontSize(13)
              .enabled(!this.managementLocked())
              .onClick(() => this.openEditor(summary.id))
            Button('分流规则', { type: ButtonType.Normal })
              .width(this.contentWidth < 480 ? '48%' : '31%').height(38).margin({ bottom: 8 }).borderRadius(11).backgroundColor('#EEF2FF')
              .fontColor(ACCENT).fontSize(13)
              .onClick(() => {
                this.refresh();
                router.pushUrl({
                  url: 'pages/DomainListsPage',
                  params: { profileId: summary.id, profileName: summary.name },
                });
              })
            Button('删除', { type: ButtonType.Normal })
              .width(this.contentWidth < 480 ? '48%' : '31%').height(38).margin({ bottom: 8 }).borderRadius(11).backgroundColor(PAPER)
              .fontColor(DANGER).fontSize(13)
              .enabled(!this.managementLocked())
              .onClick(() => this.confirmForget(summary))
          }.width('100%')
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding(18)
        .backgroundColor(PAPER)
        .borderRadius(20)
      }, (summary: ProfileSummary) => summary.id)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private editorCard() {
    Column({ space: 14 }) {
      Text(this.editingId === '' ? '新增 WireGuard 配置' : '编辑 WireGuard 配置')
        .fontSize(20).fontWeight(FontWeight.Bold).fontColor(INK)
      TextInput({ text: this.draftName, placeholder: '配置名称（例如：办公室、家庭）' })
        .fontSize(14)
        .height(42)
        .width('100%')
        .fontColor(INK)
        .backgroundColor(CANVAS)
        .enabled(!this.managementLocked())
        .onChange((value: string) => { this.draftName = value; })
      TextArea({ text: this.draft, placeholder: '在此粘贴 .conf 内容' })
        .fontSize(14)
        .height(260)
        .width('100%')
        .fontColor(INK)
        .backgroundColor(CANVAS)
        .enabled(!this.managementLocked())
        .autoCapitalizationMode(AutoCapitalizationMode.NONE)
        .onChange((value: string) => { this.draft = value; })
      if (this.notice.length > 0) {
        Text(this.notice).fontSize(14).lineHeight(21).fontColor(DANGER)
      }
      Row({ space: 10 }) {
        Button('导入文件', { type: ButtonType.Normal })
          .layoutWeight(1).height(44).borderRadius(12).backgroundColor('#EEF2FF').fontColor(ACCENT)
          .enabled(!this.managementLocked()).onClick(() => this.chooseFile())
        Button('取消', { type: ButtonType.Normal })
          .layoutWeight(1).height(44).borderRadius(12).backgroundColor('#EEF2FF').fontColor(ACCENT)
          .enabled(!this.busy).onClick(() => this.closeEditor())
      }.width('100%')
      Button(this.editingId === '' ? '保存新配置' : '保存配置', { type: ButtonType.Normal })
        .borderRadius(12)
        .backgroundColor(ACCENT)
        .fontColor(PAPER)
        .fontSize(15)
        .fontWeight(FontWeight.Bold)
        .width('100%')
        .height(46)
        .enabled(!this.managementLocked() && this.draft.trim().length > 0 && this.draftName.trim().length > 0)
        .onClick(() => this.saveDraft())
    }.width('100%').constraintSize({ maxWidth: 760 }).alignItems(HorizontalAlign.Start)
      .padding(this.contentWidth < 480 ? 16 : 22).backgroundColor(PAPER).borderRadius(20)
  }

  @Builder
  private pageContent() {
    Scroll() {
      Column({ space: 22 }) {
        this.heading()
        if (this.editing) {
          this.editorCard()
        } else {
          Flex({ direction: this.contentWidth >= 800 ? FlexDirection.Row : FlexDirection.Column,
            justifyContent: FlexAlign.SpaceBetween }) {
            Column({ space: 16 }) {
              this.tunnelCard()
              if (this.notice.length > 0) {
                Text(this.notice).width('100%').fontSize(14).lineHeight(21).fontColor(DANGER)
              }
            }.width(this.contentWidth >= 800 ? '49%' : '100%').alignItems(HorizontalAlign.Start)
              .margin({ bottom: this.contentWidth >= 800 ? 0 : 22 })
            Column() {
              this.profilesCard()
            }.width(this.contentWidth >= 800 ? '49%' : '100%')
          }.width('100%')
        }
      }.width('100%').constraintSize({ maxWidth: 1120 }).alignItems(HorizontalAlign.Start)
        .padding({ left: this.contentWidth < 600 ? 16 : 28, right: this.contentWidth < 600 ? 16 : 28, top: 24, bottom: 28 })
    }.width('100%').height('100%').scrollBar(BarState.Off).backgroundColor(CANVAS).align(Alignment.Top)
      .onAreaChange((_oldArea: Area, area: Area) => { this.contentWidth = Number(area.width); })
  }

  build() {
    Column() {
      WorkspaceShell({ active: 'tunnels', title: 'WireGuard 多配置分流', navigationLocked: this.busy }) {
        this.pageContent()
      }
    }.width('100%').height('100%')
  }
}
