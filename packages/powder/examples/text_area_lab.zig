//! SDL event-loop lab for the retained Text and TextArea components.

const std = @import("std");
const powder = @import("powder");
const sdl = powder.sdl;

const Title = powder.text(.{
    .x = 24,
    .y = 20,
    .width = 560,
    .height = 28,
    .font_size = 18,
    .color = .{ .r = 0.82, .g = 0.88, .b = 0.96, .a = 1.0 },
});

const Composer = powder.textArea(.{
    .x = 24,
    .y = 64,
    .width = 720,
    .height = 220,
    .padding_x = 12,
    .padding_y = 12,
    .font_size = 17,
    .glyph_width = COMPOSER_DEBUG_CHAR_WIDTH,
    .line_height = COMPOSER_LINE_HEIGHT,
    .placeholder_text = "Ask Powder to compose something...",
    .submit_on_enter = true,
});

const COMPOSER_TEXT_X: f32 = 36;
const COMPOSER_TEXT_Y: f32 = 76;
const COMPOSER_DEBUG_CHAR_WIDTH: f32 = 8;
const COMPOSER_LINE_HEIGHT: f32 = 21.25;
const DEBUG_TEXT_WRAP_COLUMNS: usize = 87;

pub export fn powder_text_area_lab_main() c_int {
    run() catch |err| {
        std.debug.print("powder text_area_lab failed: {s}\n", .{@errorName(err)});
        return 1;
    };
    return 0;
}

pub fn run() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try sdl.init(.{ .video = true, .events = true });
    defer sdl.quit();

    const window = try sdl.Window.create("Powder Text Area Lab", 800, 360, .{ .resizable = true, .vulkan = true });
    defer sdl.Window.destroy(window);
    const renderer = try sdl.Renderer.create(window);
    defer sdl.Renderer.destroy(renderer);
    try sdl.setRenderDrawBlendMode(renderer, .blend);

    sdl.startTextInput(window) catch {};
    defer sdl.stopTextInput(window) catch {};

    var title = try Title.init(allocator, "Powder TextArea");
    defer title.deinit(allocator);

    var composer = try Composer.init(allocator,
        \\Type here. Shift+Enter inserts a newline.
        \\Enter marks the component as submitted.
    );
    defer composer.deinit(allocator);
    composer.setCallbacks(.{
        .on_event = handleComposerEvent,
        .on_key = handleComposerKey,
        .set_clipboard = handleSetClipboard,
        .get_clipboard = handleGetClipboard,
    });

    var batch: powder.RenderBatch = .{};
    defer batch.deinit(allocator);

    std.debug.print("powder text_area_lab started; close the window or press Ctrl+C to exit.\n", .{});
    defer std.debug.print("powder text_area_lab stopped.\n", .{});

    var running = true;
    var frame_index: usize = 0;
    while (running) : (frame_index += 1) {
        composer.tick(16);
        var event: sdl.Event = undefined;
        while (sdl.pollEvent(&event)) {
            switch (event.type) {
                .quit => {
                    std.debug.print("powder text_area_lab received SDL quit.\n", .{});
                    running = false;
                },
                .window_close_requested => {
                    std.debug.print("powder text_area_lab received window close.\n", .{});
                    running = false;
                },
                else => {
                    _ = try composer.update(allocator, &event);
                },
            }
        }

        batch.clear();
        try title.render(allocator, &batch);
        try composer.render(allocator, &batch);
        try drawBatch(renderer, batch.commands.items);
        try drawDebugText(allocator, renderer, title.text(), composer);
        updateWindowTitle(window, composer, batch.commands.items.len, frame_index);

        sdl.delay(16);
    }
}

fn drawBatch(renderer: *sdl.Renderer, commands: []const powder.draw.Command) !void {
    try sdl.setRenderDrawColor(renderer, 14, 16, 20, 255);
    try sdl.renderClear(renderer);

    for (commands) |command| {
        const color = commandColor(command);
        try sdl.setRenderDrawColor(renderer, color[0], color[1], color[2], color[3]);
        if (command.kind == .cursor or command.kind == .selection or command.kind == .glyph) {
            try sdl.setRenderClipRect(renderer, textClipRect());
        }
        try sdl.renderFillRect(renderer, .{
            .x = command.rect.x,
            .y = command.rect.y,
            .w = command.rect.w,
            .h = command.rect.h,
        });
        if (command.kind == .cursor or command.kind == .selection or command.kind == .glyph) {
            try sdl.setRenderClipRect(renderer, null);
        }
    }
}

fn commandColor(command: powder.draw.Command) [4]u8 {
    if (command.kind == .glyph) {
        return .{ 0, 0, 0, 0 };
    }
    return .{
        floatChannel(command.color.r),
        floatChannel(command.color.g),
        floatChannel(command.color.b),
        floatChannel(command.color.a),
    };
}

fn floatChannel(value: f32) u8 {
    const clamped = @min(@max(value, 0.0), 1.0);
    return @intFromFloat(clamped * 255.0);
}

