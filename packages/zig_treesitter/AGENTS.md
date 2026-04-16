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

## Development Prerequisite

Developers working on this package need the Tree-sitter C library and headers installed on their machine.

Linux:
```bash
sudo apt-get install libtree-sitter-dev pkg-config
```

macOS:
```bash
brew install tree-sitter
```
