//! Cross-platform layout review example.

const std = @import("std");
const powder = @import("powder");

const Provider = powder.select(.{ .height = 32, .menu_height = 96, .item_count = 3, .item_label = providerLabel });
const Model = powder.select(.{ .height = 32, .menu_height = 96, .item_count = 3, .item_label = modelLabel });
const Reasoning = powder.select(.{ .height = 32, .menu_height = 96, .item_count = 3, .item_label = reasoningLabel });
const Prompt = powder.textInput(.{ .height = 36, .placeholder_text = "Ask Verde" });
const Fast = powder.toggle(.{ .label = "Fast" });
const Send = powder.button(.{ .label = "Send" });

pub fn main() !void {
    try run(true);
}

fn run(print_report: bool) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var provider = Provider.initFromConfig();
    var model = Model.initFromConfig();
    var reasoning = Reasoning.initFromConfig();
    var prompt = try Prompt.init(allocator, "");
    defer prompt.deinit(allocator);
    var fast = Fast.init(false);
    var send = Send.init();

    const window: powder.Rect = .{ .x = 0, .y = 0, .w = 760, .h = 220 };
    const shell: powder.layout.Box = .{
        .rect = window,
        .margin = powder.layout.Edges.all(12),
        .padding = powder.layout.Edges.all(16),
    };

    var sections: [2]powder.Rect = undefined;
    powder.layout.flex(
        shell.contentRect(),
        .{ .direction = .column, .gap = 12 },
        &.{
            powder.layout.FlexItem.fixed(0, 32),
            powder.layout.FlexItem.fixed(0, 36),
        },
        &sections,
    );

    try powder.layout.applyGrid(
        allocator,
        sections[0],
        .{
            .columns = &.{ .{ .fr = 1 }, .{ .fr = 1 }, .{ .fr = 1 }, .{ .px = 86 } },
            .rows = &.{.{ .px = 32 }},
            .gap_x = 8,
        },
        .{
            powder.layout.GridItem{ .column = 0, .row = 0 },
            powder.layout.GridItem{ .column = 1, .row = 0 },
            powder.layout.GridItem{ .column = 2, .row = 0 },
            powder.layout.GridItem{ .column = 3, .row = 0 },
        },
        .{ &provider, &model, &reasoning, &fast },
    );

    powder.layout.applyFlex(
        sections[1],
        .{ .direction = .row, .gap = 8 },
        .{
            powder.layout.FlexItem{ .basis_w = 240, .basis_h = 36, .grow = 1 },
            powder.layout.FlexItem.fixed(88, 36),
        },
        .{ &prompt, &send },
    );

    var batch: powder.RenderBatch = .{};
    defer batch.deinit(allocator);
    try provider.render(allocator, &batch);
    try model.render(allocator, &batch);
    try reasoning.render(allocator, &batch);
    try fast.render(allocator, &batch);
    try prompt.render(allocator, &batch);
    try send.render(allocator, &batch);

    if (print_report) {
        std.debug.print("Powder layout review\n", .{});
        printRect("shell.content", shell.contentRect());
        printRect("provider", provider.bounds());
        printRect("model", model.bounds());
        printRect("reasoning", reasoning.bounds());
        printRect("fast", fast.bounds());
        printRect("prompt", prompt.bounds());
        printRect("send", send.bounds());
        std.debug.print("commands={d}\n", .{batch.commands.items.len});
    }

    if (batch.commands.items.len == 0) return error.EmptyLayoutReview;
}

fn printRect(label: []const u8, rect: powder.Rect) void {
    std.debug.print("{s}: x={d:.1} y={d:.1} w={d:.1} h={d:.1}\n", .{ label, rect.x, rect.y, rect.w, rect.h });
}

fn providerLabel(_: ?*anyopaque, index: usize) []const u8 {
    return switch (index) {
        0 => "OpenAI",
        1 => "Local",
        else => "Mock",
    };
}

fn modelLabel(_: ?*anyopaque, index: usize) []const u8 {
    return switch (index) {
        0 => "Fast",
        1 => "Default",
        else => "Deep",
    };
}

fn reasoningLabel(_: ?*anyopaque, index: usize) []const u8 {
    return switch (index) {
        0 => "Low",
        1 => "Medium",
        else => "High",
    };
}

test "layout review runs" {
    try run(false);
}
