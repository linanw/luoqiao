import { dismissWorkspaceDrawer } from '../model/WorkspaceNavigation';
import { WorkspaceShell } from '../components/WorkspaceShell';
import { common } from '@kit.AbilityKit';
import { router } from '@kit.ArkUI';
import { connection } from '@kit.NetworkKit';
import { readVpnResourceSample, ResourceMetric, VpnDiagnosticRecord } from '../model/VpnDiagnostics';
import { readPublishedTunnelState, readTunnelRequest, TunnelPhase, TunnelState } from '../model/TunnelState';

const INK: string = '#172033';
const MUTED: string = '#728097';
const BLUE: string = '#315EFB';
const SAMPLE_FRESH_MS: number = 90000;
const STATE_FRESH_MS: number = 15000;

@Entry
@Component
struct VpnDiagnosticsPage {
  @State private contentWidth: number = 0;
  onBackPress(): boolean {
    if (dismissWorkspaceDrawer()) { return true; }
    router.replaceUrl({ url: 'pages/NetworksPage' });
    return true;
  }
  @State private sample: VpnDiagnosticRecord | undefined = undefined;
  @State private request: TunnelState | undefined = undefined;
  @State private tunnel: TunnelState | undefined = undefined;
  @State private now: number = Date.now();
  @State private systemVpn: string = '正在读取…';
  private timer: number = -1;
  private networkCheck: number = 0;
  private checkingNetwork: boolean = false;

  private context(): common.UIAbilityContext { return this.getUIContext().getHostContext() as common.UIAbilityContext; }
  aboutToAppear(): void { this.resume(); }
  onPageShow(): void { this.resume(); }
  onPageHide(): void { this.pause(); }
  aboutToDisappear(): void { this.pause(); }
  private resume(): void {
    this.refresh();
    if (this.timer < 0) { this.timer = setInterval(() => this.refresh(), 5000); }
  }
  private pause(): void {
    if (this.timer >= 0) { clearInterval(this.timer); this.timer = -1; }
  }
  private refresh(): void {
    const directory = this.context().filesDir;
    this.sample = readVpnResourceSample(directory);
    this.request = readTunnelRequest(directory);
    this.tunnel = readPublishedTunnelState(directory);
    this.now = Date.now();
    if (this.now - this.networkCheck >= 30000 && !this.checkingNetwork) { this.refreshSystemVpn(); }
  }
  private async refreshSystemVpn(): Promise<void> {
    this.checkingNetwork = true; this.networkCheck = Date.now();
    try {
      const networks = await connection.getAllNets();
      let present = false;
      for (const network of networks) {
        const capabilities = await connection.getNetCapabilities(network);
        if (capabilities.bearerTypes.includes(connection.NetBearType.BEARER_VPN)) { present = true; break; }
      }
      this.systemVpn = present ? '已检测到 VPN' : '未检测到 VPN';
    } catch (_) { this.systemVpn = '暂时无法读取'; }
    finally { this.checkingNetwork = false; }
  }
  private fresh(at: number, maximumAge: number): boolean {
    return Number.isFinite(at) && at > 0 && at <= this.now && this.now - at <= maximumAge;
  }
  private currentSession(): boolean {
    return !!this.sample && !!this.sample.session && this.request?.session === this.sample.session &&
      this.request?.phase === TunnelPhase.Starting && this.tunnel?.session === this.sample.session;
  }
  private recent(): boolean {
    return this.currentSession() && this.fresh(this.sample?.resources?.sampledAt || 0, SAMPLE_FRESH_MS) &&
      this.fresh(this.tunnel?.updated || 0, STATE_FRESH_MS) &&
      (this.tunnel?.phase === TunnelPhase.Starting || this.tunnel?.phase === TunnelPhase.Waiting ||
        this.tunnel?.phase === TunnelPhase.Connected);
  }
  private sampleStatus(): string {
    if (!this.sample?.resources) { return '暂无运行采样'; }
    const sampledAt = this.sample.resources.sampledAt;
    if (!Number.isFinite(sampledAt) || sampledAt <= 0 || sampledAt > this.now) { return '采样时间异常'; }
    if (!this.fresh(sampledAt, SAMPLE_FRESH_MS)) { return '样本已过时'; }
    if (!this.currentSession()) { return '历史会话样本'; }
    if (!this.recent()) { return '尚未确认当前运行状态'; }
    return '近期样本 · 会话状态已更新';
  }
  private sampleTime(): string {
    const at = this.sample?.resources?.sampledAt || 0;
    if (!Number.isFinite(at) || at <= 0) { return '暂无数据'; }
    return new Date(at).toLocaleString();
  }
  private sampleAge(): string {
    const at = this.sample?.resources?.sampledAt || 0;
    if (!Number.isFinite(at) || at <= 0 || at > this.now) { return ''; }
    const seconds = Math.floor((this.now - at) / 1000);
    if (seconds < 60) { return seconds.toString() + ' 秒前'; }
    if (seconds < 3600) { return Math.floor(seconds / 60).toString() + ' 分钟前'; }
    if (seconds < 86400) { return Math.floor(seconds / 3600).toString() + ' 小时前'; }
    return Math.floor(seconds / 86400).toString() + ' 天前';
  }
  private number(metric: ResourceMetric | undefined): string {
    if (!metric?.valid || !Number.isFinite(metric.value) || metric.value < 0) { return '暂无数据'; }
    return Math.round(metric.value).toLocaleString();
  }
  private memory(metric: ResourceMetric | undefined): string {
    if (!metric?.valid || !Number.isFinite(metric.value) || metric.value < 0) { return '暂无数据'; }
    if (metric.value >= 1073741824) { return (metric.value / 1073741824).toFixed(2) + ' GiB'; }
    return (metric.value / 1048576).toFixed(1) + ' MiB';
  }
  private pid(): string {
    const pid = this.sample?.resources?.pid;
    return pid !== undefined && Number.isSafeInteger(pid) && pid > 0 ? pid.toString() : '暂无数据';
  }
  private flows(): string {
    const flows = this.sample?.resources?.activity.activeFlows;
    return flows !== undefined && Number.isSafeInteger(flows) && flows >= 0 ? flows.toLocaleString() : '暂无数据';
  }

