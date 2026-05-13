//! Reusable markdown body parsing and rendering helpers for chat threads.

const std = @import("std");

const colors = @import("colors.zig");
const palette = @import("palette");
const text_measure = @import("text_measure.zig");
const theme = @import("theme.zig");
const zig_dif = @import("zig_dif");
const zig_markdown = @import("zig_markdown");

fn transcriptTextWidth(font_size: f32, text: []const u8) f32 {
    return transcriptTextWidthForRole(font_size, .prose, text);
}

fn transcriptTextWidthForRole(font_size: f32, role: palette.FontRole, text: []const u8) f32 {
    if (text.len == 0) return 0.0;
    if (inlineWhitespaceWidth(font_size, text)) |width| return width;
    return text_measure.textWidth(role, font_size, text);
}

// NotoSans-Bold's space advance is ~0.29em before Palette's SDL_GPU atlas text
// scale. Keep manual whitespace measurement aligned with rendered glyphs so
// markdown chunk positions do not create visible rivers between words.
const TRANSCRIPT_SPACE_EM: f32 = 0.26;

fn estimatedTranscriptTextWidth(font_size: f32, text: []const u8) f32 {
    var width: f32 = 0.0;
    for (text) |byte| {
        width += switch (byte) {
            'i', 'l', 'I', '.', ',', ':', ';', '!' => font_size * 0.28,
            'm', 'w', 'M', 'W' => font_size * 0.78,
            ' ' => font_size * TRANSCRIPT_SPACE_EM,
            '\t' => font_size * TRANSCRIPT_SPACE_EM * 4.0,
            else => font_size * 0.55,
        };
    }
    return width;
}

fn inlineWhitespaceWidth(font_size: f32, text: []const u8) ?f32 {
    var width: f32 = 0.0;
    for (text) |byte| {
        switch (byte) {
            ' ' => width += font_size * TRANSCRIPT_SPACE_EM,
            '\t' => width += font_size * TRANSCRIPT_SPACE_EM * 4.0,
            else => return null,
        }
    }
    return width;
}

const Allocator = std.mem.Allocator;

/// Opaque fill: translucent alpha looked muddy over dark transcript bubbles under GL blending.
const markdown_selection_fill_rgba = colors.rgba(88, 166, 255, 255);

pub const RenderOptions = struct {
    base_font_size: f32 = 24.0,
    line_height: ?f32 = null,
    glyph_width: ?f32 = null,
    heading_font: ?*anyopaque = null,
    heading_font_size: ?f32 = null,
    bold_font: ?*anyopaque = null,
    italic_font: ?*anyopaque = null,
    bold_italic_font: ?*anyopaque = null,
    code_font: ?*anyopaque = null,
    code_font_size: ?f32 = null,
};

pub const PaletteRenderContext = struct {
    allocator: Allocator,
    batch: *palette.RenderBatch,
    frame_text: *std.ArrayList(u8),
    cursor: palette.Rect,
    available_width: f32,
    mouse_pos: [2]f32 = .{ -1.0, -1.0 },
    hovered: bool = false,
    clip: ?palette.Rect = null,
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

pub const TableCellView = struct {
    text: []const u8,
    runs: []InlineRunView,

    pub fn deinit(self: *TableCellView, allocator: Allocator) void {
        allocator.free(self.text);
        allocator.free(self.runs);
        self.* = undefined;
    }
};

pub const TableRowView = struct {
    cells: []TableCellView,

    pub fn deinit(self: *TableRowView, allocator: Allocator) void {
        for (self.cells) |*cell| cell.deinit(allocator);
        allocator.free(self.cells);
        self.* = undefined;
    }
};

pub const TableView = struct {
    span: zig_markdown.Span,
    alignments: []zig_markdown.TableAlignment,
    header: TableRowView,
    rows: []TableRowView,
    indent: usize = 0,
    compact: bool = false,

    pub fn deinit(self: *TableView, allocator: Allocator) void {
        self.header.deinit(allocator);
        for (self.rows) |*row| row.deinit(allocator);
        allocator.free(self.rows);
        allocator.free(self.alignments);
        self.* = undefined;
    }
};

pub const BlockKind = enum {
    blank,
    text,
    fenced_code,
    thematic_break,
    table,
};

pub const BlockView = union(enum) {
    blank: zig_markdown.Span,
    text: TextBlockView,
    fenced_code: FencedCodeView,
    thematic_break: ThematicBreakView,
    table: TableView,

    pub fn kind(self: BlockView) BlockKind {
        return switch (self) {
            .blank => .blank,
            .text => .text,
            .fenced_code => .fenced_code,
            .thematic_break => .thematic_break,
            .table => .table,
        };
    }

    pub fn span(self: BlockView) zig_markdown.Span {
        return switch (self) {
            .blank => |blank_span| blank_span,
            .text => |text| text.span,
            .fenced_code => |code| code.span,
            .thematic_break => |rule| rule.span,
            .table => |t| t.span,
        };
    }

    pub fn isCompact(self: BlockView) bool {
        return switch (self) {
            .blank => false,
            .text => |text| text.compact,
            .fenced_code => |code| code.compact,
            .thematic_break => |rule| rule.compact,
            .table => |t| t.compact,
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
    _ = view;
    _ = options;
}

/// Renders a parsed markdown body into a Palette batch and advances `context.cursor.y`.
pub fn renderPaletteBody(context: *PaletteRenderContext, view: BodyView, options: RenderOptions) void {
    const available_width = @max(context.available_width, 1.0);

    var previous: ?BlockView = null;
    for (view.blocks) |block| {
        if (previous) |prior| {
            if (prior.kind() != .blank and block.kind() != .blank) {
                advancePaletteCursor(context, if (prior.isCompact() or block.isCompact()) compactBlockGap(options) else blockGap(options));
            }
        }

        switch (block) {
            .blank => renderPaletteBlankBlock(context, options),
            .text => |text| renderPaletteTextBlock(context, text, available_width, options),
            .fenced_code => |code| renderPaletteFencedCodeBlock(context, code, available_width, options),
            .thematic_break => |rule| renderPaletteThematicBreakBlock(context, rule, available_width, options),
            .table => |table| renderPaletteTableBlock(context, table, available_width, options),
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
                        const line_text = collectSelectableLineText(allocator, line) catch return null;
                        defer allocator.free(line_text);
                        return selectionRangeForRawLine(allocator, point.line_index, line_text, line.total_columns, point.column, click_count);
                    }
                    global_line_index += 1;
                }
            },
            .fenced_code => |code_block| {
                const lines = buildSelectableCodeLines(allocator, code_block, options) catch return null;
                defer deinitSelectableCodeLines(allocator, lines);

                for (lines) |line| {
                    if (global_line_index == point.line_index) {
                        return selectionRangeForRawLine(allocator, point.line_index, line.text, line.total_columns, point.column, click_count);
                    }
                    global_line_index += 1;
                }
            },
            .thematic_break => {},
            .table => {
                // Tables aren't selectable line-by-line yet; treat each rendered
                // row as one logical line so global_line_index advances and
                // subsequent block lookups stay aligned.
                const row_count = 1 + block.table.rows.len;
                global_line_index += row_count;
            },
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
                total += if (prior.isCompact() or block.isCompact()) compactBlockGap(options) else blockGap(options);
            }
        }

        total += switch (block) {
            .blank => blankBlockHeight(options),
            .text => |text| measureTextBlockHeight(text, width, options),
            .fenced_code => |code| measureFencedCodeHeight(code, width, options),
            .thematic_break => |rule| measureThematicBreakHeight(rule),
            .table => |table| measureTableHeight(table, width, options),
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
    _ = allocator;
    _ = view;
    _ = options;
    _ = selection;
    _ = copy_selection;
    return .{};
}

/// Selectable Palette markdown fallback. It preserves copy/select point behavior with fixed metrics,
/// but callers must still route mouse and batch context explicitly.
pub fn renderSelectablePaletteBody(
    context: *PaletteRenderContext,
    allocator: Allocator,
    view: BodyView,
    options: RenderOptions,
    selection: ?SelectionRange,
    copy_selection: bool,
) SelectionRenderOutput {
    const available_width = @max(context.available_width, 1.0);
    const mouse_pos = context.mouse_pos;
    const hovered = context.hovered;
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
                const gap_height = if (prior.isCompact() or block.isCompact()) compactBlockGap(options) else blockGap(options);
                renderSelectableBlankLine(
                    allocator,
                    &output,
                    ordered_selection,
                    copy_selection,
                    &copy_builder,
                    &copied_any_line,
                    mouse_pos,
                    hovered,
                    context,
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
                    context,
                    global_line_index,
                    blankBlockHeight(options),
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
                    context,
                    &global_line_index,
                    text_block,
                    available_width,
                    options,
                ) catch renderPaletteTextBlock(context, text_block, available_width, options);
            },
            .fenced_code => |code_block| {
                renderSelectablePaletteCodeBlock(
                    allocator,
                    &output,
                    ordered_selection,
                    copy_selection,
                    &copy_builder,
                    &copied_any_line,
                    mouse_pos,
                    hovered,
                    context,
                    &global_line_index,
                    code_block,
                    available_width,
                    options,
                ) catch renderPaletteFencedCodeBlock(context, code_block, available_width, options);
            },
            .thematic_break => |rule| {
                renderPaletteThematicBreakBlock(context, rule, available_width, options);
            },
            .table => |table_block| {
                // Tables don't participate in line-level selection yet; render
                // the block and bump global_line_index past its rows so the
                // caller's selection coordinates stay in sync.
                renderPaletteTableBlock(context, table_block, available_width, options);
                global_line_index += 1 + table_block.rows.len;
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
            .table => |table| try blocks.append(allocator, .{
                .table = try buildTableView(allocator, table, context),
            }),
        }
    }
}

