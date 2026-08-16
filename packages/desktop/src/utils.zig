const ai_harness = @import("providers/harness.zig");
const chat_types = @import("state/chat_types.zig");
const loop_wakeup = @import("loop_wakeup");
const platform_runtime = @import("platform_runtime");
const provider_models = @import("state/provider_models.zig");
const state_ui_types = @import("state/ui_types.zig");
const windows_integrations = @import("platform/windows/integrations.zig");
const process_env = @import("platform/env.zig");
const runtime_log = @import("runtime/log.zig");
const stb_image = @import("media/stb_image.zig");
const chat_threads = @import("chat/threads.zig");
const std = @import("std");
const builtin = @import("builtin");

const log = std.log.scoped(.native_utils);

// Shared runtime constants live here so state and the UI shell can import them
// without creating a cycle back through `main.zig`.
pub const CLIPBOARD_IMAGE_MAX_BYTES: usize = 10 * 1024 * 1024;
pub const PERSISTED_DIFF_MARKER_V1 = "EDITORTS_DIFF_V1\n";
pub const PERSISTED_DIFF_MARKER = "VERDE_DIFF_V2\n";

extern fn verde_macos_clipboard_copy_image(out_bytes: *?[*]u8, out_len: *usize, out_mime: *?[*:0]const u8) c_int;
extern fn free(ptr: ?*anyopaque) void;

pub const PickDirectoryError = std.process.RunError || std.mem.Allocator.Error || error{
    UnsupportedOperatingSystem,
    FolderPickerUnavailable,
    UserCancelled,
    ChildProcessFailed,
};

pub const OpenProjectError = std.mem.Allocator.Error || error{
    UnsupportedOperatingSystem,
    LauncherUnavailable,
} || std.process.SpawnError;

pub const OpenFileResult = enum {
    editor,
    file_manager,
};

pub const FileLocation = struct {
    line: ?usize = null,
    column: ?usize = null,
};

pub const FileReference = struct {
    path: []const u8,
    location: FileLocation = .{},
};

/// Separates the conventional `:line` or `:line:column` suffix from a file path.
pub fn parseFileReference(value: []const u8) FileReference {
    const final_colon = std.mem.findScalarLast(u8, value, ':') orelse return .{ .path = value };
    if (final_colon == 0) return .{ .path = value };

    const final_number = parsePositiveDecimal(value[final_colon + 1 ..]) orelse return .{ .path = value };
    const before_final = value[0..final_colon];
    if (std.mem.findScalarLast(u8, before_final, ':')) |line_colon| {
        if (line_colon > 0) {
            if (parsePositiveDecimal(before_final[line_colon + 1 ..])) |line| {
                return .{
                    .path = before_final[0..line_colon],
                    .location = .{ .line = line, .column = final_number },
                };
            }
        }
    }

    // Do not interpret a Windows drive-relative path such as `C:12` as a line reference.
    if (final_colon == 1 and std.ascii.isAlphabetic(value[0])) return .{ .path = value };
    return .{ .path = before_final, .location = .{ .line = final_number } };
}

fn parsePositiveDecimal(value: []const u8) ?usize {
    if (value.len == 0) return null;
    for (value) |byte| {
        if (!std.ascii.isDigit(byte)) return null;
    }
    const parsed = std.fmt.parseInt(usize, value, 10) catch return null;
    return if (parsed > 0) parsed else null;
}

pub fn loadEmbeddedTexture(bytes: []const u8) ?state_ui_types.CachedImageTexture {
    const loaded = stb_image.loadFromMemory(bytes) catch |err| {
        log.err("failed to decode embedded logo texture: {s}", .{@errorName(err)});
        return null;
    };
    defer loaded.deinit();
    return uploadTexture(loaded);
}

pub fn uploadTexture(loaded: stb_image.LoadedImage) ?state_ui_types.CachedImageTexture {
    _ = loaded;
    return null;
}

/// Normalized device / layout rectangle for bitmap draws (avoids anonymous-struct mismatch).
pub const ImageLayoutRect = struct { x: f32, y: f32, w: f32, h: f32 };

/// Aspect-fill inside a fixed slot so non-square bitmaps are not stretched to a square
/// (which blurs logos). Same slot bounds; excess is cropped by the clip rect.
pub fn imageRectCover(tex_w: i32, tex_h: i32, slot_x: f32, slot_y: f32, slot_w: f32, slot_h: f32) ImageLayoutRect {
    if (tex_w <= 0 or tex_h <= 0 or slot_w <= 0.0 or slot_h <= 0.0) {
        return .{ .x = slot_x, .y = slot_y, .w = slot_w, .h = slot_h };
    }
    const iw: f32 = @floatFromInt(tex_w);
    const ih: f32 = @floatFromInt(tex_h);
    const scale = @max(slot_w / iw, slot_h / ih);
    const dw = iw * scale;
    const dh = ih * scale;
    return .{
        .x = slot_x + (slot_w - dw) * 0.5,
        .y = slot_y + (slot_h - dh) * 0.5,
        .w = dw,
        .h = dh,
    };
}

/// Like CSS `object-fit: contain`: full bitmap visible, aspect preserved, centered in the slot.
pub fn imageRectContain(tex_w: i32, tex_h: i32, slot_x: f32, slot_y: f32, slot_w: f32, slot_h: f32) ImageLayoutRect {
    if (tex_w <= 0 or tex_h <= 0 or slot_w <= 0.0 or slot_h <= 0.0) {
        return .{ .x = slot_x, .y = slot_y, .w = slot_w, .h = slot_h };
    }
    const iw: f32 = @floatFromInt(tex_w);
    const ih: f32 = @floatFromInt(tex_h);
    const scale = @min(slot_w / iw, slot_h / ih);
    const dw = iw * scale;
    const dh = ih * scale;
    return .{
        .x = slot_x + (slot_w - dw) * 0.5,
        .y = slot_y + (slot_h - dh) * 0.5,
        .w = dw,
        .h = dh,
    };
}

/// Integer pixel bounds for texture quads so bilinear sampling is not shifted by
/// sub-pixel placement (reduces mushy edges on tiny minified logos).
pub fn snapImageRectToPixels(r: ImageLayoutRect) ImageLayoutRect {
    return .{
        .x = @round(r.x),
        .y = @round(r.y),
        .w = @max(1, @round(r.w)),
        .h = @max(1, @round(r.h)),
    };
}

pub fn projectLabelFromPath(path: []const u8) []const u8 {
    const basename = std.fs.path.basename(path);
    return if (basename.len == 0) path else basename;
}

pub fn canOpenProjectDirectory() bool {
    return switch (@import("builtin").os.tag) {
        .macos => commandExists("open"),
        .linux, .freebsd, .netbsd, .openbsd, .dragonfly => commandExists("xdg-open") or commandExists("gio"),
        .windows => true,
        else => false,
    };
}

pub fn openProjectDirectory(allocator: std.mem.Allocator, project_path: []const u8) OpenProjectError!void {
    return switch (@import("builtin").os.tag) {
        .macos => {
            runtime_log.diagnostic("openProjectDirectory launcher=open path={s}", .{project_path});
            return spawnDetached(allocator, &.{ "open", project_path }, null);
        },
        .linux, .freebsd, .netbsd, .openbsd, .dragonfly => {
            if (commandExists("xdg-open")) {
                runtime_log.diagnostic("openProjectDirectory launcher=xdg-open path={s}", .{project_path});
                return spawnDetached(allocator, &.{ "xdg-open", project_path }, null);
            }
            if (commandExists("gio")) {
                runtime_log.diagnostic("openProjectDirectory launcher=gio open path={s}", .{project_path});
                return spawnDetached(allocator, &.{ "gio", "open", project_path }, null);
            }
            runtime_log.diagnostic("openProjectDirectory launcher unavailable path={s}", .{project_path});
            return error.LauncherUnavailable;
        },
        .windows => {
            runtime_log.diagnostic("openProjectDirectory launcher=ShellExecute path={s}", .{project_path});
            if (!windows_integrations.shellOpen(project_path, null)) return error.LauncherUnavailable;
        },
        else => error.UnsupportedOperatingSystem,
    };
}

pub fn openUrlInDefaultBrowser(allocator: std.mem.Allocator, url: []const u8) OpenProjectError!void {
    return switch (@import("builtin").os.tag) {
        .macos => {
            runtime_log.diagnostic("openUrlInDefaultBrowser launcher=open url_len={d}", .{url.len});
            return spawnDetached(allocator, &.{ "open", url }, null);
        },
        .linux, .freebsd, .netbsd, .openbsd, .dragonfly => {
            if (commandExists("xdg-open")) {
                runtime_log.diagnostic("openUrlInDefaultBrowser launcher=xdg-open url_len={d}", .{url.len});
                return spawnDetached(allocator, &.{ "xdg-open", url }, null);
            }
            if (commandExists("gio")) {
                runtime_log.diagnostic("openUrlInDefaultBrowser launcher=gio open url_len={d}", .{url.len});
                return spawnDetached(allocator, &.{ "gio", "open", url }, null);
            }
            runtime_log.diagnostic("openUrlInDefaultBrowser launcher unavailable url_len={d}", .{url.len});
            return error.LauncherUnavailable;
        },
        .windows => {
            runtime_log.diagnostic("openUrlInDefaultBrowser launcher=ShellExecute url_len={d}", .{url.len});
            if (!windows_integrations.shellOpen(url, null)) return error.LauncherUnavailable;
        },
        else => error.UnsupportedOperatingSystem,
    };
}

pub fn canOpenProjectEditor(target: state_ui_types.ProjectEditorTarget) bool {
    return switch (target) {
        .configured => canOpenConfiguredEditor(),
        .cursor => hasCursorLauncher(),
        .vscode => hasVsCodeLauncher(),
        .zed => hasZedLauncher(),
    };
}

pub fn configuredEditorDisplayName() ?[]const u8 {
    const editor = preferredEditorEnv() orelse return null;
    const executable = commandExecutableName(editor.value);
    if (executable.len == 0) return null;
    return executable;
}

pub fn configuredEditorIsNeovim() bool {
    const editor = preferredEditorEnv() orelse return false;
    return std.ascii.eqlIgnoreCase(commandExecutableName(editor.value), "nvim");
}

pub fn configuredEditorTerminalCommandAlloc(allocator: std.mem.Allocator) !?[]u8 {
    const editor = preferredEditorEnv() orelse return null;
    if (!std.ascii.eqlIgnoreCase(commandExecutableName(editor.value), "nvim")) return null;
    return try std.fmt.allocPrint(allocator, "exec ${s}\n", .{editor.name});
}

pub fn configuredNeovimFileCommandAlloc(
    allocator: std.mem.Allocator,
    file_path: []const u8,
    location: FileLocation,
) !?[]u8 {
    const editor = preferredEditorEnv() orelse return null;
    const executable = commandExecutableName(editor.value);
    if (!std.ascii.eqlIgnoreCase(executable, "nvim")) return null;

    const escaped_path = try shellSingleQuoteEscape(allocator, file_path);
    defer allocator.free(escaped_path);
    const location_arg = try vimLocationArgumentAlloc(allocator, executable, location);
    defer if (location_arg) |arg| allocator.free(arg);

    return if (location_arg) |arg|
        try std.fmt.allocPrint(allocator, "exec ${s} '{s}' -- '{s}'\n", .{ editor.name, arg, escaped_path })
    else
        try std.fmt.allocPrint(allocator, "exec ${s} -- '{s}'\n", .{ editor.name, escaped_path });
}

pub fn executableNameForCommand(command: []const u8) []const u8 {
    return commandExecutableName(command);
}

pub fn openProjectEditor(
    allocator: std.mem.Allocator,
    project_path: []const u8,
    target: state_ui_types.ProjectEditorTarget,
) OpenProjectError!void {
    return switch (target) {
        .configured => {
            const editor = preferredEditorEnv() orelse return error.LauncherUnavailable;
            return openConfiguredEditor(allocator, editor, project_path);
        },
        .cursor => openCursor(allocator, project_path),
        .vscode => openVsCode(allocator, project_path),
        .zed => openZed(allocator, project_path),
    };
}

pub fn openFilePreferEditor(
    allocator: std.mem.Allocator,
    file_path: []const u8,
    location: FileLocation,
) OpenProjectError!OpenFileResult {
    const parent_dir = std.fs.path.dirname(file_path) orelse file_path;

    if (preferredEditorEnv()) |editor| {
        if (canOpenConfiguredEditor()) {
            try openConfiguredEditorPath(allocator, editor, parent_dir, file_path, location);
            return .editor;
        }
    }

    openKnownEditorPath(allocator, parent_dir, file_path) catch |err| switch (err) {
        error.LauncherUnavailable => {},
        else => return err,
    };
    if (hasCursorLauncher() or hasVsCodeLauncher() or hasZedLauncher()) return .editor;

    try revealFileInFileManager(allocator, file_path);
    return .file_manager;
}

pub fn runCustomProjectCommand(
    allocator: std.mem.Allocator,
    project_path: []const u8,
    command: []const u8,
) OpenProjectError!void {
    if (builtin.os.tag == .windows) {
        const shell = if (commandExists("pwsh")) "pwsh" else if (commandExists("powershell")) "powershell" else return error.LauncherUnavailable;
        return spawnDetached(allocator, &.{ shell, "-NoLogo", "-NoProfile", "-Command", command }, project_path);
    }
    return spawnDetached(allocator, &.{ "sh", "-lc", command, "verde-open-action", project_path }, project_path);
}

pub fn pickerWorker(state: *state_ui_types.PickerState, start_path: []u8) void {
    defer std.heap.page_allocator.free(start_path);

    runtime_log.diagnostic("pickerWorker start path={s}", .{start_path});
    const result = pickDirectory(std.heap.page_allocator, start_path);

    state.mutex.lock();
    defer state.mutex.unlock();

    if (result) |path| {
        runtime_log.diagnostic("pickerWorker selected path={s}", .{path});
        state.selected_path = path;
        state.status = .selected;
    } else |err| switch (err) {
        error.UserCancelled => {
            runtime_log.diagnostic("pickerWorker cancelled", .{});
            state.status = .cancelled;
        },
        error.UnsupportedOperatingSystem => {
            runtime_log.diagnostic("pickerWorker unavailable: unsupported os", .{});
            state.status = .unavailable;
        },
        error.FolderPickerUnavailable => {
            runtime_log.diagnostic("pickerWorker unavailable: no picker command", .{});
            state.status = .unavailable;
        },
        else => {
            runtime_log.diagnostic("pickerWorker failed: {s}", .{@errorName(err)});
            state.status = .failed;
        },
    }
}
pub fn pickDirectory(allocator: std.mem.Allocator, start_path: []const u8) PickDirectoryError![]u8 {
    return switch (@import("builtin").os.tag) {
        .macos => pickDirectoryMacOS(allocator, start_path),
        .linux, .freebsd, .netbsd, .openbsd, .dragonfly => pickDirectoryLinux(allocator, start_path),
        .windows => windows_integrations.pickDirectoryAlloc(allocator, start_path) catch |err| switch (err) {
            error.Cancelled => error.UserCancelled,
            error.Unavailable => error.FolderPickerUnavailable,
            error.OutOfMemory => error.OutOfMemory,
        },
        else => error.UnsupportedOperatingSystem,
    };
}

pub fn pickDirectoryMacOS(allocator: std.mem.Allocator, start_path: []const u8) PickDirectoryError![]u8 {
    if (!commandExists("osascript")) return error.FolderPickerUnavailable;

    const escaped_start_path = try escapeAppleScriptString(allocator, start_path);
    defer allocator.free(escaped_start_path);

    const script = try std.fmt.allocPrint(
        allocator,
        \\try
        \\set defaultLocation to POSIX file "{s}"
        \\return POSIX path of (choose folder with prompt "Select workspace folder" default location defaultLocation)
        \\on error number -128
        \\error "User cancelled" number 1
        \\end try
    ,
        .{escaped_start_path},
    );
    defer allocator.free(script);

    const result = runChild(allocator, &.{ "osascript", "-e", script }, null, 16 * 1024) catch |err| switch (err) {
        error.FileNotFound => return error.FolderPickerUnavailable,
        else => return err,
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| {
            if (code != 0) {
                if (std.mem.indexOf(u8, result.stderr, "User cancelled") != null or
                    std.mem.indexOf(u8, result.stderr, "(-128)") != null)
                {
                    return error.UserCancelled;
                }
                return error.ChildProcessFailed;
            }
        },
        else => return error.ChildProcessFailed,
    }

    const trimmed = std.mem.trim(u8, result.stdout, &std.ascii.whitespace);
    if (trimmed.len == 0) return error.UserCancelled;
    return allocator.dupe(u8, trimmed);
}

