export type KeyAction =
  | 'command_palette'
  | 'toggle_sidebar'
  | 'toggle_sidebar_hidden'
  | 'new_thread'
  | 'new_terminal'
  | 'close_pane'
  | 'focus_prompt'
  | 'workspace_previous'
  | 'workspace_next'
  | 'pane_previous'
  | 'pane_next'
  | 'focus_left'
  | 'focus_right'
  | 'focus_up'
  | 'focus_down'
  | 'maximize'
  | 'settings'
  | 'escape'
  | { kind: 'pane_select'; index: number }
  | { kind: 'workspace_select'; index: number }
  | { kind: 'active_select'; index: number }

export type PrefixCommandPlacement =
  | 'background'
  | 'terminal'
  | 'pane'
  | 'split_horizontal'
  | 'split_vertical'
  | 'floating'
  | 'tab'

export type PrefixTarget = { action: string } | { command: string; in?: PrefixCommandPlacement }

export interface Accelerator {
  key: string
  ctrl: boolean
  shift: boolean
  alt: boolean
  meta: boolean
  primary: boolean
  label: string
}

export interface PrefixBinding {
  key: Accelerator
  target: PrefixTarget
}

export interface WebKeybindConfig {
  directFocusLetters: Partial<Record<'h' | 'j' | 'k' | 'l', KeyAction>>
  prefix: {
    enabled: boolean
    keys: Accelerator[]
    bindings: PrefixBinding[]
    navigate: PrefixBinding[]
  }
}

interface Chord {
  key: string
  ctrl?: boolean
  shift?: boolean
  alt?: boolean
  meta?: boolean
  action: KeyAction
}

const DIRECT_CHORDS: Chord[] = [
  { key: 'p', ctrl: true, shift: true, action: 'command_palette' },
  { key: 's', ctrl: true, action: 'toggle_sidebar' },
  { key: 's', ctrl: true, shift: true, action: 'toggle_sidebar_hidden' },
  { key: 't', ctrl: true, alt: true, action: 'new_terminal' },
  { key: 'w', ctrl: true, action: 'close_pane' },
  { key: 'x', alt: true, action: 'close_pane' },
  { key: 'arrowup', alt: true, action: 'workspace_previous' },
  { key: 'arrowdown', alt: true, action: 'workspace_next' },
  { key: 'tab', ctrl: true, action: 'pane_next' },
  { key: 'tab', ctrl: true, shift: true, action: 'pane_previous' },
  { key: 'arrowleft', ctrl: true, action: 'focus_left' },
  { key: 'arrowright', ctrl: true, action: 'focus_right' },
  { key: 'arrowup', ctrl: true, action: 'focus_up' },
  { key: 'arrowdown', ctrl: true, action: 'focus_down' },
  { key: 'z', alt: true, action: 'maximize' },
  { key: ',', ctrl: true, action: 'settings' },
]

for (let index = 0; index <= 9; index += 1) {
  DIRECT_CHORDS.push({ key: String(index), ctrl: true, action: { kind: 'pane_select', index: index === 0 ? 9 : index - 1 } })
  DIRECT_CHORDS.push({ key: String(index), alt: true, action: { kind: 'workspace_select', index: index === 0 ? 9 : index - 1 } })
  DIRECT_CHORDS.push({
    key: String(index),
    ctrl: true,
    shift: true,
    action: { kind: 'active_select', index: index === 0 ? 9 : index - 1 },
  })
}