fn buildTableCellView(
    allocator: Allocator,
    cell: zig_markdown.TableCell,
) Allocator.Error!TableCellView {
    var content = try buildTextContent(allocator, cell.inlines);
    errdefer content.deinit(allocator);
    return .{
        .text = content.text,
        .runs = content.runs,
    };
}

fn buildTableRowView(
    allocator: Allocator,
    row: zig_markdown.TableRow,
) Allocator.Error!TableRowView {
    const cells = try allocator.alloc(TableCellView, row.cells.len);
    errdefer {
        for (cells) |*cell| cell.deinit(allocator);
        allocator.free(cells);
    }
    for (row.cells, 0..) |cell, i| {
        cells[i] = try buildTableCellView(allocator, cell);
    }
    return .{ .cells = cells };
}

fn buildTableView(
    allocator: Allocator,
    table: zig_markdown.TableBlock,
    context: FlattenContext,
) Allocator.Error!TableView {
    const alignments = try allocator.dupe(zig_markdown.TableAlignment, table.alignments);
    errdefer allocator.free(alignments);

    var header = try buildTableRowView(allocator, table.header);
    errdefer header.deinit(allocator);

    const rows = try allocator.alloc(TableRowView, table.rows.len);
    errdefer {
        for (rows) |*row| row.deinit(allocator);
        allocator.free(rows);
    }
    for (table.rows, 0..) |row, i| {
        rows[i] = try buildTableRowView(allocator, row);
    }

    return .{
        .span = table.span,
        .alignments = alignments,
        .header = header,
        .rows = rows,
        .indent = context.indent,
        .compact = context.compact,
    };
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
        // U+2022 bullet (`•`) reads as a real list mark instead of a literal
        // hyphen. The trailing space gives breathing room before the item text;
        // hanging-indent for wrapped continuation lines is handled separately
        // via the `indent` field on the flattened TextBlockView.
        .unordered => allocator.dupe(u8, "•  "),
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
            .table => |table| {
                var owned = table;
                owned.deinit(allocator);
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
    _ = language;
    if (line.len == 0) return &[_]zig_dif.Token{};

    const tokens = try allocator.alloc(zig_dif.Token, 1);
    tokens[0] = .{
        .kind = .plain,
        .text = line,
    };
    return tokens;
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

fn renderPaletteBlankBlock(context: *PaletteRenderContext, options: RenderOptions) void {
    advancePaletteCursor(context, blankBlockHeight(options));
}

fn renderPaletteTextBlock(context: *PaletteRenderContext, block: TextBlockView, available_width: f32, options: RenderOptions) void {
    const indent = indentWidth(block.indent);
    const start = .{ context.cursor.x + indent, context.cursor.y };
    const width = @max(available_width - indent, 1.0);
    const height = renderPaletteTextBlockLayout(context, .{ start[0], start[1] }, block, width, options);

    advancePaletteCursor(context, height);
}

fn renderPaletteFencedCodeBlock(context: *PaletteRenderContext, block: FencedCodeView, available_width: f32, options: RenderOptions) void {
    const indent = indentWidth(block.indent);
    const start = .{ context.cursor.x + indent, context.cursor.y };
    const width = @max(available_width - indent, minimumCodeBlockWidth(options));
    const line_height = codeLineHeight(options);
    const pad_x = codeBlockPaddingX(options);
    const pad_y = codeBlockPaddingY(options);
    const height = codeBlockHeight(block, line_height, pad_y);
    const rect: palette.Rect = .{ .x = start[0], .y = start[1], .w = width, .h = height };
    queuePaletteRoundedShell(
        context,
        rect,
        paletteColor(colors.rgba(24, 24, 28, 255)),
        paletteColor(colors.rgba(52, 54, 62, 255)),
        codeBlockRounding(options),
    );

    var y = start[1] + pad_y;
    for (block.lines) |line| {
        renderPaletteCodeLine(context, line, .{
            .x = start[0] + pad_x,
            .y = y,
            .max_x = start[0] + width - pad_x,
        }, options, rect);
        y += line_height;
    }

    advancePaletteCursor(context, height);
}

fn renderPaletteThematicBreakBlock(context: *PaletteRenderContext, rule: ThematicBreakView, available_width: f32, options: RenderOptions) void {
    const indent = indentWidth(rule.indent);
    const start = .{ context.cursor.x + indent, context.cursor.y };
    const width = @max(available_width - indent, 24.0);
    const height = thematicBreakHeight(options);
    const y = start[1] + height * 0.5;
    queuePaletteRect(context, .{ .x = start[0], .y = y, .w = width, .h = 1.0 }, paletteColor(colors.rgba(68, 72, 82, 255)));
    advancePaletteCursor(context, height);
}

/// Per-row height for a single-line table cell, including vertical padding.
fn tableRowHeight(options: RenderOptions) f32 {
    return defaultLineHeight(options) + tableCellPaddingY(options) * 2.0;
}

fn tableCellPaddingX(options: RenderOptions) f32 {
    return @max(defaultLineHeight(options) * 0.45, 8.0);
}

fn tableCellPaddingY(options: RenderOptions) f32 {
    return @max(defaultLineHeight(options) * 0.20, 4.0);
}

fn measureTableHeight(table: TableView, available_width: f32, options: RenderOptions) f32 {
    _ = available_width;
    const rows: f32 = 1.0 + @as(f32, @floatFromInt(table.rows.len));
    return tableRowHeight(options) * rows;
}

/// Sum of per-column natural widths and the available width, used to decide
/// whether columns need to be scaled down to fit.
const TableColumnMetrics = struct {
    widths: []f32,
    total_natural: f32,
};

fn buildTableColumnMetrics(
    allocator: Allocator,
    table: TableView,
    options: RenderOptions,
) !TableColumnMetrics {
    const column_count = table.header.cells.len;
    const widths = try allocator.alloc(f32, column_count);
    @memset(widths, 0.0);

    const base_size = options.base_font_size;

    // Header drives the bold-weight width; body rows use prose weight.
    for (table.header.cells, 0..) |cell, col| {
        const w = text_measure.textWidth(.prose_bold, base_size, cell.text);
        if (w > widths[col]) widths[col] = w;
    }
    for (table.rows) |row| {
        for (row.cells, 0..) |cell, col| {
            if (col >= column_count) break;
            const w = text_measure.textWidth(.prose, base_size, cell.text);
            if (w > widths[col]) widths[col] = w;
        }
    }

    const pad_x = tableCellPaddingX(options);
    var total: f32 = 0.0;
    for (widths) |*w| {
        w.* += pad_x * 2.0;
        total += w.*;
    }
    return .{ .widths = widths, .total_natural = total };
}

fn renderPaletteTableBlock(
    context: *PaletteRenderContext,
    table: TableView,
    available_width: f32,
    options: RenderOptions,
) void {
    if (table.header.cells.len == 0) return;

    const indent = indentWidth(table.indent);
    const start = .{ context.cursor.x + indent, context.cursor.y };
    const width = @max(available_width - indent, 1.0);

    const metrics = buildTableColumnMetrics(context.allocator, table, options) catch return;
    defer context.allocator.free(metrics.widths);

    // Scale columns proportionally so the table fills exactly `width`. This
    // both shrinks overflow and pads narrow tables to span the body column.
    const scale: f32 = if (metrics.total_natural > 0.0) width / metrics.total_natural else 1.0;

    const row_h = tableRowHeight(options);
    const pad_x = tableCellPaddingX(options);
    const pad_y = tableCellPaddingY(options);
    const border_color = paletteColor(colors.rgba(68, 72, 82, 255));
    const header_bg = paletteColor(colors.rgba(38, 41, 48, 200));

    // Header background tint + bottom border.
    queuePaletteRect(context, .{ .x = start[0], .y = start[1], .w = width, .h = row_h }, header_bg);

    // Draw all row content first, then borders on top so they read clearly.
    var row_index: usize = 0;
    var y_cursor: f32 = start[1];
    drawTableRow(context, table.header, metrics.widths, table.alignments, scale, start[0], y_cursor, pad_x, pad_y, row_h, options, true);
    y_cursor += row_h;
    while (row_index < table.rows.len) : (row_index += 1) {
        drawTableRow(context, table.rows[row_index], metrics.widths, table.alignments, scale, start[0], y_cursor, pad_x, pad_y, row_h, options, false);
        y_cursor += row_h;
    }

    const total_h = row_h * (1.0 + @as(f32, @floatFromInt(table.rows.len)));

    // Horizontal rules between rows + outer top/bottom.
    queuePaletteRect(context, .{ .x = start[0], .y = start[1], .w = width, .h = 1.0 }, border_color);
    queuePaletteRect(context, .{ .x = start[0], .y = start[1] + total_h - 1.0, .w = width, .h = 1.0 }, border_color);
    var rb: usize = 0;
    while (rb <= table.rows.len) : (rb += 1) {
        const yy = start[1] + row_h * @as(f32, @floatFromInt(rb));
        queuePaletteRect(context, .{ .x = start[0], .y = yy, .w = width, .h = 1.0 }, border_color);
    }

    // Vertical rules between columns + outer left/right.
    var x_cursor: f32 = start[0];
    queuePaletteRect(context, .{ .x = x_cursor, .y = start[1], .w = 1.0, .h = total_h }, border_color);
    for (metrics.widths) |w| {
        x_cursor += w * scale;
        queuePaletteRect(context, .{ .x = x_cursor, .y = start[1], .w = 1.0, .h = total_h }, border_color);
    }

    advancePaletteCursor(context, total_h);
}

fn drawTableRow(
    context: *PaletteRenderContext,
    row: TableRowView,
    column_widths: []f32,
    alignments: []zig_markdown.TableAlignment,
    scale: f32,
    x0: f32,
    y0: f32,
    pad_x: f32,
    pad_y: f32,
    row_h: f32,
    options: RenderOptions,
    is_header: bool,
) void {
    const font_size = options.base_font_size;
    const role: palette.FontRole = if (is_header) .prose_bold else .prose;
    const color = paletteColor(if (is_header) colors.rgb(0xF2, 0xE6, 0x8D) else colors.rgb(0xE2, 0xE4, 0xE9));
    const line_height = defaultLineHeight(options);
    const text_y = y0 + pad_y + (row_h - pad_y * 2.0 - line_height) * 0.5;

    var x_cursor: f32 = x0;
    for (row.cells, 0..) |cell, col| {
        if (col >= column_widths.len) break;
        const cell_w = column_widths[col] * scale;
        const content_w = @max(cell_w - pad_x * 2.0, 1.0);
        const text_w = text_measure.textWidth(role, font_size, cell.text);

        const alignment: zig_markdown.TableAlignment = if (col < alignments.len) alignments[col] else .default;
        const align_offset: f32 = switch (alignment) {
            .center => @max((content_w - text_w) * 0.5, 0.0),
            .right => @max(content_w - text_w, 0.0),
            else => 0.0,
        };

        queuePaletteRoleText(context, .{
            .x = x_cursor + pad_x + align_offset,
            .y = text_y,
            .w = content_w,
            .h = line_height,
        }, cell.text, color, font_size, role, context.clip);

        x_cursor += cell_w;
    }
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
    var state = TextBlockLayoutState.init(lineHeightForSpec(block_font, options));

    for (block.runs) |run| {
        switch (run) {
            .line_break => state.advanceLine(),
            .text => |text_run| {
                const spec = inlineFontSpec(block.style, text_run.style, options);
                const chunk_line_height = lineHeightForSpec(spec, options);
                const slice = block.text[text_run.start..text_run.end];
                const layout_font_size = fontSizeForSpecWithOptions(spec, options);
                const measure_role = markdownFontRole(block.style, text_run.style);
                var chunk_start: usize = 0;
                while (nextChunk(slice, &chunk_start)) |chunk| {
                    const chunk_width = transcriptTextWidthForRole(layout_font_size, measure_role, chunk.text);

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

fn subsliceByteOffset(haystack: []const u8, needle: []const u8) usize {
    if (needle.len == 0) return 0;
    const hptr = @intFromPtr(haystack.ptr);
    const nptr = @intFromPtr(needle.ptr);
    std.debug.assert(nptr >= hptr and nptr + needle.len <= hptr + haystack.len);
    return nptr - hptr;
}

fn renderOptionsGlyphWidth(options: RenderOptions) f32 {
    return options.glyph_width orelse options.base_font_size * 0.55;
}

const MarkdownUnderlineSpec = struct {
    rect: palette.Rect,
    color: palette.Color,
};

fn renderPaletteTextBlockLayout(
    context: *PaletteRenderContext,
    start: [2]f32,
    block: TextBlockView,
    available_width: f32,
    options: RenderOptions,
) f32 {
    var underlines: std.ArrayList(MarkdownUnderlineSpec) = .empty;
    defer underlines.deinit(context.allocator);
    var code_pills: std.ArrayList(palette.Rect) = .empty;
    defer code_pills.deinit(context.allocator);
    var text_runs: std.ArrayList(palette.TextRun) = .empty;
    defer text_runs.deinit(context.allocator);

    const RenderContext = struct {
        palette_context: *PaletteRenderContext,
        start: [2]f32,
        options: RenderOptions,
        block_text: []const u8,
        text_runs: *std.ArrayList(palette.TextRun),
        underlines: *std.ArrayList(MarkdownUnderlineSpec),
        code_pills: *std.ArrayList(palette.Rect),

        fn onStep(ctx: @This(), step: TextBlockLayoutStep) void {
            const px = ctx.start[0] + step.x;

            const draw_font_size = fontSizeForSpecWithOptions(step.font_spec, ctx.options);
            const block_font = textBlockFontSpecWithOptions(step.block_style, ctx.options);
            const block_line_height = lineHeightForSpec(block_font, ctx.options);
            // Bottom-align small chunks (inline code) so their baseline sits on
            // the surrounding prose baseline instead of floating mid-line. The
            // text run is top-positioned, so shifting `py` by the line-height
            // delta brings the smaller box down to share the larger box's
            // bottom edge.
            const py_offset: f32 = if (step.line_height < block_line_height)
                (block_line_height - step.line_height)
            else
                0.0;
            const py = ctx.start[1] + step.y + py_offset;

            const color = paletteColor(inlineTextColor(textBlockColor(step.block_style), step.inline_style));
            const clip = ctx.palette_context.clip;
            const byte_start = subsliceByteOffset(ctx.block_text, step.text);
            const byte_end = byte_start + step.text.len;
            const role = markdownFontRole(step.block_style, step.inline_style);

            // Inline-code pill: collect a per-chunk rect; adjacent code chunks
            // (including whitespace inside the span) tile edge-to-edge and read
            // as one continuous pill behind the text.
            if (step.inline_style.code) {
                const pill_inset_y: f32 = @max(step.line_height * 0.08, 1.0);
                ctx.code_pills.append(ctx.palette_context.allocator, .{
                    .x = px,
                    .y = py + pill_inset_y,
                    .w = step.width,
                    .h = step.line_height - pill_inset_y * 2.0,
                }) catch {};
            }

            ctx.text_runs.append(ctx.palette_context.allocator, .{
                .text = step.text,
                .byte_start = byte_start,
                .byte_end = byte_end,
                .x = px,
                .y = py,
                .font_size = draw_font_size,
                .line_height = step.line_height,
                .color = color,
                .clip = clip,
                .font_role = role,
            }) catch return;

            if (step.inline_style.link or step.inline_style.emphasis) {
                const underline_color = if (step.inline_style.link)
                    paletteColor(colors.rgb(0x7A, 0xCA, 0xFF))
                else
                    color;
                const underline_h: f32 = if (step.inline_style.link) 1.5 else 1.0;
                ctx.underlines.append(ctx.palette_context.allocator, .{
                    .rect = .{
                        .x = px,
                        .y = py + step.line_height - 2.0,
                        .w = step.width,
                        .h = underline_h,
                    },
                    .color = underline_color,
                }) catch return;
            }
        }
    };

    const height = walkTextBlockLayout(block, available_width, options, RenderContext{
        .palette_context = context,
        .start = start,
        .options = options,
        .block_text = block.text,
        .text_runs = &text_runs,
        .underlines = &underlines,
        .code_pills = &code_pills,
    }, RenderContext.onStep);

    // Queue pill backgrounds before the text batch so they render behind the glyphs.
    if (code_pills.items.len > 0) {
        const pill_color = paletteColor(colors.rgba(38, 41, 48, 235));
        const pill_radius = @max(theme.scaledUi(3.0), 2.0);
        for (code_pills.items) |rect| {
            queuePaletteRoundedRect(context, rect, pill_color, pill_radius);
        }
    }

    if (text_runs.items.len > 0) {
        // `block.text` is freed when the BodyView is deinit'd after this frame's layout
        // pass, while the overlay batch is drawn later — same as `queuePaletteText` we must
        // duplicate into `frame_text` so run slices stay valid until the batch is consumed.
        const stable_body = stablePaletteText(context, block.text) catch return height;
        for (text_runs.items) |*run| {
            run.text = stable_body[run.byte_start..run.byte_end];
        }

        const cmd_rect: palette.Rect = .{
            .x = start[0],
            .y = start[1],
            .w = available_width,
            .h = height,
        };
        context.batch.textRuns(
            context.allocator,
            cmd_rect,
            stable_body,
            text_runs.items,
            palette.Color.white,
            options.base_font_size,
            context.clip,
            defaultLineHeight(options),
            renderOptionsGlyphWidth(options),
        ) catch {};
    }

    for (underlines.items) |spec| {
        queuePaletteRect(context, spec.rect, spec.color);
    }

    return height;
}

fn measureTextBlockLayout(
    block: TextBlockView,
    available_width: f32,
    options: RenderOptions,
) f32 {
    return walkTextBlockLayout(block, available_width, options, {}, ignoreTextBlockLayoutStep);
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

const SelectableCodeLineChunk = struct {
    text: []const u8,
    token_kind: zig_dif.TokenKind,
    font_spec: FontSpec,
    x: f32,
    width: f32,
    start_column: usize,
    end_column: usize,
};

const SelectableCodeLine = struct {
    text: []const u8,
    y: f32,
    height: f32,
    total_columns: usize,
    chunks: []SelectableCodeLineChunk,
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

pub fn selectionPointLessThan(lhs: SelectionPoint, rhs: SelectionPoint) bool {
    return lhs.line_index < rhs.line_index or
        (lhs.line_index == rhs.line_index and lhs.column < rhs.column);
}

pub fn orderTranscriptMarkdownEndpoints(
    anchor_msg: usize,
    anchor_pt: SelectionPoint,
    focus_msg: usize,
    focus_pt: SelectionPoint,
) struct { start_msg: usize, start_pt: SelectionPoint, end_msg: usize, end_pt: SelectionPoint } {
    if (anchor_msg < focus_msg) {
        return .{ .start_msg = anchor_msg, .start_pt = anchor_pt, .end_msg = focus_msg, .end_pt = focus_pt };
    }
    if (focus_msg < anchor_msg) {
        return .{ .start_msg = focus_msg, .start_pt = focus_pt, .end_msg = anchor_msg, .end_pt = anchor_pt };
    }
    if (selectionPointLessThan(anchor_pt, focus_pt)) {
        return .{ .start_msg = anchor_msg, .start_pt = anchor_pt, .end_msg = focus_msg, .end_pt = focus_pt };
    }
    return .{ .start_msg = anchor_msg, .start_pt = focus_pt, .end_msg = focus_msg, .end_pt = anchor_pt };
}

pub fn lastSelectablePointInBody(
    allocator: Allocator,
    view: BodyView,
    available_width: f32,
    options: RenderOptions,
) Allocator.Error!SelectionPoint {
    const width = @max(available_width, 1.0);
    var global_line_index: usize = 0;
    var previous: ?BlockView = null;
    var last: SelectionPoint = .{ .line_index = 0, .column = 0 };

    for (view.blocks) |block| {
        if (previous) |prior| {
            if (prior.kind() != .blank and block.kind() != .blank) {
                last = .{ .line_index = global_line_index, .column = 0 };
                global_line_index += 1;
            }
        }

        switch (block) {
            .blank => {
                last = .{ .line_index = global_line_index, .column = 0 };
                global_line_index += 1;
            },
            .text => |text_block| {
                const indent = indentWidth(text_block.indent);
                const lines = try buildSelectableTextLines(allocator, text_block, @max(width - indent, 1.0), options);
                defer deinitSelectableLines(allocator, lines);
                for (lines) |line| {
                    last = .{ .line_index = global_line_index, .column = line.total_columns };
                    global_line_index += 1;
                }
            },
            .fenced_code => |code_block| {
                const lines = try buildSelectableCodeLines(allocator, code_block, options);
                defer deinitSelectableCodeLines(allocator, lines);
                for (lines) |line| {
                    last = .{ .line_index = global_line_index, .column = line.total_columns };
                    global_line_index += 1;
                }
            },
            .thematic_break => {},
            .table => |table_block| {
                // One logical line per row (header + body). No per-cell column
                // resolution yet — selection inside tables is a future task.
                const row_count = 1 + table_block.rows.len;
                last = .{ .line_index = global_line_index + row_count - 1, .column = 0 };
                global_line_index += row_count;
            },
        }

        previous = block;
    }

    return last;
}

pub fn localMarkdownSelectionRangeForMessage(
    allocator: Allocator,
    anchor_msg: usize,
    anchor_pt: SelectionPoint,
    focus_msg: usize,
    focus_pt: SelectionPoint,
    message_index: usize,
    view: BodyView,
    available_width: f32,
    options: RenderOptions,
) Allocator.Error!?SelectionRange {
    const o = orderTranscriptMarkdownEndpoints(anchor_msg, anchor_pt, focus_msg, focus_pt);
    if (message_index < o.start_msg or message_index > o.end_msg) return null;
    if (o.start_msg == o.end_msg and message_index == o.start_msg) {
        return .{ .anchor = o.start_pt, .focus = o.end_pt };
    }
    if (message_index == o.start_msg) {
        const last = try lastSelectablePointInBody(allocator, view, available_width, options);
        return .{ .anchor = o.start_pt, .focus = last };
    }
    if (message_index == o.end_msg) {
        return .{ .anchor = .{ .line_index = 0, .column = 0 }, .focus = o.end_pt };
    }
    const last = try lastSelectablePointInBody(allocator, view, available_width, options);
    return .{ .anchor = .{ .line_index = 0, .column = 0 }, .focus = last };
}

/// Hit-tests markdown body layout in the same coordinate space as [`PaletteRenderContext.cursor`]
/// (origin at `body_rect` top-left). Returns null when the pointer is outside selectable lines.
pub fn hitTestSelectablePaletteBody(
    allocator: Allocator,
    view: BodyView,
    options: RenderOptions,
    body_rect: palette.Rect,
    available_width: f32,
    mouse_x: f32,
    mouse_y: f32,
) Allocator.Error!?SelectionPoint {
    const mouse = [2]f32{ mouse_x, mouse_y };
    const width = @max(available_width, 1.0);
    var context_cursor = body_rect;
    var global_line_index: usize = 0;
    var previous: ?BlockView = null;

    for (view.blocks) |block| {
        if (previous) |prior| {
            if (prior.kind() != .blank and block.kind() != .blank) {
                const gap_height = if (prior.isCompact() or block.isCompact()) compactBlockGap(options) else blockGap(options);
                const start = .{ context_cursor.x, context_cursor.y };
                const top = start[1];
                const bottom = top + gap_height;
                if (mouse[1] >= top and mouse[1] <= bottom and mouse[0] >= body_rect.x and mouse[0] <= body_rect.x + body_rect.w) {
                    return .{ .line_index = global_line_index, .column = 0 };
                }
                context_cursor.y += gap_height;
                context_cursor.h = @max(context_cursor.h, gap_height);
                global_line_index += 1;
            }
        }

        switch (block) {
            .blank => {
                const height = blankBlockHeight(options);
                const start = .{ context_cursor.x, context_cursor.y };
                const top = start[1];
                const bottom = top + height;
                if (mouse[1] >= top and mouse[1] <= bottom and mouse[0] >= body_rect.x and mouse[0] <= body_rect.x + body_rect.w) {
                    return .{ .line_index = global_line_index, .column = 0 };
                }
                context_cursor.y += height;
                context_cursor.h = @max(context_cursor.h, height);
                global_line_index += 1;
            },
            .text => |text_block| {
                const indent = indentWidth(text_block.indent);
                const start = .{ context_cursor.x + indent, context_cursor.y };
                const line_width = @max(width - indent, 1.0);
                const lines = try buildSelectableTextLines(allocator, text_block, line_width, options);
                defer deinitSelectableLines(allocator, lines);

                var height: f32 = 0.0;
                for (lines, 0..) |line, index| {
                    const top = start[1] + line.y;
                    const bottom = top + line.height;
                    if (mouse[1] >= top and mouse[1] <= bottom) {
                        const col = hoveredColumnForLine(line, mouse[0] - start[0]);
                        return .{ .line_index = global_line_index + index, .column = col };
                    }
                    height = @max(height, line.y + line.height);
                }
                context_cursor.y += height;
                context_cursor.h = @max(context_cursor.h, height);
                global_line_index += lines.len;
            },
            .fenced_code => |code_block| {
                const indent = indentWidth(code_block.indent);
                const start = .{ context_cursor.x + indent, context_cursor.y };
                const line_height = codeLineHeight(options);
                const pad_x = codeBlockPaddingX(options);
                const pad_y = codeBlockPaddingY(options);
                const height = codeBlockHeight(code_block, line_height, pad_y);
                const content_start = .{ start[0] + pad_x, start[1] + pad_y };

                const lines = try buildSelectableCodeLines(allocator, code_block, options);
                defer deinitSelectableCodeLines(allocator, lines);

                for (lines, 0..) |line, index| {
                    const top = content_start[1] + line.y;
                    const bottom = top + line.height;
                    if (mouse[1] >= top and mouse[1] <= bottom) {
                        const col = hoveredColumnForCodeLine(line, mouse[0] - content_start[0]);
                        return .{ .line_index = global_line_index + index, .column = col };
                    }
                }

                context_cursor.y += height;
                context_cursor.h = @max(context_cursor.h, height);
                global_line_index += lines.len;
            },
            .thematic_break => |rule| {
                const indent = indentWidth(rule.indent);
                const height = thematicBreakHeight(options);
                _ = indent;
                context_cursor.y += height;
                context_cursor.h = @max(context_cursor.h, height);
            },
            .table => |table_block| {
                const height = measureTableHeight(table_block, width, options);
                const top = context_cursor.y;
                const bottom = top + height;
                if (mouse[1] >= top and mouse[1] <= bottom and mouse[0] >= body_rect.x and mouse[0] <= body_rect.x + body_rect.w) {
                    return .{ .line_index = global_line_index, .column = 0 };
                }
                context_cursor.y += height;
                context_cursor.h = @max(context_cursor.h, height);
                global_line_index += 1 + table_block.rows.len;
            },
        }

        previous = block;
    }

    return null;
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

fn deinitSelectableCodeLines(allocator: Allocator, lines: []SelectableCodeLine) void {
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

fn selectionRangeForRawLine(
    allocator: Allocator,
    line_index: usize,
    line_text: []const u8,
    total_columns: usize,
    column: usize,
    click_count: usize,
) ?SelectionRange {
    if (click_count >= 3) {
        return .{
            .anchor = .{ .line_index = line_index, .column = 0 },
            .focus = .{ .line_index = line_index, .column = total_columns },
        };
    }
    if (click_count < 2) return null;
    if (total_columns == 0) {
        return .{
            .anchor = .{ .line_index = line_index, .column = 0 },
            .focus = .{ .line_index = line_index, .column = 0 },
        };
    }

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
        const base_line_height = lineHeightForSpec(textBlockFontSpecWithOptions(block.style, options), options);
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
    output: *SelectionRenderOutput,
    selection: ?OrderedSelection,
    copy_selection: bool,
    copy_builder: *std.ArrayList(u8),
    copied_any_line: *bool,
    mouse_pos: [2]f32,
    hovered: bool,
    context: *PaletteRenderContext,
    start: [2]f32,
    line_index: usize,
    line: SelectableLine,
    options: RenderOptions,
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
                const selection_col = paletteColor(markdown_selection_fill_rgba);
                for (line.chunks) |chunk| {
                    const chunk_start = @max(columns.start, chunk.start_column);
                    const chunk_end = @min(columns.end, chunk.end_column);
                    if (chunk_start >= chunk_end) continue;

                    const x0 = start[0] + chunk.x + textWidthForColumns(chunk.font_spec, chunk.text, chunk_start - chunk.start_column);
                    const x1 = start[0] + chunk.x + textWidthForColumns(chunk.font_spec, chunk.text, chunk_end - chunk.start_column);
                    if (x1 > x0) {
                        queuePaletteRoundedRect(context, .{ .x = x0, .y = top, .w = x1 - x0, .h = bottom - top }, selection_col, 2.0);
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
        renderPaletteStyledChunk(
            options,
            context,
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
    context: *PaletteRenderContext,
    line_index: usize,
    height: f32,
) void {
    const start = .{ context.cursor.x, context.cursor.y };
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
    advancePaletteCursor(context, height);
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
    context: *PaletteRenderContext,
    global_line_index: *usize,
    block: TextBlockView,
    available_width: f32,
    options: RenderOptions,
) !void {
    const indent = indentWidth(block.indent);
    const start = .{ context.cursor.x + indent, context.cursor.y };
    const width = @max(available_width - indent, 1.0);
    const lines = try buildSelectableTextLines(allocator, block, width, options);
    defer deinitSelectableLines(allocator, lines);

    var height: f32 = 0.0;
    for (lines, 0..) |line, index| {
        renderSelectableLine(
            allocator,
            output,
            selection,
            copy_selection,
            copy_builder,
            copied_any_line,
            mouse_pos,
            hovered,
            context,
            start,
            global_line_index.* + index,
            line,
            options,
        );
        height = @max(height, line.y + line.height);
    }

    advancePaletteCursor(context, height);
    global_line_index.* += lines.len;
}

fn buildSelectableCodeLines(
    allocator: Allocator,
    block: FencedCodeView,
    options: RenderOptions,
) ![]SelectableCodeLine {
    const line_height = codeLineHeight(options);
    var lines = std.ArrayList(SelectableCodeLine).empty;
    errdefer {
        for (lines.items) |line| allocator.free(line.chunks);
        lines.deinit(allocator);
    }

    for (block.lines, 0..) |line, index| {
        var chunks = std.ArrayList(SelectableCodeLineChunk).empty;
        errdefer chunks.deinit(allocator);

        var cursor_x: f32 = 0.0;
        var cursor_column: usize = 0;
        for (line.tokens) |token| {
            if (token.text.len == 0) continue;
            const token_columns = countColumns(token.text);
            const token_width = transcriptTextWidthForRole(codeFontSize(options), .mono, token.text);
            try chunks.append(allocator, .{
                .text = token.text,
                .token_kind = token.kind,
                .font_spec = .{ .size = options.code_font_size },
                .x = cursor_x,
                .width = token_width,
                .start_column = cursor_column,
                .end_column = cursor_column + token_columns,
            });
            cursor_x += token_width;
            cursor_column += token_columns;
        }

        try lines.append(allocator, .{
            .text = line.text,
            .y = line_height * @as(f32, @floatFromInt(index)),
            .height = line_height,
            .total_columns = countColumns(line.text),
            .chunks = try chunks.toOwnedSlice(allocator),
        });
    }

    if (lines.items.len == 0) {
        try lines.append(allocator, .{
            .text = "",
            .y = 0.0,
            .height = line_height,
            .total_columns = 0,
            .chunks = try allocator.alloc(SelectableCodeLineChunk, 0),
        });
    }

    return lines.toOwnedSlice(allocator);
}

fn hoveredColumnForCodeLine(line: SelectableCodeLine, local_x: f32) usize {
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

fn renderSelectableCodeLine(
    allocator: Allocator,
    output: *SelectionRenderOutput,
    selection: ?OrderedSelection,
    copy_selection: bool,
    copy_builder: *std.ArrayList(u8),
    copied_any_line: *bool,
    mouse_pos: [2]f32,
    hovered: bool,
    context: *PaletteRenderContext,
    start: [2]f32,
    line_index: usize,
    line: SelectableCodeLine,
    options: RenderOptions,
    clip: palette.Rect,
) void {
    noteSelectableLineBounds(output, line_index, line.total_columns);

    const top = start[1] + line.y;
    const bottom = top + line.height;
    if (hovered and output.hovered_point == null and mouse_pos[1] >= top and mouse_pos[1] <= bottom) {
        output.hovered_point = .{
            .line_index = line_index,
            .column = hoveredColumnForCodeLine(line, mouse_pos[0] - start[0]),
        };
    }

    if (selection) |ordered| {
        if (selectionColumnsForLine(ordered, line_index, line.total_columns)) |columns| {
            if (columns.start != columns.end) {
                const selection_col = paletteColor(markdown_selection_fill_rgba);
                for (line.chunks) |chunk| {
                    const chunk_start = @max(columns.start, chunk.start_column);
                    const chunk_end = @min(columns.end, chunk.end_column);
                    if (chunk_start >= chunk_end) continue;

                    const x0 = start[0] + chunk.x + textWidthForColumns(chunk.font_spec, chunk.text, chunk_start - chunk.start_column);
                    const x1 = start[0] + chunk.x + textWidthForColumns(chunk.font_spec, chunk.text, chunk_end - chunk.start_column);
                    if (x1 > x0) {
                        queuePaletteRoundedRect(context, .{ .x = x0, .y = top, .w = x1 - x0, .h = bottom - top }, selection_col, 2.0);
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
        queuePaletteRoleText(context, .{
            .x = start[0] + chunk.x,
            .y = top,
            .w = @max(clip.x + clip.w - (start[0] + chunk.x), 1.0),
            .h = codeLineHeight(options),
        }, chunk.text, paletteColor(codeTokenColor(chunk.token_kind)), codeFontSize(options), .mono, clip);
    }
}

fn renderSelectablePaletteCodeBlock(
    allocator: Allocator,
    output: *SelectionRenderOutput,
    selection: ?OrderedSelection,
    copy_selection: bool,
    copy_builder: *std.ArrayList(u8),
    copied_any_line: *bool,
    mouse_pos: [2]f32,
    hovered: bool,
    context: *PaletteRenderContext,
    global_line_index: *usize,
    block: FencedCodeView,
    available_width: f32,
    options: RenderOptions,
) !void {
    const indent = indentWidth(block.indent);
    const start = .{ context.cursor.x + indent, context.cursor.y };
    const width = @max(available_width - indent, minimumCodeBlockWidth(options));
    const line_height = codeLineHeight(options);
    const pad_x = codeBlockPaddingX(options);
    const pad_y = codeBlockPaddingY(options);
    const height = codeBlockHeight(block, line_height, pad_y);
    const rect: palette.Rect = .{ .x = start[0], .y = start[1], .w = width, .h = height };
    queuePaletteRoundedShell(
        context,
        rect,
        paletteColor(colors.rgba(24, 24, 28, 255)),
        paletteColor(colors.rgba(52, 54, 62, 255)),
        codeBlockRounding(options),
    );

    const lines = try buildSelectableCodeLines(allocator, block, options);
    defer deinitSelectableCodeLines(allocator, lines);

    const content_start = .{ start[0] + pad_x, start[1] + pad_y };
    for (lines, 0..) |line, index| {
        renderSelectableCodeLine(
            allocator,
            output,
            selection,
            copy_selection,
            copy_builder,
            copied_any_line,
            mouse_pos,
            hovered,
            context,
            content_start,
            global_line_index.* + index,
            line,
            options,
            rect,
        );
    }

    advancePaletteCursor(context, height);
    global_line_index.* += lines.len;
}

fn renderPaletteStyledChunk(
    options: RenderOptions,
    context: *PaletteRenderContext,
    position: [2]f32,
    text: []const u8,
    block_style: TextStyle,
    inline_style: InlineStyle,
    font_spec: FontSpec,
    width: f32,
    line_height: f32,
) void {
    const color = inlineTextColor(textBlockColor(block_style), inline_style);
    const draw_font_size = fontSizeForSpecWithOptions(font_spec, options);
    const role = markdownFontRole(block_style, inline_style);

    queuePaletteRoleText(context, .{
        .x = position[0],
        .y = position[1],
        .w = width,
        .h = line_height,
    }, text, paletteColor(color), draw_font_size, role, context.clip);

    if (inline_style.link or inline_style.emphasis) {
        const underline_color = if (inline_style.link) paletteColor(colors.rgb(0x7A, 0xCA, 0xFF)) else paletteColor(color);
        queuePaletteRect(context, .{
            .x = position[0],
            .y = position[1] + line_height - 2.0,
            .w = width,
            .h = if (inline_style.link) 1.5 else 1.0,
        }, underline_color);
    }
}

fn renderPaletteCodeLine(context: *PaletteRenderContext, line: CodeLineView, layout: CodeLineLayout, options: RenderOptions, clip: palette.Rect) void {
    var cursor_x = layout.x;
    const code_fs = codeFontSize(options);
    for (line.tokens) |token| {
        if (token.text.len == 0) continue;
        if (cursor_x >= layout.max_x) break;

        const width = transcriptTextWidthForRole(code_fs, .mono, token.text);
        queuePaletteRoleText(context, .{
            .x = cursor_x,
            .y = layout.y,
            .w = @min(width, @max(layout.max_x - cursor_x, 1.0)),
            .h = codeLineHeight(options),
        }, token.text, paletteColor(codeTokenColor(token.kind)), codeFontSize(options), .mono, clip);
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
    return codeBlockHeight(block, codeLineHeight(options), codeBlockPaddingY(options));
}

fn measureThematicBreakHeight(rule: ThematicBreakView) f32 {
    _ = rule;
    return thematicBreakHeight(.{});
}

// Monotonic descending heading scale relative to the body font size. The
// previous scale was buggy: H3 (1.20) exceeded H2 (1.08), and H4–H6 all
// ended up *larger* than H3 via the `@max(base*X, heading*Y)` fallback. The
// new scale is a clean h1 > h2 > h3 > h4 > h5 > h6 > body curve with enough
// separation between adjacent levels to read as real hierarchy.
fn headingScale(style: TextStyle) f32 {
    return switch (style) {
        .heading_1 => 1.50,
        .heading_2 => 1.30,
        .heading_3 => 1.15,
        .heading_4 => 1.05,
        .heading_5 => 0.98,
        .heading_6 => 0.92,
        else => 1.0,
    };
}

fn textBlockFontSpec(style: TextStyle, options: RenderOptions) FontSpec {
    return switch (style) {
        .paragraph, .quote => .{},
        else => .{ .size = options.base_font_size * headingScale(style) },
    };
}

fn textBlockFontSpecWithOptions(style: TextStyle, options: RenderOptions) FontSpec {
    if (style == .paragraph or style == .quote) return .{};
    const reference = options.heading_font_size orelse options.base_font_size;
    return .{ .size = reference * headingScale(style) };
}

fn inlineFontSpec(block_style: TextStyle, inline_style: InlineStyle, options: RenderOptions) FontSpec {
    const base = textBlockFontSpecWithOptions(block_style, options);
    if (inline_style.code) {
        return .{
            .size = options.code_font_size,
        };
    }
    if (inline_style.strong and inline_style.emphasis) {
        _ = options.bold_italic_font orelse options.bold_font orelse options.italic_font;
        return .{ .size = base.size };
    }
    if (inline_style.strong) {
        _ = options.bold_font;
        return .{ .size = base.size };
    }
    if (inline_style.emphasis) {
        _ = options.italic_font;
        return .{ .size = base.size };
    }
    return base;
}

fn lineHeightForSpec(spec: FontSpec, options: RenderOptions) f32 {
    return (options.line_height orelse fontSizeForSpecWithOptions(spec, options) * 1.25);
}

fn textWidthForSpec(spec: FontSpec, text: []const u8) f32 {
    return @as(f32, @floatFromInt(countColumns(text))) * glyphWidthForSpec(spec, .{});
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

/// Map a markdown block + inline style to the Palette FontRole that should
/// render it. Chat headings stay on the default UI face (CalSans) so they read
/// as part of the same design language as the surrounding chrome. Body prose
/// drops to NotoSans-Regular; strong/italic emphasis selects the matching Noto
/// weight; inline code switches to mono.
fn markdownFontRole(block_style: TextStyle, inline_style: InlineStyle) palette.FontRole {
    if (inline_style.code) return .mono;
    switch (block_style) {
        .heading_1, .heading_2, .heading_3, .heading_4, .heading_5, .heading_6 => return .ui,
        else => {},
    }
    if (inline_style.strong and inline_style.emphasis) return .prose_bold_italic;
    if (inline_style.strong) return .prose_bold;
    if (inline_style.emphasis) return .prose_italic;
    return .prose;
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
    return @as(f32, @floatFromInt(level)) * 30.0;
}

fn blankBlockHeight(options: RenderOptions) f32 {
    return @max(defaultLineHeight(options) * 0.65, 1.0);
}

fn blockGap(options: RenderOptions) f32 {
    // Paragraph↔heading, paragraph↔list-loose, paragraph↔code-fence transitions.
    // Tight list items still use compactBlockGap; bumping this only affects
    // breathing room around real section breaks.
    return @max(defaultLineHeight(options) * 0.95, 1.0);
}

fn compactBlockGap(options: RenderOptions) f32 {
    return @max(defaultLineHeight(options) * 0.2, 2.0);
}

fn thematicBreakHeight(options: RenderOptions) f32 {
    return @max(defaultLineHeight(options) * 0.7, 10.0);
}

fn minimumCodeBlockWidth(options: RenderOptions) f32 {
    return @max(defaultLineHeight(options) * 10.0, 240.0);
}

fn codeBlockPaddingX(options: RenderOptions) f32 {
    return @max(defaultLineHeight(options) * 0.75, 10.0);
}

fn codeBlockPaddingY(options: RenderOptions) f32 {
    return @max(defaultLineHeight(options) * 0.5, 8.0);
}

fn codeBlockRounding(options: RenderOptions) f32 {
    return @max(defaultLineHeight(options) * 0.42, 10.0);
}

fn codeBlockHeight(block: FencedCodeView, line_height: f32, pad_y: f32) f32 {
    return pad_y * 2.0 + line_height * @as(f32, @floatFromInt(@max(block.lines.len, 1)));
}

fn advancePaletteCursor(context: *PaletteRenderContext, height: f32) void {
    context.cursor.y += height;
    context.cursor.h = @max(context.cursor.h, height);
}

fn queuePaletteRect(context: *PaletteRenderContext, rect: palette.Rect, color: palette.Color) void {
    context.batch.rect(context.allocator, rect, color) catch {};
}

fn queuePaletteRoundedRect(context: *PaletteRenderContext, rect: palette.Rect, color: palette.Color, radius: f32) void {
    context.batch.roundedRect(context.allocator, rect, color, radius) catch {};
}

/// Rounded frame without `rectBorder` (axis-aligned quads with sharp corners on top of rounded fills).
fn queuePaletteRoundedShell(
    context: *PaletteRenderContext,
    bounds: palette.Rect,
    fill_color: palette.Color,
    border_color: palette.Color,
    radius: f32,
) void {
    const inset = @max(theme.scaledUi(1.0), 1.0);
    const inner_radius = @max(radius - inset, 0.0);
    if (context.clip) |clip| {
        context.batch.roundedRectClipped(context.allocator, bounds, border_color, radius, clip) catch {};
        if (bounds.w > inset * 2.0 and bounds.h > inset * 2.0) {
            context.batch.roundedRectClipped(context.allocator, .{
                .x = bounds.x + inset,
                .y = bounds.y + inset,
                .w = bounds.w - inset * 2.0,
                .h = bounds.h - inset * 2.0,
            }, fill_color, inner_radius, clip) catch {};
        }
    } else {
        context.batch.roundedRect(context.allocator, bounds, border_color, radius) catch {};
        if (bounds.w > inset * 2.0 and bounds.h > inset * 2.0) {
            context.batch.roundedRect(context.allocator, .{
                .x = bounds.x + inset,
                .y = bounds.y + inset,
                .w = bounds.w - inset * 2.0,
                .h = bounds.h - inset * 2.0,
            }, fill_color, inner_radius) catch {};
        }
    }
}

fn queuePaletteText(context: *PaletteRenderContext, rect: palette.Rect, value: []const u8, color: palette.Color, font_size: f32, clip: ?palette.Rect) void {
    const stable = stablePaletteText(context, value) catch return;
    context.batch.fixedText(
        context.allocator,
        rect,
        stable,
        color,
        font_size,
        clip,
        .{},
        font_size * 0.55,
        font_size * 1.25,
        false,
    ) catch {};
}

fn queuePaletteRoleText(
    context: *PaletteRenderContext,
    rect: palette.Rect,
    value: []const u8,
    color: palette.Color,
    font_size: f32,
    font_role: palette.FontRole,
    clip: ?palette.Rect,
) void {
    const stable = stablePaletteText(context, value) catch return;
    context.batch.roleText(
        context.allocator,
        rect,
        stable,
        color,
        font_size,
        font_role,
        null,
        clip,
    ) catch {};
}

fn stablePaletteText(context: *PaletteRenderContext, value: []const u8) ![]const u8 {
    const start = context.frame_text.items.len;
    try context.frame_text.appendSlice(context.allocator, value);
    return context.frame_text.items[start .. start + value.len];
}

fn paletteColor(value: [4]f32) palette.Color {
    return .{ .r = value[0], .g = value[1], .b = value[2], .a = value[3] };
}

fn defaultLineHeight(options: RenderOptions) f32 {
    return options.line_height orelse options.base_font_size * 1.25;
}

fn codeFontSize(options: RenderOptions) f32 {
    return options.code_font_size orelse options.base_font_size * 0.92;
}

fn codeLineHeight(options: RenderOptions) f32 {
    return (options.code_font_size orelse options.base_font_size * 0.92) * 1.25;
}

fn fontSizeForSpecWithOptions(spec: FontSpec, options: RenderOptions) f32 {
    return spec.size orelse options.base_font_size;
}

fn glyphWidthForSpec(spec: FontSpec, options: RenderOptions) f32 {
    return fontSizeForSpecWithOptions(spec, options) * 0.55;
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

test "transcript layout width tracks GL text metrics for ASCII" {
    const w = transcriptTextWidth(16.0, "Hello");
    try std.testing.expect(w > 10.0 and w < 90.0);
}

test "double click selection expands to a code word on raw lines" {
    const allocator = std.testing.allocator;
    const line = "const answer = 42;";
    const selection = selectionRangeForRawLine(allocator, 3, line, countColumns(line), 7, 2).?;

    try std.testing.expectEqual(@as(usize, 3), selection.anchor.line_index);
    try std.testing.expectEqualStrings("answer", sliceForColumns(line, selection.anchor.column, selection.focus.column));
}

test "triple click selection expands to the full raw line" {
    const allocator = std.testing.allocator;
    const line = "hello world";
    const selection = selectionRangeForRawLine(allocator, 2, line, countColumns(line), 4, 3).?;

    try std.testing.expectEqual(@as(usize, 0), selection.anchor.column);
    try std.testing.expectEqual(@as(usize, countColumns(line)), selection.focus.column);
}
