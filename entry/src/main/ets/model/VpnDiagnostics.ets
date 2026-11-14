import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';

// Two bounded files retain evidence across process death without recording
// endpoints, DNS names, account information, configurations or descriptor paths.
const JOURNAL: string = '/vpn-diagnostics.jsonl';
const PREVIOUS: string = '/vpn-diagnostics.previous.jsonl';
const LATEST: string = '/vpn-resource-latest.json';
const MAX_FILE_BYTES: number = 131072;
const MAX_SAMPLE_BYTES: number = 8192;
const SAMPLE_INTERVAL: number = 60000;

export interface ResourceMetric { value: number; valid: boolean; }
export interface ProcessResources {
  fdCount: ResourceMetric;
  rssBytes: ResourceMetric;
  peakRssBytes: ResourceMetric;
  virtualBytes: ResourceMetric;
  swapBytes: ResourceMetric;
  threads: ResourceMetric;
  startTimeTicks: ResourceMetric;
  oomScoreAdj: ResourceMetric;
}
export interface GoResources {
  heapObjectBytes: ResourceMetric;
  heapReservedBytes: ResourceMetric;
  heapReleasedBytes: ResourceMetric;
  totalBytes: ResourceMetric;
  stackBytes: ResourceMetric;
  goroutines: ResourceMetric;
  gcCycles: ResourceMetric;
}
export interface ResourceActivity {
  groups: number;
  wireguardDevices: number;
  tailnetNodes: number;
  gateways: number;
  activeFlows: number;
  trackedConnections: number;
  directFlows: number;
  dnsAliases: number;
}
export interface VpnResourceUsage {
  version: number;
  sampledAt: number;
  pid: number;
  engine: string;
  engineUptimeMs: number;
  process: ProcessResources;
  go: GoResources;
  activity: ResourceActivity;
}
export class VpnDiagnosticRecord {
  version: number = 1;
  at: number = Date.now();
  session: string = '';
  instance: string = '';
  ability: string = '';
  event: string = '';
  attempt: number = 0;
  memoryLevel?: number;
  resources?: VpnResourceUsage;
}

function metric(input: ResourceMetric, signed: boolean = false): ResourceMetric {
  const valid = input !== null && typeof input === 'object' && input.valid === true &&
    Number.isFinite(input.value) && (signed || input.value >= 0);
  return { value: valid ? input.value : 0, valid: valid };
}
function count(input: number): number {
  return Number.isSafeInteger(input) && input >= 0 ? input : 0;
}
export function parseVpnResources(raw: string): VpnResourceUsage {
  if (raw.length > MAX_SAMPLE_BYTES) { throw new Error('Resource sample too large'); }
  const input = JSON.parse(raw) as VpnResourceUsage;
  if (input === null || input.version !== 1 || !Number.isSafeInteger(input.pid) || input.pid <= 0 ||
    !Number.isFinite(input.sampledAt) || !Number.isFinite(input.engineUptimeMs) || input.engineUptimeMs < 0 ||
    (input.engine !== 'wireguard' && input.engine !== 'tailnet') || !input.process || !input.go || !input.activity) {
    throw new Error('Invalid resource sample');
  }
  const p = input.process;
  const g = input.go;
  const a = input.activity;
  // Copy only known numeric fields. Future native fields cannot accidentally
  // add private strings to the diagnostic journal.
  return {
    version: 1, sampledAt: input.sampledAt, pid: input.pid, engine: input.engine,
    engineUptimeMs: input.engineUptimeMs,
    process: { fdCount: metric(p.fdCount), rssBytes: metric(p.rssBytes), peakRssBytes: metric(p.peakRssBytes),
      virtualBytes: metric(p.virtualBytes), swapBytes: metric(p.swapBytes), threads: metric(p.threads),
      startTimeTicks: metric(p.startTimeTicks), oomScoreAdj: metric(p.oomScoreAdj, true) },
    go: { heapObjectBytes: metric(g.heapObjectBytes), heapReservedBytes: metric(g.heapReservedBytes),
      heapReleasedBytes: metric(g.heapReleasedBytes), totalBytes: metric(g.totalBytes), stackBytes: metric(g.stackBytes),
      goroutines: metric(g.goroutines), gcCycles: metric(g.gcCycles) },
    activity: { groups: count(a.groups), wireguardDevices: count(a.wireguardDevices), tailnetNodes: count(a.tailnetNodes),
      gateways: count(a.gateways), activeFlows: count(a.activeFlows), trackedConnections: count(a.trackedConnections),
      directFlows: count(a.directFlows), dnsAliases: count(a.dnsAliases) }
  };
}

