import { util } from '@kit.ArkTS';
import { fileIo } from '@kit.CoreFileKit';
import { NetworkNodeStatus } from './NetworkProfiles';

export const VPN_ABILITY: string = 'WireGuardVpnAbility';
const REQUEST_FILE: string = '/wireguard-tunnel-request.json';
const STATUS_FILE: string = '/wireguard-tunnel-state.json';
const HEARTBEAT_REQUEST: string = '/vpn-heartbeat-request.json';
const HEARTBEAT_RESPONSE: string = '/vpn-heartbeat-response.json';

export enum TunnelPhase {
  Disconnected = 'disconnected',
  Starting = 'starting',
  Waiting = 'waiting',
  Connected = 'connected',
  Stopping = 'stopping',
  Failed = 'failed',
}

export class WireGuardNodeState {
  ID: string = '';
  SentBytes: number = 0;
  ReceivedBytes: number = 0;
  LastHandshake: number = 0;
  Running: boolean = false;
}

export class MixedNodeStatus {
  WireGuard: WireGuardNodeState[] = [];
  Tailnets: NetworkNodeStatus[] = [];
  FlowError: string = '';
  RouteEvents: RouteEvent[] = [];
  Rebinds: number = 0;
  LastRebind: number = 0;
}

export class RouteEvent {
  Time: number = 0;
  Owner: string = '';
  Target: string = '';
  Network: string = '';
  Success: boolean = false;
}

export class TunnelState {
  session: string;
  phase: TunnelPhase;
  message: string;
  sentBytes: number;
  receivedBytes: number;
  lastHandshake: number;
  connectedSince: number = 0;
  updated: number;
  profileIds: string[] = [];
  selectedDNS: number = 0;
  selectedFlows: number = 0;
  directFlows: number = 0;
  mixed: boolean = false;
  // Undefined identifies requests from versions predating persisted route mode.
  useConfigRoutes?: boolean;
  resumeOnForeground: boolean = true;
  tailnetIds: string[] = [];
  wireguardNodes: WireGuardNodeState[] = [];
  tailnetNodes: NetworkNodeStatus[] = [];
  flowError: string = '';
  physicalNetworkId: number = -1;
  localPrefixes: string[] = [];
  networkChanges: number = 0;
  lastNetworkChange: number = 0;
  networkError: string = '';
  routeEvents: RouteEvent[] = [];
  transportRebinds: number = 0;
  lastTransportRebind: number = 0;

  constructor(session: string, phase: TunnelPhase, message: string = '', sentBytes: number = 0,
    receivedBytes: number = 0, lastHandshake: number = 0) {
    this.session = session;
    this.phase = phase;
    this.message = message;
    this.sentBytes = sentBytes;
    this.receivedBytes = receivedBytes;
    this.lastHandshake = lastHandshake;
    this.updated = Date.now();
  }
}

function readState(path: string): TunnelState | undefined {
  try {
    const state = JSON.parse(fileIo.readTextSync(path)) as TunnelState;
    if (!(state.profileIds instanceof Array)) {
      state.profileIds = [];
    }
    state.mixed = state.mixed === true;
    state.resumeOnForeground = state.resumeOnForeground !== false;
    if (!Number.isFinite(state.connectedSince) || state.connectedSince < 0) { state.connectedSince = 0; }
    if (typeof state.useConfigRoutes !== 'boolean') { state.useConfigRoutes = undefined; }
    if (!(state.localPrefixes instanceof Array)) { state.localPrefixes = []; }
    if (!(state.tailnetIds instanceof Array)) { state.tailnetIds = []; }
    if (!(state.wireguardNodes instanceof Array)) { state.wireguardNodes = []; }
    if (!(state.tailnetNodes instanceof Array)) { state.tailnetNodes = []; }
    state.flowError = typeof state.flowError === 'string' ? state.flowError.slice(0, 2048) : '';
    return state;
  } catch (_) {
    return undefined;
  }
}

export function readTunnelRequest(directory: string): TunnelState | undefined {
  return readState(directory + REQUEST_FILE);
}

export function readPublishedTunnelState(directory: string): TunnelState | undefined {
  return readState(directory + STATUS_FILE);
}

export function readTunnelState(directory: string): TunnelState | undefined {
  const request = readTunnelRequest(directory);
  if (request?.phase !== TunnelPhase.Starting) {
    return request;
  }
  const state = readPublishedTunnelState(directory);
  return state?.session === request.session ? state : request;
}

