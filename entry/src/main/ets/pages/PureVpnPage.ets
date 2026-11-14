import { common } from '@kit.AbilityKit';
import { router, LengthMetrics } from '@kit.ArkUI';
import { WorkspaceShell } from '../components/WorkspaceShell';
import { dismissWorkspaceDrawer } from '../model/WorkspaceNavigation';
import { util } from '@kit.ArkTS';
import { connection } from '@kit.NetworkKit';
import { webview } from '@kit.ArkWeb';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { listProfiles } from '../model/ProfileStore';
import { parseWireGuardConfig } from '../model/WireGuardConfig';
import { readTunnelRequest, readTunnelState, TunnelPhase, TunnelState } from '../model/TunnelState';
import { PureVpnApplyTransaction, applyPureVpnConfig, recoverPureVpnApply } from '../model/PureVpnApply';
import { PureVpnProfile, PureVpnStatus, readPureVpnProfile, writePureVpnProfile, markPureVpnActivated,
  markPureVpnRefreshStarted, markPureVpnRefreshPaused, markPureVpnRefreshFailure,
  markPureVpnNeedsOfficialInteraction,
  readPureVpnRecovery, queuedPureVpnRenewalDecision,
  isCombinedVpnSession, PUREVPN_COMBINED_MESSAGE } from '../model/PureVpnProvider';
import { PUREVPN_MEMBER_URL, isPureVpnPage, parsePureVpnWebResult, PureVpnWebCommand } from '../model/PureVpnWeb';
import { createPureVpnDownloadDelegate, PureVpnDownloadCapture } from '../model/PureVpnDownload';

interface PureVpnParams { profileId?: string; name?: string; }
const INK: string = '#172033';
const MUTED: string = '#728097';
const BLUE: string = '#315EFB';
const WORKFLOW_TIMEOUT_MS: number = 120000;

@Entry
@Component
struct PureVpnPage {
  @State private contentWidth: number = 0;
  @State private contentHeight: number = 0;
  @State private controlsExpanded: boolean = true;
  @State private profileId: string = '';
  @State private name: string = 'PureVPN';
  @State private location: string = '';
  @State private locations: string[] = [];
  @State private status: string = '请在下方官网登录并完成真人验证，然后选择国家或城市。';
  @State private error: string = '';
  @State private busy: boolean = false;
  @State private verifying: boolean = false;
  @State private armed: boolean = false;
  @State private autoRenew: boolean = true;
  @State private connectNow: boolean = true;
  @State private pageAddress: string = 'my.purevpn.com';
  @State private hasCandidate: boolean = false;
  @State private hasDownloadedConfig: boolean = false;
  @State private combinedActive: boolean = false;
  @State private recoveryStatus: string = '';
  @State private sessionStatus: string = '官网允许持久保存的登录会话会保留在本机网页存储中。';
  private controller: webview.WebviewController = new webview.WebviewController();
  private script: string = '';
  private attached: boolean = false;
  private pageReady: boolean = false;
  private visible: boolean = false;
  private polling: boolean = false;
  private timer: number = -1;
  private transaction: PureVpnApplyTransaction | undefined = undefined;
  private transactionStarted: number = 0;
  private attemptStarted: number = 0;
  private attemptSession: string = '';
  private metadata: PureVpnProfile | undefined = undefined;
  private candidateMetadata: PureVpnProfile | undefined = undefined;
  private webpageConfig: string = '';
  private baselineConfig: string = '';
  private generatedInThisRun: boolean = false;
  private generationStarted: number = 0;
  private initialized: boolean = false;
  @State private finishing: boolean = false;
  private selectionAttempted: boolean = false;
  private configCommitted: boolean = false;
  private downloadCapture: PureVpnDownloadCapture | undefined = undefined;
  private downloadedConfig: string = '';
  private operationEpoch: number = 0;
  private runId: string = '';
  private observedLocation: string = '';
  private actualAddress: string = '';
  private pageRevision: number = 0;
  private workflowStarted: number = 0;
  private workflowPausedAt: number = 0;
  private officialPageReady: boolean = false;
  private cookieSaving: boolean = false;
  private cookieSavedAt: number = 0;
  private automaticRecoverySession: string = '';

  private context(): common.UIAbilityContext { return this.getUIContext().getHostContext() as common.UIAbilityContext; }

  private combinedSession(state: TunnelState | undefined): boolean {
    return isCombinedVpnSession(state?.mixed, state?.tailnetIds);
  }

  private refreshCombinedState(): boolean {
    const state = readTunnelState(this.context().filesDir);
    const request = readTunnelRequest(this.context().filesDir);
    this.combinedActive = state !== undefined &&
      [TunnelPhase.Starting, TunnelPhase.Waiting, TunnelPhase.Connected, TunnelPhase.Stopping].includes(state.phase) &&
      (this.combinedSession(state) || this.combinedSession(request));
    return this.combinedActive;
  }

  private setTransaction(transaction: PureVpnApplyTransaction): void {
    this.transaction = transaction;
    this.verifying = true;
  }

