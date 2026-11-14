const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const Module = require('node:module');
const ts = require('/Applications/DevEco-Studio.app/Contents/tools/ohpm/node_modules/typescript');
const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'multi-network-session-'));
const fileIo = {
  OpenMode: { READ_ONLY: 0, CREATE: 1, WRITE_ONLY: 2, TRUNC: 4 }, accessSync: fs.existsSync,
  statSync: fs.statSync, readTextSync: p => fs.readFileSync(p, 'utf8'), listFileSync: fs.readdirSync,
  mkdirSync: (p, recursive) => fs.mkdirSync(p, { recursive }),
  openSync: (p, mode) => ({ fd: fs.openSync(p, mode & 2 ? 'w' : 'r') }),
  writeSync: (fd, data) => fs.writeSync(fd, Buffer.from(data)), fsyncSync: fs.fsyncSync,
  closeSync: f => fs.closeSync(f.fd), renameSync: fs.renameSync, unlinkSync: fs.unlinkSync,
  copyFileSync: fs.copyFileSync, rmdirSync: p => fs.rmSync(p, { recursive: true }),
};
const started = []; let failRead = false, networkHook, vpnCreates = 0, stopCalls = 0;
const originalLoad = Module._load, oldInterval = global.setInterval, oldClear = global.clearInterval;
const intervals = new Set(); let nextTimer = 1;
global.setInterval = () => { const id = nextTimer++; intervals.add(id); return id; };
global.clearInterval = id => intervals.delete(id);
Module._load = function (id, parent, isMain) {
  if (id === '@kit.CoreFileKit') { return { fileIo }; }
  if (id === '@kit.ArkTS') { return { util: { generateRandomUUID: crypto.randomUUID,
    TextEncoder: { create: () => ({ encodeInto: s => new TextEncoder().encode(s) }) } } }; }
  if (id === '@kit.NetworkKit') { return {
    VpnExtensionAbility: class {},
    connection: {
      getDefaultNet: async () => ({ netId: 1 }),
      getConnectionProperties: async () => { if (networkHook) { await networkHook(); } return { dnses: [{ address: '9.9.9.9' }] }; },
    },
    vpnExtension: { createVpnConnection: () => ({ create: async () => { vpnCreates++; return 42; }, destroy: async () => {} }) },
  }; }
  if (id === 'libtailnet.so') { return { call: async (operation, value) => {
    if (operation === 'multi') {
      const config = JSON.parse(fs.readFileSync(value, 'utf8'));
      started.push({ config, database: fs.readFileSync(config.DatabasePath, 'utf8') }); return '';
    }
    if (operation === 'status') { return JSON.stringify({ Nodes: [], ReadError: failRead ? 'simulated tunnel error' : '' }); }
    if (operation === 'stop') { stopCalls++; }
    return '';
  } }; }
  return originalLoad.call(this, id, parent, isMain);
};
require.extensions['.ets'] = (module, filename) => {
  const result = ts.transpileModule(fs.readFileSync(filename, 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }, fileName: filename,
  });
  module._compile(result.outputText, filename);
};
const networks = require('../entry/src/main/ets/model/NetworkProfiles.ets');
const split = require('../entry/src/main/ets/model/SplitTunnel.ets');
const groups = require('../entry/src/main/ets/model/AddressGroups.ets');
const Ability = require('../entry/src/main/ets/vpn/MultiNetworkVpnAbility.ets').default;
const settle = async () => { for (let i = 0; i < 20; i++) { await new Promise(resolve => setImmediate(resolve)); } };
function ability() { const result = new Ability(); result.context = { filesDir: directory, applicationInfo: { name: 'test' } }; return result; }
async function run() {
  const profile = new networks.NetworkProfile(); profile.ID = crypto.randomUUID(); profile.Name = 'Test'; profile.Hostname = 'old-device';
  networks.saveNetworkProfiles(directory, [profile]);
  const addressGroup = groups.saveAddressGroup(directory, new groups.AddressGroup('', 'Private sites',
    ['old-group.example'], ['10.44.0.0/16', 'fd44::/48']));
  split.writeProfileRules(directory, profile.ID, new split.ProfileRules(true, false, ['site'], ['old.example'], [], [addressGroup.id]));
  fs.writeFileSync(path.join(directory, 'dlc.dat'), 'original-db');
  const first = ability(); first.onCreate(); await settle();
  assert.equal(first.active, true); assert.equal(started.length, 1);
  assert.deepEqual(started[0].config.Profiles[0].Domains, ['old.example', 'old-group.example']);
  assert.deepEqual(started[0].config.Profiles[0].CIDRs, ['10.44.0.0/16', 'fd44::/48']);
  const snapshotFolder = path.join(directory, 'session-rules', first.session);
  assert.equal(fs.existsSync(snapshotFolder), true);
  profile.Hostname = 'new-device'; networks.saveNetworkProfiles(directory, [profile]);
  split.writeProfileRules(directory, profile.ID, new split.ProfileRules(true, false, ['site'], ['new.example'], [], [addressGroup.id]));
  groups.saveAddressGroup(directory, new groups.AddressGroup(addressGroup.id, 'Changed private sites',
    ['new-group.example'], ['10.46.0.0/16', 'fd46::/48']));
  fs.writeFileSync(path.join(directory, 'dlc.dat'), 'updated-db');
  failRead = true; await first.poll(); assert.equal(first.active, false);
  assert.equal(fs.existsSync(snapshotFolder), true, 'automatic recovery retains the snapshot');
  failRead = false; first.retryAt = 0; await first.poll();
  assert.equal(started.length, 2); assert.equal(started[1].database, 'original-db');
  assert.equal(started[1].config.Directory, directory);
  assert.equal(started[1].config.Profiles[0].Hostname, 'old-device');
  assert.deepEqual(started[1].config.Profiles[0].Domains, ['old.example', 'old-group.example']);
  assert.deepEqual(started[1].config.Profiles[0].CIDRs, ['10.44.0.0/16', 'fd44::/48']);
  assert.equal(started[1].config.DatabasePath, started[0].config.DatabasePath);
  first.onDestroy(); await settle();
  assert.equal(fs.existsSync(snapshotFolder), false);
  assert.equal(networks.readNetworkStatus(directory).active, false);
  const stoppedCount = stopCalls; first.onDestroy(); await settle(); assert.equal(stopCalls, stoppedCount);

  const next = ability(); next.onCreate(); await settle();
  assert.equal(started[2].database, 'updated-db');
  assert.equal(started[2].config.Profiles[0].Hostname, 'new-device');
  assert.deepEqual(started[2].config.Profiles[0].Domains, ['new.example', 'new-group.example']);
  assert.deepEqual(started[2].config.Profiles[0].CIDRs, ['10.46.0.0/16', 'fd46::/48']);
  next.onDestroy(); await settle();

  // Stop during asynchronous transport setup must never start a native manager
  // or system VPN and must clean up the already-frozen rules after setup returns.
  let release, entered;
  const blocked = new Promise(resolve => { entered = resolve; });
  networkHook = async () => { entered(); await new Promise(resolve => { release = resolve; }); };
  const stopping = ability(); const beforeStarts = started.length, beforeCreates = vpnCreates;
  stopping.onCreate(); await blocked;
  const stoppedFolder = path.join(directory, 'session-rules', stopping.session);
  assert.equal(fs.existsSync(stoppedFolder), true);
  stopping.onDestroy(); release(); await settle(); networkHook = undefined;
  assert.equal(started.length, beforeStarts); assert.equal(vpnCreates, beforeCreates);
  assert.equal(fs.existsSync(stoppedFolder), false); assert.equal(intervals.size, 0);
  console.log('Legacy multi-network: frozen address-group domains/IPv4/IPv6, rules/identity/GeoSite during recovery, new-session updates, scoped cleanup and stop-during-start passed');
}
run().catch(error => { console.error(error); process.exitCode = 1; }).finally(() => {
  fs.rmSync(directory, { recursive: true, force: true }); Module._load = originalLoad;
  global.setInterval = oldInterval; global.clearInterval = oldClear;
});
