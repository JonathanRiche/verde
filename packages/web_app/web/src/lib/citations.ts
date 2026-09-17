import { workspaceFileUrl } from './live'

// Codex emits inline file references as directives like
//   :codex-file-citation{path="/abs/deliverable.pdf" purpose="output"}
// which marked passes through as raw text — unreadable in the transcript.
// Rewrite them into anchor chips before markdown parsing; ChatPane intercepts
// clicks to open the in-app viewer instead of navigating away.
const CITATION_RE = /:codex-file-citation\{([^{}]*)\}/g
const MARKDOWN_FILE_LINK_RE =
  /\[([^\]]*)\]\((?:file:\/\/)?(\/[^)\s]+?\.(?:pdf|docx?|pptx?|xlsx?|od[tsp]|rtf|png|jpe?g|webp|gif|bmp|md|markdown|txt|csv|log))\)/gi

const WORKSPACE_FILE_EXTS =
  /\.(pdf|docx?|pptx?|xlsx?|od[tsp]|rtf|png|jpe?g|webp|gif|bmp|md|markdown|txt|csv|log)$/i

// Numeric entities keep the label inert through marked's inline pass — a
// literal `_` or `*` in a filename would otherwise toggle emphasis mid-chip.
function escapeInline(text: string): string {
  return text.replace(/[&<>"'_*~`]/g, (ch) => `&#${ch.charCodeAt(0)};`)
}

export function fileCitationName(path: string): string {
  return path.split('/').filter(Boolean).at(-1) ?? path
}

export function decorateTranscriptFiles(body: string): string {
  return decorateWorkspaceFileLinks(decorateFileCitations(body))
}

/// Replaces every Codex file citation in a raw markdown body with an inline
/// chip that points at the authenticated file endpoint.
export function decorateFileCitations(body: string): string {
  if (!body.includes(':codex-file-citation{')) return body
  return body.replace(CITATION_RE, (match, attrs: string) => {
    const path = /path="([^"]+)"/.exec(attrs)?.[1]
    if (!path) return match
    const href = workspaceFileUrl(path)
    return (
      `<a class="file-citation" href="${escapeInline(href)}" target="_blank" rel="noopener" ` +
      `title="${escapeInline(path)}"><span>${escapeInline(fileCitationName(path))}</span></a>`
    )
  })
}

/// Agents often emit `[Pitch Deck](/abs/path.pdf)` which the browser treats as
/// a same-origin URL and the gateway then answers as JSON 404. Point those
/// links at `/api/file` so the in-app reader can intercept them.
export function decorateWorkspaceFileLinks(body: string): string {
  return body.replace(MARKDOWN_FILE_LINK_RE, (_match, label: string, path: string) => {
    const href = workspaceFileUrl(path)
    return `[${label}](${href})`
  })
}

export function filePathFromHref(href: string | null | undefined, origin = location.origin): string | null {
  if (!href) return null
  try {
    const url = new URL(href, origin)
    if (url.pathname === '/api/file' || url.pathname === '/api/preview') {
      const path = url.searchParams.get('path')
      return path && path.startsWith('/') ? path : null
    }
    if (url.protocol === 'file:') {
      return decodeURIComponent(url.pathname)
    }
    if (url.origin === origin && isWorkspaceFilePath(url.pathname)) {
      return decodeURIComponent(url.pathname)
    }
  } catch {
    return null
  }
  return null
}

function isWorkspaceFilePath(pathname: string): boolean {
  if (!pathname.startsWith('/') || pathname.startsWith('/api/') || pathname.startsWith('/assets/')) {
    return false
  }
  return WORKSPACE_FILE_EXTS.test(pathname)
}
