//! Docs content registry.
//!
//! Markdown files under `src/content/docs/*.md` are imported with Vite's
//! `?raw` suffix so they are inlined at build time (Cloudflare Workers has no
//! filesystem access at runtime). Each file has a small frontmatter block
//! (title / description / section / order / slug) parsed at module load.
//!
//! This registry is the single source of truth for the docs site, the
//! `/llms.txt` index, the `/llms-full.txt` combined dump, and the per-page
//! `/docs/<slug>.md` raw markdown routes.

import { marked, type Tokens } from 'marked'
import type { HighlighterCore } from 'shiki/core'

import { SITE_ORIGIN } from '../../lib/seo'

import quickstartRaw from './quickstart.md?raw'
import providersRaw from './providers.md?raw'
import chatRaw from './chat.md?raw'
import designModeRaw from './design-mode.md?raw'
import panesRaw from './panes.md?raw'
import keybindsRaw from './keybinds.md?raw'
import cliRaw from './cli.md?raw'
import configRaw from './config.md?raw'
import troubleshootingRaw from './troubleshooting.md?raw'

export type DocSection = 'Get started' | 'Workspace' | 'Reference'

export interface DocEntry {
  /** URL slug — also the on-disk markdown filename (without `.md`). */
  slug: string
  section: DocSection
  /** Order within the section, used for sidebar and prev/next ordering. */
  order: number
  title: string
  description: string
  /** Markdown body with frontmatter stripped. */
  body: string
  /** Original raw file content (including frontmatter) for the `.md` route. */
  raw: string
  /** Path inside the repo — used for the "Edit on GitHub" link. */
  githubPath: string
}

export interface TocItem {
  depth: number
  text: string
  slug: string
}

const SECTION_ORDER: Record<DocSection, number> = {
  'Get started': 0,
  Workspace: 1,
  Reference: 2,
}

const REPO_ROOT = 'https://github.com/JonathanRiche/verde/blob/master/packages/website/'

/** Parse a tiny `key: value` YAML-ish frontmatter block. Quotes optional. */
function parseFrontmatter(raw: string, githubPath: string): DocEntry {
  const match = /^---\r?\n([\s\S]*?)\r?\n---\r?\n([\s\S]*)$/.exec(raw)
  if (!match) {
    throw new Error(`docs frontmatter missing in ${githubPath}`)
  }

  const fmText = match[1]!
  const body = match[2]!
  const fm: Record<string, string> = {}
  for (const line of fmText.split(/\r?\n/)) {
    const m = /^([a-z_]+):\s*(.*?)\s*$/.exec(line)
    if (m) fm[m[1]!] = m[2]!.replace(/^"(.*)"$/, '$1')
  }

  const required = ['title', 'description', 'section', 'order', 'slug'] as const
  for (const key of required) {
    if (!(key in fm)) {
      throw new Error(`docs frontmatter missing '${key}' in ${githubPath}`)
    }
  }

  const section = fm.section as DocSection
  if (!(section in SECTION_ORDER)) {
    throw new Error(`docs frontmatter has unknown section '${section}' in ${githubPath}`)
  }

  return {
    slug: fm.slug!,
    section,
    order: Number(fm.order),
    title: fm.title!,
    description: fm.description!,
    body,
    raw,
    githubPath,
  }
}

const docs: DocEntry[] = [
  parseFrontmatter(quickstartRaw, 'src/content/docs/quickstart.md'),
  parseFrontmatter(providersRaw, 'src/content/docs/providers.md'),
  parseFrontmatter(chatRaw, 'src/content/docs/chat.md'),
  parseFrontmatter(designModeRaw, 'src/content/docs/design-mode.md'),
  parseFrontmatter(panesRaw, 'src/content/docs/panes.md'),
  parseFrontmatter(keybindsRaw, 'src/content/docs/keybinds.md'),
  parseFrontmatter(cliRaw, 'src/content/docs/cli.md'),
  parseFrontmatter(configRaw, 'src/content/docs/config.md'),
  parseFrontmatter(troubleshootingRaw, 'src/content/docs/troubleshooting.md'),
]

