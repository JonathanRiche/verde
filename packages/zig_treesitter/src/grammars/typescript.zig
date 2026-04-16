//! Vendored Tree-sitter TypeScript grammar accessors.

const root = @import("../root.zig");

extern fn tree_sitter_typescript() *const root.c.TSLanguage;
extern fn tree_sitter_tsx() *const root.c.TSLanguage;

pub fn language() root.Language {
    return .{ .raw = tree_sitter_typescript() };
}

pub fn tsxLanguage() root.Language {
    return .{ .raw = tree_sitter_tsx() };
}

pub const highlights_query =
    @embedFile("../queries/javascript-highlights.scm") ++
    "\n" ++
    @embedFile("../queries/typescript-highlights.scm");

pub const tsx_highlights_query =
    @embedFile("../queries/javascript-highlights.scm") ++
    "\n" ++
    @embedFile("../queries/javascript-jsx-highlights.scm") ++
    "\n" ++
    @embedFile("../queries/typescript-highlights.scm");
