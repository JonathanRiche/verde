//! SDL visual lab for retained Powder components beyond TextArea.

const std = @import("std");
const builtin = @import("builtin");
const powder = @import("powder");
const sdl = powder.sdl;

const CAL_SANS_PATH = "../desktop/src/assets/fonts/CalSans-Regular.ttf";
const LABEL_FONT_SIZE: f32 = 16.0;

const Header = powder.text(.{
    .x = 24,
    .y = 16,
    .width = 520,
    .height = 24,
    .font_size = 18,
    .color = .{ .r = 0.84, .g = 0.90, .b = 0.96, .a = 1.0 },
    .selectable = true,
});
const Search = powder.textInput(.{
    .x = 24,
    .y = 76,
    .width = 280,
    .height = 34,
    .glyph_width = 8,
    .placeholder_text = "Type here",
});
const ApplyButton = powder.button(.{ .x = 320, .y = 76, .width = 104, .height = 34, .label = "Apply" });
const ToolButton = powder.iconButton(.{ .x = 436, .y = 76, .width = 34, .height = 34, .icon_inset = 9 });
const ReadyCheck = powder.checkbox(.{ .x = 24, .y = 130, .size = 20, .label = "Ready" });
const LiveToggle = powder.toggle(.{ .x = 160, .y = 129, .width = 42, .height = 22, .label = "Live" });
const Items = powder.listBox(.{ .x = 24, .y = 198, .width = 220, .height = 132, .padding_x = 8, .padding_y = 6, .row_height = 24, .item_count = 12 });
const Choice = powder.select(.{ .x = 300, .y = 198, .width = 200, .height = 32, .menu_height = 120, .padding_x = 8, .padding_y = 6, .row_height = 28, .item_count = 8 });
const Strip = powder.tabs(.{ .x = 24, .y = 366, .width = 360, .height = 34, .tab_width = 120, .tab_count = 3 });
const Panel = powder.scrollArea(.{ .x = 560, .y = 76, .width = 160, .height = 128, .content_height = 320, .background_color = .{ .r = 0.07, .g = 0.08, .b = 0.10, .a = 1.0 }, .scrollbar_width = 6 });
const Popup = powder.menu(.{ .x = 740, .y = 96, .width = 160, .row_height = 28, .item_count = 5 });
const Dialog = powder.modal(.{ .x = 260, .y = 150, .width = 340, .height = 180 });
const Grid = powder.table(.{ .x = 560, .y = 254, .width = 330, .height = 132, .header_height = 26, .row_height = 24, .column_width = 110, .row_count = 14, .column_count = 3 });
const Source = powder.codeView(.{ .x = 24, .y = 430, .width = 856, .height = 132, .glyph_width = 8, .line_height = 18 });

const State = struct {
    apply_clicks: usize = 0,
    tool_clicks: usize = 0,
    last_menu: ?usize = null,
};

