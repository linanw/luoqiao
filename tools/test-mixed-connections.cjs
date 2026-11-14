// Portable mixed-runtime tests use isolated real files and fake native engines.
// They never read or overwrite device profiles or account identities.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const Module = require('node:module');
const ts = require('/Applications/DevEco-Studio.app/Contents/tools/ohpm/node_modules/typescript');
const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'harmony-mixed-'));
const fileIo = {
  OpenMode: { READ_ONLY: 0, CREATE: 1, WRITE_ONLY: 2, TRUNC: 4 }, accessSync: fs.existsSync,
  statSync: fs.statSync, listFileSync: fs.readdirSync, readTextSync: p => fs.readFileSync(p, 'utf8'),
  mkdirSync: (p, recursive) => fs.mkdirSync(p, { recursive }), copyFileSync: fs.copyFileSync,
  rmdirSync: p => fs.rmSync(p, { recursive: true }),
  openSync: (p, mode) => ({ fd: fs.openSync(p, mode & 2 ? 'w' : 'r') }), writeSync: (fd, data) => fs.writeSync(fd, Buffer.from(data)),
  fsyncSync: fs.fsyncSync, closeSync: f => fs.closeSync(f.fd), renameSync: fs.renameSync, unlinkSync: fs.unlinkSync,
};
let configs = new Map(), nativeCalls = [], details = { WireGuard: [], Tailnets: [] };
let propertiesHook, protectHook, createHook, resolveHook, vpnCreates = 0, physicalNetId = 1, dnsUpdates = [], rebindCalls = [], closedSockets = [];
let interfaceName = 'rmnet0', physicalAddress = '10.0.0.1', unregisters = 0;
let extraAddresses = [], physicalRoutes = [], networkUpdates = [], systemConfigs = [];
let routeCheckHook, routeChecks = [];
function routeResult(target) {
  return { Input: target, Host: target, InputKind: 'domain', Decision: { Kind: 'direct', Owner: '', NetworkID: '',
    NetworkName: '', ReasonCode: 'unmatched', Reason: 'normal network', Rule: '', RawIPMayBypassVPN: false,
    SyntheticDNS: false, DeviceIndex: -1 }, Addresses: [], DNS: { Status: 'not_requested', Source: '', Error: '' }, Warnings: [], Error: '' };
}
const networkCallbacks = new Map();
const native = {
  openSocket: () => 55, closeSocket: fd => closedSockets.push(fd), stop: () => {}, updateRoutedDNS: (_, dns) => dnsUpdates.push(JSON.parse(dns)),
  updateRoutedNetwork: (_, json) => { const snapshot = JSON.parse(json); networkUpdates.push(snapshot); dnsUpdates.push(snapshot.DNS); },
  rebindTransport: (handle, sockets, updates) => rebindCalls.push({ handle, sockets: sockets.slice(), updates: updates.slice() }),
  startRouted: (fd, sockets, configs, mtu, json) => {
    nativeCalls.push({ fd, sockets, configs, mtu, routing: JSON.parse(json) }); return 23;
  },
  status: () => ({ running: true, lastHandshake: 0, sentBytes: 10, receivedBytes: 20,
    selectedDNS: 1, selectedFlows: 2, directFlows: 3 }),
  detailStatus: () => JSON.stringify(details),
  checkRoute: async (handle, json) => {
    const request = JSON.parse(json); routeChecks.push({ handle, request });
    if (routeCheckHook) { return await routeCheckHook(handle, request); }
    return JSON.stringify(routeResult(request.Target));
  },
};
const originalLoad = Module._load;
Module._load = function (id, parent, isMain) {
  if (id === '@kit.CoreFileKit') { return { fileIo }; }
  if (id === '@kit.ArkTS') { return { util: { generateRandomUUID: crypto.randomUUID,
    TextEncoder: { create: () => ({ encodeInto: s => new TextEncoder().encode(s) }) } } }; }
  if (id === '@kit.NetworkKit') { return {
    VpnExtensionAbility: class {},
    connection: { NetBearType: { BEARER_WIFI: 1, BEARER_ETHERNET: 3 },
      getNetCapabilities: async () => ({ bearerTypes: [interfaceName === 'wlan0' ? 1 : 0] }),
      getDefaultNet: async () => ({ netId: physicalNetId }), getConnectionProperties: async () => {
      if (propertiesHook) { await propertiesHook(); }
      return { dnses: [{ address: '9.9.9.9' }], interfaceName,
        linkAddresses: [physicalAddress, ...extraAddresses].map(address => ({ address: { address }, prefixLength: address.includes(':') ? 64 : 24 })), routes: physicalRoutes };
    }, getAddressesByName: async () => { if (resolveHook) { await resolveHook(); } return [{ address: '192.0.2.2' }]; },
    createNetConnection: () => ({ register: cb => cb(), on: (event, cb) => networkCallbacks.set(event, cb),
      unregister: cb => { unregisters++; cb(); } }) },
    vpnExtension: { createVpnConnection: () => ({ protect: async () => { if (protectHook) { await protectHook(); } }, create: async config => { systemConfigs.push(config); if (createHook) { await createHook(); } vpnCreates++; return 44; }, destroy: async () => {} }) },
  }; }
  if (id === 'libwireguard.so') { return { default: native }; }
  if (id === '../model/ProfileStore') { return { MAX_PROFILES: 16,
    isValidProfileId: id => /^(main|[0-9a-f-]{8,64})$/.test(id),
    listProfiles: () => Array.from(configs.keys()).map(id => ({ id, name: id })),
    loadProfileText: async (_, id) => configs.get(id) || '',
  }; }
  return originalLoad.call(this, id, parent, isMain);
};
require.extensions['.ets'] = (module, filename) => {
  const result = ts.transpileModule(fs.readFileSync(filename, 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }, fileName: filename,
  });
  module._compile(result.outputText, filename);
};
const model = require('../entry/src/main/ets/model/MixedConnections.ets');
const networks = require('../entry/src/main/ets/model/NetworkProfiles.ets');
const rules = require('../entry/src/main/ets/model/SplitTunnel.ets');
const tunnel = require('../entry/src/main/ets/model/TunnelState.ets');
const subnets = require('../entry/src/main/ets/model/SubnetPreferences.ets');
const checker = require('../entry/src/main/ets/model/RouteChecker.ets');
const groups = require('../entry/src/main/ets/model/AddressGroups.ets');
const Ability = require('../entry/src/main/ets/vpn/WireGuardVpnAbility.ets').default;
const idA = crypto.randomUUID(), idB = crypto.randomUUID();
const config = '[Interface]\nPrivateKey = AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA=\nAddress = 10.0.0.2/32\nDNS = 1.1.1.1\n[Peer]\nPublicKey = ISIjJCUmJygpKissLS4vMDEyMzQ1Njc4OTo7PD0+P0A=\nEndpoint = 192.0.2.2:51820\nAllowedIPs = 0.0.0.0/0\n';
function instance(wg, tn, session = crypto.randomUUID()) {
  const ability = new Ability(); ability.context = { filesDir: directory, applicationInfo: { name: 'test.app' } };
  ability.directory = directory; ability.session = session; ability.profileIds = wg;
  ability.mixed = true; ability.tailnetIds = tn;
  const request = new tunnel.TunnelState(ability.session, tunnel.TunnelPhase.Starting);
  request.mixed = true; request.profileIds = wg; request.tailnetIds = tn;
  tunnel.writeTunnelRequest(directory, request); return ability;
}
async function release(ability) { ability.stopped = true; await ability.release(); }
(async () => {
  try {
    assert.deepEqual(model.readMixedSelection(directory), new model.MixedSelection());
    assert.deepEqual(model.selectedMixedWireGuardIds(directory, [{ id: 'main' }, { id: idA }]), ['main', idA]);
    model.setWireGuardSelected(directory, 'main', false);
    assert.deepEqual(model.selectedMixedWireGuardIds(directory, [{ id: 'main' }, { id: idA }]), [idA]);
    model.setWireGuardSelected(directory, 'main', true);
    assert.throws(() => model.setWireGuardSelected(directory, '../bad', false), /标识/);
    assert.equal(model.readLegacyNetworkProfile(directory), undefined);
    fs.mkdirSync(path.join(directory, 'tailnet', 'tailscale'), { recursive: true });
    const legacy = model.readLegacyNetworkProfile(directory);
    assert.equal(legacy.ID, 'legacy'); assert.equal(legacy.LegacyState, true); assert.equal(legacy.ControlURL, '');
    const a = new networks.NetworkProfile(); Object.assign(a, { ID: idA, Name: 'A', ControlURL: 'https://headscale.example.com', Hostname: 'tablet-a' });
    const b = new networks.NetworkProfile(); Object.assign(b, { ID: idB, Name: 'B', Enabled: false });
    networks.saveNetworkProfiles(directory, [a, b]);
    rules.writeProfileRules(directory, idA, new rules.ProfileRules(true, false, ['github'], ['example.com'], ['10.42.0.0/16']));
    assert.deepEqual(model.selectedMixedTailnetIds(directory), [idA, 'legacy']);
    model.setLegacySelected(directory, false); assert.deepEqual(model.selectedMixedTailnetIds(directory), [idA]);
    const snapshot = model.prepareMixedTailnetConfig(directory, ['9.9.9.9'], [idA, 'legacy']);
    assert.equal(snapshot.Profiles[0].LegacyState, false); assert.equal(snapshot.Profiles[1].LegacyState, true);
    assert.deepEqual(snapshot.Profiles[0].Domains, ['example.com']);
    assert.deepEqual(snapshot.Profiles[0].CIDRs, ['10.42.0.0/16']);
    assert.deepEqual(snapshot.Profiles[0].Lists, ['github']);
    a.ControlURL = 'https://new.example.com'; networks.saveNetworkProfiles(directory, [a, b]);
    rules.writeProfileRules(directory, idA, new rules.ProfileRules(true, false, [], ['changed.example'], []));
    assert.equal(snapshot.Profiles[0].ControlURL, 'https://headscale.example.com');
    assert.deepEqual(snapshot.Profiles[0].Domains, ['example.com']);
    assert.throws(() => model.prepareMixedTailnetConfig(directory, [], [idA, idA]), /重复/);
    assert.throws(() => model.prepareMixedTailnetConfig(directory, [], [crypto.randomUUID()]), /不存在/);
    assert.throws(() => model.prepareMixedTailnetConfig(directory, [], new Array(17).fill('legacy')), /16/);

    // A Tailnet-only group uses the same coordinator without indexing plans[0].
    details = { WireGuard: [], Tailnets: [{ ID: 'legacy', BackendState: 'Running', Error: '', PeerIPs: ['100.64.0.2'],
      PeerNames: ['disk-station', 'disk-station.example.ts.net'], SubnetRoutes: ['192.168.72.0/24'] }], FlowError: 'probe diagnostic' };
    subnets.saveSubnetPreferences(directory, [{ CIDR: '192.168.72.0/24', Priority: 'tailnet', TailnetID: 'legacy' }]);
    let ability = instance([], ['legacy']); await ability.startTunnel();
    assert.deepEqual(nativeCalls.at(-1).routing.SubnetPreferences,
      [{ CIDR: '192.168.72.0/24', Priority: 'tailnet', TailnetID: 'legacy' }]);
    assert.deepEqual(nativeCalls.at(-1).routing.LocalPrefixes, [], 'cellular prefixes are not local LAN');
    assert(systemConfigs.at(-1).routes.some(route => route.destination.address.address === '192.168.72.0' &&
      route.destination.prefixLength === 24), 'requested Tailnet prefix is declared to the VPN');
    subnets.saveSubnetPreferences(directory, [{ CIDR: '192.168.72.0/24', Priority: 'local' }]);
    assert.equal(ability.subnetPreferences[0].Priority, 'tailnet', 'preferences remain a session snapshot');
    assert.equal(nativeCalls.length, 1); assert.deepEqual(nativeCalls[0].configs, []);
    assert.equal(nativeCalls[0].mtu, 1280); assert.equal(nativeCalls[0].routing.Tailnets.Profiles[0].LegacyState, true);
    let state = tunnel.readTunnelState(directory); assert.equal(state.phase, 'connected');
    assert.equal(state.mixed, true); assert.deepEqual(state.tailnetIds, ['legacy']);
    assert.deepEqual(state.tailnetNodes[0].SubnetRoutes, ['192.168.72.0/24']);
    assert.deepEqual(state.tailnetNodes[0].PeerNames, ['disk-station', 'disk-station.example.ts.net']);
    assert.equal(state.flowError, 'probe diagnostic');
    details.FlowError = 'x'.repeat(3000); ability.report();
    assert.equal(tunnel.readTunnelState(directory).flowError.length, 2048);
    delete details.FlowError; ability.report();
    assert.equal(tunnel.readTunnelState(directory).flowError, '');
    await new Promise(resolve => setImmediate(resolve));
    physicalNetId++; await ability.refreshNetworkDNS();
    assert.deepEqual(dnsUpdates, [['9.9.9.9']], 'switching networks with the same resolver still signals Tailnet');
    assert.deepEqual(rebindCalls.at(-1).sockets, []);
    assert.equal(ability.networkChanges, 1);
    await release(ability);

    // All selected engines must be ready; one healthy WG never hides another waiting node.
    const secondConfig = config.replace('PrivateKey = AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA=',
      'PrivateKey = ISIjJCUmJygpKissLS4vMDEyMzQ1Njc4OTo7PD0+P0A=');
    configs = new Map([['main', config], [idB, secondConfig]]);
    rules.writeProfileRules(directory, 'main', new rules.ProfileRules(true, false, [], ['ifconfig.co'], []));
    rules.writeProfileRules(directory, idB, new rules.ProfileRules(true, false, [], ['example.org'], []));
    details = { WireGuard: [{ ID: 'main', Running: true, LastHandshake: 100 }, { ID: idB, Running: true, LastHandshake: 0 }],
      Tailnets: [{ ID: 'legacy', BackendState: 'Running', Error: '' }] };
    ability = instance(['main', idB], ['legacy']); await ability.startTunnel();
    state = tunnel.readTunnelState(directory); assert.equal(state.phase, 'waiting');
    assert.equal(nativeCalls.at(-1).routing.Profiles.length, 2);
    assert.equal(nativeCalls.at(-1).routing.Tailnets.Profiles.length, 1);
    assert.deepEqual(nativeCalls.at(-1).routing.Profiles[0].Domains, ['ifconfig.co']);
    assert.equal(nativeCalls.at(-1).routing.Profiles[0].RoutesFallback, false);
    details.WireGuard[1].LastHandshake = 200; ability.report();
    assert.equal(tunnel.readTunnelState(directory).phase, 'connected');
    await new Promise(resolve => setImmediate(resolve));
    const sessionBefore = ability.session, createsBeforeHandover = vpnCreates;
    physicalNetId++; interfaceName = 'wlan0'; physicalAddress = '192.168.72.61';
    await ability.refreshNetworkDNS();
    assert.deepEqual(networkUpdates.at(-1).LocalPrefixes, ['192.168.72.0/24']);
    ability.report(); assert.deepEqual(tunnel.readTunnelState(directory).localPrefixes, ['192.168.72.0/24']);
    assert.equal(ability.session, sessionBefore); assert.equal(vpnCreates, createsBeforeHandover);
    assert.equal(rebindCalls.at(-1).sockets.length, 2);
    for (const update of rebindCalls.at(-1).updates) {
      assert.match(update, /^public_key=[a-f0-9]{64}\nendpoint=192\.0\.2\.2:51820\n$/);
      assert.doesNotMatch(update, /private_key|preshared_key|allowed_ip|replace_peers/);
    }
    const changesBeforeAddress = ability.networkChanges;
    physicalAddress = '192.168.72.62'; await ability.refreshNetworkDNS();
    assert.deepEqual(networkUpdates.at(-1).LocalPrefixes, ['192.168.72.0/24']);
    assert.equal(ability.networkChanges, changesBeforeAddress + 1, 'same netId with a new link address rebinds');
    const callsBeforeUnchanged = rebindCalls.length;
    await ability.refreshNetworkDNS(); assert.equal(rebindCalls.length, callsBeforeUnchanged);
    extraAddresses = ['2001:db8::2', '2001:db8::3'];
    physicalRoutes = ['10.0.0.0', '192.168.0.0'].map(address => ({
      destination: { address: { address }, prefixLength: 16 }, gateway: { address: '192.168.72.1' }
    }));
    await ability.refreshNetworkDNS(); const orderedCount = rebindCalls.length;
    extraAddresses.reverse(); physicalRoutes.reverse();
    await ability.refreshNetworkDNS(); assert.equal(rebindCalls.length, orderedCount, 'address/route order alone cannot force handover');
    assert(!networkUpdates.at(-1).LocalPrefixes.includes('10.0.0.0/16'), 'gateway routes are not local on-link prefixes');
    extraAddresses = []; physicalRoutes = [];
    interfaceName = 'rmnet0'; physicalAddress = '10.72.1.2'; physicalNetId++;
    await ability.refreshNetworkDNS();
    assert.deepEqual(networkUpdates.at(-1).LocalPrefixes, [], 'returning to cellular clears overlap policies');
    propertiesHook = () => Promise.reject(new Error('offline'));
    await ability.refreshNetworkDNS(); ability.report();
    assert.equal(tunnel.readTunnelState(directory).phase, 'waiting');
    propertiesHook = undefined; await ability.refreshNetworkDNS();
    assert.equal(ability.networkError, '');
    // Cancellation while protecting replacement sockets must close all temporary descriptors.
    let resolveProtect;
    protectHook = () => new Promise(resolve => { resolveProtect = resolve; });
    physicalNetId++; const callsBeforeCancel = rebindCalls.length, closesBeforeCancel = closedSockets.length;
    const changing = ability.refreshNetworkDNS(); await new Promise(resolve => setImmediate(resolve));
    ability.onDestroy(); resolveProtect(); await changing; protectHook = undefined;
    assert.equal(rebindCalls.length, callsBeforeCancel); assert.equal(closedSockets.length, closesBeforeCancel + 1);
    assert.equal(ability.networkEventTimer, -1); assert.ok(unregisters > 0);
    await release(ability);

    // Separate client keys may share a server key, but duplicating a complete
    // WireGuard identity would make the server roam between the two engines.
    configs.set(idB, config);
    ability = instance(['main', idB], ['legacy']); await ability.startTunnel();
    assert.match(tunnel.readTunnelState(directory).message, /相同的客户端和服务端密钥/); await release(ability);
    configs.set(idB, secondConfig);

    // Disabling saved rules restores configuration routes without deleting the
    // rules. The mixed coordinator must agree with the editor's routing switch.
    rules.writeProfileRules(directory, 'main', new rules.ProfileRules(false, false, [], ['ifconfig.co'], []));
    ability = instance(['main'], ['legacy']); await ability.startTunnel();
    assert.equal(nativeCalls.at(-1).routing.Profiles[0].Default, true);
    assert.equal(nativeCalls.at(-1).routing.Profiles[0].RoutesFallback, true);
    assert.deepEqual(nativeCalls.at(-1).routing.Profiles[0].Domains, []);
    assert.deepEqual(rules.readProfileRules(directory, 'main').manualDomains, ['ifconfig.co']); await release(ability);

    // A configuration with a nonzero AllowedIPs prefix is still a fallback;
    // it must not take ownership ahead of discovered Tailnet peer/subnet routes.
    configs.set('main', config.replace('0.0.0.0/0', '10.0.0.0/8'));
    ability = instance(['main'], ['legacy']); await ability.startTunnel();
    const fallbackProfile = nativeCalls.at(-1).routing.Profiles[0];
    assert.equal(fallbackProfile.Default, false); assert.equal(fallbackProfile.RoutesFallback, true);
    assert.deepEqual(fallbackProfile.CIDRs, ['10.0.0.0/8']); await release(ability);

    // The exact same IP prefix explicitly chosen by the user is not fallback.
    rules.writeProfileRules(directory, 'main', new rules.ProfileRules(true, false, [], [], ['10.0.0.0/8']));
    ability = instance(['main'], ['legacy']); await ability.startTunnel();
    assert.equal(nativeCalls.at(-1).routing.Profiles[0].RoutesFallback, false);
    assert.deepEqual(nativeCalls.at(-1).routing.Profiles[0].CIDRs, ['10.0.0.0/8']); await release(ability);
    configs.set('main', config);

    // Two full-tunnel default routes are rejected before any native engine starts.
    rules.writeProfileRules(directory, 'main', new rules.ProfileRules());
    rules.writeProfileRules(directory, idB, new rules.ProfileRules());
    const before = nativeCalls.length; ability = instance(['main', idB], ['legacy']); await ability.startTunnel();
    state = tunnel.readTunnelState(directory); assert.equal(state.phase, 'failed');
    assert.match(state.message, /多个使用默认路由/); assert.equal(nativeCalls.length, before); await release(ability);

    // Cancellation during the physical-network await cannot create a new VPN
    // after the user has already stopped the zero-WG session.
    let resolveProperties;
    propertiesHook = () => new Promise(resolve => { resolveProperties = resolve; });
    ability = instance([], ['legacy']); const createsBefore = vpnCreates;
    const starting = ability.startTunnel();
    await new Promise(resolve => setImmediate(resolve));
    ability.onDestroy(); resolveProperties(); await starting; propertiesHook = undefined;
    assert.equal(vpnCreates, createsBefore); assert.equal(ability.handle, -1);

    // Cancellation while a broken VPN is being destroyed must not leave a retry
    // interval that can restart or retain the old session.
    let resolveDestroy;
    ability = instance([], ['legacy']); ability.created = true;
    ability.vpn = { destroy: () => new Promise(resolve => { resolveDestroy = resolve; }) };
    const recovering = ability.recover(); ability.onDestroy(); resolveDestroy(); await recovering;
    assert.equal(ability.retryTimer, -1); assert.equal(ability.recovering, false);

    // An unresolved probe from the old transport must neither block a new probe
    // after recovery nor clear that new probe's lock when it eventually returns.
    ability = instance([], ['legacy']); await ability.startTunnel();
    await new Promise(resolve => setImmediate(resolve));
    let finishOldProbe, finishNewProbe;
    propertiesHook = () => new Promise(resolve => { finishOldProbe = resolve; });
    physicalNetId++; const oldProbe = ability.refreshNetworkDNS();
    await new Promise(resolve => setImmediate(resolve)); await ability.release();
    propertiesHook = undefined; physicalNetId++; ability.starting = true; await ability.startTunnel();
    await new Promise(resolve => setImmediate(resolve));
    const currentEpoch = ability.transportEpoch, currentNet = ability.physicalNetworkId;
    propertiesHook = () => new Promise(resolve => { finishNewProbe = resolve; });
    const newProbe = ability.refreshNetworkDNS(); await new Promise(resolve => setImmediate(resolve));
    assert.equal(typeof finishNewProbe, 'function', 'old probe cannot block the restarted transport');
    finishOldProbe(); await oldProbe;
    assert.equal(ability.checkingNetworkEpoch, currentEpoch, 'old finally cannot unlock the current probe');
    assert.equal(ability.physicalNetworkId, currentNet, 'old network result cannot replace current diagnostics');
    finishNewProbe(); await newProbe; propertiesHook = undefined; await release(ability);

    // Failed recovery attempts keep retrying transient physical operations, but
    // parsing, rule validation and permanent API failures remain terminal.
    const finishRetry = ability => {
      clearInterval(ability.retryTimer); ability.retryTimer = -1; ability.recovering = false; ability.starting = true;
    };
    propertiesHook = () => Promise.reject(new Error('still offline'));
    ability = instance([], ['legacy']); await ability.startTunnel(true);
    assert.equal(ability.failed, false); assert.equal(ability.recovering, true); assert.ok(ability.retryTimer >= 0);
    finishRetry(ability); await ability.startTunnel(true); assert.equal(ability.retries, 2);
    propertiesHook = undefined; finishRetry(ability); await ability.startTunnel(true);
    assert.ok(ability.handle >= 0); assert.equal(ability.networkError, ''); await release(ability);

    configs.set('main', config.replace('192.0.2.2:51820', 'vpn.example.com:51820'));
    for (const stage of ['resolve', 'protect', 'create']) {
      const failure = () => Promise.reject(new Error('temporary service failure'));
      if (stage === 'resolve') { resolveHook = failure; }
      if (stage === 'protect') { protectHook = failure; }
      if (stage === 'create') { createHook = failure; }
      ability = instance(['main'], ['legacy']); await ability.startTunnel(true);
      assert.equal(ability.failed, false, stage); assert.equal(ability.recovering, true, stage);
      ability.onDestroy(); await release(ability); resolveHook = protectHook = createHook = undefined;
    }
    configs.set('main', 'not a WireGuard configuration');
    ability = instance(['main'], ['legacy']); await ability.startTunnel(true);
    assert.equal(ability.failed, true); assert.equal(ability.retryTimer, -1); await release(ability);
    configs.set('main', config);
    protectHook = () => Promise.reject(Object.assign(new Error('invalid socket'), { code: 2203004 }));
    ability = instance(['main'], ['legacy']); await ability.startTunnel(true);
    assert.equal(ability.failed, true); assert.equal(ability.retryTimer, -1); await release(ability); protectHook = undefined;

    // Live edits must not change either an automatic restart or a recreated
    // extension with the same session. A user-created new session adopts them.
    configs.set('main', config.replace('192.0.2.2:51820', 'vpn.example.com:51820'));
    const wgGroup = groups.saveAddressGroup(directory, new groups.AddressGroup('', 'WireGuard sites',
      ['old-wg-group.example'], ['198.51.100.0/24', '2001:db8:41::/48']));
    const tnGroup = groups.saveAddressGroup(directory, new groups.AddressGroup('', 'Tailnet sites',
      ['old-tn-group.example'], ['10.44.0.0/16', 'fd44::/48']));
    rules.writeProfileRules(directory, 'main', new rules.ProfileRules(true, false, ['snapshot-site'], ['old-manual.example'], ['192.0.2.0/24'], [wgGroup.id]));
    rules.writeDomainListCache(directory, 'snapshot-site', 'old-list.example\nfull:exact.example\n');
    rules.writeProfileRules(directory, idA, new rules.ProfileRules(true, false, ['tail-site'], ['old-tailnet.example'], [], [tnGroup.id]));
    fs.writeFileSync(path.join(directory, 'dlc.dat'), 'old-geosite');
    details = { WireGuard: [{ ID: 'main', Running: true, LastHandshake: 200 }], Tailnets: [{ ID: idA, BackendState: 'Running', Error: '' }] };
    ability = instance(['main'], [idA]); await ability.startTunnel();
    const assertOriginalAddressGroups = routing => {
      assert.deepEqual(routing.Profiles[0].Domains, ['old-list.example', 'old-manual.example', 'old-wg-group.example']);
      assert.deepEqual(routing.Profiles[0].CIDRs, ['192.0.2.0/24', '198.51.100.0/24', '2001:db8:41::/48']);
      assert.deepEqual(routing.Tailnets.Profiles[0].Domains, ['old-tailnet.example', 'old-tn-group.example']);
      assert.deepEqual(routing.Tailnets.Profiles[0].CIDRs, ['10.44.0.0/16', 'fd44::/48']);
      assert.equal(routing.Profiles[0].RoutesFallback, false, 'address groups are explicit selected routes');
    };
    assertOriginalAddressGroups(nativeCalls.at(-1).routing);
    const oldSession = ability.session;
    const oldDatabasePath = nativeCalls.at(-1).routing.Tailnets.DatabasePath;
    rules.writeProfileRules(directory, 'main', new rules.ProfileRules(true, false, ['snapshot-site'], ['new-manual.example'], ['198.51.100.0/24'], [wgGroup.id]));
    rules.writeDomainListCache(directory, 'snapshot-site', 'new-list.example\n');
    rules.writeProfileRules(directory, idA, new rules.ProfileRules(true, false, ['tail-site'], ['new-tailnet.example'], [], [tnGroup.id]));
    groups.saveAddressGroup(directory, new groups.AddressGroup(wgGroup.id, 'New WireGuard sites',
      ['new-wg-group.example'], ['203.0.113.0/24', '2001:db8:42::/48']));
    groups.saveAddressGroup(directory, new groups.AddressGroup(tnGroup.id, 'New Tailnet sites',
      ['new-tn-group.example'], ['10.46.0.0/16', 'fd46::/48']));
    fs.writeFileSync(path.join(directory, 'dlc.dat'), 'new-geosite');
    await ability.release(); ability.starting = true; await ability.startTunnel(true);
    assertOriginalAddressGroups(nativeCalls.at(-1).routing);
    assert.equal(fs.readFileSync(oldDatabasePath, 'utf8'), 'old-geosite');
    ability.onDestroy(); await new Promise(resolve => setImmediate(resolve));
    assert.equal(tunnel.readTunnelRequest(directory).phase, tunnel.TunnelPhase.Starting);
    assert.equal(fs.existsSync(path.join(directory, 'session-rules', oldSession, 'rules.json')), true,
      'system destruction must retain the still-requested session snapshot');
    assert.equal(fs.readFileSync(oldDatabasePath, 'utf8'), 'old-geosite');
    ability = instance(['main'], [idA], oldSession); await ability.startTunnel();
    assertOriginalAddressGroups(nativeCalls.at(-1).routing);
    assert.equal(nativeCalls.at(-1).routing.Tailnets.DatabasePath, oldDatabasePath);
    tunnel.writeTunnelRequest(directory, new tunnel.TunnelState(oldSession, tunnel.TunnelPhase.Disconnected));
    assert.equal(fs.existsSync(path.join(directory, 'session-rules', oldSession)), false,
      'an explicit stop removes only the ended session snapshot');
    ability.onDestroy(); await new Promise(resolve => setImmediate(resolve));
    ability = instance(['main'], [idA]); await ability.startTunnel();
    assert.deepEqual(nativeCalls.at(-1).routing.Profiles[0].Domains, ['new-list.example', 'new-manual.example', 'new-wg-group.example']);
    assert.deepEqual(nativeCalls.at(-1).routing.Profiles[0].CIDRs, ['198.51.100.0/24', '203.0.113.0/24', '2001:db8:42::/48']);
    assert.deepEqual(nativeCalls.at(-1).routing.Tailnets.Profiles[0].Domains, ['new-tailnet.example', 'new-tn-group.example']);
    assert.deepEqual(nativeCalls.at(-1).routing.Tailnets.Profiles[0].CIDRs, ['10.46.0.0/16', 'fd46::/48']);
    assert.equal(fs.readFileSync(nativeCalls.at(-1).routing.Tailnets.DatabasePath, 'utf8'), 'new-geosite');
    await new Promise(resolve => setImmediate(resolve));

    // The coordinator serves only this live session and ignores an old request,
    // a superseded input, an old transport result and any result after stop.
    const firstCheck = checker.requestRouteCheck(directory, 'first.example');
    await ability.serviceRouteCheck();
    assert.equal(checker.readRouteCheckResponse(directory, firstCheck).result.Host, 'first.example');
    const checksBeforeDuplicate = routeChecks.length; await ability.serviceRouteCheck();
    assert.equal(routeChecks.length, checksBeforeDuplicate);
    const invalidSessionRequest = { ...firstCheck, id: crypto.randomUUID(), session: oldSession };
    fs.writeFileSync(path.join(directory, 'route-check-request.json'), JSON.stringify(invalidSessionRequest));
    await ability.serviceRouteCheck(); assert.equal(routeChecks.length, checksBeforeDuplicate);

    let finishCheck;
    routeCheckHook = (_, request) => new Promise(resolve => { finishCheck = () => resolve(JSON.stringify(routeResult(request.Target))); });
    const replaced = checker.requestRouteCheck(directory, 'replaced.example');
    const pendingCheck = ability.serviceRouteCheck(); await new Promise(resolve => setImmediate(resolve));
    const latest = checker.requestRouteCheck(directory, 'latest.example');
    finishCheck(); await pendingCheck;
    assert.equal(checker.readRouteCheckResponse(directory, replaced), undefined);
    assert.equal(checker.readRouteCheckResponse(directory, latest), undefined);
    routeCheckHook = undefined; await ability.serviceRouteCheck();
    assert.equal(checker.readRouteCheckResponse(directory, latest).result.Host, 'latest.example');

    for (const fail of [false, true]) {
      routeCheckHook = (_, request) => new Promise((resolve, reject) => {
        finishCheck = () => fail ? reject(new Error('old network DNS failure')) : resolve(JSON.stringify(routeResult(request.Target)));
      });
      const changingNetwork = checker.requestRouteCheck(directory, fail ? 'old-dns-error.example' : 'old-dns-result.example');
      const oldNetworkCheck = ability.serviceRouteCheck(); await new Promise(resolve => setImmediate(resolve));
      ability.physicalDNSKey += '|network-changed'; finishCheck(); await oldNetworkCheck;
      assert.equal(checker.readRouteCheckResponse(directory, changingNetwork), undefined, 'old physical network result must be retried');
      assert.notEqual(ability.lastRouteCheck, changingNetwork.id);
      routeCheckHook = undefined; await ability.serviceRouteCheck();
      assert.equal(checker.readRouteCheckResponse(directory, changingNetwork).result.Input, changingNetwork.Target);
    }

    // Native DNS/local prefixes are applied before endpoint lookup/protect finishes.
    // The committed key still looks old in this window, so revision + busy guards
    // must suppress both dispatch and late completion until handover has settled.
    for (const stage of ['resolve', 'protect']) {
      routeCheckHook = (_, request) => new Promise((resolve, reject) => {
        finishCheck = () => stage === 'protect' ? reject(new Error('pre-handover DNS failure')) :
          resolve(JSON.stringify(routeResult(request.Target)));
      });
      const pendingNetwork = checker.requestRouteCheck(directory, stage + '-handover.example');
      const earlierCheck = ability.serviceRouteCheck(); await new Promise(resolve => setImmediate(resolve));
      let finishHandover;
      const waitHandover = () => new Promise(resolve => { finishHandover = resolve; });
      if (stage === 'resolve') { resolveHook = waitHandover; } else { protectHook = waitHandover; }
      const priorKey = ability.physicalDNSKey, priorRevision = ability.networkRevision, beforeUpdate = networkUpdates.length;
      physicalNetId++;
      const handover = ability.refreshNetworkDNS(); await new Promise(resolve => setImmediate(resolve));
      assert.equal(typeof finishHandover, 'function', 'test must pause in endpoint/protect after native update');
      assert.equal(networkUpdates.length, beforeUpdate + 1);
      assert.ok(ability.networkRevision > priorRevision);
      assert.equal(ability.physicalDNSKey, priorKey, 'transport has not committed its new network key');
      assert.equal(ability.checkingNetworkEpoch, ability.transportEpoch);
      finishCheck(); await earlierCheck;
      assert.equal(checker.readRouteCheckResponse(directory, pendingNetwork), undefined);
      const beforeBlockedDispatch = routeChecks.length;
      await ability.serviceRouteCheck(); assert.equal(routeChecks.length, beforeBlockedDispatch);
      resolveHook = protectHook = undefined; finishHandover(); await handover;
      routeCheckHook = undefined; await ability.serviceRouteCheck();
      assert.equal(checker.readRouteCheckResponse(directory, pendingNetwork).result.Input, pendingNetwork.Target);
    }

    // An observed network event invalidates an in-flight answer even when the
    // ensuing probe has completed and reports exactly the same addresses/DNS.
    routeCheckHook = (_, request) => new Promise(resolve => { finishCheck = () => resolve(JSON.stringify(routeResult(request.Target))); });
    const eventCheck = checker.requestRouteCheck(directory, 'network-event.example');
    const eventResult = ability.serviceRouteCheck(); await new Promise(resolve => setImmediate(resolve));
    const sameKey = ability.physicalDNSKey, eventRevision = ability.networkRevision;
    ability.scheduleNetworkRefresh();
    assert.ok(ability.networkRevision > eventRevision); assert.equal(ability.networkEventPending, true);
    const eventDispatches = routeChecks.length; await ability.serviceRouteCheck();
    assert.equal(routeChecks.length, eventDispatches);
    clearTimeout(ability.networkEventTimer); ability.networkEventTimer = -1;
    await ability.refreshNetworkDNS();
    assert.equal(ability.physicalDNSKey, sameKey); assert.equal(ability.networkEventPending, false);
    assert.equal(ability.checkingNetworkEpoch, -1);
    finishCheck(); await eventResult;
    assert.equal(checker.readRouteCheckResponse(directory, eventCheck), undefined);
    routeCheckHook = undefined; await ability.serviceRouteCheck();
    assert.equal(checker.readRouteCheckResponse(directory, eventCheck).result.Input, eventCheck.Target);

    routeCheckHook = async (_, request) => {
      const value = routeResult(request.Target);
      value.Decision.Kind = 'wireguard'; value.Decision.NetworkID = 'index:0'; value.Decision.DeviceIndex = 0;
      value.Addresses = [{ IP: '192.0.2.2', Decision: { ...value.Decision } }]; return JSON.stringify(value);
    };
    const indexed = checker.requestRouteCheck(directory, 'indexed.example'); await ability.serviceRouteCheck();
    const mapped = checker.readRouteCheckResponse(directory, indexed).result;
    assert.equal(mapped.Decision.NetworkID, 'main'); assert.equal(mapped.Decision.Owner, 'wg:main');
    assert.equal(mapped.Addresses[0].Decision.NetworkID, 'main');

    for (const nativeFailure of [false, true]) {
      routeCheckHook = nativeFailure ? async () => { throw new Error('simulated native error'); } : undefined;
      const storedCheck = checker.requestRouteCheck(directory, 'storage-retry.example');
      const previousResponse = fs.readFileSync(path.join(directory, 'route-check-response.json'));
      const originalRename = fileIo.renameSync;
      fileIo.renameSync = (source, destination) => {
        if (destination.endsWith('/route-check-response.json')) { throw new Error('simulated response storage failure'); }
        return originalRename(source, destination);
      };
      try { await ability.serviceRouteCheck(); } finally { fileIo.renameSync = originalRename; }
      assert.notEqual(ability.lastRouteCheck, storedCheck.id, 'failed response storage stays retryable');
      assert.equal(ability.routeCheckBusy, false);
      assert.deepEqual(fs.readFileSync(path.join(directory, 'route-check-response.json')), previousResponse);
      routeCheckHook = undefined; await ability.serviceRouteCheck();
      assert.equal(checker.readRouteCheckResponse(directory, storedCheck).result.Input, storedCheck.Target);
    }

    routeCheckHook = (_, request) => new Promise(resolve => { finishCheck = () => resolve(JSON.stringify(routeResult(request.Target))); });
    const priorTransport = checker.requestRouteCheck(directory, 'old-transport.example');
    const priorResult = ability.serviceRouteCheck(); await new Promise(resolve => setImmediate(resolve));
    await ability.release(); finishCheck(); await priorResult;
    assert.equal(checker.readRouteCheckResponse(directory, priorTransport), undefined);
    routeCheckHook = undefined; ability.starting = true; await ability.startTunnel(true);
    await new Promise(resolve => setImmediate(resolve));
    await ability.serviceRouteCheck();
    assert.equal(checker.readRouteCheckResponse(directory, priorTransport).result.Host, 'old-transport.example');

    routeCheckHook = (_, request) => new Promise(resolve => { finishCheck = () => resolve(JSON.stringify(routeResult(request.Target))); });
    const afterStop = checker.requestRouteCheck(directory, 'stopped.example');
    const stoppedResult = ability.serviceRouteCheck(); await new Promise(resolve => setImmediate(resolve));
    ability.onDestroy(); finishCheck(); await stoppedResult; routeCheckHook = undefined;
    assert.throws(() => checker.readRouteCheckResponse(directory, afterStop), /停止或变更/);
    const responseOnDisk = JSON.parse(fs.readFileSync(path.join(directory, 'route-check-response.json'), 'utf8'));
    assert.notEqual(responseOnDisk.id, afterStop.id); await release(ability);

    // The sole former Headscale identity keeps its encoded namespace, not tailscale's.
    fs.rmSync(path.join(directory, 'tailnet'), { recursive: true });
    const control = 'https://headscale.example.com';
    fs.mkdirSync(path.join(directory, 'tailnet', encodeURIComponent(control)), { recursive: true });
    assert.equal(model.readLegacyNetworkProfile(directory).ControlURL, control);
    fs.mkdirSync(path.join(directory, 'tailnet', encodeURIComponent('https://other.example.com')));
    assert.equal(model.readLegacyNetworkProfile(directory), undefined);
    console.log('Mixed connections: selection/identity, persistent rule snapshots, recovery/new sessions, network handover, route-check request/late/stop guards, readiness and route conflicts passed');
  } finally { fs.rmSync(directory, { recursive: true, force: true }); Module._load = originalLoad; }
})().catch(error => { console.error(error); process.exitCode = 1; });
