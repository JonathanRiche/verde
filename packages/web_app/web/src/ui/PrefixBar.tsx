import { For, Show } from 'solid-js'

import { prefixTargetLabel, type PrefixBinding } from '../lib/keybinds'
import { store } from '../lib/store'

function displayKey(label: string): string {
  return label
    .replace('Shift+Slash', '?')
    .replace('LeftBracket', '[')
    .replace('RightBracket', ']')
    .replace('Minus', '-')
    .replace('Grave', '`')
}

function Hint(props: { keyLabel: string; label: string }) {
  return (
    <span class="prefix-hint">
      <kbd>{displayKey(props.keyLabel)}</kbd>
      <span>{props.label}</span>
    </span>
  )
}

export function PrefixBar() {
  const mode = () => store.prefixMode()
  const bindings = (): PrefixBinding[] =>
    mode() === 'navigate' ? store.keybindConfig().prefix.navigate : store.keybindConfig().prefix.bindings
  const prefixLabel = () => store.keybindConfig().prefix.keys[0]?.label ?? 'Ctrl+B'
  const actionKey = (action: string) => {
    const binding = bindings().find((row) => 'action' in row.target && row.target.action === action)
    return binding ? displayKey(binding.key.label) : ''
  }

  return (
    <Show when={mode()}>
      <div class="prefix-layer" aria-live="polite">
        <Show when={store.prefixHelpVisible()}>
          <section class="prefix-which-key" aria-label="Prefix keybinds">
            <div class="prefix-which-key-title">
              <span>{mode() === 'navigate' ? 'Navigate keybinds' : 'Prefix keybinds'}</span>
              <span>{bindings().length} commands</span>
            </div>
            <div class="prefix-key-grid scrollbar-thin">
              <For each={bindings()}>
                {(binding) => (
                  <div class="prefix-key-row">
                    <kbd>{displayKey(binding.key.label)}</kbd>
                    <span title={prefixTargetLabel(binding.target)}>{prefixTargetLabel(binding.target)}</span>
                  </div>
                )}
              </For>
            </div>
          </section>
        </Show>
        <div class="prefix-status-bar">
          <span class="prefix-chevron">»</span>
          <strong>{mode() === 'navigate' ? 'NAVIGATE' : 'PREFIX'}</strong>
          <Show
            when={mode() === 'navigate'}
            fallback={
              <>
                <Hint keyLabel="Esc" label="cancel" />
                <Hint keyLabel={prefixLabel()} label="send prefix" />
                <Show when={actionKey('prefix.navigate')} keyed>
                  {(key) => <Hint keyLabel={key} label="workspace nav" />}
                </Show>
              </>
            }
          >
            <Hint keyLabel="Esc" label="back" />
            <Hint keyLabel="Up / Down" label="workspace" />
            <Hint keyLabel="Tab" label="pane" />
          </Show>
          <Show when={actionKey('prefix.keybinds')} keyed>
            {(key) => <Hint keyLabel={key} label={store.prefixHelpVisible() ? 'hide keybinds' : 'keybinds'} />}
          </Show>
        </div>
      </div>
    </Show>
  )
}
