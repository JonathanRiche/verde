// Embedded by the CLI. This is a top-document DOM approximation, not an AX tree.
(() => {
  const normalize = value => String(value || '').replace(/\s+/g, ' ').trim();
  const fail = (code, message, details) => { const error = new Error(message); error.name = code; error.code = code; if (details) error.details = details; throw error; };
  const visible = el => {
    const rect = el.getBoundingClientRect(), style = getComputedStyle(el);
    return rect.width > 0 && rect.height > 0 && style.visibility !== 'hidden' &&
      style.visibility !== 'collapse' && style.display !== 'none' &&
      !el.closest('[hidden],[inert],[aria-hidden="true"]');
  };
  const role = el => {
    const explicit = normalize(el.getAttribute('role')).split(' ')[0];
    if (explicit) return explicit;
    switch (el.localName) {
      case 'button': return 'button';
      case 'a': return el.hasAttribute('href') ? 'link' : '';
      case 'textarea': return 'textbox';
      case 'select': return el.multiple || el.size > 1 ? 'listbox' : 'combobox';
      case 'option': return 'option';
      case 'input':
        switch (el.type) {
          case 'hidden': case 'password': return '';
          case 'button': case 'submit': case 'reset': case 'image': return 'button';
          case 'checkbox': return 'checkbox';
          case 'radio': return 'radio';
          case 'range': return 'slider';
          case 'number': return 'spinbutton';
          case 'search': return 'searchbox';
          default: return 'textbox';
        }
      case 'img': return 'img';
      case 'h1': case 'h2': case 'h3': case 'h4': case 'h5': case 'h6': return 'heading';
      default: return '';
    }
  };
  const labels = el => Array.from(el.labels || [], label => normalize(label.textContent)).filter(Boolean);
  const name = el => {
    const labelledby = normalize(el.getAttribute('aria-labelledby'));
    if (labelledby) {
      const text = normalize(labelledby.split(' ').map(id => document.getElementById(id)?.textContent || '').join(' '));
      if (text) return text;
    }
    const aria = normalize(el.getAttribute('aria-label'));
    if (aria) return aria;
    const label = normalize(labels(el).join(' '));
    if (label) return label;
    if (el.localName === 'img' || (el.localName === 'input' && el.type === 'image')) return normalize(el.getAttribute('alt'));
    if (el.localName === 'input' && ['submit', 'reset', 'button'].includes(el.type)) return normalize(el.value);
    // Never use editable values as names (in particular passwords).
    if (['button', 'link', 'heading', 'option'].includes(role(el))) return normalize(el.innerText || el.textContent);
    return normalize(el.getAttribute('title'));
  };
  const fingerprint = el => JSON.stringify([el.localName, role(el), name(el), el.getAttribute('type'), el.getAttribute('href')]);
  const key = '__verdeBrowserTargetSnapshotV1';
  const snapshotId = () => {
    const previous = window[key];
    const sequence = previous?.document === document ? previous.sequence + 1 : 1;
    let entropy;
    try {
      const bytes = new Uint32Array(4);
      globalThis.crypto.getRandomValues(bytes);
      entropy = Array.from(bytes, n => n.toString(36)).join('');
    } catch (_) {
      // Insecure origins and older WebKit may lack crypto. Sequence prevents
      // same-document reuse; time and four independent draws separate documents.
      entropy = Date.now().toString(36) + Array.from({ length: 4 }, () => Math.random().toString(36).slice(2)).join('');
    }
    return { id: entropy + '-' + sequence.toString(36), sequence };
  };
  const selectorFor = el => {
    if (el.id) return '#' + CSS.escape(el.id);
    const parts = [];
    for (let node = el; node && node.nodeType === 1 && parts.length < 6; node = node.parentElement) {
      let part = node.localName;
      if (node.getAttribute('name')) part += '[name="' + CSS.escape(node.getAttribute('name')) + '"]';
      else {
        let i = 1;
        for (let p = node.previousElementSibling; p; p = p.previousElementSibling) if (p.localName === node.localName) i++;
        part += ':nth-of-type(' + i + ')';
      }
      parts.unshift(part);
    }
    return parts.join(' > ');
  };
  const elementText = el => el.localName === 'input' && el.type === 'password' ? '' :
    String(el.innerText || el.value || el.getAttribute('aria-label') || '').trim().slice(0, 300);
  const inspect = (max, textLimit = 12000) => {
    const state = { document, url: String(location.href), ...snapshotId(), refs: new Map() };
    const nodes = Array.from(document.querySelectorAll('a[href],button,input,textarea,select,[role],[contenteditable="true"],[tabindex]')).filter(visible).slice(0, max);
    const elements = nodes.map((el, i) => {
      const ref = state.id + ':' + (i + 1);
      state.refs.set(ref, { el, fingerprint: fingerprint(el) });
      const r = el.getBoundingClientRect();
      return { ref, selector: selectorFor(el), tag: el.localName, role: role(el),
        type: el.getAttribute('type'), name: el.getAttribute('name'),
        accessible_name: name(el), label: normalize(labels(el).join(' ')),
        text: elementText(el), href: el.href || null,
        disabled: Boolean(el.disabled || el.getAttribute('aria-disabled') === 'true'),
        rect: { x: r.x, y: r.y, width: r.width, height: r.height } };

    });
    window[key] = state;
    return { snapshot_id: state.id, title: document.title, text: String(document.body?.innerText || '').slice(0, textLimit), elements };
  };
  const resolve = target => {
    if (!target || typeof target !== 'object') fail('invalid_target', 'Target must be an object');
    for (const key of ['selector', 'ref', 'role', 'label', 'name']) {
      if (key in target && (typeof target[key] !== 'string' || (key !== 'name' && !normalize(target[key]))))
        fail('invalid_target', 'Target fields must be nonempty strings (name may be empty)');
    }
    const modes = ['selector', 'ref', 'role', 'label'].filter(key => typeof target[key] === 'string' && target[key].length > 0);
    if (modes.length !== 1 || (target.name !== undefined && modes[0] !== 'role')) fail('invalid_target', 'Supply exactly one selector, ref, role (with optional name), or label');
    if (modes[0] === 'selector') {
      let el;
      try { el = document.querySelector(target.selector); } catch (_) { fail('invalid_selector', 'Invalid CSS selector'); }
      if (!el) fail('element_not_found', 'No element matches selector');
      return el;
    }
    if (modes[0] === 'ref') {
      const state = window[key], entry = state?.refs.get(target.ref);
      if (!entry || state.document !== document || !entry.el.isConnected || entry.el.ownerDocument !== document || entry.fingerprint !== fingerprint(entry.el))
        fail('stale_ref', 'Element reference is stale; inspect the page again');
      return entry.el;
    }
    const matches = Array.from(document.querySelectorAll('*')).filter(visible).filter(el =>
      modes[0] === 'role' ? role(el) === normalize(target.role) && (target.name === undefined || name(el) === normalize(target.name)) :
        labels(el).includes(normalize(target.label)) || normalize(el.getAttribute('aria-label')) === normalize(target.label));
    if (!matches.length) fail('element_not_found', 'No element matches semantic target');
    if (matches.length !== 1) fail('ambiguous_target', 'Semantic target matches multiple elements; inspect and use a ref', { match_count: matches.length });
    return matches[0];
  };
  const metadata = (el, target) => ({ matched_by: ['selector', 'ref', 'role', 'label'].find(key => key in target),
    target: { role: role(el), name: name(el), tag: el.localName, ref: target.ref ?? null } });
  const click = (target, confirmed) => {
    const el = resolve(target), selector = target.selector ?? null;
    if (el.disabled || el.getAttribute('aria-disabled') === 'true') fail('element_disabled', 'Element is disabled');
    const label = elementText(el), accessible_name = name(el);
    const sensitive = el.matches('input[type=submit],button[type=submit]') || /(buy|purchase|pay|delete|remove|send|submit|confirm|publish)/i.test(label + ' ' + accessible_name);
    if (sensitive && !confirmed) return { clicked: false, sensitive: true, confirmation_required: true, selector, label, ...metadata(el, target) };
    const matched = metadata(el, target);
    el.scrollIntoView({ block: 'center', inline: 'center' });
    // Page-local focus preserves existing focus/blur-driven form behavior.
    // The browser transport must keep OS focus and workspace selection unchanged.
    if (typeof el.focus === 'function') el.focus({ preventScroll: true });
    if (typeof el.click === 'function') el.click();
    else el.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, view: window }));
    return { clicked: true, sensitive, selector, tag: el.localName, label, href: el.href || null, ...matched };
  };
  const type = (target, text, submit, confirmed) => {
    const el = resolve(target), selector = target.selector ?? null;
    const isField = el instanceof HTMLInputElement || el instanceof HTMLTextAreaElement || el.isContentEditable;
    if (!isField) fail('element_not_editable', 'Element is not an editable field');
    if (el.disabled || el.readOnly || el.getAttribute('aria-disabled') === 'true') fail('element_not_editable', 'Element is disabled or read-only');
    const sensitive = (el instanceof HTMLInputElement && el.type === 'password') || submit;
    if (sensitive && !confirmed) return { typed: false, sensitive: true, confirmation_required: true, selector, ...metadata(el, target) };
    const matched = metadata(el, target);
    el.focus({ preventScroll: true });
    if (el.isContentEditable) el.textContent = text;
    else {
      const proto = el instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
      const setter = Object.getOwnPropertyDescriptor(proto, 'value')?.set;
      if (setter) setter.call(el, text); else el.value = text;
    }
    el.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText', data: text }));
    el.dispatchEvent(new Event('change', { bubbles: true }));
    if (submit) {
      if (el.form && typeof el.form.requestSubmit === 'function') el.form.requestSubmit();
      else el.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', code: 'Enter', bubbles: true, cancelable: true }));
    }
    const value = String(el.isContentEditable ? el.textContent : el.value);
    return { typed: true, submitted: submit, sensitive, selector, tag: el.localName,
      value_matches: value === text, length: value.length, ...matched };
  };
  return { inspect, resolve, role, name, visible, click, type };
})()