const DEFAULT_PREFIX_ROWS: Array<[string, string]> = [
  ['Shift+Slash', 'prefix.keybinds'], ['W', 'prefix.navigate'],
  ['P', 'command_palette'], ['T', 'new_thread'], ['Shift+T', 'new_terminal'], ['R', 'refresh'], ['O', 'open'],
  ['E', 'open_editor'], ['Space', 'companion'], ['S', 'sidebar'], ['Shift+S', 'sidebar_hidden'],
  ['B', 'browser'], ['Grave', 'terminal.toggle'], ['Q', 'workspace.toggle_quick_pane'],
  ['X', 'workspace.close'], ['Shift+X', 'workspace.close_current'], ['Z', 'workspace.toggle_maximize'],
  ['I', 'workspace.focus_prompt'], ['C', 'workspace.split_chat_vertical'],
  ['Shift+C', 'workspace.split_chat_horizontal'], ['V', 'workspace.split_chat_vertical'],
  ['Minus', 'workspace.split_chat_horizontal'], ['Shift+V', 'workspace.split_terminal_vertical'],
  ['Shift+Minus', 'workspace.split_terminal_horizontal'],
  ['H', 'workspace.focus_left'], ['J', 'workspace.focus_down'], ['K', 'workspace.focus_up'], ['L', 'workspace.focus_right'],
  ['Left', 'workspace.focus_left'], ['Down', 'workspace.focus_down'], ['Up', 'workspace.focus_up'], ['Right', 'workspace.focus_right'],
  ['Shift+H', 'workspace.move_left'], ['Shift+J', 'workspace.move_down'], ['Shift+K', 'workspace.move_up'], ['Shift+L', 'workspace.move_right'],
  ['Ctrl+H', 'workspace.grow_left'], ['Ctrl+J', 'workspace.grow_down'], ['Ctrl+K', 'workspace.grow_up'], ['Ctrl+L', 'workspace.grow_right'],
  ['Ctrl+Left', 'workspace.grow_left'], ['Ctrl+Down', 'workspace.grow_down'], ['Ctrl+Up', 'workspace.grow_up'], ['Ctrl+Right', 'workspace.grow_right'],
  ['N', 'workspace.pane_next'], ['Shift+N', 'workspace.pane_previous'],
  ['LeftBracket', 'workspace.previous'], ['RightBracket', 'workspace.next'],
  ['Shift+LeftBracket', 'workspace.active_previous'], ['Shift+RightBracket', 'workspace.active_next'],
  ['Shift+Up', 'chat_up'], ['Shift+Down', 'chat_down'], ['PageUp', 'chat_page_up'], ['PageDown', 'chat_page_down'],
  ['M', 'chat.model_picker'], ['Shift+M', 'chat.run_config'],
  ['Ctrl+T', 'terminal.new_tab'], ['Shift+W', 'terminal.close'], ['Comma', 'terminal.rename_tab'],
  ['Ctrl+PageUp', 'terminal.tab_previous'], ['Ctrl+PageDown', 'terminal.tab_next'],
  ['Alt+Up', 'terminal.split_up'], ['Alt+Down', 'terminal.split_down'], ['Alt+Left', 'terminal.split_left'], ['Alt+Right', 'terminal.split_right'],
  ['Alt+Shift+Up', 'terminal.focus_up'], ['Alt+Shift+Down', 'terminal.focus_down'],
  ['Alt+Shift+Left', 'terminal.focus_left'], ['Alt+Shift+Right', 'terminal.focus_right'],
]

for (let index = 1; index <= 10; index += 1) {
  const digit = String(index % 10)
  DEFAULT_PREFIX_ROWS.push([digit, `workspace.pane_select.${index}`])
  DEFAULT_PREFIX_ROWS.push([`Shift+${digit}`, `workspace.select.${index}`])
  DEFAULT_PREFIX_ROWS.push([`Ctrl+${digit}`, `workspace.active_select.${index}`])
}

const DEFAULT_NAVIGATE_ROWS: Array<[string, string]> = [
  ['Up', 'workspace.previous'], ['Down', 'workspace.next'], ['Tab', 'workspace.pane_next'],
  ['Shift+Tab', 'workspace.pane_previous'], ['H', 'workspace.focus_left'], ['J', 'workspace.focus_down'],
  ['K', 'workspace.focus_up'], ['L', 'workspace.focus_right'], ['C', 'new_thread'],
  ['V', 'workspace.split_chat_vertical'], ['Minus', 'workspace.split_chat_horizontal'],
  ['Shift+V', 'workspace.split_terminal_vertical'], ['Shift+Minus', 'workspace.split_terminal_horizontal'],
  ['X', 'workspace.close'], ['Z', 'workspace.toggle_maximize'], ['P', 'command_palette'],
  ['Shift+Slash', 'prefix.keybinds'],
]
for (let index = 1; index <= 10; index += 1) DEFAULT_NAVIGATE_ROWS.push([String(index % 10), `workspace.select.${index}`])

