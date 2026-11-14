// Execute the actual address-group handlers with real model persistence and no ArkUI/device.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const Module = require('node:module');
const ts = require('/Applications/DevEco-Studio.app/Contents/tools/ohpm/node_modules/typescript');
const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'address-groups-page-'));
const fileIo = {
  OpenMode: { CREATE: 1, WRITE_ONLY: 2, TRUNC: 4 }, accessSync: fs.existsSync,
  statSync: fs.statSync, readTextSync: p => fs.readFileSync(p, 'utf8'),
  mkdirSync: (p, recursive) => fs.mkdirSync(p, { recursive }),
  openSync: p => ({ fd: fs.openSync(p, 'w') }), writeSync: (fd, data) => fs.writeSync(fd, Buffer.from(data)),
  fsyncSync: fs.fsyncSync, closeSync: f => fs.closeSync(f.fd), renameSync: fs.renameSync,
  unlinkSync: fs.unlinkSync, listFileSync: fs.readdirSync,
};
const wgID = crypto.randomUUID(), tnID = crypto.randomUUID();
const originalLoad = Module._load;
const originalEts = require.extensions['.ets'];
const oldScroller = global.Scroller, oldEdge = global.Edge;
global.Scroller = class { scrollEdge() {} };
global.Edge = { Top: 0 };
Module._load = function (id, parent, isMain) {
  if (id === '@kit.CoreFileKit') return { fileIo };
  if (id === '@kit.ArkTS') return { util: { generateRandomUUID: crypto.randomUUID,
    TextEncoder: { create: () => ({ encodeInto: s => new TextEncoder().encode(s) }) } } };
  if (id === '@kit.NetworkKit') return { connection: {} };
  if (id === '@kit.ArkUI') return { router: { getParams: () => ({}) } };
  if (id.endsWith('/ProfileStore')) return { listProfiles: () => [{ id: wgID, name: 'WG' }],
    isValidProfileId: id => /^(main|legacy|[0-9a-fA-F-]{8,64})$/.test(id) };
  return originalLoad.call(this, id, parent, isMain);
};
require.extensions['.ets'] = (module, filename) => {
  let source = fs.readFileSync(filename, 'utf8');
  if (filename.includes('/pages/')) {
    const name = path.basename(filename, '.ets');
    source = source.slice(0, source.indexOf('\n  @Builder')) + '\n}\nexport default ' + name + ';\n';
    source = source.replace(/@Entry\s+@Component\s+struct (\w+)/, 'class $1').replace(/@State /g, '');
  }
  const result = ts.transpileModule(source, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }, fileName: filename,
  });
  module._compile(result.outputText, filename);
};
try {
  const groups = require('../entry/src/main/ets/model/AddressGroups.ets');
  const split = require('../entry/src/main/ets/model/SplitTunnel.ets');
  const networks = require('../entry/src/main/ets/model/NetworkProfiles.ets');
  const tunnel = require('../entry/src/main/ets/model/TunnelState.ets');
  const Page = require('../entry/src/main/ets/pages/AddressGroupsPage.ets').default;
  const page = new Page();
  page.getUIContext = () => ({ getHostContext: () => ({ filesDir: directory }) });
  const tn = new networks.NetworkProfile(); tn.ID = tnID; tn.Name = 'Tailnet';
  networks.saveNetworkProfiles(directory, [tn]);
  split.writeProfileRules(directory, wgID, new split.ProfileRules(true));
  const session = new tunnel.TunnelState(crypto.randomUUID(), tunnel.TunnelPhase.Starting);
  session.mixed = true; session.profileIds = [wgID]; session.tailnetIds = [tnID];
  tunnel.writeTunnelRequest(directory, session);
  session.phase = tunnel.TunnelPhase.Connected; tunnel.writeTunnelState(directory, session);
  const requestPath = path.join(directory, 'wireguard-tunnel-request.json');
  const statusPath = path.join(directory, 'wireguard-tunnel-state.json');
  const request = fs.readFileSync(requestPath), status = fs.readFileSync(statusPath);
  page.reload(); assert.equal(page.ready, true); assert.equal(page.connected, true);

  // A mixed bulk input is validated as one draft and normalizes all member types.
  page.startAdd(); page.name = '  Work addresses  ';
  page.members = 'Example.COM, 192.0.2.99/24; 2001:0db8:0001::123/64\nexample.com';
  page.inspectDraft(); assert.match(page.preview, /1 个域名、2 个 IP 段/); assert.match(page.preview, /1 个重复/);
  page.save(); assert.equal(page.error, ''); assert.equal(page.formOpen, false);
  let group = groups.readAddressGroups(directory)[0];
  assert.equal(group.name, 'Work addresses'); assert.deepEqual(group.domains, ['example.com']);
  assert.deepEqual(group.cidrs, ['192.0.2.0/24', '2001:db8:1::/64']);
  assert.match(page.notice, /下次连接生效/);

  // Append preserves all previous members, and duplicate IP spellings count once.
  page.startEdit(group, true); page.additions = 'new.example;192.0.2.5/24'; page.save();
  assert.equal(page.error, ''); group = groups.readAddressGroups(directory)[0];
  assert.deepEqual(group.domains, ['example.com', 'new.example']); assert.equal(group.cidrs.length, 2);
  assert.match(page.notice, /1 个重复/);
  page.startEdit(group); page.name = 'Renamed'; page.save();
  group = groups.readAddressGroups(directory)[0];
  assert.equal(group.name, 'Renamed'); assert.equal(group.domains.length, 2); assert.equal(group.cidrs.length, 2);
  page.query = '2001:db8'; assert.equal(page.visibleGroups().length, 1);
  page.query = 'renamed'; assert.equal(page.visibleGroups().length, 1); page.query = '';

  // An invalid token rejects the entire appended batch and leaves the editor intact.
  const groupPath = path.join(directory, 'address-groups.json');
  const beforeInvalid = fs.readFileSync(groupPath);
  page.startEdit(group, true); page.additions = 'would-be-new.example\nhttps://invalid.example/path'; page.save();
  assert.match(page.error, /保存失败/); assert.equal(page.formOpen, true);
  assert.deepEqual(fs.readFileSync(groupPath), beforeInvalid);

  // Edits never overwrite an intervening save from another page/session.
  page.startEdit(group); page.name = 'Stale editor';
  groups.saveAddressGroup(directory, new groups.AddressGroup(group.id, 'Other edit', group.domains, group.cidrs));
  page.save(); assert.match(page.error, /已被更改/);
  group = groups.readAddressGroups(directory)[0]; assert.equal(group.name, 'Other edit');

  // Referenced-group changes use the shared conflict check before publishing anything.
  split.writeProfileRules(directory, wgID, new split.ProfileRules(true, false, [], [], [], [group.id]));
  split.writeProfileRules(directory, tnID, new split.ProfileRules(true, false, [], ['other-connection.example']));
  page.reload(); page.startEdit(group, true); page.additions = 'other-connection.example';
  const beforeConflict = fs.readFileSync(groupPath); page.save();
  assert.match(page.error, /同时属于/); assert.deepEqual(fs.readFileSync(groupPath), beforeConflict);
  assert.equal(page.owners(group.id).length, 1);
  page.requestDelete(group); assert.equal(page.deleteId, ''); assert.match(page.error, /先.*移除/);
  page.remove(group); assert.match(page.error, /仍被/); assert.equal(groups.readAddressGroups(directory).length, 1);

  // Once the reference is removed, the reusable group can be deleted.
  split.writeProfileRules(directory, wgID, new split.ProfileRules(true));
  page.reload(); page.requestDelete(group); assert.equal(page.deleteId, group.id);
  page.remove(group); assert.equal(page.error, ''); assert.equal(groups.readAddressGroups(directory).length, 0);
  page.startAdd(); page.name = 'Empty reusable group'; page.save();
  assert.equal(page.error, ''); assert.equal(groups.readAddressGroups(directory)[0].domains.length, 0);
  assert.deepEqual(fs.readFileSync(requestPath), request, 'editing cannot change the running session request');
  assert.deepEqual(fs.readFileSync(statusPath), status, 'editing cannot change the running session status');
  console.log('Address groups page: bulk normalization, duplicate preview, append preservation, all-or-nothing errors, rename/search, stale edits, conflicts, reference deletion guards and unchanged active session passed');
} finally {
  fs.rmSync(directory, { recursive: true, force: true }); Module._load = originalLoad;
  if (originalEts) require.extensions['.ets'] = originalEts; else delete require.extensions['.ets'];
  global.Scroller = oldScroller; global.Edge = oldEdge;
}
