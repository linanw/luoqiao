// Portable model tests use synthetic discovery data and isolated files only.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const Module = require('node:module');
const ts = require('/Applications/DevEco-Studio.app/Contents/tools/ohpm/node_modules/typescript');
const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'subnet-preferences-'));
const fileIo = {
  OpenMode: { CREATE: 1, WRITE_ONLY: 2, TRUNC: 4 }, accessSync: fs.existsSync,
  readTextSync: p => fs.readFileSync(p, 'utf8'),
  openSync: p => ({ fd: fs.openSync(p, 'w') }), writeSync: (fd, data) => fs.writeSync(fd, Buffer.from(data)),
  fsyncSync: fs.fsyncSync, closeSync: f => fs.closeSync(f.fd), renameSync: fs.renameSync, unlinkSync: fs.unlinkSync,
};
const originalLoad = Module._load;
Module._load = function (id, parent, isMain) {
  if (id === '@kit.CoreFileKit') { return { fileIo }; }
  if (id === '@kit.ArkTS') { return { util: { generateRandomUUID: crypto.randomUUID,
    TextEncoder: { create: () => ({ encodeInto: s => new TextEncoder().encode(s) }) } } }; }
  return originalLoad.call(this, id, parent, isMain);
};
require.extensions['.ets'] = (module, filename) => {
  const result = ts.transpileModule(fs.readFileSync(filename, 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }, fileName: filename,
  });
  module._compile(result.outputText, filename);
};
const model = require('../entry/src/main/ets/model/SubnetPreferences.ets');
const { SubnetPreference, normalizeSubnetCIDR: normalize, validateSubnetPreferences: validate,
  readSubnetPreferences: read, saveSubnetPreferences: save, collectSubnetSuggestions: discover,
  visibleSubnetSuggestions: visible } = model;
