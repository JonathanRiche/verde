//! Reusable markdown body parsing and rendering helpers for chat threads.

const std = @import("std");

const colors = @import("colors.zig");
const zig_dif = @import("zig_dif");
const zig_markdown = @import("zig_markdown");
const zgui = @import("zgui");

const Allocator = std.mem.Allocator;

pub const RenderOptions = struct {
    code_font: ?zgui.Font = null,
    code_font_size: ?f32 = null,
};

pub const ParagraphView = struct {
    span: zig_markdown.Span,
    text: []const u8,
};

pub const CodeLineView = struct {
    text: []const u8,
    tokens: []const zig_dif.Token,
};

pub const FencedCodeView = struct {
    span: zig_markdown.Span,
    info: []const u8,
    language: zig_dif.Language,
    lines: []CodeLineView,

    pub fn deinit(self: *FencedCodeView, allocator: Allocator) void {
        for (self.lines) |line| {
            if (line.tokens.len > 0) allocator.free(line.tokens);
        }
        allocator.free(self.lines);
        self.* = undefined;
    }
};

pub const BlockKind = enum {
    blank,
    paragraph,
    fenced_code,
};

pub const BlockView = union(enum) {
    blank: zig_markdown.Span,
    paragraph: ParagraphView,
    fenced_code: FencedCodeView,

    pub fn kind(self: BlockView) BlockKind {
        return switch (self) {
            .blank => .blank,
            .paragraph => .paragraph,
            .fenced_code => .fenced_code,
        };
    }

    pub fn span(self: BlockView) zig_markdown.Span {
        return switch (self) {
            .blank => |blank_span| blank_span,
            .paragraph => |paragraph| paragraph.span,
            .fenced_code => |code| code.span,
        };
    }
};

pub const BodyView = struct {
    const Self = @This();

    source: []const u8,
    blocks: []BlockView,

    pub fn deinit(self: *Self, allocator: Allocator) void {
        for (self.blocks) |*block| {
            switch (block.*) {
                .fenced_code => |*code| code.deinit(allocator),
                else => {},
            }
        }
        allocator.free(self.blocks);
        self.* = undefined;
    }

    pub fn blockCount(self: Self) usize {
        return self.blocks.len;
    }

    pub fn blockAt(self: Self, index: usize) BlockView {
        return self.blocks[index];
    }
};

/// Parses markdown into a reusable body view with paragraph and fenced code blocks.
pub fn buildBodyView(allocator: Allocator, source: []const u8) !BodyView {
    var document = try zig_markdown.parse(allocator, source);
    defer document.deinit(allocator);

    var blocks: std.ArrayListUnmanaged(BlockView) = .empty;
    errdefer deinitBlockViews(allocator, blocks.items);

    for (document.blocks) |block| {
        switch (block) {
            .blank => |span| try blocks.append(allocator, .{ .blank = span }),
            .paragraph => |paragraph| try blocks.append(allocator, .{
                .paragraph = .{
                    .span = paragraph.span,
                    .text = paragraph.text,
                },
            }),
            .fenced_code => |code| try blocks.append(allocator, .{
                .fenced_code = try buildFencedCodeView(allocator, code),
            }),
        }
    }

    return .{
        .source = source,
        .blocks = try blocks.toOwnedSlice(allocator),
    };
}

/// Renders a parsed markdown body as wrapped paragraphs and fenced code blocks.
pub fn renderBody(view: BodyView, options: RenderOptions) void {
    const available_width = @max(zgui.getContentRegionAvail()[0], 1.0);
    const block_gap = blockGap();

    var previous_kind: ?BlockKind = null;
    for (view.blocks) |block| {
        const kind = block.kind();
        if (previous_kind != null and previous_kind.? != .blank and kind != .blank) {
            zgui.dummy(.{ .w = 0.0, .h = block_gap });
        }

        switch (block) {
            .blank => renderBlankBlock(),
            .paragraph => |paragraph| renderParagraphBlock(paragraph),
            .fenced_code => |code| renderFencedCodeBlock(code, available_width, options),
        }

        previous_kind = kind;
    }
}

/// Measures a parsed markdown body using the current font metrics and code font options.
pub fn measureBodyHeight(view: BodyView, available_width: f32, options: RenderOptions) f32 {
    const width = @max(available_width, 1.0);
    const block_gap = blockGap();

    var total: f32 = 0.0;
    var previous_kind: ?BlockKind = null;
    for (view.blocks) |block| {
        const kind = block.kind();
        if (previous_kind != null and previous_kind.? != .blank and kind != .blank) {
            total += block_gap;
        }

        total += switch (block) {
            .blank => blankBlockHeight(),
            .paragraph => |paragraph| measureParagraphHeight(paragraph, width),
            .fenced_code => |code| measureFencedCodeHeight(code, options),
        };

        previous_kind = kind;
    }

    return total;
}

fn deinitBlockViews(allocator: Allocator, blocks: []BlockView) void {
    for (blocks) |block| {
        switch (block) {
            .fenced_code => |code| {
                var code_copy = code;
                code_copy.deinit(allocator);
            },
            else => {},
        }
    }
    allocator.free(blocks);
}

