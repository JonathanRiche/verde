//! SDL visual lab for Powder runtime flex and grid layout.

const std = @import("std");
const builtin = @import("builtin");
const powder = @import("powder");
const sdl = powder.sdl;
const stb_image = @import("stb_image.zig");

const CAL_SANS_PATH = "../desktop/src/assets/fonts/CalSans-Regular.ttf";
const PREVIEW_IMAGE_PATH = "../desktop/src/assets/verde_logo.png";
const LABEL_FONT_SIZE: f32 = 15.0;

const Provider = powder.select(.{ .height = 32, .menu_height = 108, .item_count = 4, .item_label = providerLabel });
const Model = powder.select(.{ .height = 32, .menu_height = 108, .item_count = 4, .item_label = modelLabel });
const Reasoning = powder.select(.{ .height = 32, .menu_height = 108, .item_count = 4, .item_label = reasoningLabel });
const Preview = powder.image(.{ .width = 48, .height = 38, .source_width = 105, .source_height = 122, .fit = .contain, .tint = powder.Color.white });
const Prompt = powder.textInput(.{ .height = 38, .placeholder_text = "Resize the window, type here, and click controls" });
const Send = powder.button(.{ .label = "Send" });
const Stop = powder.button(.{ .label = "Stop" });
const Fast = powder.toggle(.{ .label = "Fast" });
const Access = powder.checkbox(.{ .label = "Tools" });
const ChipA = powder.button(.{ .label = "Margin" });
const ChipB = powder.button(.{ .label = "Padding" });
const ChipC = powder.button(.{ .label = "Wrap" });
const ChipD = powder.button(.{ .label = "Grow" });
const ChipE = powder.button(.{ .label = "Grid" });
const ChipF = powder.button(.{ .label = "Span" });

const Controls = struct {
    provider: Provider,
    model: Model,
    reasoning: Reasoning,
    preview: Preview,
    prompt: Prompt,
    send: Send,
    stop: Stop,
    fast: Fast,
    access: Access,
    chip_a: ChipA,
    chip_b: ChipB,
    chip_c: ChipC,
    chip_d: ChipD,
    chip_e: ChipE,
    chip_f: ChipF,
};

const LayoutRects = struct {
    shell: powder.Rect,
    content: powder.Rect,
    grid_panel: powder.Rect,
    prompt_panel: powder.Rect,
    wrap_panel: powder.Rect,
    grid_content: powder.Rect,
    prompt_content: powder.Rect,
    wrap_content: powder.Rect,
};

const State = struct {
    send_clicks: usize = 0,
    stop_clicks: usize = 0,
    chip_clicks: usize = 0,
};

