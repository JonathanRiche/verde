//! SDL event-loop lab for the retained Text and TextArea components.

const std = @import("std");
const builtin = @import("builtin");
const powder = @import("powder");
const sdl = powder.sdl;

const CAL_SANS_PATH = "../desktop/src/assets/fonts/CalSans-Regular.ttf";

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
    .corner_radius = 12,
    .border_width = 1.5,
    .placeholder_text = "Ask Powder to compose something...",
    .submit_on_enter = true,
});

const COMPOSER_DEBUG_CHAR_WIDTH: f32 = 8;
const COMPOSER_LINE_HEIGHT: f32 = 21.25;

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
    try sdl.ttfInit();
    defer sdl.ttfQuit();

    const window = try sdl.Window.create("Powder Text Area Lab", 800, 360, labWindowFlags());
    defer sdl.Window.destroy(window);
    const renderer = try sdl.Renderer.create(window);
    defer sdl.Renderer.destroy(renderer);
    try sdl.setRenderDrawBlendMode(renderer, .blend);
    const font = try sdl.ttfOpenFont(CAL_SANS_PATH, 16.0);
    defer sdl.ttfCloseFont(font);

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
        try sdl.setRenderDrawColor(renderer, 14, 16, 20, 255);
        try sdl.renderClear(renderer);
        var presenter = powder.renderer.sdlFontRenderer(renderer, font, 16.0);
        try presenter.renderBatch(&batch);
        sdl.renderPresent(renderer);
        updateWindowTitle(window, composer, batch.commands.items.len, frame_index);

        sdl.delay(16);
    }
}

fn labWindowFlags() sdl.Window.Flags {
    var flags: sdl.Window.Flags = .{ .resizable = true };
    switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos => flags.metal = true,
        else => flags.vulkan = true,
    }
    return flags;
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
