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
    .submit_on_enter = true,
});

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

    sdl.startTextInput(window) catch {};
    defer sdl.stopTextInput(window) catch {};

    var title = try Title.init(allocator, "Powder TextArea");
    defer title.deinit(allocator);

    var composer = try Composer.init(allocator,
        \\Type here. Shift+Enter inserts a newline.
        \\Enter marks the component as submitted.
    );
    defer composer.deinit(allocator);

    var batch: powder.RenderBatch = .{};
    defer batch.deinit(allocator);

    std.debug.print("powder text_area_lab started; close the window or press Ctrl+C to exit.\n", .{});
    defer std.debug.print("powder text_area_lab stopped.\n", .{});

    var running = true;
    var frame_index: usize = 0;
    while (running) : (frame_index += 1) {
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
        try sdl.renderFillRect(renderer, .{
            .x = command.rect.x,
            .y = command.rect.y,
            .w = command.rect.w,
            .h = command.rect.h,
        });
    }

    sdl.renderPresent(renderer);
}

fn commandColor(command: powder.draw.Command) [4]u8 {
    if (command.kind == .glyph) {
        return .{ 190, 206, 230, 255 };
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