pub fn pickDirectoryLinux(allocator: std.mem.Allocator, start_path: []const u8) PickDirectoryError![]u8 {
    if (commandExists("zenity")) {
        return runLinuxGuiDirectoryPickerCommand(allocator,
            \\zenity --file-selection --directory --filename "$1" --title "Select workspace folder"
        , start_path, null);
    }

    if (commandExists("kdialog")) {
        return runLinuxGuiDirectoryPickerCommand(allocator,
            \\kdialog --getexistingdirectory "$1" --title "Select workspace folder"
        , start_path, null);
    }

    if (commandExists("yad")) {
        return runLinuxGuiDirectoryPickerCommand(allocator,
            \\yad --file-selection --directory --filename "$1" --title "Select workspace folder"
        , start_path, null);
    }

    if (commandExists("qarma")) {
        return runLinuxGuiDirectoryPickerCommand(allocator,
            \\qarma --file-selection --directory --filename "$1" --title "Select workspace folder"
        , start_path, null);
    }

    if (commandExists("python3")) {
        return runDirectoryPickerCommand(allocator, &.{
            "python3",
            "-c",
            \\import sys
            \\try:
            \\    import tkinter as tk
            \\    from tkinter import filedialog
            \\except Exception:
            \\    raise SystemExit(2)
            \\root = tk.Tk()
            \\root.withdraw()
            \\root.attributes("-topmost", True)
            \\path = filedialog.askdirectory(
            \\    initialdir=sys.argv[1],
            \\    title="Select workspace folder",
            \\    mustexist=True,
            \\)
            \\root.update()
            \\root.destroy()
            \\if not path:
            \\    raise SystemExit(1)
            \\print(path)
            ,
            start_path,
        }, 2);
    }

    return error.FolderPickerUnavailable;
}

fn runLinuxGuiDirectoryPickerCommand(
    allocator: std.mem.Allocator,
    comptime picker_command: []const u8,
    start_path: []const u8,
    unavailable_exit_code: ?u8,
) PickDirectoryError![]u8 {
    const script =
        \\export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
        \\if [ -z "${WAYLAND_DISPLAY:-}" ]; then
        \\  for socket in "$XDG_RUNTIME_DIR"/wayland-*; do
        \\    [ -S "$socket" ] || continue
        \\    export WAYLAND_DISPLAY="$(basename "$socket")"
        \\    break
        \\  done
        \\fi
        \\if [ -z "${DISPLAY:-}" ] && [ -d /tmp/.X11-unix ]; then
        \\  for socket in /tmp/.X11-unix/X*; do
        \\    [ -S "$socket" ] || continue
        \\    export DISPLAY=":${socket##*/X}"
        \\    break
        \\  done
        \\fi
        \\
    ++ picker_command;
    return runDirectoryPickerCommand(allocator, &.{ "sh", "-c", script, "verde-folder-picker", start_path }, unavailable_exit_code);
}

fn runDirectoryPickerCommand(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    unavailable_exit_code: ?u8,
) PickDirectoryError![]u8 {
    runtime_log.diagnostic("runDirectoryPickerCommand argv={s}", .{argv[0]});
    const result = runChild(allocator, argv, null, 16 * 1024) catch |err| switch (err) {
        error.FileNotFound => {
            runtime_log.diagnostic("runDirectoryPickerCommand file not found argv={s}", .{argv[0]});
            return error.FolderPickerUnavailable;
        },
        else => {
            runtime_log.diagnostic("runDirectoryPickerCommand spawn failed argv={s}: {s}", .{ argv[0], @errorName(err) });
            return err;
        },
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| {
            runtime_log.diagnostic("runDirectoryPickerCommand exited argv={s} code={d} stdout_len={d} stderr_len={d}", .{ argv[0], code, result.stdout.len, result.stderr.len });
            if (code == 1) return error.UserCancelled;
            if (unavailable_exit_code) |expected| {
                if (code == expected) return error.FolderPickerUnavailable;
            }
            if (code != 0) return error.ChildProcessFailed;
        },
        else => {
            runtime_log.diagnostic("runDirectoryPickerCommand did not exit normally argv={s}", .{argv[0]});
            return error.ChildProcessFailed;
        },
    }

    const trimmed = std.mem.trim(u8, result.stdout, &std.ascii.whitespace);
    if (trimmed.len == 0) return error.UserCancelled;
    return allocator.dupe(u8, trimmed);
}

pub fn sendWorker(state: *chat_types.SendState, request: *SendWorkerRequest) void {
    const page_alloc = std.heap.page_allocator;
    const request_cwd = request.remote_cwd orelse request.project_path;
    defer {
        page_alloc.free(request.project_path);
        page_alloc.free(request.prompt);
        if (request.image_path) |image_path| page_alloc.free(image_path);
        for (request.image_paths) |image_path| page_alloc.free(image_path);
        page_alloc.free(request.image_paths);
        if (request.provider_thread_id) |thread_id| page_alloc.free(thread_id);
        page_alloc.free(request.thread_title);
        if (request.model_ref) |model_ref| page_alloc.free(model_ref);
        if (request.opencode_reasoning_variant) |variant| page_alloc.free(variant);
        if (request.cursor_model_params_json) |params| page_alloc.free(params);
        if (request.remote_ssh_host) |host| page_alloc.free(host);
        if (request.remote_cwd) |cwd| page_alloc.free(cwd);
        page_alloc.destroy(request);
    }

    std.debug.print(
        "[codex-debug] sendWorker begin provider={s} cwd={s} model_len={d} thread_id_len={d} prompt_len={d}\n",
        .{
            @tagName(request.provider),
            request_cwd,
            if (request.model_ref) |model| model.len else 0,
            if (request.provider_thread_id) |thread_id| thread_id.len else 0,
            request.prompt.len,
        },
    );
    runtime_log.diagnostic(
        "sendWorker begin provider={s} cwd={s} model_len={d} thread_id_len={d} prompt_len={d}",
        .{
            @tagName(request.provider),
            request_cwd,
            if (request.model_ref) |model| model.len else 0,
            if (request.provider_thread_id) |thread_id| thread_id.len else 0,
            request.prompt.len,
        },
    );

    const result = runSendWorker(page_alloc, request);

    state.mutex.lock();
    defer state.mutex.unlock();
    // Whatever terminal status we settle on below, wake the render loop so
    // pollSend commits it immediately instead of on the next timeout tick.
    defer loop_wakeup.notify();

    if (result) |payload| {
        if (state.stop_requested) {
            std.heap.page_allocator.free(payload.provider_thread_id);
            std.heap.page_allocator.free(payload.reply_text);
            state.result = null;
            state.error_message = null;
            state.status = .aborted;
            return;
        }
        state.result = payload;
        state.error_message = null;
        state.status = .completed;
    } else |err| {
        std.debug.print(
            "[codex-debug] sendWorker failed provider={s} cwd={s} model_len={d} thread_id_len={d} err={s}\n",
            .{
                @tagName(request.provider),
                request_cwd,
                if (request.model_ref) |model| model.len else 0,
                if (request.provider_thread_id) |thread_id| thread_id.len else 0,
                @errorName(err),
            },
        );
        runtime_log.diagnostic(
            "sendWorker failed provider={s} cwd={s} model_len={d} thread_id_len={d} err={s}",
            .{
                @tagName(request.provider),
                request_cwd,
                if (request.model_ref) |model| model.len else 0,
                if (request.provider_thread_id) |thread_id| thread_id.len else 0,
                @errorName(err),
            },
        );
        if ((err == error.CodexTurnInterrupted or err == error.ClaudeTurnInterrupted) and state.stop_requested) {
            state.error_message = null;
            state.result = null;
            state.status = .aborted;
            return;
        }
        if (state.error_message == null) {
            state.error_message = formatSendWorkerError(page_alloc, request.provider, err) catch null;
        }
        state.result = null;
        state.status = .failed;
    }
}
pub const SendWorkerRequest = struct {
    send_state_ptr: *chat_types.SendState,
    provider: provider_models.Provider,
    harness: provider_models.Harness,
    project_path: []u8,
    prompt: []u8,
    image_path: ?[]u8,
    image_paths: [][]u8,
    provider_thread_id: ?[]u8,
    thread_title: []u8,
    model_ref: ?[]u8,
    reasoning_effort: ?provider_models.ReasoningEffort,
    /// Owned; OpenCode-only. Duplicated from thread `opencode_reasoning_variant`.
    opencode_reasoning_variant: ?[]u8,
    cursor_model_params_json: ?[]u8,
    fast_mode: provider_models.FastMode,
    access_mode: provider_models.AccessMode,
    remote_ssh_host: ?[]u8 = null,
    remote_cwd: ?[]u8 = null,
};
pub fn runSendWorker(
    allocator: std.mem.Allocator,
    request: *const SendWorkerRequest,
) !chat_types.SendResultPayload {
    if (request.harness != .local_cli) {
        return error.UnsupportedHarnessMode;
    }

    if (request.remote_ssh_host != null and request.provider != .codex) {
        return error.UnsupportedRemoteProvider;
    }
    const request_cwd = request.remote_cwd orelse request.project_path;

    const provider_config = switch (request.provider) {
        .opencode => ai_harness.ProviderConfig{
            .opencode = .{
                .allocator = allocator,
                .working_directory = request_cwd,
                .launch_if_missing = true,
            },
        },
        .codex => ai_harness.ProviderConfig{
            .codex = .{
                .cwd = request_cwd,
                .launch_on_connect = true,
                .remote_ssh = if (request.remote_ssh_host) |host| .{
                    .host = host,
                    .cwd = request_cwd,
                } else null,
            },
        },
        .claude => ai_harness.ProviderConfig{
            .claude = .{
                .cwd = request_cwd,
            },
        },
        .cursor => ai_harness.ProviderConfig{
            .cursor = .{
                .cwd = request_cwd,
                .model = request.model_ref,
            },
        },
    };

    log.info(
        "send worker starting provider={s} cwd={s} model_len={d} thread_id_len={d} prompt_len={d}",
        .{
            @tagName(request.provider),
            request_cwd,
            if (request.model_ref) |model| model.len else 0,
            if (request.provider_thread_id) |thread_id| thread_id.len else 0,
            request.prompt.len,
        },
    );

    var client = try ai_harness.connect(allocator, provider_config);
    defer client.deinit();
    std.debug.print("[codex-debug] send worker connected provider={s}\n", .{@tagName(request.provider)});
    runtime_log.diagnostic("send worker connected provider={s}", .{@tagName(request.provider)});

    const image_attachments = try allocator.alloc(ai_harness.types.ImageAttachment, request.image_paths.len);
    defer allocator.free(image_attachments);
    for (request.image_paths, 0..) |image_path, index| {
        image_attachments[index] = .{ .path = image_path };
    }

    const result = client.sendPrompt(allocator, .{
        .thread_id = request.provider_thread_id,
        .thread_title = request.thread_title,
        .prompt = request.prompt,
        .image = if (request.image_path) |image_path| .{ .path = image_path } else null,
        .images = image_attachments,
        .cwd = request_cwd,
        .model = request.model_ref,
        .opencode_variant = if (request.provider == .opencode) request.opencode_reasoning_variant else null,
        .cursor_model_params_json = if (request.provider == .cursor) request.cursor_model_params_json else null,
        .reasoning_effort = if (request.provider == .opencode and request.opencode_reasoning_variant != null) null else request.reasoning_effort,
        .service_tier = serviceTierForMode(request.provider, request.fast_mode),
        .approval_policy = approvalPolicyForMode(request.provider, request.access_mode),
        .sandbox_mode = sandboxModeForMode(request.provider, request.access_mode),
        .stream_context = request.send_state_ptr,
        .on_thread_id = handleSendThreadId,
        .on_turn_id = handleSendTurnId,
        .on_stream_delta = handleSendStreamDelta,
        .on_stream_event = handleSendStreamEvent,
        .on_failure = handleSendFailure,
        .on_should_stop = handleSendShouldStop,
        .on_approval_request = handleSendApprovalRequest,
    }) catch |err| {
        std.debug.print(
            "[codex-debug] client.sendPrompt failed provider={s} cwd={s} model_len={d} thread_id_len={d}: {s}\n",
            .{
                @tagName(request.provider),
                request_cwd,
                if (request.model_ref) |model| model.len else 0,
                if (request.provider_thread_id) |thread_id| thread_id.len else 0,
                @errorName(err),
            },
        );
        runtime_log.diagnostic(
            "client.sendPrompt failed provider={s} cwd={s} model_len={d} thread_id_len={d}: {s}",
            .{
                @tagName(request.provider),
                request_cwd,
                if (request.model_ref) |model| model.len else 0,
                if (request.provider_thread_id) |thread_id| thread_id.len else 0,
                @errorName(err),
            },
        );
        log.err(
            "send worker failed provider={s} cwd={s} model_len={d} thread_id_len={d}: {s}",
            .{
                @tagName(request.provider),
                request_cwd,
                if (request.model_ref) |model| model.len else 0,
                if (request.provider_thread_id) |thread_id| thread_id.len else 0,
                @errorName(err),
            },
        );
        return err;
    };

    log.info(
        "send worker completed provider={s} provider_thread_id_len={d} reply_len={d}",
        .{ @tagName(request.provider), result.thread_id.len, result.reply_text.len },
    );

    return .{
        .provider_thread_id = result.thread_id,
        .reply_text = result.reply_text,
    };
}

fn escapeAppleScriptString(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var escaped: std.ArrayList(u8) = .empty;
    errdefer escaped.deinit(allocator);

    for (value) |char| {
        switch (char) {
            '\\', '"' => {
                try escaped.append(allocator, '\\');
                try escaped.append(allocator, char);
            },
            else => try escaped.append(allocator, char),
        }
    }

    return escaped.toOwnedSlice(allocator);
}

fn spawnArg0IsQualifiedPath(arg0: []const u8) bool {
    if (builtin.os.tag == .windows) {
        if (std.mem.indexOfAny(u8, arg0, "\\/") != null) return true;
        return arg0.len >= 2 and arg0[1] == ':';
    }
    return std.mem.indexOfScalar(u8, arg0, '/') != null;
}

fn spawnDetached(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    cwd: ?[]const u8,
) (std.mem.Allocator.Error || std.process.SpawnError)!void {
    // GUI/desktop launches often inherit a minimal PATH. We pass an augmented environ_map so the
    // child sees ~/.local/bin, mise shims, etc. However, Zig's `process.spawn` resolves argv[0]
    // using the parent's environment only — not PATH from environ_map — so bare names like `zed`
    // fail with FileNotFound unless we pre-resolve against the same augmented PATH we give the child.
    var env_map = try process_env.buildAugmentedEnvMap(allocator);
    defer env_map.deinit();

    var argv_storage: std.ArrayList([]const u8) = .empty;
    defer argv_storage.deinit(allocator);
    var resolved_arg0: ?[]const u8 = null;
    defer if (resolved_arg0) |p| allocator.free(p);

    if (argv.len > 0 and !spawnArg0IsQualifiedPath(argv[0])) {
        resolved_arg0 = process_env.resolveExecutableInEnvMapAlloc(allocator, &env_map, argv[0]) catch null;
        if (resolved_arg0) |exe| {
            try argv_storage.append(allocator, exe);
            try argv_storage.appendSlice(allocator, argv[1..]);
        } else {
            try argv_storage.appendSlice(allocator, argv);
        }
    } else {
        try argv_storage.appendSlice(allocator, argv);
    }

    runtime_log.diagnostic(
        "spawnDetached begin arg0={s} resolved_arg0={s} argc={d} cwd={s}",
        .{
            if (argv.len > 0) argv[0] else "",
            resolved_arg0 orelse if (argv_storage.items.len > 0) argv_storage.items[0] else "",
            argv_storage.items.len,
            cwd orelse "(inherit)",
        },
    );

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    var child = try std.process.spawn(threaded.io(), .{
        .argv = argv_storage.items,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .cwd = if (cwd) |path| .{ .path = path } else .inherit,
        .environ_map = &env_map,
        .create_no_window = builtin.os.tag == .windows,
    });
    runtime_log.diagnostic("spawnDetached started arg0={s} pid={?}", .{ if (argv.len > 0) argv[0] else "", child.id });
    if (builtin.os.tag == .windows) {
        std.os.windows.CloseHandle(child.thread_handle);
        if (child.id) |process| std.os.windows.CloseHandle(process);
        child.id = null;
    }
}

