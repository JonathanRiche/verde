import { Show } from 'solid-js'

/// Centred empty/error state for side panel views, with an optional action.
export function PanelMessage(props: { text: string; action?: { label: string; run: () => void } }) {
  return (
    <div class="grid place-items-center px-6 py-10 text-center">
      <div>
        <p class="text-[13px] text-[var(--text-muted)]">{props.text}</p>
        <Show when={props.action}>
          {(action) => (
            <button type="button" class="mt-3 rounded-[7px] border border-[var(--border-muted)] px-3 py-1.5 text-[12px] text-[var(--text)] hover:bg-[var(--accent-hover)]" onClick={() => action().run()}>
              {action().label}
            </button>
          )}
        </Show>
      </div>
    </div>
  )
}