pub export fn powder_layout_lab_main() c_int {
    run() catch |err| {
        std.debug.print("powder layout_lab failed: {s}\n", .{@errorName(err)});
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

    const window = try sdl.Window.create("Powder Layout Lab", 920, 520, labWindowFlags());
    defer sdl.Window.destroy(window);
    const renderer = try sdl.Renderer.create(window);
    defer sdl.Renderer.destroy(renderer);
    try sdl.setRenderDrawBlendMode(renderer, .blend);
    const font = try sdl.ttfOpenFont(CAL_SANS_PATH, LABEL_FONT_SIZE);
    defer sdl.ttfCloseFont(font);
    const preview_image = try stb_image.load(PREVIEW_IMAGE_PATH);
    defer preview_image.deinit();
    const preview_w: f32 = @floatFromInt(preview_image.width);
    const preview_h: f32 = @floatFromInt(preview_image.height);
    const preview_surface = try sdl.createSurfaceFrom(preview_image.width, preview_image.height, .rgba8888, preview_image.pixels, preview_image.width * 4);
    defer sdl.destroySurface(preview_surface);
    const preview_texture = try sdl.createTextureFromSurface(renderer, preview_surface);
    defer sdl.destroyTexture(preview_texture);
    var texture_store: TextureStore = .{ .texture = preview_texture, .width = preview_w, .height = preview_h };

    sdl.startTextInput(window) catch {};
    defer sdl.stopTextInput(window) catch {};

    var state: State = .{};
    var controls: Controls = .{
        .provider = Provider.initFromConfig(),
        .model = Model.initFromConfig(),
        .reasoning = Reasoning.initFromConfig(),
        .preview = Preview.initWithSize(powder.TextureId.init(1), preview_w, preview_h),
        .prompt = try Prompt.init(allocator, ""),
        .send = Send.init(),
        .stop = Stop.init(),
        .fast = Fast.init(false),
        .access = Access.init(false),
        .chip_a = ChipA.init(),
        .chip_b = ChipB.init(),
        .chip_c = ChipC.init(),
        .chip_d = ChipD.init(),
        .chip_e = ChipE.init(),
        .chip_f = ChipF.init(),
    };
    defer controls.prompt.deinit(allocator);
    controls.send.setCallbacks(.{ .context = &state, .on_event = handleSend });
    controls.stop.setCallbacks(.{ .context = &state, .on_event = handleStop });
    controls.chip_a.setCallbacks(.{ .context = &state, .on_event = handleChip });
    controls.chip_b.setCallbacks(.{ .context = &state, .on_event = handleChip });
    controls.chip_c.setCallbacks(.{ .context = &state, .on_event = handleChip });
    controls.chip_d.setCallbacks(.{ .context = &state, .on_event = handleChip });
    controls.chip_e.setCallbacks(.{ .context = &state, .on_event = handleChip });
    controls.chip_f.setCallbacks(.{ .context = &state, .on_event = handleChip });

    var batch: powder.RenderBatch = .{};
    defer batch.deinit(allocator);

    std.debug.print("powder layout_lab started; close the window or press Ctrl+C to exit.\n", .{});
    defer std.debug.print("powder layout_lab stopped.\n", .{});

    var running = true;
    var frame_index: usize = 0;
    while (running) : (frame_index += 1) {
        const layout_rects = try layoutControls(allocator, window, &controls);
        controls.prompt.tick(16);

        var event: sdl.Event = undefined;
        while (sdl.pollEvent(&event)) {
            switch (event.type) {
                .quit, .window_close_requested => running = false,
                else => try routeEvent(allocator, &event, &controls),
            }
        }

        batch.clear();
        try renderLabChrome(allocator, &batch, layout_rects);
        try renderControls(allocator, &batch, &controls);

        try sdl.setRenderDrawColor(renderer, 12, 14, 18, 255);
        try sdl.renderClear(renderer);
        var presenter = powder.renderer.sdlFontRendererWithTextures(renderer, font, LABEL_FONT_SIZE, &texture_store, lookupTexture);
        try presenter.renderBatch(&batch);
        try drawOutlines(renderer, layout_rects);
        try drawLabels(&presenter, layout_rects, state, controls, frame_index);
        sdl.renderPresent(renderer);
        updateWindowTitle(window, state, controls, frame_index);
        sdl.delay(16);
    }
}

fn layoutControls(allocator: std.mem.Allocator, window: *sdl.Window, controls: *Controls) !LayoutRects {
    const size = try window.size();
    const window_rect: powder.Rect = .{ .w = @floatFromInt(size.w), .h = @floatFromInt(size.h) };
    const shell_box: powder.layout.Box = .{
        .rect = window_rect,
        .margin = powder.layout.Edges.all(12),
        .padding = powder.layout.Edges.all(16),
    };
    const content = shell_box.contentRect();
    var rows: [3]powder.Rect = undefined;
    powder.layout.flex(
        content,
        .{ .direction = .column, .gap = 18 },
        &.{
            powder.layout.FlexItem.fixed(0, 104),
            powder.layout.FlexItem.fixed(0, 70),
            powder.layout.FlexItem{ .basis_h = 52, .grow = 1, .min_h = 52 },
        },
        &rows,
    );

    const grid_box: powder.layout.Box = .{ .rect = rows[0], .padding = powder.layout.Edges.xy(14, 32) };
    const prompt_box: powder.layout.Box = .{ .rect = rows[1], .padding = powder.layout.Edges.xy(14, 24) };
    const wrap_box: powder.layout.Box = .{ .rect = rows[2], .padding = powder.layout.Edges.xy(14, 30) };

    try powder.layout.applyGrid(
        allocator,
        grid_box.contentRect(),
        .{
            .columns = &.{ .{ .fr = 1 }, .{ .fr = 1 }, .{ .fr = 1 }, .{ .px = 116 }, .{ .px = 116 } },
            .rows = &.{.{ .px = 32 }},
            .gap_x = 10,
        },
        .{
            powder.layout.GridItem{ .column = 0, .row = 0 },
            powder.layout.GridItem{ .column = 1, .row = 0 },
            powder.layout.GridItem{ .column = 2, .row = 0 },
            powder.layout.GridItem{ .column = 3, .row = 0 },
            powder.layout.GridItem{ .column = 4, .row = 0 },
        },
        .{ &controls.provider, &controls.model, &controls.reasoning, &controls.fast, &controls.access },
    );

    powder.layout.applyFlex(
        prompt_box.contentRect(),
        .{ .direction = .row, .gap = 10 },
        .{
            powder.layout.FlexItem{ .basis_w = 280, .basis_h = 38, .grow = 1, .min_w = 160 },
            powder.layout.FlexItem.fixed(48, 38),
            powder.layout.FlexItem.fixed(86, 38),
            powder.layout.FlexItem.fixed(86, 38),
        },
        .{ &controls.prompt, &controls.preview, &controls.send, &controls.stop },
    );

    powder.layout.applyFlex(
        wrap_box.contentRect(),
        .{ .direction = .row, .wrap = true, .gap = 10, .row_gap = 12, .align_items = .start },
        .{
            powder.layout.FlexItem{ .basis_w = 138, .basis_h = 34, .margin = powder.layout.Edges.xy(6, 0) },
            powder.layout.FlexItem{ .basis_w = 148, .basis_h = 34, .margin = powder.layout.Edges.xy(6, 0) },
            powder.layout.FlexItem{ .basis_w = 120, .basis_h = 34, .margin = powder.layout.Edges.xy(6, 0) },
            powder.layout.FlexItem{ .basis_w = 130, .basis_h = 34, .margin = powder.layout.Edges.xy(6, 0) },
            powder.layout.FlexItem{ .basis_w = 110, .basis_h = 34, .margin = powder.layout.Edges.xy(6, 0) },
            powder.layout.FlexItem{ .basis_w = 120, .basis_h = 34, .margin = powder.layout.Edges.xy(6, 0) },
        },
        .{ &controls.chip_a, &controls.chip_b, &controls.chip_c, &controls.chip_d, &controls.chip_e, &controls.chip_f },
    );

    return .{
        .shell = shell_box.bounds(),
        .content = content,
        .grid_panel = rows[0],
        .prompt_panel = rows[1],
        .wrap_panel = rows[2],
        .grid_content = grid_box.contentRect(),
        .prompt_content = prompt_box.contentRect(),
        .wrap_content = wrap_box.contentRect(),
    };
}

fn routeEvent(allocator: std.mem.Allocator, event: *const sdl.Event, controls: *Controls) !void {
    _ = controls.provider.update(event) catch false;
    _ = controls.model.update(event) catch false;
    _ = controls.reasoning.update(event) catch false;
    _ = try controls.prompt.update(allocator, event);
    _ = try controls.send.update(event);
    _ = try controls.stop.update(event);
    _ = try controls.fast.update(event);
    _ = try controls.access.update(event);
    _ = try controls.chip_a.update(event);
    _ = try controls.chip_b.update(event);
    _ = try controls.chip_c.update(event);
    _ = try controls.chip_d.update(event);
    _ = try controls.chip_e.update(event);
    _ = try controls.chip_f.update(event);
}

fn renderLabChrome(allocator: std.mem.Allocator, batch: *powder.RenderBatch, rects: LayoutRects) !void {
    try batch.rect(allocator, rects.shell, .{ .r = 0.06, .g = 0.07, .b = 0.09, .a = 1.0 });
    try batch.rect(allocator, rects.grid_panel, .{ .r = 0.10, .g = 0.12, .b = 0.15, .a = 1.0 });
    try batch.rect(allocator, rects.prompt_panel, .{ .r = 0.08, .g = 0.11, .b = 0.12, .a = 1.0 });
    try batch.rect(allocator, rects.wrap_panel, .{ .r = 0.09, .g = 0.09, .b = 0.12, .a = 1.0 });
    try batch.rect(allocator, rects.grid_content, .{ .r = 0.13, .g = 0.15, .b = 0.19, .a = 0.42 });
    try batch.rect(allocator, rects.prompt_content, .{ .r = 0.11, .g = 0.16, .b = 0.15, .a = 0.40 });
    try batch.rect(allocator, rects.wrap_content, .{ .r = 0.13, .g = 0.12, .b = 0.17, .a = 0.42 });
}

fn renderControls(allocator: std.mem.Allocator, batch: *powder.RenderBatch, controls: *const Controls) !void {
    try controls.provider.render(allocator, batch);
    try controls.model.render(allocator, batch);
    try controls.reasoning.render(allocator, batch);
    try controls.preview.render(allocator, batch);
    try controls.fast.render(allocator, batch);
    try controls.access.render(allocator, batch);
    try controls.prompt.render(allocator, batch);
    try controls.send.render(allocator, batch);
    try controls.stop.render(allocator, batch);
    try controls.chip_a.render(allocator, batch);
    try controls.chip_b.render(allocator, batch);
    try controls.chip_c.render(allocator, batch);
    try controls.chip_d.render(allocator, batch);
    try controls.chip_e.render(allocator, batch);
    try controls.chip_f.render(allocator, batch);
}

fn drawOutlines(renderer: *sdl.Renderer, rects: LayoutRects) !void {
    try outline(renderer, rects.shell, .{ 242, 142, 96, 255 });
    try outline(renderer, rects.content, .{ 86, 152, 244, 255 });
    try outline(renderer, rects.grid_content, .{ 76, 175, 124, 255 });
    try outline(renderer, rects.prompt_content, .{ 76, 175, 124, 255 });
    try outline(renderer, rects.wrap_content, .{ 76, 175, 124, 255 });
}

fn outline(renderer: *sdl.Renderer, rect: powder.Rect, color: [4]u8) !void {
    try sdl.setRenderDrawColor(renderer, color[0], color[1], color[2], color[3]);
    try sdl.renderFillRect(renderer, .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = 1 });
    try sdl.renderFillRect(renderer, .{ .x = rect.x, .y = rect.y + rect.h - 1, .w = rect.w, .h = 1 });
    try sdl.renderFillRect(renderer, .{ .x = rect.x, .y = rect.y, .w = 1, .h = rect.h });
    try sdl.renderFillRect(renderer, .{ .x = rect.x + rect.w - 1, .y = rect.y, .w = 1, .h = rect.h });
}

