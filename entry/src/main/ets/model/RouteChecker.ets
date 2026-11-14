import { util } from '@kit.ArkTS';
import { fileIo } from '@kit.CoreFileKit';
import { readTunnelState, TunnelPhase } from './TunnelState';

const REQUEST: string = '/route-check-request.json';
const RESPONSE: string = '/route-check-response.json';
const MAX_AGE: number = 30000;
const UUID: RegExp = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export interface RouteDecision {
  Kind: string;
  Owner: string;
  NetworkID: string;
  NetworkName: string;
  ReasonCode: string;
  Reason: string;
  Rule: string;
  RawIPMayBypassVPN: boolean;
  SyntheticDNS: boolean;
  DeviceIndex: number;
}
export interface RouteAddress { IP: string; Decision: RouteDecision; }
export interface RouteDNS { Status: string; Source: string; Error: string; }
export interface RouteCheckResult {
  Input: string;
  Host: string;
  InputKind: string;
  Decision: RouteDecision;
  Addresses: RouteAddress[];
  DNS: RouteDNS;
  Warnings: string[];
  Error: string;
}
export class RouteCheckRequest {
  version: number = 1;
  id: string = util.generateRandomUUID();
  session: string = '';
  createdAt: number = Date.now();
  Target: string = '';
  ResolveDNS: boolean = true;
}
export class RouteCheckResponse {
  version: number = 1;
  id: string = '';
  session: string = '';
  createdAt: number = Date.now();
  result?: RouteCheckResult;
  error: string = '';
}

function fresh(at: number): boolean {
  return Number.isFinite(at) && Date.now() - at >= -5000 && Date.now() - at < MAX_AGE;
}
function read(path: string, limit: number): string {
  if (fileIo.statSync(path).size > limit) { throw new Error('路由检查数据过大。'); }
  return fileIo.readTextSync(path);
}
function write(path: string, data: string): void {
  const temporary = path + '.' + util.generateRandomUUID() + '.tmp';
  const bytes = util.TextEncoder.create().encodeInto(data);
  try {
    const file = fileIo.openSync(temporary, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
    try {
      if (fileIo.writeSync(file.fd, bytes.buffer) !== bytes.length) { throw new Error('无法保存路由检查请求。'); }
    } finally { fileIo.closeSync(file); }
    fileIo.renameSync(temporary, path);
  } catch (error) {
    try { fileIo.unlinkSync(temporary); } catch (_) { /* No partial request is published. */ }
    throw error as Error;
  }
}
export function normalizeCheckInput(input: string): string {
  if (typeof input !== 'string') { throw new Error('请输入有效的 IP、域名或 HTTP / HTTPS 地址。'); }
  const value = input.trim();
  if (!value || value.length > 1024 || /[\u0000-\u0020\u007f]/.test(value)) {
    throw new Error('请输入有效的 IP、域名或 HTTP / HTTPS 地址。');
  }
  return value;
}
export function requestRouteCheck(directory: string, input: string): RouteCheckRequest {
  const target = normalizeCheckInput(input);
  const state = readTunnelState(directory);
  if (!state || !fresh(state.updated) || !UUID.test(state.session) ||
    ![TunnelPhase.Starting, TunnelPhase.Connected, TunnelPhase.Waiting].includes(state.phase)) {
    throw new Error('请先在连接页启动连接，再检查当前生效的路由。');
  }
  const request = new RouteCheckRequest(); request.session = state.session; request.Target = target;
  write(directory + REQUEST, JSON.stringify(request)); return request;
}
export function readRouteCheckRequest(directory: string, session: string): RouteCheckRequest | undefined {
  try {
    const request = JSON.parse(read(directory + REQUEST, 8192)) as RouteCheckRequest;
    if (request.version !== 1 || !UUID.test(request.id) || !UUID.test(request.session) || request.session !== session || !fresh(request.createdAt) ||
      request.ResolveDNS !== true || typeof request.Target !== 'string' || normalizeCheckInput(request.Target) !== request.Target) { return undefined; }
    return request;
  } catch (_) { return undefined; }
}
function validDecision(decision: RouteDecision): boolean {
  return !!decision && typeof decision.Kind === 'string' && typeof decision.Owner === 'string' &&
    typeof decision.NetworkID === 'string' && typeof decision.NetworkName === 'string' &&
    typeof decision.ReasonCode === 'string' && typeof decision.Reason === 'string' && typeof decision.Rule === 'string' &&
    typeof decision.RawIPMayBypassVPN === 'boolean' && typeof decision.SyntheticDNS === 'boolean' &&
    Number.isInteger(decision.DeviceIndex);
}
export function parseRouteCheckResult(json: string): RouteCheckResult {
  if (json.length > 131072) { throw new Error('路由检查结果过大。'); }
  const result = JSON.parse(json) as RouteCheckResult;
  if (!result || typeof result.Input !== 'string' || typeof result.Host !== 'string' || typeof result.InputKind !== 'string' ||
    typeof result.Error !== 'string' || !validDecision(result.Decision) ||
    !(result.Addresses instanceof Array) || result.Addresses.length > 256 ||
    !(result.Warnings instanceof Array) || result.Warnings.length > 32 || !result.DNS || typeof result.DNS.Status !== 'string' ||
    typeof result.DNS.Source !== 'string' || typeof result.DNS.Error !== 'string' ||
    result.Addresses.some((item: RouteAddress): boolean => !item || typeof item.IP !== 'string' || !validDecision(item.Decision)) ||
    result.Warnings.some((value: string): boolean => typeof value !== 'string')) { throw new Error('路由检查结果无效。'); }
  return result;
}
export function writeRouteCheckResponse(directory: string, request: RouteCheckRequest,
  result: RouteCheckResult | undefined, error: string = ''): void {
  if (readRouteCheckRequest(directory, request.session)?.id !== request.id) { return; }
  const state = readTunnelState(directory);
  if (!state || state.session !== request.session || !fresh(state.updated) ||
    ![TunnelPhase.Starting, TunnelPhase.Connected, TunnelPhase.Waiting].includes(state.phase)) { return; }
  const response = new RouteCheckResponse(); response.id = request.id; response.session = request.session;
  response.result = result; response.error = error.slice(0, 1024);
  write(directory + RESPONSE, JSON.stringify(response));
}
export function readRouteCheckResponse(directory: string, request: RouteCheckRequest): RouteCheckResponse | undefined {
  if (!fresh(request.createdAt)) { throw new Error('路由检查已过期，请重新检查。'); }
  const state = readTunnelState(directory);
  if (!state || state.session !== request.session || !fresh(state.updated) ||
    ![TunnelPhase.Starting, TunnelPhase.Connected, TunnelPhase.Waiting].includes(state.phase)) {
    throw new Error('连接已停止或变更，请重新检查。');
  }
  try {
    const response = JSON.parse(read(directory + RESPONSE, 131072)) as RouteCheckResponse;
    if (response.version !== 1 || response.id !== request.id || response.session !== request.session ||
      !fresh(response.createdAt) || typeof response.error !== 'string') { return undefined; }
    if (response.result) {
      response.result = parseRouteCheckResult(JSON.stringify(response.result));
      if (response.result.Input !== request.Target) { return undefined; }
    }
    if (!response.result && !response.error) { return undefined; }
    return response;
  } catch (_) { return undefined; }
}
