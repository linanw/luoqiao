// Exercise real page handlers without ArkUI rendering. Files, profiles and the
// active session are synthetic; no real accounts, keys or network are accessed.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const Module = require('node:module');
const ts = require('/Applications/DevEco-Studio.app/Contents/tools/ohpm/node_modules/typescript');
const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'live-rule-editing-'));
const fileIo = {
  OpenMode: { CREATE: 1, WRITE_ONLY: 2, TRUNC: 4 }, accessSync: fs.existsSync,
  statSync: fs.statSync, readTextSync: p => fs.readFileSync(p, 'utf8'),
  mkdirSync: (p, recursive) => fs.mkdirSync(p, { recursive }),
  openSync: p => ({ fd: fs.openSync(p, 'w') }), writeSync: (fd, data) => fs.writeSync(fd, Buffer.from(data)),
  fsyncSync: fs.fsyncSync, closeSync: f => fs.closeSync(f.fd), renameSync: fs.renameSync, unlinkSync: fs.unlinkSync,
  rmdirSync: p => fs.rmSync(p, { recursive: true }), listFileSync: fs.readdirSync,
};
const wgID = crypto.randomUUID(), tnID = crypto.randomUUID();
let wireguards = [{ id: wgID, name: 'Test WG' }];
let fetchHook;
const originalLoad = Module._load;
const oldScroller = global.Scroller;
const oldEdge = global.Edge;
global.Scroller = class { scrollEdge() {} };
global.Edge = { Top: 0 };
Module._load = function (id, parent, isMain) {
  if (id === '@kit.CoreFileKit') { return { fileIo }; }
  if (id === '@kit.ArkTS') { return { util: { generateRandomUUID: crypto.randomUUID,
    TextEncoder: { create: () => ({ encodeInto: s => new TextEncoder().encode(s) }) } } }; }
  if (id === '@kit.NetworkKit') { return { connection: {} }; }
  if (id === '@kit.ArkUI') { return { router: { getParams: () => ({}) } }; }
  if (id.endsWith('/ProfileStore')) { return {
    listProfiles: () => wireguards,
    isValidProfileId: id => /^(main|[0-9a-fA-F-]{8,64})$/.test(id),
  }; }
  if (id.endsWith('/DomainListSource')) { return {
    fetchCatalog: async () => ['site'], fetchDomainList: async name => {
      if (fetchHook) { await fetchHook(name); }
      return name + '.example\n';
    },
  }; }
  if (id.endsWith('/DomainDatabase')) { return {
    DomainDatabaseInfo: class { catalog = []; available = true; updatedAt = 0; },
    domainDatabaseCatalog: async () => ['site'],
    readDomainDatabaseInfo: () => ({ catalog: ['site'], available: true, updatedAt: 1 }),
  }; }
  return originalLoad.call(this, id, parent, isMain);
};
function compile(module, filename, source) {
  const result = ts.transpileModule(source, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }, fileName: filename,
  });
  module._compile(result.outputText, filename);
}
require.extensions['.ets'] = (module, filename) => {
  let source = fs.readFileSync(filename, 'utf8');
  const name = path.basename(filename, '.ets');
  if (filename.includes('/pages/')) {
    // Keep the actual event handlers/state and omit only the declarative builders.
    source = source.slice(0, source.indexOf('\n  @Builder')) + '\n}\nexport default ' + name + ';\n';
    source = source.replace(/@Entry\s+@Component\s+struct (\w+)/, 'class $1').replace(/@State /g, '');
  }
  compile(module, filename, source);
};
const split = require('../entry/src/main/ets/model/SplitTunnel.ets');
const groups = require('../entry/src/main/ets/model/AddressGroups.ets');
const networks = require('../entry/src/main/ets/model/NetworkProfiles.ets');
const tunnel = require('../entry/src/main/ets/model/TunnelState.ets');
const targets = require('../entry/src/main/ets/model/RuleTargets.ets');
const subnet = require('../entry/src/main/ets/model/SubnetPreferences.ets');
function page(name) {
  const Page = require(`../entry/src/main/ets/pages/${name}.ets`).default;
  const result = new Page();
  result.getUIContext = () => ({ getHostContext: () => ({ filesDir: directory }) });
  return result;
}
async function run() {
  const tn = new networks.NetworkProfile(); tn.ID = tnID; tn.Name = 'Test Tailnet';
  networks.saveNetworkProfiles(directory, [tn]);
  split.writeProfileRules(directory, wgID, new split.ProfileRules(true, false, [], ['old.example'], []));
  const session = new tunnel.TunnelState(crypto.randomUUID(), tunnel.TunnelPhase.Starting);
  session.mixed = true; session.profileIds = [wgID]; session.tailnetIds = [tnID];
  tunnel.writeTunnelRequest(directory, session);
  session.phase = tunnel.TunnelPhase.Connected; tunnel.writeTunnelState(directory, session);
  assert.equal(targets.ruleConnectionsActive(directory), true);
  const requestFile = path.join(directory, 'wireguard-tunnel-request.json');
  const statusFile = path.join(directory, 'wireguard-tunnel-state.json');
  const requestBefore = fs.readFileSync(requestFile), statusBefore = fs.readFileSync(statusFile);

  const custom = page('CustomRulesPage'); custom.reload(); custom.refreshLock();
  assert.equal(custom.connected, true); assert.equal(custom.locked, false);
  assert.equal(custom.rules.length, 1); assert.equal(custom.count('domain'), 1); assert.equal(custom.count('ip'), 0);
  custom.startAdd(); custom.targetKey = 'wireguard:' + wgID; custom.kind = 'domain'; custom.value = 'new.example'; custom.save();
  assert.ok(split.readProfileRules(directory, wgID).manualDomains.includes('new.example'));
  assert.equal(custom.rules.length, 2); assert.equal(custom.count('domain'), 2);
  assert.match(custom.notice, /已保存，下次连接生效/);
  const added = custom.rules.find(rule => rule.value === 'new.example');
  custom.startEdit(added); custom.targetKey = 'tailnet:' + tnID; custom.save();
  assert.equal(split.readProfileRules(directory, wgID).manualDomains.includes('new.example'), false);
  assert.ok(split.readProfileRules(directory, tnID).manualDomains.includes('new.example'));
  custom.remove(custom.rules.find(rule => rule.value === 'new.example'));
  assert.equal(split.readProfileRules(directory, tnID).manualDomains.includes('new.example'), false);
  assert.equal(custom.rules.length, 1); assert.equal(custom.count('domain'), 1);
  custom.metadataReady = false; custom.refreshLock();
  assert.equal(custom.locked, true, 'unreadable metadata still locks editing');

  const group = groups.saveAddressGroup(directory, new groups.AddressGroup('', 'Office addresses',
    ['office.example'], ['192.0.2.0/24', '2001:db8:1::/64']));
  custom.reload(); custom.startAdd(); custom.targetKey = 'wireguard:' + wgID;
  custom.kind = 'group'; custom.value = group.id; custom.save();
  assert.equal(custom.error, '');
  assert.deepEqual(split.readProfileRules(directory, wgID).groupIds, [group.id]);
  assert.equal(custom.count('group'), 1);
  assert.throws(() => groups.deleteAddressGroup(directory, group.id), /仍被/);
  custom.startAdd(); custom.targetKey = 'tailnet:' + tnID;
  custom.kind = 'domain'; custom.value = 'office.example'; custom.save();
  assert.match(custom.error, /同时属于/, 'manual rules cannot conflict with a group on another connection');
  assert.equal(split.readProfileRules(directory, tnID).manualDomains.includes('office.example'), false);
  custom.startEdit(custom.rules.find(rule => rule.kind === 'group')); custom.targetKey = 'tailnet:' + tnID; custom.save();
  assert.equal(custom.error, '');
  assert.deepEqual(split.readProfileRules(directory, wgID).groupIds, []);
  assert.deepEqual(split.readProfileRules(directory, tnID).groupIds, [group.id]);
  custom.remove(custom.rules.find(rule => rule.kind === 'group'));
  assert.deepEqual(split.readProfileRules(directory, tnID).groupIds, []);
  assert.ok(groups.readAddressGroups(directory).some(item => item.id === group.id), 'removing a rule keeps the reusable group');
  custom.startAdd(); custom.targetKey = 'wireguard:' + wgID;
  custom.kind = 'group'; custom.value = group.id; custom.save();
  assert.equal(custom.error, '');

  const library = page('DomainLibraryPage'); library.refreshProfiles(); library.selectedKey = 'wireguard:' + wgID;
  library.refreshProfiles(); await library.changeAssignment('site', true);
  assert.deepEqual(split.readProfileRules(directory, wgID).lists, ['site']);
  assert.equal(split.readDomainListCache(directory, 'site'), 'site.example\n');
  assert.match(library.notice, /已保存，下次连接生效/);
  await library.updateWireGuardLists(); assert.match(library.notice, /已保存，下次连接生效/);
  library.selectedKey = 'tailnet:' + tnID; library.refreshProfiles();
  await library.changeAssignment('site', true);
  assert.deepEqual(split.readProfileRules(directory, wgID).lists, []);
  assert.deepEqual(split.readProfileRules(directory, tnID).lists, ['site']);
  await library.changeAssignment('site', false);
  assert.deepEqual(split.readProfileRules(directory, tnID).lists, []);

  // Starting a download while connected is allowed, but stale edits after an
  // asynchronous fetch still cannot overwrite an intervening configuration save.
  library.selectedKey = 'wireguard:' + wgID; library.refreshProfiles();
  let release, started;
  const fetching = new Promise(resolve => { started = resolve; });
  fetchHook = async () => { started(); await new Promise(resolve => { release = resolve; }); };
  const pending = library.changeAssignment('race-site', true);
  await fetching;
  const intervening = split.readProfileRules(directory, wgID); intervening.manualDomains.push('concurrent.example');
  split.writeProfileRules(directory, wgID, intervening);
  release(); await pending; fetchHook = undefined;
  assert.match(library.error, /规则已变化/);
  assert.ok(split.readProfileRules(directory, wgID).manualDomains.includes('concurrent.example'));
  assert.equal(split.readProfileRules(directory, wgID).lists.includes('race-site'), false);
  assert.equal(split.readDomainListCache(directory, 'race-site'), undefined);

  // Address-group edits do not alter split-rules JSON. Both asynchronous paths
  // must compare their expanded members before publishing cache or ownership.
  for (const operation of ['assign', 'update']) {
    const name = 'group-race-' + operation;
    const currentRules = split.readProfileRules(directory, wgID);
    currentRules.lists = operation === 'update' ? [name] : [];
    split.writeProfileRules(directory, wgID, currentRules);
    if (operation === 'update') { split.writeDomainListCache(directory, name, 'old-cache.example\n'); }
    const rulesFile = path.join(directory, `split-rules-${wgID}.json`);
    const rulesBeforeDownload = fs.readFileSync(rulesFile, 'utf8');
    const cacheBeforeDownload = split.readDomainListCache(directory, name);
    let releaseGroup, startedGroup;
    const groupFetching = new Promise(resolve => { startedGroup = resolve; });
    fetchHook = async () => { startedGroup(); await new Promise(resolve => { releaseGroup = resolve; }); };
    const groupPending = operation === 'assign' ? library.changeAssignment(name, true) : library.updateWireGuardLists();
    await groupFetching;
    const changed = groups.readAddressGroups(directory).find(item => item.id === group.id);
    if (operation === 'assign') { changed.domains.push('changed-during-download.example'); }
    else { changed.cidrs.push('198.51.100.42/32'); }
    groups.saveAddressGroup(directory, changed);
    assert.equal(fs.readFileSync(rulesFile, 'utf8'), rulesBeforeDownload, 'group edits alone do not change stored rule references');
    releaseGroup(); await groupPending; fetchHook = undefined;
    assert.match(library.error, /规则已变化/, `${operation} must detect changed group members`);
    assert.equal(fs.readFileSync(rulesFile, 'utf8'), rulesBeforeDownload);
    assert.equal(split.readDomainListCache(directory, name), cacheBeforeDownload, 'a stale download cannot publish cache');
    assert.ok(groups.readAddressGroups(directory).find(item => item.id === group.id).domains.includes('changed-during-download.example'));
  }

  // The WireGuard limit covers list contents plus groups, including a refresh of
  // an existing assignment. The old cached batch and rule ownership remain intact.
  const beforeLimitRules = split.readProfileRules(directory, wgID);
  const beforeLimitGroup = groups.readAddressGroups(directory).find(item => item.id === group.id);
  groups.saveAddressGroup(directory, new groups.AddressGroup(group.id, 'Limit test',
    Array.from({ length: 1200 }, (_, i) => `member${i}.group.example`), []));
  split.writeProfileRules(directory, wgID, new split.ProfileRules(true, false, [], [], [], [group.id]));
  await library.changeAssignment('group-limit', true);
  assert.match(library.error, /1200/);
  assert.deepEqual(split.readProfileRules(directory, wgID).lists, []);
  assert.equal(split.readDomainListCache(directory, 'group-limit'), undefined);
  split.writeProfileRules(directory, wgID, new split.ProfileRules(true, false, ['group-limit'], [], [], [group.id]));
  split.writeDomainListCache(directory, 'group-limit', 'member0.group.example\n');
  await library.updateWireGuardLists();
  assert.match(library.error, /1200/);
  assert.deepEqual(split.readProfileRules(directory, wgID).lists, ['group-limit']);
  assert.equal(split.readDomainListCache(directory, 'group-limit'), 'member0.group.example\n');
  groups.saveAddressGroup(directory, beforeLimitGroup);
  split.writeProfileRules(directory, wgID, beforeLimitRules);

  const routes = page('SubnetRoutesPage'); routes.reload(); routes.lastLocalCheck = Date.now(); routes.refresh();
  assert.equal(routes.connected, true); assert.equal(routes.locked, false);
  routes.cidr = '192.168.72.60/24'; routes.priority = 'local'; routes.add();
  assert.equal(subnet.readSubnetPreferences(directory)[0].Priority, 'local');
  routes.update(routes.preferences[0], 'tailnet', tnID);
  assert.equal(subnet.readSubnetPreferences(directory)[0].TailnetID, tnID);
  routes.remove(routes.preferences[0]); assert.deepEqual(subnet.readSubnetPreferences(directory), []);
  assert.match(routes.notice, /已保存，下次连接生效/);
  routes.ready = false; routes.refresh(); assert.equal(routes.locked, true);

  const old = page('DomainListsPage'); old.profileId = wgID; old.rulesEnabled = true;
  old.groupIds = split.readProfileRules(directory, wgID).groupIds;
  old.newDomain = 'legacy-editor.example'; old.addManualDomain();
  assert.deepEqual(split.readProfileRules(directory, wgID).manualDomains, ['legacy-editor.example']);
  assert.deepEqual(split.readProfileRules(directory, wgID).groupIds, [group.id], 'other editors preserve group references');
  assert.match(old.notice, /已保存，下次连接生效/);
  assert.deepEqual(fs.readFileSync(requestFile), requestBefore, 'edits cannot change the active session request');
  assert.deepEqual(fs.readFileSync(statusFile), statusBefore, 'edits cannot alter current status/rules');
  assert.equal(targets.ruleConnectionsActive(directory), true);
  console.log('Live rule editing: active-session add/move/delete, list updates, metadata guards, async rule/group conflicts, combined group/list limits, subnet preferences and unchanged session files passed');
}
run().catch(error => { console.error(error); process.exitCode = 1; }).finally(() => {
  fs.rmSync(directory, { recursive: true, force: true }); Module._load = originalLoad;
  global.Scroller = oldScroller; global.Edge = oldEdge;
});