  @Builder
  private processCard() {
    Column({ space: 10 }) {
      Text('进程资源').fontSize(18).fontWeight(FontWeight.Medium).fontColor(INK)
      Row({ space: 18 }) {
        Text('进程编号（PID）').fontSize(14).fontColor(MUTED).layoutWeight(1)
        Text(this.pid()).fontSize(19).fontWeight(FontWeight.Medium).fontColor(INK).textAlign(TextAlign.End)
      }.width('100%').padding({ top: 8, bottom: 8 })
      Row({ space: 18 }) {
        Text('进程内存（RSS）').fontSize(14).fontColor(MUTED).layoutWeight(1)
        Text(this.memory(this.sample?.resources?.process.rssBytes))
          .fontSize(19).fontWeight(FontWeight.Medium).fontColor(INK).textAlign(TextAlign.End)
      }.width('100%').padding({ top: 8, bottom: 8 })
      Row({ space: 18 }) {
        Text('打开的句柄（FD）').fontSize(14).fontColor(MUTED).layoutWeight(1)
        Text(this.number(this.sample?.resources?.process.fdCount))
          .fontSize(19).fontWeight(FontWeight.Medium).fontColor(INK).textAlign(TextAlign.End)
      }.width('100%').padding({ top: 8, bottom: 8 })
    }.alignItems(HorizontalAlign.Start).width(this.contentWidth >= 760 ? '49%' : '100%').padding(this.contentWidth < 480 ? 16 : 22).backgroundColor(Color.White).borderRadius(20).margin({ bottom: this.contentWidth >= 760 ? 0 : 20 })
  }
  @Builder
  private engineCard() {
    Column({ space: 10 }) {
      Text('转发引擎资源').fontSize(18).fontWeight(FontWeight.Medium).fontColor(INK)
      Row({ space: 18 }) {
        Text('Go 活跃堆').fontSize(14).fontColor(MUTED).layoutWeight(1)
        Text(this.memory(this.sample?.resources?.go.heapObjectBytes))
          .fontSize(19).fontWeight(FontWeight.Medium).fontColor(INK).textAlign(TextAlign.End)
      }.width('100%').padding({ top: 8, bottom: 8 })
      Row({ space: 18 }) {
        Text('Go 协程数').fontSize(14).fontColor(MUTED).layoutWeight(1)
        Text(this.number(this.sample?.resources?.go.goroutines))
          .fontSize(19).fontWeight(FontWeight.Medium).fontColor(INK).textAlign(TextAlign.End)
      }.width('100%').padding({ top: 8, bottom: 8 })
      Row({ space: 18 }) {
        Text('活动流数').fontSize(14).fontColor(MUTED).layoutWeight(1)
        Text(this.flows()).fontSize(19).fontWeight(FontWeight.Medium).fontColor(INK).textAlign(TextAlign.End)
      }.width('100%').padding({ top: 8, bottom: 8 })
      Text('进程内存包含运行时、缓冲区等资源；Go 活跃堆只是一部分，两者数值不同。')
        .fontSize(13).lineHeight(21).fontColor(MUTED)
    }.alignItems(HorizontalAlign.Start).width(this.contentWidth >= 760 ? '49%' : '100%').padding(this.contentWidth < 480 ? 16 : 22).backgroundColor(Color.White).borderRadius(20)
  }
  @Builder
  private pageContent() {
    Column() {
      Scroll() {
        Column({ space: 22 }) {
          Row({ space: 16 }) {
            Button('‹ 返回').fontSize(14).fontColor(BLUE).backgroundColor('#EEF2FF').onClick(() => router.replaceUrl({ url: 'pages/NetworksPage' }))
            Column({ space: 6 }) {
              Text('运行诊断').fontSize(this.contentWidth < 600 ? 25 : 28).fontWeight(FontWeight.Bold).fontColor(INK)
              Text('连接运行时的资源记录').fontSize(12).fontColor(MUTED)
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          }.width('100%')
          Text('系统网络状态：' + this.systemVpn).fontSize(14).fontColor(MUTED).width('100%')

          Column({ space: 12 }) {
            Text(this.sampleStatus()).fontSize(19).fontWeight(FontWeight.Medium)
              .fontColor(this.recent() ? BLUE : INK)
            Text('最近采样：' + this.sampleTime()).fontSize(14).fontColor(MUTED).lineHeight(22)
            if (this.sampleAge()) { Text(this.sampleAge()).fontSize(12).fontColor(MUTED) }
            Text('连接运行时每 60 秒采样一次。记录反映采样时刻，不能单独证明连接现在仍在运行。')
              .fontSize(13).lineHeight(21).fontColor(MUTED)
          }.alignItems(HorizontalAlign.Start).width('100%').padding(22).backgroundColor(Color.White).borderRadius(20)

          Flex({ direction: this.contentWidth >= 760 ? FlexDirection.Row : FlexDirection.Column,
            justifyContent: FlexAlign.SpaceBetween }) {
            this.processCard()
            this.engineCard()
          }.width('100%')
          Text('关闭此页面不会停止后台 VPN。若系统终止 VPN 进程，需回到应用才能恢复；手动断开的连接不会自动恢复。')
            .fontSize(13).lineHeight(22).fontColor(MUTED).width('100%')
        }.width('100%').constraintSize({ maxWidth: 1120 }).padding({ left: this.contentWidth < 600 ? 16 : 28, right: this.contentWidth < 600 ? 16 : 28, top: 24, bottom: 40 })
      }.width('100%').layoutWeight(1).align(Alignment.Top)
    }.width('100%').height('100%').backgroundColor('#F5F7FB')
      .onAreaChange((_oldArea: Area, area: Area) => { this.contentWidth = Number(area.width); })
  }

  build() {
    Column() {
      WorkspaceShell({ active: 'diagnostics', title: '运行诊断' }) {
        this.pageContent()
      }
    }.width('100%').height('100%')
  }
}