fn runChild(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    cwd: ?[]const u8,
    max_output_bytes: usize,
) !std.process.RunResult {
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    return std.process.run(allocator, threaded.io(), .{
        .argv = argv,
        .cwd = if (cwd) |path| .{ .path = path } else .inherit,
        .stdout_limit = .limited(max_output_bytes),
        .stderr_limit = .limited(max_output_bytes),
    });
}

const PreferredEditorEnv = struct {
    name: []const u8,
    value: []const u8,
};

fn preferredEditorEnv() ?PreferredEditorEnv {
    const visual = std.c.getenv("VISUAL");
    if (visual) |value| {
        const trimmed = std.mem.trim(u8, std.mem.sliceTo(value, 0), &std.ascii.whitespace);
        if (trimmed.len > 0) return .{ .name = "VISUAL", .value = trimmed };
    }

    const editor = std.c.getenv("EDITOR");
    if (editor) |value| {
        const trimmed = std.mem.trim(u8, std.mem.sliceTo(value, 0), &std.ascii.whitespace);
        if (trimmed.len > 0) return .{ .name = "EDITOR", .value = trimmed };
    }
    return null;
}

fn canOpenConfiguredEditor() bool {
    const editor = preferredEditorEnv() orelse return false;
    if (!isTerminalEditorCommand(editor.value)) return true;
    return canLaunchConfiguredEditorTerminal();
}

fn openConfiguredEditor(
    allocator: std.mem.Allocator,
    editor: PreferredEditorEnv,
    project_path: []const u8,
) OpenProjectError!void {
    if (builtin.os.tag == .windows) {
        return openConfiguredEditorWindows(allocator, editor.value, project_path, project_path, isTerminalEditorCommand(editor.value), null);
    }
    const script = try std.fmt.allocPrint(allocator, "exec ${s} \"$1\"", .{editor.name});
    defer allocator.free(script);

    if (isTerminalEditorCommand(editor.value)) {
        return launchConfiguredEditorInTerminal(allocator, project_path, script);
    }
    return spawnDetached(allocator, &.{ "sh", "-lc", script, "verde-open-editor", project_path }, project_path);
}

fn openConfiguredEditorPath(
    allocator: std.mem.Allocator,
    editor: PreferredEditorEnv,
    working_dir: []const u8,
    path: []const u8,
    location: FileLocation,
) OpenProjectError!void {
    const executable = commandExecutableName(editor.value);
    if (std.ascii.eqlIgnoreCase(executable, "cursor")) {
        return openCursorPath(allocator, working_dir, path);
    }
    if (std.ascii.eqlIgnoreCase(executable, "code") or std.ascii.eqlIgnoreCase(executable, "code-insiders")) {
        return openVsCodePath(allocator, working_dir, path);
    }
    if (std.ascii.eqlIgnoreCase(executable, "zed") or std.ascii.eqlIgnoreCase(executable, "zeditor")) {
        return openZedPath(allocator, working_dir, path);
    }

    const location_arg = try vimLocationArgumentAlloc(allocator, executable, location);
    defer if (location_arg) |arg| allocator.free(arg);

    if (builtin.os.tag == .windows) {
        return openConfiguredEditorWindows(allocator, editor.value, working_dir, path, isTerminalEditorCommand(editor.value), location_arg);
    }

    const script = try std.fmt.allocPrint(allocator, "exec ${s} \"$1\"", .{editor.name});
    defer allocator.free(script);

    if (isTerminalEditorCommand(editor.value)) {
        const escaped_path = try shellSingleQuoteEscape(allocator, path);
        defer allocator.free(escaped_path);
        const terminal_script = if (location_arg) |arg|
            try std.fmt.allocPrint(allocator, "exec ${s} '{s}' -- '{s}'", .{ editor.name, arg, escaped_path })
        else
            try std.fmt.allocPrint(allocator, "exec ${s} -- '{s}'", .{ editor.name, escaped_path });
        defer allocator.free(terminal_script);
        return launchConfiguredEditorInTerminal(allocator, working_dir, terminal_script);
    }
    return spawnDetached(allocator, &.{ "sh", "-lc", script, "verde-open-file", path }, working_dir);
}

fn isTerminalEditorCommand(command: []const u8) bool {
    const trimmed = std.mem.trim(u8, command, &std.ascii.whitespace);
    if (trimmed.len == 0) return false;

    const executable = commandExecutableName(trimmed);
    if (executable.len == 0) return false;

    if (std.mem.eql(u8, executable, "emacs") or std.mem.eql(u8, executable, "emacsclient")) {
        return std.mem.indexOf(u8, trimmed, " -nw") != null or
            std.mem.indexOf(u8, trimmed, " --no-window-system") != null or
            std.mem.indexOf(u8, trimmed, " -t") != null or
            std.mem.indexOf(u8, trimmed, " --tty") != null or
            std.mem.indexOf(u8, trimmed, " --terminal") != null;
    }

    return std.mem.eql(u8, executable, "nvim") or
        std.mem.eql(u8, executable, "vim") or
        std.mem.eql(u8, executable, "vi") or
        std.mem.eql(u8, executable, "view") or
        std.mem.eql(u8, executable, "nano") or
        std.mem.eql(u8, executable, "hx") or
        std.mem.eql(u8, executable, "helix") or
        std.mem.eql(u8, executable, "kak") or
        std.mem.eql(u8, executable, "kakoune") or
        std.mem.eql(u8, executable, "micro");
}

fn vimLocationArgumentAlloc(
    allocator: std.mem.Allocator,
    executable: []const u8,
    location: FileLocation,
) std.mem.Allocator.Error!?[]u8 {
    const line = location.line orelse return null;
    const is_vim = std.ascii.eqlIgnoreCase(executable, "nvim") or
        std.ascii.eqlIgnoreCase(executable, "vim") or
        std.ascii.eqlIgnoreCase(executable, "vi") or
        std.ascii.eqlIgnoreCase(executable, "view");
    if (!is_vim) return null;

    if (location.column) |column| {
        return try std.fmt.allocPrint(allocator, "+call cursor({d},{d})", .{ line, column });
    }
    return try std.fmt.allocPrint(allocator, "+{d}", .{line});
}

fn commandExecutableName(command: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, command, &std.ascii.whitespace);
    if (trimmed.len == 0) return "";

    var end: usize = 0;
    while (end < trimmed.len and !std.ascii.isWhitespace(trimmed[end])) : (end += 1) {}
    var token = trimmed[0..end];
    token = std.mem.trim(u8, token, "\"'");
    return std.fs.path.basename(token);
}

fn canLaunchConfiguredEditorTerminal() bool {
    return switch (@import("builtin").os.tag) {
        .linux, .freebsd, .netbsd, .openbsd, .dragonfly => preferredLinuxTerminalLauncher() != null,
        .macos => commandExists("osascript"),
        .windows => commandExists("wt"),
        else => false,
    };
}

fn launchConfiguredEditorInTerminal(
    allocator: std.mem.Allocator,
    project_path: []const u8,
    script: []const u8,
) OpenProjectError!void {
    return switch (@import("builtin").os.tag) {
        .linux, .freebsd, .netbsd, .openbsd, .dragonfly => launchConfiguredEditorInLinuxTerminal(allocator, project_path, script),
        .macos => launchConfiguredEditorInMacTerminal(allocator, project_path, script),
        .windows => error.UnsupportedOperatingSystem,
        else => error.UnsupportedOperatingSystem,
    };
}

const ParsedCommand = struct {
    argv: std.ArrayList([]const u8) = .empty,

    fn deinit(self: *ParsedCommand, allocator: std.mem.Allocator) void {
        for (self.argv.items) |arg| allocator.free(arg);
        self.argv.deinit(allocator);
    }
};

fn parseConfiguredCommand(allocator: std.mem.Allocator, command: []const u8) !ParsedCommand {
    var parsed: ParsedCommand = .{};
    errdefer parsed.deinit(allocator);
    var current: std.ArrayList(u8) = .empty;
    defer current.deinit(allocator);
    var quote: ?u8 = null;
    var index: usize = 0;

    while (index < command.len) : (index += 1) {
        const byte = command[index];
        if (quote) |active_quote| {
            if (byte == active_quote) {
                quote = null;
            } else if (byte == '\\' and index + 1 < command.len and command[index + 1] == active_quote) {
                index += 1;
                try current.append(allocator, command[index]);
            } else {
                try current.append(allocator, byte);
            }
            continue;
        }
        if (byte == '\'' or byte == '"') {
            quote = byte;
        } else if (std.ascii.isWhitespace(byte)) {
            if (current.items.len > 0) try finishParsedCommandArg(allocator, &parsed, &current);
        } else {
            try current.append(allocator, byte);
        }
    }
    if (quote != null) return error.InvalidArguments;
    if (current.items.len > 0) try finishParsedCommandArg(allocator, &parsed, &current);
    if (parsed.argv.items.len == 0) return error.InvalidArguments;
    return parsed;
}

fn finishParsedCommandArg(allocator: std.mem.Allocator, parsed: *ParsedCommand, current: *std.ArrayList(u8)) !void {
    const arg = try current.toOwnedSlice(allocator);
    errdefer allocator.free(arg);
    try parsed.argv.append(allocator, arg);
}

fn openConfiguredEditorWindows(
    allocator: std.mem.Allocator,
    command: []const u8,
    working_dir: []const u8,
    target: []const u8,
    terminal: bool,
    location_arg: ?[]const u8,
) OpenProjectError!void {
    var parsed = parseConfiguredCommand(allocator, command) catch return error.LauncherUnavailable;
    defer parsed.deinit(allocator);
    if (location_arg) |arg| {
        const arg_copy = try allocator.dupe(u8, arg);
        parsed.argv.append(allocator, arg_copy) catch |err| {
            allocator.free(arg_copy);
            return err;
        };
    }
    const target_copy = try allocator.dupe(u8, target);
    errdefer allocator.free(target_copy);
    try parsed.argv.append(allocator, target_copy);

    if (!terminal) return spawnDetached(allocator, parsed.argv.items, working_dir);
    if (!commandExists("wt")) return error.LauncherUnavailable;
    var terminal_argv: std.ArrayList([]const u8) = .empty;
    defer terminal_argv.deinit(allocator);
    try terminal_argv.appendSlice(allocator, &.{ "wt", "-d", working_dir, "--" });
    try terminal_argv.appendSlice(allocator, parsed.argv.items);
    return spawnDetached(allocator, terminal_argv.items, working_dir);
}

const LinuxTerminalLauncher = enum {
    xdg_terminal_exec,
    alacritty,
    kitty,
    wezterm,
    foot,
    gnome_terminal,
    konsole,
    xterm,
};

fn preferredLinuxTerminalLauncher() ?LinuxTerminalLauncher {
    if (std.c.getenv("TERMINAL")) |terminal| {
        if (linuxTerminalLauncherForCommand(commandExecutableName(std.mem.sliceTo(terminal, 0)))) |launcher| return launcher;
    }

    if (commandExists("xdg-terminal-exec")) return .xdg_terminal_exec;
    if (commandExists("alacritty")) return .alacritty;
    if (commandExists("kitty")) return .kitty;
    if (commandExists("wezterm")) return .wezterm;
    if (commandExists("foot")) return .foot;
    if (commandExists("gnome-terminal")) return .gnome_terminal;
    if (commandExists("konsole")) return .konsole;
    if (commandExists("xterm")) return .xterm;
    return null;
}

fn linuxTerminalLauncherForCommand(command: []const u8) ?LinuxTerminalLauncher {
    if (std.mem.eql(u8, command, "xdg-terminal-exec")) return .xdg_terminal_exec;
    if (std.mem.eql(u8, command, "alacritty")) return .alacritty;
    if (std.mem.eql(u8, command, "kitty")) return .kitty;
    if (std.mem.eql(u8, command, "wezterm")) return .wezterm;
    if (std.mem.eql(u8, command, "foot")) return .foot;
    if (std.mem.eql(u8, command, "gnome-terminal")) return .gnome_terminal;
    if (std.mem.eql(u8, command, "konsole")) return .konsole;
    if (std.mem.eql(u8, command, "xterm")) return .xterm;
    return null;
}

fn launchConfiguredEditorInLinuxTerminal(
    allocator: std.mem.Allocator,
    project_path: []const u8,
    script: []const u8,
) OpenProjectError!void {
    const launcher = preferredLinuxTerminalLauncher() orelse return error.LauncherUnavailable;

    return switch (launcher) {
        .xdg_terminal_exec => {
            const dir_arg = try std.fmt.allocPrint(allocator, "--dir={s}", .{project_path});
            defer allocator.free(dir_arg);
            return spawnDetached(allocator, &.{ "xdg-terminal-exec", dir_arg, "--", "sh", "-lc", script, "verde-open-editor", project_path }, null);
        },
        .alacritty => spawnDetached(allocator, &.{ "alacritty", "--working-directory", project_path, "-e", "sh", "-lc", script, "verde-open-editor", project_path }, null),
        .kitty => spawnDetached(allocator, &.{ "kitty", "--directory", project_path, "sh", "-lc", script, "verde-open-editor", project_path }, null),
        .wezterm => spawnDetached(allocator, &.{ "wezterm", "start", "--cwd", project_path, "sh", "-lc", script, "verde-open-editor", project_path }, null),
        .foot => {
            const dir_arg = try std.fmt.allocPrint(allocator, "--working-directory={s}", .{project_path});
            defer allocator.free(dir_arg);
            return spawnDetached(allocator, &.{ "foot", dir_arg, "sh", "-lc", script, "verde-open-editor", project_path }, null);
        },
        .gnome_terminal => {
            const dir_arg = try std.fmt.allocPrint(allocator, "--working-directory={s}", .{project_path});
            defer allocator.free(dir_arg);
            return spawnDetached(allocator, &.{ "gnome-terminal", dir_arg, "--", "sh", "-lc", script, "verde-open-editor", project_path }, null);
        },
        .konsole => spawnDetached(allocator, &.{ "konsole", "--workdir", project_path, "-e", "sh", "-lc", script, "verde-open-editor", project_path }, null),
        .xterm => spawnDetached(allocator, &.{ "xterm", "-e", "sh", "-lc", script, "verde-open-editor", project_path }, project_path),
    };
}

fn launchConfiguredEditorInMacTerminal(
    allocator: std.mem.Allocator,
    project_path: []const u8,
    script: []const u8,
) OpenProjectError!void {
    if (!commandExists("osascript")) return error.LauncherUnavailable;

    const escaped_path = try escapeAppleScriptString(allocator, project_path);
    defer allocator.free(escaped_path);
    const escaped_script = try escapeAppleScriptString(allocator, script);
    defer allocator.free(escaped_script);
    const apple_script = try std.fmt.allocPrint(
        allocator,
        \\tell application "Terminal"
        \\activate
        \\do script "cd \"{s}\"; {s} verde-open-editor \"{s}\""
        \\end tell
    ,
        .{ escaped_path, escaped_script, escaped_path },
    );
    defer allocator.free(apple_script);

    return spawnDetached(allocator, &.{ "osascript", "-e", apple_script }, null);
}

/// Basename of the executable after resolving symlinks (PATH shims often point at another binary).
fn executableTargetBasenameAlloc(allocator: std.mem.Allocator, resolved_path: []const u8) std.mem.Allocator.Error![]const u8 {
    const use_realpath = builtin.link_libc and switch (builtin.os.tag) {
        .linux, .macos, .freebsd, .netbsd, .openbsd, .dragonfly, .illumos => true,
        else => false,
    };
    if (use_realpath) {
        const path_z = try allocator.dupeZ(u8, resolved_path);
        defer allocator.free(path_z);
        var resolved_buf: [std.posix.PATH_MAX]u8 = undefined;
        if (std.c.realpath(path_z.ptr, resolved_buf[0..].ptr)) |p| {
            const canon = std.mem.sliceTo(p, 0);
            return try allocator.dupe(u8, std.fs.path.basename(canon));
        }
    }
    return try allocator.dupe(u8, std.fs.path.basename(resolved_path));
}

