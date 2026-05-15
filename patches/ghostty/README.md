# ghostty Patch Queue

These patches are reapplied after the upstream Ghostty snapshot in
`packages/ghostty/` is refreshed. Verde consumes only the
`ghostty-vt` module; everything else (UI, apprt, GTK) is unbuilt.

Rules:

- Patch files must be standard unified diffs rooted at the repo root,
  so paths should start with `packages/ghostty/...`.
- Patches apply in lexical order. Name them with a numeric prefix
  such as `0001-...patch`.
- Keep patches small and Verde-specific. Send fixes upstream where
  possible and delete the local patch once they land.
- After editing `packages/ghostty/`, capture the diff as a new patch
  instead of relying on undocumented manual edits.

Adding a new local patch:

```bash
git diff -- packages/ghostty > patches/ghostty/0NNN-short-description.patch
```

Refreshing from upstream: re-copy the Ghostty tree into
`packages/ghostty/`, then re-apply each patch in `patches/ghostty/`
in lexical order with `git apply`.

## Current patches

- `0001-os-path-expand-stub-on-windows.patch` —
  `packages/ghostty/src/os/path.zig::expand` used `std.process.getenvW`
  and `std.fs.cwd().openFile`, both removed in Zig 0.16. The function
  is only reached from `build/Config.zig::expandPath("pandoc")` and
  `expandPath("xcodebuild")`, neither of which Verde needs (we consume
  only the `ghostty-vt` module). Replaced the Windows arm with the
  same `return null` behavior the POSIX arm has always had upstream.
  Restore the original walk if a future Verde feature relies on it.
