const std = @import("std");
const zgui = @import("zgui");

const chat_threads = @import("../chat/threads.zig");
const native_state = @import("../state.zig");
const colors = @import("colors.zig");
const runtime = @import("runtime.zig");
const ui_theme = @import("theme.zig");

const AccessMode = native_state.AccessMode;
const AppState = native_state.AppState;
const ChatThread = native_state.ChatThread;
const ModelOption = native_state.ModelOption;
const Provider = native_state.Provider;
const ReasoningOption = native_state.ReasoningOption;
const CODEX_MODEL_OPTIONS = native_state.CODEX_MODEL_OPTIONS;
const CODEX_REASONING_OPTIONS = native_state.CODEX_REASONING_OPTIONS;
const DEFAULT_CODEX_MODEL = native_state.DEFAULT_CODEX_MODEL;
const DEFAULT_OPENCODE_MODEL = native_state.DEFAULT_OPENCODE_MODEL;
const OPENCODE_MODEL_OPTIONS = native_state.OPENCODE_MODEL_OPTIONS;
const COMPOSER_PROVIDER_OPTIONS = [_]Provider{ .codex, .opencode };

pub fn render(state: *AppState) void {
    const thread = state.currentThreadMutable();
    const provider_locked = thread.committed;

    const transparent = colors.rgba(0, 0, 0, 0);
    const picker_frame_bg = colors.rgba(36, 38, 44, 255);
    const picker_text_color = colors.rgba(160, 164, 180, 255);
    const picker_hover_bg = colors.rgba(50, 52, 60, 255);
    const picker_active_bg = colors.rgba(58, 60, 70, 255);
    const picker_popup_bg = colors.rgba(26, 27, 32, 255);
    const separator_color = colors.rgba(60, 62, 72, 255);
    const chip_spacing = ui_theme.scaledUi(8.0);
    const base_padding_x = ui_theme.scaledUi(12.0);
    const base_padding_y = ui_theme.scaledUi(7.0);
    const provider_logo_gap = ui_theme.scaledUi(8.0);
    const popup_padding = ui_theme.scaledUi(10.0);
    const provider_row_height = ui_theme.scaledUi(38.0);
    const model_row_height = ui_theme.scaledUi(34.0);
    const provider_panel_width = composerProviderPanelWidth(state, provider_row_height);
    const model_panel_width = ui_theme.scaledUi(214.0);
    const provider_row_text_padding = 0.0;

    zgui.pushStyleVar1f(.{ .idx = .frame_rounding, .v = ui_theme.scaledUi(11.0) });
    zgui.pushStyleVar2f(.{ .idx = .frame_padding, .v = .{ base_padding_x, base_padding_y } });
    zgui.pushStyleColor4f(.{ .idx = .frame_bg, .c = picker_frame_bg });
    zgui.pushStyleColor4f(.{ .idx = .frame_bg_hovered, .c = picker_hover_bg });
    zgui.pushStyleColor4f(.{ .idx = .frame_bg_active, .c = picker_active_bg });
    zgui.pushStyleColor4f(.{ .idx = .window_bg, .c = picker_popup_bg });
    zgui.pushStyleColor4f(.{ .idx = .popup_bg, .c = picker_popup_bg });
    zgui.pushStyleColor4f(.{ .idx = .header, .c = colors.rgba(42, 44, 52, 255) });
    zgui.pushStyleColor4f(.{ .idx = .header_hovered, .c = colors.rgba(52, 54, 64, 255) });
    zgui.pushStyleColor4f(.{ .idx = .header_active, .c = colors.rgba(58, 60, 70, 255) });
    zgui.pushStyleColor4f(.{ .idx = .text, .c = picker_text_color });
    defer {
        zgui.popStyleColor(.{ .count = 9 });
        zgui.popStyleVar(.{ .count = 2 });
    }

    const model_preview = chat_threads.selectedModelLabel(ModelOption, thread, OPENCODE_MODEL_OPTIONS[0..], CODEX_MODEL_OPTIONS[0..]);
    const provider_logo_size = providerLogoSize(state, thread.provider, zgui.getFrameHeight() - ui_theme.scaledUi(10.0));
    const popup_width = if (provider_locked)
        model_panel_width
    else
        provider_panel_width + popup_padding * 2.0;
    const popup_height = if (provider_locked)
        popup_padding * 2.0 + modelRowPanelHeight(thread.provider, model_row_height)
    else
        popup_padding * 2.0 + provider_row_height * @as(f32, @floatFromInt(COMPOSER_PROVIDER_OPTIONS.len));
    const combo_preview_pos = zgui.getCursorScreenPos();
    const combo_preview_width = composerPickerTextWidth(model_preview) + provider_logo_size[0] + provider_logo_gap + ui_theme.scaledUi(52.0);
    const combo_preview_height = zgui.getFrameHeight();
    const combo_draw_list = zgui.getWindowDrawList();
    zgui.setNextWindowSize(.{ .w = popup_width, .h = popup_height });
    zgui.pushStyleVar2f(.{ .idx = .frame_padding, .v = .{
        base_padding_x + provider_logo_size[0] + provider_logo_gap,
        base_padding_y,
    } });
    zgui.pushStyleVar1f(.{ .idx = .window_rounding, .v = ui_theme.scaledUi(16.0) });
    zgui.pushStyleVar1f(.{ .idx = .child_rounding, .v = ui_theme.scaledUi(12.0) });
    zgui.pushStyleVar2f(.{ .idx = .window_padding, .v = .{
        if (provider_locked) ui_theme.scaledUi(4.0) else popup_padding,
        popup_padding,
    } });
    zgui.setNextItemWidth(combo_preview_width);
    const model_combo_open = zgui.beginCombo("##model-provider-picker", .{
        .preview_value = "",
        .flags = .{ .popup_align_left = true, .height_large = true },
    });
    drawModelPreviewInRect(combo_draw_list, state, thread.provider, model_preview, combo_preview_pos, combo_preview_width, combo_preview_height, base_padding_x);
    zgui.popStyleVar(.{ .count = 4 });
    if (model_combo_open) {
        defer zgui.endCombo();

        if (provider_locked) {
            state.composer_picker_provider = null;
            zgui.pushStyleVar2f(.{ .idx = .item_spacing, .v = .{ 0.0, 0.0 } });
            defer zgui.popStyleVar(.{ .count = 1 });

            const active_model_ref = if (thread.model_ref != null) thread.model_ref.? else defaultModelRef(thread.provider);
            for (chat_threads.modelOptions(ModelOption, thread.provider, OPENCODE_MODEL_OPTIONS[0..], CODEX_MODEL_OPTIONS[0..]), 0..) |option, index| {
                zgui.pushIntId(@intCast(index));
                const is_selected = if (option.value) |value|
                    std.mem.eql(u8, active_model_ref, value)
                else
                    false;
                const clicked = zgui.invisibleButton("##locked-model-row", .{
                    .w = zgui.getWindowWidth() - ui_theme.scaledUi(8.0),
                    .h = model_row_height,
                });
                const is_hovered = zgui.isItemHovered(.{});
                if (clicked) {
                    setThreadModelRef(state, thread, option.value);
                    zgui.closeCurrentPopup();
                }
                drawLockedModelRowForLastItem(option.label, is_selected, is_hovered);
                zgui.popId();
            }
        } else {
            var active_provider: ?Provider = state.composer_picker_provider;
            if (active_provider != null and active_provider != .codex and active_provider != .opencode) {
                active_provider = null;
            }
            const panel_height = provider_row_height * @as(f32, @floatFromInt(COMPOSER_PROVIDER_OPTIONS.len));
            const provider_panel_shift = ui_theme.scaledUi(10.0);
            const provider_child_width = provider_panel_width + popup_padding + provider_panel_shift;

            state.composer_picker_provider = active_provider;

            zgui.pushStyleVar2f(.{ .idx = .item_spacing, .v = .{ 0.0, 0.0 } });
            zgui.pushStyleVar2f(.{ .idx = .frame_padding, .v = .{ provider_row_text_padding, ui_theme.scaledUi(9.0) } });
            zgui.pushStyleVar2f(.{ .idx = .window_padding, .v = .{ 0.0, 0.0 } });
            zgui.pushStyleColor4f(.{ .idx = .child_bg, .c = colors.rgba(0, 0, 0, 0) });
            defer zgui.popStyleVar(.{ .count = 3 });
            defer zgui.popStyleColor(.{ .count = 1 });

            const popup_cursor = zgui.getCursorPos();
            zgui.setCursorPos(.{ popup_cursor[0] - popup_padding - provider_panel_shift, popup_cursor[1] });
            const popup_origin = zgui.getCursorScreenPos();
            _ = zgui.beginChild("##provider-panel", .{
                .w = provider_child_width,
                .h = panel_height,
                .child_flags = .{ .border = false },
                .window_flags = .{ .no_saved_settings = true, .no_scrollbar = true, .no_scroll_with_mouse = true },
            });
            for (COMPOSER_PROVIDER_OPTIONS) |candidate| {
                zgui.pushIntId(@intFromEnum(candidate));
                const is_active = active_provider != null and candidate == active_provider.?;
                const clicked = zgui.invisibleButton("##provider-row", .{
                    .w = zgui.getWindowWidth(),
                    .h = provider_row_height,
                });
                const is_hovered = zgui.isItemHovered(.{});
                if (clicked) {
                    active_provider = candidate;
                    state.composer_picker_provider = candidate;
                }
                drawProviderRowForLastItem(state, candidate, is_active, is_hovered);
                if (is_hovered) {
                    active_provider = candidate;
                    state.composer_picker_provider = candidate;
                }
                zgui.popId();
            }
            zgui.endChild();

            if (active_provider) |provider| {
                const provider_index = composerProviderIndex(provider);
                renderComposerModelFlyout(state, thread, provider, popup_origin, popup_padding, provider_child_width, provider_index, model_panel_width, model_row_height);
            }
        }
    } else {
        state.composer_picker_provider = null;
    }

    zgui.sameLine(.{ .spacing = chip_spacing });
    zgui.textColored(separator_color, "|", .{});

    zgui.sameLine(.{ .spacing = chip_spacing });
    const reasoning_preview = chat_threads.selectedReasoningLabel(ReasoningOption, thread, CODEX_REASONING_OPTIONS[0..]);
    var reasoning_buf = std.mem.zeroes([80:0]u8);
    const reasoning_label = std.fmt.bufPrintZ(&reasoning_buf, "{s} v", .{reasoning_preview}) catch "Reasoning v";
    zgui.setNextItemWidth(composerPickerTextWidth(reasoning_preview) + ui_theme.scaledUi(36.0));
    if (zgui.beginCombo("##reasoning-picker", .{
        .preview_value = reasoning_label,
        .flags = .{ .no_arrow_button = true },
    })) {
        defer zgui.endCombo();
        for (CODEX_REASONING_OPTIONS) |option| {
            const is_selected = if (option.value) |value|
                thread.reasoning_effort != null and thread.reasoning_effort.? == value
            else
                thread.reasoning_effort == null;
            var row_buf = std.mem.zeroes([96:0]u8);
            const row_label = comboRowLabel(&row_buf, option.label, is_selected);
            if (zgui.selectable(row_label, .{ .selected = is_selected, .h = 28.0 })) {
                thread.reasoning_effort = option.value;
                if (thread.provider_thread_id) |thread_id| {
                    state.allocator.free(thread_id);
                }
                thread.provider_thread_id = null;
                state.markDirty();
            }
        }
    }

    if (thread.provider == .codex) {
        zgui.sameLine(.{ .spacing = chip_spacing });
        zgui.textColored(separator_color, "|", .{});

        zgui.sameLine(.{ .spacing = chip_spacing });
        zgui.pushStyleColor4f(.{ .idx = .button, .c = transparent });
        zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = picker_hover_bg });
        zgui.pushStyleColor4f(.{ .idx = .button_active, .c = picker_hover_bg });
        const fast_label: [:0]const u8 = if (thread.fast_mode == .on) "Fast" else "Default";
        if (zgui.button(fast_label, .{ .w = 0.0, .h = 0.0 })) {
            thread.fast_mode = if (thread.fast_mode == .on) .off else .on;
            state.markDirty();
        }
        zgui.popStyleColor(.{ .count = 3 });

        zgui.sameLine(.{ .spacing = chip_spacing });
        zgui.textColored(separator_color, "|", .{});
    }

    zgui.sameLine(.{ .spacing = chip_spacing });
    zgui.pushStyleColor4f(.{ .idx = .button, .c = transparent });
    zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = picker_hover_bg });
    zgui.pushStyleColor4f(.{ .idx = .button_active, .c = picker_hover_bg });
    const access_label: [:0]const u8 = chat_threads.accessModeLabel(thread.access_mode);
    if (zgui.button(access_label, .{ .w = 0.0, .h = 0.0 })) {
        const new_mode: AccessMode = if (thread.access_mode == .full_access) .supervised else .full_access;
        if (thread.access_mode != new_mode) {
            thread.access_mode = new_mode;
            if (thread.provider_thread_id) |thread_id| {
                state.allocator.free(thread_id);
            }
            thread.provider_thread_id = null;
            state.markDirty();
        }
    }
    zgui.popStyleColor(.{ .count = 3 });
}