fn resolvedPathLooksLikeCursorIdeBinary(resolved_path: []const u8) bool {
    switch (builtin.os.tag) {
        .windows => {
            const ext = std.fs.path.extension(resolved_path);
            if (std.ascii.eqlIgnoreCase(ext, ".cmd") or std.ascii.eqlIgnoreCase(ext, ".bat"))
                return false;
            return true;
        },
        .macos => {
            const fd = std.posix.openat(std.posix.AT.FDCWD, resolved_path, .{ .ACCMODE = .RDONLY }, 0) catch return false;
            defer _ = std.c.close(fd);
            var header: [4]u8 = undefined;
            const n = std.posix.read(fd, &header) catch return false;
            if (n >= 2 and header[0] == '#' and header[1] == '!') return false;
            return true;
        },
        else => {
            const fd = std.posix.openat(std.posix.AT.FDCWD, resolved_path, .{ .ACCMODE = .RDONLY }, 0) catch return false;
            defer _ = std.c.close(fd);
            var header: [4]u8 = undefined;
            const n = std.posix.read(fd, &header) catch return false;
            if (n >= 2 and header[0] == '#' and header[1] == '!') return false;
            return n >= 4 and header[0] == 0x7f and header[1] == 'E' and header[2] == 'L' and header[3] == 'F';
        },
    }
}

/// Cursor IDE ships a native `cursor` CLI; `cursor-agent` / shell shims are not the desktop editor.
fn hasCursorIdeCliResolved(allocator: std.mem.Allocator) bool {
    var env_map = process_env.buildAugmentedEnvMap(allocator) catch return false;
    defer env_map.deinit();
    const resolved = process_env.resolveExecutableInEnvMapAlloc(allocator, &env_map, "cursor") catch return false;
    defer allocator.free(resolved);
    const base_owned = executableTargetBasenameAlloc(allocator, resolved) catch return false;
    defer allocator.free(base_owned);
    const base = base_owned;
    if (std.ascii.eqlIgnoreCase(base, "cursor-agent") or std.ascii.eqlIgnoreCase(base, "cursor-agent.exe"))
        return false;

    const basename_ok = (std.ascii.eqlIgnoreCase(base, "cursor") or std.ascii.eqlIgnoreCase(base, "cursor.exe")) or
        (std.ascii.startsWithIgnoreCase(base, "cursor-") and !std.ascii.startsWithIgnoreCase(base, "cursor-agent"));
    if (!basename_ok) return false;

    return resolvedPathLooksLikeCursorIdeBinary(resolved);
}

fn hasVsCodeExeResolved(allocator: std.mem.Allocator, exe_name: []const u8) bool {
    var env_map = process_env.buildAugmentedEnvMap(allocator) catch return false;
    defer env_map.deinit();
    const resolved = process_env.resolveExecutableInEnvMapAlloc(allocator, &env_map, exe_name) catch return false;
    defer allocator.free(resolved);
    const base_owned = executableTargetBasenameAlloc(allocator, resolved) catch return false;
    defer allocator.free(base_owned);
    const base = base_owned;
    if (std.ascii.eqlIgnoreCase(base, exe_name)) return true;
    var buf: [96]u8 = undefined;
    const as_exe = std.fmt.bufPrint(&buf, "{s}.exe", .{exe_name}) catch return false;
    if (std.ascii.eqlIgnoreCase(base, as_exe)) return true;
    const as_cmd = std.fmt.bufPrint(&buf, "{s}.cmd", .{exe_name}) catch return false;
    return std.ascii.eqlIgnoreCase(base, as_cmd);
}

fn hasZedExeResolved(allocator: std.mem.Allocator, exe_name: []const u8) bool {
    var env_map = process_env.buildAugmentedEnvMap(allocator) catch return false;
    defer env_map.deinit();
    const resolved = process_env.resolveExecutableInEnvMapAlloc(allocator, &env_map, exe_name) catch return false;
    defer allocator.free(resolved);
    const base_owned = executableTargetBasenameAlloc(allocator, resolved) catch return false;
    defer allocator.free(base_owned);
    const base = base_owned;
    if (std.ascii.eqlIgnoreCase(base, exe_name)) return true;
    var buf: [96]u8 = undefined;
    const as_exe = std.fmt.bufPrint(&buf, "{s}.exe", .{exe_name}) catch return false;
    return std.ascii.eqlIgnoreCase(base, as_exe);
}

fn hasCursorLauncher() bool {
    if (macApplicationExists("Cursor")) return true;
    return hasCursorIdeCliResolved(std.heap.page_allocator);
}

fn openCursor(allocator: std.mem.Allocator, project_path: []const u8) OpenProjectError!void {
    if (macApplicationExists("Cursor")) return openMacApplication(allocator, "Cursor", project_path);
    if (hasCursorIdeCliResolved(std.heap.page_allocator))
        return spawnDetached(allocator, &.{ "cursor", project_path }, project_path);
    return error.LauncherUnavailable;
}

fn openCursorPath(allocator: std.mem.Allocator, working_dir: []const u8, file_path: []const u8) OpenProjectError!void {
    if (macApplicationExists("Cursor")) return openMacApplication(allocator, "Cursor", file_path);
    if (hasCursorIdeCliResolved(std.heap.page_allocator))
        return spawnDetached(allocator, &.{ "cursor", file_path }, working_dir);
    return error.LauncherUnavailable;
}

fn hasVsCodeLauncher() bool {
    if (macApplicationExists("Visual Studio Code") or macApplicationExists("Visual Studio Code - Insiders")) return true;
    const a = std.heap.page_allocator;
    return hasVsCodeExeResolved(a, "code") or hasVsCodeExeResolved(a, "code-insiders");
}

fn openVsCode(allocator: std.mem.Allocator, project_path: []const u8) OpenProjectError!void {
    if (macApplicationExists("Visual Studio Code")) return openMacApplication(allocator, "Visual Studio Code", project_path);
    if (macApplicationExists("Visual Studio Code - Insiders")) return openMacApplication(allocator, "Visual Studio Code - Insiders", project_path);
    const a = std.heap.page_allocator;
    if (hasVsCodeExeResolved(a, "code"))
        return spawnDetached(allocator, &.{ "code", project_path }, project_path);
    if (hasVsCodeExeResolved(a, "code-insiders"))
        return spawnDetached(allocator, &.{ "code-insiders", project_path }, project_path);
    return error.LauncherUnavailable;
}

fn openVsCodePath(allocator: std.mem.Allocator, working_dir: []const u8, file_path: []const u8) OpenProjectError!void {
    if (macApplicationExists("Visual Studio Code")) return openMacApplication(allocator, "Visual Studio Code", file_path);
    if (macApplicationExists("Visual Studio Code - Insiders")) return openMacApplication(allocator, "Visual Studio Code - Insiders", file_path);
    const a = std.heap.page_allocator;
    if (hasVsCodeExeResolved(a, "code"))
        return spawnDetached(allocator, &.{ "code", file_path }, working_dir);
    if (hasVsCodeExeResolved(a, "code-insiders"))
        return spawnDetached(allocator, &.{ "code-insiders", file_path }, working_dir);
    return error.LauncherUnavailable;
}

fn hasZedLauncher() bool {
    if (macApplicationExists("Zed")) return true;
    const a = std.heap.page_allocator;
    return hasZedExeResolved(a, "zed") or hasZedExeResolved(a, "zeditor");
}

fn openZed(allocator: std.mem.Allocator, project_path: []const u8) OpenProjectError!void {
    if (macApplicationExists("Zed")) return openMacApplication(allocator, "Zed", project_path);
    const a = std.heap.page_allocator;
    if (hasZedExeResolved(a, "zed"))
        return spawnDetached(allocator, &.{ "zed", project_path }, project_path);
    if (hasZedExeResolved(a, "zeditor"))
        return spawnDetached(allocator, &.{ "zeditor", project_path }, project_path);
    return error.LauncherUnavailable;
}

fn openZedPath(allocator: std.mem.Allocator, working_dir: []const u8, file_path: []const u8) OpenProjectError!void {
    if (macApplicationExists("Zed")) return openMacApplication(allocator, "Zed", file_path);
    const a = std.heap.page_allocator;
    if (hasZedExeResolved(a, "zed"))
        return spawnDetached(allocator, &.{ "zed", file_path }, working_dir);
    if (hasZedExeResolved(a, "zeditor"))
        return spawnDetached(allocator, &.{ "zeditor", file_path }, working_dir);
    return error.LauncherUnavailable;
}

fn openMacApplication(allocator: std.mem.Allocator, app_name: []const u8, project_path: []const u8) OpenProjectError!void {
    if (!commandExists("open")) return error.LauncherUnavailable;
    return spawnDetached(allocator, &.{ "open", "-a", app_name, project_path }, project_path);
}

fn openKnownEditorPath(allocator: std.mem.Allocator, working_dir: []const u8, file_path: []const u8) OpenProjectError!void {
    openCursorPath(allocator, working_dir, file_path) catch |err| switch (err) {
        error.LauncherUnavailable => {},
        else => return err,
    };
    openVsCodePath(allocator, working_dir, file_path) catch |err| switch (err) {
        error.LauncherUnavailable => {},
        else => return err,
    };
    return openZedPath(allocator, working_dir, file_path);
}

fn revealFileInFileManager(allocator: std.mem.Allocator, file_path: []const u8) OpenProjectError!void {
    return switch (@import("builtin").os.tag) {
        .macos => {
            if (!commandExists("open")) return error.LauncherUnavailable;
            return spawnDetached(allocator, &.{ "open", "-R", file_path }, null);
        },
        .linux, .freebsd, .netbsd, .openbsd, .dragonfly => {
            const parent_dir = std.fs.path.dirname(file_path) orelse file_path;
            return openProjectDirectory(allocator, parent_dir);
        },
        .windows => {
            if (!windows_integrations.revealFile(file_path)) return error.LauncherUnavailable;
        },
        else => error.UnsupportedOperatingSystem,
    };
}

fn macApplicationExists(app_name: []const u8) bool {
    if (@import("builtin").os.tag != .macos) return false;

    const system_path = std.fmt.allocPrint(std.heap.page_allocator, "/Applications/{s}.app", .{app_name}) catch return false;
    defer std.heap.page_allocator.free(system_path);
    if (directoryExistsAbsolute(system_path)) return true;

    const home = std.mem.sliceTo(std.c.getenv("HOME") orelse return false, 0);
    const user_path = std.fmt.allocPrint(std.heap.page_allocator, "{s}/Applications/{s}.app", .{ home, app_name }) catch return false;
    defer std.heap.page_allocator.free(user_path);
    return directoryExistsAbsolute(user_path);
}

fn directoryExistsAbsolute(path: []const u8) bool {
    var threaded = std.Io.Threaded.init_single_threaded;
    var dir = std.Io.Dir.openDirAbsolute(threaded.io(), path, .{}) catch return false;
    defer dir.close(threaded.io());
    return true;
}

fn commandExists(name: []const u8) bool {
    return process_env.commandExists(name);
}

fn formatSendWorkerError(
    allocator: std.mem.Allocator,
    provider: provider_models.Provider,
    err: anyerror,
) ![]u8 {
    return switch (err) {
        error.FileNotFound => switch (provider) {
            .claude => allocator.dupe(
                u8,
                "Node was not found on PATH. Install Node.js and make sure packaged app launches can find the node executable.",
            ),
            .cursor => allocator.dupe(
                u8,
                "Cursor CLI was not found. Install Cursor CLI, make sure `agent` is on PATH, then run `agent login`.",
            ),
            else => std.fmt.allocPrint(
                allocator,
                "{s} CLI was not found. Install it and make sure it is available on PATH for packaged app launches.",
                .{providerLabel(provider)},
            ),
        },
        error.ProviderBridgeNotFound => allocator.dupe(
            u8,
            "The bundled provider bridge was not found. Rebuild or reinstall Verde so provider_bridge.mjs is installed.",
        ),
        error.OpencodeServerUnavailable => allocator.dupe(
            u8,
            "OpenCode did not start. Ensure the opencode CLI is installed, authenticated, and reachable from this session.",
        ),
        error.OpencodeEmptyReply => allocator.dupe(
            u8,
            "OpenCode ended the turn without producing any output. Please retry the prompt.",
        ),
        error.CursorAttachmentsUnsupported => allocator.dupe(
            u8,
            "Cursor does not currently support local image attachments through this provider.",
        ),
        error.CursorSignedOut => allocator.dupe(
            u8,
            "Cursor is not authenticated. Run `agent login` or set CURSOR_API_KEY before sending.",
        ),
        error.CursorAcpFailed => allocator.dupe(
            u8,
            "Cursor ACP request failed. Check that the Cursor CLI works with `agent status` and `agent acp`.",
        ),
        error.UnsupportedRemoteProvider => allocator.dupe(
            u8,
            "Remote Herdr GUI sends currently support Codex only. Use the Herdr terminal/TUI pane for this provider.",
        ),
        else => std.fmt.allocPrint(allocator, "{s} request failed. Check the provider status and retry.", .{providerLabel(provider)}),
    };
}

const CLAUDE_USAGE_LIMIT_MESSAGE = "Claude's 5-hour usage limit has been reached. View usage to see the reset time and your other plan limits.";
const CLAUDE_PLAN_LIMIT_MESSAGE = "Claude's plan usage limit has been reached. View usage to see which window was exhausted and when it resets.";
const CLAUDE_WEEKLY_LIMIT_MESSAGE = "Claude's weekly usage limit has been reached. View usage to see the reset time and your other plan limits.";
const CLAUDE_OPUS_WEEKLY_LIMIT_MESSAGE = "Claude's weekly Opus usage limit has been reached. View usage to see the reset time and your other plan limits.";
const CLAUDE_SONNET_WEEKLY_LIMIT_MESSAGE = "Claude's weekly Sonnet usage limit has been reached. View usage to see the reset time and your other plan limits.";
const CODEX_USAGE_LIMIT_MESSAGE = "Codex's usage limit has been reached. View usage to see which window was exhausted and when it resets.";
const CODEX_FIVE_HOUR_LIMIT_MESSAGE = "Codex's 5-hour usage limit has been reached. View usage to see the reset time and your other plan limits.";

fn asciiContainsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var index: usize = 0;
    while (index + needle.len <= haystack.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[index .. index + needle.len], needle)) return true;
    }
    return false;
}

fn isProviderUsageLimitFailure(provider: provider_models.Provider, message: []const u8) bool {
    if (provider != .claude and provider != .codex) return false;
    const markers = [_][]const u8{
        "usage limit",
        "usage_limit",
        "hit your limit",
        "limit has been reached",
        "5-hour limit",
        "5 hour limit",
        "five hour limit",
    };
    for (markers) |marker| {
        if (asciiContainsIgnoreCase(message, marker)) return true;
    }
    return false;
}

/// Converts provider failures into stable, actionable transcript text.
pub fn providerFailureDisplayMessage(provider: provider_models.Provider, message: []const u8) []const u8 {
    if (!isProviderUsageLimitFailure(provider, message)) return message;
    return switch (provider) {
        .claude => if (asciiContainsIgnoreCase(message, "seven_day_opus") or asciiContainsIgnoreCase(message, "weekly opus"))
            CLAUDE_OPUS_WEEKLY_LIMIT_MESSAGE
        else if (asciiContainsIgnoreCase(message, "seven_day_sonnet") or asciiContainsIgnoreCase(message, "weekly sonnet"))
            CLAUDE_SONNET_WEEKLY_LIMIT_MESSAGE
        else if (asciiContainsIgnoreCase(message, "seven_day") or asciiContainsIgnoreCase(message, "weekly usage"))
            CLAUDE_WEEKLY_LIMIT_MESSAGE
        else if (asciiContainsIgnoreCase(message, "five_hour") or
            asciiContainsIgnoreCase(message, "5-hour") or
            asciiContainsIgnoreCase(message, "5 hour") or
            asciiContainsIgnoreCase(message, "five hour"))
            CLAUDE_USAGE_LIMIT_MESSAGE
        else
            CLAUDE_PLAN_LIMIT_MESSAGE,
        .codex => if (asciiContainsIgnoreCase(message, "5-hour") or
            asciiContainsIgnoreCase(message, "5 hour") or
            asciiContainsIgnoreCase(message, "five hour"))
            CODEX_FIVE_HOUR_LIMIT_MESSAGE
        else
            CODEX_USAGE_LIMIT_MESSAGE,
        else => unreachable,
    };
}

