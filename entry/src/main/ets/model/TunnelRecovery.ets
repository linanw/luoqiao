import { common, Want } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { connection, vpnExtension } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { readNetworkStatus } from './NetworkProfiles';
import { readTailnet } from './TailnetState';
import { readRecoverySessionRules } from './SessionRules';
import { readTunnelRequest, readPublishedTunnelState, TunnelPhase, TunnelState, VPN_ABILITY,
  requestTunnelHeartbeat, receivedTunnelHeartbeat, isTunnelMutationActive } from './TunnelState';

const RECORD: string = '/vpn-foreground-recovery.json';
const FRESH_MS: number = 15000;
const START_GRACE_MS: number = 90000;
const PROBE_MS: number = 8000;
const MAX_ATTEMPTS: number = 3;
const STABLE_MS: number = 5 * 60 * 1000;
const BACKOFF_MS: number[] = [5000, 15000, 45000];

export class TunnelRecoveryStatus {
  version: number = 1;
  session: string = '';
  key: string = '';
  attempts: number = 0;
  nextAttemptAt: number = 0;
  startedAt: number = 0;
  healthySince: number = 0;
  lastHealthyUpdated: number = 0;
  updated: number = Date.now();
  phase: string = 'idle';
  message: string = '';
}

function requestKey(request: TunnelState): string {
  return JSON.stringify([request.session, request.phase, request.updated, request.profileIds,
    request.tailnetIds, request.mixed, request.useConfigRoutes, request.resumeOnForeground]);
}

function recoverable(request: TunnelState | undefined): boolean {
  return request !== undefined && request.phase === TunnelPhase.Starting && request.resumeOnForeground !== false &&
    /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(request.session) &&
    request.profileIds.length + request.tailnetIds.length > 0;
}

function activePhase(phase: TunnelPhase): boolean {
  return [TunnelPhase.Starting, TunnelPhase.Waiting, TunnelPhase.Connected].includes(phase);
}

function recent(at: number, duration: number = FRESH_MS): boolean {
  return Number.isFinite(at) && Date.now() - at >= -5000 && Date.now() - at < duration;
}

export function readTunnelRecoveryStatus(directory: string): TunnelRecoveryStatus {
  const request = readTunnelRequest(directory);
  const empty = new TunnelRecoveryStatus();
  if (!request || !recoverable(request)) { return empty; }
  try {
    if (fileIo.statSync(directory + RECORD).size > 8192) { return empty; }
    const status = JSON.parse(fileIo.readTextSync(directory + RECORD)) as TunnelRecoveryStatus;
    if (status.version !== 1 || status.session !== request.session || status.key !== requestKey(request) ||
      !Number.isInteger(status.attempts) || status.attempts < 0 || status.attempts > MAX_ATTEMPTS ||
      !Number.isFinite(status.nextAttemptAt) || !Number.isFinite(status.startedAt) ||
      typeof status.phase !== 'string' || typeof status.message !== 'string') { return empty; }
    if (!Number.isFinite(status.healthySince) || status.healthySince < 0) { status.healthySince = 0; }
    if (!Number.isFinite(status.lastHealthyUpdated) || status.lastHealthyUpdated < 0) { status.lastHealthyUpdated = 0; }
    return status;
  } catch (_) { return empty; }
}

function saveStatus(directory: string, status: TunnelRecoveryStatus): void {
  const path = directory + RECORD;
  const temporary = path + '.' + util.generateRandomUUID() + '.tmp';
  const bytes = util.TextEncoder.create().encodeInto(JSON.stringify(status));
  try {
    const file = fileIo.openSync(temporary, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
    try {
      if (fileIo.writeSync(file.fd, bytes.buffer) !== bytes.length) { throw new Error('无法保存连接恢复记录。'); }
      fileIo.fsyncSync(file.fd);
    } finally { fileIo.closeSync(file); }
    fileIo.renameSync(temporary, path);
  } catch (error) {
    try { fileIo.unlinkSync(temporary); } catch (_) { /* No partial record is published. */ }
    throw error as Error;
  }
}

function otherAppConnection(directory: string): boolean {
  return readNetworkStatus(directory).active || readTailnet(directory).BackendState !== 'Stopped';
}

// Fail closed: unavailable network information must never mean "there is no VPN".
async function anySystemVpn(): Promise<boolean> {
  const networks = await connection.getAllNets();
  for (const network of networks) {
    const capabilities = await connection.getNetCapabilities(network);
    if (capabilities.bearerTypes.includes(connection.NetBearType.BEARER_VPN)) { return true; }
  }
  return false;
}

function delay(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void): void => { setTimeout(resolve, ms); });
}

/** A foreground coordinator, not an always-running service or a system watchdog. */
export class TunnelRecoveryController {
  private context: common.UIAbilityContext;
  private foreground: boolean = false;
  private generation: number = 0;
  private timer: number = -1;
  private busy: boolean = false;
  private forceProbe: boolean = true;

