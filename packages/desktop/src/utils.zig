const app_state = @import("state.zig");
const ai_harness = @import("harness.zig");
const process_env = @import("process_env.zig");
const runtime_log = @import("runtime_log.zig");
const stb_image = @import("stb_image.zig");
const chat_threads = @import("chat/threads.zig");
const std = @import("std");
const builtin = @import("builtin");

const log = std.log.scoped(.native_utils);

const GL_TEXTURE_2D = 0x0DE1;
const GL_RGBA = 0x1908;
const GL_UNSIGNED_BYTE = 0x1401;
const GL_LINEAR = 0x2601;
const GL_TEXTURE_MIN_FILTER = 0x2801;
const GL_TEXTURE_MAG_FILTER = 0x2800;
const GL_TEXTURE_WRAP_S = 0x2802;
const GL_TEXTURE_WRAP_T = 0x2803;
const GL_CLAMP_TO_EDGE = 0x812F;
const GL_UNPACK_ALIGNMENT = 0x0CF5;
const GL_LINEAR_MIPMAP_LINEAR = 0x2703;

// Shared runtime constants live here so state and the UI shell can import them
// without creating a cycle back through `main.zig`.
pub const CLIPBOARD_IMAGE_MAX_BYTES: usize = 10 * 1024 * 1024;
pub const PERSISTED_DIFF_MARKER = "EDITORTS_DIFF_V1\n";

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

pub fn loadEmbeddedTexture(bytes: []const u8) ?app_state.CachedImageTexture {
    const loaded = stb_image.loadFromMemory(bytes) catch |err| {
        app_state.log.err("failed to decode embedded logo texture: {s}", .{@errorName(err)});
        return null;
    };
    defer loaded.deinit();
    return uploadTexture(loaded);
}

extern fn glGenTextures(n: c_int, textures: [*]c_uint) void;
extern fn glBindTexture(target: c_uint, texture: c_uint) void;
extern fn glPixelStorei(pname: c_uint, param: c_int) void;
extern fn glTexParameteri(target: c_uint, pname: c_uint, param: c_int) void;
extern fn glTexImage2D(target: c_uint, level: c_int, internalformat: c_int, width: c_int, height: c_int, border: c_int, format: c_uint, type_: c_uint, pixels: ?*const anyopaque) void;
extern fn glGenerateMipmap(target: c_uint) void;

pub fn uploadTexture(loaded: stb_image.LoadedImage) ?app_state.CachedImageTexture {
    var textures = [_]c_uint{0};
    glGenTextures(1, &textures);
    const texture_id = textures[0];
    if (texture_id == 0) return null;

    glBindTexture(GL_TEXTURE_2D, texture_id);
    glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR_MIPMAP_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glTexImage2D(
        GL_TEXTURE_2D,
        0,
        GL_RGBA,
        @intCast(loaded.width),
        @intCast(loaded.height),
        0,
        GL_RGBA,
        GL_UNSIGNED_BYTE,
        loaded.pixels,
    );
    glGenerateMipmap(GL_TEXTURE_2D);
    glBindTexture(GL_TEXTURE_2D, 0);

    return .{
        .texture_id = texture_id,
        .width = loaded.width,
        .height = loaded.height,
        .valid = true,
    };
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
        else => false,
    };
}

pub fn openProjectDirectory(allocator: std.mem.Allocator, project_path: []const u8) OpenProjectError!void {
    return switch (@import("builtin").os.tag) {
        .macos => spawnDetached(allocator, &.{ "open", project_path }, null),
        .linux, .freebsd, .netbsd, .openbsd, .dragonfly => {
            if (commandExists("xdg-open")) return spawnDetached(allocator, &.{ "xdg-open", project_path }, null);
            if (commandExists("gio")) return spawnDetached(allocator, &.{ "gio", "open", project_path }, null);
            return error.LauncherUnavailable;
        },
        else => error.UnsupportedOperatingSystem,
    };
}