  private clearTransaction(): void {
    this.transaction = undefined;
    this.verifying = false;
  }

  aboutToAppear(): void {
    this.visible = true;
    this.refreshCombinedState();
    const params = router.getParams() as PureVpnParams;
    this.profileId = params?.profileId || '';
    if (params?.name) { this.name = params.name; }
    try {
      if (this.profileId) {
        this.name = listProfiles(this.context()).find(item => item.id === this.profileId)?.name || this.name;
        this.metadata = readPureVpnProfile(this.context().filesDir, this.profileId);
        if (this.metadata) {
          this.location = this.metadata.location;
          this.autoRenew = this.metadata.autoRenew;
          if (this.metadata.status === PureVpnStatus.Refreshing) {
            this.metadata = markPureVpnRefreshPaused(this.metadata, Date.now());
            writePureVpnProfile(this.context().filesDir, this.metadata);
          }
        }
      }
      this.script = util.TextDecoder.create('utf-8').decodeToString(
        this.context().resourceManager.getRawFileContentSync('purevpn-assistant.js'));
    } catch (_) { this.error = '无法初始化 PureVPN 配置助手，请返回后重试。'; }
    this.recover();
  }
  private async recover(): Promise<void> {
    this.busy = true;
    try {
      await recoverPureVpnApply(this.context());
      if (this.profileId) { this.metadata = readPureVpnProfile(this.context().filesDir, this.profileId); }
      this.initialized = true;
    }
    catch (error) { this.error = (error as Error).message; }
    finally { this.busy = false; this.watch(); }
  }
  onPageShow(): void { this.visible = true; this.refreshCombinedState(); this.watch(); if (this.attached) { this.attachDownloads(); } }
  onPageHide(): void { this.preserveOfficialSession(true); this.visible = false; this.invalidateWorkflow(); this.unwatch(); this.disposeDownloads(); if (!this.finishing) { this.cancelPending(true); } }
  aboutToDisappear(): void { this.preserveOfficialSession(true); this.visible = false; this.invalidateWorkflow(); this.unwatch(); this.disposeDownloads(); if (!this.finishing) { this.cancelPending(true); } this.webpageConfig = ''; this.baselineConfig = ''; }
  onBackPress(): boolean { if (dismissWorkspaceDrawer()) { return true; } if (this.busy || this.transaction || this.finishing) { return true; } return false; }
  private watch(): void { this.unwatch(); this.timer = setInterval(() => this.tick(), 2000); }
  private unwatch(): void { if (this.timer >= 0) { clearInterval(this.timer); this.timer = -1; } }

  private currentOperation(epoch: number, requestedLocation: string): boolean {
    return this.visible && this.operationEpoch === epoch && this.location === requestedLocation;
  }

  private invalidateWorkflow(): void {
    this.operationEpoch++;
    this.runId = '';
    this.armed = false; this.generatedInThisRun = false; this.generationStarted = 0;
    this.workflowStarted = 0; this.workflowPausedAt = 0;
    this.automaticRecoverySession = '';
    this.observedLocation = '';
    this.webpageConfig = ''; this.hasCandidate = false;
    this.disposeDownloads();
  }

  private startWorkflow(): void {
    const baseline = this.webpageConfig;
    this.invalidateWorkflow();
    this.runId = util.generateRandomUUID();
    this.armed = true; this.baselineConfig = baseline;
    this.workflowStarted = Date.now();
    this.selectionAttempted = false;
    if (this.attached && this.visible) { this.attachDownloads(); }
  }

  private pauseWorkflow(): void {
    if (this.armed && this.workflowPausedAt === 0) { this.workflowPausedAt = Date.now(); }
  }

  private resumeWorkflow(): void {
    if (this.workflowPausedAt > 0) {
      const pausedFor = Date.now() - this.workflowPausedAt;
      this.workflowStarted += pausedFor;
      if (this.generationStarted > 0) { this.generationStarted += pausedFor; }
      this.workflowPausedAt = 0;
    }
  }

  // Keep cookie contents within ArkWeb. In particular, do not extract HttpOnly tokens,
  // change cookie lifetimes, or store account passwords in application metadata.
  private async preserveOfficialSession(force: boolean = false): Promise<void> {
    if (!this.attached || !isPureVpnPage(this.actualAddress) || this.cookieSaving ||
      (!force && this.cookieSavedAt > 0 && Date.now() - this.cookieSavedAt < 30000)) { return; }
    this.cookieSaving = true;
    try {
      await webview.WebCookieManager.saveCookieAsync();
      this.cookieSavedAt = Date.now();
      this.sessionStatus = '已保存官网允许持久化的网页数据；会话过期或真人验证仍需你完成。';
    } catch (_) {
      this.sessionStatus = '官网会话暂未完成落盘，退出应用后可能需要重新登录。';
    } finally { this.cookieSaving = false; }
  }

