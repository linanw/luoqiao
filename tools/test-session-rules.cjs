// Persistent rule snapshots are tested with isolated files, never real profiles.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const Module = require('node:module');
const ts = require('/Applications/DevEco-Studio.app/Contents/tools/ohpm/node_modules/typescript');
const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'session-rules-'));
const fileIo = {
  OpenMode: { READ_ONLY: 0, CREATE: 1, WRITE_ONLY: 2, TRUNC: 4 }, accessSync: fs.existsSync,
  statSync: fs.statSync, readTextSync: p => fs.readFileSync(p, 'utf8'),
  mkdirSync: (p, recursive) => fs.mkdirSync(p, { recursive }),
  openSync: (p, mode) => ({ fd: fs.openSync(p, mode & 2 ? 'w' : 'r') }),
  writeSync: (fd, data) => fs.writeSync(fd, Buffer.from(data)), fsyncSync: fs.fsyncSync,
  closeSync: f => fs.closeSync(f.fd), renameSync: fs.renameSync, unlinkSync: fs.unlinkSync,
  copyFileSync: fs.copyFileSync, rmdirSync: p => fs.rmSync(p, { recursive: true }), listFileSync: fs.readdirSync,
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
const sessions = require('../entry/src/main/ets/model/SessionRules.ets');
const split = require('../entry/src/main/ets/model/SplitTunnel.ets');
const networks = require('../entry/src/main/ets/model/NetworkProfiles.ets');
const subnets = require('../entry/src/main/ets/model/SubnetPreferences.ets');
const tunnel = require('../entry/src/main/ets/model/TunnelState.ets');
const groups = require('../entry/src/main/ets/model/AddressGroups.ets');
const wg = crypto.randomUUID(), tn = crypto.randomUUID(), session = crypto.randomUUID();
const load = (id = session, wgIds = [wg], tnIds = [tn], mixed = true, useConfigRoutes = false) =>
  sessions.readOrCreateSessionRules(directory, id, wgIds, tnIds, mixed, useConfigRoutes);
const sessionDir = id => path.join(directory, 'session-rules', id);
try {
  const profile = new networks.NetworkProfile(); profile.ID = tn; profile.Name = 'Original network'; profile.Hostname = 'first-device';
  networks.saveNetworkProfiles(directory, [profile]);
  split.writeProfileRules(directory, wg, new split.ProfileRules(true, false, ['site'], ['manual.example'], ['192.0.2.0/24']));
  split.writeProfileRules(directory, tn, new split.ProfileRules(true, false, ['tail-site'], ['private.example'], ['10.0.0.0/8']));
  split.writeDomainListCache(directory, 'site', 'old.example\nfull:exact.example\ninclude:child\n');
  split.writeDomainListCache(directory, 'child', 'child.example\n');
  subnets.saveSubnetPreferences(directory, [new subnets.SubnetPreference('192.168.72.0/24', 'local')]);
  fs.writeFileSync(path.join(directory, 'dlc.dat'), 'synthetic-original-geosite');
  fs.writeFileSync(path.join(directory, 'private-test-config'), 'PrivateKey = NEVER_COPY_THIS_SECRET');

  const snapshot = load();
  assert.equal(snapshot.WireGuard[0].Rules.hasContent(), true);
  assert.deepEqual(snapshot.WireGuard[0].Domains, ['old.example', 'child.example', 'manual.example']);
  assert.deepEqual(snapshot.WireGuard[0].Exacts, ['exact.example']);
  assert.equal(snapshot.Tailnets.Profiles[0].Hostname, 'first-device');
  assert.equal(snapshot.Tailnets.DatabasePath, sessionDir(session) + '/dlc.dat');
  assert.equal(fs.readFileSync(snapshot.Tailnets.DatabasePath, 'utf8'), 'synthetic-original-geosite');
  const rulesFile = path.join(sessionDir(session), 'rules.json');
  const saved = fs.readFileSync(rulesFile, 'utf8');
  assert.equal(saved.includes('NEVER_COPY_THIS_SECRET'), false);
  assert.equal(saved.includes('PrivateKey'), false);
  assert.deepEqual(fs.readdirSync(sessionDir(session)).sort(), ['dlc.dat', 'rules.json']);

  // Change every editable source. A recreated ability gets the original effective
  // rules, expanded includes, Tailnet identity, preferences and database bytes.
  split.writeProfileRules(directory, wg, new split.ProfileRules(false, true));
  split.writeProfileRules(directory, tn, new split.ProfileRules(true, false, ['tail-site'], ['new-private.example'], []));
  split.writeDomainListCache(directory, 'site', 'new.example\n');
  split.writeDomainListCache(directory, 'child', 'changed-child.example\n');
  profile.Hostname = 'new-device'; profile.ControlURL = 'https://headscale.example.com'; networks.saveNetworkProfiles(directory, [profile]);
  subnets.saveSubnetPreferences(directory, [new subnets.SubnetPreference('192.168.72.0/24', 'tailnet', tn)]);
  fs.writeFileSync(path.join(directory, 'dlc.dat'), 'synthetic-new-geosite');
  snapshot.WireGuard[0].Domains.push('in-memory.example'); snapshot.Tailnets.Profiles[0].Hostname = 'mutated';
  const recovered = load();
  assert.equal(recovered.WireGuard[0].Rules.hasContent(), true);
  assert.deepEqual(recovered.WireGuard[0].Domains, ['old.example', 'child.example', 'manual.example']);
  assert.equal(recovered.WireGuard[0].Rules.isDefault, false);
  assert.equal(recovered.Tailnets.Profiles[0].Hostname, 'first-device');
  assert.equal(recovered.Tailnets.Profiles[0].ControlURL, '');
  assert.deepEqual(recovered.Tailnets.Profiles[0].Domains, ['private.example']);
  assert.equal(recovered.SubnetPreferences[0].Priority, 'local');
  assert.equal(fs.readFileSync(recovered.Tailnets.DatabasePath, 'utf8'), 'synthetic-original-geosite');
  assert.equal(fs.readFileSync(rulesFile, 'utf8'), saved);

  const nextSession = crypto.randomUUID(), next = load(nextSession);
  assert.equal(next.WireGuard[0].Rules.isDefault, true); assert.deepEqual(next.WireGuard[0].Domains, []);
  assert.equal(next.Tailnets.Profiles[0].Hostname, 'new-device');
  assert.equal(next.SubnetPreferences[0].Priority, 'tailnet');
  assert.equal(fs.readFileSync(next.Tailnets.DatabasePath, 'utf8'), 'synthetic-new-geosite');
  sessions.cleanupSessionRules(directory, nextSession); assert.equal(fs.existsSync(sessionDir(nextSession)), false);
  assert.equal(fs.existsSync(sessionDir(session)), true);
  assert.equal(fs.readFileSync(path.join(directory, 'dlc.dat'), 'utf8'), 'synthetic-new-geosite');

  // Invalid/corrupt existing sessions never silently adopt newly saved rules.
  assert.throws(() => load(session, [], [tn]), /快照无法恢复/);
  assert.throws(() => load(session, [wg], [tn], true, true), /快照无法恢复/);
  assert.throws(() => load(session, [wg], [tn], false), /快照无法恢复/);
  for (const mutate of [doc => { doc.session = crypto.randomUUID(); },
    doc => { doc.WireGuard[0].Rules = null; }, doc => { doc.WireGuard[0].Domains = 'invalid'; },
    doc => { doc.Tailnets.Directory = '/another-identity'; },
    doc => { doc.Tailnets.DatabasePath = path.join(directory, 'dlc.dat'); },
    doc => { doc.SubnetPreferences = [{ CIDR: '::/0', Priority: 'local' }]; }]) {
    const corrupt = JSON.parse(saved); mutate(corrupt); fs.writeFileSync(rulesFile, JSON.stringify(corrupt));
    assert.throws(() => load(), /快照无法恢复/);
    fs.writeFileSync(rulesFile, saved);
  }
  fs.writeFileSync(rulesFile, '{'); assert.throws(() => load(), /快照无法恢复/); fs.writeFileSync(rulesFile, saved);
  const database = path.join(sessionDir(session), 'dlc.dat');
  fs.writeFileSync(database, 'truncated'); assert.throws(() => load(), /快照无法恢复/);
  fs.unlinkSync(database); assert.throws(() => load(), /快照无法恢复/);
  fs.writeFileSync(database, 'synthetic-original-geosite');
  const incomplete = crypto.randomUUID(); fs.mkdirSync(sessionDir(incomplete));
  assert.throws(() => load(incomplete), /快照无法恢复/);
  assert.equal(fs.existsSync(path.join(sessionDir(incomplete), 'rules.json')), false);
  sessions.cleanupSessionRules(directory, incomplete);

  // Failed creation publishes neither partial rules nor a partial database.
  for (const operation of ['copyFileSync', 'writeSync', 'fsyncSync', 'renameSync']) {
    const id = crypto.randomUUID(), original = fileIo[operation];
    fileIo[operation] = operation === 'writeSync' ? () => 1 : () => { throw new Error('simulated ' + operation + ' failure'); };
    try { assert.throws(() => load(id)); } finally { fileIo[operation] = original; }
    assert.equal(fs.existsSync(sessionDir(id)), false);
    assert.equal(fs.readdirSync(path.join(directory, 'session-rules')).some(name => name.startsWith(id)), false);
    assert.equal(fs.readFileSync(rulesFile, 'utf8'), saved);
  }

  split.writeProfileRules(directory, wg, new split.ProfileRules(false, false));
  const fallback = load(crypto.randomUUID(), [wg], []);
  assert.equal(fallback.WireGuard[0].Rules.isDefault, true);
  assert.deepEqual(fallback.WireGuard[0].Domains, []); assert.equal(fallback.Tailnets, undefined);
  split.writeProfileRules(directory, wg, new split.ProfileRules(true, false, ['not-cached']));
  const missing = crypto.randomUUID(); assert.throws(() => load(missing, [wg], []), /未完整下载/);
  assert.equal(fs.existsSync(sessionDir(missing)), false);
  const configured = load(crypto.randomUUID(), [wg], [], false, true);
  assert.equal(configured.WireGuard[0].Rules.isDefault, true);
  const onlyTailnet = load(crypto.randomUUID(), [], [tn]);
  assert.deepEqual(onlyTailnet.WireGuard, []); assert.equal(onlyTailnet.Tailnets.Profiles[0].ID, tn);
  fs.mkdirSync(path.join(directory, 'tailnet', 'tailscale'), { recursive: true });
  const legacy = load(crypto.randomUUID(), [], ['legacy']);
  assert.equal(legacy.Tailnets.Profiles[0].LegacyState, true);
  assert.equal(legacy.DatabaseBytes, 0); assert.equal(legacy.Tailnets.DatabasePath, '');
  assert.throws(() => load('../escape'), /标识/);
  assert.throws(() => sessions.cleanupSessionRules(directory, '../escape'), /标识/);
  assert.throws(() => load(crypto.randomUUID(), [wg, wg], []), /重复/);

  // Named address groups are frozen as effective rules for each engine. Editing
  // or even losing the catalog must not change a recovered running session.
  const groupWG = crypto.randomUUID(), groupTN = crypto.randomUUID();
  const groupedProfile = new networks.NetworkProfile();
  Object.assign(groupedProfile, { ID: groupTN, Name: 'Grouped Tailnet', Hostname: 'group-test' });
  networks.saveNetworkProfiles(directory, [profile, groupedProfile]);
  const wgGroup = groups.saveAddressGroup(directory, new groups.AddressGroup('', 'Work sites',
    ['wg-old-group.example'], ['198.51.100.0/24', '2001:db8:41::/48']));
  const tnGroup = groups.saveAddressGroup(directory, new groups.AddressGroup('', 'Home sites',
    ['tn-old-group.example'], ['10.44.0.0/16', 'fd44::/48']));
  split.writeProfileRules(directory, groupWG, new split.ProfileRules(true, false, [],
    ['wg-manual.example'], ['192.0.2.0/24'], [wgGroup.id]));
  split.writeProfileRules(directory, groupTN, new split.ProfileRules(true, false, [],
    ['tn-manual.example'], ['10.45.0.0/16'], [tnGroup.id]));
  const groupedSession = crypto.randomUUID(), grouped = load(groupedSession, [groupWG], [groupTN]);
  const oldWGDomains = ['wg-manual.example', 'wg-old-group.example'];
  const oldWGIPs = ['192.0.2.0/24', '198.51.100.0/24', '2001:db8:41::/48'];
  const oldTNDomains = ['tn-manual.example', 'tn-old-group.example'];
  const oldTNIPs = ['10.45.0.0/16', '10.44.0.0/16', 'fd44::/48'];
  const assertOriginalGroups = value => {
    assert.deepEqual(value.WireGuard[0].Domains, oldWGDomains);
    assert.deepEqual(value.WireGuard[0].Rules.manualCidrs, oldWGIPs);
    assert.deepEqual(value.WireGuard[0].Rules.groupIds, [wgGroup.id]);
    assert.deepEqual(value.Tailnets.Profiles[0].Domains, oldTNDomains);
    assert.deepEqual(value.Tailnets.Profiles[0].CIDRs, oldTNIPs);
  };
  assertOriginalGroups(grouped);
  assert.equal(grouped.DatabaseBytes, 0, 'manual address groups do not require a GeoSite database');
  const groupedJSON = fs.readFileSync(path.join(sessionDir(groupedSession), 'rules.json'), 'utf8');
  groups.saveAddressGroup(directory, new groups.AddressGroup(wgGroup.id, 'Changed work sites',
    ['wg-new-group.example'], ['203.0.113.0/24', '2001:db8:42::/48']));
  groups.saveAddressGroup(directory, new groups.AddressGroup(tnGroup.id, 'Changed home sites',
    ['tn-new-group.example'], ['10.46.0.0/16', 'fd46::/48']));
  assertOriginalGroups(load(groupedSession, [groupWG], [groupTN]));
  assert.equal(fs.readFileSync(path.join(sessionDir(groupedSession), 'rules.json'), 'utf8'), groupedJSON);
  const groupedNext = load(crypto.randomUUID(), [groupWG], [groupTN]);
  assert.deepEqual(groupedNext.WireGuard[0].Domains, ['wg-manual.example', 'wg-new-group.example']);
  assert.deepEqual(groupedNext.WireGuard[0].Rules.manualCidrs, ['192.0.2.0/24', '203.0.113.0/24', '2001:db8:42::/48']);
  assert.deepEqual(groupedNext.Tailnets.Profiles[0].Domains, ['tn-manual.example', 'tn-new-group.example']);
  assert.deepEqual(groupedNext.Tailnets.Profiles[0].CIDRs, ['10.45.0.0/16', '10.46.0.0/16', 'fd46::/48']);
  const groupOnlyID = crypto.randomUUID();
  split.writeProfileRules(directory, groupOnlyID, new split.ProfileRules(true, false, [], [], [], [wgGroup.id]));
  const groupOnly = load(crypto.randomUUID(), [groupOnlyID], []);
  assert.equal(groupOnly.WireGuard[0].Rules.isDefault, false, 'a group-only rule must not become a default route');
  assert.deepEqual(groupOnly.WireGuard[0].Domains, ['wg-new-group.example']);
  assert.deepEqual(groupOnly.WireGuard[0].Rules.manualCidrs, ['203.0.113.0/24', '2001:db8:42::/48']);
  const catalogPath = path.join(directory, 'address-groups.json');
  fs.renameSync(catalogPath, catalogPath + '.missing');
  try {
    assertOriginalGroups(load(groupedSession, [groupWG], [groupTN]));
    for (const [wireguards, tailnets] of [[[groupWG], []], [[], [groupTN]]]) {
      const id = crypto.randomUUID();
      assert.throws(() => load(id, wireguards, tailnets), /地址组.*不存在|不存在.*地址组|地址组.*缺失/);
      assert.equal(fs.existsSync(sessionDir(id)), false, 'a missing group cannot publish a partial session');
    }
  } finally { fs.renameSync(catalogPath + '.missing', catalogPath); }

  // A disconnected status may be a system-destroy/restart boundary. Only a
  // successfully published explicit stop request can retire that session's rules.
  const stoppedSession = crypto.randomUUID(), untouchedSession = crypto.randomUUID();
  load(stoppedSession, [], ['legacy']); load(untouchedSession, [], ['legacy']);
  tunnel.writeTunnelRequest(directory, new tunnel.TunnelState(stoppedSession, tunnel.TunnelPhase.Starting));
  tunnel.writeTunnelState(directory, new tunnel.TunnelState(stoppedSession, tunnel.TunnelPhase.Disconnected));
  assert.equal(fs.existsSync(sessionDir(stoppedSession)), true, 'publishing status alone cannot clear a requested session');
  const rename = fileIo.renameSync;
  fileIo.renameSync = (source, destination) => {
    if (destination.endsWith('/wireguard-tunnel-request.json')) { throw new Error('simulated stop publication failure'); }
    return rename(source, destination);
  };
  try {
    assert.throws(() => tunnel.writeTunnelRequest(directory, new tunnel.TunnelState(stoppedSession, tunnel.TunnelPhase.Disconnected)));
  } finally { fileIo.renameSync = rename; }
  assert.equal(fs.existsSync(sessionDir(stoppedSession)), true);
  assert.equal(tunnel.readTunnelRequest(directory).phase, tunnel.TunnelPhase.Starting);
  tunnel.writeTunnelRequest(directory, new tunnel.TunnelState(stoppedSession, tunnel.TunnelPhase.Stopping));
  assert.equal(fs.existsSync(sessionDir(stoppedSession)), true);
  tunnel.writeTunnelRequest(directory, new tunnel.TunnelState(stoppedSession, tunnel.TunnelPhase.Disconnected));
  assert.equal(fs.existsSync(sessionDir(stoppedSession)), false);
  assert.equal(fs.existsSync(sessionDir(untouchedSession)), true);
  assert.equal(fs.existsSync(path.join(directory, 'tailnet', 'tailscale')), true);
  assert.equal(fs.readFileSync(path.join(directory, 'dlc.dat'), 'utf8'), 'synthetic-new-geosite');
  console.log('Session rules: immutable recovery/new-session changes, WG/Tailnet address groups with IPv4/IPv6 and missing catalog recovery, expanded caches, isolated GeoSite copy, no keys, strict corruption rejection, atomic failures, defaults/zero-WG/legacy and scoped cleanup passed');
} finally { fs.rmSync(directory, { recursive: true, force: true }); Module._load = originalLoad; }
