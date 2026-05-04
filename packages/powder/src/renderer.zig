//! SDL_GPU renderer bridge for powder render batches.

const Self = @This();
const std = @import("std");

const draw = @import("draw.zig");
const sdl = @import("sdl.zig");

pub const c = struct {
    pub const SDL_GPUDevice = opaque {};
    pub const SDL_GPURenderPass = opaque {};
    pub const SDL_GPUGraphicsPipeline = opaque {};

    extern fn SDL_CreateGPUDevice(format_flags: u32, debug_mode: bool, name: ?[*:0]const u8) ?*SDL_GPUDevice;
    extern fn SDL_DestroyGPUDevice(device: *SDL_GPUDevice) void;
    extern fn SDL_ReleaseGPUGraphicsPipeline(device: *SDL_GPUDevice, pipeline: *SDL_GPUGraphicsPipeline) void;
};

pub const RendererConfig = struct {
    debug_mode: bool = false,
    shader_formats: u32 = 0,
};

pub const Renderer = struct {
    device: ?*c.SDL_GPUDevice = null,
    pipeline: ?*c.SDL_GPUGraphicsPipeline = null,
    command_counts: CommandCounts = .{},

    /// Creates the SDL_GPU device. Vulkan and Metal are selected by SDL for Linux/macOS.
    pub fn init(config: RendererConfig) !Renderer {
        const device = c.SDL_CreateGPUDevice(config.shader_formats, config.debug_mode, null) orelse return error.SdlGpuCreateDeviceFailed;
        return .{ .device = device };
    }

    pub fn deinit(self: *Renderer) void {
        if (self.device) |device| {
            if (self.pipeline) |pipeline| c.SDL_ReleaseGPUGraphicsPipeline(device, pipeline);
            c.SDL_DestroyGPUDevice(device);
        }
        self.* = undefined;
    }

    /// Walks every command in the batch. The SDL_GPU backend still needs platform
    /// upload/pass glue, but command handling is centralized here rather than in
    /// components or app-specific presenters.
    pub fn renderBatch(self: *Renderer, pass: *c.SDL_GPURenderPass, batch: *const draw.RenderBatch) void {
        _ = pass;
        self.command_counts = CommandCounts.fromBatch(batch);
    }
};

pub const CommandCounts = struct {
    rects: usize = 0,
    text: usize = 0,
    cursors: usize = 0,
    selections: usize = 0,
    scrollbars: usize = 0,

    pub fn fromBatch(batch: *const draw.RenderBatch) CommandCounts {
        var counts: CommandCounts = .{};
        for (batch.commands.items) |command| {
            switch (command.kind) {
                .rect => counts.rects += 1,
                .text => counts.text += 1,
                .cursor => counts.cursors += 1,
                .selection => counts.selections += 1,
                .scrollbar => counts.scrollbars += 1,
            }
        }
        return counts;
    }
};

pub const Mesh = struct {
    vertices: std.ArrayList(draw.Vertex) = .empty,
    indices: std.ArrayList(u32) = .empty,

    pub fn deinit(self: *Mesh, allocator: std.mem.Allocator) void {
        self.vertices.deinit(allocator);
        self.indices.deinit(allocator);
    }

    pub fn clear(self: *Mesh) void {
        self.vertices.clearRetainingCapacity();
        self.indices.clearRetainingCapacity();
    }
};

