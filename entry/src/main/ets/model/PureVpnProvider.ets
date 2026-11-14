import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';

const DIRECTORY: string = '/purevpn-provider';
const RECOVERY_DIRECTORY: string = '/purevpn-recovery';
const MAX_METADATA_BYTES: number = 4096;
const MAX_FAILURE_COUNT: number = 10;
const WAIT_BEFORE_REFRESH_MS: number = 90000;
const RECENT_HANDSHAKE_MS: number = 180000;
const MAX_OBSERVATION_GAP_MS: number = 30000;
const OBSERVATION_WRITE_INTERVAL_MS: number = 15000;
const MAX_BACKOFF_MS: number = 30 * 60 * 1000;
const PROFILE_ID: RegExp = /^(main|[0-9a-fA-F-]{8,64})$/;
export const PUREVPN_COMBINED_MESSAGE: string = '请先在连接列表断开包含 Tailnet 的组合连接，再导入或更新 PureVPN 配置。';

export function isCombinedVpnSession(mixed: boolean | undefined, tailnetIds: string[] | undefined): boolean {
  return mixed === true || (tailnetIds instanceof Array && tailnetIds.length > 0);
}

export enum PureVpnStatus {
  Ready = 'ready',
  Active = 'active',
  Refreshing = 'refreshing',
  NeedsUser = 'needs-user',
  Retry = 'retry',
  Queued = 'queued',
}

// This document deliberately contains no password, cookie, token, or WireGuard configuration.
export class PureVpnProfile {
  profileId: string;
  location: string;
  importedAt: number;
  autoRenew: boolean;
  lastActivatedAt: number = 0;
  status: PureVpnStatus = PureVpnStatus.Ready;
  failureCount: number = 0;
  nextAttemptAt: number = 0;
  resumeOnOfficialPage: boolean = false;

  constructor(profileId: string, location: string, importedAt: number, autoRenew: boolean = false) {
    this.profileId = profileId;
    this.location = location;
    this.importedAt = importedAt;
    this.autoRenew = autoRenew;
  }
}

interface PureVpnDocument { version: number; profile: PureVpnProfile; }

export interface PureVpnRenewalInput {
  now: number;
  // The caller must supply the identity of the profile represented by lastHandshake.
  // An aggregate handshake from a session containing several profiles is not sufficient.
  profileId: string;
  phase: string;
  lastHandshake: number;
  attemptStartedAt: number;
  physicalNetworkAvailable: boolean;
  mixed?: boolean;
  tailnetIds?: string[];
  session?: string;
}

export class PureVpnRenewalDecision {
  action: string;
  reason: string;
  activatedAt: number;
  retryAt: number;

  constructor(action: string, reason: string, activatedAt: number = 0, retryAt: number = 0) {
    this.action = action;
    this.reason = reason;
    this.activatedAt = activatedAt;
    this.retryAt = retryAt;
  }
}

function validTimestamp(value: number): boolean {
  return typeof value === 'number' && Number.isSafeInteger(value) && value >= 0;
}

function checkProfileId(profileId: string): void {
  if (typeof profileId !== 'string' || !PROFILE_ID.test(profileId)) {
    throw new Error('PureVPN 连接标识无效。');
  }
}

function copyProfile(profile: PureVpnProfile): PureVpnProfile {
  if (!profile || typeof profile !== 'object') { throw new Error('PureVPN 关联信息无效。'); }
  checkProfileId(profile.profileId);
  if (typeof profile.location !== 'string' || profile.location.length === 0 || profile.location.length > 128 ||
    profile.location !== profile.location.trim() || /[\u0000-\u001f\u007f]/.test(profile.location) ||
    typeof profile.autoRenew !== 'boolean' || !validTimestamp(profile.importedAt) || profile.importedAt === 0 ||
    !validTimestamp(profile.lastActivatedAt) ||
    (profile.lastActivatedAt !== 0 && profile.lastActivatedAt <= profile.importedAt) ||
    !validTimestamp(profile.nextAttemptAt) || !Number.isInteger(profile.failureCount) ||
    (profile.resumeOnOfficialPage !== undefined && typeof profile.resumeOnOfficialPage !== 'boolean') ||
    profile.failureCount < 0 || profile.failureCount > MAX_FAILURE_COUNT ||
    ![PureVpnStatus.Ready, PureVpnStatus.Active, PureVpnStatus.Refreshing, PureVpnStatus.NeedsUser,
      PureVpnStatus.Retry, PureVpnStatus.Queued].includes(profile.status)) {
    throw new Error('PureVPN 关联信息无效。');
  }
  const result = new PureVpnProfile(profile.profileId, profile.location, profile.importedAt, profile.autoRenew);
  result.lastActivatedAt = profile.lastActivatedAt;
  result.status = profile.status;
  result.failureCount = profile.failureCount;
  result.nextAttemptAt = profile.nextAttemptAt;
  result.resumeOnOfficialPage = profile.resumeOnOfficialPage === true;
  return result;
}