export function writeTunnelRequest(directory: string, state: TunnelState): void {
  writeState(directory + REQUEST_FILE, state);
  // Explicit stop ends the immutable rule snapshot. System extension destruction
  // leaves the Starting request intact, so a same-session restart can reuse it.
  if (state.phase === TunnelPhase.Disconnected && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(state.session)) {
    try {
      const folder = directory + '/session-rules/' + state.session;
      if (fileIo.accessSync(folder)) { fileIo.rmdirSync(folder); }
    } catch (_) { /* Retaining an ended non-secret snapshot must not prevent stopping. */ }
  }
}

export function writeTunnelState(directory: string, state: TunnelState): void {
  writeState(directory + STATUS_FILE, state);
}

function writeState(path: string, state: TunnelState): void {
  const temporary = path + '.' + util.generateRandomUUID() + '.tmp';
  const bytes = util.TextEncoder.create().encodeInto(JSON.stringify(state));
  try {
    const file = fileIo.openSync(temporary,
      fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    try {
      if (fileIo.writeSync(file.fd, bytes.buffer) !== bytes.length) {
        throw new Error('无法更新隧道状态。');
      }
    } finally {
      fileIo.closeSync(file);
    }
    fileIo.renameSync(temporary, path);
  } catch (error) {
    try {
      fileIo.unlinkSync(temporary);
    } catch (_) {
      // The temporary file may not have been created.
    }
    throw error as Error;
  }
}

// Persist cancellation before an asynchronous system stop. The Starting phase is
// retained so the extension can acknowledge onDestroy; recovery skips the cancelled request.
export function cancelTunnelRecovery(directory: string, session: string): void {
  const request = readTunnelRequest(directory);
  if (request?.session !== session || request.phase !== TunnelPhase.Starting) { return; }
  request.resumeOnForeground = false;
  writeTunnelRequest(directory, request);
}

export class TunnelHeartbeat {
  version: number = 1;
  id: string = util.generateRandomUUID();
  session: string = '';
  createdAt: number = Date.now();
}

function readHeartbeat(path: string): TunnelHeartbeat | undefined {
  try {
    if (fileIo.statSync(path).size > 2048) { return undefined; }
    const value = JSON.parse(fileIo.readTextSync(path)) as TunnelHeartbeat;
    if (value.version !== 1 || typeof value.id !== 'string' || typeof value.session !== 'string' ||
      !/^[0-9a-f-]{36}$/i.test(value.id) || !/^[0-9a-f-]{36}$/i.test(value.session) ||
      !Number.isSafeInteger(value.createdAt) || Date.now() - value.createdAt < -5000 ||
      Date.now() - value.createdAt > 30000) { return undefined; }
    return value;
  } catch (_) { return undefined; }
}

function writeHeartbeat(path: string, value: TunnelHeartbeat): void {
  const temporary = path + '.' + util.generateRandomUUID() + '.tmp';
  const bytes = util.TextEncoder.create().encodeInto(JSON.stringify(value));
  try {
    const file = fileIo.openSync(temporary, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
    try {
      if (fileIo.writeSync(file.fd, bytes.buffer) !== bytes.length) { throw new Error('无法保存 VPN 存活检查。'); }
    } finally { fileIo.closeSync(file); }
    fileIo.renameSync(temporary, path);
  } catch (error) {
    try { fileIo.unlinkSync(temporary); } catch (_) { /* No partial heartbeat is published. */ }
    throw error as Error;
  }
}

export function requestTunnelHeartbeat(directory: string, session: string): TunnelHeartbeat {
  const heartbeat = new TunnelHeartbeat(); heartbeat.session = session;
  writeHeartbeat(directory + HEARTBEAT_REQUEST, heartbeat); return heartbeat;
}

export function receivedTunnelHeartbeat(directory: string, heartbeat: TunnelHeartbeat): boolean {
  const response = readHeartbeat(directory + HEARTBEAT_RESPONSE);
  return response?.id === heartbeat.id && response.session === heartbeat.session &&
    response.createdAt >= heartbeat.createdAt;
}

// Called by the extension's independent timer, including during slow transport
// startup. A response proves this session's process is alive, not packet delivery.
export function respondTunnelHeartbeat(directory: string, session: string): void {
  const request = readHeartbeat(directory + HEARTBEAT_REQUEST);
  if (!request || request.session !== session || readTunnelRequest(directory)?.session !== session) { return; }
  const old = readHeartbeat(directory + HEARTBEAT_RESPONSE);
  if (old?.id === request.id && old.session === session) { return; }
  request.createdAt = Date.now(); writeHeartbeat(directory + HEARTBEAT_RESPONSE, request);
}

// UI-process gate for asynchronous configuration transactions before their
// durable journal is reserved. It is separate from the user's persistent stop
// intent: an internal stop must never erase a later explicit cancellation.
let tunnelMutationActive: boolean = false;
export function setTunnelMutationActive(active: boolean): void { tunnelMutationActive = active; }
export function isTunnelMutationActive(): boolean { return tunnelMutationActive; }
