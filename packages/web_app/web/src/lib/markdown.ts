import DOMPurify from 'dompurify'
import { Marked } from 'marked'
import type { Config, DOMPurify as DOMPurifyApi } from 'dompurify'

import { decorateFileCitations } from './citations'

const markdown = new Marked({ gfm: true, breaks: true })

// Markdown is untrusted provider/repository content. Keep its output in the
// HTML namespace and admit only the presentational elements the UI styles.
// In particular, SVG/MathML, forms, embedded documents, inline styles, event
// handlers, arbitrary data attributes, and named DOM properties stay out.
const MARKDOWN_SANITIZE_CONFIG: Config = {
  ALLOWED_NAMESPACES: ['http://www.w3.org/1999/xhtml'],
  ALLOWED_TAGS: [
    'a',
    'blockquote',
    'br',
    'code',
    'del',
    'em',
    'h1',
    'h2',
    'h3',
    'h4',
    'h5',
    'h6',
    'hr',
    'img',
    'li',
    'ol',
    'p',
    'pre',
    'span',
    'strong',
    'table',
    'tbody',
    'td',
    'th',
    'thead',
    'tr',
    'ul',
  ],
  ALLOWED_ATTR: [
    'alt',
    'class',
    'href',
    'rel',
    'src',
    'title',
  ],
  ALLOW_ARIA_ATTR: false,
  ALLOW_DATA_ATTR: false,
  ALLOW_UNKNOWN_PROTOCOLS: false,
  SANITIZE_DOM: true,
}

export type MarkdownSanitizer = Pick<DOMPurifyApi, 'isSupported' | 'sanitize'>

export type MarkdownOptions = {
  fileCitations?: boolean
}

/// Testable sanitizer seam. Production passes the browser-backed DOMPurify
/// instance; tests pass an instance backed by a current JSDOM document.
export function renderMarkdownWith(
  sanitizer: MarkdownSanitizer,
  body: string,
  options: MarkdownOptions = {},
): string {
  // DOMPurify reports unsupported legacy DOM implementations instead of
  // sanitizing. Fail closed as inert text if Verde ever runs in one.
  if (!sanitizer.isSupported) return escapeHtml(body)
  const source = options.fileCitations ? decorateFileCitations(body) : body
  const unsafe_html = markdown.parse(source, { async: false }) as string
  return String(sanitizer.sanitize(unsafe_html, MARKDOWN_SANITIZE_CONFIG))
}

/// Parses and sanitizes Markdown for insertion through Solid's `innerHTML`.
export function renderMarkdown(body: string, options: MarkdownOptions = {}): string {
  return renderMarkdownWith(DOMPurify, body, options)
}

function escapeHtml(text: string): string {
  return text.replace(/[&<>"']/g, (character) => `&#${character.charCodeAt(0)};`)
}
