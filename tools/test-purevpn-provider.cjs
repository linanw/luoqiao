// Portable policy/storage tests, including real files and interrupted atomic writes.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const Module = require('node:module');
const devEco = process.env.DEVECO_HOME || '/Applications/DevEco-Studio.app/Contents';
const ts = require(path.join(devEco, 'tools/ohpm/node_modules/typescript'));
let shortWrite = false;
let failRename = false;
let raceMkdir = false;
let writeCount = 0;
const fileIo = {
  OpenMode: { CREATE: 1, WRITE_ONLY: 2, TRUNC: 4 },
  accessSync: fs.existsSync,
  statSync: fs.statSync,
  readTextSync: file => fs.readFileSync(file, 'utf8'),
  mkdirSync: (file, recursive) => {
    if (raceMkdir) { raceMkdir = false; fs.mkdirSync(file, { recursive }); }
    if (fs.existsSync(file)) { const error = new Error('File exists'); error.code = 13900015; throw error; }
    fs.mkdirSync(file, { recursive });
  },
  openSync: file => ({ fd: fs.openSync(file, 'w') }),
  writeSync: (fd, data) => {
    writeCount++;
    const bytes = Buffer.from(data);
    return fs.writeSync(fd, bytes, 0, shortWrite ? bytes.length - 1 : bytes.length);
  },
  fsyncSync: fs.fsyncSync,
  closeSync: file => fs.closeSync(file.fd),
  renameSync: (source, destination) => {
    if (failRename) { throw new Error('injected rename failure'); }
    fs.renameSync(source, destination);
  },
  unlinkSync: fs.unlinkSync,
};
const originalLoad = Module._load;
const originalEts = require.extensions['.ets'];
Module._load = function (id, parent, isMain) {
  if (id === '@kit.CoreFileKit') { return { fileIo }; }
  if (id === '@kit.ArkTS') {
    return { util: { generateRandomUUID: crypto.randomUUID,
      TextEncoder: { create: () => ({ encodeInto: text => new TextEncoder().encode(text) }) } } };
  }
  return originalLoad.call(this, id, parent, isMain);
};
require.extensions['.ets'] = (module, filename) => {
  const result = ts.transpileModule(fs.readFileSync(filename, 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }, fileName: filename,
  });
  module._compile(result.outputText, filename);
};
const model = require('../entry/src/main/ets/model/PureVpnProvider.ets');
const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'harmony-purevpn-'));
const importedAt = 1700000000000;
const profile = () => new model.PureVpnProfile('main', 'Malaysia / Kuala Lumpur', importedAt, true);
const input = overrides => Object.assign({
  now: importedAt + 120000,
  profileId: 'main',
  phase: 'waiting',
  lastHandshake: 0,
  attemptStartedAt: importedAt + 1000,
  physicalNetworkAvailable: true,
}, overrides);
const decision = (p, overrides) => model.renewalDecision(p, input(overrides));
try {
  // Activation and elapsed download time are different concepts. Neither 15 minutes nor an
  // idle established tunnel is evidence that the provider revoked the configuration.
  const healthy = model.markPureVpnActivated(profile(), importedAt + 2000);
  assert.equal(decision(healthy, { now: importedAt + 24 * 3600000, phase: 'connected',
    lastHandshake: importedAt + 2000 }).action, 'keep');
  assert.equal(decision(profile(), { now: importedAt + 16 * 60000, phase: 'connected',
    lastHandshake: importedAt + 15 * 60000 }).reason, 'recent-handshake');
  assert.equal(decision(profile(), { phase: 'connected', lastHandshake: 0 }).action, 'keep');
  assert.equal(decision(profile(), { now: importedAt + 24 * 3600000, phase: 'waiting',
    lastHandshake: importedAt + 2000 }).reason, 'prior-handshake', 'old activated keys are not diagnosed as expired');
  assert.equal(decision(profile(), { lastHandshake: importedAt + 10000 }).action, 'keep');
  assert.equal(decision(profile(), {}).action, 'refresh');
  assert.equal(decision(profile(), {}).reason, 'connection-unresponsive');
  assert.equal(decision(profile(), { mixed: true, tailnetIds: ['tailnet-a'] }).reason, 'combined-session');
  assert.equal(decision(profile(), { mixed: true, tailnetIds: [] }).action, 'keep');
  assert.equal(decision(profile(), { mixed: false, tailnetIds: ['tailnet-a'] }).reason, 'combined-session');
  assert.equal(decision(profile(), { mixed: true, lastHandshake: importedAt + 10000 }).activatedAt, 0,
    'aggregate combined handshake must not activate a PureVPN profile');
  assert.equal(decision(profile(), { now: importedAt + 90999 }).action, 'keep');
  assert.equal(decision(profile(), { now: importedAt + 91000 }).action, 'refresh');
  assert.equal(decision(profile(), { attemptStartedAt: 0 }).action, 'keep');
  assert.equal(decision(profile(), { physicalNetworkAvailable: false }).reason, 'offline');
  assert.equal(decision(undefined, {}).reason, 'unknown-profile');
  assert.equal(decision(profile(), { profileId: '12345678', lastHandshake: importedAt + 100000 }).reason, 'unknown-profile');
  assert.equal(decision(profile(), { phase: 'failed' }).action, 'keep');
  const disabled = profile(); disabled.autoRenew = false;
  assert.equal(decision(disabled, {}).reason, 'disabled');
  const recentOtherImport = importedAt - 1;
  assert.equal(model.markPureVpnActivated(profile(), 0).lastActivatedAt, 0);
  assert.equal(model.markPureVpnActivated(profile(), recentOtherImport).lastActivatedAt, 0);
  assert.equal(model.markPureVpnActivated(profile(), importedAt).lastActivatedAt, 0);
  assert.equal(model.markPureVpnActivated(profile(), importedAt + 1).lastActivatedAt, importedAt + 1);
  assert.equal(decision(profile(), { lastHandshake: NaN }).reason, 'invalid-time');
  assert.equal(decision(profile(), { lastHandshake: importedAt + 200000 }).reason, 'invalid-time');
  assert.equal(decision(profile(), { now: importedAt - 1 }).reason, 'invalid-time');

  // A refresh must be claimed before invoking the website, so another poll cannot start it.
  const started = model.markPureVpnRefreshStarted(profile(), input({}).now);
  assert.equal(decision(started, { now: importedAt + 999999 }).reason, 'refresh-in-progress');
  let failed = model.markPureVpnRefreshFailure(started, input({}).now);
  assert.equal(failed.nextAttemptAt, input({}).now + 60000);
  assert.equal(decision(failed, {}).reason, 'backoff');
  assert.equal(decision(failed, { now: failed.nextAttemptAt }).action, 'refresh');
  let now = failed.nextAttemptAt;
  for (let index = 0; index < 30; index++) {
    failed = model.markPureVpnRefreshFailure(failed, now);
    assert.ok(failed.nextAttemptAt - now <= 30 * 60000);
    now = failed.nextAttemptAt;
  }
  assert.equal(failed.failureCount, 10);
  assert.equal(failed.nextAttemptAt - (now - 30 * 60000), 30 * 60000);
  const needsUser = model.markPureVpnRefreshFailure(failed, now, true);
  assert.equal(decision(needsUser, { now: now + 99999999 }).reason, 'needs-user');
  const recovered = model.markPureVpnActivated(failed, now + 1);
  assert.equal(recovered.failureCount, 0);
  assert.equal(recovered.nextAttemptAt, 0);
  assert.equal(recovered.status, 'active');
  assert.equal(profile().status, 'ready', 'helpers must not mutate caller state');
  const paused = model.markPureVpnRefreshPaused(started, input({}).now + 5000);
  assert.equal(paused.status, 'queued'); assert.equal(paused.failureCount, 0);

  // The runtime has its own durable observation document and never overwrites foreground
  // task state. A lost handshake is an unresponsive startup, not a provider-expiry diagnosis.
  model.writePureVpnProfile(directory, profile());
  const health = overrides => Object.assign({ now: importedAt + 1000, profileId: 'main', session: 'session-a',
    phase: 'waiting', physicalNetworkAvailable: true, networkError: false, running: true,
    lastHandshake: 0, sentBytes: 148, receivedBytes: 0, lastFailedRequestAt: 0 }, overrides);
  let observation;
  for (let elapsed = 0; elapsed <= 90000; elapsed += 10000) {
    observation = model.observePureVpnHealth(directory, health({ now: importedAt + 1000 + elapsed }));
    assert.equal(observation.state, elapsed < 90000 ? 'watching' : 'queued');
  }
  assert.equal(observation.reason, 'startup-unresponsive');
  assert.equal(model.readPureVpnProfile(directory, 'main').status, 'ready', 'runtime must not claim the UI job');
  assert.equal(model.readPureVpnRecovery(directory, 'main').state, 'queued', 'queue survives a new reader');
  const queuedInput = input({ session: 'session-a', now: observation.updatedAt,
    attemptStartedAt: observation.waitingSince });
  assert.equal(model.queuedPureVpnRenewalDecision(profile(), observation, queuedInput).action, 'refresh');
  for (const changed of [{ session: 'session-b' }, { now: observation.updatedAt + 30001 },
    { lastHandshake: importedAt + 1 }, { physicalNetworkAvailable: false }, { mixed: true },
    { phase: 'connected' }]) {
    assert.equal(model.queuedPureVpnRenewalDecision(profile(), observation,
      { ...queuedInput, ...changed }).action, 'keep');
  }
  const blocked = model.markPureVpnNeedsOfficialInteraction(profile(), observation.updatedAt);
  assert.equal(model.queuedPureVpnRenewalDecision(blocked, observation, queuedInput).reason, 'needs-user');
  assert.equal(model.queuedPureVpnRenewalDecision(blocked, observation, queuedInput, true).action, 'refresh',
    'only a verified official page can resume the interactive job');
  const cancelled = model.markPureVpnRefreshFailure(profile(), observation.updatedAt, true);
  assert.equal(model.queuedPureVpnRenewalDecision(cancelled, observation, queuedInput, true).action, 'keep',
    'an authenticated page must not undo an explicit cancellation or repeat an unknown website failure');
  const updatedProfile = new model.PureVpnProfile('main', 'Malaysia', observation.updatedAt, true);
  assert.equal(model.queuedPureVpnRenewalDecision(updatedProfile, observation, queuedInput).action, 'keep');
  observation = model.observePureVpnHealth(directory, health({ now: importedAt + 100000,
    physicalNetworkAvailable: false }));
  assert.equal(observation.reason, 'offline'); assert.equal(observation.waitingSince, 0);
  observation = model.observePureVpnHealth(directory, health({ now: importedAt + 110000 }));
  assert.equal(observation.state, 'watching'); assert.equal(observation.waitingSince, importedAt + 110000);
  observation = model.observePureVpnHealth(directory, health({ now: importedAt + 210000 }));
  assert.equal(observation.state, 'watching', 'a suspended observer cannot count a long offline gap as failure');
  assert.equal(observation.waitingSince, importedAt + 210000);
  observation = model.observePureVpnHealth(directory, health({ now: importedAt + 220000, networkError: true }));
  assert.equal(observation.reason, 'offline'); assert.equal(observation.waitingSince, 0);
  observation = model.observePureVpnHealth(directory, health({ now: importedAt + 230000, running: false }));
  assert.equal(observation.state, 'needs-check');
  assert.equal(observation.reason, 'native-not-running');
  assert.equal(model.observePureVpnHealth(directory, health({ now: importedAt + 240000,
    lastFailedRequestAt: NaN })), undefined);
  assert.equal(model.observePureVpnHealth(directory, health({ profileId: '12345678' })), undefined);

  // Long-idle established connections stay healthy; simulated failed requests can request
  // checking the exact profile, but never automatically generate a replacement key.
  const idleAt = importedAt + 24 * 3600000;
  const established = { session: 'session-b', phase: 'connected', lastHandshake: importedAt + 2000 };
  observation = model.observePureVpnHealth(directory, health({ ...established, now: idleAt }));
  assert.equal(observation.state, 'watching'); assert.equal(observation.reason, 'healthy');
  for (let index = 1; index <= 3; index++) {
    observation = model.observePureVpnHealth(directory, health({ ...established,
      now: idleAt + index * 10000, lastFailedRequestAt: idleAt + index * 10000 }));
  }
  assert.equal(observation.state, 'needs-check'); assert.equal(observation.reason, 'request-failures');
  assert.equal(observation.failureCount, 3);
  assert.equal(model.queuedPureVpnRenewalDecision(profile(), observation,
    input({ now: observation.updatedAt, session: 'session-b' })).action, 'keep');
  observation = model.observePureVpnHealth(directory, health({ ...established, now: idleAt + 40000,
    lastFailedRequestAt: idleAt + 30000 }));
  assert.equal(observation.failureCount, 3, 'the same retained native event is counted only once');
  observation = model.observePureVpnHealth(directory, health({ ...established, now: idleAt + 50000,
    receivedBytes: 10, lastFailedRequestAt: idleAt + 30000 }));
  assert.equal(observation.state, 'watching'); assert.equal(observation.failureCount, 0, 'new receive traffic cancels suspicion');
  observation = model.observePureVpnHealth(directory, health({ ...established, now: idleAt + 60000,
    receivedBytes: 10, lastFailedRequestAt: idleAt + 30000 }));
  assert.equal(observation.failureCount, 0, 'an old failure must not be recounted after recovery');
  // No sent packets means no connection attempt, even if the runtime's phase is waiting.
  const idleStart = idleAt + 120000;
  for (let elapsed = 0; elapsed <= 150000; elapsed += 10000) {
    observation = model.observePureVpnHealth(directory, health({ session: 'unused-session',
      now: idleStart + elapsed, sentBytes: 0 }));
    assert.equal(observation.state, 'watching'); assert.equal(observation.waitingSince, 0);
    assert.equal(observation.reason, 'waiting-for-traffic');
  }
  // Fast VPN polling retains every sample in memory, with at most one persisted write per
  // 15s except for meaningful transitions. An offline transition is immediate.
  const burstStart = idleStart + 180000;
  model.observePureVpnHealth(directory, health({ session: 'poll-session', now: burstStart, sentBytes: 0 }));
  const beforeBurst = writeCount;
  for (let elapsed = 1500; elapsed <= 13500; elapsed += 1500) {
    observation = model.observePureVpnHealth(directory, health({ session: 'poll-session',
      now: burstStart + elapsed, sentBytes: 0 }));
  }
  assert.equal(writeCount, beforeBurst, 'steady polling does not fsync every 1.5s');
  model.observePureVpnHealth(directory, health({ session: 'poll-session', now: burstStart + 15000, sentBytes: 0 }));
  assert.equal(writeCount, beforeBurst + 1);
  model.observePureVpnHealth(directory, health({ session: 'poll-session', now: burstStart + 16000,
    sentBytes: 0, physicalNetworkAvailable: false }));
  assert.equal(writeCount, beforeBurst + 2);
  assert.equal(model.readPureVpnRecovery(directory, 'main').reason, 'offline');
  // Persistence failures are surfaced to the runtime's catch, leave the prior file intact,
  // and do not issue any connection or configuration mutation.
  const durableObservation = fs.readFileSync(path.join(directory, 'purevpn-recovery', 'main.json'), 'utf8');
  failRename = true;
  assert.throws(() => model.observePureVpnHealth(directory, health({ session: 'poll-session',
    now: burstStart + 17000, sentBytes: 0 })), /rename/);
  failRename = false;
  assert.equal(fs.readFileSync(path.join(directory, 'purevpn-recovery', 'main.json'), 'utf8'), durableObservation);
  model.deletePureVpnProfile(directory, 'main');

  // Metadata operations may only touch their own directory, never encrypted configs or rules.
  fs.mkdirSync(path.join(directory, 'profiles'));
  fs.writeFileSync(path.join(directory, 'profiles', 'main.enc'), 'encrypted sentinel');
  fs.writeFileSync(path.join(directory, 'split-rules-main.json'), 'rules sentinel');
  assert.equal(model.readPureVpnProfile(directory, 'main'), undefined);
  const original = profile(); original.privateKey = 'must never be serialized';
  model.writePureVpnProfile(directory, original);
  const metadataPath = path.join(directory, 'purevpn-provider', 'main.json');
  const saved = fs.readFileSync(metadataPath, 'utf8');
  assert.ok(!saved.includes('privateKey'));
  assert.equal(model.readPureVpnProfile(directory, 'main').location, original.location);
  const next = profile(); next.location = 'Singapore';
  shortWrite = true;
  assert.throws(() => model.writePureVpnProfile(directory, next));
  shortWrite = false;
  assert.equal(fs.readFileSync(metadataPath, 'utf8'), saved);
  failRename = true;
  assert.throws(() => model.writePureVpnProfile(directory, next));
  failRename = false;
  assert.equal(fs.readFileSync(metadataPath, 'utf8'), saved);
  assert.deepEqual(fs.readdirSync(path.dirname(metadataPath)), ['main.json'], 'failed temporary writes cleaned');
  model.writePureVpnProfile(directory, next);
  assert.equal(model.readPureVpnProfile(directory, 'main').location, 'Singapore');
  for (const text of ['{broken', JSON.stringify({ version: 1, profile: { ...original, profileId: '12345678' } }),
    JSON.stringify({ version: 1, profile: { ...original, status: 'pretend-expired' } }),
    JSON.stringify({ version: 1, profile: { ...original, failureCount: 1000 } }), 'x'.repeat(4097)]) {
    fs.writeFileSync(metadataPath, text);
    assert.equal(model.readPureVpnProfile(directory, 'main'), undefined, 'corruption must fail closed');
  }
  for (const id of ['../escape', '', 'main/other', 'main\u0000']) {
    assert.throws(() => model.readPureVpnProfile(directory, id));
    assert.throws(() => model.deletePureVpnProfile(directory, id));
    const bad = profile(); bad.profileId = id;
    assert.throws(() => model.writePureVpnProfile(directory, bad));
  }
  const badLocation = profile(); badLocation.location = 'x'.repeat(129);
  assert.throws(() => model.writePureVpnProfile(directory, badLocation));
  model.deletePureVpnProfile(directory, 'main');
  model.deletePureVpnProfile(directory, 'main');
  assert.equal(fs.readFileSync(path.join(directory, 'profiles', 'main.enc'), 'utf8'), 'encrypted sentinel');
  assert.equal(fs.readFileSync(path.join(directory, 'split-rules-main.json'), 'utf8'), 'rules sentinel');
  const providerDirectory = path.join(directory, 'purevpn-provider');
  fs.rmSync(providerDirectory, { recursive: true });
  raceMkdir = true;
  model.writePureVpnProfile(directory, profile());
  assert.equal(model.readPureVpnProfile(directory, 'main').profileId, 'main', 'concurrent directory creation is safe');
  fs.rmSync(providerDirectory, { recursive: true }); fs.writeFileSync(providerDirectory, 'not a directory');
  assert.throws(() => model.writePureVpnProfile(directory, profile()), /目录/);
  assert.equal(fs.readFileSync(providerDirectory, 'utf8'), 'not a directory');
  console.log('PureVPN: activation vs elapsed time, same-profile evidence, offline/interactive guards, bounded backoff, atomic failure recovery and metadata isolation passed');
} finally {
  Module._load = originalLoad;
  if (originalEts) { require.extensions['.ets'] = originalEts; } else { delete require.extensions['.ets']; }
  fs.rmSync(directory, { recursive: true, force: true });
}
