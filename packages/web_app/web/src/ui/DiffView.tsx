/**
 * Shared unified-diff renderer: stacked or split, word-level emphasis, and
 * (for the Changes panel) collapsed unchanged context. Transcript diff cards
 * and the commit sheet render plain patches; the panel passes `fold` and
 * `select` (clickable line numbers for asking a chat about lines).
 */
import { For, Show, createMemo, createSignal } from 'solid-js'

import {
  type DiffFold, type DiffLine, type DiffLineKind, type DiffLineSelection, type DiffSide,
  foldPatchLines, lineNumberOn, parsePatchLines, splitItems, splitRows, stackedSide,
} from '../lib/diff_lines'

export type DiffLayout = 'stacked' | 'split'
const DIFF_LAYOUT_KEY = 'verde.web.diff_layout'
function readDiffLayout(): DiffLayout {
  try {
    return localStorage.getItem(DIFF_LAYOUT_KEY) === 'split' ? 'split' : 'stacked'
  } catch {
    return 'stacked'
  }
}
// One preference for every diff view (desktop parity), so it is module state.
const [diffLayout, setDiffLayoutSignal] = createSignal<DiffLayout>(readDiffLayout())
export { diffLayout }
export function setDiffLayout(layout: DiffLayout) {
  setDiffLayoutSignal(layout)
  try {
    localStorage.setItem(DIFF_LAYOUT_KEY, layout)
  } catch {
    // Private mode: the preference just lasts for this page.
  }
}
// Split needs two readable columns; below lg it always renders stacked.
const wideQuery = typeof matchMedia === 'function' ? matchMedia('(min-width: 1024px)') : null
const [wideScreen, setWideScreen] = createSignal(wideQuery?.matches ?? false)
wideQuery?.addEventListener('change', (event) => setWideScreen(event.matches))
export { wideScreen }

/// Stacked | Split segmented control; hidden below lg where split never shows.
export function DiffLayoutToggle(props: { class?: string }) {
  return (
    <div role="group" aria-label="Diff layout" class={`hidden shrink-0 overflow-hidden rounded-[6px] bg-[var(--panel-muted)] text-[11px] lg:flex ${props.class ?? ''}`}>
      <For each={['stacked', 'split'] as const}>
        {(layout) => (
          <button
            type="button"
            aria-pressed={diffLayout() === layout}
            class={`px-2.5 py-1 capitalize ${diffLayout() === layout ? 'bg-[var(--accent-wash)] text-[var(--text)]' : 'text-[var(--text-muted)] hover:text-[var(--text)]'}`}
            onClick={() => setDiffLayout(layout)}
          >
            {layout}
          </button>
        )}
      </For>
    </div>
  )
}

function diffTextClass(kind: DiffLineKind): string {
  if (kind === 'add') return 'text-[var(--diff-add)]'
  if (kind === 'del') return 'text-[var(--danger)]'
  if (kind === 'ctx') return 'text-[var(--text-muted)]'
  return 'text-[var(--text-subtle)]'
}

function DiffText(props: { line: DiffLine }) {
  const emph = () => props.line.emph
  return (
    <Show when={emph() && emph()![1] > emph()![0]} fallback={<>{props.line.text.length > 0 ? props.line.text : ' '}</>}>
      {props.line.text.slice(0, emph()![0])}
      <span class={props.line.kind === 'add' ? 'diff-emph-add' : 'diff-emph-del'}>
        {props.line.text.slice(emph()![0], emph()![1])}
      </span>
      {props.line.text.slice(emph()![1])}
    </Show>
  )
}

/// Line selection for "ask about these lines" (one side at a time).
export interface DiffSelectControls {
  selection: DiffLineSelection | null
  /// A line number was pressed; `extend` (shift) grows the range from its anchor.
  onLine: (side: DiffSide, line: number, extend: boolean) => void
}

/// Line-number gutter; a button when the patch is selectable.
function LineNo(props: { no: number | null; side: DiffSide; select?: DiffSelectControls }) {
  const selected = () => {
    const range = props.select?.selection
    return !!range && props.no != null && range.side === props.side && props.no >= range.start && props.no <= range.end
  }
  return (
    <Show when={props.select && props.no != null} fallback={<span class="diff-no">{props.no ?? ''}</span>}>
      <span
        class="diff-no diff-no-select"
        classList={{ 'diff-no-selected': selected() }}
        role="button"
        tabIndex={-1}
        aria-label={`Select ${props.side} line ${props.no}`}
        aria-pressed={selected()}
        onPointerDown={(event) => { event.preventDefault(); props.select!.onLine(props.side, props.no!, event.shiftKey) }}
      >{props.no}</span>
    </Show>
  )
}

function DiffCell(props: { line?: DiffLine; side: DiffSide; select?: DiffSelectControls }) {
  return (
    <Show when={props.line} fallback={<><span class="diff-no" aria-hidden="true" /><span class="diff-blank" aria-hidden="true" /></>}>
      {(line) => (
        <>
          <LineNo no={(props.side === 'old' ? line().old_no : line().new_no) ?? null} side={props.side} select={props.select} />
          <span class={`diff-text diff-bg-${line().kind} ${diffTextClass(line().kind)}`}>
            <span class="diff-sign">{line().kind === 'add' ? '+' : line().kind === 'del' ? '−' : ' '}</span>
            <DiffText line={line()} />
          </span>
        </>
      )}
    </Show>
  )
}

