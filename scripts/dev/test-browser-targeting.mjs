#!/usr/bin/env node
// Isolated DOM fixtures: no browser, server, dependencies, or persistent state.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { runInNewContext } from 'node:vm';
import { webcrypto } from 'node:crypto';

const source = readFileSync(new URL('../../packages/desktop/src/cli/browser_targeting.js', import.meta.url), 'utf8');
let nodes = [];
const document = {
  querySelectorAll: () => nodes,
  querySelector: selector => {
    if (selector === '[') throw new Error('syntax');
    return nodes.find(el => el.getAttribute('id') === selector.slice(1)) || null;
  },
  getElementById: id => nodes.find(el => el.getAttribute('id') === id) || null,
};
const window = {};
const location = { href: 'https://fixture.invalid/' };
class Input {
  set value(value) { this._value = value; this.setterCalled = true; }
  get value() { return this._value || ''; }
}
class Textarea extends Input {}
class DomEvent { constructor(type, options) { this.type = type; Object.assign(this, options); } }
const context = {
  document, window, location, crypto: webcrypto, CSS: { escape: value => value },
  HTMLInputElement: Input, HTMLTextAreaElement: Textarea,
  InputEvent: DomEvent, Event: DomEvent, KeyboardEvent: DomEvent, MouseEvent: DomEvent,
  getComputedStyle: () => ({ visibility: 'visible', display: 'block' }),
};
const targeting = runInNewContext(source, context);
function element(tag, attrs = {}, text = '') {
  const el = {
    id: attrs.id, nodeType: 1, localName: tag, type: attrs.type || 'text', textContent: text, innerText: text,
    value: '', labels: [], isConnected: true, ownerDocument: document,
    getAttribute: key => attrs[key] ?? null,
    hasAttribute: key => key in attrs,
    getBoundingClientRect: () => ({ width: 20, height: 20 }),
    closest: () => null,
    focus: () => { el.focused = true; },
    click: () => { el.clicked = true; },
    scrollIntoView: () => {},
    matches: () => false,
    dispatchEvent: event => { (el.events ||= []).push(event); },
  };
  if (tag === 'input' || tag === 'textarea') {
    delete el.value;
    Object.setPrototypeOf(el, tag === 'input' ? Input.prototype : Textarea.prototype);
  }
  nodes.push(el);
  return el;
}
const rejects = (target, code) => assert.throws(() => targeting.resolve(target), { name: code });
const save = element('button', { id: 'save' }, ' Save\n changes ');
assert.equal(targeting.resolve({ selector: '#save' }), save);
assert.equal(targeting.resolve({ role: 'button', name: 'Save changes' }), save);
rejects({ selector: '[' }, 'invalid_selector');
rejects({ role: 'link' }, 'element_not_found');
rejects({ selector: '#save', role: 'button' }, 'invalid_target');
rejects({ name: 'Save changes' }, 'invalid_target');
const other = element('button', {}, 'Save changes');
rejects({ role: 'button', name: 'Save changes' }, 'ambiguous_target');
other.disabled = true;
rejects({ role: 'button', name: 'Save changes' }, 'ambiguous_target');
other.closest = () => ({});
assert.equal(targeting.resolve({ role: 'button', name: 'Save changes' }), save);
const input = element('input', { type: 'password', id: 'password' });
input.value = 'never expose me';
input.labels = [{ textContent: ' Account\n password ' }];
assert.equal(targeting.name(input), 'Account password');
assert.equal(targeting.role(input), '');
assert.equal(targeting.resolve({ label: 'Account password' }), input);
const accessible = element('button', { 'aria-labelledby': 'heading' }, 'ignored');
element('span', { id: 'heading' }, 'Accessible name');
assert.equal(targeting.resolve({ role: 'button', name: 'Accessible name' }), accessible);
const first = targeting.inspect(10);
const ref = first.elements.find(item => item.selector === '#save').ref;
assert.equal(targeting.resolve({ ref }), save);
save.innerText = 'Different action';
rejects({ ref }, 'stale_ref');
save.innerText = 'Save changes';
save.isConnected = false;
element('button', { id: 'save' }, 'Save changes');
rejects({ ref }, 'stale_ref');
save.isConnected = true;
location.href += '#changed';
assert.equal(targeting.resolve({ ref }), save);
location.href = 'https://fixture.invalid/new-route';
assert.equal(targeting.resolve({ ref }), save);
location.href = 'https://fixture.invalid/';
targeting.inspect(10);
rejects({ ref }, 'stale_ref');
const fresh = targeting.inspect(10).elements[0].ref;
save.ownerDocument = {};
rejects({ ref: fresh }, 'stale_ref');
delete window.__verdeBrowserTargetSnapshotV1;
rejects({ ref: fresh }, 'stale_ref');
// Malformed inputs are rejected before resolution.
for (const bad of [null, {}, { ref: 1 }, { role: null }, { role: '  ' },
  { selector: '#save', ref: '' }, { label: [] }, { role: 'button', name: false },
  { label: 'Account password', name: 'invalid' }]) rejects(bad, 'invalid_target');