fn composerPickerTextWidth(label: []const u8) f32 {
    return zgui.calcTextSize(label, .{})[0];
}

fn providerLogoTexture(state: *AppState, provider: Provider) ?native_state.CachedImageTexture {
    return switch (provider) {
        .opencode => state.opencode_logo_texture,
        .codex => state.codex_logo_texture,
    };
}

fn providerLogoUvBounds(provider: Provider) struct { min: [2]f32, max: [2]f32 } {
    return switch (provider) {
        .codex => .{
            .min = .{ 118.0 / 721.0, 120.0 / 721.0 },
            .max = .{ 603.0 / 721.0, 601.0 / 721.0 },
        },
        .opencode => .{
            .min = .{ 0.0, 0.0 },
            .max = .{ 1.0, 1.0 },
        },
    };
}

fn providerLogoSize(state: *AppState, provider: Provider, target_height: f32) [2]f32 {
    if (providerLogoTexture(state, provider)) |_| {
        const safe_height = @max(target_height * providerLogoScale(provider), ui_theme.scaledUi(14.0));
        const uv_bounds = providerLogoUvBounds(provider);
        const visible_width = uv_bounds.max[0] - uv_bounds.min[0];
        const visible_height = uv_bounds.max[1] - uv_bounds.min[1];
        const aspect_ratio = visible_width / visible_height;
        return .{ safe_height * aspect_ratio, safe_height };
    }
    return .{ 0.0, 0.0 };
}

