/**
 * Unified-diff line model shared by every diff view: transcript diff cards,
 * the commit sheet and the Changes panel. Pure so it is unit tested.
 */
import { emphasisSpans } from './highlight'

export type DiffLineKind = 'meta' | 'hunk' | 'add' | 'del' | 'ctx'
export interface DiffLine {
  kind: DiffLineKind
  text: string
  old_no: number | null
  new_no: number | null
  /// [start, end) of the changed span within text, for paired -/+ lines.
  emph?: [number, number]
  /// Hunk header start lines (`@@ -old_start +new_start @@`).
  old_start?: number
  new_start?: number
}
export interface DiffSplitRow {
  full?: DiffLine
  left?: DiffLine
  right?: DiffLine
}

const HUNK_HEADER = /^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@/

export function parsePatchLines(patch: string): DiffLine[] {
  const lines: DiffLine[] = []
  let old_no = 0
  let new_no = 0
  let in_hunk = false
  for (const raw of patch.split('\n')) {
    const hunk = HUNK_HEADER.exec(raw)
    if (hunk) {
      old_no = Number(hunk[1])
      new_no = Number(hunk[2])
      in_hunk = true
      lines.push({ kind: 'hunk', text: raw, old_no: null, new_no: null, old_start: old_no, new_start: new_no })
    } else if (!in_hunk || raw.startsWith('\\')) {
      lines.push({ kind: 'meta', text: raw, old_no: null, new_no: null })
    } else if (raw.startsWith('+')) {
      lines.push({ kind: 'add', text: raw.slice(1), old_no: null, new_no: new_no++ })
    } else if (raw.startsWith('-')) {
      lines.push({ kind: 'del', text: raw.slice(1), old_no: old_no++, new_no: null })
    } else if (raw.startsWith('diff ') || raw.startsWith('index ')) {
      in_hunk = false
      lines.push({ kind: 'meta', text: raw, old_no: null, new_no: null })
    } else {
      lines.push({ kind: 'ctx', text: raw.slice(1), old_no: old_no++, new_no: new_no++ })
    }
  }
  if (lines.at(-1)?.kind === 'ctx' && lines.at(-1)?.text === '') lines.pop()
  markWordEmphasis(lines)
  return lines
}

/// Pairs each run of deletions with the additions that follow it and marks the
/// span between their common prefix and suffix (desktop word-level emphasis).
export function markWordEmphasis(lines: DiffLine[]): void {
  let i = 0
  while (i < lines.length) {
    if (lines[i].kind !== 'del') { i += 1; continue }
    let adds = i
    while (adds < lines.length && lines[adds].kind === 'del') adds += 1
    let end = adds
    while (end < lines.length && lines[end].kind === 'add') end += 1
    const pairs = Math.min(adds - i, end - adds)
    for (let k = 0; k < pairs; k += 1) {
      const a = lines[i + k]
      const b = lines[adds + k]
      const spans = emphasisSpans(a.text, b.text)
      if (!spans) continue
      a.emph = spans.a
      b.emph = spans.b
    }
    i = end
  }
}

export function splitRows(lines: DiffLine[]): DiffSplitRow[] {
  const rows: DiffSplitRow[] = []
  let i = 0
  while (i < lines.length) {
    const line = lines[i]
    if (line.kind === 'meta' || line.kind === 'hunk') { rows.push({ full: line }); i += 1; continue }
    if (line.kind === 'ctx') { rows.push({ left: line, right: line }); i += 1; continue }
    let adds = i
    while (adds < lines.length && lines[adds].kind === 'del') adds += 1
    let end = adds
    while (end < lines.length && lines[end].kind === 'add') end += 1
    const count = Math.max(adds - i, end - adds)
    for (let k = 0; k < count; k += 1) {
      rows.push({
        left: i + k < adds ? lines[i + k] : undefined,
        right: adds + k < end ? lines[adds + k] : undefined,
      })
    }
    i = end
  }
  return rows
}

// ---- Collapsed context ------------------------------------------------------

/// Unchanged lines kept visible on each side of a change.
export const FOLD_KEEP = 3
/// Smaller runs are shown: a fold row costs as much space as one line.
const FOLD_MIN_HIDDEN = 2

/// Hidden unchanged lines. `key` is the first hidden old line number, so the
/// gap between two `-U3` hunks and the matching run of a full-context patch
/// of the same file share a key. `lines` is null when the patch did not
/// carry them (a gap between hunks): revealing it needs more context.
export interface DiffFold { key: number; old_start: number; new_start: number; count: number; lines: DiffLine[] | null }
export type DiffItem = { kind: 'line'; line: DiffLine } | { kind: 'fold'; fold: DiffFold }

