//! Window-system platform layer. Comptime-selects the backend: Wayland (Linux/BSD),
//! AppKit (macOS) or Win32 (Windows). Every backend exports the same App/Window/Event API.
//!
//! See README.md in this directory for the API overview and protocol coverage.
const builtin = @import("builtin");

pub const present = @import("present.zig");
pub const paths = @import("paths.zig");
/// SDL_GetPrefPath-compatible per-user data directory (see `paths.prefPath`).
pub const prefPath = paths.prefPath;
/// Win32 scancode <-> evdev tables (pure; usable on any host).
pub const windows_keymap = @import("windows/keymap.zig");

const backend = switch (builtin.os.tag) {
    .linux, .freebsd, .openbsd, .netbsd, .dragonfly => @import("wayland/backend.zig"),
    .macos => @import("macos/backend.zig"),
    .windows => @import("windows/backend.zig"),
    else => @compileError("palette platform: no backend for " ++ @tagName(builtin.os.tag)),
};

/// The Objective-C runtime shim (macOS only; for hosts and tests that talk to AppKit).
pub const objc = if (builtin.os.tag == .macos) @import("macos/objc.zig") else struct {};

pub const App = backend.App;
pub const Window = backend.Window;
pub const AppOptions = backend.AppOptions;
pub const WindowOptions = backend.WindowOptions;
pub const Decorations = backend.Decorations;
pub const CursorShape = backend.CursorShape;
pub const Size = backend.Size;
pub const Rect = backend.Rect;
pub const NativeHandles = backend.NativeHandles;
pub const WindowStates = backend.WindowStates;
pub const GlobalInfo = backend.GlobalInfo;
pub const Error = backend.Error;
pub const SystemTheme = backend.SystemTheme;

test {
    // The pure macOS and Win32 translation tables and IME logic run on every host; the
    // Wayland files use Linux syscalls (socketpairs, memfds) and only build on Unix.
    _ = @import("paths.zig");
    _ = @import("macos/objc.zig");
    _ = @import("macos/keys.zig");
    _ = @import("macos/text_input.zig");
    _ = @import("macos/backend.zig");
    _ = @import("windows/win32.zig");
    _ = @import("windows/keymap.zig");
    _ = @import("windows/translate.zig");
    if (builtin.os.tag != .macos and builtin.os.tag != .windows) {
        _ = @import("wayland/wire.zig");
        _ = @import("wayland/keysym.zig");
        _ = @import("wayland/xkb.zig");
        _ = @import("wayland/input.zig");
        _ = @import("wayland/selection.zig");
    }
    _ = backend;
    @import("std").testing.refAllDecls(backend.App);
    @import("std").testing.refAllDecls(backend.Window);
}
