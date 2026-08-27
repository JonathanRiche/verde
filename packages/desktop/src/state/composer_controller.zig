//! Composer widget, focus, picker, attachment-hit, and run-config state.

const std = @import("std");
const palette = @import("palette");
const provider_models = @import("provider_models.zig");

const Provider = provider_models.Provider;

pub fn State(
    comptime ComposerPrompt: type,
    comptime ModelPicker: type,
    comptime ModelPickerEntry: type,
    comptime DirectoryPicker: type,
    comptime DirectoryPickerEntry: type,
    comptime RuntimePicker: type,
    comptime RunStepper: type,
    comptime RunStepperContext: type,
) type {
    return struct {
        focused: bool = false,
        bang_history_message_index: ?usize = null,
        input_nonce: u32 = 0,
        input_bounds_valid: bool = false,
        input_min: [2]f32 = .{ 0.0, 0.0 },
        input_max: [2]f32 = .{ 0.0, 0.0 },
        send_bounds_valid: bool = false,
        send_min: [2]f32 = .{ 0.0, 0.0 },
        send_max: [2]f32 = .{ 0.0, 0.0 },
        send_pressed: bool = false,
        send_hovered: bool = false,
        draft_image_clear_valid: bool = false,
        draft_image_clear_rect: palette.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
        draft_image_clear_index: usize = 0,
        draft_image_clear_count: usize = 0,
        draft_image_clear_rects: [16]palette.Rect = [_]palette.Rect{.{ .x = 0, .y = 0, .w = 0, .h = 0 }} ** 16,
        draft_image_clear_indices: [16]usize = [_]usize{0} ** 16,
        overlay_scroll_y: f32 = 0.0,
        overlay_follow_cursor: bool = true,
        overlay_last_cursor_pos: usize = 0,
        overlay_last_draft_len: usize = 0,
        toolbar_overlay_valid: bool = false,
        toolbar_directory_rect: palette.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
        toolbar_runtime_rect: palette.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
        toolbar_model_rect: palette.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
        toolbar_reasoning_rect: palette.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
        toolbar_fast_rect: palette.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
        toolbar_access_rect: palette.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
        composer: ComposerPrompt,
        model_picker: ModelPicker,
        model_picker_entries: std.ArrayList(ModelPickerEntry) = .empty,
        directory_picker: DirectoryPicker,
        directory_picker_entries: std.ArrayList(DirectoryPickerEntry) = .empty,
        /// Local/Remote runtime chooser on the directory strip; Remote is a
        /// reserved "coming soon" row until cloud/remote daemons ship.
        runtime_picker: RuntimePicker,
        /// Set while the shared folder dialog was opened from the directory
        /// picker's Browse row, so `pollPicker` routes the result to the
        /// current thread instead of the workspace importer.
        browse_for_chat_directory: bool = false,
        /// Lazily resolved absolute paths behind the Home / Scratch rows and
        /// the matching pill labels.
        home_path: ?[]const u8 = null,
        scratch_path: ?[]const u8 = null,
        run_config_open: bool = false,
        popover_restore_focus: bool = false,
        run_config_focused_row: usize = 0,
        run_config_last_tick_ms: i64 = 0,
        run_steppers: [3]RunStepper,
        run_stepper_contexts: [3]RunStepperContext = .{ .{}, .{}, .{} },
        picker_provider: ?Provider = null,
        slash_selected: usize = 0,
        locked_model_picker_open: bool = false,

        const Self = @This();

        pub fn init() Self {
            return .{
                .composer = ComposerPrompt.init(),
                .model_picker = ModelPicker.init(0),
                .directory_picker = DirectoryPicker.init(0),
                .runtime_picker = RuntimePicker.init(0),
                .run_steppers = .{ RunStepper.init(0), RunStepper.init(2), RunStepper.init(2) },
            };
        }
    };
}

pub fn requestComposerFocus(self: anytype) void {
    _ = self.acknowledgeFocusedChatCompletion();
    restoreComposerFocus(self);
}

pub fn restoreComposerFocus(self: anytype) void {
    self.composer_controller.composer.focused = true;
    self.composer_controller.focused = true;
    self.terminal_controller.focused = false;
    self.unfocusBrowserPane();
    self.browser_controller.address_focused = false;
}
