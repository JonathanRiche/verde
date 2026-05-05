//! Cross-platform composer prompt review example.

const std = @import("std");
const powder = @import("powder");

const Composer = powder.composerPrompt(.{
    .width = 720,
    .height = 176,
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

pub fn main() !void {
    try run(true);
}

fn run(print_report: bool) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var composer = Composer.init();
    composer.setBounds(.{ .x = 0, .y = 0, .w = 720, .h = 176 });

    var batch: powder.RenderBatch = .{};
    defer batch.deinit(allocator);
    try composer.render(allocator, &batch);

    var text_commands: usize = 0;
    var icon_runs: usize = 0;
    var separators: usize = 0;
    var rounded_shell = false;
    var rounded_send = false;

    for (batch.commands.items) |command| {
        if (command.kind == .text) {
            text_commands += 1;
            for (command.text_runs) |text_run| {
                if (text_run.font_role == .icon) icon_runs += 1;
            }
        }
        if (command.kind == .rect and command.radius >= 12.0 and command.border_width > 0.0) rounded_shell = true;
        if (command.kind == .rect and command.radius >= 16.0 and command.border_width == 0.0 and command.color.g > 0.4) rounded_send = true;
        if (command.kind == .rect and command.rect.w <= 1.0 and command.rect.h > 8.0) separators += 1;
    }

    if (print_report) {
        std.debug.print("Powder composer prompt review\n", .{});
        printRect("composer", composer.bounds());
        printRect("text", composer.textRect());
        printRect("toolbar", composer.toolbarRect());
        printRect("send", composer.sendButtonRect());
        std.debug.print("commands={d} text_commands={d} icon_runs={d} separators={d}\n", .{ batch.commands.items.len, text_commands, icon_runs, separators });
    }

    if (!rounded_shell or !rounded_send or text_commands < 5 or icon_runs < 4 or separators < 3) return error.InvalidComposerPromptReview;
}

fn printRect(label: []const u8, rect: powder.Rect) void {
    std.debug.print("{s}: x={d:.1} y={d:.1} w={d:.1} h={d:.1}\n", .{ label, rect.x, rect.y, rect.w, rect.h });
}

test "composer prompt review runs" {
    try run(false);
}