function metadataPath(directory: string, profileId: string): string {
  checkProfileId(profileId);
  if (typeof directory !== 'string' || !directory.startsWith('/') || /[\u0000\r\n]/.test(directory)) {
    throw new Error('PureVPN 存储目录无效。');
  }
  return directory + DIRECTORY + '/' + profileId + '.json';
}

function ensureMetadataDirectory(directory: string): void {
  if (!fileIo.accessSync(directory)) {
    try { fileIo.mkdirSync(directory, true); }
    catch (error) {
      if ((error as BusinessError).code !== 13900015) { throw error as Error; }
    }
  }
  if (!fileIo.statSync(directory).isDirectory()) { throw new Error('PureVPN 关联信息目录不可用。'); }
}

export function readPureVpnProfile(directory: string, profileId: string): PureVpnProfile | undefined {
  const path = metadataPath(directory, profileId);
  try {
    const info = fileIo.statSync(path);
    if (!info.isFile() || info.size < 1 || info.size > MAX_METADATA_BYTES) { return undefined; }
    const text = fileIo.readTextSync(path);
    const bytes = util.TextEncoder.create().encodeInto(text);
    if (bytes.length > MAX_METADATA_BYTES) { return undefined; }
    const parsed = JSON.parse(text) as PureVpnDocument;
    if (parsed.version !== 1 || parsed.profile?.profileId !== profileId) { return undefined; }
    return copyProfile(parsed.profile);
  } catch (_) { return undefined; }
}