pub export fn powder_component_lab_main() c_int {
    run() catch |err| {
        std.debug.print("powder component_lab failed: {s}\n", .{@errorName(err)});
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

    const window = try sdl.Window.create("Powder Component Lab", 920, 600, labWindowFlags());
    defer sdl.Window.destroy(window);
    const renderer = try sdl.Renderer.create(window);
    defer sdl.Renderer.destroy(renderer);
    try sdl.setRenderDrawBlendMode(renderer, .blend);
    const font = try sdl.ttfOpenFont(CAL_SANS_PATH, LABEL_FONT_SIZE);
    defer sdl.ttfCloseFont(font);

    sdl.startTextInput(window) catch {};
    defer sdl.stopTextInput(window) catch {};

    var state: State = .{};
    var header = try Header.init(allocator, "Powder Component Lab");
    defer header.deinit(allocator);
    header.setCallbacks(.{ .set_clipboard = setClipboard });

    var search = try Search.init(allocator, "powder");
    defer search.deinit(allocator);
    search.setCallbacks(.{ .set_clipboard = setClipboard, .get_clipboard = getClipboard });

    var apply = ApplyButton.init();
    apply.setCallbacks(.{ .context = &state, .on_event = handleApplyEvent });
    var tool = ToolButton.init();
    tool.setCallbacks(.{ .context = &state, .on_event = handleToolEvent });
    var checkbox = ReadyCheck.init(false);
    var toggle = LiveToggle.init(false);
    var list = Items.initFromConfig();
    var select = Choice.initFromConfig();
    select.open = true;
    select.highlighted_index = 0;
    var tabs = Strip.initFromConfig();
    var panel = Panel.init();
    var popup = Popup.initFromConfig();
    popup.setCallbacks(.{ .context = &state, .on_event = handleMenuEvent });
    var dialog = Dialog.init(false);
    var table = Grid.initFromConfig();
    var source = try Source.init(allocator,
        \\const app = powder.ui();
        \\+ add retained components
        \\+ wire SDL events
        \\- remove immediate-only assumptions
        \\render(batch);
        \\copy/select/scroll/check/dropdown/table/code
    );
    defer source.deinit(allocator);

    var batch: powder.RenderBatch = .{};
    defer batch.deinit(allocator);

    std.debug.print("powder component_lab started; close the window or press Ctrl+C to exit.\n", .{});
    defer std.debug.print("powder component_lab stopped.\n", .{});

    var running = true;
    var frame_index: usize = 0;
    while (running) : (frame_index += 1) {
        search.tick(16);

        var event: sdl.Event = undefined;
        while (sdl.pollEvent(&event)) {
            switch (event.type) {
                .quit, .window_close_requested => running = false,
                else => try routeEvent(allocator, &event, &header, &search, &apply, &tool, &checkbox, &toggle, &list, &select, &tabs, &panel, &popup, &dialog, &table, &source),
            }
        }

        batch.clear();
        try header.render(allocator, &batch);
        try search.render(allocator, &batch);
        try apply.render(allocator, &batch);
        try tool.render(allocator, &batch);
        try checkbox.render(allocator, &batch);
        try toggle.render(allocator, &batch);
        try list.render(allocator, &batch);
        try select.render(allocator, &batch);
        try tabs.render(allocator, &batch);
        try panel.render(allocator, &batch);
        try popup.render(allocator, &batch);
        try table.render(allocator, &batch);
        try source.render(allocator, &batch);
        try dialog.render(allocator, &batch);

        var presenter = powder.renderer.sdlFontRenderer(renderer, font, LABEL_FONT_SIZE);
        try drawBatch(renderer, batch.commands.items);
        try drawDebugOverlay(&presenter, state, header, search, checkbox, toggle, list, select, tabs, panel, popup, dialog, table, source);
        sdl.renderPresent(renderer);
        updateWindowTitle(window, state, search, checkbox, toggle, list, select, tabs, batch.commands.items.len, frame_index);
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

fn routeEvent(
    allocator: std.mem.Allocator,
    event: *const sdl.Event,
    header: *Header,
    search: *Search,
    apply: *ApplyButton,
    tool: *ToolButton,
    checkbox: *ReadyCheck,
    toggle: *LiveToggle,
    list: *Items,
    select: *Choice,
    tabs: *Strip,
    panel: *Panel,
    popup: *Popup,
    dialog: *Dialog,
    table: *Grid,
    source: *Source,
) !void {
    if (dialog.open) {
        if (try dialog.update(event)) return;
    }
    switch (event.type) {
        .key_down => {
            if (event.key.key == .escape and popup.open) {
                _ = popup.handleInput(.{ .key = .{ .code = .escape } });
                return;
            }
            _ = try search.update(allocator, event);
            _ = try header.update(event);
            _ = try apply.update(event);
            _ = try tool.update(event);
            _ = try checkbox.update(event);
            _ = try toggle.update(event);
            _ = list.update(event) catch false;
            _ = select.update(event) catch false;
            _ = tabs.update(event) catch false;
            if (event.key.key == .space) _ = popup.handleInput(.open);
            if (event.key.key == .@"return" and event.key.mod & sdl.Keymod.ctrl != 0) _ = dialog.handleInput(.open);
        },
        .text_input, .text_editing => _ = try search.update(allocator, event),
        .mouse_motion => {
            _ = try header.update(event);
            _ = try search.update(allocator, event);
            _ = try apply.update(event);
            _ = try tool.update(event);
            _ = try checkbox.update(event);
            _ = try toggle.update(event);
            _ = list.update(event) catch false;
            _ = select.update(event) catch false;
            _ = tabs.update(event) catch false;
            _ = panel.update(event) catch false;
            _ = popup.update(event) catch false;
            _ = source.handleInput(.{ .mouse_drag = .{ .x = event.motion.x, .y = event.motion.y } });
        },
        .mouse_button_down => {
            const point: powder.draw.Vec2 = .{ .x = event.button.x, .y = event.button.y };
            if (event.button.button == 3) {
                _ = popup.handleInput(.open);
                return;
            }
            if (point.x >= 740 and point.x <= 900 and point.y >= 68 and point.y <= 88) {
                _ = popup.handleInput(.open);
            }
            if (point.x >= 740 and point.x <= 900 and point.y >= 404 and point.y <= 426) {
                _ = dialog.handleInput(.open);
            }
            _ = try header.update(event);
            _ = try search.update(allocator, event);
            _ = try apply.update(event);
            _ = try tool.update(event);
            _ = try checkbox.update(event);
            _ = try toggle.update(event);
            _ = list.update(event) catch false;
            _ = select.update(event) catch false;
            _ = tabs.update(event) catch false;
            _ = panel.update(event) catch false;
            _ = popup.update(event) catch false;
            _ = table.handleInput(.{ .mouse_down = point });
            _ = source.handleInput(.{ .mouse_down = point });
        },
        .mouse_button_up => {
            _ = try search.update(allocator, event);
            _ = try apply.update(event);
            _ = try tool.update(event);
            _ = try checkbox.update(event);
            _ = try toggle.update(event);
            _ = list.update(event) catch false;
            _ = select.update(event) catch false;
            _ = panel.update(event) catch false;
            _ = source.handleInput(.{ .mouse_up = .{ .x = event.button.x, .y = event.button.y } });
        },
        .mouse_wheel => {
            _ = list.update(event) catch false;
            _ = select.update(event) catch false;
            _ = panel.update(event) catch false;
            _ = table.handleInput(.{ .mouse_wheel = event.wheel.y });
            _ = source.handleInput(.{ .mouse_wheel = event.wheel.y });
        },
        else => {},
    }
}

fn drawBatch(renderer: *sdl.Renderer, commands: []const powder.draw.Command) !void {
    try sdl.setRenderDrawColor(renderer, 13, 15, 18, 255);
    try sdl.renderClear(renderer);
    for (commands) |command| {
        const color = commandColor(command);
        if (color[3] == 0) continue;
        try sdl.setRenderDrawColor(renderer, color[0], color[1], color[2], color[3]);
        try sdl.renderFillRect(renderer, .{ .x = command.rect.x, .y = command.rect.y, .w = command.rect.w, .h = command.rect.h });
    }
}

fn drawDebugOverlay(
    presenter: *powder.renderer.SdlFontRenderer,
    state: State,
    header: Header,
    search: Search,
    checkbox: ReadyCheck,
    toggle: LiveToggle,
    list: Items,
    select: Choice,
    tabs: Strip,
    panel: Panel,
    popup: Popup,
    dialog: Dialog,
    table: Grid,
    source: Source,
) !void {
    try debugText(presenter, 24, 22, header.text(), .{ 214, 226, 242, 255 });
    try debugText(presenter, 24, 42, "Selectable header: drag over title, Ctrl+C", .{ 122, 137, 156, 255 });
    try debugText(presenter, 24, 60, "TextInput", .{ 122, 137, 156, 255 });
    try debugText(presenter, 320, 60, "Button / IconButton", .{ 122, 137, 156, 255 });
    try debugText(presenter, 32, 87, if (search.text().len == 0) "Type here" else search.text(), .{ 236, 241, 248, 255 });
    try debugText(presenter, 342, 88, "Apply", .{ 236, 241, 248, 255 });
    try debugText(presenter, 447, 88, "*", .{ 236, 241, 248, 255 });
    try debugText(presenter, 24, 116, "Checkbox / Toggle", .{ 122, 137, 156, 255 });
    try debugText(presenter, 54, 133, "Ready", .{ 236, 241, 248, 255 });
    try debugText(presenter, 214, 133, "Live", .{ 236, 241, 248, 255 });

    try debugText(presenter, 24, 178, "ListBox", .{ 122, 137, 156, 255 });
    try debugText(presenter, 300, 178, "Select / Dropdown", .{ 122, 137, 156, 255 });
    try drawListLabels(presenter, list);
    try debugText(presenter, 308, 207, selectLabel(select.selected_index), .{ 236, 241, 248, 255 });
    try debugText(presenter, 472, 207, "v", .{ 170, 184, 204, 255 });
    if (select.open) try drawSelectLabels(presenter, select);
    try debugText(presenter, 24, 346, "Tabs", .{ 122, 137, 156, 255 });
    try drawTabLabels(presenter, tabs);
    try debugText(presenter, 560, 56, "ScrollArea", .{ 122, 137, 156, 255 });
    try drawPanelContent(presenter, panel);
    try debugText(presenter, 740, 56, "Menu", .{ 122, 137, 156, 255 });
    try debugText(presenter, 740, 74, "Open menu", .{ 236, 241, 248, 255 });
    if (popup.open) try drawMenuLabels(presenter);
    try debugText(presenter, 560, 234, "Table", .{ 122, 137, 156, 255 });
    try drawTableText(presenter, table);
    try debugText(presenter, 740, 404, "Open modal", .{ 236, 241, 248, 255 });
    try debugText(presenter, 24, 410, "CodeView / DiffView", .{ 122, 137, 156, 255 });
    try drawCodeText(presenter, source);

    var status_buf: [256]u8 = undefined;
    const status = try std.fmt.bufPrint(&status_buf, "clicks={d}/{d} ready={} live={} list={?} select={?} tab={d} scroll={d} menu={?} modal={}", .{
        state.apply_clicks,
        state.tool_clicks,
        checkbox.checked,
        toggle.checked,
        list.selected_index,
        select.selected_index,
        tabs.active_index,
        @as(i32, @intFromFloat(panel.scrollY())),
        state.last_menu,
        dialog.open,
    });
    try debugText(presenter, 24, 576, status, .{ 170, 184, 204, 255 });

    if (dialog.open) {
        try debugText(presenter, 292, 184, "Modal surface", .{ 236, 241, 248, 255 });
        try debugText(presenter, 292, 208, "Click outside or press Escape to dismiss.", .{ 196, 207, 222, 255 });
    }
}

fn drawListLabels(presenter: *powder.renderer.SdlFontRenderer, list: Items) !void {
    var index: usize = 0;
    while (index < 12) : (index += 1) {
        const y = 207 + @as(f32, @floatFromInt(index)) * 24.0 - list.scrollY();
        if (y < 198 or y > 320) continue;
        var buf: [32]u8 = undefined;
        try debugText(presenter, 34, y, try std.fmt.bufPrint(&buf, "List item {d}", .{index + 1}), .{ 236, 241, 248, 255 });
    }
}

fn drawSelectLabels(presenter: *powder.renderer.SdlFontRenderer, select: Choice) !void {
    var index: usize = 0;
    while (index < 8) : (index += 1) {
        const y = 238 + @as(f32, @floatFromInt(index)) * 28.0 - select.scrollY();
        if (y < 230 or y > 342) continue;
        try debugText(presenter, 308, y, selectLabel(index), .{ 236, 241, 248, 255 });
    }
}

fn drawTabLabels(presenter: *powder.renderer.SdlFontRenderer, tabs: Strip) !void {
    _ = tabs;
    try debugText(presenter, 52, 376, "Inspect", .{ 236, 241, 248, 255 });
    try debugText(presenter, 172, 376, "Review", .{ 236, 241, 248, 255 });
    try debugText(presenter, 292, 376, "Ship", .{ 236, 241, 248, 255 });
}

fn drawPanelContent(presenter: *powder.renderer.SdlFontRenderer, panel: Panel) !void {
    var row: usize = 0;
    while (row < 14) : (row += 1) {
        const y = 86 + @as(f32, @floatFromInt(row)) * 22.0 - panel.scrollY();
        if (y < 76 or y > 196) continue;
        var buf: [32]u8 = undefined;
        try debugText(presenter, 572, y, try std.fmt.bufPrint(&buf, "Scroll row {d}", .{row + 1}), .{ 210, 220, 232, 255 });
    }
}

fn drawMenuLabels(presenter: *powder.renderer.SdlFontRenderer) !void {
    try debugText(presenter, 748, 104, "New thread", .{ 236, 241, 248, 255 });
    try debugText(presenter, 748, 132, "Copy", .{ 236, 241, 248, 255 });
    try debugText(presenter, 748, 160, "Archive", .{ 236, 241, 248, 255 });
    try debugText(presenter, 748, 188, "Settings", .{ 236, 241, 248, 255 });
    try debugText(presenter, 748, 216, "Close", .{ 236, 241, 248, 255 });
}

fn drawTableText(presenter: *powder.renderer.SdlFontRenderer, table: Grid) !void {
    try debugText(presenter, 568, 262, "Name", .{ 236, 241, 248, 255 });
    try debugText(presenter, 678, 262, "State", .{ 236, 241, 248, 255 });
    try debugText(presenter, 788, 262, "Age", .{ 236, 241, 248, 255 });
    var row: usize = 0;
    while (row < 14) : (row += 1) {
        const y = 286 + @as(f32, @floatFromInt(row)) * 24.0 - table.scroll_y;
        if (y < 280 or y > 376) continue;
        var buf: [64]u8 = undefined;
        try debugText(presenter, 568, y, try std.fmt.bufPrint(&buf, "Task {d}", .{row + 1}), .{ 236, 241, 248, 255 });
        try debugText(presenter, 678, y, if (row % 2 == 0) "open" else "done", .{ 236, 241, 248, 255 });
        try debugText(presenter, 788, y, try std.fmt.bufPrint(&buf, "{d}m", .{(row + 1) * 3}), .{ 236, 241, 248, 255 });
    }
}

fn drawCodeText(presenter: *powder.renderer.SdlFontRenderer, source: Source) !void {
    var y: f32 = 438 - source.scroll_y;
    var start: usize = 0;
    var line: usize = 1;
    while (start <= source.text().len) : (line += 1) {
        const end = std.mem.indexOfScalarPos(u8, source.text(), start, '\n') orelse source.text().len;
        if (y >= 430 and y <= 552) {
            var line_buf: [12]u8 = undefined;
            try debugText(presenter, 34, y, try std.fmt.bufPrint(&line_buf, "{d}", .{line}), .{ 122, 137, 156, 255 });
            try debugText(presenter, 82, y, source.text()[start..end], .{ 236, 241, 248, 255 });
        }
        y += 18;
        if (end == source.text().len) break;
        start = end + 1;
    }
}

fn selectLabel(index: ?usize) []const u8 {
    return switch (index orelse 0) {
        0 => "Alpha",
        1 => "Bravo",
        2 => "Charlie",
        3 => "Delta",
        4 => "Echo",
        5 => "Foxtrot",
        6 => "Golf",
        else => "Hotel",
    };
}

fn commandColor(command: powder.draw.Command) [4]u8 {
    if (command.kind == .text) return .{ 0, 0, 0, 0 };
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

fn debugText(presenter: *powder.renderer.SdlFontRenderer, x: f32, y: f32, text: []const u8, color: [4]u8) !void {
    try presenter.renderLine(x, y, text, colorFromBytes(color), LABEL_FONT_SIZE);
}

fn colorFromBytes(color: [4]u8) powder.draw.Color {
    return .{
        .r = @as(f32, @floatFromInt(color[0])) / 255.0,
        .g = @as(f32, @floatFromInt(color[1])) / 255.0,
        .b = @as(f32, @floatFromInt(color[2])) / 255.0,
        .a = @as(f32, @floatFromInt(color[3])) / 255.0,
    };
}

fn setClipboard(_: ?*anyopaque, text: []const u8) bool {
    const z_text = std.heap.page_allocator.dupeZ(u8, text) catch return false;
    defer std.heap.page_allocator.free(z_text);
    sdl.setClipboardText(z_text) catch return false;
    return true;
}

fn getClipboard(_: ?*anyopaque, allocator: std.mem.Allocator) ?[]u8 {
    return sdl.getClipboardText(allocator) catch null;
}

fn handleApplyEvent(context: ?*anyopaque, event: powder.ButtonEvent) void {
    const state: *State = @ptrCast(@alignCast(context orelse return));
    switch (event) {
        .clicked, .activated => state.apply_clicks += 1,
        else => {},
    }
}

fn handleToolEvent(context: ?*anyopaque, event: powder.ButtonEvent) void {
    const state: *State = @ptrCast(@alignCast(context orelse return));
    switch (event) {
        .clicked, .activated => state.tool_clicks += 1,
        else => {},
    }
}

fn handleMenuEvent(context: ?*anyopaque, event: powder.MenuEvent) void {
    const state: *State = @ptrCast(@alignCast(context orelse return));
    switch (event) {
        .selected => |index| state.last_menu = index,
        else => {},
    }
}

fn updateWindowTitle(window: *sdl.Window, state: State, search: Search, checkbox: ReadyCheck, toggle: LiveToggle, list: Items, select: Choice, tabs: Strip, command_count: usize, frame_index: usize) void {
    var title_buffer: [256:0]u8 = undefined;
    @memset(&title_buffer, 0);
    const title = std.fmt.bufPrintZ(
        &title_buffer,
        "Powder Component Lab | text={d} ready={} live={} list={?} select={?} tab={d} clicks={d}/{d} commands={d} frame={d}",
        .{ search.text().len, checkbox.checked, toggle.checked, list.selected_index, select.selected_index, tabs.active_index, state.apply_clicks, state.tool_clicks, command_count, frame_index },
    ) catch return;
    sdl.Window.setTitle(window, title);
}
