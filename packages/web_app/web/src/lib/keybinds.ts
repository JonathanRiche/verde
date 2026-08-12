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

interface Chord {
  key: string
  ctrl?: boolean
  shift?: boolean
  alt?: boolean
  meta?: boolean
  action: KeyAction
}

const CHORDS: Chord[] = [
  { key: 'p', ctrl: true, shift: true, action: 'command_palette' },
  { key: 's', ctrl: true, action: 'toggle_sidebar' },
  { key: 's', ctrl: true, shift: true, action: 'toggle_sidebar_hidden' },
  { key: 't', ctrl: true, action: 'new_thread' },
  { key: 't', ctrl: true, alt: true, action: 'new_terminal' },
  { key: 'w', ctrl: true, action: 'close_pane' },
  { key: 'x', alt: true, action: 'close_pane' },
  { key: 'arrowup', alt: true, action: 'workspace_previous' },
  { key: 'arrowdown', alt: true, action: 'workspace_next' },
  { key: 'tab', ctrl: true, action: 'pane_next' },
  { key: 'tab', ctrl: true, shift: true, action: 'pane_previous' },
  { key: 'h', ctrl: true, action: 'focus_left' },
  { key: 'arrowleft', ctrl: true, action: 'focus_left' },
  { key: 'l', ctrl: true, action: 'focus_right' },
  { key: 'arrowright', ctrl: true, action: 'focus_right' },
  { key: 'k', ctrl: true, action: 'focus_up' },
  { key: 'arrowup', ctrl: true, action: 'focus_up' },
  { key: 'j', ctrl: true, action: 'focus_down' },
  { key: 'arrowdown', ctrl: true, action: 'focus_down' },
  { key: 'z', alt: true, action: 'maximize' },
  { key: ',', ctrl: true, action: 'settings' },
]

for (let index = 0; index <= 9; index += 1) {
  CHORDS.push({ key: String(index), ctrl: true, action: { kind: 'pane_select', index: index === 0 ? 9 : index - 1 } })
  CHORDS.push({ key: String(index), alt: true, action: { kind: 'workspace_select', index: index === 0 ? 9 : index - 1 } })
  CHORDS.push({
    key: String(index),
    ctrl: true,
    shift: true,
    action: { kind: 'active_select', index: index === 0 ? 9 : index - 1 },
  })
}

function isEditableTarget(target: EventTarget | null): boolean {
  if (!(target instanceof HTMLElement)) return false
  const tag = target.tagName
  return tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT' || target.isContentEditable
}

export function matchKeyAction(event: KeyboardEvent): KeyAction | null {
  if (event.key === 'Escape') return 'escape'
  if (event.key === 'Tab' && !event.ctrlKey && !event.metaKey && !event.altKey && !isEditableTarget(event.target)) {
    return 'focus_prompt'
  }

  const key = event.key.toLowerCase()
  const ctrl = event.ctrlKey || event.metaKey
  const shift = event.shiftKey
  const alt = event.altKey
  const meta = event.metaKey && !event.ctrlKey

  // Typing in a field should still receive bare keys; chords always win.
  const isChord = ctrl || alt || meta || (shift && event.key === 'Tab')
  if (!isChord) return null

  for (const chord of CHORDS) {
    if (chord.key !== key) continue
    if (Boolean(chord.ctrl) !== ctrl) continue
    if (Boolean(chord.shift) !== shift) continue
    if (Boolean(chord.alt) !== alt) continue
    return chord.action
  }
  return null
}
