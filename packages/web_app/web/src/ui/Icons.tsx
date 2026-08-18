import { store } from '../lib/store'
import type { LivePane } from '../lib/types'

import logoMaskUrl from '../../../../desktop/src/assets/verde_logo_mask.png'
import openaiUrl from '../../../../desktop/src/assets/OpenAI-white-monoblossom.png'
import claudeUrl from '../../../../desktop/src/assets/claude-logo.png'
import opencodeUrl from '../../../../desktop/src/assets/opencode-logo-dark.png'
import cursorUrl from '../../../../desktop/src/assets/editor_logos/cursor.png'
import grokUrl from '../../../../desktop/src/assets/grok-logo.png'
import ampUrl from '../../../../desktop/src/assets/amp-logo.png'

export function VerdeLogo(props: { class?: string }) {
  return (
    <span
      aria-label="Verde"
      class={`inline-block shrink-0 bg-[var(--accent)] ${props.class ?? 'h-7 w-7'}`}
      role="img"
      style={{
        'mask-image': `url(${logoMaskUrl})`,
        'mask-position': 'center',
        'mask-repeat': 'no-repeat',
        'mask-size': 'contain',
        '-webkit-mask-image': `url(${logoMaskUrl})`,
        '-webkit-mask-position': 'center',
        '-webkit-mask-repeat': 'no-repeat',
        '-webkit-mask-size': 'contain',
      }}
    />
  )
}

export function ProviderGlyph(props: { provider?: string; class?: string }) {
  const src = () => {
    switch ((props.provider ?? '').toLowerCase()) {
      case 'codex':
      case 'openai':
        return openaiUrl
      case 'claude':
        return claudeUrl
      case 'opencode':
        return opencodeUrl
      case 'cursor':
        return cursorUrl
      case 'grok':
        return grokUrl
      case 'amp':
        return ampUrl
      default:
        return null
    }
  }
  const href = src()
  if (href) {
    return <img src={href} alt="" class={props.class ?? 'h-[18px] w-[18px] object-contain opacity-90'} />
  }
  return <Icon name="chat" class={props.class ?? 'h-[22px] w-[22px] text-[var(--text-subtle)]'} />
}

export function Icon(props: { name: string; class?: string }) {
  const paths: Record<string, string> = {
    search: 'M11 7.2a3.8 3.8 0 1 0 0 7.6 3.8 3.8 0 0 0 0-7.6z M14.2 14.2 L17.4 17.4',
    plus: 'M12 7v10 M7 12h10',
    collapse: 'M14 7l-5 5 5 5',
    expand: 'M10 7l5 5-5 5',
    chevron: 'M9 8l4 4-4 4',
    chevronDown: 'M8 9l4 4 4-4',
    folder: 'M4 8h6l2 2h8v8H4z',
    settings: 'M12 8.4a3.6 3.6 0 1 0 0 7.2 3.6 3.6 0 0 0 0-7.2z M12 4v1.6 M12 18.4V20 M5.2 6.4l1.2.9 M17.6 16.7l1.2.9 M4 12h1.6 M18.4 12H20 M5.2 17.6l1.2-.9 M17.6 7.3l1.2-.9',
    terminal: 'M5 7h14v10H5z M7.5 10l2.2 2-2.2 2 M11.5 14h4',
    chat: 'M6 7h12v8H9l-3 2.4z',
    send: 'M12 16V8.5 M8 12l4-4 4 4',
    history: 'M7 12a5 5 0 1 0 1.4-3.4 M7 7.5V9.8h2.2',
    more: 'M7 12h.01 M12 12h.01 M17 12h.01',
    menu: 'M6 8h12 M6 12h12 M6 16h12',
    close: 'M7 7l10 10 M17 7 7 17',
    zoom: 'M9 5H5v4 M19 9V5h-4 M5 15v4h4 M15 19h4v-4',
    unzoom: 'M9 5v4H5 M15 5v4h4 M9 19v-4H5 M15 19v-4h4',
    lock: 'M8 11h8v7H8z M9.4 11V8.8a2.6 2.6 0 0 1 5.2 0V11',
  }
  return (
    <svg class={props.class ?? 'h-4 w-4'} viewBox="0 0 24 24" aria-hidden="true">
      <path
        d={paths[props.name] ?? ''}
        fill="none"
        stroke="currentColor"
        stroke-width="1.7"
        stroke-linecap="round"
        stroke-linejoin="round"
      />
    </svg>
  )
}

// Pane-header zoom toggle; lives here so terminal and chat headers share one
// control without a WorkspaceCanvas <-> ChatPane import cycle.
export function ZoomButton(props: { pane: LivePane }) {
  const zoomed = () => store.maximizedPaneId() === props.pane.pane_id
  return (
    <button
      type="button"
      class="grid h-7 w-7 shrink-0 place-items-center rounded-[6px] text-[var(--text-muted)] hover:bg-[var(--panel-alt)] hover:text-[var(--text)]"
      title={zoomed() ? 'Unzoom pane (Alt+Z)' : 'Zoom pane (Alt+Z)'}
      aria-pressed={zoomed()}
      onClick={() => void store.maximizePane(props.pane)}
    >
      <Icon name={zoomed() ? 'unzoom' : 'zoom'} class="h-4 w-4" />
    </button>
  )
}

export function StatusPip(props: { active?: boolean }) {
  return (
    <span
      class={`inline-block h-1.5 w-1.5 shrink-0 rounded-full ${props.active ? 'bg-[var(--accent)] pulse' : 'bg-[var(--text-subtle)]'}`}
    />
  )
}
