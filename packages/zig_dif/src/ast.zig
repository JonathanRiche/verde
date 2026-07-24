//! Core AST types for unified diff documents.

const std = @import("std");

pub const LineKind = enum {
    context,
    addition,
    deletion,
};

pub const FileChangeKind = enum {
    unknown,
    modified,
    added,
    deleted,
    renamed,
    binary,
};

pub const Line = struct {
    kind: LineKind,
    text: []const u8,
    missing_newline: bool = false,
};

pub const Hunk = struct {
    header: []const u8,
    old_start: usize,
    old_count: usize,
    new_start: usize,
    new_count: usize,
    lines: []const Line,
};

pub const File = struct {
    old_path: ?[]const u8 = null,
    new_path: ?[]const u8 = null,
    change_kind: FileChangeKind = .unknown,
    is_binary: bool = false,
    header_lines: []const []const u8,
    hunks: []const Hunk,
};

pub const Document = struct {
    arena: std.heap.ArenaAllocator,
    prelude_lines: []const []const u8,
    files: []const File,

    pub fn deinit(self: *Document) void {
        self.arena.deinit();
        self.* = undefined;
    }
};