/// Lines for a folding view: file headers and `@@` rows are dropped (folds
/// stand in for hunk gaps), long unchanged runs collapse to fold rows unless
/// their key is in `revealed`. Trailing context after the last hunk of a
/// short-context patch is unknown and not offered.
export function foldPatchLines(lines: DiffLine[], revealed: ReadonlySet<number> = new Set(), keep = FOLD_KEEP): DiffItem[] {
  const items: DiffItem[] = []
  // Next old/new line number after the previous hunk; null before the first.
  let old_next: number | null = null
  let new_next: number | null = null
  let i = 0
  const emitRun = (run: DiffLine[], before_change: boolean, after_change: boolean) => {
    const lead = before_change ? keep : 0
    const trail = after_change ? keep : 0
    const hidden = run.length - lead - trail
    if (hidden < FOLD_MIN_HIDDEN) { for (const line of run) items.push({ kind: 'line', line }); return }
    const head = run.slice(0, lead)
    const body = run.slice(lead, lead + hidden)
    const tail = run.slice(lead + hidden)
    for (const line of head) items.push({ kind: 'line', line })
    const key = body[0].old_no ?? 0
    if (revealed.has(key)) for (const line of body) items.push({ kind: 'line', line })
    else items.push({ kind: 'fold', fold: { key, old_start: key, new_start: body[0].new_no ?? 0, count: hidden, lines: body } })
    for (const line of tail) items.push({ kind: 'line', line })
  }
  while (i < lines.length) {
    const line = lines[i]
    if (line.kind === 'meta') { i += 1; continue }
    if (line.kind === 'hunk') {
      const old_start = line.old_start ?? 1
      const new_start = line.new_start ?? 1
      // An added/deleted file's side starts at 0 (`-0,0` / `+0,0`).
      const gap_from = old_next ?? 1
      const gap = old_start > 0 ? old_start - gap_from : 0
      if (gap > 0) {
        const new_from = new_next ?? 1
        items.push({ kind: 'fold', fold: { key: gap_from, old_start: gap_from, new_start: new_from, count: gap, lines: null } })
      }
      old_next = old_start
      new_next = new_start
      i += 1
      continue
    }
    if (line.kind === 'ctx') {
      const run: DiffLine[] = []
      const before_change = items.length > 0 && items.at(-1)!.kind === 'line' && isChange(items.at(-1)!)
      while (i < lines.length && lines[i].kind === 'ctx') run.push(lines[i++])
      const after_change = i < lines.length && (lines[i].kind === 'add' || lines[i].kind === 'del')
      emitRun(run, before_change, after_change)
      const last = run.at(-1)!
      old_next = (last.old_no ?? 0) + 1
      new_next = (last.new_no ?? 0) + 1
      continue
    }
    items.push({ kind: 'line', line })
    if (line.old_no != null) old_next = line.old_no + 1
    if (line.new_no != null) new_next = line.new_no + 1
    i += 1
  }
  return items
}

const isChange = (item: DiffItem): boolean => item.kind === 'line' && (item.line.kind === 'add' || item.line.kind === 'del')

export type DiffSplitItem = { kind: 'row'; row: DiffSplitRow } | { kind: 'fold'; fold: DiffFold }

/// Side-by-side rows for a folding view; folds stay full-width rows.
export function splitItems(items: DiffItem[]): DiffSplitItem[] {
  const out: DiffSplitItem[] = []
  let run: DiffLine[] = []
  const flush = () => { for (const row of splitRows(run)) out.push({ kind: 'row', row }); run = [] }
  for (const item of items) {
    if (item.kind === 'line') { run.push(item.line); continue }
    flush()
    out.push(item)
  }
  flush()
  return out
}

/// True when any fold still needs a wider-context patch to reveal.
export const hasUnloadedFold = (items: DiffItem[]): boolean => items.some((item) => item.kind === 'fold' && item.fold.lines === null)

/// Proportional +/- bar (GitHub style): `slots` cells, at least one per
/// non-zero side once the bar has two cells.
export function changeBar(additions: number, deletions: number, slots = 5): Array<'add' | 'del' | 'none'> {
  const total = additions + deletions
  if (total <= 0) return Array(slots).fill('none')
  const scale = Math.min(1, Math.log10(total + 1) / 2) // 100+ lines fill the bar
  const filled = Math.max(1, Math.round(slots * scale))
  let adds = Math.round((filled * additions) / total)
  if (filled > 1 && additions > 0 && adds === 0) adds = 1
  if (filled > 1 && deletions > 0 && adds === filled) adds = filled - 1
  const dels = filled - adds
  return [...Array(adds).fill('add'), ...Array(dels).fill('del'), ...Array(slots - filled).fill('none')]
}

// ---- Line selection --------------------------------------------------------------

export type DiffSide = 'old' | 'new'
/// One side's 1-based inclusive line range, ordered.
export interface DiffLineSelection { side: DiffSide; start: number; end: number }

/// The side a stacked row's line number refers to: removals are old lines,
/// additions and context are new ones.
export const stackedSide = (line: DiffLine): DiffSide => (line.kind === 'del' ? 'old' : 'new')

/// Line number of `line` on `side`, or null when it has none there.
export function lineNumberOn(line: DiffLine, side: DiffSide): number | null {
  if (line.kind === 'ctx') return side === 'old' ? line.old_no : line.new_no
  if (line.kind === 'del') return side === 'old' ? line.old_no : null
  if (line.kind === 'add') return side === 'new' ? line.new_no : null
  return null
}

/// Text of the patch lines on the selection's side (lines outside the
/// patch's loaded context are absent).
export function diffSelectionText(lines: DiffLine[], selection: DiffLineSelection): string {
  const out: string[] = []
  for (const line of lines) {
    const no = lineNumberOn(line, selection.side)
    if (no != null && no >= selection.start && no <= selection.end) out.push(line.text)
  }
  return out.join('\n')
}
