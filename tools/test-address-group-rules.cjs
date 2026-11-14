// Validate conflicting proposed edits against real group/rule persistence.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const Module = require('node:module');
const ts = require('/Applications/DevEco-Studio.app/Contents/tools/ohpm/node_modules/typescript');
const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'address-group-rules-'));
const fileIo = {
  OpenMode: { CREATE: 1, WRITE_ONLY: 2, TRUNC: 4 }, accessSync: fs.existsSync,
  statSync: fs.statSync, readTextSync: p => fs.readFileSync(p, 'utf8'),
  mkdirSync: (p, recursive) => fs.mkdirSync(p, { recursive }),
  openSync: p => ({ fd: fs.openSync(p, 'w') }), writeSync: (fd, data) => fs.writeSync(fd, Buffer.from(data)),
  fsyncSync: fs.fsyncSync, closeSync: f => fs.closeSync(f.fd), renameSync: fs.renameSync,
  unlinkSync: fs.unlinkSync, listFileSync: fs.readdirSync,
};
const originalLoad = Module._load;
Module._load = function (id, parent, isMain) {
  if (id === '@kit.CoreFileKit') return { fileIo };
  if (id === '@kit.ArkTS') return { util: { generateRandomUUID: crypto.randomUUID,
    TextEncoder: { create: () => ({ encodeInto: s => new TextEncoder().encode(s) }) } } };
  if (id === '@kit.NetworkKit') return { connection: {} };
  if (id.endsWith('/ProfileStore')) return { listProfiles: () => [], isValidProfileId: () => true };
  return originalLoad.call(this, id, parent, isMain);
};
require.extensions['.ets'] = (module, filename) => {
  const result = ts.transpileModule(fs.readFileSync(filename, 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }, fileName: filename,
  });
  module._compile(result.outputText, filename);
};
try {
  const groups = require('../entry/src/main/ets/model/AddressGroups.ets');
  const split = require('../entry/src/main/ets/model/SplitTunnel.ets');
  const { RuleTarget } = require('../entry/src/main/ets/model/RuleTargets.ets');
  const { CustomRuleOverride, validateCustomRuleAssignments: validate } = require('../entry/src/main/ets/model/CustomRuleConflicts.ets');
  const wg = new RuleTarget(crypto.randomUUID(), 'WG', 'wireguard', true);
  const tn = new RuleTarget(crypto.randomUUID(), 'TN', 'tailnet', true);
  const targets = [wg, tn];
  const group = groups.saveAddressGroup(directory, new groups.AddressGroup('', 'Office',
    ['office.example'], ['192.0.2.99/24', '2001:db8:1::ff/64']));
  const wgRules = new split.ProfileRules(true, false, [], [], [], [group.id]);
  split.writeProfileRules(directory, wg.ID, wgRules);
  split.writeProfileRules(directory, tn.ID, new split.ProfileRules(true));
  validate(directory, targets);

  // A grouped address and a manually entered address may not silently select
  // different connections, including different spellings of the same network.
  for (const rule of [
    new split.ProfileRules(true, false, [], ['OFFICE.EXAMPLE.']),
    new split.ProfileRules(true, false, [], [], ['192.0.2.250/24']),
    new split.ProfileRules(true, false, [], [], ['2001:0db8:0001::123/64']),
  ]) assert.throws(() => validate(directory, targets, [new CustomRuleOverride(tn.ID, rule)]), /同时属于/);
  validate(directory, targets, [new CustomRuleOverride(tn.ID,
    new split.ProfileRules(true, false, [], ['child.office.example'], ['192.0.2.128/25']))]);
  validate(directory, targets, [new CustomRuleOverride(wg.ID,
    new split.ProfileRules(true, false, [], ['office.example'], ['192.0.2.0/24'], [group.id]))]);

  const second = groups.saveAddressGroup(directory, new groups.AddressGroup('', 'Private', ['private.example'], []));
  split.writeProfileRules(directory, tn.ID, new split.ProfileRules(true, false, [], [], [], [second.id]));
  assert.throws(() => validate(directory, targets, [],
    new groups.AddressGroup(group.id, group.name, ['private.example'], [])), /同时属于/);
  assert.equal(groups.readAddressGroups(directory).find(g => g.id === group.id).domains[0], 'office.example');

  // Moving the reference is evaluated as one proposed configuration.
  validate(directory, targets, [new CustomRuleOverride(wg.ID, new split.ProfileRules(true)),
    new CustomRuleOverride(tn.ID, new split.ProfileRules(true, false, [], [], [], [group.id, second.id]))]);

  const many = Array.from({ length: split.MAX_SPLIT_DOMAINS }, (_, i) => `site${i}.example`);
  split.writeDomainListCache(directory, 'large-list', many.join('\n'));
  assert.throws(() => validate(directory, targets, [new CustomRuleOverride(wg.ID,
    new split.ProfileRules(true, false, ['large-list'], [], [], [group.id]))]), /超过.*域名/);
  assert.throws(() => validate(directory, targets, [new CustomRuleOverride(wg.ID,
    new split.ProfileRules(true, false, [], [], [], [crypto.randomUUID()]))]), /地址组不存在/);
  const empty = groups.saveAddressGroup(directory, new groups.AddressGroup('', 'Empty draft'));
  assert.throws(() => validate(directory, targets, [new CustomRuleOverride(wg.ID,
    new split.ProfileRules(true, false, [], [], [], [empty.id]))]), /没有可用规则/);
  assert.throws(() => validate(directory, targets, [],
    new groups.AddressGroup(group.id, group.name)), /没有可用规则/);
  assert.throws(() => validate(directory, targets, [new CustomRuleOverride(wg.ID,
    new split.ProfileRules(true, false, [], ['usable.example'], [], [empty.id]))]), /没有可用规则/);
  console.log('Address group rule conflicts: manual/group, group/group, canonical IPv4/IPv6, transfer, longest match and aggregate limit passed');
} finally {
  Module._load = originalLoad;
  fs.rmSync(directory, { recursive: true, force: true });
}
