import { common, Want } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { fileIo } from '@kit.CoreFileKit';
import { vpnExtension } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { createProfile, deleteProfile, isValidProfileId, listProfiles, loadProfileText,
  MAX_CONFIG_BYTES, ProfileMeta, saveProfileText } from './ProfileStore';
import { readNetworkStatus } from './NetworkProfiles';
import { readTailnet } from './TailnetState';
import { readProfileRules } from './SplitTunnel';
import { readTunnelRequest, readTunnelState, TunnelPhase, TunnelState,
  VPN_ABILITY, writeTunnelRequest, setTunnelMutationActive } from './TunnelState';
import { parseWireGuardConfig } from './WireGuardConfig';
import { isCombinedVpnSession, PUREVPN_COMBINED_MESSAGE } from './PureVpnProvider';

let applying: boolean = false;
const JOURNAL: string = '/purevpn-apply-journal.json';
const STALE_STATUS_MS: number = 90000;

function combinedSession(state: TunnelState | undefined): boolean {
  return isCombinedVpnSession(state?.mixed, state?.tailnetIds);
}

// Only fixed operation labels and numeric SDK codes are exposed. Error messages can
// contain configuration, paths or account details and must never enter diagnostics.
function failureDiagnostic(stage: string, error: Error): string {
  const code = error && typeof (error as BusinessError).code === 'number' &&
    Number.isSafeInteger((error as BusinessError).code) ? (error as BusinessError).code : 0;
  hilog.error(0x0001, 'PureVPN', 'Configuration update failed at %{public}s, code %{public}d', stage, code);
  return '（步骤：' + stage + '；错误码：' + code.toString() + '）';
}

class ApplyJournal {
  profileId: string = '';
  token: string = '';
  backup: string = '';
  created: boolean = false;
  wasConnected: boolean = false;
  connect: boolean = false;
  installed: boolean = false;
  started: boolean = false;
  startRejected: boolean = false;
  startedAt: number = 0;
  initialProfileIds: string[] = [];
  previousRequestKey: string = '';
}

function readJournal(directory: string): ApplyJournal | undefined {
  if (!fileIo.accessSync(directory + JOURNAL)) { return undefined; }
  const journal = JSON.parse(fileIo.readTextSync(directory + JOURNAL)) as ApplyJournal;
  if (!/^[0-9a-f-]{8,64}$/.test(journal.token) ||
    (journal.profileId !== '' && !isValidProfileId(journal.profileId)) ||
    (journal.backup !== '' && journal.backup !== directory + '/profiles/' + journal.profileId +
      '.purevpn-backup-' + journal.token + '.enc') || !(journal.initialProfileIds instanceof Array)) {
    throw new Error('配置更新恢复记录无效，未改动已保存的配置。');
  }
  return journal;
}