save.ownerDocument = document;
save.innerText = 'Save changes';
// No input value, including a password, becomes a semantic name.
input.labels = [];
assert.equal(targeting.name(input), '');
let snapshot = targeting.inspect(20);
assert.equal(snapshot.elements.find(item => item.selector === '#password').text, '');
assert.ok(!JSON.stringify(snapshot).includes('never expose me'));
assert.equal(snapshot.elements.find(item => item.selector === '#save').accessible_name, 'Save changes');
// Legacy CSS selects the first match, including duplicates.
assert.equal(targeting.resolve({ selector: '#save' }), save);
assert.equal(targeting.click({ selector: '#save' }, true).clicked, true);
assert.equal(save.clicked, true);
assert.equal(targeting.type({ selector: '#password' }, 'replacement', false, false).confirmation_required, true);
assert.equal(input.value, 'never expose me');
assert.equal(targeting.type({ selector: '#password' }, 'replacement', false, true).typed, true);
assert.equal(input.value, 'replacement');
assert.equal(input.setterCalled, true);
assert.deepEqual(input.events.map(event => event.type), ['input', 'change']);
assert.equal(input.events[0].data, 'replacement');
let submitted = 0;
input.form = { requestSubmit: () => submitted++ };
targeting.type({ selector: '#password' }, 'submitted', true, true);
assert.equal(submitted, 1);
const textarea = element('textarea', { id: 'message' });
targeting.type({ selector: '#message' }, 'hello\nworld', false, false);
assert.equal(textarea.value, 'hello\nworld');
assert.equal(textarea.setterCalled, true);
const editable = element('div', { id: 'editable' });
editable.isContentEditable = true;
targeting.type({ selector: '#editable' }, 'edited', true, true);
assert.equal(editable.textContent, 'edited');
assert.equal(editable.events.at(-1).type, 'keydown');
textarea.readOnly = true;
assert.throws(() => targeting.type({ selector: '#message' }, 'blocked', false, false), { name: 'element_not_editable' });
const send = element('button', { id: 'send' }, 'Send');
assert.equal(targeting.click({ selector: '#send' }, false).confirmation_required, true);
assert.equal(send.clicked, undefined);
// Insecure HTTP may provide getRandomValues but not randomUUID; older engines
// may have neither. New snapshots must invalidate refs in every configuration.
for (const crypto of [{ getRandomValues: array => webcrypto.getRandomValues(array) }, undefined, {}]) {
  const fallback = runInNewContext(source, { ...context, crypto });
  const a = fallback.inspect(20), b = fallback.inspect(20);
  assert.notEqual(a.snapshot_id, b.snapshot_id);
  assert.throws(() => fallback.resolve({ ref: a.elements[0].ref }), { name: 'stale_ref' });
  assert.equal(fallback.resolve({ ref: b.elements[0].ref }), save);
}
const ariaSend = element('button', { id: 'aria-send', 'aria-label': 'Delete account' }, 'Go');
assert.equal(targeting.click({ selector: '#aria-send' }, false).confirmation_required, true);
const typed = targeting.type({ selector: '#password' }, 'secret', false, true);
assert.equal(typed.value_matches, true);
assert.equal(typed.length, 6);
assert.equal(typed.matched_by, 'selector');
assert.equal(typed.target.tag, 'input');
assert.ok(!JSON.stringify(typed).includes('secret'));
console.log('browser targeting fixtures passed');

// Exercise the actual embedded wrapper strings, including JS-context replacement.
const cli = readFileSync(new URL('../../packages/desktop/src/cli/main.zig', import.meta.url), 'utf8');
const zigWrites = (start, end) => [...cli.slice(cli.indexOf(start), cli.indexOf(end, cli.indexOf(start))).matchAll(/writeAll\(("(?:\\.|[^"\\])*")\)/g)].map(match => JSON.parse(match[1]));
const startWrites = zigWrites('fn mcpBrowserStartScriptAlloc(', 'fn mcpBrowserPollScriptForModeAlloc(');
const pollWrites = zigWrites('fn mcpBrowserPollScriptAlloc(', 'const McpBrowserTarget');
const nonce = 'fixture-nonce';
const startScript = (body, async) => startWrites[0] + JSON.stringify(nonce) + startWrites[1] + startWrites[async ? 4 : 2] + body + startWrites[async ? 5 : 3];
const pollScript = pollWrites[0] + JSON.stringify(nonce) + pollWrites[1];
const page = { window: {}, location: { href: 'https://fixture.invalid/' } };
const pending = runInNewContext(startScript('return await new Promise(() => {});', true), page);
assert.equal(pending.pending, true);
assert.equal(runInNewContext(pollScript, page).pending, true);
page.window = {}; // Full navigation replaces the JS global; same-document URL changes do not.
const lost = runInNewContext(pollScript, page);
assert.equal(lost.lost, true);
assert.equal(lost.error.code, 'document_replaced');
assert.equal(lost.error.details.action_may_have_run, true);
const done = runInNewContext(startScript('window.actions = (window.actions || 0) + 1; return 42;', false), page);
assert.equal(done.result, 42);
assert.equal(runInNewContext(pollScript, page).result, 42);
assert.equal(runInNewContext(pollScript, page).result, 42);
assert.equal(page.window.actions, 1); // Polling never replays the user body.
const missingReturn = runInNewContext(startScript('(() => { window.actions++; return 42; })();', false), page);
assert.equal(missingReturn.ok, true);
assert.equal(missingReturn.result, null);
assert.equal(missingReturn.result_undefined, true);
assert.match(missingReturn.warning, /outer return/);
assert.equal(page.window.actions, 2); // Explain the missing value without re-executing it.
const explicitNull = runInNewContext(startScript('return null;', false), page);
assert.equal(explicitNull.result, null);
assert.equal(explicitNull.result_undefined, undefined);
const failure = runInNewContext(startScript("const e = new Error('Ambiguous'); e.name = 'ambiguous_target'; e.code = 'ambiguous_target'; e.details = {match_count:2}; throw e;", false), page);
assert.equal(failure.error.name, 'ambiguous_target');
assert.equal(failure.error.message, 'Ambiguous');
assert.equal(failure.error.code, 'ambiguous_target');
assert.equal(failure.error.details.match_count, 2);
console.log('browser eval context-loss fixtures passed');
