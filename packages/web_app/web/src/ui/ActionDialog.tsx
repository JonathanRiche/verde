import { For, Show, createEffect, createSignal } from 'solid-js'
import { Portal } from 'solid-js/web'
import { store } from '../lib/store'

/// One store-driven form for multi-choice actions (handoff target, thread
/// import). The store awaits the result; Cancel/Escape resolves null.
export function ActionDialog() {
  return (
    <Show when={store.actionDialog()} keyed>
      {(request) => {
        const [values, setValues] = createSignal<Record<string, string>>(
          Object.fromEntries(request.fields.map((field) => [field.key, field.initial ?? field.options?.[0]?.value ?? ''])),
        )
        let form!: HTMLFormElement
        createEffect(() => queueMicrotask(() => form?.querySelector<HTMLElement>('input, select, button[type=submit]')?.focus()))
        const close = () => store.resolveActionDialog(null)
        return (
          <Portal>
            <div class="anim-fade fixed inset-0 z-[60] grid place-items-center bg-black/60 p-4" onPointerDown={close}>
              <form
                ref={form}
                class="anim-pop w-full max-w-[460px] rounded-[14px] border border-[var(--border-muted)] bg-[var(--panel-alt)] p-5 shadow-[0_24px_70px_rgba(0,0,0,0.55)]"
                onPointerDown={(event) => event.stopPropagation()}
                onKeyDown={(event) => { if (event.key === 'Escape') { event.preventDefault(); close() } }}
                onSubmit={(event) => { event.preventDefault(); store.resolveActionDialog(values()) }}
              >
                <div class="wordmark text-[20px] text-[var(--text)]">{request.title}</div>
                <Show when={request.description}>
                  <p class="mt-2 text-[12px] leading-[1.45] text-[var(--text-subtle)]">{request.description}</p>
                </Show>
                <For each={request.fields}>
                  {(field) => (
                    <label class="mt-4 block">
                      <span class="block text-[11px] font-bold uppercase tracking-[0.08em] text-[var(--text-subtle)]">{field.label}</span>
                      <Show
                        when={field.options}
                        fallback={
                          <input
                            class="mt-2 h-11 w-full rounded-[8px] border border-[var(--border-muted)] bg-[var(--chat-black)] px-3 text-[14px] text-[var(--text)] outline-none focus:border-[var(--accent)]"
                            placeholder={field.placeholder}
                            value={values()[field.key] ?? ''}
                            onInput={(event) => { const value = event.currentTarget.value; setValues((prev) => ({ ...prev, [field.key]: value })) }}
                          />
                        }
                      >
                        {(options) => (
                          <select
                            class="mt-2 h-11 w-full rounded-[8px] border border-[var(--border-muted)] bg-[var(--chat-black)] px-3 text-[14px] text-[var(--text)] outline-none focus:border-[var(--accent)]"
                            value={values()[field.key]}
                            onChange={(event) => { const value = event.currentTarget.value; setValues((prev) => ({ ...prev, [field.key]: value })) }}
                          >
                            <For each={options()}>{(option) => <option value={option.value}>{option.label}</option>}</For>
                          </select>
                        )}
                      </Show>
                    </label>
                  )}
                </For>
                <div class="mt-5 flex justify-end gap-2">
                  <button type="button" class="h-9 rounded-[7px] px-3 text-[13px] text-[var(--text-muted)] hover:bg-white/5" onClick={close}>
                    Cancel
                  </button>
                  <button
                    type="submit"
                    disabled={request.fields.some((field) => field.options ? field.options.length === 0 : !(values()[field.key] ?? '').trim())}
                    class="h-9 rounded-[7px] bg-[var(--accent)] px-4 text-[13px] font-bold text-[#0d1213] hover:bg-[var(--accent-hi)] disabled:cursor-not-allowed disabled:opacity-40"
                  >
                    {request.submitLabel ?? 'Continue'}
                  </button>
                </div>
              </form>
            </div>
          </Portal>
        )
      }}
    </Show>
  )
}