fn drawModelPreviewInRect(
    draw_list: zgui.DrawList,
    state: *AppState,
    provider: Provider,
    label: []const u8,
    item_min: [2]f32,
    item_width: f32,
    item_height: f32,
    left_padding: f32,
) void {
    const text_size = zgui.calcTextSize(label, .{});
    const icon_slot_width = providerLogoSlotWidth(state, item_height);
    const text_pos = .{
        item_min[0] + left_padding + icon_slot_width + ui_theme.scaledUi(6.0),
        item_min[1] + (item_height - text_size[1]) * 0.5,
    };
    drawProviderLogoInRect(draw_list, state, provider, item_min, item_height, left_padding);
    draw_list.addTextUnformatted(text_pos, zgui.colorConvertFloat4ToU32(ui_theme.COLOR_TEXT_MUTED), label);
    const chevron_center_y = item_min[1] + item_height * 0.5;
    const chevron_x = item_min[0] + item_width - ui_theme.scaledUi(16.0);
    drawChevron(draw_list, chevron_x, chevron_center_y, ui_theme.COLOR_TEXT_SUBTLE);
}

fn drawProviderRowForLastItem(state: *AppState, provider: Provider, is_active: bool, is_hovered: bool) void {
    const item_min = zgui.getItemRectMin();
    const item_max = zgui.getItemRectMax();
    const item_height = item_max[1] - item_min[1];
    const draw_list = zgui.getWindowDrawList();
    const window_pos = zgui.getWindowPos();
    const row_min_x = window_pos[0] + ui_theme.scaledUi(2.0);
    const row_max_x = window_pos[0] + zgui.getWindowWidth() - ui_theme.scaledUi(2.0);
    const label = chat_threads.providerLabel(provider);
    const text_size = zgui.calcTextSize(label, .{});
    const left_padding = 0.0;
    const logo_size = providerLogoSize(state, provider, item_height - ui_theme.scaledUi(10.0));
    const row_bg = if (is_active)
        colors.rgba(52, 54, 64, 255)
    else if (is_hovered)
        colors.rgba(42, 44, 52, 255)
    else
        null;
    if (row_bg) |bg| {
        draw_list.addRectFilled(.{
            .pmin = .{ row_min_x, item_min[1] },
            .pmax = .{ row_max_x, item_max[1] },
            .col = zgui.colorConvertFloat4ToU32(bg),
            .rounding = ui_theme.scaledUi(8.0),
        });
    }
    if (providerLogoTexture(state, provider)) |cached| {
        const uv_bounds = providerLogoUvBounds(provider);
        const logo_min = .{
            row_min_x + left_padding,
            item_min[1] + (item_height - logo_size[1]) * 0.5 + providerLogoYOffset(provider),
        };
        draw_list.addImage(runtime.textureRefFromGlId(cached.texture_id), .{
            .pmin = logo_min,
            .pmax = .{ logo_min[0] + logo_size[0], logo_min[1] + logo_size[1] },
            .uvmin = uv_bounds.min,
            .uvmax = uv_bounds.max,
        });
    }
    const text_pos = .{
        row_min_x + left_padding + logo_size[0] + ui_theme.scaledUi(3.0),
        item_min[1] + (item_height - text_size[1]) * 0.5,
    };
    draw_list.addTextUnformatted(text_pos, zgui.colorConvertFloat4ToU32(if (is_active) ui_theme.COLOR_WHITE else ui_theme.COLOR_TEXT_MUTED), label);
    drawChevron(draw_list, row_max_x - ui_theme.scaledUi(14.0), item_min[1] + item_height * 0.5, if (is_active) ui_theme.COLOR_WHITE else ui_theme.COLOR_TEXT_SUBTLE);
}

