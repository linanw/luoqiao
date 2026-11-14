// Native download capture tests with real private files and a controlled WebDownloadDelegate.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const Module = require('node:module');
const ts = require(path.join(process.env.DEVECO_HOME || '/Applications/DevEco-Studio.app/Contents', 'tools/ohpm/node_modules/typescript'));
const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'harmony-purevpn-download-'));
const config = '[Interface]\nPrivateKey = AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA=\nAddress = 192.0.2.2/32\n' +
  '[Peer]\nPublicKey = ISIjJCUmJygpKissLS4vMDEyMzQ1Njc4OTo7PD0+P0A=\nEndpoint = example.invalid:51820\nAllowedIPs = 0.0.0.0/0\n';
let pauseRead = false;
let resumeRead;
let raceMkdir = false;
class Delegate {
  onBeforeDownload(fn) { this.before = fn; }
  onDownloadUpdated(fn) { this.updated = fn; }
  onDownloadFinish(fn) { this.finished = fn; }
  onDownloadFailed(fn) { this.failed = fn; }
}
const fileIo = {
  accessSync: fs.existsSync, statSync: fs.statSync, unlinkSync: fs.unlinkSync, listFileSync: fs.readdirSync,
  mkdirSync: (file, recursive) => {
    // HarmonyOS reports File exists even when recursion=true; Node silently succeeds.
    if (raceMkdir) { raceMkdir = false; fs.mkdirSync(file, { recursive }); }
    if (fs.existsSync(file)) { const error = new Error('File exists'); error.code = 13900015; throw error; }
    fs.mkdirSync(file, { recursive });
  },
};
const originalLoad = Module._load;
const originalEts = require.extensions['.ets'];
Module._load = function (id, parent, isMain) {
  if (id === '@kit.ArkWeb') return { webview: { WebDownloadDelegate: Delegate } };
  if (id === '@kit.CoreFileKit') return { fileIo };
  if (id === '@kit.ArkTS') return { util: { generateRandomUUID: crypto.randomUUID }, url: { URL: { parseURL: address => new URL(address) } } };
  if (id === './ProfileStore' && parent.filename.endsWith('/PureVpnDownload.ets')) {
    return { MAX_CONFIG_BYTES: 128 * 1024, readConfigDocument: async file => {
      const bytes = fs.readFileSync(file);
      if (bytes.length > 128 * 1024) throw new Error('too large');
      if (pauseRead) await new Promise(resolve => { resumeRead = resolve; });
      return new TextDecoder('utf-8', { fatal: true }).decode(bytes);
    } };
  }
  return originalLoad.call(this, id, parent, isMain);
};
require.extensions['.ets'] = (module, filename) => {
  const compiled = ts.transpileModule(fs.readFileSync(filename, 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }, fileName: filename,
  });
  module._compile(compiled.outputText, filename);
};
const model = require('../entry/src/main/ets/model/PureVpnDownload.ets');
const settle = () => new Promise(resolve => setImmediate(resolve));
function setup() {
  const received = [], errors = [];
  let currentPage = true;
  const capture = model.createPureVpnDownloadDelegate({ cacheDir: directory }, () => currentPage,
    text => {
      assert.equal(fs.readdirSync(path.join(directory, 'purevpn-downloads')).filter(name => name.endsWith('.tmp')).length, 0,
        'plaintext must be removed before callback');
      received.push(text);
    }, message => errors.push(message));
  return { capture, delegate: capture.delegate, received, errors, navigate: () => { currentPage = false; } };
}
function item(options = {}) {
  return Object.assign({
    guid: crypto.randomUUID(), address: 'https://my.purevpn.com/configuration/download', filename: 'wireguard.conf',
    total: -1, received: 0, canceled: 0, path: '',
    getGuid() { return this.guid; }, getUrl() { return this.address; }, getSuggestedFileName() { return this.filename; },
    getTotalBytes() { return this.total; }, getReceivedBytes() { return this.received; },
    getFullPath() { throw new Error('Do not trust provider download paths'); },
    start(file) { this.path = file; fs.writeFileSync(file, ''); },
    cancel() { this.canceled++; if (this.onCancel) this.onCancel(); },
  }, options);
}

