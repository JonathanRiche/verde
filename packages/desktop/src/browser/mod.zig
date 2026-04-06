//! Browser runtime state shared by the native controller and desktop UI.

const std = @import("std");

pub const Controller = @import("controller.zig").Controller;
pub const Event = @import("types.zig").Event;
pub const KeyEvent = @import("input.zig").KeyEvent;
pub const MouseButton = @import("input.zig").MouseButton;
pub const MouseEvent = @import("input.zig").MouseEvent;
pub const RuntimeKind = @import("types.zig").RuntimeKind;
pub const RuntimeMode = @import("types.zig").RuntimeMode;
pub const Session = @import("session.zig").Session;
pub const SessionId = @import("types.zig").SessionId;
pub const Status = @import("types.zig").Status;
pub const PaneTexture = @import("texture.zig").PaneTexture;

pub const ADDRESS_CAPACITY: usize = 2048;
pub const SCRIPT_CAPACITY: usize = 4096;
pub const JSON_CAPACITY: usize = 2048;

pub const InspectorMode = enum {
    point,
    draw_box,
    draw_freeform,

    pub fn label(self: InspectorMode) []const u8 {
        return switch (self) {
            .point => "Point",
            .draw_box => "Draw Box",
            .draw_freeform => "Draw Freeform",
        };
    }

    pub fn jsValue(self: InspectorMode) []const u8 {
        return switch (self) {
            .point => "point",
            .draw_box => "draw-box",
            .draw_freeform => "draw-freeform",
        };
    }
};

