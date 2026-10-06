import { Show, createMemo } from 'solid-js'

import { store } from '../lib/store'
import { themeTone } from '../lib/theme'
import type { LivePane, Workspace } from '../lib/types'
import { workspaceIdentity } from '../lib/workspace_identity'

import logoMaskUrl from '../../../../desktop/src/assets/verde_logo_mask.png'
import openaiUrl from '../../../../desktop/src/assets/OpenAI-white-monoblossom.png'
import claudeUrl from '../../../../desktop/src/assets/claude-logo.png'
import opencodeUrl from '../../../../desktop/src/assets/opencode-logo-dark.png'
import cursorUrl from '../../../../desktop/src/assets/editor_logos/cursor.png'
import grokUrl from '../../../../desktop/src/assets/grok-logo.png'
import piUrl from '../../../../desktop/src/assets/pi-logo.png'
import fxUrl from '../../../../desktop/src/assets/fx-logo.png'
import ampUrl from '../../../../desktop/src/assets/amp-logo.png'
import museUrl from '../../../../desktop/src/assets/muse-logo.png'

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
      case 'pi':
        return piUrl
      case 'fx':
        return fxUrl
      case 'amp':
        return ampUrl
      case 'muse':
        return museUrl
      default:
        return null
    }
  }
  // Keep the asset lookup inside Solid's reactive graph. ProviderGlyph stays
  // mounted in the composer, pane header, and sidebar while an optimistic
  // provider change updates its prop; resolving `src()` once at mount left
  // all three locations displaying the previous provider's logo.
  return (
    <Show
      when={src()}
      fallback={<Icon name="chat" class={props.class ?? 'h-[22px] w-[22px] text-[var(--text-subtle)]'} />}
    >
      {(href) => (
        <img src={href()} alt="" class={props.class ?? 'h-[18px] w-[18px] object-contain opacity-90'} />
      )}
    </Show>
  )
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
    check: 'M6.5 12.5l3.5 3.5 7.5-8',
    zoom: 'M9 5H5v4 M19 9V5h-4 M5 15v4h4 M15 19h4v-4',
    unzoom: 'M9 5v4H5 M15 5v4h4 M9 19v-4H5 M15 19v-4h4',
    lock: 'M8 11h8v7H8z M9.4 11V8.8a2.6 2.6 0 0 1 5.2 0V11',
    paperclip: 'M8.5 12.5l5.8-5.8a3 3 0 0 1 4.2 4.2l-7.2 7.2a4.5 4.5 0 0 1-6.4-6.4l7-7 M9.2 14.8l6.6-6.6',
    layers: 'M12 4.5l7.5 3.8-7.5 3.8-7.5-3.8z M4.5 12.2l7.5 3.8 7.5-3.8 M4.5 15.9l7.5 3.8 7.5-3.8',
    // Workspace identity set (lib/workspace_identity.ts WORKSPACE_ICONS order).
    'ws-folder': 'M4 8h6l2 2h8v8H4z',
    'ws-rocket': 'M12 4c2.6 1.8 4 4.8 4 8.2V15H8v-2.8C8 8.8 9.4 5.8 12 4z M8 12.5l-2.5 2.5v2.5H8 M16 12.5l2.5 2.5v2.5H16 M11 18.5h2 M12 9h.01',
    'ws-flask': 'M10 4h4 M10.5 4v5L6 17.5a1 1 0 0 0 .9 1.5h10.2a1 1 0 0 0 .9-1.5L13.5 9V4 M8 14h8',
    'ws-leaf': 'M6 18c0-7 4-12 12-12 0 8-5 12-12 12z M6 18l6-6',
    'ws-bolt': 'M13 4L6.5 13H12l-1 7 6.5-9H12z',
    'ws-star': 'M12 4.5l2.3 4.7 5.2.8-3.8 3.7.9 5.2-4.6-2.4-4.6 2.4.9-5.2-3.8-3.7 5.2-.8z',
    'ws-flame': 'M12 4c.5 3 4.5 5 4.5 9a4.5 4.5 0 0 1-9 0c0-2 1-3.5 2-4.5.3 1.5 1 2.5 2 2.5 0-2.5-.5-5 .5-7z',
    'ws-cube': 'M12 4l7 4v8l-7 4-7-4V8z M5 8l7 4 7-4 M12 12v8',
    'ws-code': 'M9 8l-4 4 4 4 M15 8l4 4-4 4 M13.5 6.5l-3 11',
    'ws-terminal': 'M5 7h14v10H5z M7.5 10l2.2 2-2.2 2 M11.5 14h4',
    'ws-globe': 'M12 4.5a7.5 7.5 0 1 0 0 15 7.5 7.5 0 0 0 0-15z M4.5 12h15 M12 4.5c2.2 2.3 3 4.8 3 7.5s-.8 5.2-3 7.5c-2.2-2.3-3-4.8-3-7.5s.8-5.2 3-7.5z',
    'ws-heart': 'M12 18.5S5 14.5 5 9.6A3.4 3.4 0 0 1 12 8a3.4 3.4 0 0 1 7 1.6c0 4.9-7 8.9-7 8.9z',
    'ws-moon': 'M18 14.5A7 7 0 0 1 9.5 6a7 7 0 1 0 8.5 8.5z',
    'ws-sun': 'M12 9a3 3 0 1 0 0 6 3 3 0 0 0 0-6z M12 4v2 M12 18v2 M4 12h2 M18 12h2 M6.3 6.3l1.4 1.4 M16.3 16.3l1.4 1.4 M6.3 17.7l1.4-1.4 M16.3 7.7l1.4-1.4',
    'ws-compass': 'M12 4.5a7.5 7.5 0 1 0 0 15 7.5 7.5 0 0 0 0-15z M14.8 9.2l-1.6 4-4 1.6 1.6-4z',
    'ws-puzzle': 'M5 9h3a2 2 0 1 1 4 0h3v3a2 2 0 1 1 0 4v3H5v-3.5a2 2 0 1 0 0-4z',
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

/// Workspace identity chip: the workspace's icon drawn in its theme-derived
/// slot color on a square tinted with that color. User-chosen slots on the
/// row override the hash-derived ones.
export function WorkspaceGlyph(props: {
  workspace: Pick<Workspace, 'workspace_id' | 'icon_index' | 'color_index'>
  class?: string
  iconClass?: string
  dim?: boolean
}) {
  const identity = createMemo(() =>
    workspaceIdentity(props.workspace.workspace_id, themeTone().accent, themeTone().dark, props.workspace))
  return (
    <span
      class={`grid shrink-0 place-items-center rounded-[5px] ${props.class ?? 'h-5 w-5'} ${props.dim ? 'opacity-50' : ''}`}
      style={{ color: identity().color, background: `${identity().color}2e` }}
      aria-hidden="true"
    >
      <Icon name={`ws-${identity().icon}`} class={props.iconClass ?? 'h-3.5 w-3.5'} />
    </span>
  )
}

/// Indeterminate progress ring (git actions).
export function Spinner(props: { class?: string }) {
  return (
    <svg class={`animate-spin shrink-0 ${props.class ?? 'h-4 w-4'}`} viewBox="0 0 24 24" aria-hidden="true">
      <circle cx="12" cy="12" r="8" fill="none" stroke="currentColor" stroke-opacity="0.25" stroke-width="2.2" />
      <path d="M20 12a8 8 0 0 0-8-8" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" />
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