fn drawFlyoutModelRowForLastItem(label: []const u8, is_selected: bool, is_hovered: bool) void {
    const item_min = zgui.getItemRectMin();
    const item_max = zgui.getItemRectMax();
    const item_height = item_max[1] - item_min[1];
    const draw_list = zgui.getWindowDrawList();
    const window_pos = zgui.getWindowPos();
    const row_min_x = window_pos[0] + ui_theme.scaledUi(2.0);
    const row_max_x = window_pos[0] + zgui.getWindowWidth() - ui_theme.scaledUi(2.0);
    const text_size = zgui.calcTextSize(label, .{});
    const row_bg = if (is_selected)
        colors.rgba(52, 54, 64, 255)
    else if (is_hovered)
        colors.rgba(42, 44, 52, 255)
    else
        null;
    if (row_bg) |bg| {
        draw_list.addRectFilled(.{
            .pmin = .{ row_min_x, item_min[1] },
            .pmax = .{ row_max_x, item_max[1] },
            .col = zgui.colorConvertFloat4ToU32(bg),
            .rounding = ui_theme.scaledUi(8.0),
        });
    }
    const text_pos = .{
        row_min_x + ui_theme.scaledUi(22.0),
        item_min[1] + (item_height - text_size[1]) * 0.5,
    };
    draw_list.addTextUnformatted(text_pos, zgui.colorConvertFloat4ToU32(if (is_selected) ui_theme.COLOR_WHITE else ui_theme.COLOR_TEXT_MUTED), label);
    if (is_selected) drawCheckForCustomRow(ui_theme.COLOR_WHITE, row_min_x + ui_theme.scaledUi(12.0));
}