const KEY_ALIASES: Record<string, string> = {
  left: 'arrowleft', right: 'arrowright', up: 'arrowup', down: 'arrowdown',
  space: ' ', grave: '`', minus: '-', comma: ',', slash: '/',
  leftbracket: '[', rightbracket: ']', pageup: 'pageup', pagedown: 'pagedown',
}

function asRecord(value: unknown): Record<string, unknown> | null {
  return value && typeof value === 'object' ? value as Record<string, unknown> : null
}

export function parseAccelerator(raw: string): Accelerator | null {
  const tokens = raw.split('+').map((part) => part.trim()).filter(Boolean)
  if (tokens.length === 0) return null
  const result: Accelerator = { key: '', ctrl: false, shift: false, alt: false, meta: false, primary: false, label: raw }
  for (const token of tokens) {
    const lower = token.toLowerCase()
    if (lower === 'ctrl' || lower === 'control') result.ctrl = true
    else if (lower === 'shift') result.shift = true
    else if (lower === 'alt' || lower === 'option') result.alt = true
    else if (lower === 'meta' || lower === 'command' || lower === 'super') result.meta = true
    else if (lower === 'commandorcontrol' || lower === 'primary') result.primary = true
    else if (!result.key) result.key = KEY_ALIASES[lower] ?? lower
    else return null
  }
  return result.key ? result : null
}

function defaultTable(rows: Array<[string, string]>): PrefixBinding[] {
  return rows.flatMap(([key, action]) => {
    const parsed = parseAccelerator(key)
    return parsed ? [{ key: parsed, target: { action } }] : []
  })
}

export const DEFAULT_WEB_KEYBINDS: WebKeybindConfig = {
  directFocusLetters: {},
  prefix: {
    enabled: false,
    keys: [parseAccelerator('Ctrl+B')!],
    bindings: defaultTable(DEFAULT_PREFIX_ROWS),
    navigate: defaultTable(DEFAULT_NAVIGATE_ROWS),
  },
}

function parseAcceleratorList(raw: unknown): Accelerator[] | null {
  const values = typeof raw === 'string' ? [raw] : Array.isArray(raw) ? raw : null
  if (!values) return null
  return values.flatMap((value) => typeof value === 'string' ? [parseAccelerator(value)].filter((item): item is Accelerator => item != null) : [])
}

function parseCommandPlacement(raw: unknown): PrefixCommandPlacement | null {
  if (typeof raw !== 'string') return null
  const aliases: Record<string, PrefixCommandPlacement> = {
    background: 'background',
    detached: 'background',
    terminal: 'terminal',
    current: 'terminal',
    focused: 'terminal',
    pane: 'pane',
    new_pane: 'pane',
    'new-pane': 'pane',
    new: 'pane',
    split: 'split_horizontal',
    horizontal: 'split_horizontal',
    split_horizontal: 'split_horizontal',
    'split-horizontal': 'split_horizontal',
    vertical: 'split_vertical',
    split_vertical: 'split_vertical',
    'split-vertical': 'split_vertical',
    floating: 'floating',
    float: 'floating',
    quick: 'floating',
    tab: 'tab',
  }
  return aliases[raw.trim().toLowerCase()] ?? null
}

