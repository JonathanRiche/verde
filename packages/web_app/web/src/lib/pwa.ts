export function registerPwa(): void {
  if (!window.isSecureContext || !('serviceWorker' in navigator)) return
  // Vite HMR + a caching SW white-screens after dependency swaps.
  if (import.meta.env.DEV) {
    void navigator.serviceWorker.getRegistrations().then((regs) => {
      for (const reg of regs) void reg.unregister()
    })
    return
  }
  const register = () => {
    void navigator.serviceWorker.register('/sw.js', { scope: '/', updateViaCache: 'none' })
  }
  if (document.readyState === 'complete') register()
  else window.addEventListener('load', register, { once: true })
}
