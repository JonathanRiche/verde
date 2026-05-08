const std = @import("std");
const palette = @import("palette");

const GL_FALSE: u8 = 0;
const GL_FLOAT: c_uint = 0x1406;
const GL_TRIANGLES: c_uint = 0x0004;
const GL_ARRAY_BUFFER: c_uint = 0x8892;
const GL_STREAM_DRAW: c_uint = 0x88E0;
const GL_VERTEX_SHADER: c_uint = 0x8B31;
const GL_FRAGMENT_SHADER: c_uint = 0x8B30;
const GL_TEXTURE0: c_uint = 0x84C0;
const GL_TEXTURE_2D: c_uint = 0x0DE1;
const GL_BLEND: c_uint = 0x0BE2;
const GL_CULL_FACE: c_uint = 0x0B44;
const GL_DEPTH_TEST: c_uint = 0x0B71;
const GL_SCISSOR_TEST: c_uint = 0x0C11;
const GL_SRC_ALPHA: c_uint = 0x0302;
const GL_ONE_MINUS_SRC_ALPHA: c_uint = 0x0303;

extern fn glCreateShader(shader_type: c_uint) c_uint;
extern fn glShaderSource(shader: c_uint, count: c_int, string: [*]const [*:0]const u8, length: ?[*]const c_int) void;
extern fn glCompileShader(shader: c_uint) void;
extern fn glDeleteShader(shader: c_uint) void;
extern fn glCreateProgram() c_uint;
extern fn glAttachShader(program: c_uint, shader: c_uint) void;
extern fn glLinkProgram(program: c_uint) void;
extern fn glDeleteProgram(program: c_uint) void;
extern fn glUseProgram(program: c_uint) void;
extern fn glGetUniformLocation(program: c_uint, name: [*:0]const u8) c_int;
extern fn glUniform2f(location: c_int, v0: f32, v1: f32) void;
extern fn glUniform1i(location: c_int, v0: c_int) void;
extern fn glGenVertexArrays(n: c_int, arrays: [*]c_uint) void;
extern fn glBindVertexArray(array: c_uint) void;
extern fn glDeleteVertexArrays(n: c_int, arrays: [*]const c_uint) void;
extern fn glGenBuffers(n: c_int, buffers: [*]c_uint) void;
extern fn glBindBuffer(target: c_uint, buffer: c_uint) void;
extern fn glBufferData(target: c_uint, size: isize, data: ?*const anyopaque, usage: c_uint) void;
extern fn glDeleteBuffers(n: c_int, buffers: [*]const c_uint) void;
extern fn glEnable(cap: c_uint) void;
extern fn glDisable(cap: c_uint) void;
extern fn glBlendFunc(sfactor: c_uint, dfactor: c_uint) void;
extern fn glEnableVertexAttribArray(index: c_uint) void;
extern fn glVertexAttribPointer(index: c_uint, size: c_int, type: c_uint, normalized: u8, stride: c_int, pointer: ?*const anyopaque) void;
extern fn glDrawArrays(mode: c_uint, first: c_int, count: c_int) void;
extern fn glActiveTexture(texture: c_uint) void;
extern fn glBindTexture(target: c_uint, texture: c_uint) void;
extern fn palette_text_gl_draw(
    font_data: [*]const u8,
    font_len: c_int,
    text: [*]const u8,
    text_len: c_int,
    x: f32,
    y: f32,
    font_size: f32,
    r: f32,
    g: f32,
    b: f32,
    a: f32,
    viewport_w: f32,
    viewport_h: f32,
) void;

const ui_font_bytes = @embedFile("../assets/fonts/CalSans-Regular.ttf");

const Vertex = extern struct {
    x: f32,
    y: f32,
    r: f32,
    g: f32,
    b: f32,
    a: f32,
};

const ImageVertex = extern struct {
    x: f32,
    y: f32,
    u: f32,
    v: f32,
    r: f32,
    g: f32,
    b: f32,
    a: f32,
};

