//! Raw cImport surface for the Tree-sitter C API.

pub const bindings = @cImport({
    @cInclude("tree_sitter/api.h");
});
