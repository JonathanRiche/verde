# fff Patch Queue

These patches are reapplied by `scripts/vendor/update-fff.sh` after the upstream snapshot is copied into `vendor/fff`.

Rules:

- Patch files must be standard unified diffs rooted at the repo root, so paths should start with `vendor/fff/...`.
- Patches apply in lexical order. Name them with a numeric prefix such as `0001-...patch`.
- Keep patches small and Verde-specific. If a change belongs upstream, send it upstream and delete the local patch once it lands.
- After changing `vendor/fff`, capture the diff as a new patch instead of relying on undocumented manual edits.

Typical refresh flow:

```bash
scripts/vendor/update-fff.sh --ref <tag-or-commit>
zig build test
```

If you refresh from a local tarball or other non-git snapshot, pass the upstream
commit explicitly:

```bash
scripts/vendor/update-fff.sh --source /path/to/fff.nvim --ref v0.4.2 --commit <upstream-sha>
```

Adding a new local patch:

```bash
git diff -- vendor/fff > patches/fff/0002-short-description.patch
```

Then rerun the sync script and verify the patch still applies cleanly.
