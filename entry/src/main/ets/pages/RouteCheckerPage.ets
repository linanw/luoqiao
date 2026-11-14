import { dismissWorkspaceDrawer } from '../model/WorkspaceNavigation';
import { WorkspaceShell } from '../components/WorkspaceShell';
import { common } from '@kit.AbilityKit';
import { router } from '@kit.ArkUI';
import { listProfiles, ProfileMeta } from '../model/ProfileStore';
import { RouteDecision, RouteAddress, RouteCheckResult, RouteCheckRequest,
  requestRouteCheck, readRouteCheckResponse } from '../model/RouteChecker';

const INK: string = '#172033';
const MUTED: string = '#728097';
const BLUE: string = '#315EFB';

@Entry
@Component
struct RouteCheckerPage {
  @State private contentWidth: number = 0;
  onBackPress(): boolean {
    if (dismissWorkspaceDrawer()) { return true; }
    router.replaceUrl({ url: 'pages/NetworksPage' });
    return true;
  }
  @State private target: string = '';
  @State private busy: boolean = false;
  @State private error: string = '';
  @State private result: RouteCheckResult | undefined = undefined;
  @State private checkedAt: string = '';
  private timer: number = -1;
  private request: RouteCheckRequest | undefined;
  private profiles: ProfileMeta[] = [];
  private context(): common.UIAbilityContext { return this.getUIContext().getHostContext() as common.UIAbilityContext; }
  onPageHide(): void { this.cancel(); }
  aboutToDisappear(): void { this.cancel(); }
  private cancel(): void {
    if (this.timer >= 0) { clearInterval(this.timer); this.timer = -1; }
    this.busy = false; this.request = undefined;
  }
  private check(): void {
    this.cancel(); this.error = ''; this.result = undefined;
    try {
      this.profiles = listProfiles(this.context());
      this.request = requestRouteCheck(this.context().filesDir, this.target);
      this.busy = true; this.timer = setInterval(() => this.poll(), 300);
    } catch (e) { this.error = (e as Error).message; }
  }
  private poll(): void {
    const request = this.request; if (!request) { return; }
    try {
      const response = readRouteCheckResponse(this.context().filesDir, request);
      if (response) {
        this.result = response.result; this.error = response.error || response.result?.Error || '';
        this.checkedAt = new Date(response.createdAt).toLocaleTimeString(); this.cancel();
      } else if (Date.now() - request.createdAt > 15000) { throw new Error('检查超时，连接可能正在恢复。请稍后重试。'); }
    } catch (e) { this.error = (e as Error).message; this.cancel(); }
  }
  private owner(decision: RouteDecision): string {
    if (decision.Kind === 'direct') { return '正常网络 · 直连'; }
    if (decision.Kind === 'wireguard') {
      const profile = this.profiles.find((item: ProfileMeta): boolean => item.id === decision.NetworkID);
      return 'WireGuard · ' + (profile?.name || decision.NetworkName || decision.NetworkID);
    }
    if (decision.Kind === 'tailnet') { return 'Tailnet · ' + (decision.NetworkName || decision.NetworkID); }
    if (decision.Kind === 'ambiguous') { return '存在冲突，无法选择连接'; }
    if (decision.Kind === 'unavailable') { return '指定连接当前不可用'; }
    if (decision.Kind === 'dns_required') { return '由解析后的 IP 决定'; }
    return '当前模式无法判断';
  }
  @Builder
  private decision(decision: RouteDecision) {
    Column({ space: 10 }) {
      Text(this.owner(decision)).fontSize(21).fontWeight(FontWeight.Medium).fontColor(INK)
      if (decision.Reason) { Text(decision.Reason).fontSize(14).fontColor(MUTED).lineHeight(22) }
      if (decision.Rule) { Text('匹配规则：' + decision.Rule).fontSize(13).fontColor(MUTED).copyOption(CopyOptions.LocalDevice) }
      if (decision.RawIPMayBypassVPN) {
        Text('直接访问此 IP 时，系统可能优先使用本地 Wi-Fi 路由；应用内选路结果不能保证覆盖系统路由。')
          .fontSize(13).fontColor('#9B661A').lineHeight(21)
      }
    }.alignItems(HorizontalAlign.Start).width('100%')
  }
  @Builder
  private inputCard() {
    Column({ space: 16 }) {
      TextInput({ text: this.target, placeholder: '域名、IP 或网址' })
        .height(52).fontSize(15).maxLength(1024).backgroundColor('#F4F6FA')
        .onChange((value: string) => this.target = value).onSubmit(() => { if (!this.busy) { this.check(); } })
      Button(this.busy ? '正在检查…' : '检查路由', { type: ButtonType.Normal }).width('100%').height(46)
        .fontColor(Color.White).backgroundColor(BLUE).borderRadius(12).enabled(!this.busy && this.target.trim().length > 0)
        .onClick(() => this.check())
      Text('这是选路检查，不会测试网站或服务是否可用。未指定连接的域名需要通过当前网络解析 IP。')
        .fontSize(12).lineHeight(20).fontColor(MUTED).width('100%')
    }.padding(this.contentWidth < 480 ? 16 : 22).backgroundColor(Color.White).borderRadius(20).width(this.contentWidth >= 800 ? '49%' : '100%')
      .margin({ bottom: this.contentWidth >= 800 ? 0 : 20 })
  }
  @Builder
  private resultCard() {
    Column({ space: 18 }) {
      if (this.error) { Text(this.error).fontSize(14).fontColor('#B84B4B').lineHeight(22).width('100%').padding(18).backgroundColor('#FFF0EF').borderRadius(14) }
      if (this.result) {
        Column({ space: 18 }) {
          Text(this.result.Host).fontSize(18).fontWeight(FontWeight.Medium).fontColor(INK).copyOption(CopyOptions.LocalDevice)
          this.decision(this.result.Decision)
          ForEach(this.result.Addresses, (item: RouteAddress) => {
            Column({ space: 12 }) {
              Text(item.IP).fontSize(14).fontColor(BLUE).copyOption(CopyOptions.LocalDevice)
              this.decision(item.Decision)
            }.width('100%').alignItems(HorizontalAlign.Start).padding(16).backgroundColor('#F5F7FB').borderRadius(12)
          }, (item: RouteAddress): string => item.IP)
          if (this.result.DNS.Error) { Text('DNS：' + this.result.DNS.Error).fontSize(13).fontColor('#9B661A').lineHeight(21) }
          ForEach(this.result.Warnings, (warning: string) => {
            Text(warning).fontSize(13).fontColor('#9B661A').lineHeight(21)
          })
          Text('当前连接 · 检查于 ' + this.checkedAt).fontSize(12).fontColor(MUTED)
        }.alignItems(HorizontalAlign.Start).width('100%').padding(this.contentWidth < 480 ? 16 : 22).backgroundColor(Color.White).borderRadius(20)
      }
      if (!this.result && !this.error) {
        Column({ space: 10 }) {
          Text(this.busy ? '正在查找路由' : '等待检查结果').fontSize(18).fontWeight(FontWeight.Medium).fontColor(INK)
          Text('检查后将在这里显示匹配规则、连接与解析地址。').fontSize(14).fontColor(MUTED).lineHeight(22)
        }.width('100%').alignItems(HorizontalAlign.Start).padding(24).backgroundColor(Color.White).borderRadius(20)
      }
    }.width(this.contentWidth >= 800 ? '49%' : '100%').alignItems(HorizontalAlign.Start)
  }
  @Builder
  private pageContent() {
    Column() {
      Scroll() {
        Column({ space: 22 }) {
          Row({ space: 16 }) {
            Button('‹ 返回').fontSize(14).fontColor(BLUE).backgroundColor('#EEF2FF').onClick(() => router.replaceUrl({ url: 'pages/NetworksPage' }))
            Column({ space: 6 }) {
              Text('路由检查').fontSize(this.contentWidth < 600 ? 25 : 28).fontWeight(FontWeight.Bold).fontColor(INK)
              Text('ROUTE CHECKER').fontSize(11).letterSpacing(2).fontColor(MUTED)
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          }.width('100%')
          Text('输入 IP、域名或网址，查看当前连接会使用哪条路由。保存后尚未重新连接的规则不会影响本次结果。')
            .fontSize(14).lineHeight(23).fontColor(MUTED).width('100%')
          Flex({ direction: this.contentWidth >= 800 ? FlexDirection.Row : FlexDirection.Column,
            justifyContent: FlexAlign.SpaceBetween }) {
            this.inputCard()
            this.resultCard()
          }.width('100%')
        }.width('100%').constraintSize({ maxWidth: 1120 }).padding({ left: this.contentWidth < 600 ? 16 : 28, right: this.contentWidth < 600 ? 16 : 28, top: 24, bottom: 40 })
      }.width('100%').layoutWeight(1).align(Alignment.Top)
    }.width('100%').height('100%').backgroundColor('#F5F7FB')
      .onAreaChange((_oldArea: Area, area: Area) => { this.contentWidth = Number(area.width); })
  }

  build() {
    Column() {
      WorkspaceShell({ active: 'checker', title: '路由检查' }) {
        this.pageContent()
      }
    }.width('100%').height('100%')
  }
}
