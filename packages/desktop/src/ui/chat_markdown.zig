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

pub const SelectionPoint = struct {
    line_index: usize,
    column: usize,
};

pub const SelectionRange = struct {
    anchor: SelectionPoint,
    focus: SelectionPoint,
};

pub const SelectionRenderOutput = struct {
    hovered: bool = false,
    hovered_point: ?SelectionPoint = null,
    first_point: ?SelectionPoint = null,
    last_point: ?SelectionPoint = null,
    copied_text: ?[:0]u8 = null,

    pub fn deinit(self: *SelectionRenderOutput, allocator: Allocator) void {
        if (self.copied_text) |text| {
            allocator.free(text);
            self.copied_text = null;
        }
    }
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

pub fn selectionRangeForClickCount(
    allocator: Allocator,
    view: BodyView,
    available_width: f32,
    options: RenderOptions,
    point: SelectionPoint,
    click_count: usize,
) ?SelectionRange {
    if (click_count < 2) return null;

    const width = @max(available_width, 1.0);
    var global_line_index: usize = 0;
    var previous: ?BlockView = null;

    for (view.blocks) |block| {
        if (previous) |prior| {
            if (prior.kind() != .blank and block.kind() != .blank) {
                if (global_line_index == point.line_index) {
                    return if (click_count >= 3)
                        .{
                            .anchor = .{ .line_index = point.line_index, .column = 0 },
                            .focus = .{ .line_index = point.line_index, .column = 0 },
                        }
                    else
                        null;
                }
                global_line_index += 1;
            }
        }

        switch (block) {
            .blank => {
                if (global_line_index == point.line_index) {
                    return if (click_count >= 3)
                        .{
                            .anchor = .{ .line_index = point.line_index, .column = 0 },
                            .focus = .{ .line_index = point.line_index, .column = 0 },
                        }
                    else
                        null;
                }
                global_line_index += 1;
            },
            .text => |text_block| {
                const indent = indentWidth(text_block.indent);
                const line_width = @max(width - indent, 1.0);
                const lines = buildSelectableTextLines(allocator, text_block, line_width, options) catch return null;
                defer deinitSelectableLines(allocator, lines);

                for (lines) |line| {
                    if (global_line_index == point.line_index) {
                        return selectionRangeForSelectableLine(allocator, point.line_index, line, point.column, click_count);
                    }
                    global_line_index += 1;
                }
            },
            .fenced_code, .thematic_break => {},
        }

        previous = block;
    }

    return null;
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

pub fn renderSelectableBody(
    allocator: Allocator,
    view: BodyView,
    options: RenderOptions,
    selection: ?SelectionRange,
    copy_selection: bool,
) SelectionRenderOutput {
    const available_width = @max(zgui.getContentRegionAvail()[0], 1.0);
    const mouse_pos = zgui.getMousePos();
    const hovered = zgui.isWindowHovered(.{ .allow_when_blocked_by_active_item = true });
    const ordered_selection = if (selection) |active| orderSelection(active) else null;

    var output: SelectionRenderOutput = .{ .hovered = hovered };
    var copy_builder = std.ArrayList(u8).empty;
    defer if (copy_selection) copy_builder.deinit(allocator);
    var copied_any_line = false;
    var global_line_index: usize = 0;
    var previous: ?BlockView = null;

    for (view.blocks) |block| {
        if (previous) |prior| {
            if (prior.kind() != .blank and block.kind() != .blank) {
                const gap_height = if (prior.isCompact() or block.isCompact()) compactBlockGap() else blockGap();
                renderSelectableBlankLine(
                    allocator,
                    &output,
                    ordered_selection,
                    copy_selection,
                    &copy_builder,
                    &copied_any_line,
                    mouse_pos,
                    hovered,
                    global_line_index,
                    gap_height,
                );
                global_line_index += 1;
            }
        }

        switch (block) {
            .blank => {
                renderSelectableBlankLine(
                    allocator,
                    &output,
                    ordered_selection,
                    copy_selection,
                    &copy_builder,
                    &copied_any_line,
                    mouse_pos,
                    hovered,
                    global_line_index,
                    blankBlockHeight(),
                );
                global_line_index += 1;
            },
            .text => |text_block| {
                renderSelectableTextBlock(
                    allocator,
                    &output,
                    ordered_selection,
                    copy_selection,
                    &copy_builder,
                    &copied_any_line,
                    mouse_pos,
                    hovered,
                    &global_line_index,
                    text_block,
                    available_width,
                    options,
                ) catch renderTextBlock(text_block, available_width, options);
            },
            .fenced_code => |code_block| {
                renderFencedCodeBlock(code_block, available_width, options);
            },
            .thematic_break => |rule| {
                renderThematicBreakBlock(rule, available_width);
            },
        }

        previous = block;
    }

    if (copy_selection and copied_any_line) {
        output.copied_text = allocator.dupeZ(u8, copy_builder.items) catch null;
    }

    return output;
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

const OrderedSelection = struct {
    start: SelectionPoint,
    end: SelectionPoint,
};

const SelectableLineChunk = struct {
    text: []const u8,
    block_style: TextStyle,
    inline_style: InlineStyle,
    font_spec: FontSpec,
    x: f32,
    width: f32,
    line_height: f32,
    start_column: usize,
    end_column: usize,
};

const SelectableLine = struct {
    y: f32,
    height: f32,
    total_columns: usize,
    chunks: []SelectableLineChunk,
};

fn orderSelection(selection: SelectionRange) OrderedSelection {
    if (selectionPointLessThan(selection.focus, selection.anchor)) {
        return .{
            .start = selection.focus,
            .end = selection.anchor,
        };
    }
    return .{
        .start = selection.anchor,
        .end = selection.focus,
    };
}

fn selectionPointLessThan(lhs: SelectionPoint, rhs: SelectionPoint) bool {
    return lhs.line_index < rhs.line_index or
        (lhs.line_index == rhs.line_index and lhs.column < rhs.column);
}

fn selectionColumnsForLine(selection: OrderedSelection, line_index: usize, total_columns: usize) ?struct { start: usize, end: usize } {
    if (line_index < selection.start.line_index or line_index > selection.end.line_index) return null;
    return .{
        .start = if (line_index == selection.start.line_index) selection.start.column else 0,
        .end = if (line_index == selection.end.line_index) selection.end.column else total_columns,
    };
}

fn countColumns(text: []const u8) usize {
    var index: usize = 0;
    var columns: usize = 0;
    while (index < text.len) {
        const width = std.unicode.utf8ByteSequenceLength(text[index]) catch return text.len;
        index += width;
        columns += 1;
    }
    return columns;
}

fn byteOffsetForColumn(text: []const u8, column: usize) usize {
    var index: usize = 0;
    var current: usize = 0;
    while (index < text.len and current < column) {
        const width = std.unicode.utf8ByteSequenceLength(text[index]) catch return text.len;
        index += width;
        current += 1;
    }
    return index;
}

fn sliceForColumns(text: []const u8, start_column: usize, end_column: usize) []const u8 {
    const start = byteOffsetForColumn(text, start_column);
    const end = byteOffsetForColumn(text, end_column);
    return text[start..@min(end, text.len)];
}

fn textWidthForColumns(spec: FontSpec, text: []const u8, column: usize) f32 {
    return textWidthForSpec(spec, text[0..byteOffsetForColumn(text, column)]);
}

fn columnForX(spec: FontSpec, text: []const u8, x: f32) usize {
    if (x <= 0.0) return 0;
    const total_columns = countColumns(text);
    if (total_columns == 0) return 0;

    var low: usize = 0;
    var high: usize = total_columns;
    while (low < high) {
        const mid = (low + high + 1) / 2;
        if (textWidthForColumns(spec, text, mid) <= x) {
            low = mid;
        } else {
            high = mid - 1;
        }
    }

    if (low >= total_columns) return total_columns;

    const current_width = textWidthForColumns(spec, text, low);
    const next_width = textWidthForColumns(spec, text, low + 1);
    return if (@abs(x - current_width) <= @abs(next_width - x)) low else low + 1;
}

const ClickSelectionClass = enum {
    whitespace,
    word,
    other,
};

const ClickSelectionCodepoint = struct {
    start_byte: usize,
    end_byte: usize,
    class: ClickSelectionClass,
};

fn deinitSelectableLines(allocator: Allocator, lines: []SelectableLine) void {
    for (lines) |line| allocator.free(line.chunks);
    allocator.free(lines);
}

fn clickSelectionClass(text: []const u8) ClickSelectionClass {
    if (text.len == 0) return .other;
    if (text.len == 1) {
        const byte = text[0];
        if (std.ascii.isWhitespace(byte)) return .whitespace;
        if (std.ascii.isAlphanumeric(byte) or byte == '_') return .word;
        return .other;
    }
    return .word;
}

fn collectSelectableLineText(allocator: Allocator, line: SelectableLine) ![]u8 {
    var buffer = std.ArrayList(u8).empty;
    errdefer buffer.deinit(allocator);
    for (line.chunks) |chunk| {
        try buffer.appendSlice(allocator, chunk.text);
    }
    return buffer.toOwnedSlice(allocator);
}

fn selectionRangeForSelectableLine(
    allocator: Allocator,
    line_index: usize,
    line: SelectableLine,
    column: usize,
    click_count: usize,
) ?SelectionRange {
    if (click_count >= 3) {
        return .{
            .anchor = .{ .line_index = line_index, .column = 0 },
            .focus = .{ .line_index = line_index, .column = line.total_columns },
        };
    }
    if (click_count < 2) return null;
    if (line.total_columns == 0) {
        return .{
            .anchor = .{ .line_index = line_index, .column = 0 },
            .focus = .{ .line_index = line_index, .column = 0 },
        };
    }

    const line_text = collectSelectableLineText(allocator, line) catch return null;
    defer allocator.free(line_text);

    var codepoints = std.ArrayList(ClickSelectionCodepoint).empty;
    defer codepoints.deinit(allocator);

    var index: usize = 0;
    while (index < line_text.len) {
        const width = std.unicode.utf8ByteSequenceLength(line_text[index]) catch return null;
        const next = @min(index + width, line_text.len);
        codepoints.append(allocator, .{
            .start_byte = index,
            .end_byte = next,
            .class = clickSelectionClass(line_text[index..next]),
        }) catch return null;
        index = next;
    }

    if (codepoints.items.len == 0) {
        return .{
            .anchor = .{ .line_index = line_index, .column = 0 },
            .focus = .{ .line_index = line_index, .column = 0 },
        };
    }

    const target_column = if (column >= codepoints.items.len) codepoints.items.len - 1 else column;
    const target_class = codepoints.items[target_column].class;

    var start_column = target_column;
    while (start_column > 0 and codepoints.items[start_column - 1].class == target_class) : (start_column -= 1) {}

    var end_column = target_column + 1;
    while (end_column < codepoints.items.len and codepoints.items[end_column].class == target_class) : (end_column += 1) {}

    return .{
        .anchor = .{ .line_index = line_index, .column = start_column },
        .focus = .{ .line_index = line_index, .column = end_column },
    };
}

fn buildSelectableTextLines(
    allocator: Allocator,
    block: TextBlockView,
    available_width: f32,
    options: RenderOptions,
) ![]SelectableLine {
    const Builder = struct {
        allocator: Allocator,
        lines: std.ArrayList(SelectableLine) = .empty,
        current_chunks: std.ArrayList(SelectableLineChunk) = .empty,
        current_y: ?f32 = null,
        current_height: f32 = 0.0,
        current_columns: usize = 0,
        failed: ?Allocator.Error = null,

        fn finalize(self: *@This()) void {
            if (self.failed != null) return;
            const current_y = self.current_y orelse return;
            const owned_chunks = self.current_chunks.toOwnedSlice(self.allocator) catch {
                self.failed = error.OutOfMemory;
                return;
            };
            self.lines.append(self.allocator, .{
                .y = current_y,
                .height = self.current_height,
                .total_columns = self.current_columns,
                .chunks = owned_chunks,
            }) catch {
                self.allocator.free(owned_chunks);
                self.failed = error.OutOfMemory;
                return;
            };
            self.current_y = null;
            self.current_height = 0.0;
            self.current_columns = 0;
            self.current_chunks = .empty;
        }

        fn onStep(self: *@This(), step: TextBlockLayoutStep) void {
            if (self.failed != null) return;
            if (self.current_y) |current_y| {
                if (step.y != current_y) {
                    self.finalize();
                    if (self.failed != null) return;
                }
            }
            if (self.current_y == null) {
                self.current_y = step.y;
                self.current_height = step.line_height;
                self.current_columns = 0;
            }

            const chunk_columns = countColumns(step.text);
            self.current_chunks.append(self.allocator, .{
                .text = step.text,
                .block_style = step.block_style,
                .inline_style = step.inline_style,
                .font_spec = step.font_spec,
                .x = step.x,
                .width = step.width,
                .line_height = step.line_height,
                .start_column = self.current_columns,
                .end_column = self.current_columns + chunk_columns,
            }) catch {
                self.failed = error.OutOfMemory;
                return;
            };
            self.current_height = @max(self.current_height, step.line_height);
            self.current_columns += chunk_columns;
        }
    };

    var builder: Builder = .{ .allocator = allocator };
    errdefer {
        builder.current_chunks.deinit(allocator);
        deinitSelectableLines(allocator, builder.lines.items);
        builder.lines.deinit(allocator);
    }

    _ = walkTextBlockLayout(block, available_width, options, &builder, Builder.onStep);
    if (builder.failed) |err| return err;
    builder.finalize();
    if (builder.failed) |err| return err;

    if (builder.lines.items.len == 0) {
        const base_line_height = lineHeightForSpec(textBlockFontSpecWithOptions(block.style, options));
        try builder.lines.append(allocator, .{
            .y = 0.0,
            .height = base_line_height,
            .total_columns = 0,
            .chunks = try allocator.alloc(SelectableLineChunk, 0),
        });
    }

    return builder.lines.toOwnedSlice(allocator);
}

fn noteSelectableLineBounds(output: *SelectionRenderOutput, line_index: usize, total_columns: usize) void {
    if (output.first_point == null) {
        output.first_point = .{ .line_index = line_index, .column = 0 };
    }
    output.last_point = .{ .line_index = line_index, .column = total_columns };
}

fn hoveredColumnForLine(line: SelectableLine, local_x: f32) usize {
    if (line.chunks.len == 0) return 0;

    const x = @max(local_x, 0.0);
    var previous_end_x: ?f32 = null;
    var previous_end_column: usize = 0;
    for (line.chunks) |chunk| {
        if (x <= chunk.x) {
            if (previous_end_x) |end_x| {
                return if (@abs(x - end_x) <= @abs(chunk.x - x)) previous_end_column else chunk.start_column;
            }
            return chunk.start_column;
        }

        const chunk_end_x = chunk.x + chunk.width;
        if (x <= chunk_end_x) {
            return chunk.start_column + columnForX(chunk.font_spec, chunk.text, x - chunk.x);
        }

        previous_end_x = chunk_end_x;
        previous_end_column = chunk.end_column;
    }
    return line.total_columns;
}

fn renderSelectableLine(
    allocator: Allocator,
    draw_list: anytype,
    output: *SelectionRenderOutput,
    selection: ?OrderedSelection,
    copy_selection: bool,
    copy_builder: *std.ArrayList(u8),
    copied_any_line: *bool,
    mouse_pos: [2]f32,
    hovered: bool,
    start: [2]f32,
    line_index: usize,
    line: SelectableLine,
) void {
    noteSelectableLineBounds(output, line_index, line.total_columns);

    const top = start[1] + line.y;
    const bottom = top + line.height;
    if (hovered and output.hovered_point == null and mouse_pos[1] >= top and mouse_pos[1] <= bottom) {
        output.hovered_point = .{
            .line_index = line_index,
            .column = hoveredColumnForLine(line, mouse_pos[0] - start[0]),
        };
    }

    if (selection) |ordered| {
        if (selectionColumnsForLine(ordered, line_index, line.total_columns)) |columns| {
            if (columns.start != columns.end) {
                const selection_col = zgui.colorConvertFloat4ToU32(colors.rgba(88, 166, 255, 72));
                for (line.chunks) |chunk| {
                    const chunk_start = @max(columns.start, chunk.start_column);
                    const chunk_end = @min(columns.end, chunk.end_column);
                    if (chunk_start >= chunk_end) continue;

                    const x0 = start[0] + chunk.x + textWidthForColumns(chunk.font_spec, chunk.text, chunk_start - chunk.start_column);
                    const x1 = start[0] + chunk.x + textWidthForColumns(chunk.font_spec, chunk.text, chunk_end - chunk.start_column);
                    if (x1 > x0) {
                        draw_list.addRectFilled(.{
                            .pmin = .{ x0, top },
                            .pmax = .{ x1, bottom },
                            .col = selection_col,
                            .rounding = 2.0,
                        });
                    }
                }
            }

            if (copy_selection) {
                if (copied_any_line.*) {
                    copy_builder.append(allocator, '\n') catch {};
                } else {
                    copied_any_line.* = true;
                }
                for (line.chunks) |chunk| {
                    const chunk_start = @max(columns.start, chunk.start_column);
                    const chunk_end = @min(columns.end, chunk.end_column);
                    if (chunk_start >= chunk_end) continue;
                    copy_builder.appendSlice(allocator, sliceForColumns(chunk.text, chunk_start - chunk.start_column, chunk_end - chunk.start_column)) catch {};
                }
            }
        }
    }

    for (line.chunks) |chunk| {
        renderStyledChunk(
            draw_list,
            .{ start[0] + chunk.x, top },
            chunk.text,
            chunk.block_style,
            chunk.inline_style,
            chunk.font_spec,
            chunk.width,
            chunk.line_height,
        );
    }
}

fn renderSelectableBlankLine(
    allocator: Allocator,
    output: *SelectionRenderOutput,
    selection: ?OrderedSelection,
    copy_selection: bool,
    copy_builder: *std.ArrayList(u8),
    copied_any_line: *bool,
    mouse_pos: [2]f32,
    hovered: bool,
    line_index: usize,
    height: f32,
) void {
    const start = zgui.getCursorScreenPos();
    noteSelectableLineBounds(output, line_index, 0);
    if (hovered and output.hovered_point == null and mouse_pos[1] >= start[1] and mouse_pos[1] <= start[1] + height) {
        output.hovered_point = .{ .line_index = line_index, .column = 0 };
    }
    if (copy_selection) {
        if (selection) |ordered| {
            if (selectionColumnsForLine(ordered, line_index, 0) != null) {
                if (copied_any_line.*) {
                    copy_builder.append(allocator, '\n') catch {};
                } else {
                    copied_any_line.* = true;
                }
            }
        }
    }
    zgui.dummy(.{ .w = 0.0, .h = height });
}

fn renderSelectableTextBlock(
    allocator: Allocator,
    output: *SelectionRenderOutput,
    selection: ?OrderedSelection,
    copy_selection: bool,
    copy_builder: *std.ArrayList(u8),
    copied_any_line: *bool,
    mouse_pos: [2]f32,
    hovered: bool,
    global_line_index: *usize,
    block: TextBlockView,
    available_width: f32,
    options: RenderOptions,
) !void {
    const indent = indentWidth(block.indent);
    if (indent > 0.0) {
        zgui.setCursorPosX(zgui.getCursorPosX() + indent);
    }

    const start = zgui.getCursorScreenPos();
    const width = @max(available_width - indent, 1.0);
    const draw_list = zgui.getWindowDrawList();
    const lines = try buildSelectableTextLines(allocator, block, width, options);
    defer deinitSelectableLines(allocator, lines);

    var height: f32 = 0.0;
    for (lines, 0..) |line, index| {
        renderSelectableLine(
            allocator,
            draw_list,
            output,
            selection,
            copy_selection,
            copy_builder,
            copied_any_line,
            mouse_pos,
            hovered,
            start,
            global_line_index.* + index,
            line,
        );
        height = @max(height, line.y + line.height);
    }

    zgui.dummy(.{ .w = width, .h = height });
    global_line_index.* += lines.len;
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