function parseTarget(raw: unknown): PrefixTarget | null {
  if (typeof raw === 'string') return raw.trim() ? { action: raw.trim() } : null
  const record = asRecord(raw)
  if (typeof record?.command === 'string' && record.command.trim()) {
    const command = record.command.trim()
    const placement_raw = record.in ?? record.open
    if (placement_raw === undefined) return { command }
    const placement = parseCommandPlacement(placement_raw)
    if (!placement) return null
    return placement === 'background' ? { command } : { command, in: placement }
  }
  if (typeof record?.action === 'string' && record.action.trim()) return { action: record.action.trim() }
  return null
}

function applyTableOverrides(base: PrefixBinding[], raw: unknown): PrefixBinding[] {
  const record = asRecord(raw)
  if (!record) return base
  const next = [...base]
  for (const [label, value] of Object.entries(record)) {
    const key = parseAccelerator(label)
    if (!key) continue
    const index = next.findIndex((binding) => acceleratorsEqual(binding.key, key))
    if (index >= 0) next.splice(index, 1)
    const target = parseTarget(value)
    if (target) next.push({ key, target })
  }
  return next
}

function directFocusLetters(root: Record<string, unknown> | null): WebKeybindConfig['directFocusLetters'] {
  const workspace = asRecord(asRecord(root?.keybinds)?.workspace)
  const result: WebKeybindConfig['directFocusLetters'] = {}
  const directions: Array<['left' | 'down' | 'up' | 'right', KeyAction]> = [
    ['left', 'focus_left'], ['down', 'focus_down'], ['up', 'focus_up'], ['right', 'focus_right'],
  ]
  for (const [direction, action] of directions) {
    for (const accelerator of parseAcceleratorList(workspace?.[`focus_${direction}`]) ?? []) {
      if (accelerator.ctrl && !accelerator.shift && !accelerator.alt && !accelerator.meta && /^[hjkl]$/.test(accelerator.key)) {
        result[accelerator.key as 'h' | 'j' | 'k' | 'l'] = action
      }
    }
  }
  return result
}

export function parseWebKeybindConfig(raw: unknown): WebKeybindConfig {
  const root = asRecord(raw)
  const value = asRecord(root?.keybinds)?.prefix
  let enabled = false
  let keys = [...DEFAULT_WEB_KEYBINDS.prefix.keys]
  let bindings = [...DEFAULT_WEB_KEYBINDS.prefix.bindings]
  let navigate = [...DEFAULT_WEB_KEYBINDS.prefix.navigate]
  if (typeof value === 'boolean') enabled = value
  else if (typeof value === 'string') {
    keys = parseAcceleratorList(value) ?? keys
    enabled = keys.length > 0
  } else {
    const prefix = asRecord(value)
    if (prefix) {
      enabled = prefix.enabled === true
      keys = parseAcceleratorList(prefix.key) ?? keys
      if (prefix.defaults === false) {
        bindings = []
        navigate = []
      }
      bindings = applyTableOverrides(bindings, prefix.bindings)
      navigate = applyTableOverrides(navigate, prefix.navigate)
    }
  }
  return { directFocusLetters: directFocusLetters(root), prefix: { enabled: enabled && keys.length > 0, keys, bindings, navigate } }
}

export function acceleratorsEqual(a: Accelerator, b: Accelerator): boolean {
  return a.key === b.key && a.ctrl === b.ctrl && a.shift === b.shift && a.alt === b.alt && a.meta === b.meta && a.primary === b.primary
}

function eventKey(event: KeyboardEvent): string {
  if (/^Digit[0-9]$/.test(event.code)) return event.code.slice(-1)
  const physical: Record<string, string> = {
    Slash: '/', Minus: '-', Comma: ',', Backquote: '`', BracketLeft: '[', BracketRight: ']',
  }
  return physical[event.code] ?? event.key.toLowerCase()
}

export function acceleratorMatches(accelerator: Accelerator, event: KeyboardEvent): boolean {
  const primary = event.ctrlKey || event.metaKey
  const modifiersMatch = accelerator.primary
    ? primary && !accelerator.ctrl && !accelerator.meta
    : accelerator.ctrl === event.ctrlKey && accelerator.meta === event.metaKey
  return accelerator.key === eventKey(event) && modifiersMatch &&
    accelerator.shift === event.shiftKey && accelerator.alt === event.altKey
}

