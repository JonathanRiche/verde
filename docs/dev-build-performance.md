# Desktop build performance

Run benchmarks from the repository root after acquiring Verde's `build`
lease. The benchmark helper uses the production LLVM backend through the
configured `mise run dev-build`; it samples the largest descendant Zig
compiler process every 50 ms.

```sh
scripts/dev/benchmark-dev-build.sh <label>
```

For invalidation measurements, make exactly one stated source edit, run the
helper once, and restore the edit before the next case. Record artifact mtimes
and sizes before and after the command to identify which executable rebuilt.

## 2026-09-03 baseline

Host measurement with Zig 0.16.0, `ReleaseSafe`, native webview, and LLVM:

| Case | Wall time | Peak Zig RSS | GUI text size | Rebuilt artifact |
| --- | ---: | ---: | ---: | --- |
| No-op `dev-build` | 0.415 s | 52,716 KiB | 79,241,224 bytes | none |
| Comment-only `ui/colors.zig` | 234.899 s | 4,109,928 KiB | 79,241,224 bytes before edit | monolithic `verde` |
| One-line UI color behavior | 230.587 s | 4,251,536 KiB | measured after phase work | monolithic `verde` |
| One-line provider log behavior | 231.216 s | 4,123,408 KiB | measured after phase work | monolithic `verde` |

The compiler trace for a UI-only edit included CLI completion, provider
implementations, daemon/store code, SQLite, SDL/Palette, and terminal rendering
in one `build-exe` invocation. The final LLVM object emission exceeded 4 GiB
RSS.

## Refactor measurements

Each retained phase was checked against the same `ReleaseSafe` LLVM build. The
Phase 1 and 2 changes landed together because the private GUI artifact is the
first boundary that makes the dependency cut measurable. Phases 3 and 4 were
also integrated together because removing the concrete provider and database
implementations required their typed daemon RPC replacements first.

| Retained cut | Invalidated GUI wall time | Peak Zig RSS | GUI text size | Evidence |
| --- | ---: | ---: | ---: | --- |
| Phases 1–2: lightweight daemon client + private GUI artifact | 190.782 s | 3,526,208 KiB | 69,311,720 bytes | only `verde-gui` rebuilt |
| Phases 3–4: provider RPC + daemon-owned persistence | 171.958 s | 3,215,324 KiB | 59,927,776 bytes | boundary artifact check passed |
| Final source-fingerprint cut | 172.289 s | 3,256,000 KiB | 59,927,776 bytes | aggregate tests and CLI polling no longer import the backend graph into `main.zig` |

## Final edit matrix

| Case | Wall time | Peak Zig RSS | Rebuilt artifact |
| --- | ---: | ---: | --- |
| No-op `dev-build` | 0.297 s | 52,656 KiB | none |
| Comment-only `ui/colors.zig` | 171.958 s | 3,215,324 KiB | `verde-gui` only |
| One-line UI drag-threshold behavior | 172.440 s | 3,196,800 KiB | `verde-gui` only |
| One-line concrete OpenCode behavior | 0.299 s | 52,620 KiB | none |

The public launcher and daemon mtimes remained unchanged for both UI samples.
After removing the final test-only source edges, the GUI mtime also remained
unchanged for the provider sample. `scripts/dev/check-gui-dependency-boundary.sh`
checks the final ELF symbol table and debug strings for the sessionizer server,
daemon store, SQLite/zqlite database implementation, concrete native provider
implementations, and provider process ownership.

The requested no-op and backend-isolation targets are met. The 45–60 second UI
edit and sub-2-GiB peak-RSS targets are not met: Zig 0.16 still emits SDL,
Palette, terminal, browser, input, rendering, and GUI state as one LLVM object.
Splitting that remaining native UI graph would require a stable compiled ABI
inside normal UI/state code, which this refactor intentionally does not add.
The self-hosted x86 backend was never enabled.

Final installed executable sizes after `mise run build`:

| Artifact | Role | Size |
| --- | --- | ---: |
| `zig-out/bin/verde` | public CLI and GUI launcher | 21,812,496 bytes |
| `zig-out/bin/verde-gui` | private native desktop UI | 59,927,776 bytes |
| `zig-out/bin/verde-daemon` | session, provider, and persistence owner | 30,099,048 bytes |