/// Stores browser-facing UI state separately from the rest of the chat shell.
pub const State = struct {
    allocator: std.mem.Allocator,
    controller: Controller,
    controls_visible: bool = false,
    inspector_enabled: bool = false,
    inspector_mode: InspectorMode = .point,
    suppressed_eval_results: u8 = 0,
    status: Status = .hidden,
    address_storage: [ADDRESS_CAPACITY:0]u8 = std.mem.zeroes([ADDRESS_CAPACITY:0]u8),
    script_storage: [SCRIPT_CAPACITY:0]u8 = std.mem.zeroes([SCRIPT_CAPACITY:0]u8),
    json_storage: [JSON_CAPACITY:0]u8 = std.mem.zeroes([JSON_CAPACITY:0]u8),
    current_url: ?[]u8 = null,
    last_error: ?[]u8 = null,
    last_js_message: ?[]u8 = null,
    last_eval_result: ?[]u8 = null,

    /// Initializes browser state and the selected platform controller.
    pub fn init(allocator: std.mem.Allocator) !State {
        var state: State = .{
            .allocator = allocator,
            .controller = try Controller.init(allocator),
        };
        state.setScript("JSON.stringify({ title: document.title, url: location.href })");
        state.setJson("{\"type\":\"ping\"}");
        return state;
    }

    /// Releases owned strings and tears down the browser controller.
    pub fn deinit(self: *State) void {
        self.controller.deinit();
        if (self.current_url) |url| self.allocator.free(url);
        if (self.last_error) |message| self.allocator.free(message);
        if (self.last_js_message) |message| self.allocator.free(message);
        if (self.last_eval_result) |result| self.allocator.free(result);
    }

    /// Returns the mutable URL buffer used by the desktop control surface.
    pub fn addressBuffer(self: *State) [:0]u8 {
        return self.address_storage[0 .. self.address_storage.len - 1 :0];
    }

    /// Returns the current URL input as a standard slice.
    pub fn addressInput(self: *const State) []const u8 {
        return std.mem.sliceTo(self.address_storage[0..], 0);
    }

    /// Returns the mutable JavaScript input buffer used by the desktop control surface.
    pub fn scriptBuffer(self: *State) [:0]u8 {
        return self.script_storage[0 .. self.script_storage.len - 1 :0];
    }

    /// Returns the current JavaScript input as a standard slice.
    pub fn scriptInput(self: *const State) []const u8 {
        return std.mem.sliceTo(self.script_storage[0..], 0);
    }

    /// Returns the mutable JSON bridge input buffer used by the desktop control surface.
    pub fn jsonBuffer(self: *State) [:0]u8 {
        return self.json_storage[0 .. self.json_storage.len - 1 :0];
    }

    /// Returns the current JSON bridge input as a standard slice.
    pub fn jsonInput(self: *const State) []const u8 {
        return std.mem.sliceTo(self.json_storage[0..], 0);
    }

    /// Shows or hides the desktop control surface that drives the browser backend.
    pub fn setControlsVisible(self: *State, visible: bool) void {
        self.controls_visible = visible;
    }

    /// Returns whether the bundled DOM inspector should remain armed for the current browser session.
    pub fn inspectorEnabled(self: *const State) bool {
        return self.inspector_enabled;
    }

    /// Records whether the DOM inspector is currently armed in app state.
    pub fn setInspectorEnabled(self: *State, enabled: bool) void {
        self.inspector_enabled = enabled;
    }

    /// Returns the currently selected bundled inspector interaction mode.
    pub fn inspectorMode(self: *const State) InspectorMode {
        return self.inspector_mode;
    }

    /// Records the interaction mode the bundled inspector should use when armed.
    pub fn setInspectorMode(self: *State, mode: InspectorMode) void {
        self.inspector_mode = mode;
    }

    /// Suppresses one forthcoming eval result for internal browser-script dispatches.
    pub fn expectSuppressedEvalResult(self: *State) void {
        self.suppressed_eval_results = std.math.add(u8, self.suppressed_eval_results, 1) catch std.math.maxInt(u8);
    }

    /// Consumes one pending internal eval suppression when available.
    pub fn consumeSuppressedEvalResult(self: *State) bool {
        if (self.suppressed_eval_results == 0) return false;
        self.suppressed_eval_results -= 1;
        return true;
    }

    /// Clears any pending internal eval suppressions when the browser lifetime resets.
    pub fn clearSuppressedEvalResults(self: *State) void {
        self.suppressed_eval_results = 0;
    }

    /// Replaces the editable URL field with a new value.
    pub fn setAddress(self: *State, value: []const u8) void {
        @memset(&self.address_storage, 0);
        const len = @min(value.len, self.address_storage.len - 1);
        @memcpy(self.address_storage[0..len], value[0..len]);
    }

    /// Replaces the editable JavaScript field with a new value.
    pub fn setScript(self: *State, value: []const u8) void {
        @memset(&self.script_storage, 0);
        const len = @min(value.len, self.script_storage.len - 1);
        @memcpy(self.script_storage[0..len], value[0..len]);
    }

    /// Replaces the editable JSON bridge field with a new value.
    pub fn setJson(self: *State, value: []const u8) void {
        @memset(&self.json_storage, 0);
        const len = @min(value.len, self.json_storage.len - 1);
        @memcpy(self.json_storage[0..len], value[0..len]);
    }

    /// Replaces the last committed URL tracked by app state.
    pub fn setCurrentUrl(self: *State, value: ?[]const u8) !void {
        try self.replaceOptionalOwned(&self.current_url, value);
    }

    /// Replaces the last error message exposed to the desktop UI.
    pub fn setLastError(self: *State, value: ?[]const u8) !void {
        try self.replaceOptionalOwned(&self.last_error, value);
    }

    /// Replaces the last JavaScript bridge payload received from the browser runtime.
    pub fn setLastJsMessage(self: *State, value: ?[]const u8) !void {
        try self.replaceOptionalOwned(&self.last_js_message, value);
    }

    /// Replaces the last JavaScript evaluation result received from the browser runtime.
    pub fn setLastEvalResult(self: *State, value: ?[]const u8) !void {
        try self.replaceOptionalOwned(&self.last_eval_result, value);
    }

    /// Returns a short, UI-friendly label for the current browser lifecycle state.
    pub fn statusLabel(self: *const State) []const u8 {
        return switch (self.status) {
            .hidden => "Hidden",
            .opening => "Opening",
            .ready => "Ready",
            .failed => "Failed",
        };
    }

    // Centralizes optional string ownership so browser state updates stay consistent.
    fn replaceOptionalOwned(self: *State, slot: *?[]u8, value: ?[]const u8) !void {
        if (slot.*) |owned| self.allocator.free(owned);
        slot.* = if (value) |slice| try self.allocator.dupe(u8, slice) else null;
    }
};
