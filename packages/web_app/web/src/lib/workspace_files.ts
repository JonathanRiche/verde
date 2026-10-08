/**
 * Files panel data: a lazily expanded tree over the workspace's folders
 * (`workspace.files.list`) and read-only file previews (`workspace.files.read`).
 * See headless workspace_files_protocol.zig. Entries are addressed as
 * `(root id, root-relative path)`; the daemon re-confines every request and
 * never accepts absolute paths, so nothing here widens access. `root.path`
 * is the daemon host's absolute folder, used only for display and prompts.
 */
import { CODE_HIGHLIGHT_MAX, type Token, tokenize } from './highlight'

export interface FilesRoot { id: string; name: string; path: string }
/// `path` is relative to the listing's root.
export interface FileEntry { name: string; path: string; kind: 'directory' | 'file'; size: number; ignored: boolean; symlink: boolean }
export interface FilesListing { roots: FilesRoot[]; root: string | null; path: string | null; entries: FileEntry[]; truncated: boolean }

/// Root id of the workspace home (paths there carry no folder prefix).
export const HOME_ROOT_ID = 'home'
/// Read caps every gateway client passes so a response fits the 1 MiB
/// transport after JSON escaping and base64 (4/3) growth. Longer text comes
/// back truncated; larger images come back `too_large`.
export const READ_MAX_TEXT_BYTES = 524_288
export const READ_MAX_IMAGE_BYTES = 614_400

export type FileContentKind = 'text' | 'markdown' | 'image' | 'binary' | 'external' | 'too_large'
export interface FileRead {
  root: string
  path: string
  name: string
  size: number
  kind: FileContentKind
  mime: string | null
  encoding: 'none' | 'utf8' | 'base64'
  content: string
  truncated: boolean
}

const num = (value: unknown): number => (typeof value === 'number' && Number.isFinite(value) && value >= 0 ? Math.floor(value) : 0)
const str = (value: unknown): string => (typeof value === 'string' ? value : '')
const record = (value: unknown): Record<string, unknown> | null =>
  value && typeof value === 'object' && !Array.isArray(value) ? value as Record<string, unknown> : null
const rows = (value: unknown): Record<string, unknown>[] =>
  (Array.isArray(value) ? value : []).flatMap((row) => { const item = record(row); return item ? [item] : [] })
const KINDS: readonly FileContentKind[] = ['text', 'markdown', 'image', 'binary', 'external', 'too_large']

export function parseFilesListing(value: unknown): FilesListing | null {
  const root = record(value)
  if (!root) return null
  const roots = rows(root.roots).flatMap((row) =>
    typeof row.id === 'string' && row.id
      ? [{ id: row.id, path: str(row.path), name: str(row.name) || baseName(str(row.path)) || row.id }] : [])
  const entries = rows(root.entries).flatMap((row): FileEntry[] => {
    if (typeof row.path !== 'string' || !row.path) return []
    // `.git` is hidden by the daemon; keep the guarantee if an old one sends it.
    const name = str(row.name) || baseName(row.path)
    if (name === '.git') return []
    return [{
      name, path: row.path, kind: row.kind === 'directory' ? 'directory' : 'file',
      size: num(row.size), ignored: row.ignored === true, symlink: row.symlink === true,
    }]
  })
  return {
    roots, root: typeof root.root === 'string' && root.root ? root.root : null,
    path: typeof root.path === 'string' ? root.path : null, entries, truncated: root.truncated === true,
  }
}

export function parseFileRead(value: unknown): FileRead | null {
  const root = record(value)
  if (!root || typeof root.path !== 'string' || typeof root.root !== 'string') return null
  const kind = KINDS.includes(root.kind as FileContentKind) ? root.kind as FileContentKind : 'binary'
  const encoding = root.encoding === 'utf8' || root.encoding === 'base64' ? root.encoding : 'none'
  return {
    root: root.root, path: root.path, name: str(root.name) || baseName(root.path), size: num(root.size), kind,
    mime: typeof root.mime === 'string' && root.mime ? root.mime : null, encoding,
    content: str(root.content), truncated: root.truncated === true,
  }
}

export function baseName(path: string): string {
  return path.split('/').filter(Boolean).at(-1) ?? path
}

const trimSlash = (path: string): string => path.replace(/\/+$/, '')

