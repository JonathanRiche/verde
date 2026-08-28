// Codex emits inline file references as directives like
//   :codex-file-citation{path="/abs/deliverable.pdf" purpose="output"}
// which marked passes through as raw text — unreadable in the transcript.
// Rewrite them into inert chips before markdown parsing. Remote workspace file
// access is not exposed until the daemon has a repository-scoped file API.
const CITATION_RE = /:codex-file-citation\{([^{}]*)\}/g
const PATH_ATTR_RE = /path="([^"]+)"/

// Numeric entities keep the label inert through marked's inline pass — a
// literal `_` or `*` in a filename would otherwise toggle emphasis mid-chip.
function escapeInline(text: string): string {
  return text.replace(/[&<>"'_*~`]/g, (ch) => `&#${ch.charCodeAt(0)};`)
}

const CHIP_ICON =
  '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M7 3h7l5 5v13H7z M14 3v5h5" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linejoin="round"/></svg>'

export function fileCitationName(path: string): string {
  return path.split('/').filter(Boolean).at(-1) ?? path
}

/// Replaces every Codex file citation in a raw markdown body with an inert
/// HTML chip. Bodies without citations are returned unchanged so the hot
/// streaming path stays a single includes() check.
export function decorateFileCitations(body: string): string {
  if (!body.includes(':codex-file-citation{')) return body
  return body.replace(CITATION_RE, (match, attrs: string) => {
    const path = PATH_ATTR_RE.exec(attrs)?.[1]
    if (!path) return match
    return (
      `<span class="file-citation" title="${escapeInline(path)}">` +
      `${CHIP_ICON}<span>${escapeInline(fileCitationName(path))}</span></span>`
    )
  })
}