/// Identifies a normalized provider usage-limit row for transcript rendering.
pub fn usageLimitProviderForDisplayMessage(message: []const u8) ?provider_models.Provider {
    const claude_messages = [_][]const u8{
        CLAUDE_USAGE_LIMIT_MESSAGE,
        CLAUDE_PLAN_LIMIT_MESSAGE,
        CLAUDE_WEEKLY_LIMIT_MESSAGE,
        CLAUDE_OPUS_WEEKLY_LIMIT_MESSAGE,
        CLAUDE_SONNET_WEEKLY_LIMIT_MESSAGE,
    };
    for (claude_messages) |candidate| {
        if (std.mem.eql(u8, message, candidate)) return .claude;
    }
    if (std.mem.eql(u8, message, CODEX_USAGE_LIMIT_MESSAGE) or
        std.mem.eql(u8, message, CODEX_FIVE_HOUR_LIMIT_MESSAGE)) return .codex;
    return null;
}

/// Identifies persisted failures written before provider error details were retained.
pub fn legacyProviderFailureForDisplayMessage(message_raw: []const u8) ?provider_models.Provider {
    const message = std.mem.trim(u8, message_raw, &std.ascii.whitespace);
    const claude_messages = [_][]const u8{
        "ClaudeRequestFailed",
        "Provider request failed: ClaudeRequestFailed",
    };
    for (claude_messages) |candidate| {
        if (std.mem.eql(u8, message, candidate)) return .claude;
    }
    const codex_messages = [_][]const u8{
        "CodexTurnFailed",
        "Provider request failed: CodexTurnFailed",
    };
    for (codex_messages) |candidate| {
        if (std.mem.eql(u8, message, candidate)) return .codex;
    }
    return null;
}

/// Returns the provider for any failure row that can offer a `/usage` action.
pub fn providerFailureActionProvider(message: []const u8) ?provider_models.Provider {
    return usageLimitProviderForDisplayMessage(message) orelse legacyProviderFailureForDisplayMessage(message);
}

/// Replaces opaque legacy enum names with an honest explanation.
pub fn providerFailureActionBody(message: []const u8) []const u8 {
    const provider = legacyProviderFailureForDisplayMessage(message) orelse return message;
    return switch (provider) {
        .claude => "This older Claude failure did not save its original details. View current usage to check whether a plan limit caused it.",
        .codex => "This older Codex failure did not save its original details. View current usage to check whether a plan limit caused it.",
        else => unreachable,
    };
}

fn shellSingleQuoteEscape(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var escaped: std.ArrayList(u8) = .empty;
    errdefer escaped.deinit(allocator);

    for (value) |char| {
        if (char == '\'') {
            try escaped.appendSlice(allocator, "'\\''");
        } else {
            try escaped.append(allocator, char);
        }
    }

    return escaped.toOwnedSlice(allocator);
}

pub fn approvalPolicyForMode(_: provider_models.Provider, mode: provider_models.AccessMode) ?ai_harness.ApprovalPolicy {
    return switch (mode) {
        .full_access => .never,
        .supervised => .on_request,
    };
}

pub fn serviceTierForMode(provider: provider_models.Provider, fast_mode: provider_models.FastMode) ?ai_harness.ServiceTier {
    if (provider != .codex) return null;
    return switch (fast_mode) {
        .on => .fast,
        .off => null,
    };
}

pub fn sandboxModeForMode(provider: provider_models.Provider, mode: provider_models.AccessMode) ?ai_harness.SandboxMode {
    if (provider != .codex and provider != .claude) return null;
    return switch (mode) {
        .full_access => .danger_full_access,
        .supervised => .workspace_write,
    };
}
fn handleSendThreadId(context: ?*anyopaque, thread_id: []const u8) void {
    const send_state: *chat_types.SendState = @ptrCast(@alignCast(context orelse return));
    const page_alloc = std.heap.page_allocator;

    send_state.mutex.lock();
    defer send_state.mutex.unlock();
    if (send_state.status != .pending) return;

    if (send_state.provisional_provider_thread_id) |existing| {
        if (std.mem.eql(u8, existing, thread_id)) return;
        page_alloc.free(existing);
        send_state.provisional_provider_thread_id = null;
    }

    send_state.provisional_provider_thread_id = page_alloc.dupe(u8, thread_id) catch |err| {
        std.debug.print("[codex-debug] failed to store provisional thread id len={d}: {s}\n", .{ thread_id.len, @errorName(err) });
        runtime_log.diagnostic("failed to store provisional thread id len={d}: {s}", .{ thread_id.len, @errorName(err) });
        return;
    };
    send_state.ui_revision +%= 1;
    loop_wakeup.notify();
}
fn handleSendTurnId(context: ?*anyopaque, turn_id: []const u8) void {
    const send_state: *chat_types.SendState = @ptrCast(@alignCast(context orelse return));
    const page_alloc = std.heap.page_allocator;

    send_state.mutex.lock();
    defer send_state.mutex.unlock();
    if (send_state.status != .pending) return;

    if (send_state.active_turn_id) |existing| {
        if (std.mem.eql(u8, existing, turn_id)) return;
        page_alloc.free(existing);
        send_state.active_turn_id = null;
    }

    send_state.active_turn_id = page_alloc.dupe(u8, turn_id) catch |err| {
        std.debug.print("[codex-debug] failed to store active turn id len={d}: {s}\n", .{ turn_id.len, @errorName(err) });
        runtime_log.diagnostic("failed to store active turn id len={d}: {s}", .{ turn_id.len, @errorName(err) });
        return;
    };
    send_state.ui_revision +%= 1;
    loop_wakeup.notify();
}
fn handleSendStreamDelta(context: ?*anyopaque, delta: []const u8) void {
    const send_state: *chat_types.SendState = @ptrCast(@alignCast(context orelse return));
    const page_alloc = std.heap.page_allocator;

    send_state.mutex.lock();
    defer send_state.mutex.unlock();
    if (send_state.status != .pending) return;
    send_state.partial_text.appendSlice(page_alloc, delta) catch |err| {
        std.debug.print(
            "[codex-debug] failed to append stream delta delta_len={d} partial_len={d}: {s}\n",
            .{ delta.len, send_state.partial_text.items.len, @errorName(err) },
        );
        runtime_log.diagnostic(
            "failed to append stream delta delta_len={d} partial_len={d}: {s}",
            .{ delta.len, send_state.partial_text.items.len, @errorName(err) },
        );
        return;
    };
    send_state.ui_revision +%= 1;
    // Wake the render loop now; otherwise streamed tokens only appear on the
    // next PENDING_SEND timeout tick (~4fps). loop_wakeup coalesces bursts.
    loop_wakeup.notify();
}
fn handleSendStreamEvent(context: ?*anyopaque, event: ai_harness.StreamEvent) void {
    const send_state: *chat_types.SendState = @ptrCast(@alignCast(context orelse return));
    const page_alloc = std.heap.page_allocator;

    send_state.mutex.lock();
    defer send_state.mutex.unlock();
    if (send_state.status != .pending) return;

    switch (event) {
        .message => |message| {
            flushPendingAssistantTextLocked(send_state, page_alloc);
            if (send_state.pending_events.items.len > 0) {
                const last = send_state.pending_events.items[send_state.pending_events.items.len - 1];
                if (last.role == .system and std.mem.eql(u8, last.author, message.title) and std.mem.eql(u8, last.body, message.body)) {
                    return;
                }
            }

            const owned_author = page_alloc.dupe(u8, message.title) catch return;
            errdefer page_alloc.free(owned_author);
            const owned_body = page_alloc.dupe(u8, message.body) catch return;
            errdefer page_alloc.free(owned_body);

            send_state.pending_events.append(page_alloc, .{
                .role = .system,
                .author = owned_author,
                .body = owned_body,
            }) catch {
                page_alloc.free(owned_author);
                page_alloc.free(owned_body);
                return;
            };
            send_state.ui_revision +%= 1;
            loop_wakeup.notify();
        },
        .tool_call => |tool_call| {
            // Content-less reasoning drives the "Thinking" header indicator
            // instead of a timeline row, so no text flush either: nothing is
            // inserted into the transcript.
            if (transientThinkStatus(tool_call)) |thinking| {
                send_state.thinking = thinking;
                send_state.ui_revision +%= 1;
                loop_wakeup.notify();
                return;
            }
            flushPendingAssistantTextLocked(send_state, page_alloc);
            upsertPendingToolCallEvent(page_alloc, &send_state.pending_events, tool_call) catch return;
            send_state.ui_revision +%= 1;
            loop_wakeup.notify();
        },
        .diff => |diff| {
            flushPendingAssistantTextLocked(send_state, page_alloc);
            applyPendingDiffUpdateLocked(page_alloc, send_state, diff);
            send_state.ui_revision +%= 1;
            loop_wakeup.notify();
        },
    }
}

fn toolCallDefaultTitle(tool_call: ai_harness.ToolCallUpdate) []const u8 {
    return switch (tool_call.kind orelse .other) {
        .read => "Read",
        .edit => "Edit",
        .delete => "Delete",
        .move => "Move",
        .search => "Search",
        .execute => if ((tool_call.status orelse .unknown) == .failed) "Command failed" else "Ran command",
        .think => switch (tool_call.status orelse .unknown) {
            // Live reasoning reads as an activity ("Thinking"), not a noun.
            .pending, .in_progress => "Thinking",
            else => "Think",
        },
        .fetch => "Fetch",
        .mcp => "MCP tool",
        .other => "Cursor tool",
    };
}

fn isGenericMcpToolTitle(title: []const u8) bool {
    return std.ascii.eqlIgnoreCase(title, "MCP: tool") or
        std.ascii.eqlIgnoreCase(title, "MCP tool");
}

fn toolCallDisplayAuthor(tool_call: ai_harness.ToolCallUpdate) []const u8 {
    // MCP method names belong in the card body. Keeping the stable author
    // makes every provider use the structured command-card renderer instead
    // of treating provider-specific method names as ordinary system bubbles.
    if ((tool_call.kind orelse .other) == .mcp) return "MCP tool";
    return toolCallDefaultTitle(tool_call);
}

fn toolCallBodyAlloc(allocator: std.mem.Allocator, tool_call: ai_harness.ToolCallUpdate) !?[]u8 {
    const Field = struct {
        label: []const u8,
        value: ?[]const u8,
    };
    const fields = [_]Field{
        .{ .label = "Input", .value = tool_call.input },
        .{ .label = "Output", .value = tool_call.output },
        .{ .label = "Error", .value = tool_call.error_text },
        .{ .label = "Locations", .value = tool_call.locations },
    };

    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var wrote = false;
    const title = std.mem.trim(u8, tool_call.title, &std.ascii.whitespace);
    const generic_mcp_title = (tool_call.kind orelse .other) == .mcp and isGenericMcpToolTitle(title);
    if (title.len > 0 and !generic_mcp_title and !std.mem.eql(u8, title, toolCallDisplayAuthor(tool_call))) {
        try writer.writer.print("Tool:\n{s}", .{title});
        wrote = true;
    }
    for (fields) |field| {
        const value = field.value orelse continue;
        const trimmed = std.mem.trim(u8, value, &std.ascii.whitespace);
        if (trimmed.len == 0) continue;
        const pretty_json = if ((tool_call.kind orelse .other) == .mcp)
            try prettyJsonContainerAlloc(allocator, trimmed)
        else
            null;
        defer if (pretty_json) |owned| allocator.free(owned);
        const display_value = pretty_json orelse trimmed;
        if (wrote) try writer.writer.writeAll("\n\n");
        try writer.writer.print("{s}:\n{s}", .{ field.label, display_value });
        wrote = true;
    }
    if (!wrote) {
        const raw = tool_call.raw orelse {
            writer.deinit();
            return null;
        };
        const trimmed = std.mem.trim(u8, raw, &std.ascii.whitespace);
        if (trimmed.len == 0) {
            writer.deinit();
            return null;
        }
        try writer.writer.print("Raw event:\n{s}", .{trimmed});
    }
    return try writer.toOwnedSlice();
}

fn prettyJsonContainerAlloc(allocator: std.mem.Allocator, text: []const u8) !?[]u8 {
    if (text.len < 2 or (text[0] != '{' and text[0] != '[')) return null;

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, text, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object and parsed.value != .array) return null;

    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var stringify: std.json.Stringify = .{
        .writer = &writer.writer,
        .options = .{ .whitespace = .indent_2 },
    };
    try stringify.write(parsed.value);
    return try writer.toOwnedSlice();
}

fn hasVisibleText(value: ?[]const u8) bool {
    const text = value orelse return false;
    return std.mem.trim(u8, text, &std.ascii.whitespace).len > 0;
}

fn hasToolCallContent(input: ?[]const u8, output: ?[]const u8, error_text: ?[]const u8) bool {
    return hasVisibleText(input) or hasVisibleText(output) or hasVisibleText(error_text);
}

/// Detects content-less think lifecycle updates. These carry pure liveness
/// ("the model is reasoning right now"), so the pending stream header shows
/// them next to the elapsed-time label instead of a transcript row. Returns
/// whether reasoning is currently active, or null for think updates that
/// carry real thought content (those stay timeline rows).
pub fn transientThinkStatus(tool_call: ai_harness.ToolCallUpdate) ?bool {
    if ((tool_call.kind orelse .other) != .think) return null;
    if (hasToolCallContent(tool_call.input, tool_call.output, tool_call.error_text)) return null;
    return switch (tool_call.status orelse .unknown) {
        .pending, .in_progress => true,
        else => false,
    };
}

/// A think row without thought content is pure liveness feedback ("Thinking");
/// once its terminal status lands there is nothing left worth keeping, so the
/// row disappears instead of persisting as a confusing "Think - completed".
fn isTransientThinkTerminal(
    kind: ?ai_harness.ToolCallKind,
    status: ?ai_harness.ToolCallStatus,
    input: ?[]const u8,
    output: ?[]const u8,
    error_text: ?[]const u8,
) bool {
    if ((kind orelse .other) != .think) return false;
    switch (status orelse .unknown) {
        .completed, .failed, .cancelled => {},
        else => return false,
    }
    return !hasToolCallContent(input, output, error_text);
}

/// Content-less rows need a placeholder body. Think rows use a quiet ellipsis:
/// the raw status tagName both reads poorly next to "Thinking" and matches the
/// status-only-row hiding in the transcript renderer.
fn toolCallFallbackBody(kind: ?ai_harness.ToolCallKind, status: ?ai_harness.ToolCallStatus) []const u8 {
    if ((kind orelse .other) == .think) return "…";
    return @tagName(status orelse .unknown);
}