fn drawLockedModelRowForLastItem(label: []const u8, is_selected: bool, is_hovered: bool) void {
    const item_min = zgui.getItemRectMin();
    const item_max = zgui.getItemRectMax();
    const item_height = item_max[1] - item_min[1];
    const draw_list = zgui.getWindowDrawList();
    const window_pos = zgui.getWindowPos();
    const row_min_x = window_pos[0] + ui_theme.scaledUi(4.0);
    const row_max_x = window_pos[0] + zgui.getWindowWidth() - ui_theme.scaledUi(4.0);
    const text_size = zgui.calcTextSize(label, .{});
    const row_bg = if (is_selected)
        colors.rgba(52, 54, 64, 255)
    else if (is_hovered)
        colors.rgba(42, 44, 52, 255)
    else
        null;
    if (row_bg) |bg| {
        draw_list.addRectFilled(.{
            .pmin = .{ row_min_x, item_min[1] },
            .pmax = .{ row_max_x, item_max[1] },
            .col = zgui.colorConvertFloat4ToU32(bg),
            .rounding = ui_theme.scaledUi(8.0),
        });
    }
    const text_pos = .{
        row_min_x + ui_theme.scaledUi(16.0),
        item_min[1] + (item_height - text_size[1]) * 0.5,
    };
    draw_list.addTextUnformatted(text_pos, zgui.colorConvertFloat4ToU32(if (is_selected) ui_theme.COLOR_WHITE else ui_theme.COLOR_TEXT_MUTED), label);
    if (is_selected) drawLockedModelCheckForLastItem(ui_theme.COLOR_WHITE, row_min_x);
}