export function writePureVpnProfile(directory: string, profile: PureVpnProfile): void {
  const clean = copyProfile(profile);
  const path = metadataPath(directory, clean.profileId);
  const document: PureVpnDocument = { version: 1, profile: clean };
  const bytes = util.TextEncoder.create().encodeInto(JSON.stringify(document));
  if (bytes.length > MAX_METADATA_BYTES) { throw new Error('PureVPN 关联信息过大。'); }
  ensureMetadataDirectory(directory + DIRECTORY);
  const temporary = path + '.' + util.generateRandomUUID() + '.tmp';
  try {
    const file = fileIo.openSync(temporary,
      fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
    try {
      if (fileIo.writeSync(file.fd, bytes.buffer) !== bytes.length) {
        throw new Error('PureVPN 关联信息写入不完整。');
      }
      fileIo.fsyncSync(file.fd);
    } finally { fileIo.closeSync(file); }
    fileIo.renameSync(temporary, path);
  } catch (error) {
    try { fileIo.unlinkSync(temporary); } catch (_) {}
    throw error as Error;
  }
}

export function deletePureVpnProfile(directory: string, profileId: string): void {
  const path = metadataPath(directory, profileId);
  if (fileIo.accessSync(path)) { fileIo.unlinkSync(path); }
  const recovery = recoveryPath(directory, profileId);
  if (fileIo.accessSync(recovery)) { fileIo.unlinkSync(recovery); }
  recoveryCache.delete(recovery);
}

// Only a handshake belonging to this imported configuration is evidence of activation.
// A stale or missing handshake does not prove provider expiry.
export function markPureVpnActivated(profile: PureVpnProfile, handshake: number): PureVpnProfile {
  const next = copyProfile(profile);
  if (!validTimestamp(handshake) || handshake <= profile.importedAt) { return next; }
  next.lastActivatedAt = Math.max(next.lastActivatedAt, handshake);
  next.status = PureVpnStatus.Active;
  next.failureCount = 0;
  next.nextAttemptAt = 0;
  next.resumeOnOfficialPage = false;
  return next;
}

export function markPureVpnRefreshStarted(profile: PureVpnProfile, now: number): PureVpnProfile {
  const next = copyProfile(profile);
  if (!validTimestamp(now) || now < profile.importedAt) { throw new Error('PureVPN 重试时间无效。'); }
  next.status = PureVpnStatus.Refreshing;
  next.nextAttemptAt = Math.min(Number.MAX_SAFE_INTEGER, now + WAIT_BEFORE_REFRESH_MS);
  next.resumeOnOfficialPage = false;
  return next;
}

// Leaving the assistant is not a provider failure. Preserve a resumable job without adding
// backoff; a fresh matching runtime observation is still required before resuming it.
export function markPureVpnRefreshPaused(profile: PureVpnProfile, now: number): PureVpnProfile {
  const next = copyProfile(profile);
  if (!validTimestamp(now) || now < profile.importedAt) { throw new Error('PureVPN 重试时间无效。'); }
  next.status = PureVpnStatus.Queued;
  next.nextAttemptAt = now;
  next.resumeOnOfficialPage = false;
  return next;
}

export function markPureVpnRefreshFailure(profile: PureVpnProfile, now: number,
  needsUser: boolean = false): PureVpnProfile {
  const next = copyProfile(profile);
  if (!validTimestamp(now) || now < profile.importedAt) { throw new Error('PureVPN 重试时间无效。'); }
  next.failureCount = Math.min(MAX_FAILURE_COUNT, next.failureCount + 1);
  next.status = needsUser ? PureVpnStatus.NeedsUser : PureVpnStatus.Retry;
  next.resumeOnOfficialPage = false;
  const backoff = Math.min(MAX_BACKOFF_MS, 60000 * Math.pow(2, next.failureCount - 1));
  next.nextAttemptAt = needsUser ? 0 : Math.min(Number.MAX_SAFE_INTEGER, now + backoff);
  return next;
}

export function markPureVpnNeedsOfficialInteraction(profile: PureVpnProfile, now: number): PureVpnProfile {
  const next = markPureVpnRefreshFailure(profile, now, true);
  next.resumeOnOfficialPage = true;
  return next;
}

// This policy requests a foreground provider workflow; it never creates a hidden browser or
// claims a configuration has expired. Login and human verification remain interactive.
export function renewalDecision(profile: PureVpnProfile | undefined,
  input: PureVpnRenewalInput): PureVpnRenewalDecision {
  if (profile === undefined || input.profileId !== profile.profileId) {
    return new PureVpnRenewalDecision('keep', 'unknown-profile');
  }
  if (isCombinedVpnSession(input.mixed, input.tailnetIds)) { return new PureVpnRenewalDecision('keep', 'combined-session'); }
  let clean: PureVpnProfile;
  try { clean = copyProfile(profile); } catch (_) { return new PureVpnRenewalDecision('keep', 'invalid-profile'); }
  if (!validTimestamp(input.now) || input.now < clean.importedAt || !validTimestamp(input.lastHandshake) ||
    input.lastHandshake > input.now || !validTimestamp(input.attemptStartedAt) || input.attemptStartedAt > input.now) {
    return new PureVpnRenewalDecision('keep', 'invalid-time', clean.lastActivatedAt);
  }
  const activatedAt = input.lastHandshake > clean.importedAt ?
    Math.max(clean.lastActivatedAt, input.lastHandshake) : clean.lastActivatedAt;
  if (input.lastHandshake > clean.importedAt && input.now - input.lastHandshake <= RECENT_HANDSHAKE_MS) {
    return new PureVpnRenewalDecision('keep', 'recent-handshake', activatedAt);
  }
  // A quiet established WireGuard connection can have an old handshake. Its age alone must
  // not force rotation, even many hours after download.
  if (input.phase === 'connected') { return new PureVpnRenewalDecision('keep', 'connected', activatedAt); }
  if (input.lastHandshake !== 0) { return new PureVpnRenewalDecision('keep', 'prior-handshake', activatedAt); }
  if (!clean.autoRenew) { return new PureVpnRenewalDecision('keep', 'disabled', activatedAt); }
  if (input.physicalNetworkAvailable !== true) { return new PureVpnRenewalDecision('keep', 'offline', activatedAt); }
  if (clean.status === PureVpnStatus.NeedsUser) {
    return new PureVpnRenewalDecision('keep', 'needs-user', activatedAt);
  }
  if (clean.status === PureVpnStatus.Refreshing) {
    return new PureVpnRenewalDecision('keep', 'refresh-in-progress', activatedAt, clean.nextAttemptAt);
  }
  if (input.phase !== 'waiting' || input.attemptStartedAt === 0) {
    return new PureVpnRenewalDecision('keep', 'not-waiting', activatedAt);
  }
  const eligibleAt = Math.max(input.attemptStartedAt + WAIT_BEFORE_REFRESH_MS, clean.nextAttemptAt);
  if (input.now < eligibleAt) { return new PureVpnRenewalDecision('keep', 'backoff', activatedAt, eligibleAt); }
  return new PureVpnRenewalDecision('refresh', 'connection-unresponsive', activatedAt);
}

// Written only by the VPN runtime. The foreground assistant owns PureVpnProfile task state;
// keeping these documents separate prevents a background sample from overwriting a login,
// generation, rollback, or user-verification decision.
export interface PureVpnHealthSnapshot {
  now: number;
  profileId: string;
  session: string;
  phase: string;
  physicalNetworkAvailable: boolean;
  networkError: boolean;
  running: boolean;
  lastHandshake: number;
  sentBytes: number;
  receivedBytes: number;
  // Most recent failed route event for this exact wg:<profileId>, in milliseconds. A failed
  // dial is evidence for checking the connection, not proof that PureVPN revoked its key.
  lastFailedRequestAt?: number;
}

export class PureVpnRecoveryObservation {
  version: number = 1;
  profileId: string = '';
  importedAt: number = 0;
  session: string = '';
  updatedAt: number = 0;
  waitingSince: number = 0;
  lastHandshake: number = 0;
  sentBytes: number = 0;
  receivedBytes: number = 0;
  lastFailedRequestAt: number = 0;
  failureSince: number = 0;
  failureCount: number = 0;
  state: string = 'watching';
  reason: string = 'observing';
}

class PureVpnRecoveryCache {
  observed: PureVpnRecoveryObservation;
  persisted: PureVpnRecoveryObservation;
  constructor(observed: PureVpnRecoveryObservation, persisted: PureVpnRecoveryObservation) {
    this.observed = observed; this.persisted = persisted;
  }
}
const recoveryCache: Map<string, PureVpnRecoveryCache> = new Map<string, PureVpnRecoveryCache>();

function recoveryPath(directory: string, profileId: string): string {
  // Reuse the identifier/directory checks without ever accepting a caller-supplied filename.
  metadataPath(directory, profileId);
  return directory + RECOVERY_DIRECTORY + '/' + profileId + '.json';
}

function validRecovery(value: PureVpnRecoveryObservation): boolean {
  return !!value && value.version === 1 && typeof value.profileId === 'string' && PROFILE_ID.test(value.profileId) &&
    typeof value.session === 'string' && value.session.length > 0 && value.session.length <= 128 &&
    !/[\u0000-\u001f\u007f]/.test(value.session) && validTimestamp(value.importedAt) && value.importedAt > 0 &&
    validTimestamp(value.updatedAt) && value.updatedAt >= value.importedAt &&
    validTimestamp(value.waitingSince) && value.waitingSince <= value.updatedAt &&
    validTimestamp(value.lastHandshake) && value.lastHandshake <= value.updatedAt &&
    validTimestamp(value.sentBytes) && validTimestamp(value.receivedBytes) &&
    validTimestamp(value.lastFailedRequestAt) && value.lastFailedRequestAt <= value.updatedAt &&
    validTimestamp(value.failureSince) && value.failureSince <= value.updatedAt &&
    Number.isInteger(value.failureCount) && value.failureCount >= 0 && value.failureCount <= MAX_FAILURE_COUNT &&
    ['watching', 'queued', 'needs-check'].includes(value.state) &&
    ['observing', 'offline', 'inactive', 'healthy', 'native-not-running', 'waiting-for-handshake',
      'waiting-for-traffic', 'startup-unresponsive', 'request-failures', 'disabled'].includes(value.reason);
}

export function readPureVpnRecovery(directory: string, profileId: string): PureVpnRecoveryObservation | undefined {
  const path = recoveryPath(directory, profileId);
  try {
    const info = fileIo.statSync(path);
    if (!info.isFile() || info.size < 1 || info.size > MAX_METADATA_BYTES) { return undefined; }
    const parsed = JSON.parse(fileIo.readTextSync(path)) as PureVpnRecoveryObservation;
    return validRecovery(parsed) && parsed.profileId === profileId ? parsed : undefined;
  } catch (_) { return undefined; }
}

function writeRecovery(directory: string, observation: PureVpnRecoveryObservation): void {
  const path = recoveryPath(directory, observation.profileId);
  const bytes = util.TextEncoder.create().encodeInto(JSON.stringify(observation));
  if (!validRecovery(observation) || bytes.length > MAX_METADATA_BYTES) { throw new Error('PureVPN 恢复观察无效。'); }
  ensureMetadataDirectory(directory + RECOVERY_DIRECTORY);
  const temporary = path + '.' + util.generateRandomUUID() + '.tmp';
  try {
    const file = fileIo.openSync(temporary, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
    try {
      if (fileIo.writeSync(file.fd, bytes.buffer) !== bytes.length) { throw new Error('PureVPN 恢复观察写入不完整。'); }
      fileIo.fsyncSync(file.fd);
    } finally { fileIo.closeSync(file); }
    fileIo.renameSync(temporary, path);
  } catch (error) {
    try { fileIo.unlinkSync(temporary); } catch (_) {}
    throw error as Error;
  }
}

export function observePureVpnHealth(directory: string,
  input: PureVpnHealthSnapshot): PureVpnRecoveryObservation | undefined {
  const profile = readPureVpnProfile(directory, input.profileId);
  if (!profile) { return undefined; }
  const failedAt = input.lastFailedRequestAt === undefined ? 0 : input.lastFailedRequestAt;
  if (!validTimestamp(input.now) || input.now < profile.importedAt || typeof input.session !== 'string' ||
    input.session.length < 1 || input.session.length > 128 || /[\u0000-\u001f\u007f]/.test(input.session) ||
    !validTimestamp(input.lastHandshake) || input.lastHandshake > input.now || !validTimestamp(input.sentBytes) ||
    !validTimestamp(input.receivedBytes) || !validTimestamp(failedAt) || failedAt > input.now ||
    typeof input.physicalNetworkAvailable !== 'boolean' || typeof input.networkError !== 'boolean' ||
    typeof input.running !== 'boolean') { return undefined; }
  const path = recoveryPath(directory, input.profileId);
  const cached = recoveryCache.get(path);
  const persisted = cached?.persisted || readPureVpnRecovery(directory, input.profileId);
  const previous = cached?.observed || persisted;
  const continuous = previous !== undefined && previous.importedAt === profile.importedAt &&
    previous.session === input.session && input.now >= previous.updatedAt &&
    input.now - previous.updatedAt <= MAX_OBSERVATION_GAP_MS &&
    input.sentBytes >= previous.sentBytes && input.receivedBytes >= previous.receivedBytes &&
    input.lastHandshake >= previous.lastHandshake;
  const next = new PureVpnRecoveryObservation();
  next.profileId = input.profileId; next.importedAt = profile.importedAt; next.session = input.session;
  next.updatedAt = input.now; next.lastHandshake = input.lastHandshake;
  next.sentBytes = input.sentBytes; next.receivedBytes = input.receivedBytes;
  next.lastFailedRequestAt = failedAt;
  if (!input.physicalNetworkAvailable || input.networkError) { next.reason = 'offline'; }
  else if (!['starting', 'waiting', 'connected'].includes(input.phase)) { next.reason = 'inactive'; }
  else if (!input.running) { next.state = 'needs-check'; next.reason = 'native-not-running'; }
  else if (!profile.autoRenew) { next.reason = 'disabled'; }
  else {
    const progressed = continuous && previous !== undefined &&
      (input.lastHandshake > previous.lastHandshake || input.receivedBytes > previous.receivedBytes);
    const recentHandshake = input.lastHandshake > profile.importedAt &&
      input.now - input.lastHandshake <= RECENT_HANDSHAKE_MS;
    if (progressed || recentHandshake) { next.reason = 'healthy'; }
    else if (input.phase === 'waiting' && input.lastHandshake === 0) {
      // wireguard-go SendBuffers counts successfully sent handshake packets in tx_bytes.
      // With zero transmitted bytes, a never-used connection may simply be idle.
      if (input.sentBytes === 0) { next.reason = 'waiting-for-traffic'; }
      else {
        next.waitingSince = continuous && previous !== undefined && previous.waitingSince > 0 ?
          previous.waitingSince : input.now;
        next.reason = 'waiting-for-handshake';
        if (input.now - next.waitingSince >= WAIT_BEFORE_REFRESH_MS) {
          next.state = 'queued'; next.reason = 'startup-unresponsive';
        }
      }
    } else {
      // Neither an old handshake nor a silent/idle connection is a failure. Only distinct
      // fresh failed requests accumulate, and even repeated errors merely ask for a check.
      next.reason = input.phase === 'connected' ? 'healthy' : 'observing';
      if (failedAt > 0 && input.now - failedAt <= WAIT_BEFORE_REFRESH_MS) {
        if (continuous && previous !== undefined && previous.failureSince > 0 &&
          input.now - previous.lastFailedRequestAt <= WAIT_BEFORE_REFRESH_MS) {
          next.failureSince = previous.failureSince;
          next.failureCount = Math.min(MAX_FAILURE_COUNT, previous.failureCount +
            (failedAt > previous.lastFailedRequestAt ? 1 : 0));
        } else if (!continuous || previous === undefined || failedAt > previous.lastFailedRequestAt) {
          next.failureSince = input.now; next.failureCount = 1;
        }
        if (next.failureCount >= 3) { next.state = 'needs-check'; next.reason = 'request-failures'; }
      }
    }
  }
  // Keep every in-process sample for continuity and unique failure events, but limit flash
  // writes. Queue/state/network transitions remain immediately observable by the UI.
  const mustWrite = !persisted || next.session !== persisted.session || next.importedAt !== persisted.importedAt ||
    next.state !== persisted.state || next.reason !== persisted.reason || next.updatedAt < persisted.updatedAt ||
    next.updatedAt - persisted.updatedAt >= OBSERVATION_WRITE_INTERVAL_MS;
  if (mustWrite) { writeRecovery(directory, next); }
  if (recoveryCache.size >= 128 && !recoveryCache.has(path)) { recoveryCache.clear(); }
  recoveryCache.set(path, new PureVpnRecoveryCache(next, mustWrite || !persisted ? next : persisted));
  return next;
}

// A durable queue entry is advisory: it cannot apply an old request to a new session or key,
// resume offline, or turn a diagnostic request-failure warning into provider expiry.
export function queuedPureVpnRenewalDecision(profile: PureVpnProfile | undefined,
  observation: PureVpnRecoveryObservation | undefined, input: PureVpnRenewalInput,
  officialPageReady: boolean = false): PureVpnRenewalDecision {
  if (!profile || !observation || !validRecovery(observation) || observation.profileId !== profile.profileId ||
    observation.importedAt !== profile.importedAt || observation.state !== 'queued' ||
    input.session !== observation.session || input.lastHandshake !== 0 ||
    observation.reason !== 'startup-unresponsive' || !validTimestamp(input.now) ||
    input.now < observation.updatedAt || input.now - observation.updatedAt > MAX_OBSERVATION_GAP_MS) {
    return new PureVpnRenewalDecision('keep', 'no-current-queue');
  }
  if (profile.status === PureVpnStatus.NeedsUser && profile.resumeOnOfficialPage === true && officialPageReady) {
    const next = markPureVpnRefreshPaused(profile, input.now);
    return renewalDecision(next, input);
  }
  return renewalDecision(profile, input);
}