  private needsOfficialInteraction(): void {
    this.officialPageReady = false;
    if (this.metadata?.status === PureVpnStatus.Refreshing || this.metadata?.status === PureVpnStatus.Queued) {
      this.metadata = markPureVpnNeedsOfficialInteraction(this.metadata, Date.now());
      writePureVpnProfile(this.context().filesDir, this.metadata);
    }
  }

  private automaticRecoveryCurrent(): boolean {
    if (!this.automaticRecoverySession) { return true; }
    const state = readTunnelState(this.context().filesDir);
    const observation = readPureVpnRecovery(this.context().filesDir, this.profileId);
    return !this.refreshCombinedState() && state?.session === this.automaticRecoverySession &&
      state.phase === TunnelPhase.Waiting && state.lastHandshake === 0 && !state.networkError &&
      state.profileIds.length === 1 && state.profileIds[0] === this.profileId &&
      observation !== undefined && observation.session === state.session &&
      observation.importedAt === this.metadata?.importedAt && observation.state === 'queued' &&
      Date.now() >= observation.updatedAt && Date.now() - observation.updatedAt <= 30000;
  }

  // ArkWeb history events and getUrl() can lag behind a member-area SPA transition.
  // Read only the top-level address before asking the origin/path-guarded adapter for page data.
  private async currentAddress(epoch: number, requestedLocation: string): Promise<string> {
    if (!this.attached || !this.currentOperation(epoch, requestedLocation) ||
      !isPureVpnPage(this.controller.getUrl())) { return ''; }
    const revision = this.pageRevision;
    const raw = await this.controller.runJavaScript('JSON.stringify(location.href)');
    if (!this.currentOperation(epoch, requestedLocation) || this.pageRevision !== revision) { return ''; }
    let address = JSON.parse(raw) as string;
    if (typeof address === 'string' && address.startsWith('"')) { address = JSON.parse(address) as string; }
    if (typeof address !== 'string' || address.length > 8192 || !isPureVpnPage(address)) {
      this.actualAddress = ''; return '';
    }
    this.actualAddress = address;
    this.pageAddress = address.split('?')[0].split('#')[0];
    return address;
  }

  private async reopen(): Promise<void> {
    await this.cancelPending();
    if (!this.visible || !this.initialized) { return; }
    this.actualAddress = ''; this.pageReady = false;
    this.status = '正在打开 PureVPN 官方会员页…';
    if (this.attached) { this.attachDownloads(); this.controller.loadUrl(PUREVPN_MEMBER_URL); }
  }

  private historyChanged(address: string): void {
    if (address !== this.actualAddress) { this.pageRevision++; }
    this.actualAddress = isPureVpnPage(address) ? address : '';
    this.pageAddress = address.split('?')[0].split('#')[0];
    this.pageReady = !!this.actualAddress;
    if (!isPureVpnPage(address, true)) { this.observedLocation = ''; this.officialPageReady = false; this.pauseWorkflow(); }
    this.preserveOfficialSession();
    this.tick();
  }

  private attachDownloads(): void {
    if (this.downloadCapture) { return; }
    const epoch = this.operationEpoch;
    let stage = 'create';
    try {
      this.downloadCapture = createPureVpnDownloadDelegate(this.context(),
      (): boolean => this.visible && !this.busy && !this.transaction && !this.finishing &&
        this.operationEpoch === epoch && this.pageReady && isPureVpnPage(this.actualAddress, true),
      (text: string): void => {
        if (!this.visible || this.operationEpoch !== epoch) { return; }
        this.downloadedConfig = text; this.hasDownloadedConfig = true;
        // The next inspection confirms the country again before importing this asynchronous download.
        this.status = '已接收官网的 WireGuard 文件，正在核对地区。';
        }, (message: string): void => { this.error = message; });
      stage = 'attach';
      this.controller.setDownloadDelegate(this.downloadCapture.delegate);
    } catch (error) {
      hilog.error(0x0001, 'PureVPN', 'Download initialization failed at %{public}s: %{public}d', stage, (error as BusinessError).code || 0);
      this.downloadCapture?.dispose(); this.downloadCapture = undefined;
      this.error = '无法初始化配置下载，请返回后重试；仍可在网页显示配置后导入。';
    }
  }

  private disposeDownloads(): void {
    this.downloadCapture?.dispose(); this.downloadCapture = undefined;
    this.downloadedConfig = ''; this.hasDownloadedConfig = false;
  }

  private async cancelPending(resumeLater: boolean = false): Promise<void> {
    if (this.finishing) { return; }
    this.finishing = true;
    this.invalidateWorkflow();
    const pending = this.transaction;
    try {
      if (pending) { await pending.rollback(); this.clearTransaction(); this.candidateMetadata = undefined; }
      if (this.metadata?.status === PureVpnStatus.Refreshing) {
        this.metadata = resumeLater ? markPureVpnRefreshPaused(this.metadata, Date.now()) :
          markPureVpnRefreshFailure(this.metadata, Date.now(), true);
        writePureVpnProfile(this.context().filesDir, this.metadata);
      } else if (!resumeLater && this.metadata?.resumeOnOfficialPage) {
        this.metadata.resumeOnOfficialPage = false;
        writePureVpnProfile(this.context().filesDir, this.metadata);
      }
    } catch (error) { this.error = (error as Error).message; this.initialized = false; }
    finally {
      this.clearTransaction(); this.candidateMetadata = undefined; this.finishing = false;
      if (this.visible && this.attached) { this.attachDownloads(); }
    }
  }