fn buildFencedCodeView(allocator: Allocator, block: zig_markdown.FencedCodeBlock) !FencedCodeView {
    const language = codeLanguageForTag(block.language);
    const lines = try collectCodeLineSlices(allocator, block.code);
    errdefer allocator.free(lines);

    var code_lines: std.ArrayListUnmanaged(CodeLineView) = .empty;
    errdefer deinitCodeLineViews(allocator, code_lines.items);

    for (lines) |line| {
        const tokens = try tokenizeCodeLine(allocator, language, line);
        try code_lines.append(allocator, .{
            .text = line,
            .tokens = tokens,
        });
    }

    allocator.free(lines);
    return .{
        .span = block.span,
        .info = block.info,
        .language = language,
        .lines = try code_lines.toOwnedSlice(allocator),
    };
}

fn deinitCodeLineViews(allocator: Allocator, lines: []CodeLineView) void {
    for (lines) |line| {
        if (line.tokens.len > 0) allocator.free(line.tokens);
    }
    allocator.free(lines);
}

fn collectCodeLineSlices(allocator: Allocator, code: []const u8) ![]const []const u8 {
    var lines: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer lines.deinit(allocator);

    var start: usize = 0;
    while (std.mem.indexOfScalarPos(u8, code, start, '\n')) |newline| {
        try lines.append(allocator, code[start..newline]);
        start = newline + 1;
    }

    if (start < code.len) {
        try lines.append(allocator, code[start..]);
    } else if (lines.items.len == 0) {
        try lines.append(allocator, "");
    }

    return try lines.toOwnedSlice(allocator);
}

fn tokenizeCodeLine(allocator: Allocator, language: zig_dif.Language, line: []const u8) ![]const zig_dif.Token {
    return zig_dif.syntax.tokenizeLine(allocator, language, line) catch {
        if (line.len == 0) return &[_]zig_dif.Token{};
        const tokens = try allocator.alloc(zig_dif.Token, 1);
        tokens[0] = .{
            .kind = .plain,
            .text = line,
        };
        return tokens;
    };
}

fn codeLanguageForTag(language: ?[]const u8) zig_dif.Language {
    const tag = language orelse return .plain;
    if (std.ascii.eqlIgnoreCase(tag, "zig")) return .zig;
    if (std.ascii.eqlIgnoreCase(tag, "js") or std.ascii.eqlIgnoreCase(tag, "javascript")) return .javascript;
    if (std.ascii.eqlIgnoreCase(tag, "jsx")) return .jsx;
    if (std.ascii.eqlIgnoreCase(tag, "ts") or std.ascii.eqlIgnoreCase(tag, "typescript")) return .typescript;
    if (std.ascii.eqlIgnoreCase(tag, "tsx")) return .tsx;
    if (std.ascii.eqlIgnoreCase(tag, "json")) return .json;
    if (std.ascii.eqlIgnoreCase(tag, "md") or std.ascii.eqlIgnoreCase(tag, "markdown")) return .markdown;
    return .plain;
}

// Renders a blank markdown block as vertical spacing.
fn renderBlankBlock() void {
    zgui.dummy(.{ .w = 0.0, .h = blankBlockHeight() });
}

// Renders a wrapped markdown paragraph in the normal body font.
fn renderParagraphBlock(paragraph: ParagraphView) void {
    zgui.pushTextWrapPos(0.0);
    defer zgui.popTextWrapPos();
    zgui.textWrapped("{s}", .{paragraph.text});
}

// Renders a fenced code block with token colors, padding, and a muted background.
fn renderFencedCodeBlock(block: FencedCodeView, available_width: f32, options: RenderOptions) void {
    const start = zgui.getCursorScreenPos();
    const width = @max(available_width, minimumCodeBlockWidth());
    const pushed_font = pushCodeFont(options);
    defer if (pushed_font) zgui.popFont();

    const line_height = zgui.getTextLineHeightWithSpacing();
    const pad_x = codeBlockPaddingX();
    const pad_y = codeBlockPaddingY();
    const height = codeBlockHeight(block, line_height, pad_y);
    const max_pos = .{ start[0] + width, start[1] + height };
    const draw_list = zgui.getWindowDrawList();

    draw_list.addRectFilled(.{
        .pmin = start,
        .pmax = max_pos,
        .col = zgui.colorConvertFloat4ToU32(colors.rgba(24, 24, 28, 255)),
        .rounding = codeBlockRounding(),
    });
    draw_list.addRect(.{
        .pmin = start,
        .pmax = max_pos,
        .col = zgui.colorConvertFloat4ToU32(colors.rgba(52, 54, 62, 255)),
        .rounding = codeBlockRounding(),
        .thickness = 1.0,
    });

    draw_list.pushClipRect(.{
        .pmin = start,
        .pmax = max_pos,
        .intersect_with_current = true,
    });
    defer draw_list.popClipRect();

    var y = start[1] + pad_y;
    for (block.lines) |line| {
        renderCodeLine(draw_list, line, .{
            .x = start[0] + pad_x,
            .y = y,
            .max_x = max_pos[0] - pad_x,
        });
        y += line_height;
    }

    zgui.dummy(.{ .w = width, .h = height });
}