fn composerProviderIndex(provider: Provider) usize {
    for (COMPOSER_PROVIDER_OPTIONS, 0..) |candidate, index| {
        if (candidate == provider) return index;
    }
    return 0;
}

fn renderComposerModelFlyout(
    state: *AppState,
    thread: *ChatThread,
    provider: Provider,
    provider_popup_origin: [2]f32,
    popup_padding: f32,
    provider_panel_width: f32,
    provider_index: usize,
    model_panel_width: f32,
    model_row_height: f32,
) void {
    const model_panel_height = modelRowPanelHeight(provider, model_row_height);
    const flyout_gap = ui_theme.scaledUi(-10.0);
    const flyout_x = provider_popup_origin[0] + provider_panel_width + flyout_gap - popup_padding;
    const flyout_y = provider_popup_origin[1] + providerRowHeightForFlyout(provider_index) - popup_padding - ui_theme.scaledUi(2.0);
    const desired_window_height = model_panel_height + popup_padding * 2.0;
    const viewport = zgui.getMainViewport();
    const work_pos = viewport.getWorkPos();
    const work_size = viewport.getWorkSize();
    const viewport_bottom = work_pos[1] + work_size[1] - ui_theme.scaledUi(12.0);
    const available_window_height = @max(ui_theme.scaledUi(84.0), viewport_bottom - flyout_y);
    const window_height = @min(desired_window_height, available_window_height);
    const needs_scroll = desired_window_height > window_height + 0.5;
    zgui.setNextWindowPos(.{
        .x = flyout_x,
        .y = flyout_y,
    });
    zgui.setNextWindowSize(.{
        .w = model_panel_width,
        .h = window_height,
    });
    zgui.pushStyleVar1f(.{ .idx = .window_rounding, .v = ui_theme.scaledUi(14.0) });
    zgui.pushStyleVar2f(.{ .idx = .window_padding, .v = .{ popup_padding, popup_padding } });
    zgui.pushStyleVar2f(.{ .idx = .item_spacing, .v = .{ 0.0, 0.0 } });
    zgui.pushStyleColor4f(.{ .idx = .window_bg, .c = colors.rgba(28, 30, 36, 255) });
    zgui.pushStyleColor4f(.{ .idx = .border, .c = colors.rgba(66, 68, 78, 255) });
    defer {
        zgui.popStyleColor(.{ .count = 2 });
        zgui.popStyleVar(.{ .count = 3 });
    }

    _ = zgui.begin("##composer-model-flyout", .{
        .flags = .{
            .no_title_bar = true,
            .no_resize = true,
            .no_saved_settings = true,
            .no_move = true,
            .no_focus_on_appearing = true,
            .no_nav_focus = true,
            .no_scrollbar = !needs_scroll,
            .no_scroll_with_mouse = !needs_scroll,
            .always_vertical_scrollbar = needs_scroll,
        },
    });
    defer zgui.end();

    for (chat_threads.modelOptions(ModelOption, provider, OPENCODE_MODEL_OPTIONS[0..], CODEX_MODEL_OPTIONS[0..]), 0..) |option, index| {
        zgui.pushIntId(@intCast(index));
        var should_close_picker = false;
        const active_model_ref = if (thread.provider == provider and thread.model_ref != null)
            thread.model_ref.?
        else
            defaultModelRef(provider);
        const is_selected = if (option.value) |value|
            thread.provider == provider and std.mem.eql(u8, active_model_ref, value)
        else
            false;
        const clicked = zgui.invisibleButton("##model-row", .{
            .w = zgui.getWindowWidth() - popup_padding * 2.0,
            .h = model_row_height,
        });
        const is_hovered = zgui.isItemHovered(.{});
        if (clicked) {
            setThreadProvider(state, thread, provider);
            setThreadModelRef(state, thread, option.value);
            state.composer_picker_provider = null;
            should_close_picker = true;
        }
        drawFlyoutModelRowForLastItem(option.label, is_selected, is_hovered);
        zgui.popId();
        if (should_close_picker) {
            zgui.closeCurrentPopup();
            return;
        }
    }
}