  private async execute(action: string): Promise<void> {
    if (!this.attached || !this.pageReady || !this.visible || !this.script || this.busy) { return; }
    const epoch = this.operationEpoch;
    const requestedLocation = this.location;
    const address = await this.currentAddress(epoch, requestedLocation);
    if (!address || !this.currentOperation(epoch, requestedLocation)) { return; }
    if (!isPureVpnPage(address, true)) {
      this.pauseWorkflow();
      this.needsOfficialInteraction();
      this.status = '请在官网完成登录。登录信息直接提交给 PureVPN。';
      if (this.error === '暂时无法读取官网或连接状态，请确认网络后重试。') { this.error = ''; }
      return;
    }
    const revision = this.pageRevision;
    const command: PureVpnWebCommand = { action, location: requestedLocation, runId: this.runId };
    const raw = await this.controller.runJavaScript(this.script.replace('__PUREVPN_COMMAND__', (): string => JSON.stringify(command)));
    if (!this.currentOperation(epoch, requestedLocation) || this.pageRevision !== revision) { return; }
    const afterAddress = await this.currentAddress(epoch, requestedLocation);
    if (!this.currentOperation(epoch, requestedLocation) || afterAddress !== address) { return; }
    const result = parsePureVpnWebResult(raw);
    if (this.error === '暂时无法读取官网或连接状态，请确认网络后重试。') { this.error = ''; }
    if (result.status !== 'configuration') { this.webpageConfig = ''; this.hasCandidate = false; }
    if (result.locations.length > 0) { this.locations = result.locations; }
    this.observedLocation = result.selected;
    if (result.status === 'verification' || result.status === 'login' || result.status === 'session-error') {
      this.pauseWorkflow();
      this.needsOfficialInteraction();
      this.status = result.status === 'verification' ? '请在官网完成真人验证，完成后会继续读取配置。' :
        (result.status === 'session-error' ? '官网会话异常，请在网页重新登录。' : '请在官网完成登录。登录信息直接提交给 PureVPN。');
      return;
    }
    this.officialPageReady = result.locations.length > 0 ||
      ['configuration', 'generating', 'location-selected', 'choosing'].includes(result.status);
    if (this.officialPageReady) { this.preserveOfficialSession(); }
    this.resumeWorkflow();
    if (!this.armed && !this.location && result.selected) { this.location = result.selected; }
    const matchingCountry = !!requestedLocation && result.selected === requestedLocation;
    if (this.armed && this.generatedInThisRun && matchingCountry && this.downloadedConfig &&
      this.downloadedConfig !== this.baselineConfig) {
      await this.importCandidate(this.downloadedConfig, result.selected, epoch);
      return;
    }
    if (result.status === 'configuration') {
      this.webpageConfig = result.config; this.hasCandidate = true;
      if (this.armed && this.generatedInThisRun && matchingCountry && result.config !== this.baselineConfig) {
        await this.importCandidate(result.config, result.selected, epoch);
      } else if (!matchingCountry && requestedLocation) {
        this.status = '官网当前配置的地区尚未确认一致，请选择目标地区后重新生成。';
      } else if (!this.transaction && !this.armed && this.metadata?.status !== PureVpnStatus.Active) {
        this.status = '网页已有 WireGuard 配置。核对地区后可导入官网当前配置。';
      }
    } else if (result.status === 'generating') {
      if (!matchingCountry) {
        this.status = '官网尚未确认目标地区，正在等待地区同步。';
        return;
      }
      this.status = '官网正在生成配置，生成后会自动校验并导入。';
      if (this.generationStarted === 0) { this.generationStarted = Date.now(); }
      this.generatedInThisRun = true;
    } else if (result.status === 'location-selected' || result.status === 'choosing') {
      this.status = this.armed ? '正在选择官网地区、WireGuard 和设备类型…' : '已登录，请选择地区后点击“生成新配置”。';
    } else if (result.status === 'wrong-location') {
      this.status = '官网当前地区与目标地区不同，正在等待地区选择完成。';
    } else if (result.status === 'ambiguous') {
      this.status = '网页同时显示多份配置，请在官网只保留本次要使用的一份。';
    } else if (this.armed) {
      if (!this.selectionAttempted && requestedLocation && result.locations.includes(requestedLocation) && !matchingCountry) {
        this.selectionAttempted = true;
        await this.execute('select');
        return;
      }
      this.status = '正在获取所选地区的 WireGuard 配置，请留在本页。';
    } else if (!this.configCommitted && !this.error &&
      (result.status === 'locations' || result.status === 'choose-location' || result.locations.length > 0)) {
      this.status = '已登录，请选择官网支持的国家／地区，然后点击“生成新配置”。';
    }
  }

