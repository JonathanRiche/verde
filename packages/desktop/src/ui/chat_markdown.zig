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

pub const TextStyle = enum {
    paragraph,
    heading_1,
    heading_2,
    heading_3,
    heading_4,
    heading_5,
    heading_6,
    quote,
};

pub const TextBlockView = struct {
    span: zig_markdown.Span,
    text: []const u8,
    style: TextStyle,
    indent: usize = 0,
    compact: bool = false,
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
    indent: usize = 0,
    compact: bool = false,

    pub fn deinit(self: *FencedCodeView, allocator: Allocator) void {
        for (self.lines) |line| {
            if (line.tokens.len > 0) allocator.free(line.tokens);
        }
        allocator.free(self.lines);
        self.* = undefined;
    }
};

pub const ThematicBreakView = struct {
    span: zig_markdown.Span,
    indent: usize = 0,
    compact: bool = false,
};

pub const BlockKind = enum {
    blank,
    text,
    fenced_code,
    thematic_break,
};

pub const BlockView = union(enum) {
    blank: zig_markdown.Span,
    text: TextBlockView,
    fenced_code: FencedCodeView,
    thematic_break: ThematicBreakView,

    pub fn kind(self: BlockView) BlockKind {
        return switch (self) {
            .blank => .blank,
            .text => .text,
            .fenced_code => .fenced_code,
            .thematic_break => .thematic_break,
        };
    }

    pub fn span(self: BlockView) zig_markdown.Span {
        return switch (self) {
            .blank => |blank_span| blank_span,
            .text => |text| text.span,
            .fenced_code => |code| code.span,
            .thematic_break => |rule| rule.span,
        };
    }

    pub fn isCompact(self: BlockView) bool {
        return switch (self) {
            .blank => false,
            .text => |text| text.compact,
            .fenced_code => |code| code.compact,
            .thematic_break => |rule| rule.compact,
        };
    }
};

pub const BodyView = struct {
    const Self = @This();

    source: []const u8,
    document: zig_markdown.Document,
    blocks: []BlockView,

    pub fn deinit(self: *Self, allocator: Allocator) void {
        deinitBlockViews(allocator, self.blocks);
        allocator.free(self.blocks);
        self.document.deinit(allocator);
        self.* = undefined;
    }

    pub fn blockCount(self: Self) usize {
        return self.blocks.len;
    }

    pub fn blockAt(self: Self, index: usize) BlockView {
        return self.blocks[index];
    }
};

const FlattenContext = struct {
    indent: usize = 0,
    quote_depth: usize = 0,
    compact: bool = false,

    fn indented(self: FlattenContext) FlattenContext {
        return .{
            .indent = self.indent + 1,
            .quote_depth = self.quote_depth,
            .compact = self.compact,
        };
    }

    fn quoted(self: FlattenContext) FlattenContext {
        return .{
            .indent = self.indent + 1,
            .quote_depth = self.quote_depth + 1,
            .compact = self.compact,
        };
    }

    fn compacted(self: FlattenContext) FlattenContext {
        return .{
            .indent = self.indent,
            .quote_depth = self.quote_depth,
            .compact = true,
        };
    }
};

/// Parses markdown into a reusable body view with flattened text, rule, and code blocks.
pub fn buildBodyView(allocator: Allocator, source: []const u8) !BodyView {
    var document = try zig_markdown.parse(allocator, source);
    errdefer document.deinit(allocator);

    var blocks: std.ArrayListUnmanaged(BlockView) = .empty;
    errdefer {
        deinitBlockViews(allocator, blocks.items);
        blocks.deinit(allocator);
    }

    try appendMarkdownBlocks(allocator, &blocks, document.blocks, .{});

    return .{
        .source = source,
        .document = document,
        .blocks = try blocks.toOwnedSlice(allocator),
    };
}

/// Renders a parsed markdown body as wrapped text, themed rules, and fenced code blocks.
pub fn renderBody(view: BodyView, options: RenderOptions) void {
    const available_width = @max(zgui.getContentRegionAvail()[0], 1.0);

    var previous: ?BlockView = null;
    for (view.blocks) |block| {
        if (previous) |prior| {
            if (prior.kind() != .blank and block.kind() != .blank) {
                zgui.dummy(.{
                    .w = 0.0,
                    .h = if (prior.isCompact() or block.isCompact()) compactBlockGap() else blockGap(),
                });
            }
        }

        switch (block) {
            .blank => renderBlankBlock(),
            .text => |text| renderTextBlock(text, available_width),
            .fenced_code => |code| renderFencedCodeBlock(code, available_width, options),
            .thematic_break => |rule| renderThematicBreakBlock(rule, available_width),
        }

        previous = block;
    }
}

