//! Minimal SDL3 declarations used by powder examples and component input.

const std = @import("std");

pub const Error = error{SdlError};

pub const InitFlags = packed struct(u32) {
    __unused0: bool = false,
    __unused1: bool = false,
    __unused2: bool = false,
    __unused3: bool = false,
    audio: bool = false,
    video: bool = false,
    __unused6: bool = false,
    __unused7: bool = false,
    __unused8: bool = false,
    joystick: bool = false,
    __unused10: bool = false,
    __unused11: bool = false,
    haptic: bool = false,
    gamepad: bool = false,
    events: bool = false,
    sensor: bool = false,
    camera: bool = false,
    __unused17: u15 = 0,
};

pub const WindowId = enum(u32) { invalid = 0, _ };
pub const KeyboardId = enum(u32) { _ };
pub const MouseId = enum(u32) { _ };

pub const Window = opaque {
    pub const Flags = packed struct(u64) {
        fullscreen: bool = false,
        opengl: bool = false,
        occluded: bool = false,
        hidden: bool = false,
        borderless: bool = false,
        resizable: bool = false,
        minimized: bool = false,
        maximized: bool = false,
        mouse_grabbed: bool = false,
        input_focus: bool = false,
        mouse_focus: bool = false,
        external: bool = false,
        modal: bool = false,
        high_pixel_density: bool = false,
        mouse_capture: bool = false,
        mouse_relative_mode: bool = false,
        always_on_top: bool = false,
        utility: bool = false,
        tooltip: bool = false,
        popup_menu: bool = false,
        keyboard_grabbed: bool = false,
        __unused21: u7 = 0,
        vulkan: bool = false,
        metal: bool = false,
        transparent: bool = false,
        not_focusable: bool = false,
        __unused32: u32 = 0,
    };

    pub const create = createWindow;
    pub const destroy = destroyWindow;
    pub const setTitle = setWindowTitle;
};

pub const Renderer = opaque {
    pub const create = createRenderer;
    pub const destroy = destroyRenderer;
};

pub const FRect = extern struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
};

pub const EventType = enum(u32) {
    quit = 0x100,
    window_shown = 0x202,
    window_hidden,
    window_exposed,
    window_moved,
    window_resized,
    window_pixel_size_changed,
    window_minimized,
    window_maximized,
    window_restored,
    window_mouse_enter,
    window_mouse_leave,
    window_focus_gained,
    window_focus_lost,
    window_close_requested,
    key_down = 0x300,
    key_up,
    text_editing,
    text_input,
    mouse_motion = 0x400,
    mouse_button_down,
    mouse_button_up,
    mouse_wheel,
    _,
};

pub const Keymod = struct {
    pub const none: u16 = 0x0000;
    pub const shift: u16 = 0x0001 | 0x0002;
    pub const ctrl: u16 = 0x0040 | 0x0080;
    pub const gui: u16 = 0x0400 | 0x0800;
};

pub const Keycode = enum(u32) {
    backspace = 8,
    tab = 9,
    @"return" = 13,
    escape = 27,
    space = 32,
    delete = 127,
    a = 'a',
    insert = 0x40000049,
    home = 0x4000004a,
    pageup = 0x4000004b,
    end = 0x4000004d,
    pagedown = 0x4000004e,
    right = 0x4000004f,
    left = 0x40000050,
    down = 0x40000051,
    up = 0x40000052,
    kp_enter = 0x40000058,
    _,
};

pub const CommonEvent = extern struct {
    type: EventType,
    reserved: u32,
    timestamp: u64,
};

pub const KeyboardEvent = extern struct {
    type: EventType,
    reserved: u32,
    timestamp: u64,
    window_id: WindowId,
    which: KeyboardId,
    scancode: u32,
    key: Keycode,
    mod: u16,
    raw: u16,
    down: bool,
    repeat: bool,
};

pub const TextInputEvent = extern struct {
    type: EventType,
    reserved: u32,
    timestamp: u64,
    window_id: WindowId,
    text: [*:0]const u8,
};

pub const MouseButtonFlags = packed struct(u32) {
    left: bool = false,
    middle: bool = false,
    right: bool = false,
    x1: bool = false,
    x2: bool = false,
    __unused: u27 = 0,
};

