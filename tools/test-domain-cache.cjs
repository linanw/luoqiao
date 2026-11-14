// Exercise cache visibility with real temporary files and fault-injected HarmonyOS file APIs.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const Module = require('node:module');
const devEco = process.env.DEVECO_HOME || '/Applications/DevEco-Studio.app/Contents';
const ts = require(path.join(devEco, 'tools/ohpm/node_modules/typescript'));
let failDestination = '';
let failCleanup = false;
let shortWrite = false;
const fileIo = {
  OpenMode: { CREATE: 1, WRITE_ONLY: 2, TRUNC: 4 },
  accessSync: fs.existsSync,
  readTextSync: (file) => fs.readFileSync(file, 'utf8'),
  mkdirSync: (file, recursive) => fs.mkdirSync(file, { recursive }),
  openSync: (file) => ({ fd: fs.openSync(file, 'w') }),
  writeSync: (fd, data) => {
    const bytes = typeof data === 'string' ? Buffer.from(data) : Buffer.from(data);
    return fs.writeSync(fd, bytes, 0, shortWrite ? bytes.length - 1 : bytes.length);
  },
  fsyncSync: fs.fsyncSync,
  closeSync: (file) => fs.closeSync(typeof file === 'number' ? file : file.fd),
  renameSync: (source, destination) => {
    if (failDestination && destination.endsWith(failDestination)) { throw new Error('injected rename failure'); }
    fs.renameSync(source, destination);
  },
  unlinkSync: fs.unlinkSync,
  rmdirSync: (file) => {
    if (failCleanup) { throw new Error('injected interrupted cleanup'); }
    fs.rmSync(file, { recursive: true });
  },
  listFileSync: fs.readdirSync,
};
const load = Module._load;
Module._load = function (id, parent, isMain) {
  if (id === '@kit.CoreFileKit') { return { fileIo }; }
  if (id === '@kit.ArkTS') {
    return { util: { generateRandomUUID: crypto.randomUUID,
      TextEncoder: { create: () => ({ encodeInto: (text) => new TextEncoder().encode(text) }) } } };
  }
  if (id === '@kit.NetworkKit') { return { connection: {} }; }
  return load.call(this, id, parent, isMain);
};
require.extensions['.ets'] = (module, filename) => {
  const result = ts.transpileModule(fs.readFileSync(filename, 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }, fileName: filename,
  });
  module._compile(result.outputText, filename);
};
const cache = require('../entry/src/main/ets/model/DomainListCache.ets');
const split = require('../entry/src/main/ets/model/SplitTunnel.ets');
const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'harmony-domain-cache-'));
const root = path.join(directory, 'domain-lists');
const activePath = path.join(root, 'active.json');
const item = (name, content) => new cache.DomainListContent(name, content);
const read = (name) => split.readDomainListCache(directory, name);
try {
  fs.mkdirSync(root);
  fs.writeFileSync(path.join(root, 'a.txt'), 'legacy-a');
  fs.writeFileSync(path.join(root, 'b.txt'), 'legacy-b');
  assert.equal(read('a'), 'legacy-a');
  assert.equal(split.hasDomainListCache(directory, 'b'), true);
  cache.writeCachedDomainLists(directory, [item('a', 'old-a'), item('b', 'old-b')]);
  const previous = fs.readFileSync(activePath, 'utf8');
  const assertUnchanged = () => {
    assert.equal(fs.readFileSync(activePath, 'utf8'), previous);
    assert.equal(read('a'), 'old-a');
    assert.equal(read('b'), 'old-b');
  };

  failDestination = '/b.txt';
  assert.throws(() => cache.writeCachedDomainLists(directory, [item('a', 'new-a'), item('b', 'new-b')]));
  assertUnchanged();
  failDestination = '/active.json';
  assert.throws(() => cache.writeCachedDomainLists(directory, [item('a', 'new-a'), item('b', 'new-b')]));
  assertUnchanged();
  failDestination = '';
  shortWrite = true;
  assert.throws(() => cache.writeCachedDomainLists(directory, [item('a', 'new-a'), item('b', 'new-b')]));
  shortWrite = false;
  assertUnchanged();

  failDestination = '/active.json'; failCleanup = true;
  assert.throws(() => cache.writeCachedDomainLists(directory, [item('a', 'orphan-a'), item('b', 'orphan-b')]));
  assertUnchanged();
  assert.ok(fs.readdirSync(path.join(root, 'batches')).length > 1, 'interrupted batch remains invisible');
  failDestination = ''; failCleanup = false;
  cache.writeCachedDomainLists(directory, [item('a', 'new-a'), item('b', 'new-b')]);
  assert.equal(read('a'), 'new-a'); assert.equal(read('b'), 'new-b');
  assert.equal(fs.readdirSync(path.join(root, 'batches')).length, 2, 'orphan pruned; prior batch retained');

  split.writeDomainListCache(directory, 'a', 'old-page-write');
  assert.equal(read('a'), 'old-page-write'); assert.equal(read('b'), 'new-b');
  fs.writeFileSync(path.join(root, 'unmigrated.txt'), 'legacy-unmigrated');
  assert.equal(read('unmigrated'), 'legacy-unmigrated', 'legacy files still available after manifest migration');

  const currentText = fs.readFileSync(activePath, 'utf8');
  const current = JSON.parse(currentText);
  const a = current.entries.find((entry) => entry.name === 'a');
  fs.unlinkSync(path.join(root, 'batches', a.batch, 'a.txt'));
  assert.equal(read('a'), undefined, 'missing active blob must not fall back to stale legacy file');
  fs.writeFileSync(activePath, '{invalid');
  assert.equal(read('b'), undefined, 'corrupt manifest fails closed');
  assert.throws(() => split.writeDomainListCache(directory, 'b', 'discarded'));
  assert.equal(fs.readFileSync(activePath, 'utf8'), '{invalid');
  fs.writeFileSync(activePath, currentText);
  assert.throws(() => cache.writeCachedDomainLists(directory, [item('../escape', 'invalid')]));
  assert.throws(() => cache.writeCachedDomainLists(directory, [item('b', 'one'), item('b', 'two')]));
  console.log('Domain cache: legacy compatibility, batch visibility, write/rename failure, interrupted batch, single-file writes and fail-closed reads passed');
} finally {
  Module._load = load;
  fs.rmSync(directory, { recursive: true, force: true });
}