/// Measures a parsed markdown body using the current font metrics and code font options.
pub fn measureBodyHeight(view: BodyView, available_width: f32, options: RenderOptions) f32 {
    const width = @max(available_width, 1.0);

    var total: f32 = 0.0;
    var previous: ?BlockView = null;
    for (view.blocks) |block| {
        if (previous) |prior| {
            if (prior.kind() != .blank and block.kind() != .blank) {
                total += if (prior.isCompact() or block.isCompact()) compactBlockGap() else blockGap();
            }
        }

        total += switch (block) {
            .blank => blankBlockHeight(),
            .text => |text| measureTextBlockHeight(text, width),
            .fenced_code => |code| measureFencedCodeHeight(code, width, options),
            .thematic_break => |rule| measureThematicBreakHeight(rule),
        };

        previous = block;
    }

    return total;
}

fn appendMarkdownBlocks(
    allocator: Allocator,
    blocks: *std.ArrayListUnmanaged(BlockView),
    markdown_blocks: []const zig_markdown.Block,
    context: FlattenContext,
) Allocator.Error!void {
    for (markdown_blocks) |block| {
        switch (block) {
            .blank => |span| try blocks.append(allocator, .{ .blank = span }),
            .paragraph => |paragraph| {
                const text = try flattenInlinesToText(allocator, paragraph.inlines);
                errdefer allocator.free(text);
                try blocks.append(allocator, .{
                    .text = .{
                        .span = paragraph.span,
                        .text = text,
                        .style = if (context.quote_depth > 0) .quote else .paragraph,
                        .indent = context.indent,
                        .compact = context.compact,
                    },
                });
            },
            .heading => |heading| {
                const text = try flattenInlinesToText(allocator, heading.inlines);
                errdefer allocator.free(text);
                try blocks.append(allocator, .{
                    .text = .{
                        .span = heading.span,
                        .text = text,
                        .style = headingStyle(heading.level),
                        .indent = context.indent,
                        .compact = context.compact,
                    },
                });
            },
            .fenced_code => |code| try blocks.append(allocator, .{
                .fenced_code = try buildFencedCodeView(allocator, code, context),
            }),
            .thematic_break => |span| try blocks.append(allocator, .{
                .thematic_break = .{
                    .span = span,
                    .indent = context.indent,
                    .compact = context.compact,
                },
            }),
            .block_quote => |quote| try appendMarkdownBlocks(allocator, blocks, quote.blocks, context.quoted()),
            .list => |list| try appendListBlock(allocator, blocks, list, context),
        }
    }
}

fn appendListBlock(
    allocator: Allocator,
    blocks: *std.ArrayListUnmanaged(BlockView),
    list: zig_markdown.ListBlock,
    context: FlattenContext,
) Allocator.Error!void {
    for (list.items, 0..) |item, item_index| {
        const marker = try listItemMarker(allocator, list.kind, list.start_number + item_index);
        defer allocator.free(marker);

        if (item.blocks.len == 0) {
            try appendOwnedTextBlock(allocator, blocks, .{
                .span = item.span,
                .text = try allocator.dupe(u8, marker),
                .style = if (context.quote_depth > 0) .quote else .paragraph,
                .indent = context.indent,
                .compact = true,
            });
            continue;
        }

        switch (item.blocks[0]) {
            .paragraph => |paragraph| {
                const base = try flattenInlinesToText(allocator, paragraph.inlines);
                defer allocator.free(base);
                try appendOwnedTextBlock(allocator, blocks, .{
                    .span = paragraph.span,
                    .text = try prefixText(allocator, marker, base),
                    .style = if (context.quote_depth > 0) .quote else .paragraph,
                    .indent = context.indent,
                    .compact = true,
                });
                if (item.blocks.len > 1) {
                    try appendMarkdownBlocks(allocator, blocks, item.blocks[1..], context.indented().compacted());
                }
            },
            .heading => |heading| {
                const base = try flattenInlinesToText(allocator, heading.inlines);
                defer allocator.free(base);
                try appendOwnedTextBlock(allocator, blocks, .{
                    .span = heading.span,
                    .text = try prefixText(allocator, marker, base),
                    .style = headingStyle(heading.level),
                    .indent = context.indent,
                    .compact = true,
                });
                if (item.blocks.len > 1) {
                    try appendMarkdownBlocks(allocator, blocks, item.blocks[1..], context.indented().compacted());
                }
            },
            else => {
                try appendOwnedTextBlock(allocator, blocks, .{
                    .span = item.span,
                    .text = try allocator.dupe(u8, marker),
                    .style = if (context.quote_depth > 0) .quote else .paragraph,
                    .indent = context.indent,
                    .compact = true,
                });
                try appendMarkdownBlocks(allocator, blocks, item.blocks, context.indented().compacted());
            },
        }
    }
}

