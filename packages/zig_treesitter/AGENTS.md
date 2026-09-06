# Tree-sitter wrapper

Follow the [root Zig rules](../../AGENTS.md).

- Keep this package focused on safe C bindings and typed parser/tree/node/cursor/query helpers; no diff logic or UI.
- Compile bundled Tree-sitter from `vendor/tree-sitter` into consumers. Never add system `pkg-config`, Homebrew, or distro Tree-sitter linkage.
