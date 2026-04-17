//! Reusable markdown body parsing and rendering helpers for chat threads.

const std = @import("std");

const colors = @import("colors.zig");
const zig_dif = @import("zig_dif");
const zig_markdown = @import("zig_markdown");
const zgui = @import("zgui");

const Allocator = std.mem.Allocator;

pub const RenderOptions = struct {
    heading_font: ?zgui.Font = null,
    heading_font_size: ?f32 = null,
    bold_font: ?zgui.Font = null,
    italic_font: ?zgui.Font = null,
    bold_italic_font: ?zgui.Font = null,
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

pub const InlineStyle = struct {
    strong: bool = false,
    emphasis: bool = false,
    code: bool = false,
    link: bool = false,
};

pub const TextRunView = struct {
    start: usize,
    end: usize,
    style: InlineStyle,
};

pub const InlineRunView = union(enum) {
    text: TextRunView,
    line_break: zig_markdown.LineBreakKind,
};

pub const TextBlockView = struct {
    span: zig_markdown.Span,
    text: []const u8,
    runs: []InlineRunView,
    style: TextStyle,
    indent: usize = 0,
    compact: bool = false,

    pub fn deinit(self: *TextBlockView, allocator: Allocator) void {
        allocator.free(self.text);
        allocator.free(self.runs);
        self.* = undefined;
    }
};

const TextContent = struct {
    text: []const u8,
    runs: []InlineRunView,

    pub fn deinit(self: *TextContent, allocator: Allocator) void {
        allocator.free(self.text);
        allocator.free(self.runs);
        self.* = undefined;
    }
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

const FontSpec = struct {
    font: ?zgui.Font = null,
    size: ?f32 = null,
};

const Chunk = struct {
    text: []const u8,
    is_whitespace: bool,
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
            .text => |text| renderTextBlock(text, available_width, options),
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
            .text => |text| measureTextBlockHeight(text, width, options),
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
                var content = try buildTextContent(allocator, paragraph.inlines);
                errdefer content.deinit(allocator);
                try appendOwnedTextBlock(allocator, blocks, .{
                    .span = paragraph.span,
                    .text = content.text,
                    .runs = content.runs,
                    .style = if (context.quote_depth > 0) .quote else .paragraph,
                    .indent = context.indent,
                    .compact = context.compact,
                });
            },
            .heading => |heading| {
                var content = try buildTextContent(allocator, heading.inlines);
                errdefer content.deinit(allocator);
                try appendOwnedTextBlock(allocator, blocks, .{
                    .span = heading.span,
                    .text = content.text,
                    .runs = content.runs,
                    .style = headingStyle(heading.level),
                    .indent = context.indent,
                    .compact = context.compact,
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
            var content = try buildPlainTextContent(allocator, marker, .{});
            errdefer content.deinit(allocator);
            try appendOwnedTextBlock(allocator, blocks, .{
                .span = item.span,
                .text = content.text,
                .runs = content.runs,
                .style = if (context.quote_depth > 0) .quote else .paragraph,
                .indent = context.indent,
                .compact = true,
            });
            continue;
        }

        switch (item.blocks[0]) {
            .paragraph => |paragraph| {
                var base = try buildTextContent(allocator, paragraph.inlines);
                defer base.deinit(allocator);
                var prefixed = try prefixTextContent(allocator, marker, base);
                errdefer prefixed.deinit(allocator);
                try appendOwnedTextBlock(allocator, blocks, .{
                    .span = paragraph.span,
                    .text = prefixed.text,
                    .runs = prefixed.runs,
                    .style = if (context.quote_depth > 0) .quote else .paragraph,
                    .indent = context.indent,
                    .compact = true,
                });
                if (item.blocks.len > 1) {
                    try appendMarkdownBlocks(allocator, blocks, item.blocks[1..], context.indented().compacted());
                }
            },
            .heading => |heading| {
                var base = try buildTextContent(allocator, heading.inlines);
                defer base.deinit(allocator);
                var prefixed = try prefixTextContent(allocator, marker, base);
                errdefer prefixed.deinit(allocator);
                try appendOwnedTextBlock(allocator, blocks, .{
                    .span = heading.span,
                    .text = prefixed.text,
                    .runs = prefixed.runs,
                    .style = headingStyle(heading.level),
                    .indent = context.indent,
                    .compact = true,
                });
                if (item.blocks.len > 1) {
                    try appendMarkdownBlocks(allocator, blocks, item.blocks[1..], context.indented().compacted());
                }
            },
            else => {
                var content = try buildPlainTextContent(allocator, marker, .{});
                errdefer content.deinit(allocator);
                try appendOwnedTextBlock(allocator, blocks, .{
                    .span = item.span,
                    .text = content.text,
                    .runs = content.runs,
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
    var owned = text_block;
    errdefer owned.deinit(allocator);
    try blocks.append(allocator, .{ .text = owned });
}

fn buildTextContent(
    allocator: Allocator,
    inlines: []const zig_markdown.Inline,
) Allocator.Error!TextContent {
    var text_builder: std.ArrayListUnmanaged(u8) = .empty;
    errdefer text_builder.deinit(allocator);

    var runs: std.ArrayListUnmanaged(InlineRunView) = .empty;
    errdefer runs.deinit(allocator);

    try appendInlineRuns(allocator, &text_builder, &runs, inlines, .{});
    return .{
        .text = try text_builder.toOwnedSlice(allocator),
        .runs = try runs.toOwnedSlice(allocator),
    };
}

fn buildPlainTextContent(
    allocator: Allocator,
    text: []const u8,
    style: InlineStyle,
) Allocator.Error!TextContent {
    var builder: std.ArrayListUnmanaged(u8) = .empty;
    errdefer builder.deinit(allocator);

    var runs: std.ArrayListUnmanaged(InlineRunView) = .empty;
    errdefer runs.deinit(allocator);

    try appendStyledText(allocator, &builder, &runs, text, style);
    return .{
        .text = try builder.toOwnedSlice(allocator),
        .runs = try runs.toOwnedSlice(allocator),
    };
}

fn prefixTextContent(
    allocator: Allocator,
    prefix: []const u8,
    content: TextContent,
) Allocator.Error!TextContent {
    var text_builder: std.ArrayListUnmanaged(u8) = .empty;
    errdefer text_builder.deinit(allocator);

    var runs: std.ArrayListUnmanaged(InlineRunView) = .empty;
    errdefer runs.deinit(allocator);

    try appendStyledText(allocator, &text_builder, &runs, prefix, .{});
    const prefix_len = text_builder.items.len;
    try text_builder.appendSlice(allocator, content.text);

    for (content.runs) |run| {
        switch (run) {
            .text => |text_run| try runs.append(allocator, .{
                .text = .{
                    .start = prefix_len + text_run.start,
                    .end = prefix_len + text_run.end,
                    .style = text_run.style,
                },
            }),
            .line_break => |kind| try runs.append(allocator, .{ .line_break = kind }),
        }
    }

    return .{
        .text = try text_builder.toOwnedSlice(allocator),
        .runs = try runs.toOwnedSlice(allocator),
    };
}

fn appendInlineRuns(
    allocator: Allocator,
    text_builder: *std.ArrayListUnmanaged(u8),
    runs: *std.ArrayListUnmanaged(InlineRunView),
    inlines: []const zig_markdown.Inline,
    style: InlineStyle,
) Allocator.Error!void {
    for (inlines) |item| {
        switch (item) {
            .text => |text| try appendStyledText(allocator, text_builder, runs, text.text, style),
            .emphasis => |container| try appendInlineRuns(
                allocator,
                text_builder,
                runs,
                container.children,
                mergeInlineStyle(style, .{ .emphasis = true }),
            ),
            .strong => |container| try appendInlineRuns(
                allocator,
                text_builder,
                runs,
                container.children,
                mergeInlineStyle(style, .{ .strong = true }),
            ),
            .code => |code| try appendStyledText(
                allocator,
                text_builder,
                runs,
                code.text,
                mergeInlineStyle(style, .{ .code = true }),
            ),
            .link => |link| {
                const link_style = mergeInlineStyle(style, .{ .link = true });
                if (link.children.len > 0) {
                    try appendInlineRuns(allocator, text_builder, runs, link.children, link_style);
                } else {
                    try appendStyledText(allocator, text_builder, runs, link.label, link_style);
                }
            },
            .line_break => |kind| try runs.append(allocator, .{ .line_break = kind }),
        }
    }
}

fn appendStyledText(
    allocator: Allocator,
    text_builder: *std.ArrayListUnmanaged(u8),
    runs: *std.ArrayListUnmanaged(InlineRunView),
    text: []const u8,
    style: InlineStyle,
) Allocator.Error!void {
    if (text.len == 0) return;

    const start = text_builder.items.len;
    try text_builder.appendSlice(allocator, text);
    const end = text_builder.items.len;

    if (runs.items.len > 0) {
        switch (runs.items[runs.items.len - 1]) {
            .text => |*last| {
                if (std.meta.eql(last.style, style) and last.end == start) {
                    last.end = end;
                    return;
                }
            },
            else => {},
        }
    }

    try runs.append(allocator, .{
        .text = .{
            .start = start,
            .end = end,
            .style = style,
        },
    });
}

fn mergeInlineStyle(base: InlineStyle, extra: InlineStyle) InlineStyle {
    return .{
        .strong = base.strong or extra.strong,
        .emphasis = base.emphasis or extra.emphasis,
        .code = base.code or extra.code,
        .link = base.link or extra.link,
    };
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

fn deinitBlockViews(allocator: Allocator, blocks: []BlockView) void {
    for (blocks) |block| {
        switch (block) {
            .text => |text| {
                var owned = text;
                owned.deinit(allocator);
            },
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

fn renderTextBlock(block: TextBlockView, available_width: f32, options: RenderOptions) void {
    const indent = indentWidth(block.indent);
    if (indent > 0.0) {
        zgui.setCursorPosX(zgui.getCursorPosX() + indent);
    }

    const start = zgui.getCursorScreenPos();
    const width = @max(available_width - indent, 1.0);
    const draw_list = zgui.getWindowDrawList();
    const height = renderTextBlockLayout(draw_list, .{ start[0], start[1] }, block, width, options);

    zgui.dummy(.{ .w = width, .h = height });
}

fn renderFencedCodeBlock(block: FencedCodeView, available_width: f32, options: RenderOptions) void {
    const indent = indentWidth(block.indent);
    if (indent > 0.0) {
        zgui.setCursorPosX(zgui.getCursorPosX() + indent);
    }

    const start = zgui.getCursorScreenPos();
    const width = @max(available_width - indent, minimumCodeBlockWidth());
    const pushed_font = pushFontSpec(.{
        .font = options.code_font,
        .size = options.code_font_size,
    });
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

const TextBlockLayoutState = struct {
    base_line_height: f32,
    x: f32,
    y: f32,
    line_height: f32,
    line_start: bool,

    fn init(base_line_height: f32) TextBlockLayoutState {
        return .{
            .base_line_height = base_line_height,
            .x = 0.0,
            .y = 0.0,
            .line_height = base_line_height,
            .line_start = true,
        };
    }

    fn advanceLine(self: *TextBlockLayoutState) void {
        self.y += self.line_height;
        self.x = 0.0;
        self.line_height = self.base_line_height;
        self.line_start = true;
    }

    fn totalHeight(self: TextBlockLayoutState) f32 {
        return self.y + self.line_height;
    }
};

const TextBlockLayoutStep = struct {
    text: []const u8,
    block_style: TextStyle,
    inline_style: InlineStyle,
    font_spec: FontSpec,
    x: f32,
    y: f32,
    width: f32,
    line_height: f32,
};

fn walkTextBlockLayout(
    block: TextBlockView,
    available_width: f32,
    options: RenderOptions,
    context: anytype,
    comptime on_step: fn (@TypeOf(context), TextBlockLayoutStep) void,
) f32 {
    const width = @max(available_width, 1.0);
    const block_font = textBlockFontSpecWithOptions(block.style, options);
    var state = TextBlockLayoutState.init(lineHeightForSpec(block_font));

    for (block.runs) |run| {
        switch (run) {
            .line_break => state.advanceLine(),
            .text => |text_run| {
                const spec = inlineFontSpec(block.style, text_run.style, options);
                const chunk_line_height = lineHeightForSpec(spec);
                const slice = block.text[text_run.start..text_run.end];
                var chunk_start: usize = 0;
                while (nextChunk(slice, &chunk_start)) |chunk| {
                    const chunk_width = textWidthForSpec(spec, chunk.text);

                    if (chunk.is_whitespace and state.line_start) {
                        continue;
                    }

                    if (!chunk.is_whitespace and !state.line_start and state.x + chunk_width > width) {
                        state.advanceLine();
                    } else if (chunk.is_whitespace and state.x + chunk_width > width) {
                        state.advanceLine();
                        continue;
                    }

                    on_step(context, .{
                        .text = chunk.text,
                        .block_style = block.style,
                        .inline_style = text_run.style,
                        .font_spec = spec,
                        .x = state.x,
                        .y = state.y,
                        .width = chunk_width,
                        .line_height = chunk_line_height,
                    });

                    state.x += chunk_width;
                    state.line_height = @max(state.line_height, chunk_line_height);
                    state.line_start = false;
                }
            },
        }
    }

    return state.totalHeight();
}

fn ignoreTextBlockLayoutStep(_: void, _: TextBlockLayoutStep) void {}

fn measureTextBlockLayout(
    block: TextBlockView,
    available_width: f32,
    options: RenderOptions,
) f32 {
    return walkTextBlockLayout(block, available_width, options, {}, ignoreTextBlockLayoutStep);
}

fn renderTextBlockLayout(
    draw_list: anytype,
    start: [2]f32,
    block: TextBlockView,
    available_width: f32,
    options: RenderOptions,
) f32 {
    const RenderContext = struct {
        draw_list: @TypeOf(draw_list),
        start: [2]f32,

        fn onStep(ctx: @This(), step: TextBlockLayoutStep) void {
            renderStyledChunk(
                ctx.draw_list,
                .{ ctx.start[0] + step.x, ctx.start[1] + step.y },
                step.text,
                step.block_style,
                step.inline_style,
                step.font_spec,
                step.width,
                step.line_height,
            );
        }
    };

    return walkTextBlockLayout(block, available_width, options, RenderContext{
        .draw_list = draw_list,
        .start = start,
    }, RenderContext.onStep);
}

fn renderStyledChunk(
    draw_list: anytype,
    position: [2]f32,
    text: []const u8,
    block_style: TextStyle,
    inline_style: InlineStyle,
    font_spec: FontSpec,
    width: f32,
    line_height: f32,
) void {
    const pushed_font = pushFontSpec(font_spec);
    defer if (pushed_font) zgui.popFont();

    const color = inlineTextColor(textBlockColor(block_style), inline_style);
    const color_u32 = zgui.colorConvertFloat4ToU32(color);

    if (inline_style.code) {
        draw_list.addRectFilled(.{
            .pmin = .{ position[0] - 3.0, position[1] + 1.0 },
            .pmax = .{ position[0] + width + 3.0, position[1] + line_height - 1.0 },
            .col = zgui.colorConvertFloat4ToU32(colors.rgba(36, 39, 46, 255)),
            .rounding = 4.0,
        });
    }

    draw_list.addTextUnformatted(position, color_u32, text);
    if (inline_style.strong) {
        draw_list.addTextUnformatted(.{ position[0] + 0.75, position[1] }, color_u32, text);
    }

    if (inline_style.link or inline_style.emphasis) {
        const underline_color = if (inline_style.link)
            zgui.colorConvertFloat4ToU32(colors.rgb(0x7A, 0xCA, 0xFF))
        else
            color_u32;
        draw_list.addLine(.{
            .p1 = .{ position[0], position[1] + line_height - 2.0 },
            .p2 = .{ position[0] + width, position[1] + line_height - 2.0 },
            .col = underline_color,
            .thickness = if (inline_style.link) 1.5 else 1.0,
        });
    }
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

fn measureTextBlockHeight(block: TextBlockView, available_width: f32, options: RenderOptions) f32 {
    const width = @max(available_width - indentWidth(block.indent), 1.0);
    return measureTextBlockLayout(block, width, options);
}

fn measureFencedCodeHeight(block: FencedCodeView, available_width: f32, options: RenderOptions) f32 {
    _ = available_width;
    const pushed_font = pushFontSpec(.{
        .font = options.code_font,
        .size = options.code_font_size,
    });
    defer if (pushed_font) zgui.popFont();
    const line_height = zgui.getTextLineHeightWithSpacing();
    return codeBlockHeight(block, line_height, codeBlockPaddingY());
}

fn measureThematicBreakHeight(rule: ThematicBreakView) f32 {
    _ = rule;
    return thematicBreakHeight();
}

fn pushFontSpec(spec: FontSpec) bool {
    if (spec.font != null or spec.size != null) {
        zgui.pushFont(spec.font orelse zgui.getFont(), spec.size orelse zgui.getFontSize());
        return true;
    }
    return false;
}

fn textBlockFontSpec(style: TextStyle) FontSpec {
    const base_size = zgui.getFontSize();
    const heading_size = base_size;

    return switch (style) {
        .paragraph, .quote => .{},
        .heading_1 => .{ .font = null, .size = heading_size * 1.18 },
        .heading_2 => .{ .font = null, .size = heading_size * 1.08 },
        .heading_3 => .{ .font = null, .size = @max(base_size * 1.20, heading_size * 0.94) },
        .heading_4 => .{ .font = null, .size = @max(base_size * 1.12, heading_size * 0.86) },
        .heading_5 => .{ .font = null, .size = @max(base_size * 1.06, heading_size * 0.8) },
        .heading_6 => .{ .font = null, .size = @max(base_size * 1.02, heading_size * 0.76) },
    };
}

fn textBlockFontSpecWithOptions(style: TextStyle, options: RenderOptions) FontSpec {
    const base = textBlockFontSpec(style);
    if (style == .paragraph or style == .quote) return base;

    return .{
        .font = options.heading_font orelse base.font,
        .size = if (options.heading_font_size) |heading_size|
            switch (style) {
                .heading_1 => heading_size * 1.18,
                .heading_2 => heading_size * 1.08,
                .heading_3 => @max(zgui.getFontSize() * 1.20, heading_size * 0.94),
                .heading_4 => @max(zgui.getFontSize() * 1.12, heading_size * 0.86),
                .heading_5 => @max(zgui.getFontSize() * 1.06, heading_size * 0.8),
                .heading_6 => @max(zgui.getFontSize() * 1.02, heading_size * 0.76),
                else => base.size,
            }
        else
            base.size,
    };
}

fn inlineFontSpec(block_style: TextStyle, inline_style: InlineStyle, options: RenderOptions) FontSpec {
    const base = textBlockFontSpecWithOptions(block_style, options);
    if (inline_style.code) {
        return .{
            .font = options.code_font,
            .size = options.code_font_size,
        };
    }
    if (inline_style.strong and inline_style.emphasis) {
        return .{
            .font = options.bold_italic_font orelse options.bold_font orelse options.italic_font,
            .size = base.size,
        };
    }
    if (inline_style.strong) {
        return .{
            .font = options.bold_font,
            .size = base.size,
        };
    }
    if (inline_style.emphasis) {
        return .{
            .font = options.italic_font,
            .size = base.size,
        };
    }
    return base;
}

fn lineHeightForSpec(spec: FontSpec) f32 {
    const pushed_font = pushFontSpec(spec);
    defer if (pushed_font) zgui.popFont();
    return zgui.getTextLineHeight();
}

fn textWidthForSpec(spec: FontSpec, text: []const u8) f32 {
    const pushed_font = pushFontSpec(spec);
    defer if (pushed_font) zgui.popFont();
    return zgui.calcTextSize(text, .{})[0];
}

fn nextChunk(text: []const u8, index: *usize) ?Chunk {
    if (index.* >= text.len) return null;

    const start = index.*;
    const initial_is_whitespace = isInlineWhitespace(text[start]);
    var end = start + 1;
    while (end < text.len and isInlineWhitespace(text[end]) == initial_is_whitespace) : (end += 1) {}
    index.* = end;
    return .{
        .text = text[start..end],
        .is_whitespace = initial_is_whitespace,
    };
}

fn isInlineWhitespace(byte: u8) bool {
    return byte == ' ' or byte == '\t';
}

fn inlineTextColor(base_color: [4]f32, style: InlineStyle) [4]f32 {
    var color = base_color;
    if (style.code) color = colors.rgb(0xF5, 0xD0, 0x7A);
    if (style.link) color = colors.rgb(0x7A, 0xCA, 0xFF);
    if (style.emphasis and !style.code) color = lighten(color, 0.08);
    if (style.strong and !style.code) color = lighten(color, 0.12);
    return color;
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

fn lighten(color: [4]f32, amount: f32) [4]f32 {
    return .{
        @min(color[0] + amount, 1.0),
        @min(color[1] + amount, 1.0),
        @min(color[2] + amount, 1.0),
        color[3],
    };
}

test "builds a body view with headings lists and fenced code" {
    const allocator = std.testing.allocator;
    const source =
        \\## Review
        \\
        \\- first item
        \\- second item with **bold** and *soft*
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
        .text => |text| {
            try std.testing.expectEqualStrings("- second item with bold and soft", text.text);

            var found_bold = false;
            var found_soft = false;
            for (text.runs) |run| switch (run) {
                .text => |span| {
                    const slice = text.text[span.start..span.end];
                    if (std.mem.eql(u8, slice, "bold")) {
                        found_bold = true;
                        try std.testing.expect(span.style.strong);
                    }
                    if (std.mem.eql(u8, slice, "soft")) {
                        found_soft = true;
                        try std.testing.expect(span.style.emphasis);
                    }
                },
                else => {},
            };
            try std.testing.expect(found_bold);
            try std.testing.expect(found_soft);
        },
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

test "preserves links and inline code runs" {
    const allocator = std.testing.allocator;
    const source = "Use `npm run check` and visit [docs](https://example.com).";

    var body = try buildBodyView(allocator, source);
    defer body.deinit(allocator);

    switch (body.blockAt(0)) {
        .text => |text| {
            var found_code = false;
            var found_link = false;
            for (text.runs) |run| switch (run) {
                .text => |span| {
                    const slice = text.text[span.start..span.end];
                    if (std.mem.eql(u8, slice, "npm run check")) {
                        found_code = true;
                        try std.testing.expect(span.style.code);
                    }
                    if (std.mem.eql(u8, slice, "docs")) {
                        found_link = true;
                        try std.testing.expect(span.style.link);
                    }
                },
                else => {},
            };
            try std.testing.expect(found_code);
            try std.testing.expect(found_link);
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
