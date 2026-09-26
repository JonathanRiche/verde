# D-07 diff card fixtures

Everything here except the `*.golden.txt` / `core-golden.txt` expectations is real
K-11 client-core output. The Android tests only replay it; the fake render source in
`DiffCardTest` fails a test on any query outside the recording.

| File | Contents |
| --- | --- |
| `multi.diff` | Hand-written VERDE_DIFF_V2 body (95,817 bytes, over the 64 KiB per-patch text budget): a two-hunk TS edit with a tab, emoji and missing-newline notice; a new JSON file; a binary file; an empty (mode-only) patch; a 450-line new file; a 4,200-line new file past the 4,096-line patch budget |
| `golden.diff` | The K-11 core golden patch (`client_core/src/fixtures/render-diff.json` input) as a one-file V2 body |
| `core-render-diff.json` | Verbatim copy of `packages/client_core/src/fixtures/render-diff.json` |
| `render.json` | `[{query:{kind,sha256,language?}, result}]`: the core's `diff_index` reply for both bodies, `diff` for every per-file record, and `highlight` for each TS/JSON side, keyed by the SHA-256 of the query text |
| `transcript-render.json` | `diff_index` for the D-06 rich-page diff row, text-keyed like `d06/render.json` |
| `*.golden.txt` | Expected unified rows (`diffGolden`), checked by eye against the core output |

The per-file `diff` result for `golden.diff` equals `core-render-diff.json`.

## Regenerating

Add a temporary test to `packages/client_core` that `@embedFile`s both bodies and, through
`host.Host.query`, prints the `diff_index` reply, then `diff` for
`"VERDE_DIFF_V2\n" ++ body[start..end]` of each entry, then `highlight` (`ts`/`json`) for
each side of that file (old: context + deleted, new: context + added lines, joined by `\n`;
see `sideText`). Run `zig build test --release=safe` (take the `build` lease), rebuild
`render.json` from the output, and revert the temporary test.