fn drawLabels(presenter: *powder.renderer.SdlFontRenderer, rects: LayoutRects, state: State, controls: Controls, frame_index: usize) !void {
    try label(presenter, rects.shell.x + 12, rects.shell.y + 10, "Powder Layout Lab", .{ 235, 241, 248, 255 });
    try label(presenter, rects.grid_panel.x + 14, rects.grid_panel.y + 9, "Grid: 3 fractional columns + 2 fixed columns", .{ 166, 180, 198, 255 });
    try label(presenter, rects.prompt_panel.x + 14, rects.prompt_panel.y + 7, "Flex row: prompt grows, buttons stay fixed", .{ 166, 180, 198, 255 });
    try label(presenter, rects.wrap_panel.x + 14, rects.wrap_panel.y + 9, "Flex wrap: resize narrower to force chips onto new rows", .{ 166, 180, 198, 255 });
    try label(presenter, rects.shell.x + 16, rects.shell.y + rects.shell.h - 24, "orange=shell margin box  blue=content  green=padded content", .{ 166, 180, 198, 255 });

    var status_buf: [256]u8 = undefined;
    const status = try std.fmt.bufPrint(&status_buf, "send={d} stop={d} chips={d} fast={} tools={} prompt_bytes={d} frame={d}", .{
        state.send_clicks,
        state.stop_clicks,
        state.chip_clicks,
        controls.fast.checked,
        controls.access.checked,
        controls.prompt.text().len,
        frame_index,
    });
    try label(presenter, rects.shell.x + 16, rects.shell.y + rects.shell.h - 46, status, .{ 214, 226, 242, 255 });
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

const TextureStore = struct {
    texture: *sdl.Texture,
    width: f32,
    height: f32,
};

fn lookupTexture(context: ?*anyopaque, id: powder.TextureId) ?powder.renderer.SdlTexture {
    if (id.value != 1) return null;
    const store: *TextureStore = @ptrCast(@alignCast(context orelse return null));
    return .{ .texture = store.texture, .width = store.width, .height = store.height };
}

fn handleSend(context: ?*anyopaque, event: powder.ButtonEvent) void {
    const state: *State = @ptrCast(@alignCast(context orelse return));
    switch (event) {
        .clicked, .activated => state.send_clicks += 1,
        else => {},
    }
}

fn handleStop(context: ?*anyopaque, event: powder.ButtonEvent) void {
    const state: *State = @ptrCast(@alignCast(context orelse return));
    switch (event) {
        .clicked, .activated => state.stop_clicks += 1,
        else => {},
    }
}

fn handleChip(context: ?*anyopaque, event: powder.ButtonEvent) void {
    const state: *State = @ptrCast(@alignCast(context orelse return));
    switch (event) {
        .clicked, .activated => state.chip_clicks += 1,
        else => {},
    }
}

fn updateWindowTitle(window: *sdl.Window, state: State, controls: Controls, frame_index: usize) void {
    var title_buffer: [256:0]u8 = undefined;
    @memset(&title_buffer, 0);
    const title = std.fmt.bufPrintZ(
        &title_buffer,
        "Powder Layout Lab | send={d} stop={d} chips={d} fast={} tools={} prompt={d} frame={d}",
        .{ state.send_clicks, state.stop_clicks, state.chip_clicks, controls.fast.checked, controls.access.checked, controls.prompt.text().len, frame_index },
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

fn providerLabel(_: ?*anyopaque, index: usize) []const u8 {
    return switch (index) {
        0 => "OpenAI",
        1 => "Anthropic",
        2 => "Local",
        else => "Mock",
    };
}

fn modelLabel(_: ?*anyopaque, index: usize) []const u8 {
    return switch (index) {
        0 => "Fast",
        1 => "Default",
        2 => "Deep",
        else => "Custom",
    };
}

fn reasoningLabel(_: ?*anyopaque, index: usize) []const u8 {
    return switch (index) {
        0 => "Low",
        1 => "Medium",
        2 => "High",
        else => "Max",
    };
}
