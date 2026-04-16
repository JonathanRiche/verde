//! Vendored Tree-sitter JavaScript grammar accessors.

const root = @import("../root.zig");

extern fn tree_sitter_javascript() *const root.c.TSLanguage;

pub fn language() root.Language {
    return .{ .raw = tree_sitter_javascript() };
}

pub const highlights_query = @embedFile("../queries/javascript-highlights.scm");
pub const jsx_highlights_query =
    @embedFile("../queries/javascript-highlights.scm") ++
    "\n" ++
    @embedFile("../queries/javascript-jsx-highlights.scm");