function saveJournal(directory: string, journal: ApplyJournal): void {
  const path = directory + JOURNAL;
  const temporary = path + '.tmp';
  const bytes = util.TextEncoder.create().encodeInto(JSON.stringify(journal));
  const file = fileIo.openSync(temporary, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
  try {
    if (fileIo.writeSync(file.fd, bytes.buffer) !== bytes.length) { throw new Error('无法保存配置更新恢复记录。'); }
    fileIo.fsyncSync(file.fd);
  } finally { fileIo.closeSync(file); }
  fileIo.renameSync(temporary, path);
}

function clearJournal(directory: string, token: string): void {
  if (readJournal(directory)?.token === token) { fileIo.unlinkSync(directory + JOURNAL); }
}

function active(phase: TunnelPhase): boolean {
  return [TunnelPhase.Starting, TunnelPhase.Waiting, TunnelPhase.Connected, TunnelPhase.Stopping].includes(phase);
}

function assertOtherVpnStopped(directory: string): void {
  const state = readTunnelState(directory);
  if (state && active(state.phase) &&
    (combinedSession(state) || combinedSession(readTunnelRequest(directory)))) {
    throw new Error(PUREVPN_COMBINED_MESSAGE);
  }
  if (readNetworkStatus(directory).active || readTailnet(directory).BackendState !== 'Stopped') {
    throw new Error('请先断开 Tailnet，再更新 PureVPN 配置。');
  }
}

function requestKey(state: TunnelState | undefined): string {
  return state ? state.session + ':' + state.phase + (combinedSession(state) ? ':combined' : '') : '';
}

function assertRequest(directory: string, expected: string): void {
  assertOtherVpnStopped(directory);
  const request = readTunnelRequest(directory);
  if (requestKey(request) !== expected) {
    throw new Error('连接操作已变化，已停止本次配置更新。');
  }
}

function assertUncancelled(directory: string, session: string): void {
  const request = readTunnelRequest(directory);
  if (!request || request.session !== session || request.phase !== TunnelPhase.Starting || request.resumeOnForeground === false) {
    throw new Error('连接已由用户停止，未重新启动 VPN。');
  }
}

function want(context: common.UIAbilityContext, session: string, profileId: string = '', direct: boolean = false): Want {
  return { bundleName: context.abilityInfo.bundleName, abilityName: VPN_ABILITY,
    parameters: { wireguardSession: session, wireguardProfiles: profileId ? [profileId] : [],
      wireguardUseConfigRoutes: direct } };
}

function configRoutes(directory: string, id: string): boolean {
  const rules = readProfileRules(directory, id);
  if (rules.enabled && !rules.isDefault && !rules.hasContent()) {
    throw new Error('此连接已启用站点分流，但尚无规则。请先添加域名或 IP 规则。');
  }
  return !(rules.enabled && !rules.isDefault);
}

function delay(milliseconds: number): Promise<void> {
  return new Promise<void>((resolve: () => void): void => { setTimeout(resolve, milliseconds); });
}

// Keep the request unchanged until onDestroy can publish its acknowledgement.
function hasPublishedStatus(directory: string, session: string): boolean {
  try {
    const state = JSON.parse(fileIo.readTextSync(directory + '/wireguard-tunnel-state.json')) as TunnelState;
    return state.session === session;
  } catch (_) { return false; }
}

function publishedStatusText(directory: string): string {
  try { return fileIo.readTextSync(directory + '/wireguard-tunnel-state.json'); }
  catch (_) { return ''; }
}

function stalePublishedStatus(text: string, before: TunnelState, session: string, now: number): boolean {
  try {
    const published = JSON.parse(text) as TunnelState;
    return published.session === session && before.session === session && published.phase === before.phase &&
      published.updated === before.updated && Number.isSafeInteger(published.updated) && published.updated > 0 &&
      now - published.updated >= STALE_STATUS_MS;
  } catch (_) { return false; }
}

async function stopOwned(context: common.UIAbilityContext, expected: string, session: string,
  startRejected: boolean = false): Promise<void> {
  const directory = context.filesDir;
  assertRequest(directory, expected);
  const before = readTunnelState(directory);
  if (!before || before.phase === TunnelPhase.Disconnected) { return; }
  const beforeText = publishedStatusText(directory);
  const staleBeforeStop = stalePublishedStatus(beforeText, before, session, Date.now());
  const published = hasPublishedStatus(directory, session);
  await vpnExtension.stopVpnExtensionAbility(want(context, session));
  assertRequest(directory, expected);
  // A rejected start can leave only our reservation, with no extension to publish
  // onDestroy. A fulfilled system stop still confirms termination in this case.
  if (startRejected && !published && !hasPublishedStatus(directory, session)) { return; }
  const deadline = Date.now() + 10000;
  let observedActivity = false;
  while (true) {
    assertRequest(directory, expected);
    const state = readTunnelState(directory);
    if (state?.session === session &&
      (state.phase === TunnelPhase.Disconnected || state.phase === TunnelPhase.Failed)) { return; }
    if (publishedStatusText(directory) !== beforeText) { observedActivity = true; }
    if (Date.now() >= deadline) {
      // Installing a HAP or a killed extension can leave an old status without an
      // onDestroy acknowledgement. A fulfilled system stop plus a full quiet wait
      // permits recovery only when that same record was already stale beforehand.
      // A changed request, any new status, a fresh record, or a rejected stop must fail.
      if (staleBeforeStop && !observedActivity && state?.session === session &&
        state.phase === before.phase && state.updated === before.updated) { return; }
      throw new Error('尚未确认旧 VPN 已停止，原配置未被替换。请返回连接列表检查状态。');
    }
    await delay(100);
  }
}

function removeBackup(path: string): void {
  try {
    if (path && fileIo.accessSync(path)) { fileIo.unlinkSync(path); }
  } catch (_) { /* An unused encrypted backup must not undo a verified working connection. */ }
}

/** Holds secrets only in memory; the rollback file is an unchanged encrypted envelope. */
export class PureVpnApplyTransaction {
  readonly profileId: string;
  readonly session: string;
  private context: common.UIAbilityContext;
  private token: string;
  private candidate: string;
  private backup: string;
  private created: boolean;
  private wasConnected: boolean;
  private requestedConnect: boolean;
  private startedAt: number;
  private closed: boolean = false;
  private installed: boolean = false;
  private started: boolean = false;
  private startRejected: boolean = false;
  private journal: ApplyJournal;

  constructor(context: common.UIAbilityContext, profileId: string, token: string,
    candidate: string, backup: string, created: boolean, wasConnected: boolean, connect: boolean,
    journal: ApplyJournal) {
    this.context = context; this.profileId = profileId; this.token = token;
    this.session = connect ? token : ''; this.candidate = candidate; this.backup = backup;
    this.created = created; this.wasConnected = wasConnected; this.requestedConnect = connect;
    this.journal = journal; this.startedAt = journal.startedAt;
    this.installed = journal.installed; this.started = journal.started;
    this.startRejected = journal.startRejected === true;
  }

  markInstalled(): void {
    this.installed = true; this.journal.profileId = this.profileId; this.journal.installed = true;
    saveJournal(this.context.filesDir, this.journal);
  }
  markStarted(): void {
    this.journal.started = true; saveJournal(this.context.filesDir, this.journal); this.started = true;
  }
  markStartRejected(): void {
    this.startRejected = true; this.journal.startRejected = true; saveJournal(this.context.filesDir, this.journal);
  }

  private assertOwned(): TunnelState {
    if (this.closed) { throw new Error('本次配置更新已经结束。'); }
    assertOtherVpnStopped(this.context.filesDir);
    const request = readTunnelRequest(this.context.filesDir);
    if (!request || request.session !== this.token) {
      throw new Error('已有新的连接操作，未覆盖该操作；原配置的加密备份已保留。');
    }
    if (combinedSession(request) || combinedSession(readTunnelState(this.context.filesDir))) {
      throw new Error(PUREVPN_COMBINED_MESSAGE);
    }
    return request;
  }

  private async assertCandidate(): Promise<TunnelState> {
    this.assertOwned();
    if (this.installed && await loadProfileText(this.context, this.profileId) !== this.candidate) {
      throw new Error('配置已被其他操作修改，未覆盖该修改；原配置的加密备份已保留。');
    }
    return this.assertOwned();
  }

  private finish(): void {
    this.candidate = ''; this.closed = true; applying = false; setTunnelMutationActive(false);
  }

  /** A successful start call is insufficient: a new, recent single-profile handshake is required. */
  async commit(): Promise<void> {
    await this.assertCandidate();
    this.assertOwned();
    if (this.requestedConnect) {
      const state = readTunnelState(this.context.filesDir);
      if (!state || state.session !== this.token || state.phase !== TunnelPhase.Connected ||
        combinedSession(state) ||
        state.profileIds.length !== 1 || state.profileIds[0] !== this.profileId ||
        state.lastHandshake < this.startedAt || Date.now() - state.lastHandshake > 180000) {
        throw new Error('新配置尚未完成有效握手，暂不能确认更新成功。');
      }
    }
    clearJournal(this.context.filesDir, this.token);
    removeBackup(this.backup);
    this.finish();
  }

  /** Restores only this transaction's candidate; a newer user request is never stopped or overwritten. */
  async rollback(): Promise<void> {
    const directory = this.context.filesDir;
    try {
      await this.assertCandidate();
      let request = this.assertOwned();
      let resume = this.wasConnected && request.phase === TunnelPhase.Starting && request.resumeOnForeground !== false;
      if (this.started && active(readTunnelState(directory)?.phase || TunnelPhase.Disconnected)) {
        await stopOwned(this.context, requestKey(request), this.token, this.startRejected);
        request = this.assertOwned();
      }
      await this.assertCandidate();
      this.assertOwned();
      if (this.installed || !this.created) {
        if (this.created) {
          await deleteProfile(this.context, this.profileId);
        } else {
          if (!this.backup || !fileIo.accessSync(this.backup)) { throw new Error('原配置的加密备份不可用。'); }
          const target = directory + '/profiles/' + this.profileId + '.enc';
          const temporary = target + '.' + this.token + '.rollback';
          try {
            fileIo.copyFileSync(this.backup, temporary);
            fileIo.renameSync(temporary, target);
          } finally {
            if (fileIo.accessSync(temporary)) { fileIo.unlinkSync(temporary); }
          }
        }
      }
      const finalRequest = this.assertOwned();
      resume = resume && finalRequest.phase === TunnelPhase.Starting && finalRequest.resumeOnForeground !== false;
      writeTunnelRequest(directory, new TunnelState(this.token, TunnelPhase.Disconnected));
      clearJournal(directory, this.token);
      removeBackup(this.backup);
      if (resume && !this.created) {
        const direct = configRoutes(directory, this.profileId);
        const session = util.generateRandomUUID();
        const state = new TunnelState(session, TunnelPhase.Starting, '已恢复更新前的配置。');
        state.profileIds = [this.profileId]; state.useConfigRoutes = direct;
        writeTunnelRequest(directory, state);
        try { await vpnExtension.startVpnExtensionAbility(want(this.context, session, this.profileId, direct)); }
        catch (_) {
          const request = readTunnelRequest(directory);
          if (request?.session === session && !combinedSession(request) && !combinedSession(readTunnelState(directory))) {
            const failed = new TunnelState(session, TunnelPhase.Failed, '原配置已恢复，请从连接列表重新连接。');
            failed.profileIds = [this.profileId]; writeTunnelRequest(directory, failed);
          }
          throw new Error('原配置已恢复，但重连未成功，请从连接列表重新连接。');
        }
      }
    } finally { this.finish(); }
  }
}

export async function applyPureVpnConfig(context: common.UIAbilityContext, profileId: string,
  name: string, configText: string, connect: boolean): Promise<PureVpnApplyTransaction> {
  if (applying) { throw new Error('另一次 PureVPN 配置更新尚未结束。'); }
  if (readJournal(context.filesDir)) { throw new Error('上次配置更新尚未结束，请先恢复上次更新。'); }
  if (util.TextEncoder.create().encodeInto(configText).length > MAX_CONFIG_BYTES) {
    throw new Error('配置文件不能超过 128 KB。');
  }
  parseWireGuardConfig(configText);
  if (profileId && !isValidProfileId(profileId)) { throw new Error('配置标识无效。'); }
  const trimmedName = name.trim();
  if (!profileId && (!trimmedName || trimmedName.length > 64 || /[\u0000-\u001f]/.test(trimmedName))) {
    throw new Error('配置名称需为 1 到 64 个可见字符。');
  }
  const directory = context.filesDir;
  assertOtherVpnStopped(directory);
  const initialRequest = readTunnelRequest(directory);
  const initialKey = requestKey(initialRequest);
  const state = readTunnelState(directory);
  const wasActive = state !== undefined && active(state.phase);
  if (wasActive && (!profileId || state!.profileIds.length !== 1 || state!.profileIds[0] !== profileId)) {
    throw new Error('只能更新正在单独运行的同一 WireGuard 连接。请先断开其他连接或多连接组。');
  }
  if (wasActive && !connect) { throw new Error('此连接正在运行，请选择更新并重连，或先断开后仅保存。'); }
  if (state?.phase === TunnelPhase.Stopping) { throw new Error('VPN 正在断开，请稍后重试。'); }
  if (profileId && !listProfiles(context).some((item: ProfileMeta): boolean => item.id === profileId)) {
    throw new Error('此连接已不存在，请返回连接列表。');
  }
  if (profileId && connect) { configRoutes(directory, profileId); }
  const token = util.generateRandomUUID();
  let backup = '';
  let transaction: PureVpnApplyTransaction | undefined;
  let reserved = false;
  let id = profileId;
  const journal = new ApplyJournal();
  journal.profileId = id; journal.token = token; journal.created = !profileId;
  journal.wasConnected = wasActive; journal.connect = connect; journal.startedAt = Date.now();
  journal.previousRequestKey = initialKey;
  journal.initialProfileIds = listProfiles(context).map((item: ProfileMeta): string => item.id);
  let stage = '读取原配置';
  try {
    applying = true; setTunnelMutationActive(true);
    if (profileId) {
      if (!(await loadProfileText(context, profileId))) { throw new Error('原配置为空，无法安全更新。'); }
      assertRequest(directory, initialKey);
      if (initialRequest?.phase === TunnelPhase.Starting && initialRequest.resumeOnForeground !== false) { assertUncancelled(directory, initialRequest.session); }
      backup = directory + '/profiles/' + profileId + '.purevpn-backup-' + token + '.enc';
      stage = '备份原配置';
      fileIo.copyFileSync(directory + '/profiles/' + profileId + '.enc', backup);
      journal.backup = backup;
    }
    stage = '确认旧连接状态';
    assertRequest(directory, initialKey);
    if (initialRequest?.phase === TunnelPhase.Starting && initialRequest.resumeOnForeground !== false) { assertUncancelled(directory, initialRequest.session); }
    if (state && state.phase !== TunnelPhase.Disconnected && initialRequest) {
      stage = '停止旧 VPN 并等待确认';
      await stopOwned(context, initialKey, initialRequest.session);
    }
    stage = '确认旧 VPN 已停止';
    assertRequest(directory, initialKey);
    if (initialRequest?.phase === TunnelPhase.Starting && initialRequest.resumeOnForeground !== false) { assertUncancelled(directory, initialRequest.session); }
    // Reserve the session before asynchronous encrypted writes so other editors see an active operation.
    const reservation = new TunnelState(token, TunnelPhase.Starting, '正在安全更新 PureVPN 配置…');
    reservation.profileIds = id ? [id] : [];
    stage = '保存更新恢复记录';
    saveJournal(directory, journal);
    stage = '预留新连接会话';
    writeTunnelRequest(directory, reservation); reserved = true;
    if (id) {
      transaction = new PureVpnApplyTransaction(context, id, token, configText, backup, false, wasActive, connect, journal);
      stage = '加密保存新配置';
      await saveProfileText(context, id, configText);
    } else {
      stage = '新建连接配置';
      const profile = await createProfile(context, trimmedName, configText); id = profile.id;
      transaction = new PureVpnApplyTransaction(context, id, token, configText, '', true, false, connect, journal);
    }
    stage = '确认新配置写入';
    transaction.markInstalled();
    assertRequest(directory, token + ':' + TunnelPhase.Starting);
    assertUncancelled(directory, token);
    if (connect) {
      stage = '准备新 VPN';
      const direct = configRoutes(directory, id);
      const starting = new TunnelState(token, TunnelPhase.Starting); starting.profileIds = [id]; starting.useConfigRoutes = direct;
      writeTunnelRequest(directory, starting);
      transaction.markStarted();
      stage = '启动新 VPN';
      try { await vpnExtension.startVpnExtensionAbility(want(context, token, id, direct)); }
      catch (error) { transaction.markStartRejected(); throw error as Error; }
      stage = '确认新连接会话';
      assertRequest(directory, token + ':' + TunnelPhase.Starting);
      assertUncancelled(directory, token);
    } else {
      stage = '完成仅保存配置';
      writeTunnelRequest(directory, new TunnelState(token, TunnelPhase.Disconnected));
    }
    return transaction;
  } catch (error) {
    const diagnostic = failureDiagnostic(stage, error as Error);
    if (transaction) {
      try { await transaction.rollback(); }
      catch (rollbackError) {
        const rollbackDiagnostic = failureDiagnostic('恢复原配置', rollbackError as Error);
        throw new Error('配置更新未完成' + diagnostic + '。连接状态已变化或恢复失败' + rollbackDiagnostic +
          '，原配置的加密备份已保留；请检查连接列表。');
      }
    } else {
      const request = readTunnelRequest(directory);
      if (reserved && request?.session === token && !combinedSession(request) && !combinedSession(readTunnelState(directory))) {
        writeTunnelRequest(directory, new TunnelState(token, TunnelPhase.Disconnected));
      }
      clearJournal(directory, token);
      removeBackup(backup);
      applying = false; setTunnelMutationActive(false);
    }
    throw new Error('PureVPN 配置更新未完成' + diagnostic + '，原有配置已保留。请检查连接状态后重试。');
  }
}

/** Resolve an interrupted apply after process restart, before accepting another update. */
export async function recoverPureVpnApply(context: common.UIAbilityContext): Promise<void> {
  if (applying) { throw new Error('配置更新仍在进行，请等待其结束。'); }
  const directory = context.filesDir;
  const journal = readJournal(directory);
  if (!journal) { return; }
  assertOtherVpnStopped(directory);
  if (!journal.installed && requestKey(readTunnelRequest(directory)) === journal.previousRequestKey) {
    clearJournal(directory, journal.token); removeBackup(journal.backup); return;
  }
  if (readTunnelRequest(directory)?.session !== journal.token) {
    // A later explicit connection request supersedes this transaction. Keep its encrypted
    // backup for recovery, but do not block subsequent updates with an obsolete journal.
    clearJournal(directory, journal.token); return;
  }
  if (combinedSession(readTunnelRequest(directory)) || combinedSession(readTunnelState(directory))) {
    throw new Error(PUREVPN_COMBINED_MESSAGE);
  }
  if (!journal.profileId && journal.created) {
    const added = listProfiles(context).filter((item: ProfileMeta): boolean => !journal.initialProfileIds.includes(item.id));
    if (added.length > 1) { throw new Error('无法确认上次新建的配置，未改动现有连接。'); }
    if (added.length === 0) {
      writeTunnelRequest(directory, new TunnelState(journal.token, TunnelPhase.Disconnected));
      clearJournal(directory, journal.token); return;
    }
    journal.profileId = added[0].id; journal.installed = true;
  }
  const candidate = await loadProfileText(context, journal.profileId);
  const request = readTunnelRequest(directory);
  if (combinedSession(request) || combinedSession(readTunnelState(directory))) {
    throw new Error(PUREVPN_COMBINED_MESSAGE);
  }
  if (request?.session !== journal.token) {
    throw new Error('连接操作已变化，已停止恢复。');
  }
  // A process can exit after the encrypted rename but before its journal acknowledgement.
  journal.installed = true;
  applying = true; setTunnelMutationActive(true);
  const transaction = new PureVpnApplyTransaction(context, journal.profileId, journal.token, candidate,
    journal.backup, journal.created, journal.wasConnected, journal.connect, journal);
  const state = readTunnelState(directory);
  if (!journal.connect || (state?.session === journal.token && state.phase === TunnelPhase.Connected &&
    state.lastHandshake >= journal.startedAt && Date.now() - state.lastHandshake <= 180000)) {
    try { await transaction.commit(); return; } catch (_) { /* Restore if validation could not be completed. */ }
  }
  await transaction.rollback();
}