  private async importCandidate(text: string, observedCountry: string = this.observedLocation,
    epoch: number = this.operationEpoch): Promise<void> {
    if (!this.initialized || this.busy || this.transaction || !this.visible) { return; }
    if (this.refreshCombinedState()) { this.error = PUREVPN_COMBINED_MESSAGE; return; }
    if (!this.automaticRecoveryCurrent()) { await this.cancelPending(true); return; }
    const requestedLocation = this.location;
    if (!requestedLocation.trim() || observedCountry !== requestedLocation) {
      this.error = '官网尚未确认所选地区，未导入配置。请在官网选择相同地区后重试。'; return;
    }
    if (!this.currentOperation(epoch, requestedLocation)) { return; }
    this.busy = true; this.error = '';
    this.configCommitted = false;
    try {
      const address = await this.currentAddress(epoch, requestedLocation);
      if (!this.currentOperation(epoch, requestedLocation) || !isPureVpnPage(address, true)) { return; }
      if (this.refreshCombinedState()) { this.error = PUREVPN_COMBINED_MESSAGE; return; }
      if (!this.automaticRecoveryCurrent()) { await this.cancelPending(true); return; }
      this.armed = false; this.workflowStarted = 0; this.workflowPausedAt = 0;
      this.generationStarted = 0; this.generatedInThisRun = false;
      parseWireGuardConfig(text);
      this.status = '正在加密保存配置，并保留此连接的域名与 IP 规则…';
      this.transactionStarted = Date.now();
      if (this.metadata) {
        this.metadata.status = PureVpnStatus.NeedsUser;
        this.metadata.resumeOnOfficialPage = false;
        writePureVpnProfile(this.context().filesDir, this.metadata);
      }
      const pending = await applyPureVpnConfig(this.context(), this.profileId, this.name === 'PureVPN' ?
        ('PureVPN ' + observedCountry).slice(0, 64) : this.name, text, this.connectNow);
      this.setTransaction(pending);
      this.downloadedConfig = ''; this.hasDownloadedConfig = false;
      this.candidateMetadata = new PureVpnProfile(pending.profileId, observedCountry, this.transactionStarted, this.autoRenew);
      if (!this.currentOperation(epoch, requestedLocation)) { await this.cancelPending(); return; }
      if (!this.connectNow) {
        this.finishing = true;
        try { await pending.commit(); } finally { this.finishing = false; }
        this.clearTransaction();
        this.configCommitted = true;
        this.metadata = this.candidateMetadata; this.candidateMetadata = undefined;
        this.profileId = this.metadata.profileId;
        writePureVpnProfile(this.context().filesDir, this.metadata);
        this.status = '配置已导入。请尽快连接以激活官网生成的配置。';
      } else { this.status = '新配置已启动，正在验证 WireGuard 握手…'; }
    } catch (error) {
      if (this.transaction) { await this.cancelPending(); }
      this.error = (error as Error).message;
      this.status = this.configCommitted ? '配置已保存，但 PureVPN 关联信息未能保存。请重新打开助手确认。' :
        '配置未完成更新，请检查提示后重试。';
    } finally { this.busy = false; }
  }