const file = path.join(directory, 'subnet-preferences.json');
const tailnet = crypto.randomUUID();
try {
  assert.equal(normalize(' 192.168.72.60/24 '), '192.168.72.0/24');
  assert.equal(normalize('192.168.72.60'), '192.168.72.60/32');
  assert.equal(normalize('FD00:1234:0000:0000:0000:0000:0000:0042/64'), 'fd00:1234::/64');
  assert.equal(normalize('2001:db8::1'), '2001:db8::1/128');
  for (const input of ['', 'hostname.local', '300.1.1.1/24', '10.0.0.1/33', 'fd00::/129',
    'fd00::%wlan0/64', '0.0.0.0/0', '::/0', '10.1.2.3/0']) {
    assert.throws(() => normalize(input), /有效|默认/);
  }
  assert.throws(() => validate([new SubnetPreference('10.0.1.1/24', 'local'),
    new SubnetPreference('10.0.1.222/24', 'tailnet')]), /已有偏好/);
  assert.throws(() => validate([new SubnetPreference('fd00:1::12/64', 'local'),
    new SubnetPreference('fd00:0001:0::99/64', 'tailnet')]), /已有偏好/);
  assert.throws(() => validate([new SubnetPreference('10.0.0.0/24', 'wireguard')]), /本地网络或 Tailnet/);
  assert.throws(() => validate([new SubnetPreference('10.0.0.0/24', 'tailnet', '../identity')]), /标识/);
  assert.throws(() => validate([new SubnetPreference('10.0.0.0/24', 'local', tailnet)]), /不能同时/);
  assert.throws(() => validate(Array.from({ length: 129 }, (_, i) =>
    new SubnetPreference(`10.0.${i}.0/24`, 'local'))), /128/);
  assert.throws(() => validate(undefined), /128/);
  assert.throws(() => validate([null]), /本地网络或 Tailnet/);

  assert.deepEqual(read(directory), []);
  save(directory, [new SubnetPreference('192.168.72.60/24', 'tailnet', 'legacy'),
    new SubnetPreference('2001:db8::1/64', 'tailnet', tailnet),
    new SubnetPreference('10.0.0.0/8', 'local'), new SubnetPreference('10.2.0.0/16', 'tailnet', '')]);
  const saved = read(directory);
  assert.equal(saved[0].CIDR, '192.168.72.0/24'); assert.equal(saved[0].TailnetID, 'legacy');
  assert.equal(saved[1].CIDR, '2001:db8::/64'); assert.equal(saved[1].TailnetID, tailnet);
  const disk = JSON.parse(fs.readFileSync(file, 'utf8'));
  assert.equal(disk.version, 1);
  assert.equal('TailnetID' in disk.preferences[2], false);
  assert.equal('TailnetID' in disk.preferences[3], false);

  // Validation and failed replacement must leave the last complete document intact.
  const original = fs.readFileSync(file, 'utf8');
  assert.throws(() => save(directory, [new SubnetPreference('bad', 'local')]));
  assert.equal(fs.readFileSync(file, 'utf8'), original);
  for (const operation of ['writeSync', 'fsyncSync', 'renameSync']) {
    const previous = fileIo[operation];
    fileIo[operation] = operation === 'writeSync' ? () => 1 : () => { throw new Error('simulated storage failure'); };
    try { assert.throws(() => save(directory, [])); } finally { fileIo[operation] = previous; }
    assert.equal(fs.readFileSync(file, 'utf8'), original);
    assert.deepEqual(fs.readdirSync(directory), ['subnet-preferences.json']);
  }
  for (const bad of ['{', '{"version":2,"preferences":[]}', '{"version":1}',
    JSON.stringify({ version: 1, preferences: [{ CIDR: '::/0', Priority: 'local' }] }), ' '.repeat(65537)]) {
    fs.writeFileSync(file, bad);
    assert.throws(() => read(directory));
    assert.equal(fs.readFileSync(file, 'utf8'), bad);
  }
  save(directory, []); assert.deepEqual(read(directory), []);

  // Discovery is bounded in the visible list, searchable, IPv6-aware, and never saved implicitly.
  const nodes = [{ ID: 'legacy', SubnetRoutes: ['192.168.72.0/24', '192.168.0.0/16',
    'fd00:1234:1::/80', '0.0.0.0/0', '::/0', 'invalid'] },
    { ID: tailnet, SubnetRoutes: ['192.168.72.99/24', '10.0.0.0/8'] }];
  const suggestions = discover(['192.168.72.60/24', 'fd00:1234:1::44/64', 'bad'], nodes);
  const lan = suggestions.find(s => s.CIDR === '192.168.72.0/24');
  assert.equal(lan.Local, true); assert.equal(lan.OverlapsLocal, true);
  assert.deepEqual(lan.TailnetIDs, ['legacy', tailnet]);
  assert.equal(suggestions.find(s => s.CIDR === '192.168.0.0/16').OverlapsLocal, true);
  assert.equal(suggestions.find(s => s.CIDR === 'fd00:1234:1::/80').OverlapsLocal, true);
  assert.equal(suggestions.find(s => s.CIDR === '10.0.0.0/8').OverlapsLocal, false);
  assert.equal(suggestions.length, 5);
  assert.ok(suggestions[0].Local && suggestions[1].Local);
  const many = discover(['192.168.72.0/24'], [{ ID: tailnet,
    SubnetRoutes: Array.from({ length: 2000 }, (_, i) => `10.${Math.floor(i / 256)}.${i % 256}.0/24`) }]);
  assert.equal(many.length, 2001); assert.equal(visible(many, '').length, 12);
  assert.equal(visible(many, '')[0].CIDR, '192.168.72.0/24');
  assert.deepEqual(visible(many, '10.7.207.0/24').map(s => s.CIDR), ['10.7.207.0/24']);
  assert.equal(visible(suggestions, ' FD00:1234:1::/80 ')[0].CIDR, 'fd00:1234:1::/80');
  assert.deepEqual(discover([], [{ ID: '../bad', SubnetRoutes: ['10.0.0.0/8'] }]), []);
  assert.deepEqual(read(directory), []);
  console.log('Subnet preferences: IPv4/IPv6 normalization, duplicates/targets/limits, atomic storage failures, discovery overlap/search/12-row limit passed');
} finally { fs.rmSync(directory, { recursive: true, force: true }); Module._load = originalLoad; }
