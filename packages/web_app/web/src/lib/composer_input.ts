/// Prompt-box key policy. The textarea should stay a normal multiline field
/// until an explicit send; only a physical-keyboard Enter submits.

export interface ComposerKeyEvent {
  key: string
  shiftKey: boolean
  defaultPrevented?: boolean
  isComposing?: boolean
  keyCode?: number
}

export function composerEnterShouldSubmit(
  event: ComposerKeyEvent,
  options: { compact: boolean; coarsePointer: boolean },
): boolean {
  if (event.defaultPrevented) return false
  if (event.key !== 'Enter') return false
  if (event.shiftKey) return false
  // IME / soft-keyboard composition (iOS autocorrect, CJK candidates).
  if (event.isComposing || event.keyCode === 229) return false
  // Phone and tablet Return keys insert a newline; the send button submits.
  if (options.compact || options.coarsePointer) return false
  return true
}
