/// Lossless code/diff helpers. DOM decoration only creates text nodes and spans;
/// untrusted source never becomes markup.

export const CODE_HIGHLIGHT_MAX = 20_000
const HASH_COMMENT_LANGS = new Set(['py', 'python', 'sh', 'bash', 'zsh', 'fish', 'shell', 'rb', 'ruby', 'yaml', 'yml', 'toml', 'ini', 'dockerfile', 'makefile', 'nix', 'r', 'perl', 'pl', 'elixir', 'ex'])
const SPACED_HASH_LANGS = new Set(['sh', 'bash', 'zsh', 'fish', 'shell', 'yaml', 'yml'])
const DASH_COMMENT_LANGS = new Set(['sql', 'lua', 'haskell', 'hs', 'elm', 'ada'])
const NO_SLASH_COMMENT_LANGS = new Set([...HASH_COMMENT_LANGS, ...DASH_COMMENT_LANGS, 'html', 'xml', 'css', 'json', 'md', 'markdown', 'diff', 'text', 'txt', 'plaintext', 'console', 'log', 'output', 'nginx', 'http', 'url'])
// Block comments outside the C family would swallow shell/YAML globs (`build/*`).
const BLOCK_COMMENT_EXTRA_LANGS = new Set(['css', 'sql'])
const CODE_KEYWORDS = new Set(('abstract and as async await break case catch class comptime const continue def default defer del do elif else enum errdefer except export extends extern false final finally fn for from func function if impl implements import in inline interface is let match mod mut namespace new nil none None not null or orelse package pass private protected pub public raise return self static struct super switch then this throw trait true True False try type typeof undefined union unreachable use var void when where while with yield').split(' '))

export type TokenClass = 'tok-comment' | 'tok-string' | 'tok-number' | 'tok-keyword' | 'tok-call'
export interface Token {
  cls: TokenClass | null
  text: string
}

/// Small generic tokenizer: comments, strings, numbers, keywords, calls.
/// Lossless: joining every token's text reproduces the input exactly.
export function tokenize(text: string, lang: string): Token[] {
  lang = lang.toLowerCase()
  if (text.length === 0 || text.length > CODE_HIGHLIGHT_MAX) return [{ cls: null, text }]
  const comments: string[] = []
  const slash = !NO_SLASH_COMMENT_LANGS.has(lang)
  if (slash || BLOCK_COMMENT_EXTRA_LANGS.has(lang)) comments.push('\\/\\*[\\s\\S]*?\\*\\/')
  // `(?<!:)` keeps unquoted URLs out of comments.
  if (slash) comments.push('(?<!:)\\/\\/[^\\n]*')
  // `$#`, `${#arr}` and `${v#prefix}` are shell expansions, not comments.
  if (HASH_COMMENT_LANGS.has(lang)) comments.push(SPACED_HASH_LANGS.has(lang) ? '(?<!\\S)#[^\\n]*' : '(?<![$\\w{])#[^\\n]*')
  if (DASH_COMMENT_LANGS.has(lang)) comments.push('--[^\\n]*')
  const comment = comments.length > 0 ? `(?<c>${comments.join('|')})|` : ''
  const pattern = new RegExp(
    `(?<u>\\b[A-Za-z][A-Za-z0-9+.-]*:\\/\\/[^\\s"\'<>\x60]+)|${comment}(?<s>"(?:\\\\.|[^"\\\\\\n])*"|'(?:\\\\.|[^'\\\\\\n])*'|\`(?:\\\\.|[^\`\\\\])*\`)|(?<n>\\b\\d[\\w.]*\\b)|(?<w>[A-Za-z_@][\\w]*)`,
    'g',
  )
  const out: Token[] = []
  let last = 0
  for (const match of text.matchAll(pattern)) {
    const groups = match.groups ?? {}
    const cls: TokenClass | null = groups.u != null ? null : groups.c != null ? 'tok-comment'
      : groups.s != null ? 'tok-string'
      : groups.n != null ? 'tok-number'
      : CODE_KEYWORDS.has(match[0]) ? 'tok-keyword'
      : text[match.index + match[0].length] === '(' ? 'tok-call'
      : null
    if (!cls) continue
    if (match.index > last) out.push({ cls: null, text: text.slice(last, match.index) })
    out.push({ cls, text: match[0] })
    last = match.index + match[0].length
  }
  if (last < text.length) out.push({ cls: null, text: text.slice(last) })
  return out
}

const isLowSurrogate = (code: number) => code >= 0xdc00 && code <= 0xdfff