fn appendOwnedTextBlock(
    allocator: Allocator,
    blocks: *std.ArrayListUnmanaged(BlockView),
    text_block: TextBlockView,
) Allocator.Error!void {
    errdefer allocator.free(text_block.text);
    try blocks.append(allocator, .{ .text = text_block });
}

fn buildFencedCodeView(
    allocator: Allocator,
    block: zig_markdown.FencedCodeBlock,
    context: FlattenContext,
) !FencedCodeView {
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
        .indent = context.indent,
        .compact = context.compact,
    };
}

fn flattenInlinesToText(
    allocator: Allocator,
    inlines: []const zig_markdown.Inline,
) Allocator.Error![]const u8 {
    var builder: std.ArrayListUnmanaged(u8) = .empty;
    errdefer builder.deinit(allocator);

    try appendInlineText(allocator, &builder, inlines);
    return try builder.toOwnedSlice(allocator);
}

fn appendInlineText(
    allocator: Allocator,
    builder: *std.ArrayListUnmanaged(u8),
    inlines: []const zig_markdown.Inline,
) Allocator.Error!void {
    for (inlines) |item| {
        switch (item) {
            .text => |text| try builder.appendSlice(allocator, text.text),
            .emphasis => |container| try appendInlineText(allocator, builder, container.children),
            .strong => |container| try appendInlineText(allocator, builder, container.children),
            .code => |code| try builder.appendSlice(allocator, code.text),
            .link => |link| {
                if (link.children.len > 0) {
                    try appendInlineText(allocator, builder, link.children);
                } else {
                    try builder.appendSlice(allocator, link.label);
                }
            },
            .line_break => try builder.append(allocator, '\n'),
        }
    }
}

fn prefixText(allocator: Allocator, prefix: []const u8, text: []const u8) Allocator.Error![]const u8 {
    var builder: std.ArrayListUnmanaged(u8) = .empty;
    errdefer builder.deinit(allocator);

    try builder.appendSlice(allocator, prefix);
    try builder.appendSlice(allocator, text);
    return try builder.toOwnedSlice(allocator);
}

fn listItemMarker(
    allocator: Allocator,
    kind: zig_markdown.ListKind,
    number: usize,
) Allocator.Error![]const u8 {
    return switch (kind) {
        .unordered => allocator.dupe(u8, "- "),
        .ordered => std.fmt.allocPrint(allocator, "{d}. ", .{number}),
    };
}

fn headingStyle(level: u8) TextStyle {
    return switch (level) {
        1 => .heading_1,
        2 => .heading_2,
        3 => .heading_3,
        4 => .heading_4,
        5 => .heading_5,
        else => .heading_6,
    };
}

