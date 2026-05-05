//! SDL visual lab for the Powder composer prompt visual model.

const std = @import("std");
const builtin = @import("builtin");
const powder = @import("powder");
const sdl = powder.sdl;

const CAL_SANS_PATH = "../desktop/src/assets/fonts/CalSans-Regular.ttf";
const LABEL_FONT_SIZE: f32 = 15.0;

const Composer = powder.composerPrompt(.{
    .placeholder = "Ask anything, or use / to show available commands",
    .model_icon = "O",
    .model_label = "GPT-5.5",
    .reasoning_label = "Low",
    .fast_icon = "~",
    .fast_label = "Fast",
    .access_icon = "L",
    .access_label = "Full access",
    .send_icon = "^",
});

pub export fn powder_composer_prompt_lab_main() c_int {
    run() catch |err| {
        std.debug.print("powder composer_prompt_lab failed: {s}\n", .{@errorName(err)});
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

    const window = try sdl.Window.create("Powder Composer Prompt Lab", 900, 560, labWindowFlags());
    defer sdl.Window.destroy(window);
    const renderer = try sdl.Renderer.create(window);
    defer sdl.Renderer.destroy(renderer);
    try sdl.setRenderDrawBlendMode(renderer, .blend);
    const font = try sdl.ttfOpenFont(CAL_SANS_PATH, LABEL_FONT_SIZE);
    defer sdl.ttfCloseFont(font);

    sdl.startTextInput(window) catch {};
    defer sdl.stopTextInput(window) catch {};

    var composer = Composer.init();
    var prompt_text: std.ArrayList(u8) = .empty;
    defer prompt_text.deinit(allocator);
    var batch: powder.RenderBatch = .{};
    defer batch.deinit(allocator);

    var running = true;
    var clicks: ClickCounts = .{};
    var frame_index: usize = 0;

    std.debug.print("powder composer_prompt_lab started; close the window or press Ctrl+C to exit.\n", .{});
    defer std.debug.print("powder composer_prompt_lab stopped.\n", .{});

    while (running) : (frame_index += 1) {
        const composer_rect = try layoutComposer(window, &composer);

        var event: sdl.Event = undefined;
        while (sdl.pollEvent(&event)) {
            switch (event.type) {
                .quit, .window_close_requested => running = false,
                .text_input => {
                    try prompt_text.appendSlice(allocator, std.mem.span(event.text.text));
                    composer.setText(prompt_text.items);
                },
                .key_down => {
                    if (event.key.key == .backspace and prompt_text.items.len > 0) {
                        _ = prompt_text.pop();
                        composer.setText(prompt_text.items);
                    } else if (event.key.key == .escape) {
                        running = false;
                    }
                },
                .mouse_motion => _ = composer.updateHover(.{ .x = event.motion.x, .y = event.motion.y }),
                .mouse_button_down => {
                    const point: powder.draw.Vec2 = .{ .x = event.button.x, .y = event.button.y };
                    if (composer.hitTest(point)) |part| {
                        clicks.add(part);
                        composer.setHoveredPart(part);
                    } else {
                        composer.setHoveredPart(null);
                    }
                },
                else => {},
            }
        }

        batch.clear();
        try renderBackground(allocator, &batch, window, composer_rect);
        try composer.render(allocator, &batch);

        const counts = countBatch(batch);
        try sdl.setRenderDrawColor(renderer, 9, 12, 14, 255);
        try sdl.renderClear(renderer);
        var presenter = powder.renderer.sdlFontRenderer(renderer, font, LABEL_FONT_SIZE);
        try presenter.renderBatch(&batch);
        try drawFrameLabels(&presenter, composer_rect, prompt_text.items.len, clicks, counts, frame_index);
        sdl.renderPresent(renderer);
        updateWindowTitle(window, prompt_text.items.len, clicks, counts, frame_index);
        sdl.delay(16);
    }
}

fn layoutComposer(window: *sdl.Window, composer: *Composer) !powder.Rect {
    const size = try window.size();
    const window_rect: powder.Rect = .{ .w = @floatFromInt(size.w), .h = @floatFromInt(size.h) };
    const width = @min(@max(window_rect.w - 80.0, 360.0), 760.0);
    const height: f32 = 176.0;
    const rect: powder.Rect = .{
        .x = (window_rect.w - width) * 0.5,
        .y = @max(window_rect.h - height - 72.0, 96.0),
        .w = width,
        .h = height,
    };
    composer.setBounds(rect);
    return rect;
}

fn renderBackground(allocator: std.mem.Allocator, batch: *powder.RenderBatch, window: *sdl.Window, composer_rect: powder.Rect) !void {
    const size = try window.size();
    const window_rect: powder.Rect = .{ .w = @floatFromInt(size.w), .h = @floatFromInt(size.h) };
    try batch.rect(allocator, window_rect, .{ .r = 0.03, .g = 0.05, .b = 0.05, .a = 1.0 });
    try batch.rect(allocator, .{ .x = 0, .y = window_rect.h - 260.0, .w = window_rect.w, .h = 260.0 }, .{ .r = 0.06, .g = 0.08, .b = 0.08, .a = 1.0 });
    try batch.panel(allocator, .{ .x = composer_rect.x - 16, .y = composer_rect.y - 16, .w = composer_rect.w + 32, .h = composer_rect.h + 32 }, .{ .r = 0.05, .g = 0.07, .b = 0.07, .a = 1.0 }, .{ .r = 0.16, .g = 0.22, .b = 0.24, .a = 1.0 }, 18, 1);
}

const Counts = struct {
    commands: usize = 0,
    text_commands: usize = 0,
    icon_runs: usize = 0,
    separators: usize = 0,
};

const ClickCounts = struct {
    model: usize = 0,
    reasoning: usize = 0,
    fast: usize = 0,
    access: usize = 0,
    send: usize = 0,

    fn add(self: *ClickCounts, part: powder.ComposerPromptPart) void {
        switch (part) {
            .model => self.model += 1,
            .reasoning => self.reasoning += 1,
            .fast => self.fast += 1,
            .access => self.access += 1,
            .send => self.send += 1,
        }
    }
};

fn countBatch(batch: powder.RenderBatch) Counts {
    var counts: Counts = .{ .commands = batch.commands.items.len };
    for (batch.commands.items) |command| {
        if (command.kind == .text) {
            counts.text_commands += 1;
            for (command.text_runs) |text_run| {
                if (text_run.font_role == .icon) counts.icon_runs += 1;
            }
        }
        if (command.kind == .rect and command.rect.w <= 1.0 and command.rect.h > 8.0) counts.separators += 1;
    }
    return counts;
}

fn drawFrameLabels(presenter: *powder.renderer.SdlFontRenderer, composer_rect: powder.Rect, prompt_bytes: usize, clicks: ClickCounts, counts: Counts, frame_index: usize) !void {
    try label(presenter, composer_rect.x, 42, "Powder Composer Prompt Lab", .{ 235, 241, 248, 255 });
    try label(presenter, composer_rect.x, 66, "Type prompt text. Hover/click toolbar controls and send. Resize the window.", .{ 166, 180, 198, 255 });

    var status_buf: [256]u8 = undefined;
    const status = try std.fmt.bufPrint(&status_buf, "prompt={d} model={d} reasoning={d} fast={d} access={d} send={d} commands={d} text={d} icons={d} separators={d} frame={d}", .{
        prompt_bytes,
        clicks.model,
        clicks.reasoning,
        clicks.fast,
        clicks.access,
        clicks.send,
        counts.commands,
        counts.text_commands,
        counts.icon_runs,
        counts.separators,
        frame_index,
    });
    try label(presenter, composer_rect.x, composer_rect.y + composer_rect.h + 30, status, .{ 214, 226, 242, 255 });
}

fn label(presenter: *powder.renderer.SdlFontRenderer, x: f32, y: f32, text: []const u8, color: [4]u8) !void {
    try presenter.renderLine(x, y, text, colorFromBytes(color), LABEL_FONT_SIZE);
}

fn colorFromBytes(color: [4]u8) powder.Color {
    return .{
        .r = @as(f32, @floatFromInt(color[0])) / 255.0,
        .g = @as(f32, @floatFromInt(color[1])) / 255.0,
        .b = @as(f32, @floatFromInt(color[2])) / 255.0,
        .a = @as(f32, @floatFromInt(color[3])) / 255.0,
    };
}

fn updateWindowTitle(window: *sdl.Window, prompt_bytes: usize, clicks: ClickCounts, counts: Counts, frame_index: usize) void {
    var title_buffer: [256:0]u8 = undefined;
    @memset(&title_buffer, 0);
    const title = std.fmt.bufPrintZ(
        &title_buffer,
        "Powder Composer Prompt Lab | prompt={d} model={d} reasoning={d} fast={d} access={d} send={d} commands={d} frame={d}",
        .{ prompt_bytes, clicks.model, clicks.reasoning, clicks.fast, clicks.access, clicks.send, counts.commands, frame_index },
    ) catch return;
    sdl.Window.setTitle(window, title);
}

fn labWindowFlags() sdl.Window.Flags {
    var flags: sdl.Window.Flags = .{ .resizable = true };
    switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos => flags.metal = true,
        else => flags.vulkan = true,
    }
    return flags;
}
