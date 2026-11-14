const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const Module = require('node:module');
const ts = require('/Applications/DevEco-Studio.app/Contents/tools/ohpm/node_modules/typescript');
const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'vpn-diagnostics-'));
let shortWrite = false, failRename = false;
let opened = 0, closed = 0;
const fileIo = {
  OpenMode: { CREATE: 1, WRITE_ONLY: 2, TRUNC: 4, APPEND: 8 }, accessSync: fs.existsSync,
  statSync: fs.statSync, readTextSync: p => fs.readFileSync(p, 'utf8'),
  openSync: (p, mode) => { const fd = fs.openSync(p, mode & 8 ? 'a' : 'w'); opened++; return { fd }; },
  writeSync: (fd, bytes) => shortWrite ? fs.writeSync(fd, Buffer.from(bytes).subarray(0, 3)) : fs.writeSync(fd, Buffer.from(bytes)),
  closeSync: file => { fs.closeSync(file.fd); closed++; },
  renameSync: (a, b) => { if (failRename) throw new Error('rename failure'); fs.renameSync(a, b); },
  unlinkSync: fs.unlinkSync,
};
const originalLoad = Module._load;
Module._load = function (id, parent, isMain) {
  if (id === '@kit.CoreFileKit') return { fileIo };
  if (id === '@kit.ArkTS') return { util: { generateRandomUUID: crypto.randomUUID,
    TextEncoder: { create: () => ({ encodeInto: s => new TextEncoder().encode(s) }) } } };
  return originalLoad.call(this, id, parent, isMain);
};
require.extensions['.ets'] = (module, filename) => {
  const result = ts.transpileModule(fs.readFileSync(filename, 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }, fileName: filename,
  });
  module._compile(result.outputText, filename);
};
const { VpnDiagnostics, parseVpnResources, readVpnResourceSample } = require('../entry/src/main/ets/model/VpnDiagnostics.ets');
function resources() {
  return { version: 1, sampledAt: Date.now(), pid: 12345, engine: 'wireguard', engineUptimeMs: 1000,
    process: { fdCount: { value: 90, valid: true }, rssBytes: { value: 100 * 1024 * 1024, valid: true },
      oomScoreAdj: { value: -100, valid: true }, swapBytes: { value: 0, valid: false } },
    go: { heapObjectBytes: { value: 40000000, valid: true }, goroutines: { value: 150, valid: true } },
    activity: { groups: 1, tailnetNodes: 1, activeFlows: 3 } };
}
try {
  const session = crypto.randomUUID();
  const diagnostics = new VpnDiagnostics(directory, session, 'wireguard');
  assert.equal(diagnostics.beginSample(1000), true);
  assert.equal(diagnostics.beginSample(60999), false);
  assert.equal(diagnostics.beginSample(61000), true);
  assert.equal(diagnostics.beginSample(100), true, 'clock rollback must not disable sampling forever');
  const input = resources(); input.secret = 'NEVER_PERSIST_THIS'; input.process.fdCount.secret = 'NEVER_PERSIST_THIS';
  diagnostics.sample(JSON.stringify(input));
  let latest = readVpnResourceSample(directory);
  assert.equal(latest.session, session);
  assert.equal(latest.resources.process.fdCount.value, 90);
  assert.equal(latest.resources.process.oomScoreAdj.value, -100);
  assert.equal(latest.resources.process.threads.valid, false);
  assert.equal(latest.resources.process.swapBytes.valid, false);
  assert.equal(latest.resources.go.heapObjectBytes.value, 40000000);
  assert.equal(fs.readFileSync(path.join(directory, 'vpn-resource-latest.json'), 'utf8').includes('NEVER_PERSIST_THIS'), false);

  for (const raw of ['null', '{}', 'broken', ' '.repeat(8193), JSON.stringify({ ...resources(), pid: -1 }),
    JSON.stringify({ ...resources(), engine: 'unknown' })]) {
    assert.throws(() => parseVpnResources(raw));
    assert.doesNotThrow(() => diagnostics.sample(raw));
    assert.equal(readVpnResourceSample(directory).resources.pid, 12345);
  }
  const malformed = resources(); malformed.process.rssBytes = { value: -1, valid: true };
  malformed.go.goroutines = { value: 12, valid: 'true' };
  assert.equal(parseVpnResources(JSON.stringify(malformed)).process.rssBytes.valid, false);
  assert.equal(parseVpnResources(JSON.stringify(malformed)).go.goroutines.valid, false);
  diagnostics.memoryPressure(2); diagnostics.memoryPressure(-1);
  assert.ok(fs.readFileSync(path.join(directory, 'vpn-diagnostics.jsonl'), 'utf8').includes('"memoryLevel":2'));

  // Several hours of samples rotate bounded journals without unbounded memory or files.
  for (let i = 0; i < 500; i++) diagnostics.sample(JSON.stringify(resources()));
  assert.ok(fs.statSync(path.join(directory, 'vpn-diagnostics.jsonl')).size <= 131072);
  assert.ok(fs.statSync(path.join(directory, 'vpn-diagnostics.previous.jsonl')).size <= 131072);
  assert.equal(fs.readdirSync(directory).length, 3);
  for (const name of ['vpn-diagnostics.jsonl', 'vpn-diagnostics.previous.jsonl']) {
    for (const line of fs.readFileSync(path.join(directory, name), 'utf8').trim().split('\n')) JSON.parse(line);
  }
  const before = fs.readFileSync(path.join(directory, 'vpn-resource-latest.json'), 'utf8');
  shortWrite = true;
  assert.doesNotThrow(() => diagnostics.sample(JSON.stringify(resources())));
  shortWrite = false;
  assert.equal(fs.readFileSync(path.join(directory, 'vpn-resource-latest.json'), 'utf8'), before);
  failRename = true;
  assert.doesNotThrow(() => diagnostics.sample(JSON.stringify(resources())));
  failRename = false;
  assert.equal(fs.readFileSync(path.join(directory, 'vpn-resource-latest.json'), 'utf8'), before);
  assert.equal(fs.readdirSync(directory).filter(name => name.endsWith('.tmp')).length, 0);
  assert.equal(opened, closed, 'all sample and journal descriptors close on errors');
  console.log('VPN diagnostics: privacy filtering, unavailable metrics, sampling, bounded rotation and failure isolation passed.');
} finally {
  Module._load = originalLoad;
  fs.rmSync(directory, { recursive: true, force: true });
}