  private async tick(): Promise<void> {
    if (this.polling || !this.visible || this.busy || this.finishing || !this.initialized) { return; }
    this.polling = true;
    const tickEpoch = this.operationEpoch;
    try {
      if (!this.visible || this.operationEpoch !== tickEpoch) { return; }
      this.refreshCombinedState();
      const state = readTunnelState(this.context().filesDir);
      const observation = this.profileId ? readPureVpnRecovery(this.context().filesDir, this.profileId) : undefined;
      this.recoveryStatus = '';
      if (observation && observation.importedAt === this.metadata?.importedAt &&
        observation.session === state?.session && Date.now() >= observation.updatedAt &&
        Date.now() - observation.updatedAt <= 30000) {
        if (observation.state === 'queued') {
          this.recoveryStatus = this.combinedActive ? '该连接启动后未完成握手，已记录待处理任务；请先断开组合连接。' :
            '该连接启动后持续未完成握手，已记录恢复任务；留在本页可继续官方流程。';
        } else if (observation.state === 'needs-check') {
          this.recoveryStatus = '检测到此连接异常，需要检查网络、服务端或账号；尚不能确认配置失效，不会自动更换。';
        }
      }
      if (this.transaction) {
        const pending = this.transaction;
        if (!this.combinedActive && !this.combinedSession(state) &&
          state?.session === this.transaction.session && state.phase === TunnelPhase.Connected &&
          state.lastHandshake > this.transactionStarted) {
          this.finishing = true;
          try { await pending.commit(); }
          catch (error) { this.initialized = false; this.candidateMetadata = undefined; throw error as Error; }
          finally { this.clearTransaction(); this.finishing = false; }
          this.configCommitted = true;
          if (this.candidateMetadata) {
            this.metadata = markPureVpnActivated(this.candidateMetadata, state.lastHandshake);
            this.profileId = this.metadata.profileId; this.candidateMetadata = undefined;
            writePureVpnProfile(this.context().filesDir, this.metadata);
          }
          this.status = '已导入并完成 WireGuard 握手。原有站点与 IP 分流规则继续生效。';
        } else if (Date.now() - this.transactionStarted > 90000 || state?.phase === TunnelPhase.Failed) {
          this.finishing = true;
          try { await pending.rollback(); }
          catch (error) { this.initialized = false; throw error as Error; }
          finally { this.clearTransaction(); this.candidateMetadata = undefined; this.finishing = false; }
          if (this.metadata) {
            this.metadata = markPureVpnRefreshFailure(this.metadata, Date.now());
            writePureVpnProfile(this.context().filesDir, this.metadata);
          }
          this.error = '新配置未完成握手，已回退保存的配置。请检查地区、账号和网络后重试。';
        }
        return;
      }
      if (this.armed && this.automaticRecoverySession && !this.automaticRecoveryCurrent()) {
        await this.cancelPending(true);
        this.status = '连接或网络状态已改变，本次自动生成已暂停；会重新核对恢复条件。';
        return;
      }
      if (state && state.session !== this.attemptSession) {
        this.attemptSession = state.session; this.attemptStarted = Date.now();
      }
      if (!this.combinedActive && !this.combinedSession(state) &&
        this.metadata && state && state.profileIds.length === 1 && state.profileIds[0] === this.profileId &&
        this.location === this.metadata.location &&
        Date.now() - state.updated < 15000 && !this.armed) {
        const net = await connection.getDefaultNet();
        if (!this.visible || !this.initialized || this.operationEpoch !== tickEpoch) { return; }
        if (this.refreshCombinedState() || readTunnelState(this.context().filesDir)?.session !== state.session) { return; }
        const decision = queuedPureVpnRenewalDecision(this.metadata, observation,
          { now: Date.now(), profileId: this.profileId, session: state.session,
          phase: state.phase, lastHandshake: state.lastHandshake, attemptStartedAt: observation?.waitingSince || 0,
          physicalNetworkAvailable: net.netId > 0 && !state.networkError, mixed: state.mixed,
          tailnetIds: state.tailnetIds }, this.officialPageReady);
        if (decision.action === 'refresh') {
          this.metadata = markPureVpnRefreshStarted(this.metadata, Date.now());
          writePureVpnProfile(this.context().filesDir, this.metadata);
          this.startWorkflow();
          this.automaticRecoverySession = state.session;
          this.connectNow = true;
          this.status = '连接未能恢复，正在尝试获取新配置；如官网要求验证，请在下方完成。';
          if (this.attached) { this.pageReady = false; this.actualAddress = ''; this.controller.loadUrl(PUREVPN_MEMBER_URL); }
        }
      }
      await this.execute(this.armed ? 'advance' : 'inspect');
      if (this.armed && this.workflowPausedAt === 0 &&
        ((this.workflowStarted > 0 && Date.now() - this.workflowStarted > WORKFLOW_TIMEOUT_MS) ||
        (this.generationStarted > 0 && Date.now() - this.generationStarted > 60000))) {
        this.invalidateWorkflow();
        if (this.attached && this.visible) { this.attachDownloads(); }
        this.status = '官网尚未返回新配置，请查看下方提示并重试。';
        if (this.metadata) {
          this.metadata = markPureVpnRefreshFailure(this.metadata, Date.now(), true);
          writePureVpnProfile(this.context().filesDir, this.metadata);
        }
      }
    } catch (error) {
      this.error = this.initialized ? '暂时无法读取官网或连接状态，请确认网络后重试。' :
        ((error as Error).message || '更新恢复未完成，请返回连接列表检查状态。');
    } finally { this.polling = false; }
  }

  private begin(): void {
    if (!this.initialized || this.busy || this.transaction) { return; }
    if (!this.location.trim()) { this.error = '请先选择地区或填写与官网选择一致的地区备注。'; return; }
    if (this.metadata && !this.refreshCombinedState()) {
      this.metadata = markPureVpnRefreshStarted(this.metadata, Date.now());
      writePureVpnProfile(this.context().filesDir, this.metadata);
    }
    this.startWorkflow(); this.error = '';
    this.status = '正在为所选地区生成 WireGuard 配置…';
    this.pageReady = false; this.actualAddress = '';
    this.controller.loadUrl(PUREVPN_MEMBER_URL);
  }

  private changedLocation(value: string): void {
    this.invalidateWorkflow();
    this.location = value;
    this.error = '';
    if (this.metadata?.status === PureVpnStatus.Refreshing || this.metadata?.resumeOnOfficialPage) {
      this.metadata = markPureVpnRefreshFailure(this.metadata, Date.now(), true);
      writePureVpnProfile(this.context().filesDir, this.metadata);
    }
    if (this.visible && this.attached) { this.attachDownloads(); }
  }