fn deinitBlockViews(allocator: Allocator, blocks: []BlockView) void {
    for (blocks) |block| {
        switch (block) {
            .text => |text| allocator.free(text.text),
            .fenced_code => |code| {
                var code_copy = code;
                code_copy.deinit(allocator);
            },
            else => {},
        }
    }
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

fn renderBlankBlock() void {
    zgui.dummy(.{ .w = 0.0, .h = blankBlockHeight() });
}

fn renderTextBlock(block: TextBlockView, available_width: f32) void {
    const indent = indentWidth(block.indent);
    if (indent > 0.0) {
        zgui.setCursorPosX(zgui.getCursorPosX() + indent);
    }

    const color = textBlockColor(block.style);
    zgui.pushStyleColor4f(.{ .idx = .text, .c = color });
    defer zgui.popStyleColor(.{ .count = 1 });

    zgui.pushTextWrapPos(0.0);
    defer zgui.popTextWrapPos();
    _ = available_width;
    zgui.textWrapped("{s}", .{block.text});
}

fn renderFencedCodeBlock(block: FencedCodeView, available_width: f32, options: RenderOptions) void {
    const indent = indentWidth(block.indent);
    if (indent > 0.0) {
        zgui.setCursorPosX(zgui.getCursorPosX() + indent);
    }

    const start = zgui.getCursorScreenPos();
    const width = @max(available_width - indent, minimumCodeBlockWidth());
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

fn renderThematicBreakBlock(rule: ThematicBreakView, available_width: f32) void {
    const indent = indentWidth(rule.indent);
    if (indent > 0.0) {
        zgui.setCursorPosX(zgui.getCursorPosX() + indent);
    }

    const start = zgui.getCursorScreenPos();
    const width = @max(available_width - indent, 24.0);
    const y = start[1] + thematicBreakHeight() * 0.5;
    const draw_list = zgui.getWindowDrawList();
    draw_list.addLine(.{
        .p1 = .{ start[0], y },
        .p2 = .{ start[0] + width, y },
        .col = zgui.colorConvertFloat4ToU32(colors.rgba(68, 72, 82, 255)),
        .thickness = 1.0,
    });
    zgui.dummy(.{ .w = width, .h = thematicBreakHeight() });
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

fn measureTextBlockHeight(block: TextBlockView, available_width: f32) f32 {
    const width = @max(available_width - indentWidth(block.indent), 1.0);
    return @max(zgui.calcTextSize(block.text, .{ .wrap_width = width })[1], zgui.getTextLineHeight());
}

fn measureFencedCodeHeight(block: FencedCodeView, available_width: f32, options: RenderOptions) f32 {
    _ = available_width;
    const pushed_font = pushCodeFont(options);
    defer if (pushed_font) zgui.popFont();
    const line_height = zgui.getTextLineHeightWithSpacing();
    return codeBlockHeight(block, line_height, codeBlockPaddingY());
}

fn measureThematicBreakHeight(rule: ThematicBreakView) f32 {
    _ = rule;
    return thematicBreakHeight();
}

fn pushCodeFont(options: RenderOptions) bool {
    if (options.code_font) |font| {
        zgui.pushFont(font, options.code_font_size orelse zgui.getFontSize());
        return true;
    }
    return false;
}

fn textBlockColor(style: TextStyle) [4]f32 {
    return switch (style) {
        .paragraph => colors.rgb(0xE2, 0xE4, 0xE9),
        .heading_1 => colors.rgb(0xFF, 0xF2, 0xA8),
        .heading_2 => colors.rgb(0xF2, 0xE6, 0x8D),
        .heading_3 => colors.rgb(0xDE, 0xE8, 0xFF),
        .heading_4, .heading_5, .heading_6 => colors.rgb(0xCF, 0xD7, 0xE5),
        .quote => colors.rgb(0xB3, 0xBE, 0xD4),
    };
}

fn indentWidth(level: usize) f32 {
    return @as(f32, @floatFromInt(level)) * @max(zgui.getTextLineHeightWithSpacing() * 1.25, 18.0);
}

fn blankBlockHeight() f32 {
    return @max(zgui.getTextLineHeightWithSpacing() * 0.65, 1.0);
}

fn blockGap() f32 {
    return @max(zgui.getTextLineHeightWithSpacing() * 0.65, 1.0);
}

fn compactBlockGap() f32 {
    return @max(zgui.getTextLineHeightWithSpacing() * 0.2, 2.0);
}

fn thematicBreakHeight() f32 {
    return @max(zgui.getTextLineHeightWithSpacing() * 0.7, 10.0);
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

test "builds a body view with headings lists and fenced code" {
    const allocator = std.testing.allocator;
    const source =
        \\## Review
        \\
        \\- first item
        \\- second item with **bold**
        \\
        \\```ts
        \\const result = reviewCampaign(csvPath);
        \\```
    ;

    var body = try buildBodyView(allocator, source);
    defer body.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 6), body.blockCount());
    try std.testing.expectEqual(BlockKind.text, body.blockAt(0).kind());
    try std.testing.expectEqual(BlockKind.blank, body.blockAt(1).kind());
    try std.testing.expectEqual(BlockKind.text, body.blockAt(2).kind());
    try std.testing.expectEqual(BlockKind.text, body.blockAt(3).kind());
    try std.testing.expectEqual(BlockKind.blank, body.blockAt(4).kind());
    try std.testing.expectEqual(BlockKind.fenced_code, body.blockAt(5).kind());

    switch (body.blockAt(0)) {
        .text => |text| {
            try std.testing.expectEqual(TextStyle.heading_2, text.style);
            try std.testing.expectEqualStrings("Review", text.text);
        },
        else => unreachable,
    }

    switch (body.blockAt(2)) {
        .text => |text| try std.testing.expectEqualStrings("- first item", text.text),
        else => unreachable,
    }

    switch (body.blockAt(3)) {
        .text => |text| try std.testing.expectEqualStrings("- second item with bold", text.text),
        else => unreachable,
    }

    switch (body.blockAt(5)) {
        .fenced_code => |code| {
            try std.testing.expectEqual(zig_dif.Language.typescript, code.language);
            try std.testing.expectEqual(@as(usize, 1), code.lines.len);
            try std.testing.expectEqualStrings("const result = reviewCampaign(csvPath);", code.lines[0].text);
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