  constructor(context: common.UIAbilityContext) { this.context = context; }

  setForeground(active: boolean): void {
    this.foreground = active; this.generation++;
    if (this.timer >= 0) { clearInterval(this.timer); this.timer = -1; }
    if (active) {
      this.forceProbe = true;
      this.check();
      this.timer = setInterval(() => { this.check(); }, 2000);
    }
  }

  private owned(request: TunnelState, generation: number): boolean {
    const current = readTunnelRequest(this.context.filesDir);
    return this.foreground && this.generation === generation && recoverable(current) && current !== undefined &&
      requestKey(current) === requestKey(request) && !isTunnelMutationActive() && !fileIo.accessSync(this.context.filesDir + '/purevpn-apply-journal.json') &&
      !otherAppConnection(this.context.filesDir);
  }

  private publish(status: TunnelRecoveryStatus, phase: string, message: string): void {
    status.phase = phase; status.message = message; status.updated = Date.now();
    saveStatus(this.context.filesDir, status);
  }

  private observeHealthy(status: TunnelRecoveryStatus, published: TunnelState | undefined): void {
    if (status.attempts === 0 && status.phase === 'idle' && status.nextAttemptAt === 0) { return; }
    if (!published || published.session !== status.session || published.phase !== TunnelPhase.Connected || !recent(published.updated)) {
      status.healthySince = 0; status.lastHealthyUpdated = 0;
      this.publish(status, 'idle', ''); return;
    }
    // Re-reading the same fresh file is not new evidence of continuous health.
    if (published.updated === status.lastHealthyUpdated) {
      if (status.phase !== 'idle') { this.publish(status, 'idle', ''); }
      return;
    }
    const extensionSince = published.connectedSince || 0;
    if (extensionSince > 0 && extensionSince <= published.updated) {
      // The extension resets this marker whenever it leaves Connected. This also
      // proves continuity while the UI is in the background or has been recreated.
      status.healthySince = extensionSince;
    } else if (status.healthySince <= 0 || status.lastHealthyUpdated <= 0 ||
      published.updated < status.lastHealthyUpdated || published.updated - status.lastHealthyUpdated > FRESH_MS) {
      status.healthySince = Date.now();
    }
    status.lastHealthyUpdated = published.updated;
    if (published.updated - status.healthySince >= STABLE_MS) {
      status.attempts = 0; status.nextAttemptAt = 0; status.startedAt = 0;
    }
    this.publish(status, 'idle', '');
  }