fn renderCodeLine(draw_list: anytype, line: CodeLineView, layout: CodeLineLayout) void {
    var cursor_x = layout.x;
    for (line.tokens) |token| {
        if (token.text.len == 0) continue;
        if (cursor_x >= layout.max_x) break;

        const width = zgui.calcTextSize(token.text, .{})[0];
        draw_list.addTextUnformatted(
            .{ cursor_x, layout.y },
            zgui.colorConvertFloat4ToU32(codeTokenColor(token.kind)),
            token.text,
        );
        cursor_x += width;
    }
}

const CodeLineLayout = struct {
    x: f32,
    y: f32,
    max_x: f32,
};

fn measureParagraphHeight(paragraph: ParagraphView, available_width: f32) f32 {
    return @max(zgui.calcTextSize(paragraph.text, .{ .wrap_width = available_width })[1], zgui.getTextLineHeight());
}

fn measureFencedCodeHeight(block: FencedCodeView, options: RenderOptions) f32 {
    const pushed_font = pushCodeFont(options);
    defer if (pushed_font) zgui.popFont();
    const line_height = zgui.getTextLineHeightWithSpacing();
    return codeBlockHeight(block, line_height, codeBlockPaddingY());
}

fn pushCodeFont(options: RenderOptions) bool {
    if (options.code_font) |font| {
        zgui.pushFont(font, options.code_font_size orelse zgui.getFontSize());
        return true;
    }
    return false;
}

fn blankBlockHeight() f32 {
    return @max(zgui.getTextLineHeightWithSpacing() * 0.65, 1.0);
}

fn blockGap() f32 {
    return @max(zgui.getTextLineHeightWithSpacing() * 0.65, 1.0);
}

fn minimumCodeBlockWidth() f32 {
    return @max(zgui.getTextLineHeightWithSpacing() * 10.0, 240.0);
}

fn codeBlockPaddingX() f32 {
    return @max(zgui.getTextLineHeightWithSpacing() * 0.75, 10.0);
}

fn codeBlockPaddingY() f32 {
    return @max(zgui.getTextLineHeightWithSpacing() * 0.5, 8.0);
}

fn codeBlockRounding() f32 {
    return @max(zgui.getTextLineHeightWithSpacing() * 0.3, 6.0);
}

fn codeBlockHeight(block: FencedCodeView, line_height: f32, pad_y: f32) f32 {
    return pad_y * 2.0 + line_height * @as(f32, @floatFromInt(@max(block.lines.len, 1)));
}

fn codeTokenColor(kind: zig_dif.TokenKind) [4]f32 {
    return switch (kind) {
        .plain => colors.rgb(0xE2, 0xE4, 0xE9),
        .comment => colors.rgb(0x8A, 0x91, 0xA0),
        .string => colors.rgb(0x66, 0xDC, 0xAA),
        .number => colors.rgb(0xF5, 0xB4, 0x78),
        .keyword => colors.rgb(0xFF, 0xD6, 0x66),
        .type_name => colors.rgb(0x7A, 0xCA, 0xFF),
        .function_name => colors.rgb(0x60, 0xDB, 0xDB),
        .property_name => colors.rgb(0x6B, 0xA8, 0xFF),
        .variable_name => colors.rgb(0xE2, 0xE4, 0xE9),
        .constant_name => colors.rgb(0xF1, 0xC4, 0x6B),
        .operator, .punctuation => colors.rgb(0xB6, 0xBB, 0xC5),
    };
}

test "builds a body view with paragraphs and fenced code blocks" {
    const allocator = std.testing.allocator;
    const source =
        \\intro paragraph
        \\
        \\```ts
        \\const result = reviewCampaign(csvPath);
        \\```
        \\
        \\tail paragraph
    ;

    var body = try buildBodyView(allocator, source);
    defer body.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 5), body.blockCount());
    try std.testing.expectEqual(BlockKind.paragraph, body.blockAt(0).kind());
    try std.testing.expectEqual(BlockKind.blank, body.blockAt(1).kind());
    try std.testing.expectEqual(BlockKind.fenced_code, body.blockAt(2).kind());

    switch (body.blockAt(2)) {
        .fenced_code => |code| {
            try std.testing.expectEqual(zig_dif.Language.typescript, code.language);
            try std.testing.expectEqual(@as(usize, 1), code.lines.len);
            try std.testing.expectEqualStrings("const result = reviewCampaign(csvPath);", code.lines[0].text);
            try std.testing.expect(code.lines[0].tokens.len > 0);
            try std.testing.expectEqualStrings("const", code.lines[0].tokens[0].text);
        },
        else => unreachable,
    }
}

test "maps markdown fence tags to syntax languages" {
    try std.testing.expectEqual(zig_dif.Language.tsx, codeLanguageForTag("tsx"));
    try std.testing.expectEqual(zig_dif.Language.json, codeLanguageForTag("json"));
    try std.testing.expectEqual(zig_dif.Language.markdown, codeLanguageForTag("markdown"));
    try std.testing.expectEqual(zig_dif.Language.plain, codeLanguageForTag(null));
}
