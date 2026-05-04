//! Non-windowed retained component catalog used as a buildable example.

const std = @import("std");
const powder = @import("powder");

const Label = powder.text(.{ .x = 12, .y = 10, .width = 180, .height = 24, .selectable = true });
const Input = powder.textInput(.{ .x = 12, .y = 42, .width = 220, .height = 32, .placeholder_text = "Filter" });
const PrimaryButton = powder.button(.{ .x = 12, .y = 84, .width = 96, .height = 32, .label = "Apply" });
const Logo = powder.image(.{ .x = 128, .y = 84, .width = 64, .height = 32, .source_width = 64, .source_height = 32, .fit = .contain });
const Check = powder.checkbox(.{ .x = 12, .y = 126, .label = "Enabled" });
const Switch = powder.toggle(.{ .x = 12, .y = 158, .label = "Live" });
const Items = powder.listBox(.{ .x = 260, .y = 10, .width = 180, .height = 96, .item_count = 8 });
const Choice = powder.select(.{ .x = 260, .y = 124, .width = 180, .height = 30, .menu_height = 90, .item_count = 5 });
const Strip = powder.tabs(.{ .x = 12, .y = 204, .width = 300, .height = 32, .tab_count = 3 });
const Viewport = powder.scrollArea(.{ .x = 460, .y = 10, .width = 120, .height = 96, .content_height = 240 });
const Dialog = powder.modal(.{ .x = 120, .y = 80, .width = 220, .height = 120 });
const Popup = powder.menu(.{ .x = 460, .y = 124, .width = 120, .row_height = 24, .item_count = 4 });
const Grid = powder.table(.{ .x = 600, .y = 10, .width = 260, .height = 120, .row_count = 6, .column_count = 3 });
const Source = powder.codeView(.{ .x = 600, .y = 150, .width = 260, .height = 120 });

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var label = try Label.init(allocator, "Selectable label");
    defer label.deinit(allocator);
    var input = try Input.init(allocator, "powder");
    defer input.deinit(allocator);
    var button = PrimaryButton.init();
    var logo = Logo.init(powder.TextureId.init(99));
    var checkbox = Check.init(false);
    var toggle = Switch.init(false);
    var list = Items.initFromConfig();
    var select = Choice.initFromConfig();
    var tabs = Strip.initFromConfig();
    var viewport = Viewport.init();
    var modal = Dialog.init(false);
    var menu = Popup.initFromConfig();
    var table = Grid.initFromConfig();
    var source = try Source.init(allocator, "const ok = true;\n+added\n-removed");
    defer source.deinit(allocator);

    powder.layout.applyFlex(
        .{ .x = 12, .y = 42, .w = 220, .h = 32 },
        .{ .direction = .row, .gap = 8, .align_items = .stretch },
        .{
            powder.layout.FlexItem{ .basis_w = 80, .basis_h = 32, .grow = 1 },
            powder.layout.FlexItem.fixed(80, 32),
        },
        .{ &input, &button },
    );

    try powder.layout.applyGrid(
        allocator,
        .{ .x = 260, .y = 10, .w = 320, .h = 146 },
        .{
            .columns = &.{ .{ .fr = 1 }, .{ .fr = 1 } },
            .rows = &.{ .{ .px = 96 }, .{ .px = 30 } },
            .gap_x = 16,
            .gap_y = 18,
        },
        .{
            powder.layout.GridItem{ .column = 0, .row = 0, .column_span = 2 },
            powder.layout.GridItem{ .column = 0, .row = 1 },
            powder.layout.GridItem{ .column = 1, .row = 1 },
        },
        .{ &select, &checkbox, &toggle },
    );

    _ = label.handleInput(.{ .mouse_down = .{ .x = 12, .y = 16 } });
    _ = label.handleInput(.{ .mouse_drag = .{ .x = 44, .y = 16 } });
    _ = try input.handleInput(allocator, .{ .key = .{ .code = .end } });
    _ = button.handleInput(.{ .mouse_move = .{ .x = 20, .y = 90 } });
    _ = checkbox.handleInput(.{ .activation_key = .space });
    _ = toggle.handleInput(.{ .focus = true });
    _ = toggle.handleInput(.{ .activation_key = .space });
    _ = list.handleInput(.{ .key = .{ .code = .down } });
    _ = select.handleInput(.{ .key = .{ .code = .enter } });
    _ = tabs.handleInput(.{ .key = .{ .code = .right } });
    viewport.scrollBy(24);
    _ = modal.handleInput(.open);
    _ = menu.handleInput(.open);
    _ = table.handleInput(.{ .key = .{ .code = .end } });
    _ = source.handleInput(.{ .mouse_wheel = -1 });

    var batch: powder.RenderBatch = .{};
    defer batch.deinit(allocator);

    try label.render(allocator, &batch);
    try input.render(allocator, &batch);
    try button.render(allocator, &batch);
    try logo.render(allocator, &batch);
    try checkbox.render(allocator, &batch);
    try toggle.render(allocator, &batch);
    try list.render(allocator, &batch);
    try select.render(allocator, &batch);
    try tabs.render(allocator, &batch);
    try viewport.render(allocator, &batch);
    try modal.render(allocator, &batch);
    try menu.render(allocator, &batch);
    try table.render(allocator, &batch);
    try source.render(allocator, &batch);

    if (batch.commands.items.len == 0) return error.EmptyCatalog;
}

test "component catalog renders commands" {
    try main();
}