fn providerLogoSlotWidth(state: *AppState, item_height: f32) f32 {
    return @max(
        providerLogoSize(state, .codex, item_height - ui_theme.scaledUi(10.0))[0],
        providerLogoSize(state, .opencode, item_height - ui_theme.scaledUi(10.0))[0],
    );
}

fn composerProviderPanelWidth(state: *AppState, row_height: f32) f32 {
    const icon_slot_width = providerLogoSlotWidth(state, row_height);
    var max_label_width: f32 = 0.0;
    for (COMPOSER_PROVIDER_OPTIONS) |provider| {
        max_label_width = @max(max_label_width, zgui.calcTextSize(chat_threads.providerLabel(provider), .{})[0]);
    }
    return icon_slot_width + ui_theme.scaledUi(6.0) + max_label_width + ui_theme.scaledUi(18.0);
}

fn providerRowHeightForFlyout(provider_index: usize) f32 {
    return ui_theme.scaledUi(38.0) * @as(f32, @floatFromInt(provider_index));
}

fn providerLogoScale(provider: Provider) f32 {
    return switch (provider) {
        .codex => 0.86,
        .opencode => 0.78,
    };
}

fn providerLogoYOffset(provider: Provider) f32 {
    return switch (provider) {
        .codex => ui_theme.scaledUi(0.0),
        .opencode => ui_theme.scaledUi(-0.5),
    };
}

fn drawProviderLogoInRect(
    draw_list: zgui.DrawList,
    state: *AppState,
    provider: Provider,
    item_min: [2]f32,
    item_height: f32,
    left_padding: f32,
) void {
    if (providerLogoTexture(state, provider)) |cached| {
        const logo_size = providerLogoSize(state, provider, item_height - ui_theme.scaledUi(10.0));
        const slot_width = providerLogoSlotWidth(state, item_height);
        const uv_bounds = providerLogoUvBounds(provider);
        const logo_min = .{
            item_min[0] + left_padding + (slot_width - logo_size[0]) * 0.5,
            item_min[1] + (item_height - logo_size[1]) * 0.5 + providerLogoYOffset(provider),
        };
        draw_list.addImage(runtime.textureRefFromGlId(cached.texture_id), .{
            .pmin = logo_min,
            .pmax = .{ logo_min[0] + logo_size[0], logo_min[1] + logo_size[1] },
            .uvmin = uv_bounds.min,
            .uvmax = uv_bounds.max,
        });
    }
}

