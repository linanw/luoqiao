// Exercise the shipped page adapter against public DOM shapes observed on the official member page.
// This fixture contains no account data and performs no network requests.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const Module = require('node:module');
const devEco = process.env.DEVECO_HOME || '/Applications/DevEco-Studio.app/Contents';
const ts = require(path.join(devEco, 'tools/ohpm/node_modules/typescript'));
const source = fs.readFileSync(path.join(__dirname, '../entry/src/main/resources/rawfile/purevpn-assistant.js'), 'utf8');
const manualPath = '/v2/dashboard/manual-config';
const config = '[Interface]\nPrivateKey = TEST-FIXTURE-NOT-A-KEY\nAddress = 192.0.2.2/32\n[Peer]\nPublicKey = TEST-PEER\nEndpoint = example.invalid:51820';
let passed = 0;
const failures = [];
function check(name, fn) {
  try { fn(); passed++; }
  catch (error) { failures.push(name + ': ' + error.stack); }
}
function confidential(object, name) {
  Object.defineProperty(object, name, { get() { throw new Error('Forbidden access to ' + name); } });
  return object;
}
// A deliberately small DOM: unsupported selectors fail so new page capabilities get reviewed.
function splitSelector(selector, delimiter) {
  const parts = []; let start = 0; let quoted = ''; let depth = 0;
  for (let index = 0; index < selector.length; index++) {
    const character = selector[index];
    if (quoted) { if (character === quoted) quoted = ''; continue; }
    if (character === '"' || character === "'") { quoted = character; continue; }
    if (character === '[' || character === '(') { depth++; continue; }
    if (character === ']' || character === ')') { depth--; continue; }
    if (!depth && delimiter(character)) {
      if (selector.slice(start, index).trim()) parts.push(selector.slice(start, index).trim());
      start = index + 1;
    }
  }
  if (selector.slice(start).trim()) parts.push(selector.slice(start).trim());
  return parts;
}
function matchesSimple(item, selector) {
  let rest = selector;
  const tag = rest.match(/^(\*|[a-z][\w-]*)/i);
  if (tag) {
    if (tag[1] !== '*' && item.tagName !== tag[1].toUpperCase()) return false;
    rest = rest.slice(tag[0].length);
  }
  while (rest) {
    let match;
    if ((match = rest.match(/^\.([\w-]+)/))) {
      if (!item.className.split(/\s+/).includes(match[1])) return false;
    } else if ((match = rest.match(/^#([\w-]+)/))) {
      if (item.id !== match[1]) return false;
    } else if ((match = rest.match(/^\[([\w-]+)(?:([*^$~]?=)(?:"([^"]*)"|'([^']*)'|([^\]\s]+))\s*(i)?)?\]/))) {
      const actual = item.getAttribute(match[1]);
      if (actual === null) return false;
      if (match[2]) {
        let expected = match[3] ?? match[4] ?? match[5]; let value = String(actual);
        if (match[6]) { expected = expected.toLowerCase(); value = value.toLowerCase(); }
        const operation = match[2];
        if (operation === '=' && value !== expected || operation === '*=' && !value.includes(expected) ||
          operation === '^=' && !value.startsWith(expected) || operation === '$=' && !value.endsWith(expected) ||
          operation === '~=' && !value.split(/\s+/).includes(expected)) return false;
      }
    } else if ((match = rest.match(/^:not\(([^()]*)\)/))) {
      if (matchesSimple(item, match[1])) return false;
    } else {
      throw new Error('Unexpected selector; review adapter capability: ' + selector);
    }
    rest = rest.slice(match[0].length);
  }
  return true;
}
function matches(item, selector) {
  return splitSelector(selector, character => character === ',').some(group => {
    const chain = splitSelector(group, character => /\s/.test(character));
    if (!matchesSimple(item, chain.pop())) return false;
    let ancestor = item.parentElement;
    while (chain.length) {
      const wanted = chain.pop();
      while (ancestor && !matchesSimple(ancestor, wanted)) ancestor = ancestor.parentElement;
      if (!ancestor) return false;
      ancestor = ancestor.parentElement;
    }
    return true;
  });
}
function element(tag, text = '', extra = {}, children = []) {
  const item = Object.assign({
    tagName: tag.toUpperCase(), _text: text, className: '', id: '', name: '', type: '', value: '',
    disabled: false, hidden: false, clicked: 0, scrolls: 0, events: [], attributes: {}, children: [], parentElement: null,
    append(...nodes) { for (const node of nodes) { node.parentElement = this; this.children.push(node); } },
    getClientRects() { return this.hidden || this.parentElement && !this.parentElement.getClientRects().length ? [] : [{ width: 100, height: 20 }]; },
    getAttribute(name) {
      if (name === 'class') return this.className || null;
      if (['id', 'name', 'type', 'value'].includes(name)) return this[name] || null;
      return this.attributes[name] ?? null;
    },
    click() { this.clicked++; if (this.onClick) this.onClick(); },
    scrollIntoView() { this.scrolls++; },
    dispatchEvent(event) { this.events.push(event.type); if (this.onEvent) this.onEvent(event); return true; },
    querySelectorAll(selector) {
      const descendants = [];
      const walk = node => { for (const child of node.children) { descendants.push(child); walk(child); } };
      walk(this);
      return descendants.filter(node => matches(node, selector));
    },
    querySelector(selector) { return this.querySelectorAll(selector)[0] || null; },
    closest(selector) { for (let node = this; node; node = node.parentElement) if (matches(node, selector)) return node; return null; },
    matches(selector) { return matches(this, selector); },
    contains(other) { for (let node = other; node; node = node.parentElement) if (node === this) return true; return false; },
  }, extra);
  Object.defineProperty(item, 'textContent', { get() { return this._text + this.children.map(child => child.textContent).join(''); }, set(value) { this._text = value; this.children = []; } });
  Object.defineProperty(item, 'innerText', { get() { return this.textContent; } });
  Object.defineProperty(item, 'text', { get() { return this.textContent; } });
  Object.defineProperty(item, 'options', { get() { return this.children.filter(child => child.tagName === 'OPTION'); } });
  Object.defineProperty(item, 'selectedOptions', { get() { return this.options.filter(option => option.value === this.value); } });
  Object.defineProperty(item, 'selectedIndex', { get() { return this.options.findIndex(option => option.value === this.value); }, set(index) { this.value = this.options[index]?.value || ''; } });
  item.append(...children);
  return item;
}
function fixture(options = {}) {
  const body = element('body', options.text || '', {}, options.nodes || []);
  const queries = [];
  const document = {
    body,
    querySelectorAll(selector) { queries.push(selector); return body.querySelectorAll(selector); },
    querySelector(selector) { return this.querySelectorAll(selector)[0] || null; },
  };
  confidential(document, 'cookie');
  const sandbox = {
    location: { origin: options.origin || 'https://my.purevpn.com', pathname: options.pathname || manualPath },
    document,
    getComputedStyle: item => ({ visibility: item.hidden ? 'hidden' : 'visible' }),
    Event: class Event { constructor(type, init) { this.type = type; this.bubbles = !!init?.bubbles; } },
    fetch() { throw new Error('Adapter must not perform network requests'); },
  };
  sandbox.window = sandbox;
  confidential(sandbox, 'localStorage'); confidential(sandbox, 'sessionStorage'); confidential(sandbox, 'XMLHttpRequest');
  const context = vm.createContext(sandbox);
  return {
    body, queries,
    run(command = { action: 'inspect', location: '', runId: '' }) {
      const script = source.replace('__PUREVPN_COMMAND__', () => JSON.stringify(command));
      return JSON.parse(vm.runInContext(script, context, { timeout: 1000 }));
    },
  };
}
function challenge() {
  return confidential(confidential(element('iframe', '', {
    src: 'https://challenges.cloudflare.com/turnstile/widget', title: 'Security challenge',
  }), 'contentWindow'), 'contentDocument');
}
function country(label) {
  const heading = element('h3', label);
  const click = element('div', '', { className: 'clickCountry' }, [heading, element('span', '1 Location | OBFQR')]);
  const expand = element('button', '', { className: 'countryButton' });
  const download = element('button', '下载', { hidden: true });
  const root = element('div', '', { className: 'subscription-head country' }, [
    element('div', '', { className: 'countryData' }, [element('div', '', { className: 'content' }, [click]), expand]),
    element('div', '', { className: 'countryDownload' }, [download]),
  ]);
  // Verified on the member page: the heading's div is not the expansion action.
  expand.onClick = () => { download.hidden = false; };
  return { root, heading, click, expand, download };
}
function modal(label = 'Malaysia', options = {}) {
  const protocol = element('select', '', { name: 'select', value: options.protocol || 'UDP' },
    ['WireGuard', 'TCP', 'UDP', 'IKEV', 'IPSEC'].map((label, index) => element('option', label, { value: ['wireguard', 'tcp', 'udp', 'ikev', 'ipsec'][index] })));
  // Match the option's actual value, which is deliberately not its display text.
  protocol.value = options.protocol || 'udp';
  const device = element('select', '', { id: 'device', value: options.device || '' }, [element('option', 'Select Device', { value: '' }),
    ...['Android', 'Android TV', 'DD-WRT', 'iOS', 'Kodi', 'Linux', 'Mac', 'Tomato', 'Windows'].map(label => element('option', label, { value: label.toLowerCase().replace(/ /g, '-') }))]);
  const generate = element('button', 'Generate Configuration');
  const buy = element('button', 'Buy WireGuard Add-on');
  const body = element('div', '', { className: 'mod-body' }, [
    element('div', '', { className: 'country' }, [element('h3', label)]), protocol,
  ]);
  // Verified on device: the device selector and Generate action are outside .mod-body.
  const footer = element('footer', '', {}, [device, generate, buy]);
  const root = element('section', '', {}, [body, footer]);
  return { root, body, footer, protocol, device, generate, buy };
}
function resultPanel(label, children = []) {
  // The generated result replaces the selection modal rather than its selection body.
  return element('section', '', {}, [element('p', 'Location: ' + label), ...children]);
}


check('foreign origins cannot inspect or interact', () => {
  for (const origin of ['http://my.purevpn.com', 'https://my.purevpn.com.evil.invalid', 'https://evil.invalid', 'https://purevpn.com']) {
    const page = modal();
    const test = fixture({ origin, nodes: [page.root, element('pre', config)] });
    assert.equal(test.run({ action: 'advance', location: 'Malaysia', runId: 'one' }).status, 'outside');
    assert.equal(test.queries.length, 0); assert.equal(page.generate.clicked, 0);
  }
});
check('non-manual paths cannot expose configs or invoke generation', () => {
  for (const pathname of ['/v2/dashboard', '/login', manualPath + '/other']) {
    const page = modal();
    const test = fixture({ pathname, nodes: [page.root, element('pre', config)] });
    const result = test.run({ action: 'advance', location: 'Malaysia', runId: 'one' });
    assert.notEqual(result.status, 'configuration'); assert.equal(result.config, ''); assert.equal(page.generate.clicked, 0);
  }
});
check('login is handed to the user without reading password values', () => {
  const password = confidential(element('input', '', { type: 'password' }), 'value');
  const page = modal();
  const test = fixture({ nodes: [password, page.root, element('pre', config)] });
  assert.equal(test.run({ action: 'advance', location: 'Malaysia', runId: 'one' }).status, 'login');
  assert.equal(page.generate.clicked, 0);
});
check('visible verification never invokes page actions or reads frame tokens', () => {
  for (const settings of [{ nodes: [challenge()] }, { text: 'Verify that you are human' }]) {
    const page = modal();
    const test = fixture({ ...settings, nodes: [...(settings.nodes || []), page.root] });
    assert.equal(test.run({ action: 'advance', location: 'Malaysia', runId: 'one' }).status, 'verification');
    assert.equal(page.generate.clicked, 0); assert.equal(page.buy.clicked, 0);
    assert.equal(page.protocol.value, 'udp'); assert.equal(page.device.value, '');
  }
});
check('a generated configuration remains readable with a persistent completed widget', () => {
  const page = modal();
  page.root.append(element('textarea', '', { value: config }));
  const test = fixture({ nodes: [page.root, challenge()] });
  const result = test.run();
  assert.equal(result.status, 'configuration'); assert.equal(result.config, config); assert.equal(result.selected, 'Malaysia');
  assert.equal(page.generate.clicked, 0);
});
check('distinct configurations fail closed while duplicate representations deduplicate', () => {
  const page = modal();
  page.root.append(element('pre', config), element('code', config + '\n# other'));
  const ambiguous = fixture({ nodes: [page.root] });
  const result = ambiguous.run({ action: 'advance', location: 'Malaysia', runId: 'one' });
  assert.equal(result.status, 'ambiguous'); assert.equal(result.config, ''); assert.equal(page.generate.clicked, 0);
  const duplicated = fixture({ nodes: [element('pre', config), element('textarea', '', { value: config })] });
  assert.equal(duplicated.run().status, 'configuration');
});
check('hidden, incomplete, and oversized configuration text is not extracted', () => {
  const test = fixture({ nodes: [element('pre', config, { hidden: true }), element('pre', '[Interface]\nhello'),
    element('pre', config + '\n#' + 'x'.repeat(131072))] });
  assert.equal(test.run().config, '');
});
check('session errors cannot invoke generation', () => {
  const page = modal();
  assert.equal(fixture({ text: 'User Agent Exception', nodes: [page.root] })
    .run({ action: 'advance', location: 'Malaysia', runId: 'one' }).status, 'session-error');
  assert.equal(page.generate.clicked, 0);
});

check('country catalog comes from country cards and never the sorting selector', () => {
  const malaysia = country('Malaysia'); const singapore = country('Singapore');
  const sorting = element('select', '', { value: 'name' }, [element('option', 'Popularity', { value: 'popular' }), element('option', 'Name', { value: 'name' })]);
  const test = fixture({ nodes: [sorting, malaysia.root, singapore.root, country('Hidden country').root] });
  test.body.children[3].hidden = true;
  const result = test.run();
  assert.equal(result.status, 'locations'); assert.deepEqual(result.locations, ['Malaysia', 'Singapore']);
  assert.equal(result.selected, ''); assert.equal(malaysia.click.clicked, 0); assert.equal(singapore.click.clicked, 0);
  assert.equal(malaysia.expand.clicked, 0); assert.equal(singapore.expand.clicked, 0);
  assert.equal(sorting.value, 'name'); assert.deepEqual(sorting.events, []);
});
check('exact country flow opens only its download, selects WireGuard and Linux, then generates once', () => {
  const malaysia = country('Malaysia'); const singapore = country('Singapore'); const page = modal();
  const buy = element('button', '立即升级');
  page.root.hidden = true;
  malaysia.download.onClick = () => { page.root.hidden = false; };
  const test = fixture({ nodes: [buy, malaysia.root, singapore.root, page.root] });
  const command = { action: 'advance', location: 'Malaysia', runId: 'country-flow' };
  assert.equal(test.run({ ...command, action: 'select' }).status, 'choosing');
  assert.equal(malaysia.expand.clicked, 1); assert.equal(malaysia.click.clicked, 0); assert.equal(malaysia.download.clicked, 0);
  assert.equal(test.run(command).status, 'choosing');
  assert.equal(malaysia.download.clicked, 1); assert.equal(page.generate.clicked, 0);
  assert.equal(test.run(command).selected, 'Malaysia');
  assert.equal(page.protocol.value, 'wireguard'); assert.deepEqual(page.protocol.events, ['input', 'change']);
  assert.equal(page.device.value, ''); assert.equal(page.generate.clicked, 0);
  assert.equal(test.run(command).status, 'choosing');
  assert.equal(page.device.value, 'linux'); assert.deepEqual(page.device.events, ['input', 'change']);
  assert.equal(page.generate.clicked, 0);
  assert.equal(test.run(command).status, 'generating'); assert.equal(page.generate.clicked, 1);
  for (let index = 0; index < 4; index++) assert.equal(test.run(command).status, 'generating');
  assert.equal(page.generate.clicked, 1); assert.equal(malaysia.download.clicked, 1); assert.equal(malaysia.expand.clicked, 1);
  assert.equal(malaysia.click.clicked, 0); assert.equal(singapore.click.clicked, 0);
  assert.equal(singapore.expand.clicked, 0); assert.equal(singapore.download.clicked, 0);
  assert.equal(page.buy.clicked, 0); assert.equal(buy.clicked, 0);
  page.root.hidden = true;
  const downloaded = resultPanel('Malaysia');
  test.body.append(downloaded);
  const afterDownload = test.run(command);
  assert.equal(afterDownload.status, 'generating'); assert.equal(afterDownload.selected, 'Malaysia');
  assert.equal(afterDownload.config, ''); assert.equal(page.generate.clicked, 1);
  downloaded.append(element('pre', config));
  const generated = test.run(command);
  assert.equal(generated.status, 'configuration'); assert.equal(generated.selected, 'Malaysia'); assert.equal(generated.config, config);
  assert.equal(page.generate.clicked, 1);
});
check('unarmed or unidentified actions cannot change the official page', () => {
  for (const command of [
    { action: 'inspect', location: 'Malaysia', runId: 'one' },
    { action: 'advance', location: 'Malaysia' },
    { action: 'advance', location: '', runId: 'one' },
    { action: 'unexpected', location: 'Malaysia', runId: 'one' },
  ]) {
    const page = modal(); const test = fixture({ nodes: [page.root] });
    assert.equal(test.run(command).status, 'locations');
    assert.equal(page.protocol.value, 'udp'); assert.deepEqual(page.protocol.events, []);
    assert.equal(page.generate.clicked, 0); assert.equal(page.buy.clicked, 0);
  }
});
check('country expansion requires the actual countryButton, never the heading div', () => {
  for (const restriction of ['disabled', 'hidden', 'missing']) {
    const malaysia = country('Malaysia');
    if (restriction === 'disabled') malaysia.expand.disabled = true;
    if (restriction === 'hidden') malaysia.expand.hidden = true;
    if (restriction === 'missing') malaysia.expand.className = '';
    const test = fixture({ nodes: [malaysia.root] });
    assert.equal(test.run({ action: 'advance', location: 'Malaysia', runId: 'expand-regression' }).status, 'choosing');
    assert.equal(malaysia.click.clicked, 0); assert.equal(malaysia.expand.clicked, 0);
    assert.equal(malaysia.download.clicked, 0); assert.equal(malaysia.download.hidden, true);
  }
});
check('a modal for a different or missing country cannot change protocol or generate', () => {
  for (const label of ['Singapore', '', 'Malaysia East']) {
    const page = modal(label); const test = fixture({ nodes: [page.root] });
    const result = test.run({ action: 'advance', location: 'Malaysia', runId: 'one' });
    assert.equal(result.status, 'wrong-location'); assert.equal(result.selected, label);
    assert.equal(page.protocol.value, 'udp'); assert.equal(page.device.value, ''); assert.equal(page.generate.clicked, 0);
  }
});
check('unknown and duplicate country rows are never guessed', () => {
  for (const names of [['Malaysia', 'Singapore'], ['Unknown', 'Unknown']]) {
    const countries = names.map(country);
    const test = fixture({ nodes: countries.map(item => item.root) });
    assert.equal(test.run({ action: 'advance', location: 'Unknown', runId: 'one' }).status, 'locations');
    for (const item of countries) {
      assert.equal(item.click.clicked, 0); assert.equal(item.expand.clicked, 0); assert.equal(item.download.clicked, 0);
    }
  }
});
check('multiple visible modals or generate actions cannot be guessed', () => {
  const first = modal('Malaysia', { protocol: 'wireguard', device: 'linux' });
  const second = modal('Malaysia', { protocol: 'wireguard', device: 'linux' });
  const test = fixture({ nodes: [first.root, second.root] });
  const command = { action: 'advance', location: 'Malaysia', runId: 'one' };
  assert.equal(test.run(command).status, 'ambiguous');
  assert.equal(first.generate.clicked, 0); assert.equal(second.generate.clicked, 0);
  second.root.hidden = true;
  const duplicate = element('button', 'Generate Configuration'); first.root.append(duplicate);
  assert.equal(test.run(command).status, 'choosing');
  assert.equal(first.generate.clicked, 0); assert.equal(duplicate.clicked, 0);
  duplicate.hidden = true;
  assert.equal(test.run(command).status, 'generating'); assert.equal(first.generate.clicked, 1); assert.equal(second.generate.clicked, 0);
});
check('disabled generation actions and disabled WireGuard or Linux options cannot advance', () => {
  for (const restriction of ['disabled-button', 'aria-button', 'hidden-button', 'wireguard-option', 'linux-option']) {
    const page = modal('Malaysia', { protocol: 'wireguard', device: 'linux' });
    if (restriction === 'disabled-button') page.generate.disabled = true;
    if (restriction === 'aria-button') page.generate.attributes['aria-disabled'] = 'true';
    if (restriction === 'hidden-button') page.generate.hidden = true;
    if (restriction === 'wireguard-option') page.protocol.options[0].disabled = true;
    if (restriction === 'linux-option') page.device.options.find(option => option.textContent === 'Linux').disabled = true;
    const test = fixture({ nodes: [page.root] });
    assert.notEqual(test.run({ action: 'advance', location: 'Malaysia', runId: 'one' }).status, 'generating');
    assert.equal(page.generate.clicked, 0); assert.equal(page.buy.clicked, 0);
  }
});
check('disabled protocol and device selectors cannot dispatch changes', () => {
  for (const restriction of ['protocol', 'device', 'aria-protocol', 'aria-device']) {
    const page = modal('Malaysia', { protocol: restriction.includes('device') ? 'wireguard' : 'udp' });
    const blocked = restriction.includes('device') ? page.device : page.protocol;
    if (restriction.startsWith('aria-')) blocked.attributes['aria-disabled'] = 'true'; else blocked.disabled = true;
    const test = fixture({ nodes: [page.root] });
    assert.equal(test.run({ action: 'advance', location: 'Malaysia', runId: 'one' }).status, 'choosing');
    assert.deepEqual(blocked.events, []); assert.equal(page.generate.clicked, 0);
  }
});
check('human verification freezes a pending operation and allows progress only after completion', () => {
  const page = modal('Malaysia', { protocol: 'wireguard', device: 'linux' }); const widget = challenge();
  const test = fixture({ nodes: [page.root, widget] });
  const command = { action: 'advance', location: 'Malaysia', runId: 'one' };
  assert.equal(test.run(command).status, 'verification'); assert.equal(page.generate.clicked, 0);
  assert.equal(test.run(command).status, 'verification'); assert.equal(page.generate.clicked, 0);
  widget.hidden = true;
  assert.equal(test.run(command).status, 'generating'); assert.equal(page.generate.clicked, 1);
  widget.hidden = false;
  assert.equal(test.run(command).status, 'verification'); assert.equal(page.generate.clicked, 1);
  page.root.append(element('pre', config));
  assert.equal(test.run(command).status, 'configuration'); assert.equal(page.generate.clicked, 1);
});
check('an old completed configuration is never reused as a fresh generation', () => {
  const page = modal('Malaysia', { protocol: 'wireguard', device: 'linux' });
  const cancel = element('button', 'Cancel');
  page.root.hidden = true;
  const test = fixture({ nodes: [page.root, resultPanel('Malaysia', [element('pre', config), cancel])] });
  const command = { action: 'advance', location: 'Malaysia', runId: 'new-generation' };
  const result = test.run(command);
  assert.equal(result.status, 'choosing'); assert.equal(result.config, ''); assert.equal(result.selected, 'Malaysia');
  assert.equal(cancel.clicked, 1); assert.equal(page.generate.clicked, 0);
  assert.equal(test.run(command).status, 'choosing'); assert.equal(cancel.clicked, 1); assert.equal(page.generate.clicked, 0);
  const inspect = test.run();
  assert.equal(inspect.status, 'configuration'); assert.equal(inspect.config, config); assert.equal(cancel.clicked, 1);
});
check('result labels do not falsely attribute a requested country', () => {
  const page = modal('Malaysia', { protocol: 'wireguard', device: 'linux' });
  const test = fixture({ nodes: [page.root, resultPanel('Singapore')] });
  const result = test.run({ action: 'advance', location: 'Malaysia', runId: 'one' });
  assert.equal(result.status, 'wrong-location'); assert.equal(result.selected, 'Singapore'); assert.equal(page.generate.clicked, 0);
});
check('distinct result locations fail closed without falling back to the selection modal country', () => {
  const page = modal('Malaysia', { protocol: 'wireguard', device: 'linux' });
  const cancel = element('button', 'Cancel');
  const test = fixture({ nodes: [page.root, resultPanel('Malaysia', [cancel, element('pre', config)]), resultPanel('Singapore')] });
  for (const action of ['inspect', 'advance']) {
    const result = test.run({ action, location: 'Malaysia', runId: 'ambiguous-result' });
    assert.equal(result.status, 'ambiguous'); assert.equal(result.selected, ''); assert.equal(result.config, '');
    assert.equal(page.generate.clicked, 0); assert.equal(cancel.clicked, 0);
    assert.deepEqual(page.protocol.events, []); assert.deepEqual(page.device.events, []);
  }
  test.body.children[2].hidden = true;
  test.body.append(resultPanel('Malaysia'));
  const duplicate = test.run();
  assert.equal(duplicate.status, 'configuration'); assert.equal(duplicate.selected, 'Malaysia');
  assert.equal(page.generate.clicked, 0); assert.equal(cancel.clicked, 0);
});
check('footer actions still require a confirmed country and a unique device selector', () => {
  const page = modal('Malaysia', { protocol: 'wireguard' });
  page.body.hidden = true;
  const test = fixture({ nodes: [page.root] });
  const command = { action: 'advance', location: 'Malaysia', runId: 'footer-country' };
  assert.equal(test.run(command).status, 'locations');
  assert.equal(page.device.value, ''); assert.equal(page.generate.clicked, 0);
  page.body.hidden = false;
  const duplicate = element('select', '', { id: 'device', value: '' }, [element('option', 'Linux', { value: 'linux' })]);
  test.body.append(duplicate);
  assert.equal(test.run(command).status, 'choosing');
  assert.equal(page.device.value, ''); assert.equal(duplicate.value, ''); assert.equal(page.generate.clicked, 0);
  duplicate.hidden = true;
  assert.equal(test.run(command).status, 'choosing'); assert.equal(page.device.value, 'linux');
});

const originalLoad = Module._load;
const originalEts = require.extensions['.ets'];
try {
  Module._load = function (id, parent, isMain) {
    if (id === '@kit.ArkTS') { return { url: { URL: { parseURL: address => new URL(address) } } }; }
    return originalLoad.call(this, id, parent, isMain);
  };
  require.extensions['.ets'] = (module, filename) => {
    const result = ts.transpileModule(fs.readFileSync(filename, 'utf8'), {
      compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }, fileName: filename,
    });
    module._compile(result.outputText, filename);
  };
  const native = require('../entry/src/main/ets/model/PureVpnWeb.ets');
  check('native URL validation rejects deceptive domains, schemes and authorities', () => {
    assert.equal(native.isPureVpnPage(native.PUREVPN_MEMBER_URL, true), true);
    assert.equal(native.isPureVpnPage(native.PUREVPN_MEMBER_URL + '/', true), true);
    assert.equal(native.isPureVpnPage('https://my.purevpn.com/login', true), false);
    for (const address of ['http://my.purevpn.com' + manualPath, 'javascript:alert(1)', 'file:///etc/passwd',
      'https://my.purevpn.com.evil.invalid' + manualPath, 'https://purevpn.com@evil.invalid' + manualPath,
      'https://user:password@my.purevpn.com' + manualPath, 'https://my.purevpn.com:444' + manualPath,
      'https://notpurevpn.com' + manualPath, 'not a URL']) {
      assert.equal(native.isPureVpnPage(address), false, address);
      assert.equal(native.isPureVpnPage(address, true), false, address);
    }
  });
  check('native result validation bounds strings, arrays and serialization wrappers', () => {
    const good = { status: 'configuration', locations: ['Malaysia'], selected: 'Malaysia', config };
    assert.deepEqual(native.parsePureVpnWebResult(JSON.stringify(good)), good);
    assert.deepEqual(native.parsePureVpnWebResult(JSON.stringify(JSON.stringify(good))), good);
    for (const bad of ['null', '[]', '{}', '{broken', 'x'.repeat(300001), JSON.stringify(JSON.stringify(JSON.stringify(good))),
      JSON.stringify({ ...good, locations: new Array(301).fill('a') }),
      JSON.stringify({ ...good, locations: [null] }), JSON.stringify({ ...good, selected: 'x'.repeat(101) }),
      JSON.stringify({ ...good, config: 'x'.repeat(131073) }), JSON.stringify({ ...good, status: 1 })]) {
      assert.throws(() => native.parsePureVpnWebResult(bad));
    }
  });
} finally {
  Module._load = originalLoad;
  if (originalEts) { require.extensions['.ets'] = originalEts; } else { delete require.extensions['.ets']; }
}
if (failures.length) {
  console.error(failures.join('\n'));
  process.exitCode = 1;
} else {
  console.log('PureVPN web: ' + passed + ' fixture scenarios passed; origin/path guards, private fields, human verification, configuration extraction, explicit actions and native validation');
}
