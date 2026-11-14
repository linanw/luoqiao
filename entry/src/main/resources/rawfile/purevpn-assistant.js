/* Visible official member UI only. No auth APIs, challenge interaction, token reads, or storage. */
(function (command) {
  'use strict';
  const result = (status, extra) => JSON.stringify(Object.assign({ status, locations: [], selected: '', config: '' }, extra || {}));
  if (location.origin !== 'https://my.purevpn.com') return result('outside');
  if (!document.body) return result('loading');
  const visible = el => !!el && el.getClientRects().length > 0 && getComputedStyle(el).visibility !== 'hidden';
  const text = el => (el.textContent || '').replace(/\s+/g, ' ').trim();
  const all = (root, selector) => Array.from(root.querySelectorAll(selector)).filter(visible);
  const enabled = el => !el.disabled && el.getAttribute('aria-disabled') !== 'true';
  const buttons = root => all(root, 'button,[role="button"]').filter(enabled);
  const pageText = (document.body.innerText || '').slice(0, 80000);
  if (/User Agent Exception/i.test(pageText)) return result('session-error');
  if (all(document, 'input[type="password"]').length) return result('login');
  if (!/^\/v2\/dashboard\/manual-config\/?$/.test(location.pathname)) return result('login');

  // These selectors are from the logged-in country catalog, not the sorting select.
  const countries = all(document, '.subscription-head.country').map(card => {
    const headings = all(card, '.clickCountry h3');
    return { card, label: headings.length === 1 ? text(headings[0]) : '' };
  }).filter(item => item.label && item.label.length <= 100);
  const locations = Array.from(new Set(countries.map(item => item.label))).slice(0, 300);
  const modals = all(document, '.mod-body');
  const modal = modals.length === 1 ? modals[0] : null;
  let selected = '';
  let completed = false;
  if (modal) {
    const headings = all(modal, '.country h3');
    if (headings.length === 1) selected = text(headings[0]);
  }
  // The generated result replaces the selection body with a separate result panel.
  const labels = all(document, 'p,span,div').map(text)
    .filter(label => /^Location:\s*[^:]+$/i.test(label) && label.length <= 110);
  const unique = Array.from(new Set(labels.map(label => label.replace(/^Location:\s*/i, '').trim())));
  if (unique.length > 1) return result('ambiguous', { locations });
  if (unique.length === 1) { selected = unique[0]; completed = true; }
  if (selected.length > 100) selected = '';
  const base = { locations, selected };
  const configs = all(document, 'textarea, pre, code').map(el => el.tagName === 'TEXTAREA' ? el.value : el.textContent)
    .filter(value => typeof value === 'string' && value.length <= 131072 && /^\s*(?:#[^\n]*\n\s*)*\[Interface\]/i.test(value) && /\[Peer\]/i.test(value));
  const uniqueConfigs = Array.from(new Set(configs));
  if (uniqueConfigs.length > 1) return result('ambiguous', base);

  const active = command.action === 'advance' || command.action === 'select';
  const requested = typeof command.location === 'string' ? command.location : '';
  const runId = typeof command.runId === 'string' ? command.runId : '';
  let flow = globalThis.__harmonyPureVpnFlow;
  if (active && runId && requested && (!flow || flow.runId !== runId || flow.country !== requested)) {
    flow = { runId, country: requested, expanded: false, opened: false, protocol: false, device: false, generated: false, closed: false };
    globalThis.__harmonyPureVpnFlow = flow;
  }
  const sameRun = !!flow && flow.runId === runId && flow.country === requested;
  // A completed configuration may be read after a challenge widget remains mounted.
  if (uniqueConfigs.length === 1 && (!active || (sameRun && flow.generated))) {
    return result('configuration', Object.assign(base, { config: uniqueConfigs[0] }));
  }
  const verification = all(document, 'iframe').some(el => /captcha|challenge|turnstile/i.test((el.src || '') + ' ' + (el.title || '')));
  if (verification || /verify (that )?you are human|checking your browser|complete the security check|验证您是真人|验证您是否为真人/i.test(pageText)) {
    return result('verification', base);
  }
  if (!active || !runId || !requested || !sameRun) return result('locations', base);
  if (modals.length > 1) return result('ambiguous', base);
  if (modal || completed) {
    if (!selected || selected !== requested) return result('wrong-location', base);
    if (flow.generated) return result('generating', base); // One generation per operation, including after download.
    if (completed || uniqueConfigs.length) {
      const cancel = buttons(document).filter(el => /^(Cancel|取消)$/.test(text(el)));
      if (cancel.length === 1 && !flow.closed) { flow.closed = true; cancel[0].click(); }
      return result('choosing', base);
    }
    const selects = all(modal, 'select');
    const protocols = selects.filter(el => Array.from(el.options).some(option => /^WireGuard$/i.test(text(option))));
    if (protocols.length !== 1) return result('choosing', base);
    const protocol = protocols[0];
    if (!enabled(protocol)) return result('choosing', base);
    const wireguard = Array.from(protocol.options).filter(option => /^WireGuard$/i.test(text(option)) && !option.disabled);
    if (wireguard.length !== 1) return result('ambiguous', base);
    if (protocol.value !== wireguard[0].value) {
      if (!flow.protocol) {
        flow.protocol = true; protocol.value = wireguard[0].value;
        protocol.dispatchEvent(new Event('input', { bubbles: true }));
        protocol.dispatchEvent(new Event('change', { bubbles: true }));
      }
      return result('choosing', base);
    }
    // The device step is rendered in the modal footer, outside .mod-body.
    const devices = all(document, 'select#device');
    if (devices.length !== 1) return result('choosing', base);
    if (!enabled(devices[0])) return result('choosing', base);
    const linux = Array.from(devices[0].options).filter(option => text(option) === 'Linux' && !option.disabled);
    if (linux.length !== 1) return result('ambiguous', base);
    if (devices[0].value !== linux[0].value) {
      if (!flow.device) {
        flow.device = true; devices[0].value = linux[0].value;
        devices[0].dispatchEvent(new Event('input', { bubbles: true }));
        devices[0].dispatchEvent(new Event('change', { bubbles: true }));
      }
      return result('choosing', base);
    }
    const generate = buttons(document).filter(el => /^(Generate Configuration|生成配置)$/.test(text(el)));
    if (generate.length === 1) {
      flow.generated = true;
      generate[0].click();
      return result('generating', base);
    }
    return result('choosing', base);
  }
  if (flow.generated) return result('generating', base);
  const matches = countries.filter(item => item.label === requested);
  if (matches.length !== 1) return result('locations', base);
  const country = matches[0];
  const downloads = buttons(country.card).filter(el => /^(Download|下载)$/.test(text(el)));
  if (downloads.length === 1) {
    if (!flow.opened) { flow.opened = true; downloads[0].click(); }
    return result('choosing', base); // Country is confirmed only once the modal displays it.
  }
  const expand = all(country.card, 'button.countryButton').filter(enabled);
  if (downloads.length === 0 && expand.length === 1 && !flow.expanded) {
    flow.expanded = true; expand[0].click();
  }
  return result('choosing', base);
})(__PUREVPN_COMMAND__);
