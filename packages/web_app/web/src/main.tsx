import { ErrorBoundary } from 'solid-js'
import { render } from 'solid-js/web'

import './styles.css'
import { registerPwa } from './lib/pwa'
import { startThemeSync } from './lib/theme'
import { App } from './ui/App'

startThemeSync()
registerPwa()

const root = document.getElementById('app')
if (!root) throw new Error('missing #app')
render(
  () => (
    <ErrorBoundary
      fallback={(err) => (
        <div class="grid h-full place-items-center bg-[#0d1213] p-6 text-[#dcd7ba]">
          <div class="max-w-xl">
            <p class="mb-2 text-sm uppercase tracking-wide text-[#c34043]">Verde failed to load</p>
            <pre class="whitespace-pre-wrap font-mono text-[13px] leading-relaxed">{String(err)}</pre>
          </div>
        </div>
      )}
    >
      <App />
    </ErrorBoundary>
  ),
  root,
)
