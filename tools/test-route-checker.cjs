const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const Module = require('node:module');
const ts = require('/Applications/DevEco-Studio.app/Contents/tools/ohpm/node_modules/typescript');
const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'route-checker-'));
const fileIo = {
  OpenMode: { CREATE: 1, WRITE_ONLY: 2, TRUNC: 4 }, accessSync: fs.existsSync,
  statSync: fs.statSync, readTextSync: p => fs.readFileSync(p, 'utf8'),
  openSync: p => ({ fd: fs.openSync(p, 'w') }), writeSync: (fd, data) => fs.writeSync(fd, Buffer.from(data)),
  closeSync: f => fs.closeSync(f.fd), renameSync: fs.renameSync, unlinkSync: fs.unlinkSync,
};
const originalLoad = Module._load;
Module._load = function (id, parent, isMain) {
  if (id === '@kit.CoreFileKit') { return { fileIo }; }
  if (id === '@kit.ArkTS') { return { util: { generateRandomUUID: crypto.randomUUID,
    TextEncoder: { create: () => ({ encodeInto: s => new TextEncoder().encode(s) }) } } }; }
  return originalLoad.call(this, id, parent, isMain);
};
require.extensions['.ets'] = (module, filename) => {
  const result = ts.transpileModule(fs.readFileSync(filename, 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }, fileName: filename,
  });
  module._compile(result.outputText, filename);
};
const checker = require('../entry/src/main/ets/model/RouteChecker.ets');
const tunnel = require('../entry/src/main/ets/model/TunnelState.ets');
const requestFile = path.join(directory, 'route-check-request.json');
const responseFile = path.join(directory, 'route-check-response.json');
const session = crypto.randomUUID();
function state(phase = tunnel.TunnelPhase.Connected, id = session, updated = Date.now()) {
  const request = new tunnel.TunnelState(id, tunnel.TunnelPhase.Starting); request.updated = updated;
  tunnel.writeTunnelRequest(directory, request);
  const status = new tunnel.TunnelState(id, phase); status.updated = updated;
  tunnel.writeTunnelState(directory, status);
}
function result(input = 'example.com') {
  return { Input: input, Host: 'example.com', InputKind: 'domain', Decision: { Kind: 'direct', Owner: '', NetworkID: '',
    NetworkName: '', ReasonCode: 'unmatched', Reason: 'normal network', Rule: '', RawIPMayBypassVPN: false,
    SyntheticDNS: false, DeviceIndex: -1 }, Addresses: [], DNS: { Status: 'not_needed', Source: '', Error: '' }, Warnings: [], Error: '' };
}
try {
  assert.throws(() => checker.requestRouteCheck(directory, 'example.com'), /先.*启动/);
  for (const input of ['', ' ', undefined, 4, 'a b', 'a\nb', 'a\u0000b', 'a\u007fb', 'x'.repeat(1025)]) {
    assert.throws(() => checker.normalizeCheckInput(input), /有效/);
  }
  for (const input of ['disk-station', '192.168.72.60', '2001:db8::1', 'https://example.com/path?q=1']) {
    assert.equal(checker.normalizeCheckInput(' ' + input + ' '), input);
  }
  state();
  let request = checker.requestRouteCheck(directory, ' example.com ');
  assert.equal(request.Target, 'example.com'); assert.equal(request.session, session);
  assert.equal(checker.readRouteCheckRequest(directory, session).id, request.id);
  assert.equal(checker.readRouteCheckRequest(directory, crypto.randomUUID()), undefined);
  checker.writeRouteCheckResponse(directory, request, result());
  assert.equal(checker.readRouteCheckResponse(directory, request).result.Decision.Kind, 'direct');

  const validRequest = fs.readFileSync(requestFile, 'utf8');
  for (const mutate of [doc => { doc.id = '-'.repeat(36); }, doc => { doc.version = 2; },
    doc => { doc.createdAt = Date.now() - 31000; }, doc => { doc.createdAt = Date.now() + 10000; },
    doc => { doc.ResolveDNS = 'true'; }, doc => { doc.Target = 'not a host'; },
    doc => { doc.Target = ' example.com'; }]) {
    const corrupted = JSON.parse(validRequest); mutate(corrupted); fs.writeFileSync(requestFile, JSON.stringify(corrupted));
    assert.equal(checker.readRouteCheckRequest(directory, session), undefined);
  }
  for (const bytes of ['{', ' '.repeat(8193)]) {
    fs.writeFileSync(requestFile, bytes); assert.equal(checker.readRouteCheckRequest(directory, session), undefined);
  }
  fs.writeFileSync(requestFile, validRequest);

  // Old asynchronous replies cannot replace a newer input's response.
  const newer = checker.requestRouteCheck(directory, 'new.example');
  const responseBeforeOld = fs.readFileSync(responseFile, 'utf8');
  checker.writeRouteCheckResponse(directory, request, result());
  assert.equal(fs.readFileSync(responseFile, 'utf8'), responseBeforeOld);
  assert.equal(checker.readRouteCheckResponse(directory, newer), undefined);
  checker.writeRouteCheckResponse(directory, newer, result('new.example'));
  assert.equal(checker.readRouteCheckResponse(directory, newer).result.Input, 'new.example');
  assert.equal(checker.readRouteCheckResponse(directory, request), undefined);
  request = newer;

  const validResponse = fs.readFileSync(responseFile, 'utf8');
  for (const mutate of [doc => { doc.createdAt = Date.now() - 31000; }, doc => { doc.createdAt = Date.now() + 10000; },
    doc => { doc.session = crypto.randomUUID(); }, doc => { doc.id = crypto.randomUUID(); },
    doc => { doc.result.Input = 'wrong.example'; }, doc => { doc.result.Decision.RawIPMayBypassVPN = 'false'; },
    doc => { doc.result.DNS.Error = 1; }, doc => { doc.error = 1; },
    doc => { doc.result.Addresses = [{ IP: '192.0.2.1', Decision: {} }]; }]) {
    const corrupted = JSON.parse(validResponse); mutate(corrupted); fs.writeFileSync(responseFile, JSON.stringify(corrupted));
    assert.equal(checker.readRouteCheckResponse(directory, request), undefined);
  }
  fs.writeFileSync(responseFile, validResponse);
  for (const invalid of [{}, { ...result(), Warnings: [1] }, { ...result(), Addresses: new Array(257).fill({}) },
    { ...result(), Decision: { Kind: 'direct' } }, { ...result(), Input: 1 }]) {
    assert.throws(() => checker.parseRouteCheckResult(JSON.stringify(invalid)), /无效/);
  }
  assert.throws(() => checker.parseRouteCheckResult(' '.repeat(131073)), /过大/);
  assert.throws(() => checker.readRouteCheckResponse(directory, { ...request, createdAt: Date.now() - 31000 }), /过期/);

  // Current session/phase is checked on both publication and consumption.
  for (const phase of [tunnel.TunnelPhase.Stopping, tunnel.TunnelPhase.Disconnected, tunnel.TunnelPhase.Failed]) {
    state(phase); const before = fs.readFileSync(responseFile, 'utf8');
    checker.writeRouteCheckResponse(directory, request, undefined, 'late error');
    assert.equal(fs.readFileSync(responseFile, 'utf8'), before);
    assert.throws(() => checker.readRouteCheckResponse(directory, request), /停止或变更/);
    assert.throws(() => checker.requestRouteCheck(directory, 'example.com'), /先.*启动/);
  }
  state(tunnel.TunnelPhase.Connected, crypto.randomUUID());
  checker.writeRouteCheckResponse(directory, request, undefined, 'old session');
  assert.equal(fs.readFileSync(responseFile, 'utf8'), validResponse);
  assert.throws(() => checker.readRouteCheckResponse(directory, request), /停止或变更/);
  state(tunnel.TunnelPhase.Connected, session, Date.now() - 31000);
  assert.throws(() => checker.requestRouteCheck(directory, 'example.com'), /先.*启动/);
  state();

  // Atomic write failures preserve each previous complete IPC document.
  for (const operation of ['writeSync', 'renameSync']) {
    const original = fileIo[operation], previousRequest = fs.readFileSync(requestFile, 'utf8');
    fileIo[operation] = operation === 'writeSync' ? () => 1 : () => { throw new Error('simulated replacement failure'); };
    try {
      assert.throws(() => checker.requestRouteCheck(directory, 'failure.example'));
      assert.equal(fs.readFileSync(requestFile, 'utf8'), previousRequest);
      assert.throws(() => checker.writeRouteCheckResponse(directory, request, undefined, 'failure'));
      assert.equal(fs.readFileSync(responseFile, 'utf8'), validResponse);
    } finally { fileIo[operation] = original; }
    assert.equal(fs.readdirSync(directory).some(name => name.endsWith('.tmp')), false);
  }
  checker.writeRouteCheckResponse(directory, request, undefined, 'x'.repeat(2000));
  assert.equal(checker.readRouteCheckResponse(directory, request).error.length, 1024);
  console.log('Route checker: active session IPC, input/result validation, stale/cross-session/late response guards and atomic request/response failures passed');
} finally { fs.rmSync(directory, { recursive: true, force: true }); Module._load = originalLoad; }