pub const SdlDebugRenderer = struct {
    allocator: std.mem.Allocator,
    renderer: *sdl.Renderer,

    pub fn renderBatch(self: *SdlDebugRenderer, batch: *const draw.RenderBatch) !void {
        for (batch.commands.items) |command| {
            switch (command.kind) {
                .rect, .cursor, .selection, .scrollbar => try self.renderRect(command),
                .text => try self.renderText(command),
            }
        }
    }

    fn renderRect(self: *SdlDebugRenderer, command: draw.Command) !void {
        const color = colorBytes(command.color);
        if (color[3] == 0) return;
        try sdl.setRenderDrawColor(self.renderer, color[0], color[1], color[2], color[3]);
        try sdl.renderFillRect(self.renderer, .{
            .x = command.rect.x,
            .y = command.rect.y,
            .w = command.rect.w,
            .h = command.rect.h,
        });
    }

    fn renderText(self: *SdlDebugRenderer, command: draw.Command) !void {
        if (command.text.len == 0 or command.color.a <= 0.0) return;
        const color = colorBytes(command.color);
        try sdl.setRenderDrawColor(self.renderer, color[0], color[1], color[2], color[3]);
        if (command.clip) |clip| try sdl.setRenderClipRect(self.renderer, rectToSdl(clip));
        defer if (command.clip != null) sdl.setRenderClipRect(self.renderer, null) catch {};

        const wrap_columns = if (command.wrap)
            @max(@as(usize, @intFromFloat(@floor(command.rect.w / @max(command.glyph_width, 1.0)))), 1)
        else
            std.math.maxInt(usize);
        var row: usize = 0;
        var start: usize = 0;
        while (start <= command.text.len) {
            const hard_end = std.mem.indexOfScalarPos(u8, command.text, start, '\n') orelse command.text.len;
            var line_start = start;
            while (line_start <= hard_end) {
                const line_end = visualLineEnd(command.text[line_start..hard_end], wrap_columns) + line_start;
                const y = command.rect.y + @as(f32, @floatFromInt(row)) * command.line_height - command.scroll.y;
                if (command.clip == null or rectIntersectsY(command.clip.?, y, command.line_height)) {
                    try self.renderDebugLine(command.rect.x - command.scroll.x, y, command.text[line_start..line_end]);
                }
                row += 1;
                if (line_end >= hard_end) break;
                line_start = line_end;
            }
            if (hard_end == command.text.len) break;
            start = hard_end + 1;
        }
    }

    fn renderDebugLine(self: *SdlDebugRenderer, x: f32, y: f32, value: []const u8) !void {
        const z_text = try self.allocator.dupeZ(u8, if (value.len == 0) " " else value);
        defer self.allocator.free(z_text);
        try sdl.renderDebugText(self.renderer, x, y, z_text);
    }
};

pub fn sdlDebugRenderer(allocator: std.mem.Allocator, sdl_renderer: *sdl.Renderer) SdlDebugRenderer {
    return .{ .allocator = allocator, .renderer = sdl_renderer };
}

/// Converts retained render commands into indexed quads ready for GPU upload.
pub fn buildMesh(allocator: std.mem.Allocator, batch: *const draw.RenderBatch, mesh: *Mesh) !void {
    mesh.clear();
    try mesh.vertices.ensureUnusedCapacity(allocator, batch.commands.items.len * 4);
    try mesh.indices.ensureUnusedCapacity(allocator, batch.commands.items.len * 6);
    for (batch.commands.items) |command| {
        appendCommand(mesh, command);
    }
}

fn appendCommand(mesh: *Mesh, command: draw.Command) void {
    if (command.kind == .text) return;
    const base: u32 = @intCast(mesh.vertices.items.len);
    const x0 = command.rect.x;
    const y0 = command.rect.y;
    const x1 = command.rect.x + command.rect.w;
    const y1 = command.rect.y + command.rect.h;
    const uv_x0 = command.uv.x;
    const uv_y0 = command.uv.y;
    const uv_x1 = command.uv.x + command.uv.w;
    const uv_y1 = command.uv.y + command.uv.h;
    mesh.vertices.appendAssumeCapacity(.{ .pos = .{ .x = x0, .y = y0 }, .uv = .{ .x = uv_x0, .y = uv_y0 }, .color = command.color });
    mesh.vertices.appendAssumeCapacity(.{ .pos = .{ .x = x1, .y = y0 }, .uv = .{ .x = uv_x1, .y = uv_y0 }, .color = command.color });
    mesh.vertices.appendAssumeCapacity(.{ .pos = .{ .x = x1, .y = y1 }, .uv = .{ .x = uv_x1, .y = uv_y1 }, .color = command.color });
    mesh.vertices.appendAssumeCapacity(.{ .pos = .{ .x = x0, .y = y1 }, .uv = .{ .x = uv_x0, .y = uv_y1 }, .color = command.color });
    mesh.indices.appendSliceAssumeCapacity(&.{ base, base + 1, base + 2, base, base + 2, base + 3 });
}