/// Workspace-relative path shown to the user and sent to chats
/// (client_core selection_prompt.displayPath): home-relative, `<folder>/…`
/// under another root (the deepest containing root wins), else unchanged.
export function displayPath(path: string, roots: FilesRoot[]): string {
  let best: FilesRoot | null = null
  for (const root of roots) {
    const base = trimSlash(root.path)
    if (!base || !path.startsWith(base)) continue
    if (path.length > base.length && path[base.length] !== '/') continue
    if (!best || base.length > trimSlash(best.path).length) best = root
  }
  if (!best) return path
  const rest = path.slice(trimSlash(best.path).length).replace(/^\/+/, '')
  if (best.id === HOME_ROOT_ID) return rest || '.'
  return rest ? `${best.name}/${rest}` : best.name
}

/// Path shown for a root entry and sent to chats: bare for the workspace
/// home, `<folder>/…` for another root.
export function rootPath(root: Pick<FilesRoot, 'id' | 'name'>, path: string): string {
  if (root.id === HOME_ROOT_ID) return path || '.'
  return path ? `${root.name}/${path}` : root.name
}

/// Daemon-host absolute path of a root entry (display and prompts only).
export function absolutePath(root: FilesRoot, path: string): string {
  const base = trimSlash(root.path)
  return path ? `${base}/${path}` : base
}

/// `(root id, relative path)` of an absolute daemon path, from the deepest
/// root that contains it; null when it lies outside every root.
export function locateInRoots(path: string, roots: FilesRoot[]): { root: string; path: string } | null {
  let best: FilesRoot | null = null
  for (const root of roots) {
    const base = trimSlash(root.path)
    if (!base || !path.startsWith(`${base}/`)) continue
    if (!best || base.length > trimSlash(best.path).length) best = root
  }
  if (!best) return null
  const rest = path.slice(trimSlash(best.path).length + 1).split('/').filter((part) => part && part !== '.').join('/')
  return rest && !rest.split('/').includes('..') ? { root: best.id, path: rest } : null
}

export function formatSize(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(bytes < 10 * 1024 ? 1 : 0)} KB`
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`
}

/// Plain-language text for a daemon error code.
export function filesErrorText(code: string | undefined, message: string | undefined): string {
  switch (code) {
    case 'method_not_found': case 'unknown_method': case 'unsupported':
      return 'This Verde daemon does not support the Files view yet. Update and restart the daemon.'
    case 'resource_not_found': return 'This workspace is no longer available.'
    case 'store_unavailable': return 'The workspace store is unavailable. Try again shortly.'
    case 'root_not_found': return 'This workspace folder is no longer configured.'
    case 'invalid_params': return 'That path is not valid in this workspace.'
    case 'path_outside_roots': return 'That path is outside this workspace.'
    case 'not_found': return 'This file or folder no longer exists.'
    case 'not_directory': return 'That is not a folder.'
    case 'not_file': return 'That is not a regular file.'
    default: return message || 'Could not load files.'
  }
}

// ---- Code view -------------------------------------------------------------------

const NAMED_LANGS: Record<string, string> = { makefile: 'makefile', dockerfile: 'dockerfile', 'cmakelists.txt': 'cmake' }
const EXT_LANGS: Record<string, string> = {
  mjs: 'js', cjs: 'js', jsx: 'js', tsx: 'ts', mts: 'ts', cts: 'ts', yml: 'yaml', htm: 'html', svg: 'xml',
  mk: 'makefile', zon: 'zig', kts: 'kotlin', kt: 'kotlin', h: 'c', hpp: 'cpp', cc: 'cpp', txt: 'text', log: 'log',
}

/// Tokenizer language for a file name (see highlight.ts language sets).
export function languageForPath(path: string): string {
  const name = baseName(path).toLowerCase()
  if (NAMED_LANGS[name]) return NAMED_LANGS[name]
  const dot = name.lastIndexOf('.')
  if (dot <= 0) return name.startsWith('.') ? 'sh' : 'text'
  const ext = name.slice(dot + 1)
  return EXT_LANGS[ext] ?? ext
}

/// Per-line tokens. Lines are tokenized in chunks under the tokenizer's size
/// cap so block comments and multi-line strings colour across lines.
export function highlightLines(text: string, lang: string): Token[][] {
  const lines = text.split('\n')
  if (lines.at(-1) === '' && lines.length > 1) lines.pop()
  const out: Token[][] = []
  let start = 0
  while (start < lines.length) {
    let end = start
    let size = 0
    while (end < lines.length && (end === start || size + lines[end].length + 1 <= CODE_HIGHLIGHT_MAX)) { size += lines[end].length + 1; end += 1 }
    const chunk = lines.slice(start, end).join('\n')
    let current: Token[] = []
    for (const token of tokenize(chunk, lang)) {
      const parts = token.text.split('\n')
      parts.forEach((part, index) => {
        if (index > 0) { out.push(current); current = [] }
        if (part) current.push({ cls: token.cls, text: part })
      })
    }
    out.push(current)
    start = end
  }
  return out
}