fn drawChevron(draw_list: zgui.DrawList, x: f32, center_y: f32, color: [4]f32) void {
    const half = ui_theme.scaledUi(4.0);
    const col = zgui.colorConvertFloat4ToU32(color);
    draw_list.addLine(.{
        .p1 = .{ x - half, center_y - half },
        .p2 = .{ x, center_y },
        .col = col,
        .thickness = ui_theme.scaledUi(1.8),
    });
    draw_list.addLine(.{
        .p1 = .{ x - half, center_y + half },
        .p2 = .{ x, center_y },
        .col = col,
        .thickness = ui_theme.scaledUi(1.8),
    });
}

fn drawCheckForCustomRow(color: [4]f32, x: f32) void {
    const item_min = zgui.getItemRectMin();
    const item_max = zgui.getItemRectMax();
    const draw_list = zgui.getWindowDrawList();
    const col = zgui.colorConvertFloat4ToU32(color);
    const center_y = item_min[1] + (item_max[1] - item_min[1]) * 0.5;
    const small = ui_theme.scaledUi(3.0);
    const large = ui_theme.scaledUi(6.0);
    draw_list.addLine(.{
        .p1 = .{ x - small, center_y },
        .p2 = .{ x, center_y + small },
        .col = col,
        .thickness = ui_theme.scaledUi(1.8),
    });
    draw_list.addLine(.{
        .p1 = .{ x, center_y + small },
        .p2 = .{ x + large, center_y - large * 0.6 },
        .col = col,
        .thickness = ui_theme.scaledUi(1.8),
    });
}

fn drawLockedModelCheckForLastItem(color: [4]f32, row_min_x: f32) void {
    const item_min = zgui.getItemRectMin();
    const item_max = zgui.getItemRectMax();
    const draw_list = zgui.getWindowDrawList();
    const col = zgui.colorConvertFloat4ToU32(color);
    const x = row_min_x + ui_theme.scaledUi(7.0);
    const center_y = item_min[1] + (item_max[1] - item_min[1]) * 0.5;
    const small = ui_theme.scaledUi(3.0);
    const large = ui_theme.scaledUi(6.0);
    draw_list.addLine(.{
        .p1 = .{ x - small, center_y },
        .p2 = .{ x, center_y + small },
        .col = col,
        .thickness = ui_theme.scaledUi(1.8),
    });
    draw_list.addLine(.{
        .p1 = .{ x, center_y + small },
        .p2 = .{ x + large, center_y - large * 0.6 },
        .col = col,
        .thickness = ui_theme.scaledUi(1.8),
    });
}

fn modelRowPanelHeight(provider: Provider, row_height: f32) f32 {
    const model_count = chat_threads.modelOptions(ModelOption, provider, OPENCODE_MODEL_OPTIONS[0..], CODEX_MODEL_OPTIONS[0..]).len;
    return row_height * @as(f32, @floatFromInt(model_count));
}

fn setThreadProvider(state: *AppState, thread: *ChatThread, provider: Provider) void {
    if (thread.provider == provider) return;

    thread.provider = provider;
    if (thread.provider_thread_id) |thread_id| {
        state.allocator.free(thread_id);
    }
    thread.provider_thread_id = null;
    if (thread.model_ref) |model_ref| {
        state.allocator.free(model_ref);
    }
    thread.model_ref = state.allocator.dupeZ(u8, defaultModelRef(provider)) catch null;
    thread.reasoning_effort = null;
    thread.fast_mode = .off;
    state.markDirty();
}

fn setThreadModelRef(state: *AppState, thread: *ChatThread, value: ?[:0]const u8) void {
    if (thread.model_ref) |existing| {
        state.allocator.free(existing);
        thread.model_ref = null;
    }

    thread.model_ref = if (value) |next|
        state.allocator.dupeZ(u8, next) catch null
    else
        null;
    state.markDirty();
}

fn defaultModelRef(provider: Provider) [:0]const u8 {
    return switch (provider) {
        .codex => DEFAULT_CODEX_MODEL,
        .opencode => DEFAULT_OPENCODE_MODEL,
    };
}

fn comboRowLabel(buffer: []u8, label: []const u8, selected: bool) [:0]const u8 {
    return std.fmt.bufPrintZ(buffer, "{s} {s}", .{ if (selected) ">" else " ", label }) catch " row";
}