pub const Renderer = struct {
    program: c_uint = 0,
    vao: c_uint = 0,
    vbo: c_uint = 0,
    viewport_uniform: c_int = -1,
    image_program: c_uint = 0,
    image_vao: c_uint = 0,
    image_vbo: c_uint = 0,
    image_viewport_uniform: c_int = -1,
    image_sampler_uniform: c_int = -1,
    vertices: std.ArrayList(Vertex) = .empty,
    image_vertices: std.ArrayList(ImageVertex) = .empty,

    pub fn init() Renderer {
        const vertex_shader = compileShader(GL_VERTEX_SHADER,
            \\#version 330 core
            \\layout (location = 0) in vec2 a_pos;
            \\layout (location = 1) in vec4 a_color;
            \\uniform vec2 u_viewport;
            \\out vec4 v_color;
            \\void main() {
            \\    vec2 ndc = vec2((a_pos.x / u_viewport.x) * 2.0 - 1.0, 1.0 - (a_pos.y / u_viewport.y) * 2.0);
            \\    gl_Position = vec4(ndc, 0.0, 1.0);
            \\    v_color = a_color;
            \\}
        );
        defer glDeleteShader(vertex_shader);

        const fragment_shader = compileShader(GL_FRAGMENT_SHADER,
            \\#version 330 core
            \\in vec4 v_color;
            \\out vec4 color;
            \\void main() {
            \\    color = v_color;
            \\}
        );
        defer glDeleteShader(fragment_shader);

        var renderer: Renderer = .{ .program = glCreateProgram() };
        glAttachShader(renderer.program, vertex_shader);
        glAttachShader(renderer.program, fragment_shader);
        glLinkProgram(renderer.program);
        renderer.viewport_uniform = glGetUniformLocation(renderer.program, "u_viewport");
        var vaos = [_]c_uint{0};
        var vbos = [_]c_uint{0};
        glGenVertexArrays(1, &vaos);
        glGenBuffers(1, &vbos);
        renderer.vao = vaos[0];
        renderer.vbo = vbos[0];

        const image_vertex_shader = compileShader(GL_VERTEX_SHADER,
            \\#version 330 core
            \\layout (location = 0) in vec2 a_pos;
            \\layout (location = 1) in vec2 a_uv;
            \\layout (location = 2) in vec4 a_color;
            \\uniform vec2 u_viewport;
            \\out vec2 v_uv;
            \\out vec4 v_color;
            \\void main() {
            \\    vec2 ndc = vec2((a_pos.x / u_viewport.x) * 2.0 - 1.0, 1.0 - (a_pos.y / u_viewport.y) * 2.0);
            \\    gl_Position = vec4(ndc, 0.0, 1.0);
            \\    v_uv = a_uv;
            \\    v_color = a_color;
            \\}
        );
        defer glDeleteShader(image_vertex_shader);

        const image_fragment_shader = compileShader(GL_FRAGMENT_SHADER,
            \\#version 330 core
            \\in vec2 v_uv;
            \\in vec4 v_color;
            \\uniform sampler2D u_texture;
            \\out vec4 color;
            \\void main() {
            \\    color = texture(u_texture, v_uv) * v_color;
            \\}
        );
        defer glDeleteShader(image_fragment_shader);

        renderer.image_program = glCreateProgram();
        glAttachShader(renderer.image_program, image_vertex_shader);
        glAttachShader(renderer.image_program, image_fragment_shader);
        glLinkProgram(renderer.image_program);
        renderer.image_viewport_uniform = glGetUniformLocation(renderer.image_program, "u_viewport");
        renderer.image_sampler_uniform = glGetUniformLocation(renderer.image_program, "u_texture");
        glGenVertexArrays(1, &vaos);
        glGenBuffers(1, &vbos);
        renderer.image_vao = vaos[0];
        renderer.image_vbo = vbos[0];
        return renderer;
    }

    pub fn deinit(self: *Renderer, allocator: std.mem.Allocator) void {
        self.vertices.deinit(allocator);
        self.image_vertices.deinit(allocator);
        if (self.vbo != 0) {
            const buffers = [_]c_uint{self.vbo};
            glDeleteBuffers(1, &buffers);
        }
        if (self.vao != 0) {
            const arrays = [_]c_uint{self.vao};
            glDeleteVertexArrays(1, &arrays);
        }
        if (self.image_vbo != 0) {
            const buffers = [_]c_uint{self.image_vbo};
            glDeleteBuffers(1, &buffers);
        }
        if (self.image_vao != 0) {
            const arrays = [_]c_uint{self.image_vao};
            glDeleteVertexArrays(1, &arrays);
        }
        if (self.program != 0) glDeleteProgram(self.program);
        if (self.image_program != 0) glDeleteProgram(self.image_program);
        self.* = undefined;
    }

    pub fn renderBatch(self: *Renderer, allocator: std.mem.Allocator, batch: *const palette.RenderBatch, framebuffer_width: f32, framebuffer_height: f32) !void {
        self.vertices.clearRetainingCapacity();
        for (batch.commands.items) |command| {
            switch (command.kind) {
                .rect => try self.appendPanel(allocator, command),
                .triangle => try self.appendTriangle(allocator, command.p0, command.p1, command.p2, command.color, command.clip),
                .cursor, .selection, .scrollbar => try self.appendRect(allocator, command.rect, command.color, command.clip),
                .text => {
                    try self.flush(framebuffer_width, framebuffer_height);
                    self.renderTextCommand(command, batch, framebuffer_width, framebuffer_height);
                },
                .image => {
                    try self.flush(framebuffer_width, framebuffer_height);
                    try self.renderImageCommand(allocator, command, framebuffer_width, framebuffer_height);
                },
            }
        }
        try self.flush(framebuffer_width, framebuffer_height);
    }

    pub fn renderBatchFallback(self: *Renderer, allocator: std.mem.Allocator, batch: *const palette.RenderBatch, framebuffer_width: f32, framebuffer_height: f32) !void {
        self.vertices.clearRetainingCapacity();
        for (batch.commands.items) |command| {
            switch (command.kind) {
                .rect, .cursor, .selection, .scrollbar => try self.appendRect(allocator, command.rect, command.color, command.clip),
                .triangle => try self.appendTriangle(allocator, command.p0, command.p1, command.p2, command.color, command.clip),
                .text => try self.appendText(allocator, command),
                .image => {
                    try self.flush(framebuffer_width, framebuffer_height);
                    try self.renderImageCommand(allocator, command, framebuffer_width, framebuffer_height);
                },
            }
        }
        try self.flush(framebuffer_width, framebuffer_height);
    }

    fn flush(self: *Renderer, framebuffer_width: f32, framebuffer_height: f32) !void {
        if (self.vertices.items.len == 0) return;

        glDisable(GL_SCISSOR_TEST);
        glDisable(GL_DEPTH_TEST);
        glDisable(GL_CULL_FACE);
        glEnable(GL_BLEND);
        glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
        glUseProgram(self.program);
        glUniform2f(self.viewport_uniform, framebuffer_width, framebuffer_height);
        glBindVertexArray(self.vao);
        glBindBuffer(GL_ARRAY_BUFFER, self.vbo);
        glBufferData(
            GL_ARRAY_BUFFER,
            @intCast(self.vertices.items.len * @sizeOf(Vertex)),
            self.vertices.items.ptr,
            GL_STREAM_DRAW,
        );
        glEnableVertexAttribArray(0);
        glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, @sizeOf(Vertex), null);
        glEnableVertexAttribArray(1);
        glVertexAttribPointer(1, 4, GL_FLOAT, GL_FALSE, @sizeOf(Vertex), @ptrFromInt(@offsetOf(Vertex, "r")));
        glDrawArrays(GL_TRIANGLES, 0, @intCast(self.vertices.items.len));
        self.vertices.clearRetainingCapacity();
    }

    fn renderImageCommand(self: *Renderer, allocator: std.mem.Allocator, command: palette.draw.Command, framebuffer_width: f32, framebuffer_height: f32) !void {
        if (command.color.a <= 0.0 or command.rect.w <= 0.0 or command.rect.h <= 0.0) return;
        if (!command.texture.valid()) {
            try self.appendImageFallback(allocator, command);
            return;
        }

        const clipped = clippedImage(command.rect, command.uv, command.clip) orelse return;
        self.image_vertices.clearRetainingCapacity();
        try self.appendImageQuad(allocator, clipped.rect, clipped.uv, command.color);
        if (self.image_vertices.items.len == 0) return;

        glDisable(GL_SCISSOR_TEST);
        glDisable(GL_DEPTH_TEST);
        glDisable(GL_CULL_FACE);
        glEnable(GL_BLEND);
        glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
        glUseProgram(self.image_program);
        glUniform2f(self.image_viewport_uniform, framebuffer_width, framebuffer_height);
        glUniform1i(self.image_sampler_uniform, 0);
        glActiveTexture(GL_TEXTURE0);
        glBindTexture(GL_TEXTURE_2D, @intCast(command.texture.value));
        glBindVertexArray(self.image_vao);
        glBindBuffer(GL_ARRAY_BUFFER, self.image_vbo);
        glBufferData(
            GL_ARRAY_BUFFER,
            @intCast(self.image_vertices.items.len * @sizeOf(ImageVertex)),
            self.image_vertices.items.ptr,
            GL_STREAM_DRAW,
        );
        glEnableVertexAttribArray(0);
        glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, @sizeOf(ImageVertex), null);
        glEnableVertexAttribArray(1);
        glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, @sizeOf(ImageVertex), @ptrFromInt(@offsetOf(ImageVertex, "u")));
        glEnableVertexAttribArray(2);
        glVertexAttribPointer(2, 4, GL_FLOAT, GL_FALSE, @sizeOf(ImageVertex), @ptrFromInt(@offsetOf(ImageVertex, "r")));
        glDrawArrays(GL_TRIANGLES, 0, @intCast(self.image_vertices.items.len));
        glBindTexture(GL_TEXTURE_2D, 0);
        self.image_vertices.clearRetainingCapacity();
    }

    fn appendImageFallback(self: *Renderer, allocator: std.mem.Allocator, command: palette.draw.Command) !void {
        try self.appendRect(allocator, command.rect, .{
            .r = command.color.r * 0.35,
            .g = command.color.g * 0.35,
            .b = command.color.b * 0.35,
            .a = command.color.a,
        }, command.clip);
    }

    fn renderTextCommands(self: *Renderer, batch: *const palette.RenderBatch, framebuffer_width: f32, framebuffer_height: f32) void {
        for (batch.commands.items) |command| {
            if (command.kind != .text) continue;
            self.renderTextCommand(command, batch, framebuffer_width, framebuffer_height);
        }
    }

    fn renderTextCommand(self: *Renderer, command: palette.draw.Command, batch: *const palette.RenderBatch, framebuffer_width: f32, framebuffer_height: f32) void {
        _ = self;
        if (command.text_run_count > 0) {
            const runs = batch.text_runs.items[command.text_run_start..][0..command.text_run_count];
            for (runs) |run| {
                drawTextSlice(run.text, run.x, run.y, run.font_size, run.color, framebuffer_width, framebuffer_height);
            }
        } else {
            drawTextSlice(command.text, command.rect.x - command.scroll.x, command.rect.y - command.scroll.y, command.font_size, command.color, framebuffer_width, framebuffer_height);
        }
    }

    fn appendPanel(self: *Renderer, allocator: std.mem.Allocator, command: palette.draw.Command) !void {
        if (command.border_color) |border_color| {
            if (border_color.a > 0.0 and command.border_width > 0.0) {
                if (command.color.a > 0.0) {
                    const inset = @max(command.border_width, 1.0);
                    try self.appendRoundedRect(allocator, command.rect, border_color, command.radius, command.clip);
                    if (command.rect.w > inset * 2.0 and command.rect.h > inset * 2.0) {
                        try self.appendRoundedRect(allocator, .{
                            .x = command.rect.x + inset,
                            .y = command.rect.y + inset,
                            .w = command.rect.w - inset * 2.0,
                            .h = command.rect.h - inset * 2.0,
                        }, command.color, @max(command.radius - inset, 0.0), command.clip);
                    }
                    return;
                }
                try self.appendBorder(allocator, command.rect, border_color, command.border_width, command.clip);
            }
        }
        if (command.color.a > 0.0) {
            try self.appendRoundedRect(allocator, command.rect, command.color, command.radius, command.clip);
        }
    }

    fn appendBorder(self: *Renderer, allocator: std.mem.Allocator, rect: palette.Rect, color: palette.Color, width: f32, clip: ?palette.Rect) !void {
        const thickness = @max(width, 1.0);
        try self.appendRect(allocator, .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = thickness }, color, clip);
        try self.appendRect(allocator, .{ .x = rect.x, .y = rect.y + rect.h - thickness, .w = rect.w, .h = thickness }, color, clip);
        try self.appendRect(allocator, .{ .x = rect.x, .y = rect.y, .w = thickness, .h = rect.h }, color, clip);
        try self.appendRect(allocator, .{ .x = rect.x + rect.w - thickness, .y = rect.y, .w = thickness, .h = rect.h }, color, clip);
    }

    fn appendText(self: *Renderer, allocator: std.mem.Allocator, command: palette.draw.Command) !void {
        if (command.text.len == 0 or command.color.a <= 0.0) return;
        const clip = command.clip;
        const glyph_w = @max(command.glyph_width, 1.0);
        const line_h = @max(command.line_height, 1.0);
        const cell_w = glyph_w / 6.0;
        const cell_h = line_h / 9.0;
        const max_columns: usize = if (command.wrap)
            @max(@as(usize, @intFromFloat(@floor(command.rect.w / glyph_w))), 1)
        else
            std.math.maxInt(usize);

        var row: usize = 0;
        var col: usize = 0;
        var index: usize = 0;
        while (index < command.text.len) {
            const byte = command.text[index];
            if (byte == '\n') {
                row += 1;
                col = 0;
                index += 1;
                continue;
            }
            if (col >= max_columns) {
                row += 1;
                col = 0;
            }

            const glyph_byte = if (byte < 0x80) byte else '?';
            const x = command.rect.x + @as(f32, @floatFromInt(col)) * glyph_w - command.scroll.x;
            const y = command.rect.y + @as(f32, @floatFromInt(row)) * line_h - command.scroll.y;
            try self.appendGlyph(allocator, x, y, cell_w, cell_h, glyph_byte, command.color, clip);

            col += 1;
            index += utf8Advance(command.text, index);
        }
    }

    fn appendGlyph(self: *Renderer, allocator: std.mem.Allocator, x: f32, y: f32, cell_w: f32, cell_h: f32, byte: u8, color: palette.Color, clip: ?palette.Rect) !void {
        const rows = glyphRows(byte);
        for (rows, 0..) |bits, row| {
            var col: usize = 0;
            while (col < 5) : (col += 1) {
                const mask: u5 = @as(u5, 1) << @intCast(4 - col);
                if ((bits & mask) == 0) continue;
                try self.appendRect(allocator, .{
                    .x = x + cell_w * (1.0 + @as(f32, @floatFromInt(col))),
                    .y = y + cell_h * (1.0 + @as(f32, @floatFromInt(row))),
                    .w = @max(cell_w * 1.12, 1.6),
                    .h = @max(cell_h * 1.06, 1.6),
                }, color, clip);
            }
        }
    }

    fn appendRect(self: *Renderer, allocator: std.mem.Allocator, rect: palette.Rect, color: palette.Color, clip: ?palette.Rect) !void {
        if (color.a <= 0.0 or rect.w <= 0.0 or rect.h <= 0.0) return;
        const r = if (clip) |clip_rect| clippedRect(rect, clip_rect) orelse return else rect;
        try self.appendQuad(allocator, r, color);
    }

    fn appendTriangle(self: *Renderer, allocator: std.mem.Allocator, p0: palette.draw.Vec2, p1: palette.draw.Vec2, p2: palette.draw.Vec2, color: palette.Color, clip: ?palette.Rect) !void {
        if (color.a <= 0.0) return;
        if (clip) |clip_rect| {
            if (!clip_rect.contains(p0) and !clip_rect.contains(p1) and !clip_rect.contains(p2)) return;
        }
        try self.vertices.appendSlice(allocator, &.{
            vertex(p0.x, p0.y, color),
            vertex(p1.x, p1.y, color),
            vertex(p2.x, p2.y, color),
        });
    }

    fn appendRoundedRect(self: *Renderer, allocator: std.mem.Allocator, rect: palette.Rect, color: palette.Color, radius: f32, clip: ?palette.Rect) !void {
        if (color.a <= 0.0 or rect.w <= 0.0 or rect.h <= 0.0) return;
        const r = if (clip) |clip_rect| clippedRect(rect, clip_rect) orelse return else rect;
        const cr = clampedRadius(r, radius);
        if (cr <= 0.5) {
            try self.appendQuad(allocator, r, color);
            return;
        }

        try self.appendQuad(allocator, .{ .x = r.x + cr, .y = r.y, .w = r.w - 2.0 * cr, .h = r.h }, color);
        try self.appendQuad(allocator, .{ .x = r.x, .y = r.y + cr, .w = cr, .h = r.h - 2.0 * cr }, color);
        try self.appendQuad(allocator, .{ .x = r.x + r.w - cr, .y = r.y + cr, .w = cr, .h = r.h - 2.0 * cr }, color);

        const segments: usize = 8;
        try self.appendCornerFan(allocator, r.x + cr, r.y + cr, cr, std.math.pi, std.math.pi * 1.5, segments, color);
        try self.appendCornerFan(allocator, r.x + r.w - cr, r.y + cr, cr, std.math.pi * 1.5, std.math.pi * 2.0, segments, color);
        try self.appendCornerFan(allocator, r.x + r.w - cr, r.y + r.h - cr, cr, 0.0, std.math.pi * 0.5, segments, color);
        try self.appendCornerFan(allocator, r.x + cr, r.y + r.h - cr, cr, std.math.pi * 0.5, std.math.pi, segments, color);
    }

    fn appendCornerFan(self: *Renderer, allocator: std.mem.Allocator, cx: f32, cy: f32, radius: f32, start_angle: f32, end_angle: f32, segments: usize, color: palette.Color) !void {
        const center = vertex(cx, cy, color);
        var index: usize = 0;
        while (index < segments) : (index += 1) {
            const t0 = @as(f32, @floatFromInt(index)) / @as(f32, @floatFromInt(segments));
            const t1 = @as(f32, @floatFromInt(index + 1)) / @as(f32, @floatFromInt(segments));
            const a0 = start_angle + (end_angle - start_angle) * t0;
            const a1 = start_angle + (end_angle - start_angle) * t1;
            try self.vertices.appendSlice(allocator, &.{
                center,
                vertex(cx + @cos(a0) * radius, cy + @sin(a0) * radius, color),
                vertex(cx + @cos(a1) * radius, cy + @sin(a1) * radius, color),
            });
        }
    }

    fn appendQuad(self: *Renderer, allocator: std.mem.Allocator, r: palette.Rect, color: palette.Color) !void {
        if (r.w <= 0.0 or r.h <= 0.0) return;
        const base = vertex(r.x, r.y, color);
        try self.vertices.appendSlice(allocator, &.{
            base,
            vertex(r.x + r.w, r.y, color),
            vertex(r.x + r.w, r.y + r.h, color),
            base,
            vertex(r.x + r.w, r.y + r.h, color),
            vertex(r.x, r.y + r.h, color),
        });
    }

    fn appendImageQuad(self: *Renderer, allocator: std.mem.Allocator, r: palette.Rect, uv: palette.Rect, color: palette.Color) !void {
        if (r.w <= 0.0 or r.h <= 0.0) return;
        const base = imageVertex(r.x, r.y, uv.x, uv.y, color);
        try self.image_vertices.appendSlice(allocator, &.{
            base,
            imageVertex(r.x + r.w, r.y, uv.x + uv.w, uv.y, color),
            imageVertex(r.x + r.w, r.y + r.h, uv.x + uv.w, uv.y + uv.h, color),
            base,
            imageVertex(r.x + r.w, r.y + r.h, uv.x + uv.w, uv.y + uv.h, color),
            imageVertex(r.x, r.y + r.h, uv.x, uv.y + uv.h, color),
        });
    }
};