fn drawDebugText(allocator: std.mem.Allocator, renderer: *sdl.Renderer, title: []const u8, composer: Composer) !void {
    try sdl.setRenderDrawColor(renderer, 214, 226, 242, 255);
    try drawDebugLine(allocator, renderer, 40, 28, title);

    try sdl.setRenderDrawColor(renderer, 236, 241, 248, 255);
    try sdl.setRenderClipRect(renderer, textClipRect());

    const body = composer.text();
    if (composer.placeholderVisible()) {
        try sdl.setRenderDrawColor(renderer, 128, 143, 166, 194);
        try drawDebugLine(allocator, renderer, COMPOSER_TEXT_X, COMPOSER_TEXT_Y, composer.placeholder());
        try sdl.setRenderClipRect(renderer, null);
        sdl.renderPresent(renderer);
        return;
    }

    var y: f32 = COMPOSER_TEXT_Y - composer.scrollY();
    var start: usize = 0;
    while (start <= body.len) {
        const end = std.mem.indexOfScalarPos(u8, body, start, '\n') orelse body.len;
        y = try drawWrappedDebugLine(allocator, renderer, COMPOSER_TEXT_X, y, body[start..end]);
        if (end == body.len) break;
        start = end + 1;
    }

    try sdl.setRenderClipRect(renderer, null);
    sdl.renderPresent(renderer);
}

fn textClipRect() sdl.Rect {
    return .{
        .x = @intFromFloat(COMPOSER_TEXT_X),
        .y = @intFromFloat(COMPOSER_TEXT_Y),
        .w = @intFromFloat(720 - 24),
        .h = @intFromFloat(220 - 24),
    };
}

fn drawWrappedDebugLine(allocator: std.mem.Allocator, renderer: *sdl.Renderer, x: f32, y_start: f32, text: []const u8) !f32 {
    var y = y_start;
    var start: usize = 0;
    while (start < text.len) {
        const end = wrappedDebugLineEnd(text, start);
        try drawDebugLine(allocator, renderer, x, y, text[start..end]);
        y += COMPOSER_LINE_HEIGHT;
        start = end;
    }
    if (text.len == 0) {
        try drawDebugLine(allocator, renderer, x, y, "");
        y += COMPOSER_LINE_HEIGHT;
    }
    return y;
}

fn wrappedDebugLineEnd(text: []const u8, start: usize) usize {
    var end = start;
    var col: usize = 0;
    while (end < text.len and col < DEBUG_TEXT_WRAP_COLUMNS) : (col += 1) {
        end = nextUtf8Offset(text, end);
    }
    return @max(end, start + 1);
}

fn nextUtf8Offset(text: []const u8, offset: usize) usize {
    if (offset >= text.len) return text.len;
    const len = std.unicode.utf8ByteSequenceLength(text[offset]) catch 1;
    return @min(offset + len, text.len);
}

fn drawDebugLine(allocator: std.mem.Allocator, renderer: *sdl.Renderer, x: f32, y: f32, text: []const u8) !void {
    const z_text = try allocator.dupeZ(u8, if (text.len == 0) " " else text);
    defer allocator.free(z_text);
    try sdl.renderDebugText(renderer, x, y, z_text);
}

fn handleComposerEvent(_: ?*anyopaque, event: powder.TextAreaEvent) void {
    switch (event) {
        .submitted => |text| std.debug.print("text_area_lab submit: {d} bytes\n", .{text.len}),
        else => {},
    }
}

fn handleComposerKey(_: ?*anyopaque, key: powder.TextAreaKey) powder.TextAreaAction {
    if (key.code == .enter and key.shift) return .insert_newline;
    if (key.code == .enter) return .submit;
    return .default;
}

fn handleSetClipboard(_: ?*anyopaque, text: []const u8) bool {
    const z_text = std.heap.page_allocator.dupeZ(u8, text) catch return false;
    defer std.heap.page_allocator.free(z_text);
    sdl.setClipboardText(z_text) catch return false;
    return true;
}

fn handleGetClipboard(_: ?*anyopaque, allocator: std.mem.Allocator) ?[]u8 {
    return sdl.getClipboardText(allocator) catch null;
}

fn updateWindowTitle(window: *sdl.Window, composer: Composer, command_count: usize, frame_index: usize) void {
    var title_buffer: [256:0]u8 = undefined;
    @memset(&title_buffer, 0);
    const selection_len = if (composer.selection()) |range| range.end - range.start else 0;
    const marker = if (composer.submitted) " submitted" else "";
    const title = std.fmt.bufPrintZ(
        &title_buffer,
        "Powder TextArea Lab | bytes={d} cursor={d} selection={d} commands={d} frame={d}{s}",
        .{ composer.text().len, composer.cursor, selection_len, command_count, frame_index, marker },
    ) catch return;
    sdl.Window.setTitle(window, title);
}