// ---- Line selection prompt --------------------------------------------------------

export interface LineSelection { start: number; end: number }

/// Ordered, 1-based inclusive range from an anchor and a focus line.
export function lineRange(anchor: number, focus: number): LineSelection {
  return anchor <= focus ? { start: anchor, end: focus } : { start: focus, end: anchor }
}

/// Selected source lines (1-based inclusive) of `text`.
export function selectedText(text: string, range: LineSelection): string {
  return text.split('\n').slice(range.start - 1, range.end).join('\n')
}

/// Selection and instruction byte caps (client_core selection_prompt).
export const MAX_SELECTION_BYTES = 256 * 1024
export const MAX_INSTRUCTION_BYTES = 64 * 1024

const FENCE_LANGS: Record<string, string> = {
  zig: 'zig', ts: 'typescript', tsx: 'tsx', js: 'javascript', mjs: 'javascript', cjs: 'javascript', jsx: 'jsx',
  json: 'json', kt: 'kotlin', kts: 'kotlin', swift: 'swift', py: 'python', rs: 'rust', go: 'go', c: 'c', h: 'c',
  cc: 'cpp', cpp: 'cpp', hpp: 'cpp', m: 'objectivec', java: 'java', rb: 'ruby', sh: 'bash', bash: 'bash',
  zsh: 'bash', fish: 'fish', md: 'markdown', markdown: 'markdown', toml: 'toml', yaml: 'yaml', yml: 'yaml',
  html: 'html', css: 'css', scss: 'scss', sql: 'sql', xml: 'xml', lua: 'lua', php: 'php', cs: 'csharp',
  dart: 'dart', vue: 'vue', svelte: 'svelte', gradle: 'groovy', nix: 'nix',
}

/// Fence language from the file extension; empty when unknown.
export function fenceLanguage(path: string): string {
  const name = path.split('/').at(-1) ?? ''
  const dot = name.lastIndexOf('.')
  if (dot <= 0) return ''
  const ext = name.slice(dot + 1)
  return ext.length > 16 ? '' : FENCE_LANGS[ext.toLowerCase()] ?? ''
}

const utf8Bytes = (text: string): number => new TextEncoder().encode(text).length

export interface SelectionPromptInput {
  /// Absolute daemon path (for diffs: repository root joined with the file path).
  path: string
  roots: FilesRoot[]
  start_line: number
  end_line?: number | null
  side?: 'new' | 'old' | null
  text: string
  instruction: string
}

/// The "ask agent about selected lines" message every client sends
/// (client_core selection_prompt.format, byte for byte). Null for invalid
/// input: an empty or reversed range, or an oversized selection/instruction.
export function selectionPrompt(input: SelectionPromptInput): string | null {
  const start = input.start_line
  const end = input.end_line ?? start
  if (!Number.isInteger(start) || !Number.isInteger(end) || start < 1 || end < start) return null
  if (!input.path || utf8Bytes(input.text) > MAX_SELECTION_BYTES || utf8Bytes(input.instruction) > MAX_INSTRUCTION_BYTES) return null
  let out = `In \`${displayPath(input.path, input.roots)}\` `
  out += end === start ? `line ${start}` : `lines ${start}\u2013${end}`
  if (input.side) out += ` (diff, ${input.side} side)`
  out += ':\n'
  // A selection containing a fence gets a longer one so it cannot close early.
  const ticks = Math.max(3, ...[...input.text.matchAll(/`+/g)].map((match) => match[0].length + 1))
  const fence = '`'.repeat(ticks)
  const body = input.text.replace(/[\r\n]+$/, '')
  return `${out}${fence}${fenceLanguage(input.path)}\n${body}\n${fence}\n${input.instruction.replace(/^[ \t\r\n]+|[ \t\r\n]+$/g, '')}`
}

/// Image bytes from a base64 `read` result, as an object URL the caller revokes.
export function imageObjectUrl(read: Pick<FileRead, 'content' | 'mime' | 'encoding'>): string | null {
  if (read.encoding !== 'base64' || !read.content) return null
  try {
    const binary = atob(read.content)
    const bytes = new Uint8Array(binary.length)
    for (let i = 0; i < binary.length; i += 1) bytes[i] = binary.charCodeAt(i)
    // Only raster types render; SVG never reaches here (the daemon marks it external).
    const mime = read.mime && /^image\/(png|jpeg|gif|webp|bmp)$/.test(read.mime) ? read.mime : 'application/octet-stream'
    return URL.createObjectURL(new Blob([bytes], { type: mime }))
  } catch {
    return null
  }
}
