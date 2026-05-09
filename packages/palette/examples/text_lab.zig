//! Batch-level UTF-8 text lab for Palette's shared text stack.

const std = @import("std");
const palette = @import("palette");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const font = palette.TextFontFace.defaultUi("", 16);
    const sample = "Palette UTF-8 wraps NBSP:\xc2\xa0kept, CJK: 界面, emoji fallback: 🙂.";

    var batch: palette.RenderBatch = .{};
    defer batch.deinit(allocator);

    try palette.TextStack.appendTextToBatch(allocator, &batch, .{
        .rect = .{ .x = 16, .y = 24, .w = 180, .h = 120 },
        .text = sample,
        .color = palette.Color.white,
        .font = &font,
        .wrap = true,
    });

    std.debug.print("text_lab commands={d} runs={d} width={d:.2} line_height={d:.2}\n", .{
        batch.commands.items.len,
        batch.text_runs.items.len,
        palette.TextStack.measureRun(&font, sample),
        font.lineHeight(),
    });
    for (batch.text_runs.items, 0..) |run, index| {
        std.debug.print("run[{d}] x={d:.1} y={d:.1} bytes={d}:{d} text=\"{s}\"\n", .{
            index,
            run.x,
            run.y,
            run.byte_start,
            run.byte_end,
            run.text,
        });
    }
}
