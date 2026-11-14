// Execute the shipped page's non-rendering lifecycle against isolated WebView and VPN fakes.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(path.join(process.env.DEVECO_HOME || '/Applications/DevEco-Studio.app/Contents',
  'tools/ohpm/node_modules/typescript'));
let source = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/pages/PureVpnPage.ets'), 'utf8');
source = source.slice(0, source.indexOf('\n  build()')) + '\n}\n';
source = source.replace('@Entry\n@Component\nstruct PureVpnPage', 'export class PureVpnPage').replace(/@State /g, '');
const compiled = ts.transpileModule(source, { compilerOptions: {
  module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020,
}, fileName: 'PureVpnPage.ts' });
const manual = 'https://my.purevpn.com/v2/dashboard/manual-config';
const validResult = (status, selected = 'Malaysia', config = '') => JSON.stringify({
  status, selected, config, locations: ['Malaysia', 'Singapore'],
});
function setup() {
  let now = 1000000;
  let serial = 0;
  const applied = [];
  const saved = [];
  const captures = [];
  const commands = [];
  const renewals = [];
  const control = {
    cookieSaves: 0,
    actualUrl: manual, cachedUrl: 'https://my.purevpn.com/login', result: validResult('locations'),
    getUrl() { return this.cachedUrl; },
    async runJavaScript(script) {
      if (script === 'JSON.stringify(location.href)') { return JSON.stringify(this.actualUrl); }
      commands.push(JSON.parse(script));
      return typeof this.result === 'function' ? this.result() : this.result;
    },
    loadUrl(address) { this.actualUrl = address; }, setDownloadDelegate() {},
  };
  class Profile {
    constructor(profileId, location, importedAt, autoRenew) {
      Object.assign(this, { profileId, location, importedAt, autoRenew, status: 'ready' });
    }
  }
  const isOfficial = (address, manualOnly = false) => {
    try { const parsed = new URL(address); return parsed.protocol === 'https:' &&
      (manualOnly ? parsed.hostname === 'my.purevpn.com' && parsed.pathname === '/v2/dashboard/manual-config' :
        parsed.hostname === 'purevpn.com' || parsed.hostname.endsWith('.purevpn.com')); }
    catch { return false; }
  };
  const dependencies = {
    '@kit.AbilityKit': {}, '@kit.ArkUI': {}, '@kit.BasicServicesKit': {},
    '@kit.ArkTS': { util: { generateRandomUUID: () => 'test-run-' + ++serial } },
    '@kit.NetworkKit': { connection: { getDefaultNet: async () => {
      if (control.networkHook) { await control.networkHook(); }
      return { netId: 1 };
    } } },
    '@kit.ArkWeb': { webview: { WebviewController: class { constructor() { return control; } },
      WebCookieManager: { async saveCookieAsync() {
        control.cookieSaves++;
        if (control.cookieFailure) { throw Error('cookie save rejected'); }
      } } } },
    '@kit.PerformanceAnalysisKit': { hilog: { error() {} } },
    '@kit.CoreFileKit': { fileIo: { accessSync: () => false } },
    '../model/WorkspaceNavigation': { dismissWorkspaceDrawer: () => false },
    '../model/ProfileStore': { listProfiles: () => [] },
    '../model/WireGuardConfig': { parseWireGuardConfig(text) { if (!text) throw Error('empty'); } },
    '../model/TunnelState': { readTunnelState: () => control.tunnelState || control.tunnelRequest,
      readTunnelRequest: () => control.tunnelRequest,
      TunnelPhase: { Starting: 'starting', Waiting: 'waiting', Connected: 'connected', Stopping: 'stopping', Failed: 'failed' } },
    '../model/PureVpnApply': {
      recoverPureVpnApply: async () => {},
      applyPureVpnConfig: async (_context, id, name, text, connect) => {
        const call = { id, name, text, connect, commits: 0, rollbacks: 0 }; applied.push(call);
        return { profileId: id || 'main', session: 'new-session',
          async commit() { call.commits++; if (control.commitFailure) throw Error('commit rejected'); },
          async rollback() { call.rollbacks++; if (control.rollbackFailure) throw Error('rollback rejected'); } };
      },
    },
    '../model/PureVpnProvider': {
      PureVpnProfile: Profile, PureVpnStatus: { Active: 'active', Refreshing: 'refreshing', NeedsUser: 'needs-user', Queued: 'queued' },
      readPureVpnProfile: () => undefined, writePureVpnProfile: (_dir, value) => saved.push(value),
      readPureVpnRecovery: () => control.recovery,
      queuedPureVpnRenewalDecision: (_profile, _observation, input) => {
        renewals.push(input); return { action: control.renewalAction || 'keep' };
      },
      isCombinedVpnSession: (mixed, tailnetIds) => mixed === true || (Array.isArray(tailnetIds) && tailnetIds.length > 0),
      PUREVPN_COMBINED_MESSAGE: '请先在连接列表断开包含 Tailnet 的组合连接，再导入或更新 PureVPN 配置。',
      markPureVpnRefreshStarted: profile => ({ ...profile, status: 'refreshing' }),
      markPureVpnRefreshPaused: profile => ({ ...profile, status: 'queued' }),
      markPureVpnNeedsOfficialInteraction: profile => ({ ...profile, status: 'needs-user', resumeOnOfficialPage: true }),
      markPureVpnRefreshFailure: (profile) => ({ ...profile, status: 'needs-user', resumeOnOfficialPage: false }),
      markPureVpnActivated: (profile, handshake) => ({ ...profile, status: 'active', lastActivatedAt: handshake }),
    },
    '../model/PureVpnWeb': { PUREVPN_MEMBER_URL: manual, isPureVpnPage: isOfficial, parsePureVpnWebResult: JSON.parse },
    '../model/PureVpnDownload': {
      createPureVpnDownloadDelegate(_context, allowed, deliver, fail) {
        const capture = { allowed, deliver, fail, disposed: false, delegate: {}, dispose() { this.disposed = true; } };
        captures.push(capture); return capture;
      },
    },
  };
  class Clock extends Date { static now() { return now; } }
  const sandbox = { exports: {}, require(id) { assert.ok(id in dependencies, id); return dependencies[id]; },
    Date: Clock, setInterval: () => 1, clearInterval() {} };
  vm.runInNewContext(compiled.outputText, sandbox, { timeout: 1000 });
  const page = new sandbox.exports.PureVpnPage();
  Object.assign(page, { attached: true, pageReady: true, visible: true, initialized: true,
    script: '__PUREVPN_COMMAND__', actualAddress: manual, location: 'Malaysia', profileId: 'main' });
  page.getUIContext = () => ({ getHostContext: () => ({ filesDir: '/isolated', cacheDir: '/isolated-cache' }) });
  return { page, control, applied, saved, captures, commands, renewals, advance(ms) { now += ms; } };
}
const tests = [];
const test = (name, run) => tests.push({ name, run });
test('actual SPA address permits the country catalog despite stale native login URL', async () => {
  const { page, commands } = setup();
  await page.execute('inspect');
  assert.match(page.status, /已登录/); assert.equal(page.locations.length, 2);
  assert.equal(commands[0].location, 'Malaysia');
});
test('region change discards an in-flight configuration and retires old download callbacks', async () => {
  const env = setup(); const { page, control, applied, captures } = env;
  page.startWorkflow(); page.generatedInThisRun = true;
  let resolve;
  control.result = () => new Promise(done => { resolve = done; });
  const pending = page.execute('advance');
  while (!resolve) { await Promise.resolve(); }
  const oldCapture = captures[0];
  page.changedLocation('Singapore');
  oldCapture.deliver('OLD-CONFIG');
  resolve(validResult('configuration', 'Malaysia', 'OLD-CONFIG'));
  await pending;
  assert.equal(applied.length, 0); assert.equal(page.hasDownloadedConfig, false);
  assert.equal(page.hasCandidate, false); assert.equal(oldCapture.disposed, true);
});
test('actual country mismatch prevents import even during an armed generation', async () => {
  const { page, control, applied } = setup();
  page.startWorkflow(); page.generatedInThisRun = true;
  control.result = validResult('configuration', 'Singapore', 'NEW-CONFIG');
  await page.execute('advance');
  assert.equal(applied.length, 0); assert.match(page.status, /地区尚未确认一致/);
});
test('matching generated configuration commits the observed country', async () => {
  const { page, control, applied, saved } = setup();
  page.connectNow = false; page.startWorkflow(); page.generatedInThisRun = true;
  control.result = validResult('configuration', 'Malaysia', 'NEW-CONFIG');
  await page.execute('advance');
  assert.equal(applied.length, 1); assert.equal(applied[0].commits, 1);
  assert.equal(saved.at(-1).location, 'Malaysia'); assert.equal(page.armed, false);
  assert.equal(page.verifying, false); assert.equal(page.finishing, false);
});
test('handshake completion clears reactive verification state so generation is available again', async () => {
  const { page, control, applied, advance } = setup();
  await page.importCandidate('NEW-CONFIG', 'Malaysia');
  assert.equal(page.verifying, true); assert.equal(page.busy, false);
  advance(1);
  control.tunnelState = { session: page.transaction.session, phase: 'connected', lastHandshake: page.transactionStarted + 1 };
  await page.tick();
  assert.equal(applied[0].commits, 1); assert.equal(page.transaction, undefined);
  assert.equal(page.verifying, false); assert.equal(page.finishing, false);
  assert.match(page.status, /完成 WireGuard 握手/);
});
test('timeout and failed confirmation both clear reactive verification state', async () => {
  for (const failCommit of [false, true]) {
    const { page, control, applied, advance } = setup();
    await page.importCandidate('NEW-CONFIG', 'Malaysia');
    if (failCommit) {
      advance(1); control.commitFailure = true;
      control.tunnelState = { session: page.transaction.session, phase: 'connected', lastHandshake: page.transactionStarted + 1 };
    } else { advance(90001); }
    await page.tick();
    assert.equal(page.transaction, undefined); assert.equal(page.verifying, false); assert.equal(page.finishing, false);
    if (failCommit) { assert.equal(page.initialized, false); assert.equal(applied[0].commits, 1); }
    else { assert.equal(applied[0].rollbacks, 1); }
  }
});
test('cancel clears reactive verification state even when rollback needs recovery', async () => {
  const { page, control } = setup();
  await page.importCandidate('NEW-CONFIG', 'Malaysia');
  assert.equal(page.verifying, true); control.rollbackFailure = true;
  await page.cancelPending();
  assert.equal(page.transaction, undefined); assert.equal(page.verifying, false); assert.equal(page.finishing, false);
  assert.equal(page.initialized, false); assert.match(page.error, /rollback rejected/);
});
test('human verification suspends timeout and resumes the same run', async () => {
  const { page, control, advance } = setup();
  page.startWorkflow(); const runId = page.runId;
  control.result = validResult('verification', '');
  await page.tick(); advance(600000); await page.tick();
  assert.equal(page.armed, true); assert.equal(page.runId, runId);
  control.result = validResult('locations');
  await page.tick();
  assert.equal(page.armed, true); assert.equal(page.workflowPausedAt, 0);
  advance(120001); await page.tick();
  assert.equal(page.armed, false); assert.match(page.status, /尚未返回新配置/);
});
test('completed generation continues advancing through post-generation download steps', async () => {
  const { page, control, commands } = setup();
  page.startWorkflow(); control.result = validResult('generating');
  await page.tick(); await page.tick();
  assert.equal(page.generatedInThisRun, true);
  assert.deepEqual(commands.map(command => command.action), ['advance', 'advance']);
  assert.ok(commands[0].runId); assert.equal(commands[0].runId, commands[1].runId);
});
test('download arriving during Generate waits for the modal country before import', async () => {
  const { page, control, captures, applied, saved } = setup();
  page.connectNow = false; page.startWorkflow();
  control.result = () => {
    captures.at(-1).deliver('DOWNLOADED-CONFIG');
    return validResult('generating', 'Malaysia');
  };
  await page.execute('advance');
  assert.equal(applied.length, 0);
  assert.equal(page.generatedInThisRun, true); assert.equal(page.hasDownloadedConfig, true);
  control.result = validResult('locations', '');
  await page.execute('advance');
  assert.equal(applied.length, 0, 'a missing modal country must not use a remembered label');
  control.result = validResult('generating', 'Malaysia');
  await page.execute('advance');
  assert.equal(applied.length, 1); assert.equal(applied[0].text, 'DOWNLOADED-CONFIG');
  assert.equal(saved.at(-1).location, 'Malaysia');
});
test('navigating away discards an outstanding page result', async () => {
  const { page, control, applied } = setup();
  page.startWorkflow(); page.generatedInThisRun = true;
  let resolve;
  control.result = () => new Promise(done => { resolve = done; });
  const pending = page.execute('advance');
  while (!resolve) { await Promise.resolve(); }
  page.onPageHide();
  resolve(validResult('configuration', 'Malaysia', 'OLD-CONFIG'));
  await pending;
  assert.equal(applied.length, 0); assert.equal(page.hasCandidate, false); assert.equal(page.armed, false);
});
test('combined groups with one or zero WireGuard profiles permit browsing but block importing and automatic renewal', async () => {
  for (const profileIds of [['main'], []]) {
    const { page, control, applied, commands, renewals } = setup();
    page.metadata = { profileId: 'main', location: 'Malaysia', autoRenew: true };
    control.renewalAction = 'refresh';
    control.tunnelState = { session: 'combined', phase: 'waiting', mixed: true, tailnetIds: ['tailnet-a'],
      profileIds, updated: 1000000, lastHandshake: 0 };
    await page.tick();
    assert.equal(page.combinedActive, true); assert.equal(renewals.length, 0); assert.equal(page.armed, false);
    assert.equal(commands.at(-1).action, 'inspect', 'the member website remains available');
    await page.importCandidate('NEW-CONFIG', 'Malaysia');
    assert.equal(applied.length, 0); assert.match(page.error, /断开.*组合连接/);
  }
});
test('a new combined request during physical network lookup prevents renewal of the stale single profile snapshot', async () => {
  const { page, control, renewals } = setup();
  page.metadata = { profileId: 'main', location: 'Malaysia', autoRenew: true };
  control.renewalAction = 'refresh';
  control.tunnelState = { session: 'single', phase: 'waiting', profileIds: ['main'], updated: 1000000, lastHandshake: 0 };
  control.networkHook = async () => {
    control.tunnelRequest = { session: 'combined', phase: 'starting', mixed: true, tailnetIds: ['tailnet-a'], profileIds: [] };
  };
  await page.tick();
  assert.equal(renewals.length, 0); assert.equal(page.armed, false); assert.equal(page.combinedActive, true);
});
test('a new combined request during webpage validation prevents import before configuration mutation', async () => {
  const { page, control, applied, saved } = setup();
  const originalRun = control.runJavaScript.bind(control);
  control.runJavaScript = async script => {
    const result = await originalRun(script);
    if (script === 'JSON.stringify(location.href)') {
      control.tunnelRequest = { session: 'combined', phase: 'starting', mixed: true, tailnetIds: ['tailnet-a'], profileIds: ['main'] };
    }
    return result;
  };
  await page.importCandidate('NEW-CONFIG', 'Malaysia');
  assert.equal(applied.length, 0); assert.equal(saved.length, 0); assert.match(page.error, /断开.*组合连接/);
});
test('official persistence only flushes ArkWeb storage and failures do not invalidate a healthy connection', async () => {
  const { page, control, saved, advance } = setup();
  page.metadata = { profileId: 'main', location: 'Malaysia', autoRenew: true, status: 'active' };
  await page.execute('inspect');
  assert.equal(control.cookieSaves, 1);
  await page.execute('inspect'); assert.equal(control.cookieSaves, 1, 'polls are throttled');
  advance(30001); control.cookieFailure = true;
  await page.preserveOfficialSession();
  assert.match(page.sessionStatus, /可能需要重新登录/);
  assert.equal(page.metadata.status, 'active'); assert.equal(saved.length, 0);
  page.actualAddress = 'https://unrelated.example/';
  await page.preserveOfficialSession(true); assert.equal(control.cookieSaves, 2);
  assert.doesNotMatch(source, /fetchCookie|configCookie|document\.cookie|putAcceptThirdPartyCookieEnabled/);
});
test('leaving an automatic foreground job preserves a resumable queue without treating it as provider failure', async () => {
  const { page, control, saved } = setup();
  page.metadata = { profileId: 'main', location: 'Malaysia', autoRenew: true, status: 'refreshing', failureCount: 2 };
  page.startWorkflow(); page.onPageHide();
  await Promise.resolve();
  assert.equal(saved.at(-1).status, 'queued'); assert.equal(saved.at(-1).failureCount, 2);
  assert.equal(page.armed, false); assert.equal(control.cookieSaves, 1);
});
test('a queued same-profile startup failure resumes the signed-in generation flow and validates the new handshake', async () => {
  const { page, control, commands, applied, saved, advance } = setup();
  page.metadata = { profileId: 'main', location: 'Malaysia', importedAt: 1, autoRenew: true, status: 'queued' };
  control.tunnelState = { session: 'waiting-session', phase: 'waiting', profileIds: ['main'], updated: 1000000, lastHandshake: 0 };
  control.recovery = { session: 'waiting-session', profileId: 'main', importedAt: 1,
    updatedAt: 1000000, waitingSince: 900000, state: 'queued', reason: 'startup-unresponsive' };
  control.renewalAction = 'refresh'; page.connectNow = false;
  await page.tick();
  assert.equal(page.armed, true); assert.equal(page.automaticRecoverySession, 'waiting-session');
  assert.equal(page.connectNow, true, 'automatic recovery always verifies activation');
  assert.equal(saved.at(-1).status, 'refreshing');
  control.renewalAction = 'keep'; page.pageReady = true;
  control.result = validResult('generating'); await page.tick();
  assert.equal(commands.at(-1).action, 'advance'); assert.equal(page.generatedInThisRun, true);
  control.result = validResult('configuration', 'Malaysia', 'AUTO-CONFIG'); await page.tick();
  assert.equal(applied.length, 1); assert.equal(applied[0].connect, true);
  advance(1);
  control.tunnelState = { session: page.transaction.session, phase: 'connected', lastHandshake: page.transactionStarted + 1 };
  await page.tick();
  assert.equal(applied[0].commits, 1); assert.equal(saved.at(-1).status, 'active');
});
test('login or human verification persists needs-user and never imports a configuration', async () => {
  for (const result of ['login', 'verification', 'session-error']) {
    const { page, control, saved, applied } = setup();
    page.metadata = { profileId: 'main', location: 'Malaysia', autoRenew: true, status: 'refreshing' };
    page.startWorkflow(); control.result = validResult(result, '');
    await page.execute('advance');
    assert.equal(saved.at(-1).status, 'needs-user'); assert.equal(page.officialPageReady, false);
    assert.ok(page.workflowPausedAt > 0); assert.equal(applied.length, 0);
  }
});
test('explicit cancellation of a verification-paused task cannot be undone by later login', async () => {
  const { page, control, saved } = setup();
  page.metadata = { profileId: 'main', location: 'Malaysia', autoRenew: true, status: 'refreshing' };
  page.startWorkflow(); control.result = validResult('verification', '');
  await page.execute('advance');
  assert.equal(page.metadata.resumeOnOfficialPage, true);
  await page.cancelPending();
  assert.equal(saved.at(-1).status, 'needs-user'); assert.equal(saved.at(-1).resumeOnOfficialPage, false);
  assert.equal(page.armed, false);
});
test('a different session or recovered original connection retires automatic generation before import', async () => {
  for (const changed of [{ session: 'new-single-session' }, { phase: 'connected', lastHandshake: 999999 }]) {
    const { page, control, applied, saved } = setup();
    page.metadata = { profileId: 'main', location: 'Malaysia', importedAt: 1, autoRenew: true, status: 'refreshing' };
    page.startWorkflow(); page.automaticRecoverySession = 'old-session'; page.generatedInThisRun = true;
    control.tunnelState = { session: 'old-session', phase: 'waiting', profileIds: ['main'], lastHandshake: 0, ...changed };
    control.recovery = { session: 'old-session', importedAt: 1, state: 'queued', updatedAt: 1000000 };
    await page.importCandidate('AUTO-CONFIG', 'Malaysia');
    assert.equal(applied.length, 0); assert.equal(page.armed, false);
    assert.equal(saved.at(-1).status, 'queued');
  }
});
(async () => {
  let failures = 0;
  for (const { name, run } of tests) {
    try { await run(); } catch (error) { failures++; console.error(name + ': ' + error.message); }
  }
  if (failures) { process.exitCode = 1; }
  else { console.log('PureVPN page: ' + tests.length + ' lifecycle scenarios passed'); }
})();
