import { Show, createSignal, onCleanup, onMount } from 'solid-js'
import type RFB from '@novnc/novnc'

const [desktopOpen, setDesktopOpen] = createSignal(false)
export const desktopViewerOpen = desktopOpen
export const openDesktopViewer = () => setDesktopOpen(true)

export function DesktopViewer() {
  return <Show when={desktopOpen()}><DesktopSession onClose={() => setDesktopOpen(false)} /></Show>
}

function DesktopSession(props: { onClose: () => void }) {
  let target!: HTMLDivElement
  let dialog!: HTMLDialogElement
  let passwordInput: HTMLInputElement | undefined
  let usernameInput: HTMLInputElement | undefined
  let rfb: RFB | undefined
  let generation = 0
  let sentCredentials: { username?: string; password?: string } | undefined
  const clearCredentials = () => {
    if (passwordInput) passwordInput.value = ''
    if (usernameInput) usernameInput.value = ''
    passwordInput = undefined
    usernameInput = undefined
    if (sentCredentials) {
      delete sentCredentials.password
      delete sentCredentials.username
      sentCredentials = undefined
    }
  }
  const restoreFocus = document.activeElement
  const [state, setState] = createSignal<'loading' | 'disabled' | 'ready' | 'connecting' | 'connected' | 'disconnected' | 'error'>('loading')
  const [message, setMessage] = createSignal('Checking desktop availability…')
  const [control, setControl] = createSignal(false)
  const [credentials, setCredentials] = createSignal<string[]>([])
  const [name, setName] = createSignal('Host desktop')
  const buttonClass = 'rounded-[7px] border border-[var(--border-muted)] px-3 py-1.5 text-[13px] hover:bg-[var(--accent-row)] disabled:opacity-40'

  const disconnect = () => {
    generation++
    clearCredentials()
    rfb?.disconnect()
    rfb = undefined
    setCredentials([])
    setControl(false)
    setState('disconnected')
    setMessage('Disconnected. You can reconnect when ready.')
  }

  const connect = async () => {
    disconnect()
    const current = generation
    setState('connecting')
    setMessage('Connecting to the host desktop…')
    try {
      const { default: Client } = await import('@novnc/novnc')
      if (current !== generation) return
      target.replaceChildren()
      const url = new URL('/ws/desktop', window.location.href)
      url.protocol = url.protocol === 'https:' ? 'wss:' : 'ws:'
      const client = new Client(target, url.href, { shared: true })
      rfb = client
      client.viewOnly = true
      client.scaleViewport = true
      client.resizeSession = false
      const active = () => current === generation && rfb === client
      client.addEventListener('connect', () => {
        if (!active()) return
        clearCredentials()
        setState('connected')
        setMessage('Viewing the host desktop. Enable control to use its mouse and keyboard.')
      })
      client.addEventListener('disconnect', () => {
        if (!active()) return
        clearCredentials()
        rfb = undefined
        setCredentials([])
        setControl(false)
        setState('disconnected')
        setMessage('Desktop disconnected. Check that sharing is running and no other viewer is connected; your login may also have expired.')
      })
      client.addEventListener('credentialsrequired', (event) => {
        if (!active()) return
        const types = (event as CustomEvent<{ types: string[] }>).detail.types
        if (types.some((type) => type !== 'username' && type !== 'password')) {
          disconnect()
          setState('error')
          setMessage('This server requires an unsupported credential type.')
          return
        }
        setCredentials(types)
        queueMicrotask(() => passwordInput?.focus())
      })
      client.addEventListener('securityfailure', () => {
        if (!active()) return
        disconnect()
        setState('error')
        setMessage('Desktop authentication failed. Reconnect to try again.')
      })
      client.addEventListener('serververification', () => {
        if (!active()) return
        disconnect()
        setState('error')
        setMessage('This server requires identity verification that this viewer does not yet support.')
      })
      client.addEventListener('desktopname', (event) => {
        if (active()) setName((event as CustomEvent<{ name: string }>).detail.name || 'Host desktop')
      })
    } catch {
      if (current !== generation) return
      disconnect()
      setState('error')
      setMessage('Could not open the desktop viewer. Reconnect to try again.')
    }
  }

  const toggleControl = () => {
    if (!rfb || state() !== 'connected') return
    // noVNC 1.7's viewOnly setter suppresses key-up events while releasing
    // tracked keys. End the connection so the server releases all input state.
    if (control()) {
      disconnect()
      setMessage('Control stopped. Reconnect to view the desktop with input paused.')
      return
    }
    rfb.viewOnly = false
    setControl(true)
    setMessage('You are controlling the host desktop.')
    rfb.focus()
  }

  onMount(() => {
    dialog.showModal()
    const abort = new AbortController()
    void fetch('/api/desktop', { credentials: 'same-origin', cache: 'no-store', signal: abort.signal })
      .then(async (response) => {
        if (!response.ok) throw new Error('Owner login is required to access the host desktop.')
        const status = await response.json() as { enabled: boolean; target: string }
        if (abort.signal.aborted) return
        setState(status.enabled ? 'ready' : 'disabled')
        setMessage(status.enabled
          ? 'Connect to view this gateway host’s desktop. Control starts paused.'
          : 'Desktop sharing has not been enabled on this gateway host. Follow the host setup guide to enable it.')
      })
      .catch(() => {
        if (abort.signal.aborted) return
        setState('error')
        setMessage('Desktop availability could not be checked. An owner login is required.')
      })
    onCleanup(() => {
      abort.abort()
      disconnect()
      dialog.close()
      if (restoreFocus instanceof HTMLElement && restoreFocus.isConnected) restoreFocus.focus()
    })
  })

  return (
    <dialog ref={dialog} aria-label="Host desktop" class="m-0 h-full max-h-none w-full max-w-none border-0 bg-[var(--panel)] p-0 text-[var(--text)] backdrop:bg-black/70"
      onCancel={(event) => { event.preventDefault(); props.onClose() }}>
      <div class="flex h-full min-h-0 flex-col pt-[var(--safe-top)] pb-[var(--safe-bottom)]">
        <header class="flex shrink-0 flex-wrap items-center gap-2 border-b border-[var(--border-muted)] px-4 py-3">
          <div class="mr-auto min-w-0">
            <h2 class="max-w-[45vw] truncate text-[14px] font-medium">{name()}</h2>
            <p class="text-[11px] text-[var(--text-subtle)]">Gateway host · independent of chat connections</p>
          </div>
          <Show when={state() === 'connected'}>
            <button class={buttonClass} aria-pressed={control()} onClick={toggleControl}>{control() ? 'Stop control' : 'Enable control'}</button>
          </Show>
          <Show when={state() === 'connected' || state() === 'connecting'} fallback={
            <button class={buttonClass} disabled={state() === 'disabled' || state() === 'loading'} onClick={() => void connect()}>Connect</button>
          }>
            <button class={buttonClass} onClick={disconnect}>Disconnect</button>
          </Show>
          <button class={buttonClass} onClick={props.onClose}>Close</button>
        </header>
        <div class="border-b border-[var(--border-muted)] px-4 py-2 text-[12px] text-[var(--text-subtle)]" role="status" aria-live="polite">{message()}</div>
        <div class="relative flex min-h-0 flex-1 bg-black">
          <div ref={target} class="h-full min-h-0 w-full overflow-hidden" aria-label="Remote desktop display" />
          <Show when={credentials().length > 0}>
            <div class="absolute inset-0 grid place-items-center bg-black/65 p-4">
              <form class="w-full max-w-sm space-y-4 rounded-[10px] border border-[var(--border-muted)] bg-[var(--panel)] p-5"
                onSubmit={(event) => {
                  event.preventDefault()
                  const username = usernameInput?.value
                  const password = passwordInput?.value
                  if (passwordInput) passwordInput.value = ''
                  if (usernameInput) usernameInput.value = ''
                  sentCredentials = { username, password }
                  rfb?.sendCredentials(sentCredentials)
                  setCredentials([])
                }}>
                <h3 class="text-[15px] font-medium">Desktop sign-in</h3>
                <p class="text-[12px] text-[var(--text-subtle)]">Enter the host’s VNC credentials. They are used for this connection only.</p>
                <Show when={credentials().includes('username')}>
                  <label class="block text-[13px]">Username<input ref={usernameInput} class="mt-1 w-full rounded border border-[var(--border-muted)] bg-[var(--chat-black)] p-2" autocomplete="off" required /></label>
                </Show>
                <Show when={credentials().includes('password')}>
                  <label class="block text-[13px]">Password<input ref={passwordInput} type="password" class="mt-1 w-full rounded border border-[var(--border-muted)] bg-[var(--chat-black)] p-2" autocomplete="off" required /></label>
                </Show>
                <div class="flex justify-end gap-2"><button type="button" class={buttonClass} onClick={disconnect}>Cancel</button><button type="submit" class={buttonClass}>Sign in</button></div>
              </form>
            </div>
          </Show>
        </div>
      </div>
    </dialog>
  )
}