docs.sort((a, b) => {
  if (a.section !== b.section) {
    return SECTION_ORDER[a.section] - SECTION_ORDER[b.section]
  }
  return a.order - b.order
})

const bySlug = new Map(docs.map((d) => [d.slug, d] as const))

export function getAllDocs(): readonly DocEntry[] {
  return docs
}

export function getDoc(slug: string): DocEntry | undefined {
  return bySlug.get(slug)
}

/** Group docs by section, preserving per-section order. */
export function getDocsNav(): { section: DocSection; entries: DocEntry[] }[] {
  const groups: { section: DocSection; entries: DocEntry[] }[] = []
  for (const doc of docs) {
    let group = groups.find((g) => g.section === doc.section)
    if (!group) {
      group = { section: doc.section, entries: [] }
      groups.push(group)
    }
    group.entries.push(doc)
  }
  return groups
}

/** Linear prev/next across the whole sorted doc list. */
export function getPager(slug: string): { prev?: DocEntry; next?: DocEntry } {
  const i = docs.findIndex((d) => d.slug === slug)
  if (i < 0) return {}
  return {
    prev: i > 0 ? docs[i - 1] : undefined,
    next: i < docs.length - 1 ? docs[i + 1] : undefined,
  }
}

/**
 * Slugify a heading for use as an `id`/`href`. Markdown headings can contain
 * inline code, markup, and punctuation — strip everything non-wordy, replace
 * spaces with dashes. Matches the slugify used by the markdown renderer below.
 */
export function slugify(s: string): string {
  return s
    .toLowerCase()
    .replace(/<[^>]+>/g, '')
    .replace(/[^\w\s-]/g, '')
    .trim()
    .replace(/\s+/g, '-')
}

/** Extract h2/h3 from a markdown body for the "On this page" TOC. */
export function extractToc(markdown: string): TocItem[] {
  const tokens = marked.lexer(markdown)
  const toc: TocItem[] = []
  for (const token of tokens) {
    if (token.type === 'heading' && (token.depth === 2 || token.depth === 3)) {
      const heading = token as Tokens.Heading
      const text = heading.text || ''
      toc.push({ depth: heading.depth, text, slug: slugify(text) })
    }
  }
  return toc
}

/**
 * Configure marked once for the docs:
 *   - GFM tables, autolinks, strikethrough
 *   - Headings get stable slug IDs (matches `slugify` used by `extractToc`)
 *
 * The Shiki `code` renderer is attached lazily once the highlighter has
 * loaded (see `ensureShikiRenderer`); until then marked falls back to its
 * default `<pre><code>` renderer.
 *
 * Returns the configured `marked` instance so callers can call `parse(body)`.
 */
marked.use({
  gfm: true,
  renderer: {
    heading({ tokens, depth }: Tokens.Heading): string {
      // Re-render inline tokens to a string so we can slugify the visible text.
      const text = (this.parser.parseInline(tokens) ?? '').toString()
      const id = slugify(text)
      return `<h${depth} id="${id}">${text}</h${depth}>\n`
    },
  },
})

/* ──────────────────────────────────────────────────────────────────────
   Shiki syntax highlighting for fenced code blocks
   ──────────────────────────────────────────────────────────────────────

   We use Shiki's CSS-variables theme (`shiki/core`'s `createCssVariablesTheme`)
   so token colors resolve against design tokens defined in `styles.css`
   (`--shiki-token-*`). The JS regex engine (`createJavaScriptRegexEngine`)
   is used instead of oniguruma WASM so the highlighter runs in both the
   browser bundle and the Cloudflare Worker SSR bundle without `node:` or
   `.wasm` assets.

   The highlighter is created once and shared across all `renderMarkdown`
   calls. `renderMarkdown` is async because Shiki's grammars load
   asynchronously; once loaded, `codeToHtml` is synchronous.
*/

const SHIKI_LANGS = ['bash', 'json', 'yaml'] as const
const SHIKI_THEME_NAME = 'verde-dark'

