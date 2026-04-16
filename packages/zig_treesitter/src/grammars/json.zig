//! Vendored Tree-sitter JSON grammar accessors.

const root = @import("../root.zig");

extern fn tree_sitter_json() *const root.c.TSLanguage;

pub fn language() root.Language {
    return .{ .raw = tree_sitter_json() };
}

pub const highlights_query = @embedFile("../queries/json-highlights.scm");
