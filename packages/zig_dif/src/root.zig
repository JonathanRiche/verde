//! Public package entrypoint for unified diff parsing and AST access.

const std = @import("std");

pub const ast = @import("ast.zig");
pub const parser = @import("parser.zig");

pub const Document = ast.Document;
pub const File = ast.File;
pub const Hunk = ast.Hunk;
pub const Line = ast.Line;
pub const LineKind = ast.LineKind;
pub const ParseError = parser.ParseError;

/// Parses unified diff text into an owned document AST.
pub fn parseUnifiedDiff(allocator: std.mem.Allocator, input: []const u8) ParseError!Document {
    return parser.parseUnifiedDiff(allocator, input);
}

test {
    _ = ast;
    _ = parser;
}