/// Upserts a provider tool-call lifecycle update by stable call identity.
///
/// Updates may omit title/content, so existing useful fields are retained
/// while status/kind advance. An empty call ID is treated as an append-only
/// compatibility event because it cannot be correlated safely.
pub fn upsertPendingToolCallEvent(
    allocator: std.mem.Allocator,
    events: *std.ArrayListUnmanaged(chat_types.PendingTimelineEvent),
    tool_call: ai_harness.ToolCallUpdate,
) !void {
    if (tool_call.call_id.len > 0) {
        for (events.items, 0..) |*existing, index| {
            const existing_id = existing.tool_call_id orelse continue;
            if (!std.mem.eql(u8, existing_id, tool_call.call_id)) continue;

            if (std.mem.trim(u8, tool_call.title, &std.ascii.whitespace).len > 0) {
                try replaceOptionalOwned(allocator, &existing.tool_call_title, tool_call.title);
            }
            if (tool_call.input) |value| try replaceOptionalOwned(allocator, &existing.tool_call_input, value);
            if (tool_call.output) |value| try replaceOptionalOwned(allocator, &existing.tool_call_output, value);
            if (tool_call.error_text) |value| try replaceOptionalOwned(allocator, &existing.tool_call_error, value);
            if (tool_call.locations) |value| try replaceOptionalOwned(allocator, &existing.tool_call_locations, value);
            if (tool_call.raw) |value| try replaceOptionalOwned(allocator, &existing.tool_call_raw, value);
            if (tool_call.kind) |kind| existing.tool_call_kind = kind;
            if (tool_call.status) |status| existing.tool_call_status = status;

            if (isTransientThinkTerminal(
                existing.tool_call_kind,
                existing.tool_call_status,
                existing.tool_call_input,
                existing.tool_call_output,
                existing.tool_call_error,
            )) {
                freePendingTimelineEvent(allocator, existing.*);
                _ = events.orderedRemove(index);
                return;
            }

            const merged: ai_harness.ToolCallUpdate = .{
                .call_id = existing_id,
                .title = existing.tool_call_title orelse "",
                .kind = existing.tool_call_kind,
                .status = existing.tool_call_status,
                .input = existing.tool_call_input,
                .output = existing.tool_call_output,
                .error_text = existing.tool_call_error,
                .locations = existing.tool_call_locations,
                .raw = existing.tool_call_raw,
            };
            const owned_author = try allocator.dupe(u8, toolCallDisplayAuthor(merged));
            errdefer allocator.free(owned_author);
            const owned_body = (try toolCallBodyAlloc(allocator, merged)) orelse try allocator.dupe(u8, toolCallFallbackBody(merged.kind, merged.status));
            errdefer allocator.free(owned_body);
            allocator.free(existing.author);
            allocator.free(existing.body);
            existing.author = owned_author;
            existing.body = owned_body;
            return;
        }
    }

    // A terminal think event with no prior row (e.g. attach-tail replay)
    // would only materialize the row we intend to drop; skip it entirely.
    if (isTransientThinkTerminal(tool_call.kind, tool_call.status, tool_call.input, tool_call.output, tool_call.error_text)) return;

    const body = try toolCallBodyAlloc(allocator, tool_call);
    errdefer if (body) |owned| allocator.free(owned);
    const title = toolCallDisplayAuthor(tool_call);
    const owned_author = try allocator.dupe(u8, title);
    errdefer allocator.free(owned_author);
    const owned_body = body orelse try allocator.dupe(u8, toolCallFallbackBody(tool_call.kind, tool_call.status));
    errdefer allocator.free(owned_body);
    const owned_call_id = if (tool_call.call_id.len > 0)
        try allocator.dupe(u8, tool_call.call_id)
    else
        null;
    errdefer if (owned_call_id) |id| allocator.free(id);
    const owned_title = try dupeOptionalNonEmpty(allocator, tool_call.title);
    errdefer if (owned_title) |value| allocator.free(value);
    const owned_input = try dupeOptional(allocator, tool_call.input);
    errdefer if (owned_input) |value| allocator.free(value);
    const owned_output = try dupeOptional(allocator, tool_call.output);
    errdefer if (owned_output) |value| allocator.free(value);
    const owned_error = try dupeOptional(allocator, tool_call.error_text);
    errdefer if (owned_error) |value| allocator.free(value);
    const owned_locations = try dupeOptional(allocator, tool_call.locations);
    errdefer if (owned_locations) |value| allocator.free(value);
    const owned_raw = try dupeOptional(allocator, tool_call.raw);
    errdefer if (owned_raw) |value| allocator.free(value);

    try events.append(allocator, .{
        .role = .system,
        .author = owned_author,
        .body = owned_body,
        .tool_call_id = owned_call_id,
        .tool_call_kind = tool_call.kind orelse .other,
        .tool_call_status = tool_call.status orelse .unknown,
        .tool_call_title = owned_title,
        .tool_call_input = owned_input,
        .tool_call_output = owned_output,
        .tool_call_error = owned_error,
        .tool_call_locations = owned_locations,
        .tool_call_raw = owned_raw,
    });
}

fn replaceOptionalOwned(allocator: std.mem.Allocator, target: *?[]u8, value: []const u8) !void {
    const owned = try allocator.dupe(u8, value);
    if (target.*) |old| allocator.free(old);
    target.* = owned;
}

fn dupeOptional(allocator: std.mem.Allocator, value: ?[]const u8) !?[]u8 {
    const text = value orelse return null;
    return try allocator.dupe(u8, text);
}

fn dupeOptionalNonEmpty(allocator: std.mem.Allocator, value: []const u8) !?[]u8 {
    if (std.mem.trim(u8, value, &std.ascii.whitespace).len == 0) return null;
    return try allocator.dupe(u8, value);
}

fn handleSendFailure(context: ?*anyopaque, message: []const u8) void {
    const send_state: *chat_types.SendState = @ptrCast(@alignCast(context orelse return));
    const page_alloc = std.heap.page_allocator;

    send_state.mutex.lock();
    defer send_state.mutex.unlock();
    if (send_state.status != .pending) return;
    if (send_state.error_message) |old| page_alloc.free(old);
    const display_message = if (send_state.provider) |provider|
        providerFailureDisplayMessage(provider, message)
    else
        message;
    send_state.error_message = page_alloc.dupe(u8, display_message) catch null;
}

fn handleSendShouldStop(context: ?*anyopaque) bool {
    const send_state: *chat_types.SendState = @ptrCast(@alignCast(context orelse return true));
    send_state.mutex.lock();
    defer send_state.mutex.unlock();
    return send_state.stop_requested;
}

pub fn flushPendingAssistantTextLocked(send_state: *chat_types.SendState, allocator: std.mem.Allocator) void {
    if (send_state.partial_text.items.len == 0) return;
    const provider = send_state.provider orelse return;
    const trimmed = std.mem.trim(u8, send_state.partial_text.items, &std.ascii.whitespace);
    if (trimmed.len == 0) {
        send_state.partial_text.clearRetainingCapacity();
        send_state.ui_revision +%= 1;
        return;
    }

    const owned_author = allocator.dupe(u8, providerLabel(provider)) catch return;
    errdefer allocator.free(owned_author);
    const owned_body = allocator.dupe(u8, send_state.partial_text.items) catch return;
    errdefer allocator.free(owned_body);

    send_state.pending_events.append(allocator, .{
        .role = .assistant,
        .author = owned_author,
        .body = owned_body,
    }) catch {
        allocator.free(owned_author);
        allocator.free(owned_body);
        return;
    };

    send_state.partial_text.clearRetainingCapacity();
    send_state.ui_revision +%= 1;
}
pub fn mergePendingDiffFilesLocked(
    allocator: std.mem.Allocator,
    target: *std.ArrayListUnmanaged(chat_types.PendingDiffFile),
    files: []const ai_harness.StreamDiffFile,
) void {
    for (files) |file| {
        if (upsertPendingDiffFileLocked(allocator, target, file)) |_| {} else |_| return;
    }
}

/// Applies provider diff updates without allowing an individual edit to
/// overwrite a later authoritative snapshot of the whole turn.
pub fn applyPendingDiffUpdateLocked(
    allocator: std.mem.Allocator,
    send_state: *chat_types.SendState,
    diff: ai_harness.StreamDiffUpdate,
) void {
    switch (diff.scope) {
        .incremental => {
            if (send_state.pending_diff_has_turn_snapshot) return;
            mergePendingDiffFilesLocked(allocator, &send_state.pending_diff_files, diff.files);
        },
        .turn_snapshot => {
            replacePendingDiffFilesLocked(allocator, &send_state.pending_diff_files, diff.files) catch return;
            send_state.pending_diff_has_turn_snapshot = true;
        },
    }
    upsertPendingDiffSummaryEventLocked(
        allocator,
        &send_state.pending_events,
        send_state.pending_diff_files.items,
    );
}

fn replacePendingDiffFilesLocked(
    allocator: std.mem.Allocator,
    target: *std.ArrayListUnmanaged(chat_types.PendingDiffFile),
    files: []const ai_harness.StreamDiffFile,
) !void {
    var replacement: std.ArrayListUnmanaged(chat_types.PendingDiffFile) = .empty;
    errdefer freePendingDiffFiles(allocator, &replacement);
    for (files) |file| try upsertPendingDiffFileLocked(allocator, &replacement, file);
    freePendingDiffFiles(allocator, target);
    target.* = replacement;
}
fn upsertPendingDiffFileLocked(
    allocator: std.mem.Allocator,
    target: *std.ArrayListUnmanaged(chat_types.PendingDiffFile),
    file: ai_harness.StreamDiffFile,
) !void {
    for (target.items) |*existing| {
        if (!std.mem.eql(u8, existing.path, file.path)) continue;

        existing.additions = file.additions;
        existing.deletions = file.deletions;
        if (existing.patch) |existing_patch| allocator.free(existing_patch);
        existing.patch = if (file.patch) |patch| try allocator.dupe(u8, patch) else null;
        return;
    }

    try target.append(allocator, .{
        .path = try allocator.dupe(u8, file.path),
        .additions = file.additions,
        .deletions = file.deletions,
        .patch = if (file.patch) |patch| try allocator.dupe(u8, patch) else null,
        .expanded = false,
    });
}
pub fn providerLabel(provider: provider_models.Provider) [:0]const u8 {
    return chat_threads.providerLabel(provider);
}
fn handleSendApprovalRequest(context: ?*anyopaque, request: ai_harness.ApprovalRequest) ai_harness.ApprovalDecision {
    const send_state: *chat_types.SendState = @ptrCast(@alignCast(context orelse return .deny));
    const page_alloc = std.heap.page_allocator;

    const owned_call_id = page_alloc.dupe(u8, request.call_id) catch return .deny;
    errdefer page_alloc.free(owned_call_id);
    const owned_title = page_alloc.dupe(u8, request.title) catch return .deny;
    errdefer page_alloc.free(owned_title);
    const owned_body = page_alloc.dupe(u8, request.body) catch return .deny;
    errdefer page_alloc.free(owned_body);

    send_state.mutex.lock();
    defer send_state.mutex.unlock();
    if (send_state.status != .pending) {
        page_alloc.free(owned_call_id);
        page_alloc.free(owned_title);
        page_alloc.free(owned_body);
        return .deny;
    }

    flushPendingAssistantTextLocked(send_state, page_alloc);
    freePendingApprovalLocked(page_alloc, &send_state.pending_approval);
    send_state.pending_approval = .{
        .call_id = owned_call_id,
        .title = owned_title,
        .body = owned_body,
    };
    send_state.approval_decision = null;
    send_state.ui_revision +%= 1;
    // Surface the approval prompt immediately; this thread is about to block
    // on the user's decision, so a stale 250ms tick would delay the modal.
    loop_wakeup.notify();

    while (send_state.status == .pending and send_state.approval_decision == null) {
        send_state.condition.wait(&send_state.mutex);
    }

    const decision = send_state.approval_decision orelse .deny;
    send_state.approval_decision = null;
    freePendingApprovalLocked(page_alloc, &send_state.pending_approval);
    send_state.ui_revision +%= 1;
    loop_wakeup.notify();
    return decision;
}
pub fn freePendingApproval(allocator: std.mem.Allocator, approval: *?chat_types.PendingApproval) void {
    if (approval.*) |pending| {
        allocator.free(pending.call_id);
        allocator.free(pending.title);
        allocator.free(pending.body);
        approval.* = null;
    }
}
pub fn freePendingApprovalLocked(allocator: std.mem.Allocator, approval: *?chat_types.PendingApproval) void {
    freePendingApproval(allocator, approval);
}

fn freePendingTimelineEvent(allocator: std.mem.Allocator, event: chat_types.PendingTimelineEvent) void {
    var owned = event;
    owned.deinit(allocator);
}

/// Releases owned streamed timeline events copied out of the send worker.
pub fn freePendingTimelineEvents(
    allocator: std.mem.Allocator,
    events: *std.ArrayListUnmanaged(chat_types.PendingTimelineEvent),
) void {
    for (events.items) |event| freePendingTimelineEvent(allocator, event);
    events.deinit(allocator);
    events.* = .empty;
}

pub fn freePendingTimelineEventsLocked(
    allocator: std.mem.Allocator,
    events: *std.ArrayListUnmanaged(chat_types.PendingTimelineEvent),
) void {
    freePendingTimelineEvents(allocator, events);
}

/// Releases owned streamed diff entries copied out of the send worker.
pub fn freePendingDiffFiles(
    allocator: std.mem.Allocator,
    files: *std.ArrayListUnmanaged(chat_types.PendingDiffFile),
) void {
    for (files.items) |file| {
        allocator.free(file.path);
        if (file.patch) |patch| allocator.free(patch);
    }
    files.deinit(allocator);
    files.* = .empty;
}

pub fn freePendingDiffFilesLocked(
    allocator: std.mem.Allocator,
    files: *std.ArrayListUnmanaged(chat_types.PendingDiffFile),
) void {
    freePendingDiffFiles(allocator, files);
}

/// Persists the streamed diff summary as a synthetic system event on completion.
pub fn appendPendingDiffSummaryEvent(
    allocator: std.mem.Allocator,
    events: *std.ArrayListUnmanaged(chat_types.PendingTimelineEvent),
    files: []const chat_types.PendingDiffFile,
) void {
    if (files.len == 0) return;

    const owned_title = allocator.dupe(u8, "Changed files") catch return;
    errdefer allocator.free(owned_title);
    const owned_body = diffSummaryBodyAlloc(allocator, files) catch {
        allocator.free(owned_title);
        return;
    };

    events.append(allocator, .{
        .role = .system,
        .author = owned_title,
        .body = owned_body,
    }) catch {
        allocator.free(owned_title);
        allocator.free(owned_body);
    };
}

pub fn upsertPendingDiffSummaryEventLocked(
    allocator: std.mem.Allocator,
    events: *std.ArrayListUnmanaged(chat_types.PendingTimelineEvent),
    files: []const chat_types.PendingDiffFile,
) void {
    if (files.len == 0) return;
    const body = diffSummaryBodyAlloc(allocator, files) catch return;

    for (events.items) |*event| {
        if (event.role != .system or !std.mem.eql(u8, event.author, "Changed files")) continue;
        if (!isPersistedDiffBody(event.body)) continue;
        allocator.free(event.body);
        event.body = body;
        return;
    }

    const author = allocator.dupe(u8, "Changed files") catch {
        allocator.free(body);
        return;
    };
    events.append(allocator, .{
        .role = .system,
        .author = author,
        .body = body,
    }) catch {
        allocator.free(author);
        allocator.free(body);
    };
}

fn diffSummaryBodyAlloc(
    allocator: std.mem.Allocator,
    files: []const chat_types.PendingDiffFile,
) ![]u8 {
    var body: std.ArrayListUnmanaged(u8) = .empty;
    errdefer body.deinit(allocator);
    try body.appendSlice(allocator, PERSISTED_DIFF_MARKER);

    for (files) |file| {
        const patch = file.patch orelse "";
        const header = try std.fmt.allocPrint(allocator, "FILE\t{d}\t{d}\t{d}\t{d}\n", .{
            file.path.len,
            file.additions,
            file.deletions,
            patch.len,
        });
        defer allocator.free(header);
        try body.appendSlice(allocator, header);
        try body.appendSlice(allocator, file.path);
        try body.appendSlice(allocator, patch);
    }
    return body.toOwnedSlice(allocator);
}

pub fn isPersistedDiffBody(body: []const u8) bool {
    return std.mem.startsWith(u8, body, PERSISTED_DIFF_MARKER) or
        std.mem.startsWith(u8, body, PERSISTED_DIFF_MARKER_V1);
}

/// Downgrades tool calls still marked running once their turn is over.
/// A finished/stopped/failed turn can never deliver the terminal lifecycle
/// event anymore, so leftover `.pending`/`.in_progress` rows would otherwise
/// pulse forever in the persisted transcript. Content-less think rows are
/// transient liveness feedback and are removed outright instead.
pub fn cancelLingeringToolCallEvents(
    allocator: std.mem.Allocator,
    events: *std.ArrayListUnmanaged(chat_types.PendingTimelineEvent),
) void {
    var index: usize = events.items.len;
    while (index > 0) {
        index -= 1;
        const event = &events.items[index];
        const status = event.tool_call_status orelse continue;
        switch (status) {
            .pending, .in_progress => {},
            else => continue,
        }
        if ((event.tool_call_kind orelse .other) == .think and
            !hasToolCallContent(event.tool_call_input, event.tool_call_output, event.tool_call_error))
        {
            freePendingTimelineEvent(allocator, event.*);
            _ = events.orderedRemove(index);
            continue;
        }
        event.tool_call_status = .cancelled;
    }
}