(async () => {
  try {
    assert.equal(model.isPureVpnConfigDownload('https://my.purevpn.com/download', 'wg.conf'), true);
    assert.equal(model.isPureVpnConfigDownload('https://cdn.purevpn.com/download', 'WG.CONF'), true);
    assert.equal(model.isPureVpnConfigDownload('blob:https://my.purevpn.com/' + crypto.randomUUID(), 'wg.conf'), true);
    for (const [address, filename] of [
      ['https://my.purevpn.com.evil.invalid/file', 'wg.conf'], ['http://my.purevpn.com/file', 'wg.conf'],
      ['https://user:pass@my.purevpn.com/file', 'wg.conf'], ['https://my.purevpn.com:444/file', 'wg.conf'],
      ['blob:https://evil.invalid/123', 'wg.conf'], ['blob:https://my.purevpn.com/123?token=x', 'wg.conf'],
      ['data:text/plain,hello', 'wg.conf'], ['https://my.purevpn.com/file', '../wg.conf'],
      ['https://my.purevpn.com/file', 'wg.conf.exe'], ['https://my.purevpn.com/file', 'wg\n.conf'],
    ]) assert.equal(model.isPureVpnConfigDownload(address, filename), false);

    const root = path.join(directory, 'purevpn-downloads');
    fs.mkdirSync(root);
    fs.writeFileSync(path.join(root, 'purevpn-config-' + crypto.randomUUID() + '.tmp'), 'stale plaintext');
    fs.writeFileSync(path.join(root, 'user.conf'), 'untouched sentinel');
    let test = setup();
    assert.deepEqual(fs.readdirSync(root), ['user.conf'], 'only own leftover files cleaned');
    let download = item(); test.delegate.before(download);
    assert.ok(download.path.startsWith(root + '/purevpn-config-'));
    fs.writeFileSync(download.path, config);
    test.delegate.finished(download); await settle();
    assert.deepEqual(test.received, [config]); assert.equal(test.errors.length, 0);
    assert.equal(fs.existsSync(download.path), false); test.capture.dispose();

    for (const bad of [item({ filename: 'payment.html' }), item({ address: 'https://evil.invalid/file' }), item({ total: 131073 })]) {
      test = setup(); test.delegate.before(bad);
      assert.equal(bad.canceled, 1); assert.equal(bad.path, ''); assert.equal(test.received.length, 0);
      test.capture.dispose();
    }
    test = setup(); test.navigate(); download = item(); test.delegate.before(download);
    assert.equal(download.canceled, 1); assert.equal(download.path, ''); test.capture.dispose();

    test = setup(); download = item(); test.delegate.before(download);
    fs.writeFileSync(download.path, 'partial'); download.received = 131073;
    download.onCancel = () => test.delegate.failed(download); // Synchronous failure callback must not recurse.
    test.delegate.updated(download);
    assert.equal(download.canceled, 1); assert.equal(fs.existsSync(download.path), false);
    assert.equal(test.received.length, 0); assert.equal(test.errors.length, 1); test.capture.dispose();

    for (const contents of ['', 'not a configuration', config + '#'.repeat(131072), Buffer.from([0xff, 0xfe])]) {
      test = setup(); download = item(); test.delegate.before(download); fs.writeFileSync(download.path, contents);
      test.delegate.finished(download); await settle();
      assert.equal(test.received.length, 0); assert.equal(test.errors.length, 1);
      assert.equal(fs.existsSync(download.path), false); test.capture.dispose();
    }

    test = setup(); download = item(); test.delegate.before(download); fs.writeFileSync(download.path, config);
    download.address = 'https://evil.invalid/redirect'; test.delegate.finished(download); await settle();
    assert.equal(test.received.length, 0); assert.equal(fs.existsSync(download.path), false); test.capture.dispose();

    test = setup(); download = item(); test.delegate.before(download); fs.writeFileSync(download.path, 'partial');
    test.delegate.failed(download);
    assert.equal(fs.existsSync(download.path), false); assert.equal(test.errors.length, 1); test.capture.dispose();

    // A second capture must not delete a first capture's active private file.
    test = setup(); download = item(); test.delegate.before(download); fs.writeFileSync(download.path, config);
    const second = setup(); assert.equal(fs.existsSync(download.path), true); second.capture.dispose();
    test.capture.dispose(); assert.equal(fs.existsSync(download.path), false); assert.equal(test.received.length, 0);
    assert.equal(test.errors.length, 0, 'leaving the page is a silent cancellation');

    for (const dispose of [false, true]) {
      test = setup(); download = item(); test.delegate.before(download); fs.writeFileSync(download.path, config);
      pauseRead = true; test.delegate.finished(download); await settle();
      if (dispose) test.capture.dispose(); else test.navigate();
      pauseRead = false; resumeRead(); await settle();
      assert.equal(test.received.length, 0, 'asynchronous read must not deliver after navigation/disposal');
      assert.equal(fs.existsSync(download.path), false); test.capture.dispose();
    }
    assert.equal(fs.readFileSync(path.join(root, 'user.conf'), 'utf8'), 'untouched sentinel');
    fs.rmSync(root, { recursive: true });
    raceMkdir = true; test = setup(); test.capture.dispose();
    assert.ok(fs.statSync(root).isDirectory(), 'a concurrent directory creation is safe');
    fs.rmSync(root, { recursive: true }); fs.writeFileSync(root, 'not a directory');
    assert.throws(() => setup(), /目录/);
    assert.equal(fs.readFileSync(root, 'utf8'), 'not a directory');
    console.log('PureVPN downloads: official URL/file guards, size limits, parsing, redirect/navigation, cancellation races and private-file cleanup passed');
  } finally {
    Module._load = originalLoad;
    if (originalEts) require.extensions['.ets'] = originalEts; else delete require.extensions['.ets'];
    fs.rmSync(directory, { recursive: true, force: true });
  }
})().catch(error => { console.error(error.message); process.exitCode = 1; });
