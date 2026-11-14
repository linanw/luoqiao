// Transaction tests use real files and injected VPN/ProfileStore failures; no real account credentials.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const Module = require('node:module');
const ts = require('/Applications/DevEco-Studio.app/Contents/tools/ohpm/node_modules/typescript');
const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'purevpn-apply-'));
const context = { filesDir: directory, abilityInfo: { bundleName: 'test.app' } };
const source = path.resolve(__dirname, '../entry/src/main/ets/model/PureVpnApply.ets');
let profiles, rules, tailnet, calls, saveHook, startHook, loadHook, stopHook, copyHook, journalWrites, failJournalWrite, failBackupUnlink, diagnostics;
let tunnel;
const file = id => path.join(directory, 'profiles', id + '.enc');
const encode = text => Buffer.from('TEST-ENCRYPTED:' + Buffer.from(text).toString('base64'));
const decode = bytes => Buffer.from(bytes.toString().slice('TEST-ENCRYPTED:'.length), 'base64').toString();
const fileIo = {
  OpenMode: { CREATE: 1, WRITE_ONLY: 2, TRUNC: 4 }, accessSync: fs.existsSync,
  readTextSync: p => fs.readFileSync(p, 'utf8'), copyFileSync: (src, dest) => {
    if (copyHook) { const hook = copyHook; copyHook = undefined; hook(); }
    fs.copyFileSync(src, dest);
  },
  openSync: p => ({ fd: fs.openSync(p, 'w') }), writeSync: (fd, data) => fs.writeSync(fd, Buffer.from(data)),
  fsyncSync: fs.fsyncSync, closeSync: f => fs.closeSync(f.fd),
  renameSync: (src, dest) => {
    if (dest.endsWith('/purevpn-apply-journal.json') && ++journalWrites === failJournalWrite) {
      throw new Error('injected journal failure');
    }
    fs.renameSync(src, dest);
  }, unlinkSync: p => {
    if (failBackupUnlink && p.includes('.purevpn-backup-')) { throw new Error('injected encrypted backup cleanup failure'); }
    fs.unlinkSync(p);
  },
};
const store = {
  MAX_CONFIG_BYTES: 128 * 1024,
  isValidProfileId: id => /^(main|[0-9a-f-]{8,64})$/.test(id),
  listProfiles: () => profiles.map(p => ({ ...p })),
  loadProfileText: async (_, id) => {
    if (loadHook) { const hook = loadHook; loadHook = undefined; await hook(); }
    return fs.existsSync(file(id)) ? decode(fs.readFileSync(file(id))) : '';
  },
  saveProfileText: async (_, id, text) => {
    if (saveHook) { const hook = saveHook; saveHook = undefined; await hook(); }
    fs.writeFileSync(file(id), encode(text));
  },
  createProfile: async (_, name, text) => {
    const meta = { id: crypto.randomUUID(), name }; profiles.push(meta);
    fs.writeFileSync(file(meta.id), encode(text)); return meta;
  },
  deleteProfile: async (_, id) => { profiles = profiles.filter(p => p.id !== id); fs.rmSync(file(id), { force: true }); },
};
const vpnExtension = {
  stopVpnExtensionAbility: async w => {
    calls.push(['stop', w.parameters.wireguardSession]);
    if (stopHook) { const hook = stopHook; stopHook = undefined; await hook(w); return; }
    const s = new tunnel.TunnelState(w.parameters.wireguardSession, tunnel.TunnelPhase.Disconnected);
    tunnel.writeTunnelState(directory, s);
  },
  startVpnExtensionAbility: async w => {
    calls.push(['start', w.parameters.wireguardSession, w.parameters.wireguardProfiles[0], w.parameters.wireguardUseConfigRoutes]);
    if (startHook) { const hook = startHook; startHook = undefined; await hook(w); return; }
    const s = new tunnel.TunnelState(w.parameters.wireguardSession, tunnel.TunnelPhase.Waiting);
    s.profileIds = w.parameters.wireguardProfiles; tunnel.writeTunnelState(directory, s);
  },
};
const originalLoad = Module._load;
Module._load = function (id, parent, isMain) {
  if (id === '@kit.AbilityKit') { return {}; }
  if (id === '@kit.PerformanceAnalysisKit') { return { hilog: { error: (...args) => diagnostics.push(args) } }; }
  if (id === '@kit.CoreFileKit') { return { fileIo }; }
  if (id === '@kit.ArkTS') { return { util: { generateRandomUUID: crypto.randomUUID,
    TextEncoder: { create: () => ({ encodeInto: s => new TextEncoder().encode(s) }) } } }; }
  if (id === '@kit.NetworkKit') { return { vpnExtension }; }
  if (parent?.filename === source) {
    if (id === './ProfileStore') { return store; }
    if (id === './SplitTunnel') { return { readProfileRules: () => rules }; }
    if (id === './NetworkProfiles') { return { readNetworkStatus: () => ({ active: tailnet }) }; }
    if (id === './TailnetState') { return { readTailnet: () => ({ BackendState: 'Stopped' }) }; }
  }
  return originalLoad.call(this, id, parent, isMain);
};
require.extensions['.ets'] = (module, filename) => {
  const result = ts.transpileModule(fs.readFileSync(filename, 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }, fileName: filename,
  });
  module._compile(result.outputText, filename);
};
tunnel = require('../entry/src/main/ets/model/TunnelState.ets');
let api;
const oldConfig = `[Interface]\nPrivateKey = AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA=\nAddress = 10.0.0.2/32\nDNS = 1.1.1.1\n[Peer]\nPublicKey = ISIjJCUmJygpKissLS4vMDEyMzQ1Njc4OTo7PD0+P0A=\nEndpoint = vpn.example.com:51820\nAllowedIPs = 0.0.0.0/0\nPersistentKeepalive = 25\n`;
const newConfig = oldConfig.replace('10.0.0.2/32', '10.0.0.3/32');
function reset() {
  fs.rmSync(directory, { recursive: true, force: true }); fs.mkdirSync(path.join(directory, 'profiles'), { recursive: true });
  tunnel.setTunnelMutationActive(false);
  profiles = [{ id: 'main', name: 'Original name' }]; fs.writeFileSync(file('main'), encode(oldConfig));
  rules = { enabled: true, isDefault: false, hasContent: () => true, manualDomains: ['ifconfig.co'] };
  tailnet = false; calls = []; diagnostics = []; saveHook = startHook = loadHook = stopHook = copyHook = undefined;
  journalWrites = 0; failJournalWrite = -1;
  failBackupUnlink = false;
  delete require.cache[source]; api = require(source);
}
function request(session = crypto.randomUUID(), ids = ['main'], phase = tunnel.TunnelPhase.Connected) {
  const req = new tunnel.TunnelState(session, tunnel.TunnelPhase.Starting); req.profileIds = ids;
  tunnel.writeTunnelRequest(directory, req);
  const state = new tunnel.TunnelState(session, phase); state.profileIds = ids; state.lastHandshake = Date.now();
  tunnel.writeTunnelState(directory, state); return session;
}
function handshake(transaction) {
  const state = new tunnel.TunnelState(transaction.session, tunnel.TunnelPhase.Connected);
  state.profileIds = [transaction.profileId]; state.lastHandshake = Date.now(); tunnel.writeTunnelState(directory, state);
}
function combinedRequest(session = crypto.randomUUID(), ids = ['main'], marked = true) {
  const req = new tunnel.TunnelState(session, tunnel.TunnelPhase.Starting);
  req.profileIds = ids; req.mixed = marked; req.tailnetIds = ['tailnet-test'];
  tunnel.writeTunnelRequest(directory, req);
  const state = new tunnel.TunnelState(session, tunnel.TunnelPhase.Connected);
  state.profileIds = ids; state.mixed = marked; state.tailnetIds = ['tailnet-test']; state.lastHandshake = Date.now();
  tunnel.writeTunnelState(directory, state); return session;
}
function journal() { return JSON.parse(fs.readFileSync(directory + '/purevpn-apply-journal.json', 'utf8')); }
function reloadProcess() { delete require.cache[source]; api = require(source); }
async function virtualClock(run) {
  const originalNow = Date.now;
  const originalTimeout = global.setTimeout;
  let now = originalNow();
  Date.now = () => now;
  global.setTimeout = (callback, milliseconds) => setImmediate(() => { now += milliseconds; callback(); });
  try { await run(); }
  finally { Date.now = originalNow; global.setTimeout = originalTimeout; }
}
function makeStatusStale() {
  const state = tunnel.readTunnelState(directory);
  state.updated = Date.now() - 90001;
  tunnel.writeTunnelState(directory, state);
}
async function main() {
  reset(); await assert.rejects(api.applyPureVpnConfig(context, 'main', '', 'bad', true)); assert.equal(calls.length, 0);
  tailnet = true; await assert.rejects(api.applyPureVpnConfig(context, 'main', '', newConfig, true), /Tailnet/);
  reset(); request(undefined, ['main', crypto.randomUUID()]); await assert.rejects(api.applyPureVpnConfig(context, 'main', '', newConfig, true), /多连接/);
  for (const ids of [['main'], []]) {
    reset(); const combined = combinedRequest(undefined, ids);
    await assert.rejects(api.applyPureVpnConfig(context, 'main', '', newConfig, true), /断开.*组合连接/);
    await assert.rejects(api.applyPureVpnConfig(context, 'main', '', newConfig, false), /断开.*组合连接/);
    assert.equal(calls.length, 0, 'one-WG or Tailnet-only combined group is never stopped for renewal');
    assert.equal(tunnel.readTunnelRequest(directory).session, combined);
    assert.equal(await store.loadProfileText(context, 'main'), oldConfig);
  }
  reset(); combinedRequest(undefined, ['main'], false);
  await assert.rejects(api.applyPureVpnConfig(context, 'main', '', newConfig, true), /组合连接/);
  reset(); const stoppedCombined = new tunnel.TunnelState(crypto.randomUUID(), tunnel.TunnelPhase.Disconnected);
  stoppedCombined.mixed = true; stoppedCombined.tailnetIds = ['tailnet-test'];
  tunnel.writeTunnelRequest(directory, stoppedCombined);
  const afterCombined = await api.applyPureVpnConfig(context, 'main', '', newConfig, false);
  await afterCombined.commit();
  assert.equal(calls.length, 0, 'an explicitly disconnected combined request permits saving a new configuration');
  reset(); request(); await assert.rejects(api.applyPureVpnConfig(context, 'main', '', newConfig, false), /正在运行/);

  for (const [stage, target, code] of [['读取原配置', 'load', 24000001], ['备份原配置', 'copy', 13900002],
    ['停止旧 VPN 并等待确认', 'stop', 16000011]]) {
    reset(); const untouchedSession = request();
    const failure = () => { const error = new Error('PrivateKey=never-log-this SECRET-ACCOUNT-DATA'); error.code = code; throw error; };
    if (target === 'load') loadHook = failure;
    if (target === 'copy') copyHook = failure;
    if (target === 'stop') stopHook = failure;
    await assert.rejects(api.applyPureVpnConfig(context, 'main', '', newConfig, true), error => {
      assert.ok(error.message.includes(stage)); assert.ok(error.message.includes(String(code)));
      assert.ok(!error.message.includes('never-log')); return true;
    });
    assert.equal(tunnel.readTunnelRequest(directory).session, untouchedSession);
    assert.equal(await store.loadProfileText(context, 'main'), oldConfig);
    assert.ok(JSON.stringify(diagnostics).includes(stage));
    assert.ok(!JSON.stringify(diagnostics).includes('SECRET-ACCOUNT-DATA'));
  }

  reset(); const prior = request(); const oldEnvelope = fs.readFileSync(file('main'));
  let tx = await api.applyPureVpnConfig(context, 'main', 'Ignored rename', newConfig, true);
  assert.equal(tx.profileId, 'main'); assert.equal(profiles[0].name, 'Original name');
  assert.deepEqual(rules.manualDomains, ['ifconfig.co']); assert.equal(calls[0][0], 'stop'); assert.equal(calls[0][1], prior);
  assert.equal(calls[1][3], false, 'selected routing retained');
  assert.deepEqual(fs.readFileSync(journal().backup), oldEnvelope, 'backup copies encrypted bytes');
  assert.ok(!fs.readFileSync(directory + '/purevpn-apply-journal.json', 'utf8').includes('PrivateKey'));
  await assert.rejects(tx.commit(), /握手/); handshake(tx); await tx.commit();
  assert.ok(!fs.existsSync(directory + '/purevpn-apply-journal.json')); assert.equal(await store.loadProfileText(context, 'main'), newConfig);

  reset(); tx = await api.applyPureVpnConfig(context, 'main', '', newConfig, true);
  const commitBackup = journal().backup; failBackupUnlink = true; handshake(tx); await tx.commit();
  assert.ok(fs.existsSync(commitBackup), 'cleanup failure retains encrypted backup');
  assert.ok(!fs.existsSync(directory + '/purevpn-apply-journal.json'));
  const nextTx = await api.applyPureVpnConfig(context, 'main', '', oldConfig, true);
  await nextTx.rollback();
  assert.equal(await store.loadProfileText(context, 'main'), newConfig, 'next apply is not blocked by previous cleanup failure');

  reset(); request(); tx = await api.applyPureVpnConfig(context, 'main', '', newConfig, true);
  const rollbackBackup = journal().backup; failBackupUnlink = true;
  await tx.rollback(); assert.equal(await store.loadProfileText(context, 'main'), oldConfig);
  assert.equal(calls.filter(c => c[0] === 'start').length, 2, 'cleanup failure still reconnects restored configuration');
  assert.ok(fs.existsSync(rollbackBackup)); assert.ok(!fs.existsSync(directory + '/purevpn-apply-journal.json'));

  reset(); request(); tx = await api.applyPureVpnConfig(context, 'main', '', newConfig, true);
  await tx.rollback(); assert.equal(await store.loadProfileText(context, 'main'), oldConfig);
  assert.equal(calls.filter(c => c[0] === 'start').length, 2, 'old connection restarted after timeout');

  reset(); request(); tx = await api.applyPureVpnConfig(context, 'main', '', newConfig, true);
  tunnel.cancelTunnelRecovery(directory, tx.session);
  await tx.rollback();
  assert.equal(calls.filter(c => c[0] === 'start').length, 1, 'explicit stop is not revived by rollback');
  assert.equal(tunnel.readTunnelRequest(directory).phase, tunnel.TunnelPhase.Disconnected);
  assert.equal(await store.loadProfileText(context, 'main'), oldConfig);

  reset(); request(); tx = await api.applyPureVpnConfig(context, 'main', '', newConfig, true);
  stopHook = async () => {
    tunnel.cancelTunnelRecovery(directory, tx.session);
    tunnel.writeTunnelState(directory, new tunnel.TunnelState(tx.session, tunnel.TunnelPhase.Disconnected));
  };
  await tx.rollback();
  assert.equal(calls.filter(c => c[0] === 'start').length, 1, 'stop during rollback await is rechecked before resuming');
  assert.equal(tunnel.readTunnelRequest(directory).phase, tunnel.TunnelPhase.Disconnected);
  assert.equal(tunnel.isTunnelMutationActive(), false);

  reset(); request(); tx = await api.applyPureVpnConfig(context, 'main', '', newConfig, true);
  stopHook = async () => {
    tunnel.writeTunnelState(directory, new tunnel.TunnelState(tx.session, tunnel.TunnelPhase.Disconnected));
    loadHook = async () => {
      tunnel.writeTunnelRequest(directory, new tunnel.TunnelState(tx.session, tunnel.TunnelPhase.Disconnected));
    };
  };
  await tx.rollback();
  assert.equal(calls.filter(c => c[0] === 'start').length, 1, 'completed explicit stop during final candidate decrypt is never overwritten');
  assert.equal(tunnel.readTunnelRequest(directory).phase, tunnel.TunnelPhase.Disconnected);
  assert.equal(await store.loadProfileText(context, 'main'), oldConfig);

  reset(); request(); loadHook = async () => {
    assert.equal(tunnel.isTunnelMutationActive(), true, 'the pre-journal async read is protected from foreground recovery');
    assert.equal(fs.existsSync(directory + '/purevpn-apply-journal.json'), false);
  };
  tx = await api.applyPureVpnConfig(context, 'main', '', newConfig, true); handshake(tx); await tx.commit();
  assert.equal(tunnel.isTunnelMutationActive(), false);

  reset(); const cancelReadSession = request();
  loadHook = async () => tunnel.cancelTunnelRecovery(directory, cancelReadSession);
  await assert.rejects(api.applyPureVpnConfig(context, 'main', '', newConfig, true));
  assert.equal(calls.filter(c => c[0] === 'start').length, 0, 'stop during original configuration read cancels apply');
  assert.equal(await store.loadProfileText(context, 'main'), oldConfig);

  reset(); const cancelInitialStopSession = request();
  stopHook = async () => {
    tunnel.cancelTunnelRecovery(directory, cancelInitialStopSession);
    tunnel.writeTunnelState(directory, new tunnel.TunnelState(cancelInitialStopSession, tunnel.TunnelPhase.Disconnected));
  };
  await assert.rejects(api.applyPureVpnConfig(context, 'main', '', newConfig, true));
  assert.equal(calls.filter(c => c[0] === 'start').length, 0, 'stop during initial system stop cancels new candidate startup');

  for (const disconnected of [false, true]) {
    reset(); request(); saveHook = async () => {
      const current = tunnel.readTunnelRequest(directory);
      if (disconnected) tunnel.writeTunnelRequest(directory, new tunnel.TunnelState(current.session, tunnel.TunnelPhase.Disconnected));
      else tunnel.cancelTunnelRecovery(directory, current.session);
    };
    await assert.rejects(api.applyPureVpnConfig(context, 'main', '', newConfig, true));
    assert.equal(calls.filter(c => c[0] === 'start').length, 0, 'stop during candidate encryption cancels both candidate and rollback starts');
    assert.equal(await store.loadProfileText(context, 'main'), oldConfig);
    assert.equal(tunnel.readTunnelRequest(directory).phase, tunnel.TunnelPhase.Disconnected);
  }

  reset(); request(); tx = await api.applyPureVpnConfig(context, 'main', '', newConfig, true); reloadProcess();
  loadHook = async () => tunnel.cancelTunnelRecovery(directory, tx.session);
  await api.recoverPureVpnApply(context);
  assert.equal(calls.filter(c => c[0] === 'start').length, 1, 'stop while loading an interrupted candidate prevents recovery restart');
  assert.equal(tunnel.readTunnelRequest(directory).phase, tunnel.TunnelPhase.Disconnected);

  reset(); request(); saveHook = async () => { throw new Error('injected encrypted write failure'); };
  await assert.rejects(api.applyPureVpnConfig(context, 'main', '', newConfig, true));
  assert.equal(await store.loadProfileText(context, 'main'), oldConfig); assert.ok(!fs.existsSync(directory + '/purevpn-apply-journal.json'));

  reset(); request(); startHook = async () => { throw new Error('injected start failure'); };
  await assert.rejects(api.applyPureVpnConfig(context, 'main', '', newConfig, true));
  assert.equal(await store.loadProfileText(context, 'main'), oldConfig);
  assert.ok(!fs.existsSync(directory + '/purevpn-apply-journal.json'));

  reset(); startHook = async () => { throw new Error('start rejected before an extension exists'); };
  stopHook = async () => {}; // The system stop succeeds; there is no extension to send onDestroy.
  const rejectedAt = Date.now();
  await assert.rejects(api.applyPureVpnConfig(context, 'main', '', newConfig, true));
  assert.ok(Date.now() - rejectedAt < 2000, 'rejected start does not wait for an impossible extension acknowledgement');
  assert.equal(await store.loadProfileText(context, 'main'), oldConfig);
  assert.ok(!fs.existsSync(directory + '/purevpn-apply-journal.json'));

  await virtualClock(async () => {
    reset(); const killedSession = request(); makeStatusStale();
    stopHook = async () => {}; // HAP replacement killed the old extension; the system still fulfills stop.
    const stoppedAt = Date.now();
    const recovered = await api.applyPureVpnConfig(context, 'main', '', newConfig, true);
    assert.ok(Date.now() - stoppedAt >= 10000, 'a stale record still requires the complete acknowledgement wait');
    assert.notEqual(recovered.session, killedSession);
    handshake(recovered); await recovered.commit();
    assert.equal(await store.loadProfileText(context, 'main'), newConfig);
  });
  await virtualClock(async () => {
    reset(); const freshSession = request(); stopHook = async () => {};
    await assert.rejects(api.applyPureVpnConfig(context, 'main', '', newConfig, true), /停止旧 VPN/);
    assert.equal(tunnel.readTunnelRequest(directory).session, freshSession);
    assert.equal(await store.loadProfileText(context, 'main'), oldConfig, 'fresh silent record is not sufficient');
  });
  await virtualClock(async () => {
    reset(); const rejectedSession = request(); makeStatusStale();
    stopHook = async () => { const error = new Error('rejected system stop'); error.code = 16000050; throw error; };
    await assert.rejects(api.applyPureVpnConfig(context, 'main', '', newConfig, true), /16000050/);
    assert.equal(tunnel.readTunnelRequest(directory).session, rejectedSession);
    assert.equal(await store.loadProfileText(context, 'main'), oldConfig, 'age never overrides a rejected stop');
  });
  await virtualClock(async () => {
    reset(); const activeSession = request(); makeStatusStale();
    stopHook = async () => {
      const state = tunnel.readTunnelState(directory);
      state.receivedBytes++; // Any new publication counts, even if a faulty writer preserves the timestamp.
      tunnel.writeTunnelState(directory, state);
    };
    await assert.rejects(api.applyPureVpnConfig(context, 'main', '', newConfig, true), /停止旧 VPN/);
    assert.equal(tunnel.readTunnelRequest(directory).session, activeSession);
    assert.equal(await store.loadProfileText(context, 'main'), oldConfig);
  });
  await virtualClock(async () => {
    reset(); request(); makeStatusStale(); const nextSession = crypto.randomUUID();
    stopHook = async () => { request(nextSession); };
    await assert.rejects(api.applyPureVpnConfig(context, 'main', '', newConfig, true), /停止旧 VPN/);
    assert.equal(tunnel.readTunnelRequest(directory).session, nextSession, 'a new request remains untouched');
    assert.equal(await store.loadProfileText(context, 'main'), oldConfig);
  });

  reset(); request(); const newerBeforeWrite = crypto.randomUUID();
  loadHook = async () => { request(newerBeforeWrite); };
  await assert.rejects(api.applyPureVpnConfig(context, 'main', '', newConfig, true));
  assert.equal(calls.length, 0, 'request changed during decrypt: no stop/write');
  assert.equal(await store.loadProfileText(context, 'main'), oldConfig);
  assert.equal(tunnel.readTunnelRequest(directory).session, newerBeforeWrite);

  reset(); request(); const combinedDuringLoad = crypto.randomUUID();
  loadHook = async () => { combinedRequest(combinedDuringLoad, []); };
  await assert.rejects(api.applyPureVpnConfig(context, 'main', '', newConfig, true));
  assert.equal(calls.length, 0, 'new combined request takes priority during original configuration decryption');
  assert.equal(tunnel.readTunnelRequest(directory).session, combinedDuringLoad);
  assert.equal(await store.loadProfileText(context, 'main'), oldConfig);

  reset(); tx = await api.applyPureVpnConfig(context, 'main', '', newConfig, true);
  handshake(tx); const combinedDuringCommit = crypto.randomUUID(); const commitCalls = calls.length;
  loadHook = async () => { combinedRequest(combinedDuringCommit); };
  await assert.rejects(tx.commit(), /组合连接/);
  assert.equal(tunnel.readTunnelRequest(directory).session, combinedDuringCommit);
  const mixedBackup = journal().backup;
  assert.ok(fs.existsSync(mixedBackup));
  await assert.rejects(tx.rollback(), /组合连接/);
  assert.equal(calls.length, commitCalls, 'commit and rollback cannot stop a newer combined group');
  await assert.rejects(api.recoverPureVpnApply(context), /组合连接/);
  assert.equal(tunnel.readTunnelRequest(directory).session, combinedDuringCommit);
  assert.ok(fs.existsSync(mixedBackup));
  assert.equal(await store.loadProfileText(context, 'main'), newConfig);

  reset(); tx = await api.applyPureVpnConfig(context, 'main', '', newConfig, true);
  combinedRequest(tx.session); handshake(tx);
  await assert.rejects(tx.commit(), /组合连接/);
  assert.ok(fs.existsSync(journal().backup), 'same token with combined request cannot use a lone-WG status as commit proof');

  reset(); tx = await api.applyPureVpnConfig(context, 'main', '', newConfig, true);
  reloadProcess(); const combinedDuringRecovery = crypto.randomUUID(); const recoveryCalls = calls.length;
  loadHook = async () => { combinedRequest(combinedDuringRecovery, []); };
  await assert.rejects(api.recoverPureVpnApply(context), /组合连接/);
  assert.equal(calls.length, recoveryCalls, 'recovery decrypt cannot overwrite or stop a new Tailnet-only combined request');
  assert.equal(tunnel.readTunnelRequest(directory).session, combinedDuringRecovery);
  assert.equal(await store.loadProfileText(context, 'main'), newConfig);

  reset(); tx = await api.applyPureVpnConfig(context, '', 'New PureVPN', newConfig, false);
  assert.equal(tx.session, ''); assert.equal(profiles.length, 2); await tx.commit(); assert.equal(calls.length, 0);

  reset(); tx = await api.applyPureVpnConfig(context, '', 'New PureVPN', newConfig, true);
  await tx.rollback(); assert.equal(profiles.length, 1); assert.equal(await store.loadProfileText(context, 'main'), oldConfig);

  reset(); failJournalWrite = 2;
  await assert.rejects(api.applyPureVpnConfig(context, '', 'New PureVPN', newConfig, true));
  assert.equal(profiles.length, 1, 'new profile removed when installed-journal persistence fails');
  assert.equal(calls.length, 0, 'a journal failure before start does not stop another extension');

  reset(); tx = await api.applyPureVpnConfig(context, 'main', '', newConfig, true);
  const newer = request(); const beforeCalls = calls.length;
  await assert.rejects(tx.rollback(), /新的连接操作/); assert.equal(calls.length, beforeCalls);
  assert.equal(tunnel.readTunnelRequest(directory).session, newer); assert.equal(await store.loadProfileText(context, 'main'), newConfig);
  const retainedBackup = journal().backup; assert.ok(fs.existsSync(retainedBackup));
  await api.recoverPureVpnApply(context);
  assert.ok(!fs.existsSync(directory + '/purevpn-apply-journal.json'));
  assert.ok(fs.existsSync(retainedBackup), 'obsolete journal abandoned without deleting encrypted backup');
  assert.equal(tunnel.readTunnelRequest(directory).session, newer);

  reset(); request(); tx = await api.applyPureVpnConfig(context, 'main', '', newConfig, true);
  handshake(tx); reloadProcess(); await api.recoverPureVpnApply(context);
  assert.equal(await store.loadProfileText(context, 'main'), newConfig); assert.ok(!fs.existsSync(directory + '/purevpn-apply-journal.json'));

  reset(); request(); tx = await api.applyPureVpnConfig(context, 'main', '', newConfig, true);
  reloadProcess(); await api.recoverPureVpnApply(context); assert.equal(await store.loadProfileText(context, 'main'), oldConfig);
  assert.ok(!fs.existsSync(directory + '/purevpn-apply-journal.json'));

  reset(); tx = await api.applyPureVpnConfig(context, '', 'New PureVPN', newConfig, true);
  const interrupted = journal(); interrupted.profileId = ''; interrupted.installed = false; interrupted.started = false;
  fs.writeFileSync(directory + '/purevpn-apply-journal.json', JSON.stringify(interrupted));
  // Simulate the pre-start reservation, before the new id was persisted.
  const pending = new tunnel.TunnelState(tx.session, tunnel.TunnelPhase.Starting); tunnel.writeTunnelRequest(directory, pending);
  fs.rmSync(directory + '/wireguard-tunnel-state.json');
  reloadProcess(); await api.recoverPureVpnApply(context); assert.equal(profiles.length, 1);
  console.log('PureVpnApply: passed (validation, existing/new profiles, encrypted rollback, request races, crash recovery)');
}
main().catch(e => { console.error(e); process.exitCode = 1; }).finally(() => { fs.rmSync(directory, { recursive: true, force: true }); });