  private async importCurrent(): Promise<void> {
    if (this.busy || this.polling || this.transaction || !this.initialized) { return; }
    this.polling = true;
    const epoch = this.operationEpoch;
    const requestedLocation = this.location;
    try {
      const address = await this.currentAddress(epoch, requestedLocation);
      if (!this.currentOperation(epoch, requestedLocation)) { return; }
      if (!isPureVpnPage(address, true)) { throw new Error('请回到官网的手动配置页面。'); }
      const revision = this.pageRevision;
      const command: PureVpnWebCommand = { action: 'inspect', location: requestedLocation, runId: this.runId };
      const raw = await this.controller.runJavaScript(this.script.replace('__PUREVPN_COMMAND__', (): string => JSON.stringify(command)));
      if (!this.currentOperation(epoch, requestedLocation) || this.pageRevision !== revision) { return; }
      const afterAddress = await this.currentAddress(epoch, requestedLocation);
      if (!this.currentOperation(epoch, requestedLocation) || afterAddress !== address) { return; }
      const result = parsePureVpnWebResult(raw);
      if (result.status !== 'configuration') {
        this.webpageConfig = ''; this.hasCandidate = false;
        throw new Error('网页当前没有唯一的 WireGuard 配置，请重新生成。');
      }
      this.observedLocation = result.selected;
      await this.importCandidate(result.config, result.selected, epoch);
    } catch (error) { this.error = (error as Error).message; }
    finally { this.polling = false; }
  }

  build() {
    Column() {
      WorkspaceShell({ active: 'tunnels', title: 'PureVPN',
        navigationLocked: this.busy || this.verifying || this.finishing }) { this.pageContent() }
    }.width('100%').height('100%')
  }

  @Builder
  private settings() {
    Column({ space: 14 }) {
      Button('重新打开官网', { type: ButtonType.Normal }).fontColor(BLUE).backgroundColor('#EEF2FF').height(40)
        .enabled(!this.busy && !this.verifying && !this.finishing).onClick(() => this.reopen())
      Flex({ wrap: FlexWrap.Wrap, space: { main: LengthMetrics.vp(12), cross: LengthMetrics.vp(8) } }) {
        if (this.locations.length > 0) {
          Select(this.locations.map((item: string): SelectOption => { return { value: item }; }))
            .value(this.location || '选择官网地区').width('100%').enabled(!this.busy && !this.verifying && !this.finishing && !this.armed)
            .onSelect((index: number) => { this.changedLocation(this.locations[index]); this.execute('select'); })
        } else {
          TextInput({ text: this.location, placeholder: '地区备注（需与官网一致），例如 Malaysia' })
            .width('100%').height(42).maxLength(100).enabled(!this.busy && !this.verifying && !this.finishing && !this.armed)
            .onChange((value: string) => this.changedLocation(value))
        }
        Row({ space: 4 }) {
        Checkbox().select(this.connectNow).enabled(!this.busy && !this.verifying && !this.finishing).onChange((value: boolean) => this.connectNow = value)
        Text('导入后连接').fontSize(13).fontColor(INK)
        }
        Row({ space: 4 }) {
        Checkbox().select(this.autoRenew).enabled(!this.busy && !this.verifying && !this.finishing).onChange((value: boolean) => {
          this.autoRenew = value;
          if (this.metadata) { this.metadata.autoRenew = value; writePureVpnProfile(this.context().filesDir, this.metadata); }
        })
        Text('前台尝试自动更新').fontSize(13).fontColor(INK)
        }
        if (this.hasDownloadedConfig) {
          Button('导入刚下载的配置', { type: ButtonType.Normal }).fontColor(BLUE).backgroundColor('#EEF2FF').height(44)
            .enabled(!this.busy && !this.verifying && !this.finishing && this.initialized && !this.combinedActive).onClick(() => this.importCandidate(this.downloadedConfig))
        } else if (this.hasCandidate) {
          Button('导入官网当前配置', { type: ButtonType.Normal }).fontColor(BLUE).backgroundColor('#EEF2FF').height(44)
            .enabled(!this.busy && !this.verifying && !this.finishing && this.initialized && !this.combinedActive).onClick(() => this.importCurrent())
        }
        Button(this.busy || this.verifying ? '验证新配置…' : (this.armed ? '等待官网生成…' : '生成新配置'), { type: ButtonType.Normal })
          .fontColor(Color.White).backgroundColor(BLUE).height(44).enabled(!this.busy && !this.verifying && !this.finishing && !this.armed).onClick(() => this.begin())
      }.width('100%')
      Text(this.status).fontSize(14).fontColor(INK).width('100%').padding(12).backgroundColor('#EEF2FF').borderRadius(10)
      if (this.recoveryStatus) {
        Text(this.recoveryStatus).fontSize(13).fontColor('#9A6B23').width('100%')
      }
      if (this.combinedActive) {
        Text(PUREVPN_COMBINED_MESSAGE + ' 当前仍可登录官网和下载配置，自动更新已暂停。')
          .fontSize(13).fontColor('#9A6B23').width('100%').padding(12).backgroundColor('#FFF5DF').borderRadius(10)
      }
      if (this.verifying || this.armed) {
        Button(this.verifying ? '取消本次更新并恢复' : '取消获取配置', { type: ButtonType.Normal }).fontColor(BLUE).backgroundColor('#EEF2FF')
          .enabled(!this.busy && !this.finishing).onClick(async () => {
            const updating = !!this.verifying;
            await this.cancelPending();
            if (this.initialized) { this.status = updating ? '本次更新已取消，已恢复之前保存的配置。' : '已取消获取配置。'; }
          })
      }
      if (this.error) { Text(this.error).fontSize(13).fontColor('#BD4242').width('100%') }
      Text('启动后持续未握手时会记录恢复任务，打开本页后可复用官网登录并自动生成、导入和验证配置。离开本页会暂停；验证码和重新登录需你完成。请求失败只提示检查，闲置或旧握手不会被判为配置过期。')
        .fontSize(12).fontColor(MUTED).width('100%')
      Text(this.sessionStatus + ' 平板上的临时会话可能在应用重启后失效。账号密码不会保存到应用配置。')
        .fontSize(12).fontColor(MUTED).width('100%')

    }.width('100%').alignItems(HorizontalAlign.Start).padding(16)
  }