fn compileShader(shader_type: c_uint, source: [:0]const u8) c_uint {
    const shader = glCreateShader(shader_type);
    const sources = [_][*:0]const u8{source.ptr};
    glShaderSource(shader, 1, &sources, null);
    glCompileShader(shader);
    return shader;
}

fn clippedRect(rect: palette.Rect, clip: palette.Rect) ?palette.Rect {
    const x0 = @max(rect.x, clip.x);
    const y0 = @max(rect.y, clip.y);
    const x1 = @min(rect.x + rect.w, clip.x + clip.w);
    const y1 = @min(rect.y + rect.h, clip.y + clip.h);
    if (x1 <= x0 or y1 <= y0) return null;
    return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
}

const ClippedImage = struct {
    rect: palette.Rect,
    uv: palette.Rect,
};

fn clippedImage(rect: palette.Rect, uv: palette.Rect, clip: ?palette.Rect) ?ClippedImage {
    const image_rect = if (clip) |clip_rect| clippedRect(rect, clip_rect) orelse return null else rect;
    const image_uv = normalizedUv(uv);
    if (image_rect.x == rect.x and image_rect.y == rect.y and image_rect.w == rect.w and image_rect.h == rect.h) {
        return .{ .rect = image_rect, .uv = image_uv };
    }

    const left = (image_rect.x - rect.x) / rect.w;
    const top = (image_rect.y - rect.y) / rect.h;
    const right = (rect.x + rect.w - (image_rect.x + image_rect.w)) / rect.w;
    const bottom = (rect.y + rect.h - (image_rect.y + image_rect.h)) / rect.h;
    return .{
        .rect = image_rect,
        .uv = .{
            .x = image_uv.x + image_uv.w * left,
            .y = image_uv.y + image_uv.h * top,
            .w = image_uv.w * (1.0 - left - right),
            .h = image_uv.h * (1.0 - top - bottom),
        },
    };
}

