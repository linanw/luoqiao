// Synthetic address groups only: parsing, atomic persistence and rule expansion.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const Module = require('node:module');
const ts = require('/Applications/DevEco-Studio.app/Contents/tools/ohpm/node_modules/typescript');
const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'address-groups-'));
const fileIo = {
  OpenMode: { CREATE: 1, WRITE_ONLY: 2, TRUNC: 4 }, accessSync: fs.existsSync,
  readTextSync: p => fs.readFileSync(p, 'utf8'), statSync: fs.statSync, listFileSync: fs.readdirSync,
  openSync: p => ({ fd: fs.openSync(p, 'w') }), writeSync: (fd, data) => fs.writeSync(fd, Buffer.from(data)),
  fsyncSync: fs.fsyncSync, closeSync: f => fs.closeSync(f.fd), renameSync: fs.renameSync, unlinkSync: fs.unlinkSync,
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
const model = require('../entry/src/main/ets/model/AddressGroups.ets');
const split = require('../entry/src/main/ets/model/SplitTunnel.ets');
const networks = require('../entry/src/main/ets/model/NetworkProfiles.ets');
const mixed = require('../entry/src/main/ets/model/MixedConnections.ets');
const { AddressGroup, parseAddressGroupEntries: parse, saveAddressGroup: save,
  readAddressGroups: read, deleteAddressGroup: remove, normalizeAddressGroupCidr: cidr } = model;
const file = path.join(directory, 'address-groups.json');
const document = groups => JSON.stringify({ version: 1, groups });
try {
  const parsed = parse(' Example.COM.，example.com; docs.example、192.0.2.17/24\n192.0.2.0/24；2001:DB8::1/64\t2001:db8::/64 10.0.0.1\n2001:db8:1::42');
  assert.deepEqual(parsed.domains, ['example.com', 'docs.example']);
  assert.deepEqual(parsed.cidrs, ['192.0.2.0/24', '2001:db8::/64', '10.0.0.1/32', '2001:db8:1::42/128']);
  assert.equal(parsed.duplicates, 3);
  assert.deepEqual(parse(' \n，；、\t'), { domains: [], cidrs: [], duplicates: 0 });
  assert.equal(cidr(' FD00:0001:0:0:0:0:0:42/64 '), 'fd00:1::/64');
  for (const bad of ['https://example.com', 'example.com/path', 'example.com:443', '*.example.com',
    '999.999.999.999', '1.2.3.999', '10.0.0.1/33', '10.0.0.1/0', '::/0', 'fd00::/129',
    '[2001:db8::1]', 'fe80::1%wlan0', 'foo..example', 'single-label', 'example.com..']) {
    assert.throws(() => parse('good.example\n' + bad), /第 2 行、第 2 项/);
  }
  assert.throws(() => parse('x'.repeat(model.MAX_ADDRESS_GROUP_INPUT_LENGTH + 1)), /过大/);
  assert.throws(() => parse(Array.from({ length: 1201 }, (_, i) => `host${i}.example`).join('\n')), /1200/);
  assert.throws(() => parse(Array.from({ length: 3001 }, (_, i) => `10.${i >> 8}.${i % 256}.1`).join(';')), /3000/);

  assert.deepEqual(read(directory), []);
  const group = save(directory, new AddressGroup('', '  工作站点  ', ['Example.COM.', 'example.com'], ['192.0.2.44/24', '192.0.2.0/24']));
  assert.equal(model.isAddressGroupId(group.id), true); assert.equal(group.name, '工作站点');
  assert.deepEqual(group.domains, ['example.com']); assert.deepEqual(group.cidrs, ['192.0.2.0/24']);
  const edited = save(directory, new AddressGroup(group.id, 'Home', ['home.example'], ['fd00:1::42/64']));
  assert.equal(read(directory).length, 1); assert.equal(edited.id, group.id);
  const saved = fs.readFileSync(file, 'utf8');
  for (const bad of [new AddressGroup('', '', [], []), new AddressGroup('', 'x'.repeat(65)),
    new AddressGroup('', 'line\nbreak'), new AddressGroup('../bad', 'Escape'),
    new AddressGroup(crypto.randomUUID(), 'Stale editor'), new AddressGroup('', 'Bad IP', [], ['1.2.3.999']),
    new AddressGroup('', 'Wrong family', ['192.0.2.1'], []),
    new AddressGroup('', 'Too many', Array.from({ length: 1201 }, (_, i) => `host${i}.example`)),
    new AddressGroup('', 'Too many IPs', [], Array.from({ length: 3001 }, (_, i) => `10.${i >> 8}.${i % 256}.1`))]) {
    assert.throws(() => save(directory, bad)); assert.equal(fs.readFileSync(file, 'utf8'), saved);
  }
  for (const operation of ['writeSync', 'fsyncSync', 'renameSync']) {
    const original = fileIo[operation];
    fileIo[operation] = operation === 'writeSync' ? () => 1 : () => { throw new Error('simulated storage failure'); };
    try { assert.throws(() => save(directory, new AddressGroup(group.id, 'Replacement', ['new.example']))); }
    finally { fileIo[operation] = original; }
    assert.equal(fs.readFileSync(file, 'utf8'), saved);
    assert.deepEqual(fs.readdirSync(directory), ['address-groups.json']);
  }

  // Malformed stores cannot be silently replaced by a later save or deletion.
  for (const bad of ['{', 'null', '{"version":2,"groups":[]}', '{"version":1}',
    document([new AddressGroup('../escape', 'Bad')]), document([edited, edited]),
    document([{ ...edited, domains: null }]), document([{ ...edited, cidrs: ['::/0'] }])]) {
    fs.writeFileSync(file, bad);
    assert.throws(() => read(directory));
    assert.throws(() => save(directory, new AddressGroup('', 'New')));
    assert.throws(() => remove(directory, group.id));
    assert.equal(fs.readFileSync(file, 'utf8'), bad);
  }
  fs.writeFileSync(file, saved);
  for (const profile of ['main', 'legacy', crypto.randomUUID()]) {
    const rulesPath = path.join(directory, `split-rules-${profile}.json`);
    split.writeProfileRules(directory, profile, new split.ProfileRules(true, false, [], [], [], [group.id]));
    assert.throws(() => remove(directory, group.id), /仍被连接规则使用/);
    assert.equal(read(directory).length, 1); fs.unlinkSync(rulesPath);
  }
  const rulesPath = path.join(directory, 'split-rules-main.json');
  for (const corrupt of ['{', 'null', '[]', '{"groupIds":"bad"}', '{"groupIds":["../bad"]}']) {
    fs.writeFileSync(rulesPath, corrupt); assert.throws(() => remove(directory, group.id));
    assert.equal(fs.readFileSync(file, 'utf8'), saved);
  }
  fs.unlinkSync(rulesPath);
  const originalRename = fileIo.renameSync;
  fileIo.renameSync = () => { throw new Error('delete publication failed'); };
  try { assert.throws(() => remove(directory, group.id)); } finally { fileIo.renameSync = originalRename; }
  assert.equal(fs.readFileSync(file, 'utf8'), saved);

  // Group-only rules count as content and expand into copies, never their editable source.
  const extra = save(directory, new AddressGroup('', 'More', ['home.example', 'other.example'], ['fd00:1::/64', '10.0.0.12']));
  const source = new split.ProfileRules(true, false, ['site'], ['HOME.EXAMPLE.'], ['10.0.0.12/32'], [group.id, extra.id]);
  const before = JSON.stringify(source);
  const expanded = split.expandProfileRules(directory, source);
  assert.deepEqual(expanded.manualDomains, ['home.example', 'other.example']);
  assert.deepEqual(expanded.manualCidrs, ['10.0.0.12/32', 'fd00:1::/64']);
  assert.deepEqual(expanded.groupIds, [group.id, extra.id]); assert.deepEqual(expanded.lists, ['site']);
  expanded.groupIds.pop(); expanded.manualDomains.push('changed.example');
  assert.equal(JSON.stringify(source), before);
  assert.equal(new split.ProfileRules(true, false, [], [], [], [group.id]).hasContent(), true);
  assert.throws(() => split.expandProfileRules(directory, new split.ProfileRules(true, false, [], [], [], [crypto.randomUUID()])), /地址组不存在/);
  fs.writeFileSync(rulesPath, JSON.stringify({ enabled: true, manualDomains: ['old.example'] }));
  assert.deepEqual(split.readProfileRules(directory, 'main').groupIds, []);
  split.writeProfileRules(directory, 'main', source);
  assert.deepEqual(split.readProfileRules(directory, 'main').groupIds, source.groupIds);
  fs.writeFileSync(rulesPath, JSON.stringify({ groupIds: [42] }));
  assert.throws(() => split.readProfileRules(directory, 'main'), /地址组引用无效/);
  fs.unlinkSync(rulesPath);

  const wide = save(directory, new AddressGroup('', 'Large', Array.from({ length: 1200 }, (_, i) => `host${i}.example`)));
  const wideRules = new split.ProfileRules(true, false, [], ['manual.example'], [], [wide.id]);
  assert.throws(() => split.expandProfileRules(directory, wideRules), /1200/);
  assert.equal(split.expandProfileRules(directory, wideRules, 100000, 100000).manualDomains.length, 1201);
  const node = new networks.NetworkProfile(); node.ID = crypto.randomUUID(); node.Name = 'Large Tailnet';
  networks.saveNetworkProfiles(directory, [node]); split.writeProfileRules(directory, node.ID, wideRules);
  assert.equal(mixed.prepareMixedTailnetConfig(directory, [], [node.ID]).Profiles[0].Domains.length, 1201);
  assert.equal(JSON.parse(fs.readFileSync(networks.prepareNetworkConfig(directory, []), 'utf8')).Profiles[0].Domains.length, 1201);

  // Legacy Tailnet identity is reused while its address-group rules are expanded.
  fs.mkdirSync(path.join(directory, 'tailnet', 'tailscale'), { recursive: true });
  split.writeProfileRules(directory, 'legacy', new split.ProfileRules(true, false, [], [], [], [extra.id]));
  const legacy = mixed.prepareMixedTailnetConfig(directory, [], ['legacy']).Profiles[0];
  assert.equal(legacy.ID, 'legacy'); assert.equal(legacy.LegacyState, true);
  assert.deepEqual(legacy.Domains, extra.domains); assert.deepEqual(legacy.CIDRs, extra.cidrs);

  // Old configurations without group references do not depend on the new catalog.
  fs.writeFileSync(file, '{');
  assert.deepEqual(split.expandProfileRules(directory, new split.ProfileRules(true, false, [], ['old.example'])).manualDomains, ['old.example']);
  fs.writeFileSync(file, saved);
  remove(directory, group.id); assert.deepEqual(read(directory), []);
  const many = Array.from({ length: 128 }, (_, i) => new AddressGroup(crypto.randomUUID(), `Group ${i}`));
  fs.writeFileSync(file, document(many));
  assert.throws(() => save(directory, new AddressGroup('', 'Overflow')), /128/);
  assert.equal(read(directory).length, 128);
  save(directory, new AddressGroup(many[0].id, 'Updated at limit'));
  assert.equal(read(directory)[0].name, 'Updated at limit');
  console.log('Address groups: batch validation/normalization, dedupe/limits, atomic failures, corrupt stores, reference-safe delete, copied expansion, legacy compatibility and Tailnet scale passed');
} finally { fs.rmSync(directory, { recursive: true, force: true }); Module._load = originalLoad; }