  async check(): Promise<void> {
    if (!this.foreground || this.busy) { return; }
    const directory = this.context.filesDir;
    const request = readTunnelRequest(directory);
    if (!request || !recoverable(request)) { return; }
    const generation = this.generation;
    let status = readTunnelRecoveryStatus(directory);
    if (status.session !== request.session) {
      status = new TunnelRecoveryStatus(); status.session = request.session; status.key = requestKey(request);
    }
    this.busy = true;
    try {
      if (isTunnelMutationActive() || fileIo.accessSync(directory + '/purevpn-apply-journal.json')) {
        this.publish(status, 'blocked', 'PureVPN 配置更新尚未结束，请先在 PureVPN 页面完成恢复。'); return;
      }
      if (otherAppConnection(directory)) {
        this.publish(status, 'blocked', '另一个 Tailnet 连接正在运行，已暂停自动恢复。'); return;
      }
      const published = readPublishedTunnelState(directory);
      if (published?.session === request.session && published.phase === TunnelPhase.Failed) {
        this.publish(status, 'failed', '上次连接已报告失败，请检查错误后手动重新连接。'); return;
      }
      if (!this.forceProbe && published?.session === request.session && activePhase(published.phase) && recent(published.updated)) {
        this.observeHealthy(status, published);
        return;
      }
      if (status.phase === 'blocked' || status.phase === 'failed') {
        // Re-evaluate only on a new foreground event. No infinite retry or UI spinner.
        if (!this.forceProbe) { return; }
      }
      if (!this.forceProbe && status.nextAttemptAt > Date.now()) { return; }
      this.forceProbe = false;
      this.publish(status, 'checking', '正在确认上次连接是否仍在运行…');
      const beforeUpdated = published?.updated || 0;
      const heartbeat = requestTunnelHeartbeat(directory, request.session);
      let alive = false;
      // Bounded by tick count as well as timers, so a wall-clock correction cannot
      // strand the UI in an endless liveness check.
      for (let elapsed = 0; elapsed < PROBE_MS; elapsed += 250) {
        if (!this.owned(request, generation)) { return; }
        const current = readPublishedTunnelState(directory);
        if (receivedTunnelHeartbeat(directory, heartbeat) || (current?.session === request.session &&
          activePhase(current.phase) && current.updated > beforeUpdated && recent(current.updated))) {
          alive = true; break;
        }
        await delay(250);
      }
      if (!this.owned(request, generation)) { return; }
      if (alive) { this.observeHealthy(status, readPublishedTunnelState(directory)); return; }
      status.healthySince = 0; status.lastHealthyUpdated = 0;
      // A first launch may be waiting for VPN authorization or loading encrypted
      // profiles. Do not issue another start while the original start is young.
      const current = readPublishedTunnelState(directory);
      if (recent(status.startedAt, START_GRACE_MS) ||
        ((current?.session !== request.session || current.phase === TunnelPhase.Starting) && recent(request.updated, START_GRACE_MS))) {
        this.publish(status, 'waiting', '系统 VPN 仍在启动，等待响应…'); return;
      }
      if (current?.session === request.session && current.phase === TunnelPhase.Failed) {
        this.publish(status, 'failed', '上次连接已报告失败，请检查错误后手动重新连接。'); return;
      }
      if (status.attempts >= MAX_ATTEMPTS) {
        this.publish(status, 'failed', '连接连续恢复 3 次仍未稳定，请手动断开后重新连接。'); return;
      }
      let occupied = false;
      try { occupied = await anySystemVpn(); }
      catch (_) {
        if (this.owned(request, generation)) {
          this.publish(status, 'blocked', '无法核实系统 VPN 状态，已暂停自动恢复。请在系统设置确认后手动重新连接。');
        }
        return;
      }
      if (!this.owned(request, generation)) { return; }
      if (occupied) {
        this.publish(status, 'blocked', '系统中仍有 VPN 正在运行，未替换现有 VPN。请确认连接状态后再操作。'); return;
      }
      if (status.nextAttemptAt === 0) {
        status.nextAttemptAt = Date.now() + BACKOFF_MS[status.attempts];
        this.publish(status, 'backoff', '上次连接已中断，即将使用原会话恢复…'); return;
      }
      if (Date.now() < status.nextAttemptAt) {
        this.publish(status, 'backoff', '正在等待下一次连接恢复…'); return;
      }
      const useConfigRoutes = readRecoverySessionRules(directory, request.session, request.profileIds,
        request.tailnetIds, request.mixed, request.useConfigRoutes).useConfigRoutes;
      // Recheck after every asynchronous operation. No stop is used anywhere in
      // this coordinator: an unresponsive but present VPN is never destroyed.
      let occupiedAgain = false;
      try { occupiedAgain = await anySystemVpn(); }
      catch (_) {
        if (this.owned(request, generation)) {
          this.publish(status, 'blocked', '无法核实系统 VPN 状态，已暂停自动恢复。请在系统设置确认后手动重新连接。');
        }
        return;
      }
      if (!this.owned(request, generation)) { return; }
      const finalState = readPublishedTunnelState(directory);
      if (receivedTunnelHeartbeat(directory, heartbeat) || (finalState?.session === request.session &&
        activePhase(finalState.phase) && finalState.updated > beforeUpdated && recent(finalState.updated))) {
        this.observeHealthy(status, finalState); return;
      }
      if (finalState?.session === request.session && finalState.phase === TunnelPhase.Failed) {
        this.publish(status, 'failed', '连接已报告失败，请检查错误后手动重新连接。'); return;
      }
      if (occupiedAgain) {
        this.publish(status, 'blocked', '系统 VPN 状态发生变化，已暂停自动恢复。'); return;
      }
      status.attempts++; status.startedAt = Date.now();
      status.nextAttemptAt = Date.now() + START_GRACE_MS + BACKOFF_MS[Math.min(status.attempts, MAX_ATTEMPTS - 1)];
      this.publish(status, 'restarting', '正在恢复原来的连接（第 ' + status.attempts.toString() + '/3 次）…');
      const want: Want = { bundleName: this.context.abilityInfo.bundleName, abilityName: VPN_ABILITY,
        parameters: { wireguardSession: request.session, wireguardProfiles: request.profileIds,
          mixedTailnets: request.tailnetIds, mixedMode: request.mixed, wireguardUseConfigRoutes: useConfigRoutes } };
      await vpnExtension.startVpnExtensionAbility(want);
      if (!this.owned(request, generation)) { return; }
      this.publish(status, 'waiting', '已请求恢复原会话，等待 VPN 响应…');
    } catch (error) {
      if (this.owned(request, generation)) {
        const code = (error as BusinessError).code;
        // Fixed text avoids leaking configuration or paths from native exceptions.
        this.publish(status, 'failed', '连接恢复未完成' + (typeof code === 'number' ? '（错误码 ' + code.toString() + '）' : '') +
          '。请检查原会话规则快照和配置，或手动断开后重新连接。');
      }
    } finally { this.busy = false; }
  }
}

let controller: TunnelRecoveryController | undefined;
export function setTunnelRecoveryForeground(context: common.UIAbilityContext, foreground: boolean): void {
  if (!controller) { controller = new TunnelRecoveryController(context); }
  controller.setForeground(foreground);
}