function writeFile(path: string, text: string, append: boolean): void {
  const bytes = util.TextEncoder.create().encodeInto(text);
  const file = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY |
    (append ? fileIo.OpenMode.APPEND : fileIo.OpenMode.TRUNC));
  try {
    if (fileIo.writeSync(file.fd, bytes.buffer) !== bytes.length) { throw new Error('Short diagnostic write'); }
  } finally { fileIo.closeSync(file); }
}

export class VpnDiagnostics {
  private directory: string;
  private session: string;
  private ability: string;
  private instance: string = util.generateRandomUUID();
  private lastSample: number = -1;
  constructor(directory: string, session: string, ability: string) {
    this.directory = directory;
    this.session = /^[0-9a-f-]{8,64}$/i.test(session) ? session : '';
    this.ability = ['wireguard', 'tailnet', 'multi-tailnet'].includes(ability) ? ability : 'vpn';
  }
  private record(event: string, attempt: number): VpnDiagnosticRecord {
    const record = new VpnDiagnosticRecord();
    record.session = this.session; record.instance = this.instance; record.ability = this.ability;
    record.event = event; record.attempt = count(attempt);
    return record;
  }
  private append(record: VpnDiagnosticRecord): void {
    const path = this.directory + JOURNAL;
    const text = JSON.stringify(record) + '\n';
    if (text.length > MAX_SAMPLE_BYTES) { return; }
    try {
      if (fileIo.accessSync(path) && fileIo.statSync(path).size + text.length > MAX_FILE_BYTES) {
        const previous = this.directory + PREVIOUS;
        if (fileIo.accessSync(previous)) { fileIo.unlinkSync(previous); }
        fileIo.renameSync(path, previous);
      }
      writeFile(path, text, true);
    } catch (_) { /* Diagnostic storage must not stop the VPN. */ }
  }
  event(event: string, attempt: number = 0): void {
    if (!['created', 'starting', 'running', 'recovering', 'failed', 'destroyed', 'sample-unavailable'].includes(event)) { return; }
    this.append(this.record(event, attempt));
  }
  memoryPressure(level: number): void {
    if (!Number.isInteger(level) || level < 0 || level > 3) { return; }
    const record = this.record('memory-pressure', 0); record.memoryLevel = level;
    this.append(record);
  }
  shouldSample(now: number = Date.now()): boolean {
    return this.lastSample < 0 || now < this.lastSample || now - this.lastSample >= SAMPLE_INTERVAL;
  }
  // Reserve before calling a native/async sampler, including on failure.
  beginSample(now: number = Date.now()): boolean {
    if (!this.shouldSample(now)) { return false; }
    this.lastSample = now; return true;
  }
  sample(raw: string): void {
    let record: VpnDiagnosticRecord;
    try { record = this.record('resources', 0); record.resources = parseVpnResources(raw); }
    catch (_) { this.event('sample-unavailable'); return; }
    this.append(record);
    const temporary = this.directory + LATEST + '.' + this.instance + '.tmp';
    try {
      writeFile(temporary, JSON.stringify(record), false);
      fileIo.renameSync(temporary, this.directory + LATEST);
    } catch (_) {
      try { fileIo.unlinkSync(temporary); } catch (_) { /* No partial latest sample is published. */ }
    }
  }
}

export function readVpnResourceSample(directory: string): VpnDiagnosticRecord | undefined {
  try {
    const path = directory + LATEST;
    if (fileIo.statSync(path).size > MAX_SAMPLE_BYTES) { return undefined; }
    const record = JSON.parse(fileIo.readTextSync(path)) as VpnDiagnosticRecord;
    if (record.version !== 1 || record.event !== 'resources' || !record.resources) { return undefined; }
    record.resources = parseVpnResources(JSON.stringify(record.resources));
    return record;
  } catch (_) { return undefined; }
}
