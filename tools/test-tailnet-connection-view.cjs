const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const Module = require('node:module');
const ts = require('/Applications/DevEco-Studio.app/Contents/tools/ohpm/node_modules/typescript');
const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'tailnet-editor-'));
const fileIo = {
  OpenMode: { CREATE: 1, WRITE_ONLY: 2, TRUNC: 4 }, accessSync: fs.existsSync,
  statSync: fs.statSync, listFileSync: fs.readdirSync, readTextSync: p => fs.readFileSync(p, 'utf8'),
  openSync: p => ({ fd: fs.openSync(p, 'w') }), writeSync: (fd, data) => fs.writeSync(fd, Buffer.from(data)),
  closeSync: f => fs.closeSync(f.fd), renameSync: fs.renameSync, unlinkSync: fs.unlinkSync,
};
const originalLoad = Module._load;
Module._load = function (id, parent, isMain) {
  if (id === '@kit.CoreFileKit') { return { fileIo }; }
  if (id === '@kit.ArkTS') { return { util: { generateRandomUUID: crypto.randomUUID,
    TextEncoder: { create: () => ({ encodeInto: s => new TextEncoder().encode(s) }) } } }; }
  if (id === '@kit.NetworkKit') { return {}; }
  return originalLoad.call(this, id, parent, isMain);
};
require.extensions['.ets'] = (module, filename) => {
  const result = ts.transpileModule(fs.readFileSync(filename, 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }, fileName: filename,
  });
  module._compile(result.outputText, filename);
};
const profiles = require('../entry/src/main/ets/model/MixedConnections.ets');
const networks = require('../entry/src/main/ets/model/NetworkProfiles.ets');
const runtime = require('../entry/src/main/ets/model/TailnetConnectionView.ets');
const tunnel = require('../entry/src/main/ets/model/TunnelState.ets');
const legacyState = require('../entry/src/main/ets/model/TailnetState.ets');
try {
  const id = crypto.randomUUID();
  fs.mkdirSync(path.join(directory, 'tailnet/tailscale'), { recursive: true });
  const identityFile = path.join(directory, 'tailnet/tailscale/test-identity');
  fs.writeFileSync(identityFile, 'unchanged test identity');
  const rulesFile = path.join(directory, `split-rules-${id}.json`);
  fs.writeFileSync(rulesFile, '{"enabled":true,"manualDomains":["example.com"]}');
  const profile = new networks.NetworkProfile(); profile.ID = id; profile.Name = 'Work';
  networks.saveNetworkProfiles(directory, [profile]);
  const beforeProfiles = fs.readFileSync(path.join(directory, 'network-profiles.json'));
  const beforeRules = fs.readFileSync(rulesFile);

  const legacy = profiles.readLegacyNetworkProfile(directory);
  legacy.Name = 'Home Tailnet'; legacy.Hostname = 'my-tablet'; legacy.ExitNodeIP = '100.64.0.10'; legacy.Enabled = false;
  profiles.saveLegacyNetworkProfile(directory, legacy);
  let saved = profiles.readLegacyNetworkProfile(directory);
  assert.equal(saved.Name, 'Home Tailnet'); assert.equal(saved.Hostname, 'my-tablet');
  assert.equal(saved.ExitNodeIP, '100.64.0.10'); assert.equal(saved.Enabled, false);
  assert.equal(saved.ControlURL, ''); assert.equal(saved.LegacyState, true);
  assert.equal(fs.readFileSync(identityFile, 'utf8'), 'unchanged test identity');
  assert.deepEqual(fs.readFileSync(rulesFile), beforeRules);
  assert.deepEqual(fs.readFileSync(path.join(directory, 'network-profiles.json')), beforeProfiles);
  const snapshot = profiles.prepareMixedTailnetConfig(directory, ['9.9.9.9'], ['legacy']);
  assert.equal(snapshot.Profiles[0].ExitNodeIP, '100.64.0.10');
  assert.equal(snapshot.Profiles[0].Hostname, 'my-tablet');
  saved.ControlURL = 'https://other.example.com';
  assert.throws(() => profiles.saveLegacyNetworkProfile(directory, saved), /身份已变化/);
  assert.equal(profiles.readLegacyNetworkProfile(directory).ControlURL, '');

  // A historical standalone file must not hide the mixed session or expose the
  // wrong network's login URL while its current node is still starting.
  const old = new legacyState.TailnetStatus(); old.BackendState = 'NeedsLogin';
  old.AuthURL = 'https://old-login.example.com'; legacyState.writeTailnet(directory, old);
  const request = new tunnel.TunnelState(crypto.randomUUID(), tunnel.TunnelPhase.Starting);
  request.mixed = true; request.tailnetIds = ['legacy', id]; tunnel.writeTunnelRequest(directory, request);
  let view = runtime.readTailnetConnectionView(directory, 'legacy');
  assert.equal(view.mode, '组合连接'); assert.equal(view.active, true); assert.equal(view.label, '连接中');
  assert.equal(view.node.AuthURL, '');
  const state = new tunnel.TunnelState(request.session, tunnel.TunnelPhase.Waiting);
  state.mixed = true; state.tailnetIds = request.tailnetIds;
  const a = new networks.NetworkNodeStatus(); a.ID = id; a.BackendState = 'NeedsLogin'; a.AuthURL = 'https://a-login.example.com';
  const b = new networks.NetworkNodeStatus(); b.ID = 'legacy'; b.BackendState = 'Running';
  b.TailscaleIPs = ['100.64.0.2']; b.DNSSuffix = 'example.ts.net'; b.PeerNames = ['nas.example.ts.net']; b.SubnetRoutes = ['192.168.72.0/24'];
  state.tailnetNodes = [a, b]; tunnel.writeTunnelState(directory, state);
  view = runtime.readTailnetConnectionView(directory, 'legacy');
  assert.equal(view.label, '已连接'); assert.equal(view.node.AuthURL, '');
  assert.deepEqual(view.node.PeerNames, ['nas.example.ts.net']);
  assert.equal(runtime.readTailnetConnectionView(directory, id).node.AuthURL, a.AuthURL);
  state.networkError = '正在恢复底层网络连接…'; tunnel.writeTunnelState(directory, state);
  assert.equal(runtime.readTailnetConnectionView(directory, 'legacy').label, '重连中');
  assert.equal(runtime.readTailnetConnectionView(directory, 'legacy').node.Error, state.networkError);
  assert.equal(runtime.readTailnetConnectionView(directory, id).node.AuthURL, a.AuthURL);
  state.networkError = ''; tunnel.writeTunnelState(directory, state);
  assert.equal(runtime.readTailnetConnectionView(directory, 'legacy').label, '已连接');
  b.Error = '出口配置失败'; tunnel.writeTunnelState(directory, state);
  assert.equal(runtime.readTailnetConnectionView(directory, 'legacy').label, '连接异常');
  b.BackendState = 'Reconnecting'; tunnel.writeTunnelState(directory, state);
  assert.equal(runtime.readTailnetConnectionView(directory, 'legacy').label, '重连中');

  // A stopping or stale session cannot offer an expired login action.
  state.phase = tunnel.TunnelPhase.Stopping; tunnel.writeTunnelState(directory, state);
  assert.equal(runtime.readTailnetConnectionView(directory, id).label, '断开中');
  assert.equal(runtime.readTailnetConnectionView(directory, id).node.AuthURL, '');
  state.updated = Date.now() - 15001; tunnel.writeTunnelState(directory, state);
  assert.equal(runtime.readTailnetConnectionView(directory, id).active, false);
  assert.equal(runtime.readTailnetConnectionView(directory, id).node.AuthURL, '');

  // Legacy metadata is scoped to its original control server, even if a different
  // historical identity becomes the sole directory later.
  fs.rmSync(path.join(directory, 'tailnet'), { recursive: true });
  const control = 'https://headscale.example.com';
  fs.mkdirSync(path.join(directory, 'tailnet', encodeURIComponent(control)), { recursive: true });
  saved = profiles.readLegacyNetworkProfile(directory);
  assert.equal(saved.ControlURL, control); assert.equal(saved.Name, '原有 Tailnet 连接');
  assert.equal(saved.ExitNodeIP, '');
  console.log('Tailnet editor: identity-bound metadata, untouched credentials/rules, mixed status/login ownership, stopping/stale session guards passed');
} finally { fs.rmSync(directory, { recursive: true, force: true }); Module._load = originalLoad; }