pub fn pendingTimelineEventsContainAssistant(events: []const chat_types.PendingTimelineEvent) bool {
    for (events) |event| {
        if (event.role == .assistant) return true;
    }
    return false;
}

test "structured tool-call updates upsert and merge lifecycle content" {
    var events: std.ArrayListUnmanaged(chat_types.PendingTimelineEvent) = .empty;
    defer freePendingTimelineEvents(std.testing.allocator, &events);

    try upsertPendingToolCallEvent(std.testing.allocator, &events, .{
        .call_id = "call-1",
        .title = "Edit `/tmp/a.txt`",
        .kind = .edit,
        .status = .in_progress,
        .input = "{\"path\":\"/tmp/a.txt\"}",
        .raw = "{\"status\":\"in_progress\"}",
    });
    events.items[0].transcript_card_started_ms = 123;
    try upsertPendingToolCallEvent(std.testing.allocator, &events, .{
        .call_id = "call-1",
        .title = "",
        .kind = .edit,
        .status = .completed,
        .output = "Updated 3 lines",
        .raw = "{\"status\":\"completed\"}",
    });

    try std.testing.expectEqual(@as(usize, 1), events.items.len);
    const event = events.items[0];
    try std.testing.expectEqualStrings("call-1", event.tool_call_id.?);
    try std.testing.expectEqual(ai_harness.ToolCallStatus.completed, event.tool_call_status.?);
    try std.testing.expectEqual(@as(i64, 123), event.transcript_card_started_ms);
    try std.testing.expectEqualStrings("Edit", event.author);
    try std.testing.expect(std.mem.indexOf(u8, event.body, "Edit `/tmp/a.txt`") != null);
    try std.testing.expect(std.mem.indexOf(u8, event.body, "{\"path\":\"/tmp/a.txt\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, event.body, "Updated 3 lines") != null);
}

test "tagged MCP completion keeps the method inside a structured MCP card" {
    var events: std.ArrayListUnmanaged(chat_types.PendingTimelineEvent) = .empty;
    defer freePendingTimelineEvents(std.testing.allocator, &events);

    try upsertPendingToolCallEvent(std.testing.allocator, &events, .{
        .call_id = "call-mcp",
        .title = "MCP: tool",
        .kind = .mcp,
        .status = .in_progress,
    });
    try upsertPendingToolCallEvent(std.testing.allocator, &events, .{
        .call_id = "call-mcp",
        .title = "MCP: navigate_browser",
        .kind = .mcp,
        .status = .completed,
        .output = "{\"success\":true}",
    });

    try std.testing.expectEqual(@as(usize, 1), events.items.len);
    try std.testing.expectEqualStrings("MCP tool", events.items[0].author);
    try std.testing.expectEqualStrings(
        "Tool:\nMCP: navigate_browser\n\nOutput:\n{\n  \"success\": true\n}",
        events.items[0].body,
    );
}

test "provider MCP method titles cannot bypass the structured card renderer" {
    var events: std.ArrayListUnmanaged(chat_types.PendingTimelineEvent) = .empty;
    defer freePendingTimelineEvents(std.testing.allocator, &events);

    try upsertPendingToolCallEvent(std.testing.allocator, &events, .{
        .call_id = "toolu-1",
        .title = "verde.list_panes",
        .kind = .mcp,
        .status = .completed,
        .input = "{}",
        .output = "{\"ok\":true}",
    });

    try std.testing.expectEqual(@as(usize, 1), events.items.len);
    try std.testing.expectEqualStrings("MCP tool", events.items[0].author);
    try std.testing.expectEqualStrings(
        "Tool:\nverde.list_panes\n\nInput:\n{}\n\nOutput:\n{\n  \"ok\": true\n}",
        events.items[0].body,
    );
}

test "MCP card JSON formatting preserves arrays and invalid text" {
    const pretty = (try prettyJsonContainerAlloc(
        std.testing.allocator,
        "[{\"name\":\"verde\",\"active\":true}]",
    )).?;
    defer std.testing.allocator.free(pretty);
    try std.testing.expectEqualStrings(
        "[\n  {\n    \"name\": \"verde\",\n    \"active\": true\n  }\n]",
        pretty,
    );
    try std.testing.expect((try prettyJsonContainerAlloc(
        std.testing.allocator,
        "{not json}",
    )) == null);
}

test "lingering running tool calls are cancelled at turn end" {
    var events: std.ArrayListUnmanaged(chat_types.PendingTimelineEvent) = .empty;
    defer freePendingTimelineEvents(std.testing.allocator, &events);

    try upsertPendingToolCallEvent(std.testing.allocator, &events, .{
        .call_id = "call-running",
        .title = "Ran command",
        .kind = .execute,
        .status = .in_progress,
    });
    try upsertPendingToolCallEvent(std.testing.allocator, &events, .{
        .call_id = "call-done",
        .title = "Ran command",
        .kind = .execute,
        .status = .completed,
    });
    try upsertPendingToolCallEvent(std.testing.allocator, &events, .{
        .call_id = "call-think",
        .title = "",
        .kind = .think,
        .status = .in_progress,
    });

    cancelLingeringToolCallEvents(std.testing.allocator, &events);

    try std.testing.expectEqual(@as(usize, 2), events.items.len);
    try std.testing.expectEqual(ai_harness.ToolCallStatus.cancelled, events.items[0].tool_call_status.?);
    try std.testing.expectEqual(ai_harness.ToolCallStatus.completed, events.items[1].tool_call_status.?);
}

test "transient think detection drives the pending thinking indicator" {
    try std.testing.expectEqual(
        @as(?bool, true),
        transientThinkStatus(.{ .call_id = "t", .title = "", .kind = .think, .status = .in_progress }),
    );
    try std.testing.expectEqual(
        @as(?bool, false),
        transientThinkStatus(.{ .call_id = "t", .title = "", .kind = .think, .status = .completed }),
    );
    // Think updates carrying real thought content stay timeline rows.
    try std.testing.expectEqual(
        @as(?bool, null),
        transientThinkStatus(.{ .call_id = "t", .title = "", .kind = .think, .status = .completed, .output = "weighed options" }),
    );
    try std.testing.expectEqual(
        @as(?bool, null),
        transientThinkStatus(.{ .call_id = "t", .title = "", .kind = .execute, .status = .in_progress }),
    );
}

test "content-less think rows are transient across their lifecycle" {
    var events: std.ArrayListUnmanaged(chat_types.PendingTimelineEvent) = .empty;
    defer freePendingTimelineEvents(std.testing.allocator, &events);

    try upsertPendingToolCallEvent(std.testing.allocator, &events, .{
        .call_id = "think-1",
        .title = "",
        .kind = .think,
        .status = .in_progress,
    });
    try std.testing.expectEqual(@as(usize, 1), events.items.len);
    try std.testing.expectEqualStrings("Thinking", events.items[0].author);

    try upsertPendingToolCallEvent(std.testing.allocator, &events, .{
        .call_id = "think-1",
        .title = "",
        .kind = .think,
        .status = .completed,
    });
    try std.testing.expectEqual(@as(usize, 0), events.items.len);

    // A terminal think replayed without a prior row must not materialize one.
    try upsertPendingToolCallEvent(std.testing.allocator, &events, .{
        .call_id = "think-2",
        .title = "",
        .kind = .think,
        .status = .completed,
    });
    try std.testing.expectEqual(@as(usize, 0), events.items.len);

    // Think rows carrying real thought content (e.g. Cursor) persist.
    try upsertPendingToolCallEvent(std.testing.allocator, &events, .{
        .call_id = "think-3",
        .title = "",
        .kind = .think,
        .status = .completed,
        .output = "Considered zoom handling trade-offs",
    });
    try std.testing.expectEqual(@as(usize, 1), events.items.len);
    try std.testing.expectEqualStrings("Think", events.items[0].author);
}

pub const ClipboardImageCapture = struct {
    bytes: []u8,
    mime: []const u8,
};

/// Reads an image payload from the system clipboard when the platform supports it.
pub fn captureClipboardImage(allocator: std.mem.Allocator) !?ClipboardImageCapture {
    return switch (@import("builtin").os.tag) {
        .macos => captureClipboardImageMacOS(allocator),
        .linux, .freebsd, .netbsd, .openbsd, .dragonfly => {
            if (try captureClipboardImageWayland(allocator)) |image| return image;
            return try captureClipboardImageX11(allocator);
        },
        .windows => if (try windows_integrations.clipboardImageAlloc(allocator, CLIPBOARD_IMAGE_MAX_BYTES)) |image| .{
            .bytes = image.bytes,
            .mime = image.mime,
        } else null,
        else => null,
    };
}

/// Reads text from the system clipboard. SDL is attempted by the caller first;
/// this covers compositors/toolkits where SDL has no current text owner.
pub fn captureClipboardText(allocator: std.mem.Allocator) !?[]u8 {
    return switch (@import("builtin").os.tag) {
        .macos => captureClipboardTextCommand(allocator, &.{"pbpaste"}),
        .linux, .freebsd, .netbsd, .openbsd, .dragonfly => {
            if (try captureClipboardTextCommand(allocator, &.{ "sh", "-c", "export XDG_RUNTIME_DIR=\"${XDG_RUNTIME_DIR:-/run/user/$(id -u)}\"; export WAYLAND_DISPLAY=\"${WAYLAND_DISPLAY:-wayland-1}\"; wl-paste --no-newline" })) |text| return text;
            return try captureClipboardTextCommand(allocator, &.{ "xclip", "-selection", "clipboard", "-o" });
        },
        .windows => windows_integrations.clipboardTextAlloc(allocator, 1024 * 1024),
        else => null,
    };
}

fn captureClipboardTextCommand(allocator: std.mem.Allocator, argv: []const []const u8) !?[]u8 {
    const result = runChild(allocator, argv, ".", 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) {
            allocator.free(result.stdout);
            return null;
        },
        else => {
            allocator.free(result.stdout);
            return null;
        },
    }
    if (result.stdout.len == 0) {
        allocator.free(result.stdout);
        return null;
    }
    return result.stdout;
}

const MacClipboardImageFlavor = struct {
    class_code: []const u8,
    mime: []const u8,
};

fn captureClipboardImageMacOS(allocator: std.mem.Allocator) !?ClipboardImageCapture {
    if (try captureClipboardImageMacOSNative(allocator)) |capture| {
        if (std.mem.eql(u8, capture.mime, "image/tiff")) {
            return try convertClipboardTiffToPng(allocator, capture);
        }
        return capture;
    }

    const candidates = [_]MacClipboardImageFlavor{
        .{ .class_code = "PNGf", .mime = "image/png" },
        .{ .class_code = "JPEG", .mime = "image/jpeg" },
        .{ .class_code = "TIFF", .mime = "image/tiff" },
    };

    for (candidates) |candidate| {
        const capture = try readMacClipboardImageFlavor(allocator, candidate.class_code, candidate.mime) orelse continue;
        if (std.mem.eql(u8, capture.mime, "image/tiff")) {
            return try convertClipboardTiffToPng(allocator, capture);
        }
        return capture;
    }

    return null;
}

fn captureClipboardImageMacOSNative(allocator: std.mem.Allocator) !?ClipboardImageCapture {
    var native_bytes: ?[*]u8 = null;
    var native_len: usize = 0;
    var native_mime: ?[*:0]const u8 = null;

    const result = verde_macos_clipboard_copy_image(&native_bytes, &native_len, &native_mime);
    if (result < 0) return error.OutOfMemory;
    if (result == 0 or native_bytes == null or native_len == 0 or native_mime == null) return null;
    defer free(native_bytes);

    if (native_len > CLIPBOARD_IMAGE_MAX_BYTES) return error.StreamTooLong;

    const bytes = try allocator.dupe(u8, native_bytes.?[0..native_len]);
    errdefer allocator.free(bytes);
    const mime = std.mem.span(native_mime.?);

    return .{
        .bytes = bytes,
        .mime = mime,
    };
}

fn selectMacClipboardImageFlavor(info_output: []const u8) ?MacClipboardImageFlavor {
    const candidates = [_]MacClipboardImageFlavor{
        .{ .class_code = "PNGf", .mime = "image/png" },
        .{ .class_code = "JPEG", .mime = "image/jpeg" },
        .{ .class_code = "TIFF", .mime = "image/tiff" },
    };

    for (candidates) |candidate| {
        if (std.mem.indexOf(u8, info_output, candidate.class_code) != null) {
            return candidate;
        }
    }
    if (std.mem.indexOf(u8, info_output, "TIFF picture") != null) {
        return .{ .class_code = "TIFF", .mime = "image/tiff" };
    }
    if (std.mem.indexOf(u8, info_output, "JPEG picture") != null) {
        return .{ .class_code = "JPEG", .mime = "image/jpeg" };
    }
    return null;
}

fn readMacClipboardImageFlavor(
    allocator: std.mem.Allocator,
    class_code: []const u8,
    mime: []const u8,
) !?ClipboardImageCapture {
    const command = try std.fmt.allocPrint(allocator, "get the clipboard as «class {s}»", .{class_code});
    defer allocator.free(command);

    const result = runChild(allocator, &.{ "osascript", "-e", command }, ".", CLIPBOARD_IMAGE_MAX_BYTES * 4) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) {
            allocator.free(result.stdout);
            return null;
        },
        else => {
            allocator.free(result.stdout);
            return null;
        },
    }

    const decoded = decodeAppleScriptClipboardData(allocator, result.stdout, class_code) catch {
        allocator.free(result.stdout);
        return null;
    };
    allocator.free(result.stdout);

    if (decoded.len == 0) {
        allocator.free(decoded);
        return null;
    }

    return .{
        .bytes = decoded,
        .mime = mime,
    };
}

fn decodeAppleScriptClipboardData(
    allocator: std.mem.Allocator,
    encoded: []const u8,
    class_code: []const u8,
) ![]u8 {
    const prefix = try std.fmt.allocPrint(allocator, "«data {s}", .{class_code});
    defer allocator.free(prefix);

    const start_index = std.mem.indexOf(u8, encoded, prefix) orelse return error.InvalidClipboardPayload;
    const payload_start = start_index + prefix.len;
    const suffix_rel = std.mem.indexOfScalar(u8, encoded[payload_start..], '»') orelse return error.InvalidClipboardPayload;
    const payload_raw = encoded[payload_start .. payload_start + suffix_rel];

    var hex_only: std.ArrayList(u8) = .empty;
    defer hex_only.deinit(allocator);

    for (payload_raw) |char| {
        if (std.ascii.isWhitespace(char)) continue;
        try hex_only.append(allocator, char);
    }

    if (hex_only.items.len == 0 or (hex_only.items.len % 2) != 0) {
        return error.InvalidClipboardPayload;
    }

    const decoded = try allocator.alloc(u8, hex_only.items.len / 2);
    errdefer allocator.free(decoded);
    _ = try std.fmt.hexToBytes(decoded, hex_only.items);
    return decoded;
}

