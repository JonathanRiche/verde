# zig_treesitter

Typed Zig wrappers around the system Tree-sitter C library.

## Prerequisite

This package expects Tree-sitter to be installed on the development machine.

Linux:

```bash
sudo apt-get install libtree-sitter-dev pkg-config
```

macOS:

```bash
brew install tree-sitter
```

## Scope

This package owns:
- Tree-sitter C API bindings
- typed Zig wrappers for parser, tree, node, cursor, and query primitives
- small ergonomic helpers around common operations

This package does not own:
- grammar repos
- diff logic
- UI rendering