  @Builder
  private pageContent() {
    Column({ space: 12 }) {
      Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center,
        space: { main: LengthMetrics.vp(16), cross: LengthMetrics.vp(10) } }) {
        Button('‹ 返回', { type: ButtonType.Normal }).fontColor(BLUE).backgroundColor('#EEF2FF').height(40)
          .enabled(!this.busy && !this.verifying && !this.finishing).onClick(() => router.back({ url: 'pages/NetworksPage' }))
        Column({ space: 4 }) {
          Text('PureVPN 配置助手').fontSize(this.contentWidth < 440 ? 22 : 26).fontWeight(FontWeight.Bold).fontColor(INK)
          Text(this.name + ' · 官方会员网页').fontSize(13).fontColor(MUTED).maxLines(2)
        }.alignItems(HorizontalAlign.Start)
      }.width('100%').flexShrink(0)
      Row({ space: 12 }) {
        if (this.contentWidth < 800) {
          Button(this.controlsExpanded ? '收起设置' : '展开设置', { type: ButtonType.Normal })
            .height(38).fontSize(13).fontColor(BLUE).backgroundColor('#EEF2FF').borderRadius(10)
            .onClick(() => this.controlsExpanded = !this.controlsExpanded)
        }
        Text(this.pageAddress).fontSize(12).fontColor(MUTED).layoutWeight(1).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }.width('100%').flexShrink(0)
      if (this.error || (!this.controlsExpanded && this.contentWidth < 800)) {
        Text(this.error || this.status).fontSize(12).fontColor(this.error ? '#BD4242' : MUTED)
          .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%').flexShrink(0)
      }
      Flex({ direction: this.contentWidth >= 800 ? FlexDirection.Row : FlexDirection.Column }) {
        Scroll() { this.settings() }
          .width(this.contentWidth >= 800 ? 320 : '100%')
          .height(this.contentWidth >= 800 ? '100%' : Math.max(100, Math.min(320, this.contentHeight * 0.40)))
          .visibility(this.contentWidth >= 800 || this.controlsExpanded ? Visibility.Visible : Visibility.None)
          .flexShrink(0).backgroundColor(Color.White).borderRadius(16).align(Alignment.Top).scrollBar(BarState.Auto)
        Column() {
      Web({ src: PUREVPN_MEMBER_URL, controller: this.controller })
        .javaScriptAccess(true).domStorageAccess(true).fileAccess(false).mixedMode(MixedMode.None)
        .onControllerAttached(() => { this.attached = true; this.attachDownloads(); })
        .onPageBegin(() => { this.pageRevision++; this.pageReady = false; this.officialPageReady = false; this.actualAddress = ''; this.observedLocation = ''; this.webpageConfig = ''; this.hasCandidate = false; })
        .onPageEnd(event => this.historyChanged(event.url))
        .onRefreshAccessedHistory(event => { if (event.isMainFrame !== false) { this.historyChanged(event.url); } })
        .onLoadIntercept(event => {
          if (event.data.isMainFrame() && !isPureVpnPage(event.data.getRequestUrl())) {
            this.error = '官网请求跳转到其他网站，已暂停。请在 PureVPN 会员页完成登录。';
            return true;
          }
          return false;
        })
        .onSslErrorEventReceive(event => { event.handler.handleCancel(); this.error = '官网证书验证失败，已停止加载。'; })
        .width('100%').height('100%')
        }.layoutWeight(1).width('100%').height('100%').constraintSize({ minWidth: 0, minHeight: 0 })
          .padding({ left: this.contentWidth >= 800 ? 16 : 0, top: this.contentWidth >= 800 ? 0 : 12 })
      }.layoutWeight(1).width('100%')
    }.padding(this.contentWidth < 600 ? 16 : 24).width('100%').height('100%').backgroundColor('#F4F6FA')
      .onAreaChange((_old: Area, area: Area) => {
        this.contentWidth = Number(area.width); this.contentHeight = Number(area.height);
      })
  }
}