pub const MouseMotionEvent = extern struct {
    type: EventType,
    reserved: u32,
    timestamp: u64,
    window_id: WindowId,
    which: MouseId,
    state: MouseButtonFlags,
    x: f32,
    y: f32,
    xrel: f32,
    yrel: f32,
};

pub const MouseButtonEvent = extern struct {
    type: EventType,
    reserved: u32,
    timestamp: u64,
    window_id: WindowId,
    which: MouseId,
    button: u8,
    down: bool,
    clicks: u8,
    _: u8,
    x: f32,
    y: f32,
};

pub const Event = extern union {
    type: EventType,
    common: CommonEvent,
    key: KeyboardEvent,
    text: TextInputEvent,
    motion: MouseMotionEvent,
    button: MouseButtonEvent,
    _: [128]u8,
};

pub fn init(flags: InitFlags) Error!void {
    if (!SDL_Init(flags)) return error.SdlError;
}

pub const quit = SDL_Quit;
pub const delay = SDL_Delay;

pub fn setAppMetadata(name: [:0]const u8, version: [:0]const u8, identifier: [:0]const u8) Error!void {
    if (!SDL_SetAppMetadata(name.ptr, version.ptr, identifier.ptr)) return error.SdlError;
}

pub fn createWindow(title: [:0]const u8, w: c_int, h: c_int, flags: Window.Flags) Error!*Window {
    return SDL_CreateWindow(title.ptr, w, h, flags) orelse error.SdlError;
}

pub const destroyWindow = SDL_DestroyWindow;

pub fn setWindowTitle(window: *Window, title: [:0]const u8) void {
    SDL_SetWindowTitle(window, title.ptr);
}

pub fn startTextInput(window: *Window) Error!void {
    if (!SDL_StartTextInput(window)) return error.SdlError;
}

pub fn stopTextInput(window: *Window) Error!void {
    if (!SDL_StopTextInput(window)) return error.SdlError;
}

pub const pollEvent = SDL_PollEvent;

pub fn createRenderer(window: *Window) Error!*Renderer {
    return SDL_CreateRenderer(window, null) orelse error.SdlError;
}

pub const destroyRenderer = SDL_DestroyRenderer;

pub fn setRenderDrawColor(renderer: *Renderer, r: u8, g: u8, b: u8, a: u8) Error!void {
    if (!SDL_SetRenderDrawColor(renderer, r, g, b, a)) return error.SdlError;
}

pub fn renderClear(renderer: *Renderer) Error!void {
    if (!SDL_RenderClear(renderer)) return error.SdlError;
}

pub fn renderFillRect(renderer: *Renderer, rect: FRect) Error!void {
    var mutable_rect = rect;
    if (!SDL_RenderFillRect(renderer, &mutable_rect)) return error.SdlError;
}

pub fn renderPresent(renderer: *Renderer) void {
    _ = SDL_RenderPresent(renderer);
}

extern fn SDL_Init(flags: InitFlags) bool;
extern fn SDL_Quit() void;
extern fn SDL_Delay(ms: u32) void;
extern fn SDL_SetAppMetadata(appname: [*:0]const u8, appversion: [*:0]const u8, appidentifier: [*:0]const u8) bool;
extern fn SDL_CreateWindow(title: [*:0]const u8, w: c_int, h: c_int, flags: Window.Flags) ?*Window;
extern fn SDL_DestroyWindow(window: *Window) void;
extern fn SDL_SetWindowTitle(window: *Window, title: [*:0]const u8) void;
extern fn SDL_StartTextInput(window: *Window) bool;
extern fn SDL_StopTextInput(window: *Window) bool;
extern fn SDL_PollEvent(event: ?*Event) bool;
extern fn SDL_CreateRenderer(window: *Window, name: ?[*:0]const u8) ?*Renderer;
extern fn SDL_DestroyRenderer(renderer: *Renderer) void;
extern fn SDL_SetRenderDrawColor(renderer: *Renderer, r: u8, g: u8, b: u8, a: u8) bool;
extern fn SDL_RenderClear(renderer: *Renderer) bool;
extern fn SDL_RenderFillRect(renderer: *Renderer, rect: *const FRect) bool;
extern fn SDL_RenderPresent(renderer: *Renderer) bool;

test "event union stays SDL sized" {
    try std.testing.expect(@sizeOf(Event) >= 128);
}
