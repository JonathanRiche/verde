# zig_markdown

`zig_markdown` is the reusable markdown parser package for Verde.

It provides a small document model built around:

- paragraph blocks
- blank blocks
- fenced code blocks with parsed info/language hints

The parser is intentionally line-oriented so it can stay useful for thread
rendering and code-fence handling without pulling in extra dependencies.

## Development

No extra system packages are required for this package.

On Arch, the only prerequisite is a working Zig toolchain:

```bash
zig build test
```

Run that from `packages/zig_markdown/` to execute the package tests.