fn visualLineEnd(text: []const u8, max_columns: usize) usize {
    if (text.len == 0) return 0;
    var offset: usize = 0;
    var column: usize = 0;
    while (offset < text.len and column < max_columns) : (column += 1) {
        offset = nextOffset(text, offset);
    }
    return @max(offset, 1);
}

fn nextOffset(text: []const u8, offset: usize) usize {
    if (offset >= text.len) return text.len;
    const len = std.unicode.utf8ByteSequenceLength(text[offset]) catch 1;
    return @min(offset + len, text.len);
}

fn rectIntersectsY(rect: draw.Rect, y: f32, h: f32) bool {
    return y + h >= rect.y and y <= rect.y + rect.h;
}

fn rectToSdl(rect: draw.Rect) sdl.Rect {
    return .{
        .x = @intFromFloat(@floor(rect.x)),
        .y = @intFromFloat(@floor(rect.y)),
        .w = @intFromFloat(@ceil(rect.w)),
        .h = @intFromFloat(@ceil(rect.h)),
    };
}

fn colorBytes(color: draw.Color) [4]u8 {
    return .{ colorByte(color.r), colorByte(color.g), colorByte(color.b), colorByte(color.a) };
}

fn colorByte(value: f32) u8 {
    return @intFromFloat(@min(@max(value, 0.0), 1.0) * 255.0);
}

pub const ShaderSource = struct {
    pub const vertex_hlsl = @embedFile("shaders/ui.vert.hlsl");
    pub const fragment_hlsl = @embedFile("shaders/ui.frag.hlsl");
};

test "renderer builds indexed quads from commands" {
    var batch: draw.RenderBatch = .{};
    defer batch.deinit(std.testing.allocator);
    try batch.rect(std.testing.allocator, .{ .x = 1, .y = 2, .w = 3, .h = 4 }, draw.Color.white);
    try batch.cursor(std.testing.allocator, .{ .x = 5, .y = 6, .w = 7, .h = 8 }, draw.Color.white);

    var mesh: Mesh = .{};
    defer mesh.deinit(std.testing.allocator);
    try buildMesh(std.testing.allocator, &batch, &mesh);

    try std.testing.expectEqual(@as(usize, 8), mesh.vertices.items.len);
    try std.testing.expectEqual(@as(usize, 12), mesh.indices.items.len);
    try std.testing.expectEqual(@as(f32, 4), mesh.vertices.items[2].pos.x);
}

test "gpu renderer renderBatch consumes command kinds" {
    var batch: draw.RenderBatch = .{};
    defer batch.deinit(std.testing.allocator);
    try batch.rect(std.testing.allocator, .{ .w = 1, .h = 1 }, draw.Color.white);
    try batch.text(std.testing.allocator, .{ .w = 20, .h = 20 }, "hello", draw.Color.white, 16, null);
    try batch.cursor(std.testing.allocator, .{ .w = 1, .h = 20 }, draw.Color.white);
    try batch.selection(std.testing.allocator, .{ .w = 10, .h = 20 }, draw.Color.white);
    try batch.scrollbar(std.testing.allocator, .{ .w = 4, .h = 20 }, draw.Color.white);

    var renderer: Renderer = .{};
    renderer.renderBatch(undefined, &batch);
    try std.testing.expectEqual(@as(usize, 1), renderer.command_counts.rects);
    try std.testing.expectEqual(@as(usize, 1), renderer.command_counts.text);
    try std.testing.expectEqual(@as(usize, 1), renderer.command_counts.cursors);
    try std.testing.expectEqual(@as(usize, 1), renderer.command_counts.selections);
    try std.testing.expectEqual(@as(usize, 1), renderer.command_counts.scrollbars);
}
