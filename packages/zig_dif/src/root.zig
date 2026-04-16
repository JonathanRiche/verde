//! Public package entrypoint for unified diff parsing and AST access.

const std = @import("std");

pub const ast = @import("ast.zig");
pub const parser = @import("parser.zig");
pub const syntax = @import("syntax.zig");
pub const view = @import("view.zig");

pub const Document = ast.Document;
pub const File = ast.File;
pub const Hunk = ast.Hunk;
pub const Line = ast.Line;
pub const LineKind = ast.LineKind;
pub const ParseError = parser.ParseError;
pub const Language = syntax.Language;
pub const Token = syntax.Token;
pub const TokenKind = syntax.TokenKind;
pub const DisplayLine = view.DisplayLine;
pub const DisplayLineKind = view.DisplayLineKind;
pub const BuildOptions = view.BuildOptions;
pub const CollapsedContext = view.CollapsedContext;
pub const PatchView = view.PatchView;
pub const SideBySideCell = view.SideBySideCell;
pub const SideBySideRow = view.SideBySideRow;
pub const SideBySideRowKind = view.SideBySideRowKind;
pub const SideBySidePatchView = view.SideBySidePatchView;

/// Parses unified diff text into an owned document AST.
pub fn parseUnifiedDiff(allocator: std.mem.Allocator, input: []const u8) ParseError!Document {
    return parser.parseUnifiedDiff(allocator, input);
}

/// Parses unified diff text into a flattened render-oriented view.
pub fn buildPatchView(allocator: std.mem.Allocator, input: []const u8) ParseError!PatchView {
    return view.buildPatchView(allocator, input);
}

pub fn buildPatchViewWithOptions(allocator: std.mem.Allocator, input: []const u8, options: BuildOptions) ParseError!PatchView {
    return view.buildPatchViewWithOptions(allocator, input, options);
}

/// Parses unified diff text into an aligned side-by-side view.
pub fn buildSideBySidePatchView(allocator: std.mem.Allocator, input: []const u8) ParseError!SideBySidePatchView {
    return view.buildSideBySidePatchView(allocator, input);
}

pub fn buildSideBySidePatchViewWithOptions(
    allocator: std.mem.Allocator,
    input: []const u8,
    options: BuildOptions,
) ParseError!SideBySidePatchView {
    return view.buildSideBySidePatchViewWithOptions(allocator, input, options);
}

test {
    _ = ast;
    _ = parser;
    _ = syntax;
    _ = view;
}
