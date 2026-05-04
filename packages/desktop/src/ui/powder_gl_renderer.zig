const std = @import("std");
const powder = @import("powder");

const GL_FALSE: u8 = 0;
const GL_FLOAT: c_uint = 0x1406;
const GL_TRIANGLES: c_uint = 0x0004;
const GL_ARRAY_BUFFER: c_uint = 0x8892;
const GL_STREAM_DRAW: c_uint = 0x88E0;
const GL_VERTEX_SHADER: c_uint = 0x8B31;
const GL_FRAGMENT_SHADER: c_uint = 0x8B30;
const GL_BLEND: c_uint = 0x0BE2;
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
extern fn glGenVertexArrays(n: c_int, arrays: [*]c_uint) void;
extern fn glBindVertexArray(array: c_uint) void;
extern fn glDeleteVertexArrays(n: c_int, arrays: [*]const c_uint) void;
extern fn glGenBuffers(n: c_int, buffers: [*]c_uint) void;
extern fn glBindBuffer(target: c_uint, buffer: c_uint) void;
extern fn glBufferData(target: c_uint, size: isize, data: ?*const anyopaque, usage: c_uint) void;
extern fn glDeleteBuffers(n: c_int, buffers: [*]const c_uint) void;
extern fn glEnable(cap: c_uint) void;
extern fn glBlendFunc(sfactor: c_uint, dfactor: c_uint) void;
extern fn glEnableVertexAttribArray(index: c_uint) void;
extern fn glVertexAttribPointer(index: c_uint, size: c_int, type: c_uint, normalized: u8, stride: c_int, pointer: ?*const anyopaque) void;
extern fn glDrawArrays(mode: c_uint, first: c_int, count: c_int) void;

const Vertex = extern struct {
    x: f32,
    y: f32,
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
    vertices: std.ArrayList(Vertex) = .empty,

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
        return renderer;
    }

    pub fn deinit(self: *Renderer, allocator: std.mem.Allocator) void {
        self.vertices.deinit(allocator);
        if (self.vbo != 0) {
            const buffers = [_]c_uint{self.vbo};
            glDeleteBuffers(1, &buffers);
        }
        if (self.vao != 0) {
            const arrays = [_]c_uint{self.vao};
            glDeleteVertexArrays(1, &arrays);
        }
        if (self.program != 0) glDeleteProgram(self.program);
        self.* = undefined;
    }

    pub fn renderBatch(self: *Renderer, allocator: std.mem.Allocator, batch: *const powder.RenderBatch, framebuffer_width: f32, framebuffer_height: f32) !void {
        self.vertices.clearRetainingCapacity();
        for (batch.commands.items) |command| {
            switch (command.kind) {
                .rect, .cursor, .selection, .scrollbar => try self.appendRect(allocator, command.rect, command.color, command.clip),
                .text => try self.appendText(allocator, command),
            }
        }
        if (self.vertices.items.len == 0) return;

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
    }

    fn appendText(self: *Renderer, allocator: std.mem.Allocator, command: powder.draw.Command) !void {
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

    fn appendGlyph(self: *Renderer, allocator: std.mem.Allocator, x: f32, y: f32, cell_w: f32, cell_h: f32, byte: u8, color: powder.Color, clip: ?powder.Rect) !void {
        const rows = glyphRows(byte);
        for (rows, 0..) |bits, row| {
            var col: usize = 0;
            while (col < 5) : (col += 1) {
                const mask: u5 = @as(u5, 1) << @intCast(4 - col);
                if ((bits & mask) == 0) continue;
                try self.appendRect(allocator, .{
                    .x = x + cell_w * (1.0 + @as(f32, @floatFromInt(col))),
                    .y = y + cell_h * (1.0 + @as(f32, @floatFromInt(row))),
                    .w = @max(cell_w * 0.82, 1.0),
                    .h = @max(cell_h * 0.82, 1.0),
                }, color, clip);
            }
        }
    }

    fn appendRect(self: *Renderer, allocator: std.mem.Allocator, rect: powder.Rect, color: powder.Color, clip: ?powder.Rect) !void {
        if (color.a <= 0.0 or rect.w <= 0.0 or rect.h <= 0.0) return;
        const r = if (clip) |clip_rect| clippedRect(rect, clip_rect) orelse return else rect;
        const base = Vertex{ .x = r.x, .y = r.y, .r = color.r, .g = color.g, .b = color.b, .a = color.a };
        try self.vertices.appendSlice(allocator, &.{
            base,
            .{ .x = r.x + r.w, .y = r.y, .r = color.r, .g = color.g, .b = color.b, .a = color.a },
            .{ .x = r.x + r.w, .y = r.y + r.h, .r = color.r, .g = color.g, .b = color.b, .a = color.a },
            base,
            .{ .x = r.x + r.w, .y = r.y + r.h, .r = color.r, .g = color.g, .b = color.b, .a = color.a },
            .{ .x = r.x, .y = r.y + r.h, .r = color.r, .g = color.g, .b = color.b, .a = color.a },
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

fn clippedRect(rect: powder.Rect, clip: powder.Rect) ?powder.Rect {
    const x0 = @max(rect.x, clip.x);
    const y0 = @max(rect.y, clip.y);
    const x1 = @min(rect.x + rect.w, clip.x + clip.w);
    const y1 = @min(rect.y + rect.h, clip.y + clip.h);
    if (x1 <= x0 or y1 <= y0) return null;
    return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
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
