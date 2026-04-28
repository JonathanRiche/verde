# zig_treesitter

Typed Zig wrappers around the bundled Tree-sitter C library.

## Scope

This package owns:
- Tree-sitter C API bindings
- typed Zig wrappers for parser, tree, node, cursor, and query primitives
- small ergonomic helpers around common operations

This package does not own:
- grammar repos
- diff logic
- UI rendering