pub fn canOpenProjectEditor(target: app_state.ProjectEditorTarget) bool {
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

pub fn executableNameForCommand(command: []const u8) []const u8 {
    return commandExecutableName(command);
}

pub fn openProjectEditor(
    allocator: std.mem.Allocator,
    project_path: []const u8,
    target: app_state.ProjectEditorTarget,
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
) OpenProjectError!OpenFileResult {
    const parent_dir = std.fs.path.dirname(file_path) orelse file_path;

    if (preferredEditorEnv()) |editor| {
        if (canOpenConfiguredEditor()) {
            try openConfiguredEditorPath(allocator, editor, parent_dir, file_path);
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
    return spawnDetached(allocator, &.{ "sh", "-lc", command, "verde-open-action", project_path }, project_path);
}

pub fn pickerWorker(state: *app_state.PickerState, start_path: []u8) void {
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
        \\return POSIX path of (choose folder with prompt "Select project folder" default location defaultLocation)
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
            \\zenity --file-selection --directory --filename "$1" --title "Select project folder"
        , start_path, null);
    }

    if (commandExists("kdialog")) {
        return runLinuxGuiDirectoryPickerCommand(allocator,
            \\kdialog --getexistingdirectory "$1" --title "Select project folder"
        , start_path, null);
    }

    if (commandExists("yad")) {
        return runLinuxGuiDirectoryPickerCommand(allocator,
            \\yad --file-selection --directory --filename "$1" --title "Select project folder"
        , start_path, null);
    }

    if (commandExists("qarma")) {
        return runLinuxGuiDirectoryPickerCommand(allocator,
            \\qarma --file-selection --directory --filename "$1" --title "Select project folder"
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
            \\    title="Select project folder",
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
            runtime_log.diagnostic("runDirectoryPickerCommand exited argv={s} code={d} stdout_len={d} stderr_len={d} stderr={s}", .{ argv[0], code, result.stdout.len, result.stderr.len, result.stderr });
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

pub fn sendWorker(state: *app_state.SendState, request: *SendWorkerRequest) void {
    const page_alloc = std.heap.page_allocator;
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
        page_alloc.destroy(request);
    }

    std.debug.print(
        "[codex-debug] sendWorker begin provider={s} cwd={s} model={s} thread_id={s} prompt_len={d}\n",
        .{
            @tagName(request.provider),
            request.project_path,
            request.model_ref orelse "(default)",
            request.provider_thread_id orelse "(new)",
            request.prompt.len,
        },
    );
    runtime_log.diagnostic(
        "sendWorker begin provider={s} cwd={s} model={s} thread_id={s} prompt_len={d}",
        .{
            @tagName(request.provider),
            request.project_path,
            request.model_ref orelse "(default)",
            request.provider_thread_id orelse "(new)",
            request.prompt.len,
        },
    );

    const result = runSendWorker(page_alloc, request);

    state.mutex.lock();
    defer state.mutex.unlock();

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
            "[codex-debug] sendWorker failed provider={s} cwd={s} model={s} thread_id={s} err={s}\n",
            .{
                @tagName(request.provider),
                request.project_path,
                request.model_ref orelse "(default)",
                request.provider_thread_id orelse "(new)",
                @errorName(err),
            },
        );
        runtime_log.diagnostic(
            "sendWorker failed provider={s} cwd={s} model={s} thread_id={s} err={s}",
            .{
                @tagName(request.provider),
                request.project_path,
                request.model_ref orelse "(default)",
                request.provider_thread_id orelse "(new)",
                @errorName(err),
            },
        );
        if (err == error.CodexTurnInterrupted and state.stop_requested) {
            state.error_message = null;
            state.result = null;
            state.status = .aborted;
            return;
        }
        const message = formatSendWorkerError(page_alloc, request.provider, err) catch null;
        state.error_message = message;
        state.result = null;
        state.status = .failed;
    }
}
pub const SendWorkerRequest = struct {
    send_state_ptr: *app_state.SendState,
    provider: app_state.Provider,
    harness: app_state.Harness,
    project_path: []u8,
    prompt: []u8,
    image_path: ?[]u8,
    image_paths: [][]u8,
    provider_thread_id: ?[]u8,
    thread_title: []u8,
    model_ref: ?[]u8,
    reasoning_effort: ?app_state.ReasoningEffort,
    /// Owned; OpenCode-only. Duplicated from thread `opencode_reasoning_variant`.
    opencode_reasoning_variant: ?[]u8,
    cursor_model_params_json: ?[]u8,
    fast_mode: app_state.FastMode,
    access_mode: app_state.AccessMode,
};
pub fn runSendWorker(
    allocator: std.mem.Allocator,
    request: *const SendWorkerRequest,
) !app_state.SendResultPayload {
    if (request.harness != .local_cli) {
        return error.UnsupportedHarnessMode;
    }

    const provider_config = switch (request.provider) {
        .opencode => ai_harness.ProviderConfig{
            .opencode = .{
                .allocator = allocator,
                .working_directory = request.project_path,
                .launch_if_missing = true,
            },
        },
        .codex => ai_harness.ProviderConfig{
            .codex = .{
                .cwd = request.project_path,
                .launch_on_connect = true,
            },
        },
        .cursor => ai_harness.ProviderConfig{
            .cursor = .{
                .cwd = request.project_path,
                .model = request.model_ref,
            },
        },
    };

    log.info(
        "send worker starting provider={s} cwd={s} model={s} thread_id={s} prompt_len={d}",
        .{
            @tagName(request.provider),
            request.project_path,
            request.model_ref orelse "(default)",
            request.provider_thread_id orelse "(new)",
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
        .cwd = request.project_path,
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
        .on_should_stop = handleSendShouldStop,
        .on_approval_request = handleSendApprovalRequest,
    }) catch |err| {
        std.debug.print(
            "[codex-debug] client.sendPrompt failed provider={s} cwd={s} model={s} thread_id={s}: {s}\n",
            .{
                @tagName(request.provider),
                request.project_path,
                request.model_ref orelse "(default)",
                request.provider_thread_id orelse "(new)",
                @errorName(err),
            },
        );
        runtime_log.diagnostic(
            "client.sendPrompt failed provider={s} cwd={s} model={s} thread_id={s}: {s}",
            .{
                @tagName(request.provider),
                request.project_path,
                request.model_ref orelse "(default)",
                request.provider_thread_id orelse "(new)",
                @errorName(err),
            },
        );
        log.err(
            "send worker failed provider={s} cwd={s} model={s} thread_id={s}: {s}",
            .{
                @tagName(request.provider),
                request.project_path,
                request.model_ref orelse "(default)",
                request.provider_thread_id orelse "(new)",
                @errorName(err),
            },
        );
        return err;
    };

    log.info(
        "send worker completed provider={s} provider_thread_id={s} reply_len={d}",
        .{ @tagName(request.provider), result.thread_id, result.reply_text.len },
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

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const child = try std.process.spawn(threaded.io(), .{
        .argv = argv_storage.items,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .cwd = if (cwd) |path| .{ .path = path } else .inherit,
        .environ_map = &env_map,
    });
    _ = child;
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

    const script = try std.fmt.allocPrint(allocator, "exec ${s} \"$1\"", .{editor.name});
    defer allocator.free(script);

    if (isTerminalEditorCommand(editor.value)) {
        const escaped_path = try shellSingleQuoteEscape(allocator, path);
        defer allocator.free(escaped_path);
        const terminal_script = try std.fmt.allocPrint(allocator, "exec ${s} '{s}'", .{ editor.name, escaped_path });
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
        else => error.UnsupportedOperatingSystem,
    };
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
    provider: app_state.Provider,
    err: anyerror,
) ![]u8 {
    return switch (err) {
        error.FileNotFound => std.fmt.allocPrint(
            allocator,
            "{s} CLI was not found. Install it and make sure it is available on PATH for packaged app launches.",
            .{providerLabel(provider)},
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
            "Cursor is not authenticated. Set CURSOR_API_KEY or sign in before sending.",
        ),
        error.CursorBridgeFailed => allocator.dupe(
            u8,
            "Cursor provider request failed. Check Cursor authentication and @cursor/sdk availability.",
        ),
        else => std.fmt.allocPrint(allocator, "Provider request failed: {s}", .{@errorName(err)}),
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

pub fn approvalPolicyForMode(_: app_state.Provider, mode: app_state.AccessMode) ?ai_harness.ApprovalPolicy {
    return switch (mode) {
        .full_access => .never,
        .supervised => .on_request,
    };
}

pub fn serviceTierForMode(provider: app_state.Provider, fast_mode: app_state.FastMode) ?ai_harness.ServiceTier {
    if (provider != .codex) return null;
    return switch (fast_mode) {
        .on => .fast,
        .off => null,
    };
}

pub fn sandboxModeForMode(provider: app_state.Provider, mode: app_state.AccessMode) ?ai_harness.SandboxMode {
    if (provider != .codex) return null;
    return switch (mode) {
        .full_access => .danger_full_access,
        .supervised => .workspace_write,
    };
}
fn handleSendThreadId(context: ?*anyopaque, thread_id: []const u8) void {
    const send_state: *app_state.SendState = @ptrCast(@alignCast(context orelse return));
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
}
fn handleSendTurnId(context: ?*anyopaque, turn_id: []const u8) void {
    const send_state: *app_state.SendState = @ptrCast(@alignCast(context orelse return));
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
}
fn handleSendStreamDelta(context: ?*anyopaque, delta: []const u8) void {
    const send_state: *app_state.SendState = @ptrCast(@alignCast(context orelse return));
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
}
fn handleSendStreamEvent(context: ?*anyopaque, event: ai_harness.StreamEvent) void {
    const send_state: *app_state.SendState = @ptrCast(@alignCast(context orelse return));
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
            };
        },
        .diff => |diff| {
            flushPendingAssistantTextLocked(send_state, page_alloc);
            mergePendingDiffFilesLocked(page_alloc, &send_state.pending_diff_files, diff.files);
        },
    }
}

fn handleSendShouldStop(context: ?*anyopaque) bool {
    const send_state: *app_state.SendState = @ptrCast(@alignCast(context orelse return true));
    send_state.mutex.lock();
    defer send_state.mutex.unlock();
    return send_state.stop_requested;
}

pub fn flushPendingAssistantTextLocked(send_state: *app_state.SendState, allocator: std.mem.Allocator) void {
    if (send_state.partial_text.items.len == 0) return;
    const provider = send_state.provider orelse return;
    const trimmed = std.mem.trim(u8, send_state.partial_text.items, &std.ascii.whitespace);
    if (trimmed.len == 0) {
        send_state.partial_text.clearRetainingCapacity();
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
}
fn mergePendingDiffFilesLocked(
    allocator: std.mem.Allocator,
    target: *std.ArrayListUnmanaged(app_state.PendingDiffFile),
    files: []const ai_harness.StreamDiffFile,
) void {
    for (files) |file| {
        if (upsertPendingDiffFileLocked(allocator, target, file)) |_| {} else |_| return;
    }
}
fn upsertPendingDiffFileLocked(
    allocator: std.mem.Allocator,
    target: *std.ArrayListUnmanaged(app_state.PendingDiffFile),
    file: ai_harness.StreamDiffFile,
) !void {
    for (target.items) |*existing| {
        if (!std.mem.eql(u8, existing.path, file.path)) continue;

        existing.additions = file.additions;
        existing.deletions = file.deletions;
        if (file.patch) |patch| {
            if (existing.patch) |existing_patch| {
                allocator.free(existing_patch);
            }
            existing.patch = try allocator.dupe(u8, patch);
        }
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
pub fn providerLabel(provider: app_state.Provider) [:0]const u8 {
    return chat_threads.providerLabel(provider);
}
fn handleSendApprovalRequest(context: ?*anyopaque, request: ai_harness.ApprovalRequest) ai_harness.ApprovalDecision {
    const send_state: *app_state.SendState = @ptrCast(@alignCast(context orelse return .deny));
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

    while (send_state.status == .pending and send_state.approval_decision == null) {
        send_state.condition.wait(&send_state.mutex);
    }

    const decision = send_state.approval_decision orelse .deny;
    send_state.approval_decision = null;
    freePendingApprovalLocked(page_alloc, &send_state.pending_approval);
    return decision;
}
pub fn freePendingApproval(allocator: std.mem.Allocator, approval: *?app_state.PendingApproval) void {
    if (approval.*) |pending| {
        allocator.free(pending.call_id);
        allocator.free(pending.title);
        allocator.free(pending.body);
        approval.* = null;
    }
}
pub fn freePendingApprovalLocked(allocator: std.mem.Allocator, approval: *?app_state.PendingApproval) void {
    freePendingApproval(allocator, approval);
}

/// Releases owned streamed timeline events copied out of the send worker.
pub fn freePendingTimelineEvents(
    allocator: std.mem.Allocator,
    events: *std.ArrayListUnmanaged(app_state.PendingTimelineEvent),
) void {
    for (events.items) |event| {
        allocator.free(event.author);
        allocator.free(event.body);
    }
    events.deinit(allocator);
    events.* = .empty;
}

pub fn freePendingTimelineEventsLocked(
    allocator: std.mem.Allocator,
    events: *std.ArrayListUnmanaged(app_state.PendingTimelineEvent),
) void {
    freePendingTimelineEvents(allocator, events);
}

/// Releases owned streamed diff entries copied out of the send worker.
pub fn freePendingDiffFiles(
    allocator: std.mem.Allocator,
    files: *std.ArrayListUnmanaged(app_state.PendingDiffFile),
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
    files: *std.ArrayListUnmanaged(app_state.PendingDiffFile),
) void {
    freePendingDiffFiles(allocator, files);
}

/// Persists the streamed diff summary as a synthetic system event on completion.
pub fn appendPendingDiffSummaryEvent(
    allocator: std.mem.Allocator,
    events: *std.ArrayListUnmanaged(app_state.PendingTimelineEvent),
    files: []const app_state.PendingDiffFile,
) void {
    if (files.len == 0) return;

    var body_builder: std.ArrayListUnmanaged(u8) = .empty;
    defer body_builder.deinit(allocator);

    body_builder.appendSlice(allocator, PERSISTED_DIFF_MARKER) catch return;

    for (files) |file| {
        const patch = file.patch orelse "";
        const header = std.fmt.allocPrint(allocator, "FILE\t{s}\t{d}\t{d}\t{d}\n", .{
            file.path,
            file.additions,
            file.deletions,
            patch.len,
        }) catch return;
        defer allocator.free(header);
        body_builder.appendSlice(allocator, header) catch return;
        body_builder.appendSlice(allocator, patch) catch return;
        body_builder.append(allocator, '\n') catch return;
    }

    const owned_title = allocator.dupe(u8, "Changed files") catch return;
    errdefer allocator.free(owned_title);
    const owned_body = body_builder.toOwnedSlice(allocator) catch {
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

pub fn pendingTimelineEventsContainAssistant(events: []const app_state.PendingTimelineEvent) bool {
    for (events) |event| {
        if (event.role == .assistant) return true;
    }
    return false;
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
    const types_path = try std.fmt.allocPrint(allocator, "/tmp/verde-clipboard-types-{d}.txt", .{std.c.getpid()});
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
    const output_path = try std.fmt.allocPrint(allocator, "/tmp/verde-clipboard-image-{d}.bin", .{std.c.getpid()});
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
    var send_state = app_state.SendState{ .status = .pending };
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

test "upsertPendingDiffFileLocked preserves patch when later updates omit it" {
    const allocator = std.testing.allocator;
    var files: std.ArrayListUnmanaged(app_state.PendingDiffFile) = .empty;
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
    try std.testing.expectEqualStrings("@@ -1 +1 @@\n-old\n+new\n", files.items[0].patch.?);
}