let highlighterPromise: Promise<HighlighterCore> | null = null
function getHighlighter(): Promise<HighlighterCore> {
  if (!highlighterPromise) {
    // Shiki + its grammars are loaded via dynamic import so Vite splits
    // them into a lazy chunk fetched only when a docs page is rendered.
    // This keeps the homepage bundle (which never touches markdown
    // rendering) from pulling in ~225 kB of highlighter code.
    //
    // We import from `shiki/core` and only the three grammars we need
    // (`shiki/langs/{bash,json,yaml}`) so we don't pull the full Shiki
    // language bundle the way `import { createHighlighter } from 'shiki'`
    // would. The JS regex engine (`shiki/engine/javascript`) is used
    // instead of oniguruma WASM so the same code runs in the browser
    // bundle and the Cloudflare Worker SSR bundle.
    highlighterPromise = (async () => {
      const [{ createHighlighterCore, createCssVariablesTheme }, { createJavaScriptRegexEngine }, { default: bashLang }, { default: jsonLang }, { default: yamlLang }] =
        await Promise.all([
          import('shiki/core'),
          import('shiki/engine/javascript'),
          // Import grammars from `@shikijs/langs/*` (the source-of-truth
          // grammar package) rather than `shiki/langs/*` — both ship the
          // same default export, but the `@shikijs/langs/*` subpaths have
          // proper declaration files that TypeScript can resolve, while
          // `shiki/langs/*` resolves only via the package's `"./*"`
          // wildcard export, which `moduleResolution: bundler` doesn't
          // pick up reliably.
          import('@shikijs/langs/bash'),
          import('@shikijs/langs/json'),
          import('@shikijs/langs/yaml'),
        ])
      const shikiTheme = createCssVariablesTheme({
        name: SHIKI_THEME_NAME,
        variablePrefix: '--shiki-',
      })
      return createHighlighterCore({
        themes: [shikiTheme],
        langs: [bashLang, jsonLang, yamlLang],
        engine: createJavaScriptRegexEngine(),
      })
    })()
  }
  return highlighterPromise
}

/** Escape HTML special chars for the plain-text fallback code block. */
function escapeHtml(s: string): string {
  return s
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;')
}

/** Plain (non-highlighted) `<pre><code>` for unknown/empty languages. */
function renderPlainPreCode(text: string, escaped: boolean, lang: string): string {
  const body = escaped ? text : escapeHtml(text)
  return `<pre class="shiki shiki-plain" data-lang="${escapeHtml(lang)}"><code>${body}</code></pre>`
}

// Inline SVGs match the hero/CLI `CopyButton` glyphs (see `CopyButton.tsx`)
// so the code-block copy affordance reads as part of the same UI family.
const CLIPBOARD_SVG =
  '<svg class="copy-icon" viewBox="0 0 24 24" aria-hidden="true"><path fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" d="M8 7V5a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2m4 0v10a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V7h16Z"/></svg>'
const CHECK_SVG =
  '<svg class="check-icon" viewBox="0 0 24 24" aria-hidden="true"><path fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round" d="M5 13l4 4L19 7"/></svg>'

/**
 * Build a marked `code` renderer bound to a loaded Shiki highlighter.
 *
 * The rendered HTML is wrapped in a `.code-block` shell containing a header
 * row (language label + copy button) followed by the highlighted `<pre>`.
 * The copy button is wired up by a delegated click handler in the docs route
 * (see `routes/docs/$slug.tsx`).
 */
function makeCodeRenderer(highlighter: HighlighterCore) {
  return function code({ text, lang, escaped }: Tokens.Code): string {
    // The info string may carry extras (e.g. `bash title="..."`); the bare
    // language is the first whitespace-delimited token, lowercased.
    const baseLang = (lang ?? '').split(/\s+/)[0]?.trim().toLowerCase() ?? ''
    const known = (SHIKI_LANGS as readonly string[]).includes(baseLang)
    let preHtml: string
    if (known) {
      try {
        preHtml = highlighter.codeToHtml(text, { lang: baseLang, theme: SHIKI_THEME_NAME })
      } catch {
        preHtml = renderPlainPreCode(text, !!escaped, baseLang)
      }
    } else {
      preHtml = renderPlainPreCode(text, !!escaped, baseLang)
    }
    const label = baseLang || 'text'
    return `<div class="code-block" data-lang="${escapeHtml(label)}">` +
      `<div class="code-block-head">` +
      `<span class="code-block-lang">${escapeHtml(label)}</span>` +
      `<button class="code-block-copy" type="button" aria-label="Copy code" title="Copy code">${CLIPBOARD_SVG}${CHECK_SVG}</button>` +
      `</div>${preHtml}</div>\n`
  }
}

