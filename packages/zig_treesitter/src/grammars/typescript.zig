//! Vendored Tree-sitter TypeScript grammar accessors.

const root = @import("../root.zig");

extern fn tree_sitter_typescript() *const root.c.TSLanguage;

pub fn language() root.Language {
    return .{ .raw = tree_sitter_typescript() };
}

pub const highlights_query =
    @embedFile("../queries/javascript-highlights.scm") ++
    "\n" ++
    @embedFile("../queries/typescript-highlights.scm");