fn normalizedUv(uv: palette.Rect) palette.Rect {
    return if (uv.w == 0.0 and uv.h == 0.0) .{ .w = 1.0, .h = 1.0 } else uv;
}

fn drawTextSlice(text: []const u8, x: f32, y: f32, font_size: f32, color: palette.Color, framebuffer_width: f32, framebuffer_height: f32) void {
    if (text.len == 0 or color.a <= 0.0) return;
    palette_text_gl_draw(
        ui_font_bytes.ptr,
        @intCast(ui_font_bytes.len),
        text.ptr,
        @intCast(text.len),
        x,
        y,
        font_size,
        color.r,
        color.g,
        color.b,
        color.a,
        framebuffer_width,
        framebuffer_height,
    );
}

fn clampedRadius(rect: palette.Rect, radius: f32) f32 {
    return @min(@max(radius, 0.0), @min(@max(rect.w, 0.0), @max(rect.h, 0.0)) * 0.5);
}

fn vertex(x: f32, y: f32, color: palette.Color) Vertex {
    return .{ .x = x, .y = y, .r = color.r, .g = color.g, .b = color.b, .a = color.a };
}

fn imageVertex(x: f32, y: f32, u: f32, v: f32, color: palette.Color) ImageVertex {
    return .{ .x = x, .y = y, .u = u, .v = v, .r = color.r, .g = color.g, .b = color.b, .a = color.a };
}

