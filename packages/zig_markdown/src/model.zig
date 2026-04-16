//! Markdown document and block model for thread rendering.

const std = @import("std");

pub const Allocator = std.mem.Allocator;

pub const Span = struct {
    start_line: usize,
    end_line: usize,
    start_byte: usize,
    end_byte: usize,
};

pub const BlockKind = enum {
    blank,
    paragraph,
    fenced_code,
};

pub const Fence = struct {
    marker: u8,
    length: usize,
};

pub const Paragraph = struct {
    span: Span,
    text: []const u8,
};

pub const FencedCodeBlock = struct {
    span: Span,
    fence: Fence,
    info: []const u8,
    language: ?[]const u8,
    code: []const u8,
};

pub const Block = union(enum) {
    blank: Span,
    paragraph: Paragraph,
    fenced_code: FencedCodeBlock,

    pub fn kind(self: Block) BlockKind {
        return switch (self) {
            .blank => .blank,
            .paragraph => .paragraph,
            .fenced_code => .fenced_code,
        };
    }

    pub fn span(self: Block) Span {
        return switch (self) {
            .blank => |value| value,
            .paragraph => |value| value.span,
            .fenced_code => |value| value.span,
        };
    }
};

pub const Document = struct {
    source: []const u8,
    blocks: []Block,

    pub fn deinit(self: *Document, allocator: Allocator) void {
        allocator.free(self.blocks);
        self.* = undefined;
    }

    pub fn blockCount(self: Document) usize {
        return self.blocks.len;
    }

    pub fn blockAt(self: Document, index: usize) Block {
        return self.blocks[index];
    }
};
