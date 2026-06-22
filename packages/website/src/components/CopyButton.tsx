import { createSignal, onCleanup } from 'solid-js'

/* ───────────────────────── Glyphs ───────────────────────── */

function ClipboardGlyph() {
  return (
    <svg class="copy-svg" viewBox="0 0 24 24" aria-hidden="true">
      <path
        fill="none"
        stroke="currentColor"
        stroke-width="2"
        stroke-linecap="round"
        stroke-linejoin="round"
        d="M8 7V5a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2m4 0v10a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V7h16Z"
      />
    </svg>
  )
}

function CheckGlyph() {
  return (
    <svg class="copy-svg" viewBox="0 0 24 24" aria-hidden="true">
      <path
        fill="none"
        stroke="currentColor"
        stroke-width="2.5"
        stroke-linecap="round"
        stroke-linejoin="round"
        d="M5 13l4 4L19 7"
      />
    </svg>
  )
}

/* ───────────────────────── Copy button ───────────────────────── */

export interface CopyButtonProps {
  command: string
  size?: 'sm' | 'md'
  /** Optional accessible label prefix; defaults to "Copy to clipboard". */
  label?: string
}

/**
 * Copy-to-clipboard button. Renders a hidden `<input>` so the legacy
 * `document.execCommand('copy')` path has something to select, with
 * `navigator.clipboard.writeText` as a fallback. The check state auto-resets
 * after 2 seconds.
 */
export default function CopyButton(props: CopyButtonProps) {
  const [copied, setCopied] = createSignal(false)
  let copyTimer: ReturnType<typeof setTimeout> | undefined
  let sourceInput: HTMLInputElement | undefined

  onCleanup(() => {
    if (copyTimer !== undefined) clearTimeout(copyTimer)
  })

  function showCopied() {
    setCopied(true)
    if (copyTimer !== undefined) clearTimeout(copyTimer)
    copyTimer = setTimeout(() => setCopied(false), 2000)
  }

  function handleCopy(ev: MouseEvent) {
    ev.preventDefault()
    ev.stopPropagation()
    const el = sourceInput
    if (el) {
      el.focus()
      el.select()
      el.setSelectionRange(0, el.value.length)
      try {
        if (document.execCommand('copy')) {
          showCopied()
          return
        }
      } catch {
        /* fall through */
      }
    }
    if (navigator.clipboard?.writeText) {
      void navigator.clipboard
        .writeText(props.command)
        .then(() => showCopied(), () => {})
    }
  }

  const baseLabel = props.label ?? 'Copy to clipboard'

  return (
    <span class="copy-wrap">
      <input
        ref={(el) => {
          sourceInput = el
        }}
        type="text"
        class="copy-source"
        readOnly
        tabIndex={-1}
        aria-hidden="true"
        value={props.command}
      />
      <button
        type="button"
        class={`copy-btn copy-btn--${props.size ?? 'md'}${copied() ? ' copy-btn--done' : ''}`}
        onClick={handleCopy}
        aria-label={copied() ? 'Copied to clipboard' : baseLabel}
      >
        {copied() ? <CheckGlyph /> : <ClipboardGlyph />}
      </button>
    </span>
  )
}