fn utf8Advance(text: []const u8, index: usize) usize {
    return std.unicode.utf8ByteSequenceLength(text[index]) catch 1;
}

fn glyphRows(byte: u8) [7]u5 {
    const c = if (byte >= 'a' and byte <= 'z') byte - 32 else byte;
    return switch (c) {
        'A' => .{ 0b01110, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b10001 },
        'B' => .{ 0b11110, 0b10001, 0b10001, 0b11110, 0b10001, 0b10001, 0b11110 },
        'C' => .{ 0b01110, 0b10001, 0b10000, 0b10000, 0b10000, 0b10001, 0b01110 },
        'D' => .{ 0b11110, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b11110 },
        'E' => .{ 0b11111, 0b10000, 0b10000, 0b11110, 0b10000, 0b10000, 0b11111 },
        'F' => .{ 0b11111, 0b10000, 0b10000, 0b11110, 0b10000, 0b10000, 0b10000 },
        'G' => .{ 0b01110, 0b10001, 0b10000, 0b10111, 0b10001, 0b10001, 0b01110 },
        'H' => .{ 0b10001, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b10001 },
        'I' => .{ 0b11111, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b11111 },
        'J' => .{ 0b00111, 0b00010, 0b00010, 0b00010, 0b10010, 0b10010, 0b01100 },
        'K' => .{ 0b10001, 0b10010, 0b10100, 0b11000, 0b10100, 0b10010, 0b10001 },
        'L' => .{ 0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b11111 },
        'M' => .{ 0b10001, 0b11011, 0b10101, 0b10101, 0b10001, 0b10001, 0b10001 },
        'N' => .{ 0b10001, 0b11001, 0b10101, 0b10011, 0b10001, 0b10001, 0b10001 },
        'O' => .{ 0b01110, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110 },
        'P' => .{ 0b11110, 0b10001, 0b10001, 0b11110, 0b10000, 0b10000, 0b10000 },
        'Q' => .{ 0b01110, 0b10001, 0b10001, 0b10001, 0b10101, 0b10010, 0b01101 },
        'R' => .{ 0b11110, 0b10001, 0b10001, 0b11110, 0b10100, 0b10010, 0b10001 },
        'S' => .{ 0b01111, 0b10000, 0b10000, 0b01110, 0b00001, 0b00001, 0b11110 },
        'T' => .{ 0b11111, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100 },
        'U' => .{ 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110 },
        'V' => .{ 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01010, 0b00100 },
        'W' => .{ 0b10001, 0b10001, 0b10001, 0b10101, 0b10101, 0b10101, 0b01010 },
        'X' => .{ 0b10001, 0b10001, 0b01010, 0b00100, 0b01010, 0b10001, 0b10001 },
        'Y' => .{ 0b10001, 0b10001, 0b01010, 0b00100, 0b00100, 0b00100, 0b00100 },
        'Z' => .{ 0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b10000, 0b11111 },
        '0' => .{ 0b01110, 0b10001, 0b10011, 0b10101, 0b11001, 0b10001, 0b01110 },
        '1' => .{ 0b00100, 0b01100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110 },
        '2' => .{ 0b01110, 0b10001, 0b00001, 0b00010, 0b00100, 0b01000, 0b11111 },
        '3' => .{ 0b11110, 0b00001, 0b00001, 0b01110, 0b00001, 0b00001, 0b11110 },
        '4' => .{ 0b00010, 0b00110, 0b01010, 0b10010, 0b11111, 0b00010, 0b00010 },
        '5' => .{ 0b11111, 0b10000, 0b10000, 0b11110, 0b00001, 0b00001, 0b11110 },
        '6' => .{ 0b00110, 0b01000, 0b10000, 0b11110, 0b10001, 0b10001, 0b01110 },
        '7' => .{ 0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b01000, 0b01000 },
        '8' => .{ 0b01110, 0b10001, 0b10001, 0b01110, 0b10001, 0b10001, 0b01110 },
        '9' => .{ 0b01110, 0b10001, 0b10001, 0b01111, 0b00001, 0b00010, 0b01100 },
        ' ' => .{ 0, 0, 0, 0, 0, 0, 0 },
        '.' => .{ 0, 0, 0, 0, 0, 0b01100, 0b01100 },
        ',' => .{ 0, 0, 0, 0, 0, 0b01100, 0b01000 },
        ':' => .{ 0, 0b01100, 0b01100, 0, 0b01100, 0b01100, 0 },
        ';' => .{ 0, 0b01100, 0b01100, 0, 0b01100, 0b01000, 0b10000 },
        '!' => .{ 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0, 0b00100 },
        '?' => .{ 0b01110, 0b10001, 0b00001, 0b00010, 0b00100, 0, 0b00100 },
        '-' => .{ 0, 0, 0, 0b11111, 0, 0, 0 },
        '_' => .{ 0, 0, 0, 0, 0, 0, 0b11111 },
        '/' => .{ 0b00001, 0b00010, 0b00010, 0b00100, 0b01000, 0b01000, 0b10000 },
        '\\' => .{ 0b10000, 0b01000, 0b01000, 0b00100, 0b00010, 0b00010, 0b00001 },
        '+' => .{ 0, 0b00100, 0b00100, 0b11111, 0b00100, 0b00100, 0 },
        '=' => .{ 0, 0, 0b11111, 0, 0b11111, 0, 0 },
        '(' => .{ 0b00010, 0b00100, 0b01000, 0b01000, 0b01000, 0b00100, 0b00010 },
        ')' => .{ 0b01000, 0b00100, 0b00010, 0b00010, 0b00010, 0b00100, 0b01000 },
        '[' => .{ 0b01110, 0b01000, 0b01000, 0b01000, 0b01000, 0b01000, 0b01110 },
        ']' => .{ 0b01110, 0b00010, 0b00010, 0b00010, 0b00010, 0b00010, 0b01110 },
        '\'' => .{ 0b00100, 0b00100, 0b01000, 0, 0, 0, 0 },
        '"' => .{ 0b01010, 0b01010, 0, 0, 0, 0, 0 },
        '@' => .{ 0b01110, 0b10001, 0b10111, 0b10101, 0b10111, 0b10000, 0b01110 },
        '#' => .{ 0b01010, 0b01010, 0b11111, 0b01010, 0b11111, 0b01010, 0b01010 },
        '$' => .{ 0b00100, 0b01111, 0b10100, 0b01110, 0b00101, 0b11110, 0b00100 },
        '%' => .{ 0b11001, 0b11010, 0b00010, 0b00100, 0b01000, 0b01011, 0b10011 },
        '&' => .{ 0b01100, 0b10010, 0b10100, 0b01000, 0b10101, 0b10010, 0b01101 },
        '*' => .{ 0, 0b10101, 0b01110, 0b11111, 0b01110, 0b10101, 0 },
        '<' => .{ 0b00010, 0b00100, 0b01000, 0b10000, 0b01000, 0b00100, 0b00010 },
        '>' => .{ 0b01000, 0b00100, 0b00010, 0b00001, 0b00010, 0b00100, 0b01000 },
        else => .{ 0b11111, 0b10001, 0b00010, 0b00100, 0b00100, 0, 0b00100 },
    };
}
