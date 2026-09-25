# K-11 rendering queries

Use `vc_host_query` (JNI `hostQuery`) with the UTF-8 JSON selectors in
[core-api §9](core-api.md#9-pure-rendering-utilities-k-11). No new ABI symbols
or host state are required. Results use the normal `{api_version, revision,
data, error}` envelope. Queries preserve revision, pending work, and receipts.
Returned buffers remain valid until `vc_buf_free`, including after host free.

- `markdown`: `data.nodes` contains one document node. Blocks and recursive
  inline children come from `zig_markdown`. Raw HTML remains text; it must
  never be passed to a native HTML/web renderer. Link URLs admit HTTP, HTTPS,
  mailto and relative destinations; executable/data/protocol-relative URLs
  are null. Images are abstract nodes and cause no fetching.
- `highlight`: `data.spans` contains ordered, disjoint, half-open byte ranges.
  Kinds follow the desktop `zig_dif.syntax.TokenKind` vocabulary. The bundled
  default grammars are JavaScript/JSX, TypeScript, TSX and JSON (`js`/`ts`
  aliases accepted). Other languages return an empty array; render the source
  as plain text. The whole code block is parsed, preserving multiline context.
- `diff`: `data.files` contains files, hunks and lines, including optional
  one-based old/new line numbers. `VERDE_DIFF_V2` uses four tab-separated
  numeric fields (path byte length, additions, deletions, patch byte length),
  followed immediately by the path and patch bytes; records have no separator.
  Numeric fields follow web `Number`/safe-integer validation (the writer emits
  decimal integers). Counts are validated but not exposed as a second source of truth. Plain
  unified patches use the same `zig_dif` parser. Word spans reuse desktop
  side-by-side change alignment, with no context collapsing. `/dev/null`
  becomes a null path; other patch paths are preserved verbatim (including
  Git a/b prefixes). Missing-newline notices become `meta` lines. Empty V2
  patches remain file entries; binary patches have `binary:true`.

All ranges refer to the original UTF-8 source, or to a returned diff line's
text. Inline ranges describe content; block ranges can include delimiters and
quote/list prefixes. Convert byte ranges to Kotlin UTF-16 or Swift String
indices before slicing. Never interpret a byte offset as a character index.
Null optionals and empty arrays are explicit. Native renderers should use the
node hierarchy rather than reparsing source slices.

File links and `:codex-file-citation{path="..."}` directives become abstract
`{path,line}` citations. Absolute/file URLs support `:42` and `#L42` line
suffixes; local `/api/file?path=...` and `/api/preview?path=...` links support
percent-decoded paths. These are navigation requests, not filesystem access
or authorization. Platform routing must enforce its own host/workspace access.
Code spans and fenced code never activate citation directives.

Limits: 64 KiB text, 1 MiB encoded utility data, 4096 markdown nodes, 32
projection levels, and 4096 diff lines per patch/hunk side, and 65,536 change-alignment matrix
cells per patch. A conservative
64 markdown nesting-marker bytes per source line and 512 per paragraph
(outside fences) bound the shared parser's
recursive input before parsing. Unknown utilities return `unsupported`;
malformed utility fields/diffs return `invalid_input`; budget exhaustion
returns `resource_limit`. Those are query-envelope errors with null data;
malformed selector JSON still uses ABI status 1. Render source text on errors.
No utility opens files, fetches grammars/links, spawns threads or reads clocks.

Golden JSON fixtures live in `src/fixtures/render-*.json`; tests also port the
web markdown security/citation inputs and highlight changed-middle/emoji
cases. There was no standalone `parseDiffV2` test at the implementation base;
V2 tests cover its byte framing, safe integer limits, Unicode, embedded path
tabs/newlines, multiple records, truncation and empty patches. DOM-only
sanitizer/clipboard/widget tests do not apply to this data-only ABI.

## Android footprint

ReleaseSafe, Zig 0.16 / NDK 30, compared with the K-15 core at `8b246bf2`:

| ABI | Before, stripped | K-11, stripped | Increase | K-11, unstripped |
| --- | ---: | ---: | ---: | ---: |
| arm64-v8a | 358,688 B | 3,948,104 B | 3,589,416 B | 7,675,960 B |
| x86_64 | 400,416 B | 4,036,416 B | 3,636,000 B | 7,632,120 B |

Stripped measurements use the NDK's `llvm-strip --strip-all` on copies of the
outputs. Keep all four bundled grammars: about 3.5 MiB extra per installed ABI
is reasonable for the default coding languages. No online grammar downloads
or new shared-library dependency is required. The unchanged Android checker
passes for both ABIs: only libc/liblog are needed; LOAD alignment is 0x4000.
Android header translation alone removes bionic fortify/nullability annotations
and supplies the target API macros; the compiled C runtime retains its normal
NDK headers and flags.
