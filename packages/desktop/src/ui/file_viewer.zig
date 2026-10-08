//! Read-only file viewer workspace pane (`WorkspacePaneRef.file`).
//!
//! Keyboard hook contract with `main.zig` (pointer input arrives through
//! `workspace_panes.zig`, which owns pane geometry):
//! - `handleKeyDown` runs for every key-down before pane-level bindings and
//!   app shortcuts. It consumes keys only while a file pane is focused (or
//!   its agent prompt popover is open); return false lets the app see them.
//! - `handleTextInput` receives SDL text input; true when the popover's
//!   instruction field consumed it.
//! - `wantsTextInput` keeps SDL text input on while that field is focused.

const std = @import("std");
const sdl = @import("zsdl3");
const runtime = @import("runtime.zig");

pub fn handleKeyDown(state: *runtime.AppState, event: *const sdl.KeyboardEvent) bool {
    _ = state;
    _ = event;
    return false;
}

pub fn handleTextInput(state: *runtime.AppState, text: []const u8) bool {
    _ = state;
    _ = text;
    return false;
}

pub fn wantsTextInput(state: *runtime.AppState) bool {
    _ = state;
    return false;
}