export function findPrefixBinding(bindings: PrefixBinding[], event: KeyboardEvent): PrefixBinding | null {
  return bindings.find((binding) => acceleratorMatches(binding.key, event)) ?? null
}

function isEditableTarget(target: EventTarget | null): boolean {
  if (!(target instanceof HTMLElement)) return false
  const tag = target.tagName
  return tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT' || target.isContentEditable
}

export function matchKeyAction(event: KeyboardEvent, config: WebKeybindConfig = DEFAULT_WEB_KEYBINDS): KeyAction | null {
  if (event.key === 'Escape') return 'escape'
  if (event.key === 'Tab' && !event.ctrlKey && !event.metaKey && !event.altKey && !isEditableTarget(event.target)) return 'focus_prompt'

  const key = event.key.toLowerCase()
  const configuredFocus = event.ctrlKey && !event.metaKey && !event.shiftKey && !event.altKey
    ? config.directFocusLetters[key as 'h' | 'j' | 'k' | 'l']
    : undefined
  if (configuredFocus) return configuredFocus

  const ctrl = event.ctrlKey || event.metaKey
  const shift = event.shiftKey
  const alt = event.altKey
  const meta = event.metaKey && !event.ctrlKey
  const isChord = ctrl || alt || meta || (shift && event.key === 'Tab')
  if (!isChord) return null

  for (const chord of DIRECT_CHORDS) {
    if (chord.key !== key) continue
    if (Boolean(chord.ctrl) !== ctrl || Boolean(chord.shift) !== shift || Boolean(chord.alt) !== alt) continue
    return chord.action
  }
  return null
}

export function prefixTargetLabel(target: PrefixTarget): string {
  if ('command' in target) {
    const placement = target.in && target.in !== 'background'
      ? ({
          terminal: 'terminal',
          pane: 'pane',
          split_horizontal: 'split -',
          split_vertical: 'split |',
          floating: 'floating',
          tab: 'tab',
        } as const)[target.in]
      : ''
    return placement ? `$ ${target.command} · ${placement}` : `$ ${target.command}`
  }
  const ordinal = /workspace\.(pane_select|active_select|select)\.(\d+)$/.exec(target.action)
  if (ordinal) return `${ordinal[1] === 'select' ? 'Workspace' : ordinal[1] === 'pane_select' ? 'Pane' : 'Active row'} ${ordinal[2]}`
  return ({
    'prefix.keybinds': 'Keybinds', 'prefix.navigate': 'Workspace nav', command_palette: 'Command palette',
    new_thread: 'New thread', sidebar: 'Sidebar', sidebar_hidden: 'Hide sidebar',
    'workspace.close': 'Close pane', 'workspace.close_current': 'Close workspace',
    'workspace.toggle_maximize': 'Zoom pane', 'workspace.focus_prompt': 'Focus prompt',
    'workspace.split_chat_vertical': 'Chat split |', 'workspace.split_chat_horizontal': 'Chat split -',
    'workspace.split_terminal_vertical': 'Term split |', 'workspace.split_terminal_horizontal': 'Term split -',
    'workspace.split_default_vertical': 'Default split |', 'workspace.split_default_horizontal': 'Default split -',
    'workspace.split_alternate_vertical': 'Alternate split |', 'workspace.split_alternate_horizontal': 'Alternate split -',
    'workspace.focus_left': 'Focus left', 'workspace.focus_right': 'Focus right',
    'workspace.focus_up': 'Focus up', 'workspace.focus_down': 'Focus down',
    'workspace.previous': 'Prev workspace', 'workspace.next': 'Next workspace',
    'workspace.pane_previous': 'Prev pane', 'workspace.pane_next': 'Next pane',
  } as Record<string, string>)[target.action] ?? target.action.replaceAll('.', ' ')
}