function FullRow(props: { line: DiffLine }) {
  return <span class={`diff-full ${diffTextClass(props.line.kind)}`}>{props.line.text.length > 0 ? props.line.text : ' '}</span>
}

function StackedLine(props: { line: DiffLine; select?: DiffSelectControls }) {
  return (
    <Show when={props.line.kind !== 'meta' && props.line.kind !== 'hunk'} fallback={<FullRow line={props.line} />}>
      <LineNo no={lineNumberOn(props.line, stackedSide(props.line))} side={stackedSide(props.line)} select={props.select} />
      <span class={`diff-text diff-bg-${props.line.kind} ${diffTextClass(props.line.kind)}`}>
        <span class="diff-sign">{props.line.kind === 'add' ? '+' : props.line.kind === 'del' ? '-' : ' '}</span>
        <DiffText line={props.line} />
      </span>
    </Show>
  )
}

/// Collapsed-context controls for the folding view.
export interface DiffFoldControls {
  /// Fold keys the user expanded.
  revealed: ReadonlySet<number>
  /// Expand one fold. Folds without lines need a wider-context patch.
  onReveal: (fold: DiffFold) => void
  /// Key of the fold whose context is being fetched.
  pending?: number | null
}

function FoldRow(props: { fold: DiffFold; controls: DiffFoldControls; path: string }) {
  const loading = () => props.controls.pending === props.fold.key
  const count = () => `${props.fold.count.toLocaleString()} unchanged ${props.fold.count === 1 ? 'line' : 'lines'}`
  return (
    <button
      type="button"
      class="diff-fold"
      disabled={loading()}
      aria-label={`Show ${count()} from line ${props.fold.new_start} in ${props.path}`}
      onClick={() => props.controls.onReveal(props.fold)}
    >
      <span aria-hidden="true">⋯</span>
      <span>{loading() ? 'Loading…' : count()}</span>
    </button>
  )
}

const MAX_ROWS = 2000

export function DiffPatch(props: { patch: string; path: string; fold?: DiffFoldControls; split?: boolean; select?: DiffSelectControls }) {
  const [showAll, setShowAll] = createSignal(false)
  const allLines = createMemo(() => parsePatchLines(props.patch))
  const split = () => props.split ?? (diffLayout() === 'split' && wideScreen())
  const folded = createMemo(() => (props.fold ? foldPatchLines(allLines(), props.fold.revealed) : null))
  const total = () => folded()?.length ?? allLines().length
  const lines = createMemo(() => showAll() ? allLines() : allLines().slice(0, MAX_ROWS))
  const items = createMemo(() => { const all = folded() ?? []; return showAll() ? all : all.slice(0, MAX_ROWS) })
  return (
    <div class="mono diff-patch mb-2 max-w-full overflow-x-auto text-[12.5px] leading-[1.45] scrollbar-thin">
      <Show
        when={props.fold}
        fallback={
          <Show
            when={split()}
            fallback={<div class="diff-grid diff-grid-stacked"><For each={lines()}>{(line) => <StackedLine line={line} select={props.select} />}</For></div>}
          >
            <div class="diff-grid diff-grid-split">
              <For each={splitRows(lines())}>
                {(row) => (
                  <Show when={!row.full} fallback={<FullRow line={row.full!} />}>
                    <DiffCell line={row.left} side="old" select={props.select} />
                    <DiffCell line={row.right} side="new" select={props.select} />
                  </Show>
                )}
              </For>
            </div>
          </Show>
        }
      >
        {(controls) => (
          <Show
            when={split()}
            fallback={
              <div class="diff-grid diff-grid-stacked">
                <For each={items()}>
                  {(item) => item.kind === 'fold'
                    ? <FoldRow fold={item.fold} controls={controls()} path={props.path} />
                    : <StackedLine line={item.line} select={props.select} />}
                </For>
              </div>
            }
          >
            <div class="diff-grid diff-grid-split">
              <For each={splitItems(items())}>
                {(item) => item.kind === 'fold'
                  ? <FoldRow fold={item.fold} controls={controls()} path={props.path} />
                  : (
                    <Show when={!item.row.full} fallback={<FullRow line={item.row.full!} />}>
                      <DiffCell line={item.row.left} side="old" select={props.select} />
                      <DiffCell line={item.row.right} side="new" select={props.select} />
                    </Show>
                  )}
              </For>
            </div>
          </Show>
        )}
      </Show>
      <Show when={!showAll() && total() > MAX_ROWS}>
        <button type="button" class="diff-show-all" aria-label={`Show all ${total()} patch lines for ${props.path}`} onClick={() => setShowAll(true)}>
          Showing 2,000 of {total().toLocaleString()} lines · Show all
        </button>
      </Show>
    </div>
  )
}
