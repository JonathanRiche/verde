# AGENTS.md

## Zig Development

Always use `zigdoc` to discover APIs for the Zig standard library and any third-party dependencies.

Examples:
```bash
zigdoc std.fs
zigdoc tree_sitter.Parser
zigdoc tree_sitter.Node
```

## Package Goal

`packages/zig_treesitter` is the typed Zig wrapper around the system Tree-sitter C library.

Keep this package focused on:
- binding the C API safely
- converting raw handles and values into typed Zig wrappers
- ergonomic helpers for parser, tree, node, cursor, and query usage

Do not put diff logic or UI code here.

## Dependency Model

The core Tree-sitter C library is bundled under `vendor/tree-sitter` and compiled into consumers. Do not add a system `pkg-config` dependency for Tree-sitter; release builds must not link to Homebrew or distro Tree-sitter dylibs.
