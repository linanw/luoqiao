// Exercise the production foreground coordinator with real isolated request and
// snapshot files; only OHOS system APIs and time are injected. Never touches a device.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const Module = require('node:module');
const ts = require('/Applications/DevEco-Studio.app/Contents/tools/ohpm/node_modules/typescript');
const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'tunnel-recovery-'));
const source = path.resolve(__dirname, '../entry/src/main/ets/model/TunnelRecovery.ets');
const abilitySource = path.resolve(__dirname, '../entry/src/main/ets/vpn/WireGuardVpnAbility.ets');
const context = { filesDir: directory, abilityInfo: { bundleName: 'test.app' } };
let now = 1800000000000, ticks, queryHook, startHook, systemVpn, queryFailure, starts, queryCalls;
const originalNow = Date.now, originalTimeout = global.setTimeout, originalInterval = global.setInterval;
const originalClearInterval = global.clearInterval;
Date.now = () => now;
global.setTimeout = (callback, ms) => { queueMicrotask(() => { now += ms; if (ticks) ticks(ms); callback(); }); return 1; };
global.setInterval = () => 1;
global.clearInterval = () => {};
const fileIo = {
  OpenMode: { READ_ONLY: 0, CREATE: 1, WRITE_ONLY: 2, TRUNC: 4 }, accessSync: fs.existsSync,
  statSync: fs.statSync, readTextSync: p => fs.readFileSync(p, 'utf8'),
  mkdirSync: (p, recursive) => fs.mkdirSync(p, { recursive }),
  openSync: (p, mode) => ({ fd: fs.openSync(p, mode & 2 ? 'w' : 'r') }),
  writeSync: (fd, data) => fs.writeSync(fd, Buffer.from(data)), fsyncSync: fs.fsyncSync,
  closeSync: f => fs.closeSync(f.fd), renameSync: fs.renameSync, unlinkSync: fs.unlinkSync,
  copyFileSync: fs.copyFileSync, rmdirSync: p => fs.rmSync(p, { recursive: true }), listFileSync: fs.readdirSync,
};
const connection = {
  NetBearType: { BEARER_VPN: 4 },
  getAllNets: async () => {
    queryCalls++;
    if (queryHook) await queryHook(queryCalls);
    if (queryFailure) throw Object.assign(new Error('injected API failure'), { code: 201 });
    return [{ netId: 1 }];
  },
  getNetCapabilities: async () => ({ bearerTypes: [systemVpn ? 4 : 1] }),
};
const vpnExtension = {
  stopVpnExtensionAbility: async () => { throw new Error('Recovery must never stop a VPN'); },
  startVpnExtensionAbility: async want => { starts.push(want); if (startHook) await startHook(want); },
};
const originalLoad = Module._load;
Module._load = function (id, parent, main) {
  if (id === '@kit.CoreFileKit') return { fileIo };
  if (id === '@kit.ArkTS') return { util: { generateRandomUUID: crypto.randomUUID,
    TextEncoder: { create: () => ({ encodeInto: s => new TextEncoder().encode(s) }) } } };
  if (id === '@kit.AbilityKit' || id === '@kit.BasicServicesKit') return {};
  if (id === '@kit.NetworkKit') return { connection, vpnExtension, VpnExtensionAbility: class {} };
  if (id === 'libwireguard.so') return { default: {} };
  if (parent?.filename === abilitySource && id === '../model/ProfileStore') {
    return { isValidProfileId: id => /^(main|[0-9a-f-]{8,64})$/i.test(id), MAX_PROFILES: 16 };
  }
  if (parent?.filename === abilitySource && id === '../model/VpnDiagnostics') {
    return { VpnDiagnostics: class { event() {} } };
  }
  return originalLoad.call(this, id, parent, main);
};
require.extensions['.ets'] = (module, filename) => {
  const result = ts.transpileModule(fs.readFileSync(filename, 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }, fileName: filename,
  });
  module._compile(result.outputText, filename);
};
const tunnel = require('../entry/src/main/ets/model/TunnelState.ets');
const snapshots = require('../entry/src/main/ets/model/SessionRules.ets');
const split = require('../entry/src/main/ets/model/SplitTunnel.ets');
const networks = require('../entry/src/main/ets/model/NetworkProfiles.ets');
const api = require(source);
let controller, request, tn;
async function settle() { let count = 0; while (controller.busy) { if (++count > 1000) throw new Error('coordinator did not settle'); await Promise.resolve(); } }
async function foreground() { controller.setForeground(true); await settle(); }
async function check() { await controller.check(); }
function state(phase = tunnel.TunnelPhase.Connected, age = 30000) {
  const result = new tunnel.TunnelState(request.session, phase);
  result.profileIds = request.profileIds.slice(); result.tailnetIds = request.tailnetIds.slice(); result.mixed = request.mixed;
  result.updated = now - age; tunnel.writeTunnelState(directory, result); return result;
}
function reset({ mixed = true, mode = false, snapshot = true } = {}) {
  if (controller) controller.setForeground(false);
  fs.rmSync(directory, { recursive: true, force: true }); fs.mkdirSync(directory);
  tunnel.setTunnelMutationActive(false);
  now += 1000000; ticks = queryHook = startHook = undefined; systemVpn = queryFailure = false; starts = []; queryCalls = 0;
  tn = crypto.randomUUID();
  const p = new networks.NetworkProfile(); p.ID = tn; p.Name = 'Synthetic tailnet'; networks.saveNetworkProfiles(directory, [p]);
  split.writeProfileRules(directory, 'main', new split.ProfileRules(true, false, [], ['original.example'], []));
  request = new tunnel.TunnelState(crypto.randomUUID(), tunnel.TunnelPhase.Starting);
  request.updated = now - 120000; request.profileIds = ['main']; request.mixed = mixed;
  request.tailnetIds = mixed ? [tn] : []; request.useConfigRoutes = mode;
  tunnel.writeTunnelRequest(directory, request); state();
  if (snapshot) snapshots.readOrCreateSessionRules(directory, request.session, request.profileIds, request.tailnetIds, mixed, mode);
  controller = new api.TunnelRecoveryController(context);
}
const recovery = () => api.readTunnelRecoveryStatus(directory);
async function afterBackoff() { now = Math.max(now, recovery().nextAttemptAt + 1); await check(); }
(async () => {
  try {
    reset();
    const rulesFile = path.join(directory, 'session-rules', request.session, 'rules.json');
    const frozen = fs.readFileSync(rulesFile, 'utf8');
    split.writeProfileRules(directory, 'main', new split.ProfileRules(true, false, [], ['edited.example'], []));
    await foreground(); assert.equal(recovery().phase, 'backoff'); assert.equal(starts.length, 0);
    await afterBackoff(); assert.equal(starts.length, 1);
    assert.equal(starts[0].parameters.wireguardSession, request.session);
    assert.deepEqual(starts[0].parameters.wireguardProfiles, ['main']);
    assert.deepEqual(starts[0].parameters.mixedTailnets, [tn]);
    assert.equal(starts[0].parameters.mixedMode, true);
    assert.equal(starts[0].parameters.wireguardUseConfigRoutes, false);
    assert.equal(fs.readFileSync(rulesFile, 'utf8'), frozen, 'recovery must keep running-session rules');
    assert.equal(recovery().attempts, 1);
    // Re-entering the foreground during a slow restart cannot issue another start.
    await foreground(); assert.equal(starts.length, 1); assert.equal(recovery().phase, 'waiting');

    reset(); let elapsed = 0;
    ticks = ms => { elapsed += ms; if (elapsed >= 1750) tunnel.respondTunnelHeartbeat(directory, request.session); };
    await foreground(); assert.equal(starts.length, 0); assert.equal(recovery().phase, 'idle');
    assert.equal(queryCalls, 0, 'late response from a resumed extension avoids even a restart inquiry');

    reset(); ticks = () => state(tunnel.TunnelPhase.Waiting, 0);
    await foreground(); assert.equal(starts.length, 0); assert.equal(recovery().phase, 'idle');

    reset(); systemVpn = true; await foreground();
    assert.equal(recovery().phase, 'blocked'); assert.match(recovery().message, /系统中仍有 VPN/); assert.equal(starts.length, 0);
    await check(); assert.equal(queryCalls, 1, 'blocked checks do not loop');

    reset(); queryFailure = true; await foreground();
    assert.equal(recovery().phase, 'blocked'); assert.match(recovery().message, /无法核实/); assert.equal(starts.length, 0);

    reset(); ticks = () => { ticks = undefined; tunnel.cancelTunnelRecovery(directory, request.session); };
    await foreground(); assert.equal(starts.length, 0); assert.equal(tunnel.readTunnelRequest(directory).resumeOnForeground, false);
    await foreground(); assert.equal(starts.length, 0, 'explicit stop never resurrects after foreground');

    reset(); await foreground();
    queryHook = () => { tunnel.cancelTunnelRecovery(directory, request.session); };
    await afterBackoff(); assert.equal(starts.length, 0, 'stop during asynchronous system check wins');

    reset(); ticks = () => { ticks = undefined; const newer = new tunnel.TunnelState(crypto.randomUUID(), tunnel.TunnelPhase.Starting);
      newer.profileIds = ['main']; tunnel.writeTunnelRequest(directory, newer); };
    await foreground(); assert.equal(starts.length, 0); assert.notEqual(tunnel.readTunnelRequest(directory).session, request.session);

    reset(); await foreground();
    queryHook = () => { fs.writeFileSync(path.join(directory, 'purevpn-apply-journal.json'), '{}'); };
    await afterBackoff(); assert.equal(starts.length, 0, 'PureVPN update reservation wins a race with recovery');

    reset(); await foreground();
    queryHook = () => { tunnel.setTunnelMutationActive(true); };
    await afterBackoff(); assert.equal(starts.length, 0, 'pre-journal configuration writes also block recovery');

    reset(); fs.writeFileSync(path.join(directory, 'purevpn-apply-journal.json'), '{}');
    await foreground(); assert.equal(recovery().phase, 'blocked'); assert.match(recovery().message, /PureVPN/);

    reset(); ticks = () => { ticks = undefined; controller.setForeground(false); };
    await foreground(); assert.equal(starts.length, 0, 'leaving foreground cancels an in-flight recovery');

    reset(); state(tunnel.TunnelPhase.Failed); await foreground();
    assert.equal(starts.length, 0); assert.equal(recovery().phase, 'failed'); assert.equal(queryCalls, 0);

    reset(); state(tunnel.TunnelPhase.Disconnected, 0); await foreground(); await afterBackoff();
    assert.equal(starts.length, 1, 'unexpected onDestroy with an intact intent can recover');

    reset({ snapshot: false }); await foreground(); await afterBackoff();
    assert.equal(starts.length, 0); assert.equal(recovery().phase, 'failed');
    assert.equal(fs.existsSync(path.join(directory, 'session-rules', request.session)), false);

    reset({ mixed: false, mode: true });
    delete request.useConfigRoutes; tunnel.writeTunnelRequest(directory, request);
    await foreground(); await afterBackoff();
    assert.equal(starts[0].parameters.wireguardUseConfigRoutes, true, 'old request mode comes from the validated snapshot');

    reset(); request.updated = now - 1000; tunnel.writeTunnelRequest(directory, request);
    state(tunnel.TunnelPhase.Starting, 1000); await foreground();
    assert.equal(starts.length, 0); assert.equal(recovery().phase, 'waiting');

    reset(); await foreground();
    queryHook = n => { if (n === 3) systemVpn = true; };
    await afterBackoff(); assert.equal(starts.length, 0); assert.equal(recovery().phase, 'blocked');

    reset(); await foreground();
    queryHook = n => { if (n === 3) tunnel.respondTunnelHeartbeat(directory, request.session); };
    await afterBackoff(); assert.equal(starts.length, 0); assert.equal(recovery().phase, 'idle');

    reset(); await foreground(); await afterBackoff();
    // Simulate UI-process recreation. Attempt accounting survives the new controller.
    controller.setForeground(false); controller = new api.TunnelRecoveryController(context);
    now = recovery().nextAttemptAt + 1; await foreground(); assert.equal(starts.length, 2);
    now = recovery().nextAttemptAt + 1; await check(); assert.equal(starts.length, 3);
    now = recovery().nextAttemptAt + 1; await check(); assert.equal(starts.length, 3);
    assert.equal(recovery().phase, 'failed'); assert.match(recovery().message, /3 次/);
    await foreground(); assert.equal(starts.length, 3);

    reset(); await foreground();
    startHook = async () => {
      tunnel.cancelTunnelRecovery(directory, request.session);
      tunnel.writeTunnelRequest(directory, new tunnel.TunnelState(request.session, tunnel.TunnelPhase.Disconnected));
    };
    await afterBackoff(); assert.equal(starts.length, 1);
    assert.equal(tunnel.readTunnelRequest(directory).phase, tunnel.TunnelPhase.Disconnected);
    assert.equal(recovery().phase, 'idle', 'a completed stop during the start IPC is not overwritten');
    await foreground(); assert.equal(starts.length, 1);

    reset(); await foreground();
    startHook = async () => { throw Object.assign(new Error('secret-config-path'), { code: 201 }); };
    await afterBackoff(); assert.equal(recovery().phase, 'failed'); assert.match(recovery().message, /201/);
    assert.equal(recovery().message.includes('secret-config-path'), false);
    await check(); assert.equal(starts.length, 1, 'a rejected start is not retried in a foreground spin loop');

    // An old or another-session heartbeat cannot claim this session is alive.
    reset(); const nonce = tunnel.requestTunnelHeartbeat(directory, request.session);
    tunnel.respondTunnelHeartbeat(directory, crypto.randomUUID()); assert.equal(tunnel.receivedTunnelHeartbeat(directory, nonce), false);
    tunnel.respondTunnelHeartbeat(directory, request.session); assert.equal(tunnel.receivedTunnelHeartbeat(directory, nonce), true);
    const next = tunnel.requestTunnelHeartbeat(directory, request.session); assert.equal(tunnel.receivedTunnelHeartbeat(directory, next), false);

    reset(); await foreground(); await afterBackoff();
    const healthyStart = ++now;
    for (let minute = 0; minute <= 5; minute++) {
      now = healthyStart + minute * 60000;
      const healthy = state(tunnel.TunnelPhase.Connected, 0); healthy.connectedSince = healthyStart;
      tunnel.writeTunnelState(directory, healthy); await check();
      assert.equal(recovery().attempts, minute < 5 ? 1 : 0, 'only five minutes of stable Connected resets the failure round');
    }
    assert.equal(recovery().nextAttemptAt, 0); assert.equal(recovery().startedAt, 0);
    state(tunnel.TunnelPhase.Disconnected, 0); await check(); await afterBackoff();
    assert.equal(starts.length, 2); assert.equal(recovery().attempts, 1, 'a later independent failure gets a new bounded round');

    reset(); await foreground(); await afterBackoff();
    let continuousStart = ++now;
    for (let minute = 0; minute <= 6; minute++) {
      now += 60000;
      if (minute === 3) {
        state(tunnel.TunnelPhase.Waiting, 0); await check();
        continuousStart = now;
      }
      const healthy = state(tunnel.TunnelPhase.Connected, 0); healthy.connectedSince = continuousStart;
      tunnel.writeTunnelState(directory, healthy); await check();
      assert.equal(recovery().attempts, 1, 'an interruption resets the stable interval, not the attempt counter');
    }

    reset(); await foreground(); await afterBackoff();
    state(tunnel.TunnelPhase.Connected, 0); await check();
    now += 310000; ticks = () => tunnel.respondTunnelHeartbeat(directory, request.session);
    await check(); assert.equal(recovery().attempts, 1, 'a live process with an unchanged old status is not five-minute stability proof');

    reset(); await foreground(); await afterBackoff();
    const backgroundStableStart = now;
    controller.setForeground(false); now += 310000;
    const sustained = state(tunnel.TunnelPhase.Connected, 0); sustained.connectedSince = backgroundStableStart;
    tunnel.writeTunnelState(directory, sustained);
    ticks = () => tunnel.respondTunnelHeartbeat(directory, request.session);
    await foreground(); assert.equal(recovery().attempts, 0, 'a fresh continuous marker also proves stability while UI was backgrounded');

    // Run the production ability's onCreate/stillCurrent/publish, stubbing only
    // transport startup and the diagnostic observer. This exercises a delayed
    // system start arriving after the user's cancellation.
    reset(); const Ability = require(abilitySource).default;
    let transportStarts = 0;
    const makeAbility = () => { const value = new Ability(); value.context = context;
      value.watchRuntime = () => {}; value.startTunnel = () => { transportStarts++; }; return value; };
    const want = { parameters: { wireguardSession: request.session, wireguardProfiles: ['main'], mixedMode: true, mixedTailnets: [tn] } };
    const activeAbility = makeAbility(); activeAbility.onCreate(want);
    assert.equal(transportStarts, 1); assert.equal(activeAbility.stillCurrent(), true);
    tunnel.cancelTunnelRecovery(directory, request.session);
    assert.equal(activeAbility.stillCurrent(), false);
    assert.equal(activeAbility.requested(), true, 'onDestroy acknowledgement still owns its cancelled request');
    activeAbility.publish(new tunnel.TunnelState(request.session, tunnel.TunnelPhase.Disconnected));
    assert.equal(tunnel.readPublishedTunnelState(directory).phase, tunnel.TunnelPhase.Disconnected);
    const delayedAbility = makeAbility(); delayedAbility.onCreate(want);
    assert.equal(transportStarts, 1, 'a late onCreate after explicit cancel cannot start transport');

    console.log('Foreground VPN recovery: same-session frozen rules and route mode, delayed live response, system VPN/permission guard, explicit stop/new session/PureVPN/background races, startup grace, permanent failure, missing snapshot, bounded persistent retries, and nonce isolation passed');
  } finally {
    if (controller) controller.setForeground(false);
    Date.now = originalNow; global.setTimeout = originalTimeout; global.setInterval = originalInterval; global.clearInterval = originalClearInterval;
    Module._load = originalLoad; fs.rmSync(directory, { recursive: true, force: true });
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