let shikiRendererAttached = false
async function ensureShikiRenderer(): Promise<void> {
  if (shikiRendererAttached) return
  const highlighter = await getHighlighter()
  marked.use({ renderer: { code: makeCodeRenderer(highlighter) } })
  shikiRendererAttached = true
}

/**
 * Render a docs markdown body to HTML with Shiki-highlighted code blocks.
 *
 * Async because Shiki's grammars load asynchronously on first call; the
 * highlighter is cached for the lifetime of the module so subsequent
 * calls resolve quickly. The actual marked parse stays synchronous once
 * the renderer is attached.
 */
export async function renderMarkdown(body: string): Promise<string> {
  await ensureShikiRenderer()
  return marked.parse(body, { async: false }) as string
}

/**
 * Combined markdown dump for `/llms-full.txt`. The frontmatter is re-emitted
 * as an `# H1` + source URL block per page so an agent ingesting the whole
 * document can attribute each section.
 */
export function renderLlmsFull(): string {
  const parts: string[] = []
  for (const doc of docs) {
    const url = `${SITE_ORIGIN}/docs/${doc.slug}`
    parts.push(
      `# ${doc.title}\n\nSource: ${url}\nEdit: ${REPO_ROOT}${doc.githubPath}\n\n${doc.body.trim()}\n`,
    )
  }
  return parts.join('\n---\n\n')
}

/**
 * Compact index for `/llms.txt` per the llmstxt.org convention. One line per
 * doc: `title — description (url)`. The header summarizes Verde for an agent
 * that has never seen it before.
 */
export function renderLlmsIndex(): string {
  const lines = [
    `# Verde`,
    '',
    `> Verde is a native desktop workspace for coding agents. It runs Codex,`,
    `> Claude Code, OpenCode, Cursor, Pi, FX, and Grok Build as native chat`,
    `> panes, with Codex, Claude Code, OpenCode, Cursor, Pi, FX, Grok Build, and Amp`,
    `> also available as terminal TUIs in the same tiling window —`,
    `> with an embedded browser pane, a project-scoped terminal dock, a`,
    `> Ctrl+Shift+P command palette, and a local IPC socket that's scriptable from`,
    `> \`verde live\` and \`verde state\`. No hosted relay — Verde drives the`,
    `> provider CLIs already on your machine.`,
    '',
    `Project: ${SITE_ORIGIN}`,
    `Source: https://github.com/JonathanRiche/verde`,
    `Install: \`curl -fsSL ${SITE_ORIGIN}/install.sh | sh\``,
    '',
    `## Docs`,
    '',
  ]
  for (const doc of docs) {
    lines.push(`- [${doc.title}](${SITE_ORIGIN}/docs/${doc.slug}): ${doc.description}`)
  }
  lines.push('')
  lines.push(`## Optional`)
  lines.push(`- [Full docs as one markdown file](${SITE_ORIGIN}/llms-full.txt)`)
  lines.push(`- [Per-page raw markdown](${SITE_ORIGIN}/docs/<slug>.md) (e.g. ${SITE_ORIGIN}/docs/quickstart.md)`)
  lines.push(`- [verde.json JSON Schema](${SITE_ORIGIN}/config.schema.json)`)
  lines.push(`- [Homepage](${SITE_ORIGIN}/)`)
  lines.push('')
  return lines.join('\n')
}

/** Raw markdown body (frontmatter included) for a per-page `.md` route. */
export function getRawMarkdown(slug: string): string | undefined {
  return bySlug.get(slug)?.raw
}

export { REPO_ROOT, SITE_ORIGIN }
