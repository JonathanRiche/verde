//! Core markdown document model shared across renderers.

const std = @import("std");

pub const Allocator = std.mem.Allocator;

pub const Span = struct {
    start_line: usize,
    end_line: usize,
    start_byte: usize,
    end_byte: usize,
};

pub const TextInline = struct {
    text: []const u8,
};

pub const ContainerInline = struct {
    children: []Inline,
};

pub const CodeInline = struct {
    text: []const u8,
};

pub const LinkInline = struct {
    label: []const u8,
    destination: []const u8,
    children: []Inline,
};

pub const LineBreakKind = enum {
    soft,
    hard,
};

pub const InlineKind = enum {
    text,
    emphasis,
    strong,
    code,
    link,
    line_break,
};

pub const Inline = union(enum) {
    text: TextInline,
    emphasis: ContainerInline,
    strong: ContainerInline,
    code: CodeInline,
    link: LinkInline,
    line_break: LineBreakKind,

    pub fn kind(self: Inline) InlineKind {
        return switch (self) {
            .text => .text,
            .emphasis => .emphasis,
            .strong => .strong,
            .code => .code,
            .link => .link,
            .line_break => .line_break,
        };
    }
};

pub const Paragraph = struct {
    span: Span,
    text: []const u8,
    inlines: []Inline,
};

pub const Heading = struct {
    span: Span,
    level: u8,
    text: []const u8,
    inlines: []Inline,
};

pub const Fence = struct {
    marker: u8,
    length: usize,
};

pub const FencedCodeBlock = struct {
    span: Span,
    fence: Fence,
    info: []const u8,
    language: ?[]const u8,
    code: []const u8,
};

pub const BlockQuote = struct {
    span: Span,
    blocks: []Block,
};

pub const ListKind = enum {
    unordered,
    ordered,
};

pub const ListItem = struct {
    span: Span,
    blocks: []Block,
};

pub const ListBlock = struct {
    span: Span,
    kind: ListKind,
    start_number: usize,
    items: []ListItem,
    loose: bool,
};

pub const BlockKind = enum {
    blank,
    paragraph,
    heading,
    fenced_code,
    block_quote,
    list,
    thematic_break,
};

pub const Block = union(enum) {
    blank: Span,
    paragraph: Paragraph,
    heading: Heading,
    fenced_code: FencedCodeBlock,
    block_quote: BlockQuote,
    list: ListBlock,
    thematic_break: Span,

    pub fn kind(self: Block) BlockKind {
        return switch (self) {
            .blank => .blank,
            .paragraph => .paragraph,
            .heading => .heading,
            .fenced_code => .fenced_code,
            .block_quote => .block_quote,
            .list => .list,
            .thematic_break => .thematic_break,
        };
    }

    pub fn span(self: Block) Span {
        return switch (self) {
            .blank => |value| value,
            .paragraph => |value| value.span,
            .heading => |value| value.span,
            .fenced_code => |value| value.span,
            .block_quote => |value| value.span,
            .list => |value| value.span,
            .thematic_break => |value| value,
        };
    }
};

pub const Document = struct {
    const Self = @This();

    source: []const u8,
    arena: std.heap.ArenaAllocator,
    blocks: []Block,

    pub fn deinit(self: *Self, allocator: Allocator) void {
        _ = allocator;
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn blockCount(self: Self) usize {
        return self.blocks.len;
    }

    pub fn blockAt(self: Self, index: usize) Block {
        return self.blocks[index];
    }
};