/// Changed span `[start, end)` per side between the common prefix and suffix
/// of a paired -/+ line, or null when emphasis would not help: nothing
/// survived, or so little did that the pairing is probably coincidental
/// (unrelated lines sharing only indentation).
export function emphasisSpans(a: string, b: string): { a: [number, number]; b: [number, number] } | null {
  const max = Math.min(a.length, b.length)
  let prefix = 0
  while (prefix < max && a[prefix] === b[prefix]) prefix += 1
  // Never split a surrogate pair: that renders U+FFFD.
  if (prefix > 0 && prefix < max && isLowSurrogate(a.charCodeAt(prefix))) prefix -= 1
  let suffix = 0
  while (suffix < max - prefix && a[a.length - 1 - suffix] === b[b.length - 1 - suffix]) suffix += 1
  if (suffix > 0 && isLowSurrogate(a.charCodeAt(a.length - suffix))) suffix -= 1
  const common = (a.slice(0, prefix) + a.slice(a.length - suffix)).replace(/\s/g, '').length
  const longest = Math.max(a.trim().length, b.trim().length)
  if (common === 0 || common < longest * 0.3) return null
  return { a: [prefix, a.length - suffix], b: [prefix, b.length - suffix] }
}

const FRAGMENT_CACHE_ENTRIES = 64
const FRAGMENT_CACHE_CHARACTERS = 200_000
const fragmentCaches = new WeakMap<Document, { entries: Map<string, DocumentFragment>; characters: number }>()

/** Return an independent fragment; cached templates never enter the live DOM. */
export function highlightedFragment(document: Document, text: string, lang: string): DocumentFragment {
  const fragment = document.createDocumentFragment()
  if (!text || text.length > CODE_HIGHLIGHT_MAX) { fragment.append(text); return fragment }
  let cache = fragmentCaches.get(document)
  if (!cache) { cache = { entries: new Map(), characters: 0 }; fragmentCaches.set(document, cache) }
  const key = `${lang.toLowerCase()}\0${text}`
  const saved = cache.entries.get(key)
  if (saved) {
    cache.entries.delete(key)
    cache.entries.set(key, saved)
    return saved.cloneNode(true) as DocumentFragment
  }
  for (const token of tokenize(text, lang.toLowerCase())) {
    if (!token.cls) fragment.append(token.text)
    else {
      const span = document.createElement('span')
      span.className = token.cls
      span.textContent = token.text
      fragment.append(span)
    }
  }
  cache.entries.set(key, fragment)
  cache.characters += key.length
  while (cache.entries.size > FRAGMENT_CACHE_ENTRIES || cache.characters > FRAGMENT_CACHE_CHARACTERS) {
    const oldest = cache.entries.keys().next().value!
    cache.characters -= oldest.length
    cache.entries.delete(oldest)
  }
  return fragment.cloneNode(true) as DocumentFragment
}

/** Reject unavailable or denied clipboard access so callers show feedback. */
export async function copyText(text: string, clipboard = globalThis.navigator?.clipboard): Promise<void> {
  if (!clipboard?.writeText) throw new Error('Clipboard unavailable')
  await clipboard.writeText(text)
}

/** A toolbar occupies its own row, preserving the exact copyable code text. */
export function decorateCodeBlocks(root: HTMLElement, highlight: boolean): void {
  const document = root.ownerDocument
  for (const pre of root.querySelectorAll<HTMLElement>('pre')) {
    const code = pre.querySelector<HTMLElement>('code')
    const lang = /(?:^|\s)language-([\w+#-]+)/.exec(code?.className ?? '')?.[1]?.toLowerCase() ?? ''
    // Existing streaming wrappers must still acquire highlighting on completion.
    if (highlight && code && lang) code.replaceChildren(highlightedFragment(document, code.textContent ?? '', lang))
    if (pre.parentElement?.classList.contains('code-block')) continue
    const wrapper = document.createElement('div')
    wrapper.className = 'code-block'
    const toolbar = document.createElement('div')
    toolbar.className = 'code-toolbar'
    const language = document.createElement('span')
    language.className = 'code-language'
    language.textContent = lang || 'Code'
    const status = document.createElement('span')
    status.className = 'code-copy-status'
    status.setAttribute('role', 'status')
    status.setAttribute('aria-live', 'polite')
    const button = document.createElement('button')
    button.type = 'button'
    button.className = 'code-copy'
    button.textContent = 'Copy'
    button.setAttribute('aria-label', lang ? `Copy ${lang} code` : 'Copy code')
    button.addEventListener('click', async (event) => {
      event.stopPropagation()
      try {
        await copyText(code?.textContent ?? pre.textContent ?? '', document.defaultView?.navigator.clipboard)
        status.textContent = 'Copied'
      } catch { status.textContent = 'Copy failed. Select and copy manually.' }
    })
    toolbar.append(language, status, button)
    pre.replaceWith(wrapper)
    wrapper.append(toolbar, pre)
  }
}
