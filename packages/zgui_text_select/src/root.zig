const std = @import("std");

pub const LineSlice = extern struct {
    ptr: ?[*]const u8 = null,
    len: usize = 0,

    pub fn fromSlice(bytes: []const u8) LineSlice {
        return .{
            .ptr = if (bytes.len == 0) null else bytes.ptr,
            .len = bytes.len,
        };
    }

    pub fn slice(self: LineSlice) []const u8 {
        const ptr = self.ptr orelse return "";
        return ptr[0..self.len];
    }
};

pub const GetLineFn = *const fn (context: ?*anyopaque, index: usize) callconv(.c) LineSlice;
pub const GetNumLinesFn = *const fn (context: ?*anyopaque) callconv(.c) usize;

pub const Callbacks = extern struct {
    context: ?*anyopaque,
    get_line: GetLineFn,
    get_num_lines: GetNumLinesFn,
};

pub const TextSelect = opaque {
    pub fn create(callbacks: Callbacks, enable_word_wrap: bool) ?*TextSelect {
        return zgui_text_select_create(callbacks, enable_word_wrap);
    }

    pub fn destroy(self: *TextSelect) void {
        zgui_text_select_destroy(self);
    }

    pub fn update(self: *TextSelect) void {
        zgui_text_select_update(self);
    }

    pub fn hasSelection(self: *TextSelect) bool {
        return zgui_text_select_has_selection(self);
    }

    pub fn copy(self: *TextSelect) void {
        zgui_text_select_copy(self);
    }

    pub fn selectAll(self: *TextSelect) void {
        zgui_text_select_select_all(self);
    }

    pub fn clearSelection(self: *TextSelect) void {
        zgui_text_select_clear_selection(self);
    }
};

extern fn zgui_text_select_create(callbacks: Callbacks, enable_word_wrap: bool) ?*TextSelect;
extern fn zgui_text_select_destroy(selector: *TextSelect) void;
extern fn zgui_text_select_update(selector: *TextSelect) void;
extern fn zgui_text_select_has_selection(selector: *TextSelect) bool;
extern fn zgui_text_select_copy(selector: *TextSelect) void;
extern fn zgui_text_select_select_all(selector: *TextSelect) void;
extern fn zgui_text_select_clear_selection(selector: *TextSelect) void;

test "bindings compile" {
    std.testing.refAllDecls(@This());
}