fn convertClipboardTiffToPng(
    allocator: std.mem.Allocator,
    capture: ClipboardImageCapture,
) !?ClipboardImageCapture {
    defer allocator.free(capture.bytes);

    const temp_dir = std.fs.path.join(allocator, &.{ "/tmp", "editorts-native-clipboard" }) catch return error.OutOfMemory;
    defer allocator.free(temp_dir);
    var threaded = std.Io.Threaded.init_single_threaded;
    std.Io.Dir.createDirAbsolute(threaded.io(), temp_dir, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const timestamp_ms = @as(u64, @intCast(@max(@as(i64, 0), 0)));
    const input_path = try std.fmt.allocPrint(allocator, "{s}/clipboard-{d}.tiff", .{ temp_dir, timestamp_ms });
    defer allocator.free(input_path);
    const output_path = try std.fmt.allocPrint(allocator, "{s}/clipboard-{d}.png", .{ temp_dir, timestamp_ms });
    defer allocator.free(output_path);

    {
        var file = try std.Io.Dir.createFileAbsolute(threaded.io(), input_path, .{ .truncate = true });
        defer file.close(threaded.io());
        var write_buffer: [8 * 1024]u8 = undefined;
        var writer = file.writer(threaded.io(), &write_buffer);
        try writer.interface.writeAll(capture.bytes);
        try writer.interface.flush();
    }

    const convert_result = runChild(allocator, &.{ "sips", "-s", "format", "png", input_path, "--out", output_path }, ".", 16 * 1024) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(convert_result.stdout);
    defer allocator.free(convert_result.stderr);

    switch (convert_result.term) {
        .exited => |code| if (code != 0) return null,
        else => return null,
    }

    const png_bytes = png_bytes: {
        var png_file = try std.Io.Dir.openFileAbsolute(threaded.io(), output_path, .{ .mode = .read_only });
        defer png_file.close(threaded.io());
        const png_size = try png_file.stat(threaded.io());
        if (png_size.size > CLIPBOARD_IMAGE_MAX_BYTES) return error.StreamTooLong;
        var read_buffer: [8 * 1024]u8 = undefined;
        var reader = png_file.reader(threaded.io(), &read_buffer);
        break :png_bytes try reader.interface.readAlloc(allocator, @intCast(png_size.size));
    };
    std.Io.Dir.deleteFileAbsolute(threaded.io(), input_path) catch {};
    std.Io.Dir.deleteFileAbsolute(threaded.io(), output_path) catch {};

    return .{
        .bytes = png_bytes,
        .mime = "image/png",
    };
}

fn captureClipboardImageWayland(allocator: std.mem.Allocator) !?ClipboardImageCapture {
    var threaded = std.Io.Threaded.init_single_threaded;
    const types_path = try std.fmt.allocPrint(allocator, "/tmp/verde-clipboard-types-{d}.txt", .{platform_runtime.processId()});
    defer allocator.free(types_path);
    defer std.Io.Dir.deleteFileAbsolute(threaded.io(), types_path) catch {};

    const types_result = runChild(
        allocator,
        &.{ "sh", "-c", "export XDG_RUNTIME_DIR=\"${XDG_RUNTIME_DIR:-/run/user/$(id -u)}\"; export WAYLAND_DISPLAY=\"${WAYLAND_DISPLAY:-wayland-1}\"; wl-paste --list-types > \"$1\"", "sh", types_path },
        ".",
        16 * 1024,
    ) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(types_result.stdout);
    defer allocator.free(types_result.stderr);

    switch (types_result.term) {
        .exited => |code| if (code != 0) {
            runtime_log.diagnostic("clipboard image wayland list-types exited code={d} stderr_len={d}", .{ code, types_result.stderr.len });
            return null;
        },
        else => return null,
    }

    const types_output = types_output: {
        var types_file = try std.Io.Dir.openFileAbsolute(threaded.io(), types_path, .{ .mode = .read_only });
        defer types_file.close(threaded.io());
        const types_size = try types_file.stat(threaded.io());
        if (types_size.size == 0) return null;
        if (types_size.size > 16 * 1024) return error.StreamTooLong;
        var read_buffer: [1024]u8 = undefined;
        var reader = types_file.reader(threaded.io(), &read_buffer);
        break :types_output try reader.interface.readAlloc(allocator, @intCast(types_size.size));
    };
    defer allocator.free(types_output);

    const mime = selectClipboardImageMime(types_output) orelse return null;
    runtime_log.diagnostic("clipboard image wayland mime={s}", .{mime});
    const output_path = try std.fmt.allocPrint(allocator, "/tmp/verde-clipboard-image-{d}.bin", .{platform_runtime.processId()});
    defer allocator.free(output_path);
    defer std.Io.Dir.deleteFileAbsolute(threaded.io(), output_path) catch {};

    const image_result = runChild(
        allocator,
        &.{ "sh", "-c", "export XDG_RUNTIME_DIR=\"${XDG_RUNTIME_DIR:-/run/user/$(id -u)}\"; export WAYLAND_DISPLAY=\"${WAYLAND_DISPLAY:-wayland-1}\"; wl-paste --no-newline --type \"$1\" > \"$2\"", "sh", mime, output_path },
        ".",
        16 * 1024,
    ) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(image_result.stdout);
    defer allocator.free(image_result.stderr);

    switch (image_result.term) {
        .exited => |code| if (code != 0) {
            runtime_log.diagnostic("clipboard image wayland paste exited code={d} stderr_len={d}", .{ code, image_result.stderr.len });
            return null;
        },
        else => {
            runtime_log.diagnostic("clipboard image wayland paste did not exit normally", .{});
            return null;
        },
    }
    runtime_log.diagnostic("clipboard image wayland temp written stdout_len={d} stderr_len={d}", .{ image_result.stdout.len, image_result.stderr.len });

    const bytes = bytes: {
        var image_file = try std.Io.Dir.openFileAbsolute(threaded.io(), output_path, .{ .mode = .read_only });
        defer image_file.close(threaded.io());
        const image_size = try image_file.stat(threaded.io());
        runtime_log.diagnostic("clipboard image wayland temp size={d}", .{image_size.size});
        if (image_size.size == 0) return null;
        if (image_size.size > CLIPBOARD_IMAGE_MAX_BYTES) return error.StreamTooLong;
        var read_buffer: [8 * 1024]u8 = undefined;
        var reader = image_file.reader(threaded.io(), &read_buffer);
        break :bytes reader.interface.readAlloc(allocator, @intCast(image_size.size)) catch |err| {
            runtime_log.diagnostic("clipboard image wayland temp read failed: {s}", .{@errorName(err)});
            return err;
        };
    };

    return .{
        .bytes = bytes,
        .mime = mime,
    };
}

pub fn captureClipboardImageX11(allocator: std.mem.Allocator) !?ClipboardImageCapture {
    const targets_result = runChild(allocator, &.{ "xclip", "-selection", "clipboard", "-t", "TARGETS", "-o" }, ".", 16 * 1024) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(targets_result.stdout);
    defer allocator.free(targets_result.stderr);

    switch (targets_result.term) {
        .exited => |code| if (code != 0) return null,
        else => return null,
    }

    const mime = selectClipboardImageMime(targets_result.stdout) orelse return null;
    const child_allocator = std.heap.page_allocator;
    const image_result = runChild(child_allocator, &.{ "xclip", "-selection", "clipboard", "-t", mime, "-o" }, ".", CLIPBOARD_IMAGE_MAX_BYTES) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer child_allocator.free(image_result.stderr);

    switch (image_result.term) {
        .exited => |code| if (code != 0) {
            child_allocator.free(image_result.stdout);
            return null;
        },
        else => {
            child_allocator.free(image_result.stdout);
            return null;
        },
    }

    if (image_result.stdout.len == 0) {
        child_allocator.free(image_result.stdout);
        return null;
    }
    defer child_allocator.free(image_result.stdout);
    const bytes = try allocator.dupe(u8, image_result.stdout);

    return .{
        .bytes = bytes,
        .mime = mime,
    };
}

pub fn selectClipboardImageMime(types_output: []const u8) ?[]const u8 {
    const candidates = [_][]const u8{
        "image/png",
        "image/jpeg",
        "image/webp",
        "image/gif",
        "image/bmp",
    };

    for (candidates) |candidate| {
        if (std.mem.indexOf(u8, types_output, candidate) != null) {
            return candidate;
        }
    }
    return null;
}

pub fn extensionForImageMime(mime: []const u8) []const u8 {
    if (std.mem.eql(u8, mime, "image/png")) return "png";
    if (std.mem.eql(u8, mime, "image/jpeg")) return "jpg";
    if (std.mem.eql(u8, mime, "image/webp")) return "webp";
    if (std.mem.eql(u8, mime, "image/gif")) return "gif";
    if (std.mem.eql(u8, mime, "image/bmp")) return "bmp";
    return "img";
}

test "handleSendThreadId stores provisional provider thread id while pending" {
    var send_state = chat_types.SendState{ .status = .pending };
    defer if (send_state.provisional_provider_thread_id) |thread_id| std.heap.page_allocator.free(thread_id);

    handleSendThreadId(&send_state, "ses_123");
    try std.testing.expect(send_state.provisional_provider_thread_id != null);
    try std.testing.expectEqualStrings("ses_123", send_state.provisional_provider_thread_id.?);

    handleSendThreadId(&send_state, "ses_123");
    try std.testing.expectEqualStrings("ses_123", send_state.provisional_provider_thread_id.?);

    send_state.status = .idle;
    handleSendThreadId(&send_state, "ses_456");
    try std.testing.expectEqualStrings("ses_123", send_state.provisional_provider_thread_id.?);
}

test "configured editor parsing preserves Windows paths and quoted arguments" {
    const allocator = std.testing.allocator;
    var parsed = try parseConfiguredCommand(allocator, "\"C:\\Program Files\\Editor\\editor.exe\" --reuse-window 'two words'");
    defer parsed.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 3), parsed.argv.items.len);
    try std.testing.expectEqualStrings("C:\\Program Files\\Editor\\editor.exe", parsed.argv.items[0]);
    try std.testing.expectEqualStrings("--reuse-window", parsed.argv.items[1]);
    try std.testing.expectEqualStrings("two words", parsed.argv.items[2]);
}

test "file references separate line and column suffixes from paths" {
    const absolute = parseFileReference("/workspace/src/main.zig:42");
    try std.testing.expectEqualStrings("/workspace/src/main.zig", absolute.path);
    try std.testing.expectEqual(@as(?usize, 42), absolute.location.line);
    try std.testing.expectEqual(@as(?usize, null), absolute.location.column);

    const relative = parseFileReference("src/main.zig:42:7");
    try std.testing.expectEqualStrings("src/main.zig", relative.path);
    try std.testing.expectEqual(@as(?usize, 42), relative.location.line);
    try std.testing.expectEqual(@as(?usize, 7), relative.location.column);

    const windows = parseFileReference("C:\\workspace\\main.zig:9");
    try std.testing.expectEqualStrings("C:\\workspace\\main.zig", windows.path);
    try std.testing.expectEqual(@as(?usize, 9), windows.location.line);

    const drive_relative = parseFileReference("C:12");
    try std.testing.expectEqualStrings("C:12", drive_relative.path);
    try std.testing.expectEqual(@as(?usize, null), drive_relative.location.line);

    const literal = parseFileReference("notes/release:v2");
    try std.testing.expectEqualStrings("notes/release:v2", literal.path);
    try std.testing.expectEqual(@as(?usize, null), literal.location.line);
}

test "Neovim location arguments preserve line and column" {
    const allocator = std.testing.allocator;
    const line_arg = (try vimLocationArgumentAlloc(allocator, "nvim", .{ .line = 986 })).?;
    defer allocator.free(line_arg);
    try std.testing.expectEqualStrings("+986", line_arg);

    const column_arg = (try vimLocationArgumentAlloc(allocator, "nvim", .{ .line = 531, .column = 8 })).?;
    defer allocator.free(column_arg);
    try std.testing.expectEqualStrings("+call cursor(531,8)", column_arg);
    try std.testing.expect((try vimLocationArgumentAlloc(allocator, "nano", .{ .line = 12 })) == null);
}

test "upsertPendingDiffFileLocked clears stale patch when later snapshot omits it" {
    const allocator = std.testing.allocator;
    var files: std.ArrayListUnmanaged(chat_types.PendingDiffFile) = .empty;
    defer freePendingDiffFiles(allocator, &files);

    try upsertPendingDiffFileLocked(allocator, &files, .{
        .path = "packages/desktop/src/ui/chat_panel.zig",
        .additions = 12,
        .deletions = 0,
        .patch = "@@ -1 +1 @@\n-old\n+new\n",
    });
    try upsertPendingDiffFileLocked(allocator, &files, .{
        .path = "packages/desktop/src/ui/chat_panel.zig",
        .additions = 12,
        .deletions = 0,
        .patch = null,
    });

    try std.testing.expectEqual(@as(usize, 1), files.items.len);
    try std.testing.expect(files.items[0].patch == null);
}

test "streamed diff becomes a live timeline event and updates in place" {
    const allocator = std.testing.allocator;
    var files: std.ArrayListUnmanaged(chat_types.PendingDiffFile) = .empty;
    defer freePendingDiffFiles(allocator, &files);
    var events: std.ArrayListUnmanaged(chat_types.PendingTimelineEvent) = .empty;
    defer freePendingTimelineEvents(allocator, &events);

    mergePendingDiffFilesLocked(allocator, &files, &.{.{
        .path = "src/with\ttab.zig",
        .additions = 1,
        .deletions = 1,
        .patch = "@@ -1 +1 @@\n-old\n+new",
    }});
    upsertPendingDiffSummaryEventLocked(allocator, &events, files.items);
    try std.testing.expectEqual(@as(usize, 1), events.items.len);
    try std.testing.expect(isPersistedDiffBody(events.items[0].body));

    mergePendingDiffFilesLocked(allocator, &files, &.{.{
        .path = "src/with\ttab.zig",
        .additions = 2,
        .deletions = 1,
        .patch = "@@ -1 +1,2 @@\n-old\n+new\n+again",
    }});
    upsertPendingDiffSummaryEventLocked(allocator, &events, files.items);
    try std.testing.expectEqual(@as(usize, 1), events.items.len);
    try std.testing.expect(std.mem.indexOf(u8, events.items[0].body, "+again") != null);
}

test "turn diff snapshot cannot be overwritten by a later individual edit" {
    const allocator = std.testing.allocator;
    var send_state: chat_types.SendState = .{ .status = .pending };
    defer freePendingDiffFiles(allocator, &send_state.pending_diff_files);
    defer freePendingTimelineEvents(allocator, &send_state.pending_events);

    applyPendingDiffUpdateLocked(allocator, &send_state, .{
        .files = &.{.{
            .path = "src/workspace_layout.zig",
            .additions = 30,
            .deletions = 2,
            .patch = "first edit",
        }},
    });
    applyPendingDiffUpdateLocked(allocator, &send_state, .{
        .scope = .turn_snapshot,
        .files = &.{.{
            .path = "src/workspace_layout.zig",
            .additions = 80,
            .deletions = 2,
            .patch = "cumulative turn patch",
        }},
    });
    applyPendingDiffUpdateLocked(allocator, &send_state, .{
        .files = &.{.{
            .path = "src/workspace_layout.zig",
            .additions = 50,
            .deletions = 0,
            .patch = "second edit only",
        }},
    });

    try std.testing.expect(send_state.pending_diff_has_turn_snapshot);
    try std.testing.expectEqual(@as(usize, 1), send_state.pending_diff_files.items.len);
    const file = send_state.pending_diff_files.items[0];
    try std.testing.expectEqual(@as(i64, 80), file.additions);
    try std.testing.expectEqual(@as(i64, 2), file.deletions);
    try std.testing.expectEqualStrings("cumulative turn patch", file.patch.?);
    try std.testing.expectEqual(@as(usize, 1), send_state.pending_events.items.len);
    try std.testing.expect(std.mem.indexOf(u8, send_state.pending_events.items[0].body, "cumulative turn patch") != null);
}

test "provider failure display identifies Claude and Codex usage limits" {
    try std.testing.expectEqualStrings(
        CLAUDE_PLAN_LIMIT_MESSAGE,
        providerFailureDisplayMessage(.claude, "You've hit your limit · resets 10pm"),
    );
    try std.testing.expectEqualStrings(
        CLAUDE_USAGE_LIMIT_MESSAGE,
        providerFailureDisplayMessage(.claude, "Claude five_hour usage limit reached"),
    );
    try std.testing.expectEqualStrings(
        CODEX_USAGE_LIMIT_MESSAGE,
        providerFailureDisplayMessage(.codex, "Usage limit reached. Try again later."),
    );
    try std.testing.expectEqualStrings(
        "Authentication failed",
        providerFailureDisplayMessage(.claude, "Authentication failed"),
    );
    try std.testing.expectEqual(provider_models.Provider.claude, usageLimitProviderForDisplayMessage(CLAUDE_USAGE_LIMIT_MESSAGE).?);
    try std.testing.expectEqual(provider_models.Provider.codex, usageLimitProviderForDisplayMessage(CODEX_USAGE_LIMIT_MESSAGE).?);
}

test "legacy provider failures retain an actionable usage path" {
    try std.testing.expectEqual(provider_models.Provider.claude, providerFailureActionProvider("ClaudeRequestFailed").?);
    try std.testing.expectEqual(provider_models.Provider.codex, providerFailureActionProvider("Provider request failed: CodexTurnFailed").?);
    try std.testing.expect(std.mem.indexOf(u8, providerFailureActionBody("ClaudeRequestFailed"), "did not save") != null);
    try std.testing.expect(providerFailureActionProvider("Authentication failed") == null);
}
