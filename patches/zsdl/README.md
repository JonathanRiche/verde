# zsdl Patch Queue

Local patches applied on top of the vendored `packages/zsdl/` snapshot.
zsdl is the zig-gamedev SDL3/SDL2 bindings package; Verde consumes the
`zsdl3` module and supplies its own SDL3 runtime.

Rules:

- Patch files must be standard unified diffs rooted at the repo root,
  so paths should start with `packages/zsdl/...`.
- Patches apply in lexical order. Name them with a numeric prefix
  (`0001-`, `0002-`, ...).
- Keep patches small and Verde-specific. Send fixes upstream where
  appropriate and remove the local patch once they land.
- After editing `packages/zsdl/`, capture the diff as a new patch
  instead of leaving undocumented manual edits in place.

Adding a new local patch:

```bash
git diff -- packages/zsdl > patches/zsdl/0NNN-short-description.patch
```

Refreshing from upstream: re-copy the zsdl tree into
`packages/zsdl/`, then re-apply each patch in `patches/zsdl/` in
lexical order with `git apply`.

## Current patches

- `0001-skip-windows-prebuilt.patch` — zsdl's `prebuilt_sdl3` helpers
  call `lazyDependency("sdl3_prebuilt_x86_64_windows_gnu", ...)` from
  inside zsdl's own `build.zig`. The upstream prebuilt's
  `build.zig.zon` predates Zig 0.16's mandatory top-level `fingerprint`
  field, so the request fails during package resolution. The prebuilt
  is a MinGW build; Verde targets `x86_64-windows-msvc` and supplies
  SDL3 via `-Dsdl3-runtime-lib` (Phase 1) or `-Dsdl3-msvc-root`
  (Phase 2). The Windows arms of `addLibraryPathsTo` and `install`
  are now no-ops.
