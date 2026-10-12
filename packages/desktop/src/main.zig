//! Minimal native shell prototype for the desktop chat workflow.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

const palette = @import("palette");
const host = @import("ui/host.zig");
const dev_inject = @import("ui/dev_inject.zig");

const app_config = @import("app/config.zig");
const browser_runtime = @import("browser/mod.zig");
const browser_texture = @import("browser/texture.zig");
const chat_threads = @import("chat/threads.zig");
const live_ipc = @import("ipc/server.zig");
const loop_wakeup = @import("loop_wakeup");
const keybinds = @import("app/keybinds.zig");
const platform_runtime = @import("platform_runtime");
const windows_integrations = @import("platform/windows/integrations.zig");
const loop_pacing = @import("runtime/loop_pacing.zig");
const profiler = @import("runtime/profiler.zig");
const runtime_log = @import("runtime/log.zig");
const stb_image = @import("media/stb_image.zig");
const utils = @import("utils.zig");
const ui_layout = @import("ui/layout.zig");
const workspace_panes_ui = @import("ui/workspace_panes.zig");
const workspace_strip_ui = @import("ui/workspace_strip.zig");
const side_panel_ui = @import("ui/side_panel.zig");
const agent_prompt_popover_ui = @import("ui/agent_prompt_popover.zig");
const file_viewer_ui = @import("ui/file_viewer.zig");
const sidebar_ui = @import("ui/sidebar.zig");
const chat_panel_ui = @import("ui/chat_panel.zig");
const browser_ui = @import("ui/browser.zig");
const debug_ui = @import("ui/debug.zig");
const terminal_panel_ui = @import("ui/terminal_panel.zig");
const palette_frame_renderer = @import("ui/palette_frame_renderer.zig");
const ui_theme = @import("ui/theme.zig");
const colors = @import("ui/colors.zig");

comptime {
    if (builtin.os.tag == .windows and
        (!build_options.terminal_backend or !build_options.local_ipc or !build_options.windows_integrations))
    {
        @compileError("Windows desktop artifacts require the terminal, local IPC, and native integration backends");
    }
}

const native_state = @import("state.zig");
const companion_controller = @import("state/companion_controller.zig");
const AppState = native_state.AppState;
const Storage = native_state.Storage;

const log = native_state.log;
const UI_THREAD_STALL_LOG_THRESHOLD_NS: u64 = 50 * std.time.ns_per_ms;

pub const std_options: std.Options = .{
    .enable_segfault_handler = true,
    .logFn = runtime_log.logFn,
};

pub const panic = std.debug.FullPanic(runtime_log.panicFn);

const DEFAULT_FONT_SIZE: f32 = ui_theme.DEFAULT_FONT_SIZE;
const DEFAULT_WINDOW_WIDTH: c_int = 1360;
const DEFAULT_WINDOW_HEIGHT: c_int = 860;
const MIN_WINDOW_WIDTH: c_int = 960;
const MIN_WINDOW_HEIGHT: c_int = 680;
const MAX_WINDOW_WIDTH: c_int = 1520;
const MAX_WINDOW_HEIGHT: c_int = 980;
const ACTIVE_WAIT_TIMEOUT_MS: c_int = 16;
const IDLE_WAIT_TIMEOUT_MS: c_int = 50;
// ~30fps tick while a sidebar status pip is pulsing. The pulse is a ~1.6s
// sine (sidebar.zig), so 30fps already looks perfectly smooth at half the
// render cost of the 16ms ACTIVE tier; pips can stay lit for minutes while
// agents work, so the cheaper cadence matters.
const PIP_PULSE_WAIT_TIMEOUT_MS: c_int = 33;
// Pending chat turns animate the stop control and in-transcript activity cue
// at the same economical ~30fps cadence as sidebar pips.
const PENDING_SEND_WAIT_TIMEOUT_MS: c_int = 33;
// In-flight provider slash commands currently complete as one bridge result
// rather than token streaming, so the transcript row owns its liveness cue.
const SLASH_COMMAND_ANIMATION_WAIT_TIMEOUT_MS: c_int = 33;
// Detached shell tasks only need coarse liveness checks. A 1s wake keeps
// completion rows prompt without turning idle background work into animation.
const BACKGROUND_TASK_WAIT_TIMEOUT_MS: c_int = 1000;
// External config edits are human-paced. Four checks per second keep reloads
// effectively immediate without opening and statting the file on every frame.
const APP_CONFIG_POLL_INTERVAL_MS: i64 = 250;
const MOUSE_MOTION_RENDER_INTERVAL_MS: i64 = 33;
const MACOS_CMD_W_CLOSE_SUPPRESS_MS: i64 = 750;
/// Wayland app_id / macOS bundle identifier. Matches the desktop file's
/// StartupWMClass; `VERDE_APP_ID` overrides it for isolated test runs.
const DEFAULT_APP_ID = "com.verde.native";

const CursorState = struct {
    /// A native browser child view (WKWebView, windowed WebView2) applied its
    /// own CSS cursor; the next shape Verde picks must be re-sent even if it
    /// equals the last one Verde set.
    native_browser_owned: bool = false,
    /// Inputs of the last cursor resolution, so idle loop iterations (stream
    /// polls, wakeups that build no frame) can skip re-running every hit test.
    last_sync_ms: i64 = 0,
    last_mouse_x: f32 = std.math.nan(f32),
    last_mouse_y: f32 = std.math.nan(f32),
    last_browser_shape: browser_runtime.CursorShape = .default,
};

/// Upper bound on how stale an idle-loop cursor may get. Async inputs that
/// carry no event (native-browser cursor ownership, terminal OSC 22 shapes,
/// hover targets appearing under a still mouse) settle within this window.
const CURSOR_IDLE_RESYNC_MS: i64 = 250;

/// Whether a loop iteration that renders no frame must re-resolve the cursor.
/// Rendered frames always resync; idle iterations only when the pointer
/// moved, input arrived, the offscreen browser reported a new CSS cursor, or
/// the safety interval elapsed.
fn idleCursorSyncDue(
    cache: *const CursorState,
    mouse_x: f32,
    mouse_y: f32,
    browser_shape: browser_runtime.CursorShape,
    had_input: bool,
    now_ms: i64,
) bool {
    if (had_input) return true;
    if (mouse_x != cache.last_mouse_x or mouse_y != cache.last_mouse_y) return true;
    if (browser_shape != cache.last_browser_shape) return true;
    return now_ms - cache.last_sync_ms >= CURSOR_IDLE_RESYNC_MS;
}

fn noteCursorSynced(cache: *CursorState, state: *const AppState, now_ms: i64) void {
    cache.last_sync_ms = now_ms;
    cache.last_mouse_x = state.transcript_controller.palette_mouse_x;
    cache.last_mouse_y = state.transcript_controller.palette_mouse_y;
    cache.last_browser_shape = state.browser_controller.cursor_shape;
}

test "initial window frame stays inside a work area smaller than the preferred minimum" {
    // 1280x800 at 125% with a 60px taskbar: 1024x592 logical.
    const small = initialWindowFrameFor(.{ .x = 0, .y = 0, .w = 1024, .h = 592 });
    try std.testing.expect(small.x >= 0 and small.y >= 0);
    try std.testing.expect(small.x + small.w <= 1024 and small.y + small.h <= 592);
    try std.testing.expectEqual(@as(c_int, 552), small.h);

    const large = initialWindowFrameFor(.{ .x = 0, .y = 0, .w = 1920, .h = 1040 });
    try std.testing.expectEqual(@as(c_int, MIN_WINDOW_HEIGHT) + 89, large.h);
    try std.testing.expectEqual(@divTrunc(1040 - large.h, 2), large.y);

    try std.testing.expectEqual(@as(c_int, 100), scaleWindowCoordinate(80, 1.25));
    try std.testing.expectEqual(@as(c_int, 80), scaleWindowCoordinate(80, 0));
}

test "idle cursor sync runs only when an input changed or the resync interval elapsed" {
    var cache: CursorState = .{};
    // Never synced: NaN positions always compare unequal.
    try std.testing.expect(idleCursorSyncDue(&cache, 10.0, 20.0, .default, false, 1_000));
    cache.last_sync_ms = 1_000;
    cache.last_mouse_x = 10.0;
    cache.last_mouse_y = 20.0;
    cache.last_browser_shape = .default;
    // Stream polls / wakeups with a still mouse skip the hit tests.
    try std.testing.expect(!idleCursorSyncDue(&cache, 10.0, 20.0, .default, false, 1_001));
    try std.testing.expect(!idleCursorSyncDue(&cache, 10.0, 20.0, .default, false, 1_000 + CURSOR_IDLE_RESYNC_MS - 1));
    // Safety resync for event-less async cursor changes.
    try std.testing.expect(idleCursorSyncDue(&cache, 10.0, 20.0, .default, false, 1_000 + CURSOR_IDLE_RESYNC_MS));
    // Any motion, input event, or offscreen-browser CSS cursor change resyncs now.
    try std.testing.expect(idleCursorSyncDue(&cache, 11.0, 20.0, .default, false, 1_001));
    try std.testing.expect(idleCursorSyncDue(&cache, 10.0, 21.0, .default, false, 1_001));
    try std.testing.expect(idleCursorSyncDue(&cache, 10.0, 20.0, .default, true, 1_001));
    try std.testing.expect(idleCursorSyncDue(&cache, 10.0, 20.0, .pointer, false, 1_001));
}

const CAL_SANS_BYTES = @embedFile("assets/fonts/CalSans-Regular.ttf");
const NOTO_SANS_REGULAR_BYTES = @embedFile("assets/fonts/NotoSans-Regular.ttf");
const NOTO_SANS_BOLD_BYTES = @embedFile("assets/fonts/NotoSans-Bold.ttf");
const NOTO_SANS_ITALIC_BYTES = @embedFile("assets/fonts/NotoSans-Italic.ttf");
const NOTO_SANS_BOLD_ITALIC_BYTES = @embedFile("assets/fonts/NotoSans-BoldItalic.ttf");
const CODICON_BYTES = @embedFile("assets/fonts/Codicon.ttf");
const NERD_SYMBOLS_BYTES = @embedFile("assets/fonts/SymbolsNerdFontMono-Regular.ttf");
const JETBRAINS_MONO_NERD_BYTES = @embedFile("assets/fonts/JetBrainsMonoNerdFont-Regular.ttf");
const NOTO_SANS_SYMBOLS2_BYTES = @embedFile("assets/fonts/NotoSansSymbols2-Regular.ttf");
const NOTO_SANS_SYMBOLS_BYTES = @embedFile("assets/fonts/NotoSansSymbols-Regular.ttf");
const NOTO_EMOJI_BYTES = @embedFile("assets/fonts/NotoEmoji-Regular.ttf");

var macos_cmd_w_pane_close_until_ms: i64 = 0;
var macos_launch_close_suppress_until_ms: i64 = 0;
const MACOS_LAUNCH_CLOSE_SUPPRESS_MS: i64 = 650;

const WindowFrame = struct {
    x: c_int,
    y: c_int,
    w: c_int,
    h: c_int,
};

pub fn main(init: std.process.Init) void {
    mainInner(init) catch |err| {
        runtime_log.diagnostic("fatal startup error: {s}", .{@errorName(err)});
        std.debug.print("fatal startup error: {s}\n", .{@errorName(err)});
        logFatalStartupHint(err);
        std.process.exit(1);
    };
}

fn logFatalStartupHint(err: anyerror) void {
    switch (err) {
        error.VulkanLoaderNotFound, error.NoSuitableGpu, error.VulkanIncompatibleDriver, error.VulkanInitializationFailed => if (builtin.os.tag == .linux) {
            runtime_log.diagnostic("startup hint: GPU device creation failed. This usually means Vulkan is unavailable for the active GPU. Install the Vulkan driver for your GPU: Arch Intel `vulkan-intel`, AMD `vulkan-radeon`, software fallback `vulkan-swrast`; Debian/Ubuntu Intel/AMD `mesa-vulkan-drivers`.", .{});
            std.debug.print(
                \\startup hint: Verde could not create a Vulkan device.
                \\Install the Vulkan driver for the active GPU:
                \\  Arch Intel: sudo pacman -S --needed vulkan-intel
                \\  Arch AMD:   sudo pacman -S --needed vulkan-radeon
                \\  Fallback:   sudo pacman -S --needed vulkan-swrast
                \\  Debian/Ubuntu Intel/AMD: sudo apt install mesa-vulkan-drivers
                \\Then verify with: vulkaninfo --summary
                \\
            , .{});
        },
        else => {},
    }
}

fn mainInner(init: std.process.Init) !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer {
        if (builtin.mode == .Debug) _ = debug_allocator.deinit();
    }
    const allocator = if (builtin.mode == .Debug)
        debug_allocator.allocator()
    else
        std.heap.smp_allocator;

    if (builtin.os.tag == .windows and !windows_integrations.setProcessAppUserModelId()) {
        log.warn("failed to set Windows application identity to {s}", .{windows_integrations.app_user_model_id});
    }

    // Signals are handled by flag, not by palette's signalfd: that blocks
    // SIGINT/SIGTERM in the thread mask, and a blocked mask survives fork and
    // exec, so terminals and the daemon would inherit it.
    installTerminationSignalHandlers();
    const app = try palette.platform.App.init(allocator, .{
        .app_id = desktopAppId(),
        .environ = init.minimal.environ,
        .handle_signals = builtin.os.tag == .windows,
        // VERDE_ICON in src/platform/windows/verde.rc.
        .icon_resource_id = 101,
    });
    defer app.deinit();
    loop_wakeup.init(app, postLoopWakeup);
    defer loop_wakeup.deinit();
    if (builtin.os.tag == .macos) utils.native_clipboard_image_reader = readMacosClipboardImage;
    defer utils.native_clipboard_image_reader = null;

    var storage = try Storage.init(allocator);
    defer storage.deinit();
    runtime_log.init(init.io, storage.pref_path) catch |err| {
        log.warn("failed to initialize runtime logging: {s}", .{@errorName(err)});
    };
    if (runtime_log.stderrLogPath()) |path| {
        log.info("runtime stderr redirected to {s}", .{path});
    }

    const initial_window_frame = windowFrameOverrideFromEnv() orelse initialWindowFrame(app);
    const window = try app.createWindow(.{
        .title = "verde",
        .width = @intCast(initial_window_frame.w),
        .height = @intCast(initial_window_frame.h),
        .resizable = true,
    });
    defer window.destroy();
    host.install(app, window);
    defer host.uninstall();
    var cursor_state: CursorState = .{};
    // `usableRect` is logical on every backend, but Win32 positions windows in
    // physical pixels, so scale the centred origin by the window's DPI there.
    const position_scale: f32 = if (builtin.os.tag == .windows) window.scale() else 1.0;
    window.setPosition(scaleWindowCoordinate(initial_window_frame.x, position_scale), scaleWindowCoordinate(initial_window_frame.y, position_scale));
    activateMacosHostWindow(window);
    if (builtin.os.tag == .macos) {
        macos_launch_close_suppress_until_ms = currentTimeMillis() + MACOS_LAUNCH_CLOSE_SUPPRESS_MS;
    }
    defer window.stopTextInput();
    // Map the native window immediately. Font loading, GPU setup, and the
    // large durable projection all happen below; none should postpone the
    // compositor-visible launch boundary. The icon comes from the desktop
    // file (Linux), the app bundle (macOS) or the exe resource (Windows).
    window.show();
    app.sync() catch {};

    const loaded_app_config = app_config.loadAppConfig(allocator) catch |err| blk: {
        log.warn("failed to load app config: {s}", .{@errorName(err)});
        break :blk app_config.AppConfig{ .font_size = DEFAULT_FONT_SIZE };
    };
    _ = syncSystemAppearance();
    ui_theme.applyConfigTheme(allocator, loaded_app_config.theme_config);

    // Install the font metrics used by the Palette desktop UI.
    ui_theme.installFonts(
        CAL_SANS_BYTES[0..CAL_SANS_BYTES.len],
        NOTO_SANS_BOLD_BYTES[0..NOTO_SANS_BOLD_BYTES.len],
        NOTO_SANS_ITALIC_BYTES[0..NOTO_SANS_ITALIC_BYTES.len],
        NOTO_SANS_BOLD_ITALIC_BYTES[0..NOTO_SANS_BOLD_ITALIC_BYTES.len],
        CODICON_BYTES[0..CODICON_BYTES.len],
        NERD_SYMBOLS_BYTES[0..NERD_SYMBOLS_BYTES.len],
        loaded_app_config.font_size,
    );
    // Role faces for the shared font engine. Bundled faces are read straight
    // from the binary; only the user's Ghostty mono font and the system math
    // face come from disk (mapped while the collection loads them).
    const ghostty_mono_font_path = try ghosttyMonoFontPath(allocator);
    defer if (ghostty_mono_font_path) |path| allocator.free(path);
    const system_math_font_path = try systemMathFontPath(allocator);
    defer if (system_math_font_path) |path| allocator.free(path);
    const font_faces: palette.fonts.FaceSet = .{
        .ui = .{ .memory = CAL_SANS_BYTES },
        // ui_bold and prose_bold both resolve to Noto Sans Bold.
        .bold = .{ .memory = NOTO_SANS_BOLD_BYTES },
        .prose = .{ .memory = NOTO_SANS_REGULAR_BYTES },
        .italic = .{ .memory = NOTO_SANS_ITALIC_BYTES },
        .bold_italic = .{ .memory = NOTO_SANS_BOLD_ITALIC_BYTES },
        .mono = if (ghostty_mono_font_path) |path| .{ .path = path } else .{ .memory = JETBRAINS_MONO_NERD_BYTES },
        .icon = .{ .memory = NERD_SYMBOLS_BYTES },
        // Codicon backs Nerd Symbols for newer codicons (U+EC5E .txt icon).
        .icon_fallback = .{ .memory = CODICON_BYTES },
        // JetBrains Mono Nerd is always the first coverage fallback for mono,
        // even when Ghostty names another primary (e.g. CaskaydiaMono): it
        // carries common TUI symbols (Vite ➜, Claude Code's ✻/✽ spinner
        // frames, ●, □) that user-chosen fonts often lack.
        .mono_symbols = .{ .memory = JETBRAINS_MONO_NERD_BYTES },
        // Noto Sans Symbols 2 covers ~145/192 Dingbats plus Misc Symbols
        // (✻/✽/✶, ➤, ✷) that even JetBrains Mono Nerd lacks.
        .symbols = .{ .memory = NOTO_SANS_SYMBOLS2_BYTES },
        // The original Noto Sans Symbols adds numbered dingbats (❶❷..❿ /
        // ➀➁..➓ at U+2776..2793) and other blocks Symbols 2 omits.
        .symbols_alt = .{ .memory = NOTO_SANS_SYMBOLS_BYTES },
        .math = if (system_math_font_path) |path| .{ .path = path } else .none,
        // Monochrome Noto Emoji for the emoji-styled Dingbats Symbols 2
        // excludes (✨, ✅/❌, ➕/➖, ❤, ℹ, ⚡, ⚠) and 4-byte emoji (🔥/📦).
        .emoji = .{ .memory = NOTO_EMOJI_BYTES },
    };
    var palette_renderer = try palette_frame_renderer.Renderer.init(allocator, .{
        .app = app,
        .window = window,
        .io = init.io,
        .faces = font_faces,
    });
    defer palette_renderer.deinit();
    browser_texture.configureExternalUploader(
        &palette_renderer,
        palette_frame_renderer.Renderer.uploadPaneTextureCallback,
        palette_frame_renderer.Renderer.releasePaneTextureCallback,
    );
    defer browser_texture.configureExternalUploader(null, null, null);
    browser_texture.configureDmabufImporter(palette_renderer.dmabufImporter());
    defer browser_texture.configureDmabufImporter(null);
    runtime_log.diagnostic("palette renderer active backend={s}", .{palette_frame_renderer.backend_name});

    var ui_scale = currentWindowDisplayScale(window);
    // Apply the global ImGui style after the display scale is known.
    ui_theme.applyTheme(ui_scale);

    // Startup surface: submit one real GPU frame before the potentially large
    // read-only SQLite projection is materialized into AppState.
    renderStartupFrame(&palette_renderer, allocator, window) catch |err| {
        log.warn("failed to render startup frame: {s}", .{@errorName(err)});
    };
    window.show();
    app.sync() catch {};

    var state = try AppState.init(allocator, &storage, loaded_app_config, .{
        .gl_texture_uploads_enabled = false,
        .browser_textures_enabled = true,
        .texture_upload_context = &palette_renderer,
        .texture_upload_fn = palette_frame_renderer.Renderer.uploadLoadedTextureCallback,
        .texture_release_fn = palette_frame_renderer.Renderer.releaseTextureCallback,
    });
    defer state.deinit();
    // AppState.init returns by value, so attach the heap-owned runtime service
    // only after `state` has its final address. `init.io` is process-owned and
    // remains valid for every service worker through application shutdown.
    attachRuntimeService(&state, allocator, init.io) catch |err| {
        // Error names are bounded and contain neither profile contents nor
        // process-memory-only bearer credentials.
        log.warn("failed to load remote runtime profiles: {s}", .{@errorName(err)});
    };
    state.loadWorkspaceRuntimeDefaults() catch |err| {
        // A malformed or unavailable defaults file must not prevent startup;
        // new drafts remain Local until the administrator repairs it.
        log.warn("failed to load workspace runtime defaults: {s}", .{@errorName(err)});
    };
    state.app_config_file_mtime = app_config.configFileMtime(allocator) catch -1;
    state.attachBrowserHostWindow(nativeBrowserHostWindow(window));
    state.openBrowserOnLaunchIfRequested();
    state.restorePersistedBrowserPaneOnLaunch();
    state.applyInitialWorkspaceFocusOnLaunch();
    if (state.consumePendingHerdrOpenRequest() catch |err| blk: {
        log.warn("failed to consume pending Herdr open request: {s}", .{@errorName(err)});
        break :blk false;
    }) {
        log.info("consumed pending Herdr open request", .{});
    }
    state.startProviderReadinessCheck();
    // Keep the persisted Cursor picker responsive at launch, then replace it
    // with the model set reported by the installed, authenticated Cursor CLI.
    state.startCursorModelOptionsRefresh();
    // pi and fx expose their configured catalogs cheaply (one short-lived
    // process each), so discover them once in the background at launch.
    state.startPiModelOptionsRefresh();
    state.startFxModelOptionsRefresh();
    state.startGrokModelOptionsRefresh();
    state.startMuseModelOptionsRefresh();
    state.startAutomaticUpdateCheck();
    var live_server: ?live_ipc.LiveServer = live_ipc.LiveServer.init(allocator, storage.pref_path) catch |err| blk: {
        log.warn("failed to initialize live-control server: {s}", .{@errorName(err)});
        break :blk null;
    };
    if (live_server) |*server| {
        server.start() catch |err| {
            log.warn("failed to start live-control server: {s}", .{@errorName(err)});
            server.deinit();
            live_server = null;
        };
    }
    defer if (live_server) |*server| server.deinit();
    var keyboard = try keybinds.NativeKeyboardConfig.load(allocator);
    defer keyboard.deinit();
    // Reloads swap the config in place through this same pointer, so the
    // palette's accelerator hints stay live across keybind refreshes.
    state.command_controller.keyboard_config = &keyboard;

    log.info("verde main loop starting", .{});
    defer log.info("verde main loop exiting", .{});

    var running = true;
    var presentation_demand: loop_pacing.PresentationDemand = .{};
    presentation_demand.request();
    var last_mouse_motion_render_ms: i64 = 0;
    const frame_profile_logging = frameProfileLoggingEnabled();
    var last_frame_profile_log_ms: i64 = 0;
    var last_framebuffer_width: c_int = 0;
    var last_framebuffer_height: c_int = 0;
    var render_pacer: loop_pacing.FramePacer = .{};
    var app_config_poll_cadence: loop_pacing.Cadence = .{};
    var pending_wake_sequence: ?u64 = null;
    var previous_loop_start_ns = profiler.nowNs();
    var previous_loop_wait: LoopWaitTrace = .{};
    // Browser-frame-only fast path: see `palette_frame_renderer.RetainedFrame`.
    var retained_frame = palette_frame_renderer.RetainedFrame.init(allocator);
    defer retained_frame.deinit(allocator);
    // `loop_wakeup.layoutSequence()` covered by the last presented layout.
    var layout_sequence_covered: u64 = 0;
    // Pointer input since the last layout that may have changed Verde UI.
    var motion_needs_layout = false;
    while (running) {
        const loop_start_ns = profiler.nowNs();
        const loop_gap_ns = profiler.elapsedNs(previous_loop_start_ns);
        if (loop_gap_ns > 100 * std.time.ns_per_ms) {
            runtime_log.trace(
                "main-loop gap elapsed_ms={d:.2} sleep_reason={s} wait_requested_ms={d} waited_ms={d:.2} pending_frame_on_entry={}",
                .{
                    profiler.nsToMs(loop_gap_ns),
                    @tagName(previous_loop_wait.reason),
                    previous_loop_wait.requested_timeout_ms,
                    profiler.nsToMs(previous_loop_wait.waited_ns),
                    previous_loop_wait.pending_frame_on_entry,
                },
            );
        }
        previous_loop_start_ns = loop_start_ns;
        if (consumeTerminationSignal()) {
            runtime_log.diagnostic("shutdown requested by termination signal", .{});
            if (closePreflightPassed(&state)) break;
        }
        var frame_sample = profiler.FrameSample{};
        syncWindowTextInput(window, &state);
        var event_flags = EventFlags{};
        var loop_wait: LoopWaitTrace = .{
            .pending_frame_on_entry = presentation_demand.pending,
        };
        var input_fb_w: c_int = 0;
        var input_fb_h: c_int = 0;
        getWindowSizeInPixels(window, &input_fb_w, &input_fb_h);
        ui_layout.refreshPaletteModalHits(&state, @floatFromInt(input_fb_w), @floatFromInt(input_fb_h));
        running = processEvents(app, window, &palette_renderer, &state, &keyboard, ui_scale, &event_flags, &frame_sample, &loop_wait, &render_pacer, &presentation_demand);
        previous_loop_wait = loop_wait;
        if (!running) break;
        state.noteWorkspaceSwitchStage("event_drain_complete");
        frame_sample.waited_ns = loop_wait.waited_ns;
        state.pollAcknowledgements();
        if (state.acknowledgeFocusedTerminalCompletion()) presentation_demand.request();
        recordSpan(&frame_sample, .poll_picker, struct {
            fn run(app_state: *AppState) void {
                app_state.processDeferredProjectDirectoryBrowse();
            }
        }.run, .{&state});
        recordSpan(&frame_sample, .poll_picker, struct {
            fn run(app_state: *AppState) void {
                app_state.pollPicker();
            }
        }.run, .{&state});
        recordSpan(&frame_sample, .poll_models, struct {
            fn run(app_state: *AppState) void {
                app_state.pollOpencodeModelOptionsCache();
                app_state.pollClaudeModelOptionsCache();
                app_state.pollCursorModelOptionsCache();
                app_state.pollPiModelOptionsCache();
                app_state.pollFxModelOptionsCache();
                app_state.pollGrokModelOptionsCache();
                app_state.pollMuseModelOptionsCache();
                app_state.pollProviderReadiness();
                app_state.pollCookieImport();
                app_state.pollGitChanges();
                // Files stage 2 defines this; guarded so the hook lands first.
                if (@hasDecl(AppState, "pollFileViewer")) app_state.pollFileViewer();
                app_state.pollUpdateCheck();
            }
        }.run, .{&state});
        const runtime_now_ms: u64 = std.math.cast(
            u64,
            @divTrunc(loop_start_ns, std.time.ns_per_ms),
        ) orelse if (loop_start_ns < 0) 0 else std.math.maxInt(u64);
        const runtime_needs_render = state.pollRuntimeService(runtime_now_ms);
        if (state.settings_controller.update_exit_requested and closePreflightPassed(&state)) {
            _ = state.consumeUpdateExitRequest();
            running = false;
            continue;
        }
        var send_needs_render = false;
        recordSpan(&frame_sample, .poll_send, struct {
            fn run(app_state: *AppState, changed: *bool) void {
                const send_changed = app_state.pollSend();
                const slash_changed = app_state.pollSlashCommand();
                const linked_changed = app_state.pollLinkedChats();
                changed.* = send_changed or slash_changed or linked_changed;
            }
        }.run, .{ &state, &send_needs_render });
        var background_tasks_need_render = false;
        recordSpan(&frame_sample, .poll_background_tasks, struct {
            fn run(app_state: *AppState, changed: *bool) void {
                const tasks_changed = app_state.pollBackgroundTasks();
                // Commit any completed async transcript-page load before this
                // frame renders so prepended history appears with its anchor
                // rebased in the same frame.
                const hydration_changed = app_state.pollTranscriptHydration();
                changed.* = tasks_changed or hydration_changed;
            }
        }.run, .{ &state, &background_tasks_need_render });
        var browser_needs_render = false;
        recordSpan(&frame_sample, .poll_browser, struct {
            fn run(app_state: *AppState, changed: *bool) void {
                changed.* = app_state.pollBrowser();
            }
        }.run, .{ &state, &browser_needs_render });
        var terminal_needs_render = false;
        recordSpan(&frame_sample, .poll_terminals, struct {
            fn run(app_state: *AppState, changed: *bool) void {
                changed.* = app_state.pollTerminals();
            }
        }.run, .{ &state, &terminal_needs_render });
        if (app_config_poll_cadence.shouldRun(monotonicMs(), APP_CONFIG_POLL_INTERVAL_MS)) {
            recordSpan(&frame_sample, .poll_config, struct {
                fn run(app_state: *AppState, kb: *keybinds.NativeKeyboardConfig) void {
                    pollAppConfigFileChanges(app_state, kb);
                    pollOmarchyThemeChanges(app_state);
                }
            }.run, .{ &state, &keyboard });
        }
        if (state.app_config_runtime_sync_pending) {
            state.app_config_runtime_sync_pending = false;
            applyAppConfigRuntime(&state);
        }
        if (live_server) |*server| {
            if (server.processPending(&state)) presentation_demand.request();
        }
        live_ipc.pollResourceWaiters(&state);
        state.noteWorkspaceSwitchStage("pre_render_poll_complete");

        var observed_fb_width: c_int = 0;
        var observed_fb_height: c_int = 0;
        getWindowSizeInPixels(window, &observed_fb_width, &observed_fb_height);
        const framebuffer_size_changed = observed_fb_width != last_framebuffer_width or observed_fb_height != last_framebuffer_height;
        if (framebuffer_size_changed) {
            const observed_scale = currentWindowDisplayScale(window);
            const logical_size = window.logicalSize();
            runtime_log.trace("framebuffer size changed: pixel {d}x{d} logical {d}x{d} scale {d:.3} (prev pixel {d}x{d})", .{
                observed_fb_width,
                observed_fb_height,
                logical_size.width,
                logical_size.height,
                observed_scale,
                last_framebuffer_width,
                last_framebuffer_height,
            });
            last_framebuffer_width = observed_fb_width;
            last_framebuffer_height = observed_fb_height;
        }

        if (event_flags.loop_wakeup_sequence) |sequence| {
            pending_wake_sequence = sequence;
            render_pacer.requestWakeRender();
        }
        const now_ms = monotonicMs();
        const continuous_interval_ms = continuousFrameIntervalMs(&state);
        const continuous_frames = continuous_interval_ms != 0;
        const continuous_frame_due = continuous_frames and render_pacer.continuousFrameDue(now_ms, continuous_interval_ms);
        const wake_frame_due = render_pacer.wakeRenderDue(now_ms, ACTIVE_WAIT_TIMEOUT_MS);
        // Wakes that only announce a new browser frame leave the layout
        // sequence alone; those frames need no UI rebuild.
        const wake_needs_layout = wake_frame_due and loop_wakeup.layoutSequence() != layout_sequence_covered;
        // Pointer motion and forwarded wheel over an unobstructed browser page
        // only reach WebKit; the page answers with new frames.
        const pointer_in_browser = retained_frame.pointerStaysInBrowser(
            state.transcript_controller.palette_mouse_x,
            state.transcript_controller.palette_mouse_y,
        );
        const layout_mouse_motion = event_flags.has_mouse_motion and !pointer_in_browser;
        const layout_browser_wheel = event_flags.has_browser_wheel and !pointer_in_browser;
        if (layout_mouse_motion or layout_browser_wheel) motion_needs_layout = true;
        const event_needs_render = event_flags.has_non_mouse_motion or event_flags.renderer_redraw or layout_browser_wheel or
            shouldRenderMouseMotion(layout_mouse_motion, continuous_frames, &last_mouse_motion_render_ms);
        // A wake-driven send change is covered by the display-rate wake frame.
        // Non-wake polling changes still render immediately.
        const immediate_send_render = send_needs_render and event_flags.loop_wakeup_sequence == null;
        if (runtime_needs_render or immediate_send_render or background_tasks_need_render or browser_needs_render or terminal_needs_render or event_needs_render or framebuffer_size_changed or continuous_frame_due or wake_needs_layout or state.workspaceSwitchFramePending()) {
            presentation_demand.request();
        }
        if (state.takeBrowserTextureFrame() or wake_frame_due) presentation_demand.requestTextureOnly();
        // The present loop throttles until the compositor's frame callback (or
        // its timeout on hidden surfaces); building a frame it would refuse
        // only burns CPU, so keep the demand pending and wait for `.frame`.
        if (!presentation_demand.pending or !palette_renderer.ready()) {
            if (idleCursorSyncDue(
                &cursor_state,
                state.transcript_controller.palette_mouse_x,
                state.transcript_controller.palette_mouse_y,
                state.browser_controller.cursor_shape,
                event_flags.has_mouse_motion or event_flags.has_non_mouse_motion,
                now_ms,
            )) {
                recordSpan(&frame_sample, .sync_cursor, syncMouseCursor, .{ &state, &cursor_state });
                noteCursorSynced(&cursor_state, &state, now_ms);
            }
            recordFrameWithStallDiagnostic(frame_sample);
            maybeLogFrameProfile(frame_profile_logging, &last_frame_profile_log_ms, &palette_renderer);
            palette_renderer.maybeWriteDevStats(monotonicNsU64());
            continue;
        }

        if (presentation_demand.textureOnly() and !motion_needs_layout and
            state.pendingWorkspaceSwitchTrace() == null and !state.workspaceSwitchFramePending())
        texture_only: {
            var replay_width: c_int = 0;
            var replay_height: c_int = 0;
            getWindowSizeInPixels(window, &replay_width, &replay_height);
            if (!retained_frame.canReplay(retainedFrameLayout(&state, replay_width, replay_height, currentWindowDisplayScale(window), now_ms))) break :texture_only;
            var replay_presented = false;
            recordSpan(&frame_sample, .draw_backend, struct {
                fn run(
                    palette_command_renderer: *palette_frame_renderer.Renderer,
                    retained: *palette_frame_renderer.RetainedFrame,
                    allocator_arg: std.mem.Allocator,
                    framebuffer_width: c_int,
                    framebuffer_height: c_int,
                    presented: *bool,
                ) void {
                    const outcome = palette_command_renderer.renderBatch(
                        allocator_arg,
                        &retained.batch,
                        @floatFromInt(framebuffer_width),
                        @floatFromInt(framebuffer_height),
                    ) catch |err| {
                        log.warn("failed to replay retained palette batch: {s}", .{@errorName(err)});
                        retained.invalidate();
                        return;
                    };
                    presented.* = palette_frame_renderer.outcomePresented(outcome);
                }
            }.run, .{ &palette_renderer, &retained_frame, allocator, replay_width, replay_height, &replay_presented });
            logSlowGpuFrameStages(palette_renderer.lastFrameStats());
            if (!retained_frame.valid) break :texture_only;
            presentation_demand.noteAttempt(replay_presented);
            if (replay_presented) {
                palette_renderer.counters.texture_only += 1;
                state.noteBrowserFramePresented();
                render_pacer.noteRendered(monotonicMs());
                recordSpan(&frame_sample, .flush_dirty, struct {
                    fn run(app_state: *AppState) void {
                        app_state.pollFlushWorker();
                        app_state.flushIfDirty();
                    }
                }.run, .{&state});
                if (pending_wake_sequence) |sequence| {
                    loop_wakeup.finish(sequence);
                    pending_wake_sequence = null;
                    render_pacer.clearWakeRender();
                }
            }
            if (idleCursorSyncDue(
                &cursor_state,
                state.transcript_controller.palette_mouse_x,
                state.transcript_controller.palette_mouse_y,
                state.browser_controller.cursor_shape,
                event_flags.has_mouse_motion or event_flags.has_non_mouse_motion or event_flags.has_browser_wheel,
                now_ms,
            )) {
                recordSpan(&frame_sample, .sync_cursor, syncMouseCursor, .{ &state, &cursor_state });
                noteCursorSynced(&cursor_state, &state, now_ms);
            }
            frame_sample.rendered = replay_presented;
            recordFrameWithStallDiagnostic(frame_sample);
            maybeLogFrameProfile(frame_profile_logging, &last_frame_profile_log_ms, &palette_renderer);
            palette_renderer.maybeWriteDevStats(monotonicNsU64());
            continue;
        }

        var fb_width: c_int = 0;
        var fb_height: c_int = 0;
        recordSpan(&frame_sample, .render_setup, struct {
            fn run(
                app_window: *palette.platform.Window,
                framebuffer_width: *c_int,
                framebuffer_height: *c_int,
                current_scale: *f32,
            ) void {
                getWindowSizeInPixels(app_window, framebuffer_width, framebuffer_height);

                const next_ui_scale = currentWindowDisplayScale(app_window);
                if (@abs(next_ui_scale - current_scale.*) > 0.01) {
                    current_scale.* = next_ui_scale;
                    ui_theme.applyTheme(current_scale.*);
                }
            }
        }.run, .{ window, &fb_width, &fb_height, &ui_scale });
        const window_screen_position = window.position();
        state.noteAppWindowFrame(window_screen_position[0], window_screen_position[1], ui_scale);
        state.palette_overlay_batch.clear();
        state.palette_frame_text.clearRetainingCapacity();
        _ = state.palette_frame_text_arena.reset(.retain_capacity);
        state.code_copy_buttons.clearRetainingCapacity();
        state.card_toggle_hits.clearRetainingCapacity();
        state.background_task_action_hits.clearRetainingCapacity();
        chat_panel_ui.resetRuntimeBannerHits();

        state.noteWorkspaceSwitchRenderStarted();
        const build_layout_sequence = loop_wakeup.layoutSequence();
        const build_now_ms = monotonicMs();
        recordSpan(&frame_sample, .render_root, struct {
            fn run(app_state: *AppState, framebuffer_width: c_int, framebuffer_height: c_int) void {
                ui_layout.renderRoot(app_state, @floatFromInt(framebuffer_width), @floatFromInt(framebuffer_height));
            }
        }.run, .{ &state, fb_width, fb_height });
        recordSpan(&frame_sample, .sync_cursor, syncMouseCursor, .{ &state, &cursor_state });
        noteCursorSynced(&cursor_state, &state, monotonicMs());
        state.noteWorkspaceSwitchStage("render_root_cursor_complete");
        var frame_presented = false;
        recordSpan(&frame_sample, .draw_backend, struct {
            fn run(
                palette_command_renderer: *palette_frame_renderer.Renderer,
                app_state: *AppState,
                allocator_arg: std.mem.Allocator,
                framebuffer_width: c_int,
                framebuffer_height: c_int,
                presented: *bool,
            ) void {
                const outcome = palette_command_renderer.renderBatch(
                    allocator_arg,
                    &app_state.palette_overlay_batch,
                    @floatFromInt(framebuffer_width),
                    @floatFromInt(framebuffer_height),
                ) catch |err| {
                    log.warn("failed to render palette overlay batch: {s}", .{@errorName(err)});
                    return;
                };
                presented.* = palette_frame_renderer.outcomePresented(outcome);
            }
        }.run, .{ &palette_renderer, &state, allocator, fb_width, fb_height, &frame_presented });
        {
            const stats = palette_renderer.lastFrameStats();
            logSlowGpuFrameStages(stats);
            if (state.pendingWorkspaceSwitchTrace()) |trace| logWorkspaceSwitchGpuFrameStats(trace, stats);
        }
        presentation_demand.noteAttempt(frame_presented);
        if (frame_presented) {
            palette_renderer.counters.full += 1;
            layout_sequence_covered = build_layout_sequence;
            motion_needs_layout = false;
            var layout = retainedFrameLayout(&state, fb_width, fb_height, ui_scale, build_now_ms);
            layout.layout_sequence = build_layout_sequence;
            if (layout.browser_texture_id != 0) {
                retained_frame.capture(allocator, &state.palette_overlay_batch, layout);
            } else {
                retained_frame.invalidate();
            }
            state.noteBrowserFramePresented();
            render_pacer.noteRendered(monotonicMs());
            state.noteWorkspaceSwitchPresented();
            recordSpan(&frame_sample, .flush_dirty, struct {
                fn run(app_state: *AppState) void {
                    // Compatibility capture advances under a per-frame byte
                    // budget; the worker owns all deep-copy/encode/I/O work.
                    // Advance only after presentation so even the bounded slice
                    // cannot delay visual feedback for the accepted input.
                    app_state.pollFlushWorker();
                    app_state.flushIfDirty();
                }
            }.run, .{&state});
            if (pending_wake_sequence) |sequence| {
                loop_wakeup.finish(sequence);
                pending_wake_sequence = null;
                render_pacer.clearWakeRender();
            }
        } else {
            state.noteWorkspaceSwitchPresentDeferred();
        }
        frame_sample.rendered = frame_presented;
        recordFrameWithStallDiagnostic(frame_sample);
        maybeLogFrameProfile(frame_profile_logging, &last_frame_profile_log_ms, &palette_renderer);
        palette_renderer.maybeWriteDevStats(monotonicNsU64());
    }
}

fn renderStartupFrame(
    renderer: *palette_frame_renderer.Renderer,
    allocator: std.mem.Allocator,
    window: *palette.platform.Window,
) !void {
    var width: c_int = 0;
    var height: c_int = 0;
    getWindowSizeInPixels(window, &width, &height);
    const frame_width: f32 = @floatFromInt(@max(width, 1));
    const frame_height: f32 = @floatFromInt(@max(height, 1));
    var batch: palette.RenderBatch = .{};
    defer batch.deinit(allocator);
    const text_color = ui_theme.COLOR_TEXT_MUTED;
    try batch.roleText(
        allocator,
        .{ .x = 40.0, .y = frame_height - 64.0, .w = frame_width - 80.0, .h = 28.0 },
        "Loading workspace…",
        .{ .r = text_color[0], .g = text_color[1], .b = text_color[2], .a = text_color[3] },
        16.0,
        .ui,
        null,
        null,
    );
    _ = try renderer.renderBatch(allocator, &batch, frame_width, frame_height);
}

// Resolves the OS mouse cursor each frame: terminal and browser-reported
// shapes win, then interactive Palette controls, otherwise the default arrow.
fn syncMouseCursor(state: *AppState, cache: *CursorState) void {
    const mouse_x = state.transcript_controller.palette_mouse_x;
    const mouse_y = state.transcript_controller.palette_mouse_y;
    if (!modalHitAtMouse(state)) {
        if (ui_layout.companionHitAt(state, mouse_x, mouse_y)) |action| {
            applySystemCursor(cache, systemCursorForCompanionAction(action));
            return;
        }
    }
    if (!modalHitAtMouse(state)) {
        if (agent_prompt_popover_ui.systemCursorAt(state.transcript_controller.palette_mouse_x, state.transcript_controller.palette_mouse_y)) |cursor| {
            applySystemCursor(cache, cursor);
            return;
        }
    }
    // Workspace pane chrome overlays chat, terminal, and native browser
    // content, so its pointer affordance must win before content cursors.
    if (!modalHitAtMouse(state)) {
        if (workspace_panes_ui.systemCursorAt(state.transcript_controller.palette_mouse_x, state.transcript_controller.palette_mouse_y)) |cursor| {
            applySystemCursor(cache, cursor);
            return;
        }
    }
    if (!modalHitAtMouse(state)) {
        if (sidebar_ui.systemCursorAt(mouse_x, mouse_y)) |cursor| {
            applySystemCursor(cache, cursor);
            return;
        }
    }
    if (!modalHitAtMouse(state)) {
        if (workspace_strip_ui.systemCursorAt(state.transcript_controller.palette_mouse_x, state.transcript_controller.palette_mouse_y)) |cursor| {
            applySystemCursor(cache, cursor);
            return;
        }
        if (side_panel_ui.systemCursorAt(state, state.transcript_controller.palette_mouse_x, state.transcript_controller.palette_mouse_y)) |cursor| {
            applySystemCursor(cache, cursor);
            return;
        }
    }
    if (!modalHitAtMouse(state) and browser_ui.wantsPointerAt(state, state.transcript_controller.palette_mouse_x, state.transcript_controller.palette_mouse_y)) {
        applySystemCursor(cache, .pointer);
        return;
    }
    // WKWebView and windowed WebView2 apply CSS cursors themselves. Calling
    // Window.setCursor while their child view is hit would overwrite that choice.
    if (!modalHitAtMouse(state) and state.nativeBrowserOwnsCursor()) {
        cache.native_browser_owned = true;
        return;
    }
    // The settings column is docked beside the sidebar; occluded terminal
    // panes must not win the cursor while it is open.
    if (!state.settings_controller.modal_visible) {
        if (terminal_panel_ui.mouseShapeAtPoint(state, state.transcript_controller.palette_mouse_x, state.transcript_controller.palette_mouse_y)) |shape| {
            applySystemCursor(cache, if (shape == .pointer) .pointer else .default);
            return;
        }
    }
    if (state.pointerCursorWanted()) {
        applySystemCursor(cache, .pointer);
        return;
    }
    if (!modalHitAtMouse(state)) {
        if (state.browserCursorShapeAtPoint(state.transcript_controller.palette_mouse_x, state.transcript_controller.palette_mouse_y)) |shape| {
            applyBrowserCursor(cache, shape);
            return;
        }
    }
    // Modal scrims (settings, command palette, importers) intercept clicks
    // before the sidebar and workspace headers in event routing, so any modal
    // hit under the mouse must also suppress their pointer affordance.
    const modal_hit = modalHitAtMouse(state);
    if (!modal_hit and
        (sidebar_ui.wantsPointerAt(state, state.transcript_controller.palette_mouse_x, state.transcript_controller.palette_mouse_y) or
            chat_panel_ui.workspaceHeaderWantsPointerAt(state, state.transcript_controller.palette_mouse_x, state.transcript_controller.palette_mouse_y) or
            chat_panel_ui.approvalActionWantsPointerAt(state.transcript_controller.palette_mouse_x, state.transcript_controller.palette_mouse_y) or
            chat_panel_ui.backgroundTaskPinWantsPointerAt(state.transcript_controller.palette_mouse_x, state.transcript_controller.palette_mouse_y) or
            chat_panel_ui.linkedChatsWantsPointerAt(state.transcript_controller.palette_mouse_x, state.transcript_controller.palette_mouse_y) or
            chat_panel_ui.transcriptActionWantsPointerAt(state.transcript_controller.palette_mouse_x, state.transcript_controller.palette_mouse_y)))
    {
        applySystemCursor(cache, .pointer);
        return;
    }
    // One transcript pass answers both the link pointer and the text I-beam.
    const transcript_cursor: chat_panel_ui.TranscriptCursor = if (modal_hit)
        .none
    else
        chat_panel_ui.transcriptCursorAt(state, state.transcript_controller.palette_mouse_x, state.transcript_controller.palette_mouse_y);
    if (transcript_cursor == .link) {
        applySystemCursor(cache, .pointer);
        return;
    }
    if (!modal_hit and state.composer_controller.composer.textRect().contains(.{
        .x = state.transcript_controller.palette_mouse_x,
        .y = state.transcript_controller.palette_mouse_y,
    })) {
        applySystemCursor(cache, .text);
        return;
    }
    if (transcript_cursor == .text) {
        applySystemCursor(cache, .text);
        return;
    }
    applySystemCursor(cache, .default);
}

fn systemCursorForCompanionAction(action: companion_controller.HitAction) palette.platform.CursorShape {
    return switch (action) {
        .open, .collapse, .mission_control_open, .mission_control_close, .run_tab, .activity_tab, .approve, .deny, .operation_select, .operation_stop, .operation_follow_log => .pointer,
        .panel, .body => .default,
    };
}

fn routeCompanionWheel(state: *AppState, x: f32, y: f32, wheel_y: f32) bool {
    return ui_layout.handleCompanionWheel(state, x, y, wheel_y);
}

fn applyBrowserCursor(cache: *CursorState, shape: browser_runtime.CursorShape) void {
    applySystemCursor(cache, systemCursorForBrowserShape(shape));
}

fn applySystemCursor(cache: *CursorState, kind: palette.platform.CursorShape) void {
    // A native browser view may have changed the pointer behind Verde's back,
    // so the first shape after it releases the pointer is always re-sent.
    if (cache.native_browser_owned) host.invalidateCursor();
    cache.native_browser_owned = false;
    host.setCursor(kind);
}

// Browser cursors are CSS names, as are the platform's shapes (the Wayland
// cursor-shape protocol, AppKit and Win32 map the rest to their closest
// cursor). Only `custom` (an image cursor Verde cannot show) falls back.
fn systemCursorForBrowserShape(shape: browser_runtime.CursorShape) palette.platform.CursorShape {
    return switch (shape) {
        .custom => .default,
        inline else => |tag| @field(palette.platform.CursorShape, @tagName(tag)),
    };
}

test "production Companion wheel routing preserves direct ownership" {
    const allocator = std.testing.allocator;
    var state: AppState = undefined;
    state.allocator = allocator;
    state.app_config = .{ .companion_enabled = true };
    state.companion_controller = companion_controller.init();
    state.companion_controller.show();
    state.companion_composer = native_state.CompanionComposerPrompt.init();
    state.companion_composer.setBounds(.{ .x = 200.0, .y = 200.0, .w = 100.0, .h = 100.0 });
    state.lifecycle = .{};
    defer state.companion_composer.deinit(allocator);
    var frame: companion_controller.Frame = .{};
    frame.activity_count = 10;
    state.companion_controller.setFrame(frame);
    state.companion_controller.selectTab(.activity);
    state.companion_controller.addHit(.{ .x = 0.0, .y = 0.0, .w = 100.0, .h = 100.0 }, .panel);
    state.companion_controller.addHit(.{ .x = 0.0, .y = 0.0, .w = 100.0, .h = 100.0 }, .body);

    try std.testing.expect(routeCompanionWheel(&state, 50.0, 50.0, -1.0));
    try std.testing.expectEqual(@as(f32, 32.0), state.companion_controller.activity_scroll_y);
    try std.testing.expectEqual(@as(f32, 574.0), state.companion_controller.activity_max_scroll);
    try std.testing.expect(!state.companion_controller.activity_follow_tail);
    const unchanged_offset = state.companion_controller.activity_scroll_y;
    try std.testing.expect(!routeCompanionWheel(&state, 150.0, 150.0, -1.0));
    try std.testing.expectEqual(unchanged_offset, state.companion_controller.activity_scroll_y);
}

// True when any retained modal hit rect (scrim or control) covers the current
// mouse position; mirrors ui_layout.handlePaletteMouseButton's precedence.
fn modalHitAtMouse(state: *const AppState) bool {
    const point: palette.draw.Vec2 = .{ .x = state.transcript_controller.palette_mouse_x, .y = state.transcript_controller.palette_mouse_y };
    for (state.palette_modal_hits.items) |hit| {
        if (hit.rect.contains(point)) return true;
    }
    return false;
}

fn ghosttyMonoFontPath(allocator: std.mem.Allocator) !?[:0]u8 {
    const family = try ghosttyFontFamily(allocator) orelse return null;
    defer allocator.free(family);
    return try fontPathForFamily(allocator, family);
}

fn systemMathFontPath(allocator: std.mem.Allocator) !?[:0]u8 {
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const candidates = [_][]const u8{
        "/usr/share/fonts/noto/NotoSansMath-Regular.ttf",
        "/usr/share/fonts/truetype/noto/NotoSansMath-Regular.ttf",
        "/usr/share/fonts/Adwaita/AdwaitaMono-Regular.ttf",
        "/System/Library/Fonts/Supplemental/STIXTwoMath.otf",
        "/System/Library/Fonts/Supplemental/Cambria Math.ttf",
        "C:\\Windows\\Fonts\\cambria.ttc",
    };
    for (candidates) |candidate| {
        std.Io.Dir.cwd().access(io, candidate, .{}) catch continue;
        return try allocator.dupeZ(u8, candidate);
    }

    const home = std.c.getenv("HOME") orelse return null;
    const local_path = try std.fs.path.join(allocator, &.{ std.mem.span(home), ".local/share/fonts/NotoSansMath-Regular.ttf" });
    defer allocator.free(local_path);
    std.Io.Dir.cwd().access(io, local_path, .{}) catch return null;
    return try allocator.dupeZ(u8, local_path);
}

fn ghosttyFontFamily(allocator: std.mem.Allocator) !?[]u8 {
    const home = std.c.getenv("HOME") orelse return null;
    const config_path = try std.fs.path.join(allocator, &.{ std.mem.span(home), ".config", "ghostty", "config" });
    defer allocator.free(config_path);

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const content = std.Io.Dir.cwd().readFileAlloc(threaded.io(), config_path, allocator, .limited(128 * 1024)) catch return null;
    defer allocator.free(content);

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        const no_comment = if (std.mem.indexOfScalar(u8, raw_line, '#')) |index| raw_line[0..index] else raw_line;
        const line = std.mem.trim(u8, no_comment, " \t\r");
        if (line.len == 0) continue;
        const equals = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..equals], " \t\r");
        if (!std.mem.eql(u8, key, "font-family")) continue;
        return try allocator.dupe(u8, unquoteGhosttyValue(line[equals + 1 ..]));
    }
    return null;
}

fn fontPathForFamily(allocator: std.mem.Allocator, family: []const u8) !?[:0]u8 {
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var compact = std.ArrayList(u8).empty;
    defer compact.deinit(allocator);
    for (family) |byte| {
        if (byte == ' ' or byte == '\t' or byte == '-' or byte == '_') continue;
        try compact.append(allocator, byte);
    }

    const compact_name = compact.items;
    const candidates = [_][]const u8{
        "/usr/share/fonts/TTF",
        "/usr/local/share/fonts",
    };
    for (candidates) |dir| {
        const path = try allocFontCandidatePath(allocator, dir, compact_name);
        std.Io.Dir.cwd().access(io, path, .{}) catch {
            allocator.free(path);
            continue;
        };
        return path;
    }

    const home = std.c.getenv("HOME") orelse return null;
    const home_slice = std.mem.span(home);
    const local_candidates = [_][]const u8{
        ".local/share/fonts",
        ".fonts",
    };
    for (local_candidates) |dir| {
        const parent = try std.fs.path.join(allocator, &.{ home_slice, dir });
        defer allocator.free(parent);
        const path = try allocFontCandidatePath(allocator, parent, compact_name);
        std.Io.Dir.cwd().access(io, path, .{}) catch {
            allocator.free(path);
            continue;
        };
        return path;
    }
    return null;
}

fn allocFontCandidatePath(allocator: std.mem.Allocator, dir: []const u8, compact_name: []const u8) ![:0]u8 {
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}-Regular.ttf", .{ dir, compact_name });
    defer allocator.free(path);
    return try allocator.dupeZ(u8, path);
}

fn unquoteGhosttyValue(raw_value: []const u8) []const u8 {
    var value = std.mem.trim(u8, raw_value, " \t\r");
    if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') value = value[1 .. value.len - 1];
    if (value.len >= 2 and value[0] == '\'' and value[value.len - 1] == '\'') value = value[1 .. value.len - 1];
    return value;
}

const EventFlags = struct {
    has_mouse_motion: bool = false,
    /// A wheel event the visible browser page consumed.
    has_browser_wheel: bool = false,
    has_non_mouse_motion: bool = false,
    /// The window renderer needs a new frame (resize, scale change, re-show).
    renderer_redraw: bool = false,
    loop_wakeup_sequence: ?u64 = null,
};

const LoopSleepReason = enum {
    none,
    event_already_queued,
    wait_event,
    wait_timeout,
};

const LoopWaitTrace = struct {
    reason: LoopSleepReason = .none,
    requested_timeout_ms: c_int = 0,
    waited_ns: u64 = 0,
    pending_frame_on_entry: bool = false,
};

fn frameProfileLoggingEnabled() bool {
    return std.c.getenv("VERDE_FRAME_PROFILE_LOG") != null;
}

fn monotonicNsU64() u64 {
    return @intCast(@max(profiler.nowNs(), 0));
}

fn monotonicMs() i64 {
    return @intCast(@divTrunc(profiler.nowNs(), std.time.ns_per_ms));
}

fn maybeLogFrameProfile(enabled: bool, last_log_ms: *i64, palette_renderer: *const palette_frame_renderer.Renderer) void {
    if (!enabled) return;
    const now_ms: i64 = @intCast(@divTrunc(profiler.nowNs(), std.time.ns_per_ms));
    if (last_log_ms.* != 0 and now_ms - last_log_ms.* < 1000) return;
    last_log_ms.* = now_ms;

    const snapshot = profiler.snapshot();
    if (snapshot.count == 0) return;
    const sections = recentSectionStats();
    runtime_log.trace(
        "frame-profile backend={s} samples={d} avg_ms={d:.2} max_ms={d:.2} slow={d} hitch={d} latest_ms={d:.2} rendered={d} render_root_avg_ms={d:.2} draw_backend_avg_ms={d:.2} poll_send_avg_ms={d:.2} poll_terminals_avg_ms={d:.2} poll_config_avg_ms={d:.2}",
        .{
            palette_frame_renderer.backend_name,
            snapshot.count,
            profiler.nsToMs(snapshot.avg_active_ns),
            profiler.nsToMs(snapshot.max_active_ns),
            snapshot.slow_count,
            snapshot.hitch_count,
            profiler.nsToMs(snapshot.latest.active_ns),
            sections.rendered_count,
            profiler.nsToMs(sections.render_root_avg_ns),
            profiler.nsToMs(sections.draw_backend_avg_ns),
            profiler.nsToMs(sections.poll_send_avg_ns),
            profiler.nsToMs(sections.poll_terminals_avg_ns),
            profiler.nsToMs(sections.poll_config_avg_ns),
        },
    );
    const stats = palette_renderer.lastFrameStats();
    if (!stats.skipped and stats.commands > 0) logGpuFrameStats(stats, palette_renderer.windowStats(), palette_renderer.gpuMemory());
}

const SectionStats = struct {
    rendered_count: usize = 0,
    render_root_avg_ns: u64 = 0,
    draw_backend_avg_ns: u64 = 0,
    poll_send_avg_ns: u64 = 0,
    poll_terminals_avg_ns: u64 = 0,
    poll_config_avg_ns: u64 = 0,
};

fn recentSectionStats() SectionStats {
    const count = profiler.frameCount();
    if (count == 0) return .{};

    var sampled_count: usize = 0;
    var rendered_count: usize = 0;
    var render_root_sum: u128 = 0;
    var draw_backend_sum: u128 = 0;
    var poll_send_sum: u128 = 0;
    var poll_terminals_sum: u128 = 0;
    var poll_config_sum: u128 = 0;

    var index: usize = 0;
    while (index < count) : (index += 1) {
        const frame = profiler.frameAt(index) orelse continue;
        sampled_count += 1;
        poll_send_sum += frame.sectionNs(.poll_send);
        poll_terminals_sum += frame.sectionNs(.poll_terminals);
        poll_config_sum += frame.sectionNs(.poll_config);
        if (!frame.rendered) continue;
        rendered_count += 1;
        render_root_sum += frame.sectionNs(.render_root);
        draw_backend_sum += frame.sectionNs(.draw_backend);
    }
    if (sampled_count == 0) return .{};
    return .{
        .rendered_count = rendered_count,
        .render_root_avg_ns = if (rendered_count > 0) @intCast(render_root_sum / rendered_count) else 0,
        .draw_backend_avg_ns = if (rendered_count > 0) @intCast(draw_backend_sum / rendered_count) else 0,
        .poll_send_avg_ns = @intCast(poll_send_sum / sampled_count),
        .poll_terminals_avg_ns = @intCast(poll_terminals_sum / sampled_count),
        .poll_config_avg_ns = @intCast(poll_config_sum / sampled_count),
    };
}

fn logGpuFrameStats(stats: palette.gpu.FrameStats, window_stats: palette.WindowRenderer.Stats, memory: palette_frame_renderer.GpuMemory) void {
    runtime_log.trace(
        "gpu-stage build_ms={d:.2} upload_ms={d:.2} encode_ms={d:.2} submit_ms={d:.2} wait_ms={d:.2} total_ms={d:.2} commands={d} instances={d} draws={d} glyphs_rasterized={d} glyph_uploads={d} texture_uploads={d}/{d} damage_rects={d} damaged_px={d} full_redraw={} presented={d} unchanged={d} throttled={d} no_buffer={d} frame_timeouts={d} gpu_device_bytes={d} gpu_host_bytes={d} window_buffer_bytes={d}",
        .{
            profiler.nsToMs(stats.build_ns),
            profiler.nsToMs(stats.upload_ns),
            profiler.nsToMs(stats.encode_ns),
            profiler.nsToMs(stats.submit_ns),
            profiler.nsToMs(stats.wait_ns),
            profiler.nsToMs(stats.total_ns),
            stats.commands,
            stats.instances,
            stats.draws,
            stats.glyphs_rasterized,
            stats.glyph_uploads,
            stats.texture_uploads,
            stats.texture_upload_bytes,
            stats.damage_rects,
            stats.damaged_pixels,
            stats.full_redraw,
            window_stats.presented,
            window_stats.unchanged,
            window_stats.throttled,
            window_stats.no_buffer,
            window_stats.frame_timeouts,
            memory.device_local_bytes,
            memory.host_visible_bytes,
            memory.window_buffer_bytes,
        },
    );
}

fn logWorkspaceSwitchGpuFrameStats(trace: native_state.WorkspaceSwitchTrace, stats: palette.gpu.FrameStats) void {
    runtime_log.trace(
        "workspace-switch-trace seq={d} stage=gpu_stages target_index={d} attempt={d} build_ms={d:.2} upload_ms={d:.2} encode_ms={d:.2} submit_ms={d:.2} wait_ms={d:.2} total_ms={d:.2} commands={d} draws={d} texture_uploads={d}/{d} skipped={}",
        .{
            trace.sequence,
            trace.target_index,
            trace.render_attempt,
            profiler.nsToMs(stats.build_ns),
            profiler.nsToMs(stats.upload_ns),
            profiler.nsToMs(stats.encode_ns),
            profiler.nsToMs(stats.submit_ns),
            profiler.nsToMs(stats.wait_ns),
            profiler.nsToMs(stats.total_ns),
            stats.commands,
            stats.draws,
            stats.texture_uploads,
            stats.texture_upload_bytes,
            stats.skipped,
        },
    );
}

fn logSlowGpuFrameStages(stats: palette.gpu.FrameStats) void {
    const Stage = struct { name: []const u8, elapsed_ns: u64 };
    const stages = [_]Stage{
        .{ .name = "batch build", .elapsed_ns = stats.build_ns },
        .{ .name = "texture upload", .elapsed_ns = stats.upload_ns },
        .{ .name = "render encode", .elapsed_ns = stats.encode_ns },
        .{ .name = "submit present", .elapsed_ns = stats.submit_ns },
        .{ .name = "frame slot wait", .elapsed_ns = stats.wait_ns },
    };
    for (stages) |stage| {
        if (stage.elapsed_ns <= UI_THREAD_STALL_LOG_THRESHOLD_NS) continue;
        runtime_log.diagnostic(
            "SDL thread stall operation=gpu {s} elapsed_ms={d:.2}",
            .{ stage.name, profiler.nsToMs(stage.elapsed_ns) },
        );
    }
}

fn recordSpan(frame_sample: *profiler.FrameSample, section: profiler.Section, comptime function: anytype, args: anytype) void {
    const start = profiler.nowNs();
    @call(.auto, function, args);
    const elapsed_ns = profiler.elapsedNs(start);
    frame_sample.add(section, elapsed_ns);
    if (elapsed_ns > UI_THREAD_STALL_LOG_THRESHOLD_NS) {
        runtime_log.diagnostic(
            "SDL thread stall operation={s} elapsed_ms={d:.2}",
            .{ profiler.sectionName(section), profiler.nsToMs(elapsed_ns) },
        );
    }
}

fn recordFrameWithStallDiagnostic(frame_sample: profiler.FrameSample) void {
    if (frame_sample.active_ns > UI_THREAD_STALL_LOG_THRESHOLD_NS) {
        var slowest: profiler.Section = .event_handling;
        var slowest_ns = frame_sample.sectionNs(slowest);
        inline for (@typeInfo(profiler.Section).@"enum".fields) |field| {
            const section: profiler.Section = @enumFromInt(field.value);
            const section_ns = frame_sample.sectionNs(section);
            if (section_ns > slowest_ns) {
                slowest = section;
                slowest_ns = section_ns;
            }
        }
        runtime_log.diagnostic(
            "SDL thread stall operation=frame slowest={s} elapsed_ms={d:.2} active_ms={d:.2}",
            .{ profiler.sectionName(slowest), profiler.nsToMs(slowest_ns), profiler.nsToMs(frame_sample.active_ns) },
        );
    }
    profiler.recordFrame(frame_sample);
}

fn initialWindowFrame(app: *const palette.platform.App) WindowFrame {
    return initialWindowFrameFor(app.usableRect());
}

fn scaleWindowCoordinate(value: c_int, scale: f32) c_int {
    if (!std.math.isFinite(scale) or scale <= 0.0) return value;
    return @intFromFloat(@round(@as(f32, @floatFromInt(value)) * scale));
}

/// Centres the default window in `usable` (logical units). Small work areas
/// (1366x768 or 1280x800 at 125%) are below the preferred minimum, so the
/// work-area bound wins there and the title bar stays on screen.
fn initialWindowFrameFor(usable: ?palette.platform.Rect) WindowFrame {
    // Wayland reports no global coordinates (origin 0,0) and positions are a
    // no-op there; macOS and Windows centre the window in the work area.
    const usable_bounds = usable orelse return .{
        .x = 0,
        .y = 0,
        .w = DEFAULT_WINDOW_WIDTH,
        .h = DEFAULT_WINDOW_HEIGHT,
    };
    const usable_x: c_int = @intFromFloat(usable_bounds.x);
    const usable_y: c_int = @intFromFloat(usable_bounds.y);
    const usable_w: c_int = @intFromFloat(usable_bounds.w);
    const usable_h: c_int = @intFromFloat(usable_bounds.h);
    const max_width = @max(1, @min(MAX_WINDOW_WIDTH, usable_w - 40));
    const max_height = @max(1, @min(MAX_WINDOW_HEIGHT, usable_h - 40));
    const width = @min(@max(@as(c_int, @intFromFloat(@as(f32, @floatFromInt(usable_w)) * 0.72)), MIN_WINDOW_WIDTH), max_width);
    const height = @min(@max(@as(c_int, @intFromFloat(@as(f32, @floatFromInt(usable_h)) * 0.74)), MIN_WINDOW_HEIGHT), max_height);
    const x = usable_x + @divTrunc(usable_w - width, 2);
    const y = usable_y + @divTrunc(usable_h - height, 2);
    return .{ .x = x, .y = y, .w = width, .h = height };
}

fn getWindowSizeInPixels(window: *const palette.platform.Window, w: ?*c_int, h: ?*c_int) void {
    const size = window.pixelSize();
    if (w) |width| width.* = if (size.width > 0) @intCast(size.width) else DEFAULT_WINDOW_WIDTH;
    if (h) |height| height.* = if (size.height > 0) @intCast(size.height) else DEFAULT_WINDOW_HEIGHT;
}

fn currentWindowDisplayScale(window: *const palette.platform.Window) f32 {
    const scale = window.scale();
    if (!std.math.isFinite(scale) or scale <= 0.0) return 1.0;
    return clampf(scale, 1.0, 2.5);
}

/// The native parent the platform browser view attaches to: the NSWindow for
/// WKWebView, the HWND for WebView2. Linux renders WPE frames offscreen into
/// palette textures and needs no host window.
fn nativeBrowserHostWindow(window: *const palette.platform.Window) ?*anyopaque {
    const handles = window.nativeHandles();
    return switch (builtin.os.tag) {
        .macos => handles.ns_window,
        .windows => handles.hwnd,
        else => null,
    };
}

fn clampf(value: f32, min_value: f32, max_value: f32) f32 {
    return @max(min_value, @min(value, max_value));
}

// Platform pointer coordinates are logical; the Palette root lays out in
// framebuffer pixels, so scale pointer events into that space.
fn normalizeMouseEventCoordinates(window: *const palette.platform.Window, event: *palette.Event) void {
    const logical = window.logicalSize();
    const pixel = window.pixelSize();
    if (logical.width == 0 or logical.height == 0 or pixel.width == 0 or pixel.height == 0) return;

    const scale_x = @as(f32, @floatFromInt(pixel.width)) / @as(f32, @floatFromInt(logical.width));
    const scale_y = @as(f32, @floatFromInt(pixel.height)) / @as(f32, @floatFromInt(logical.height));
    if (@abs(scale_x - 1.0) < 0.01 and @abs(scale_y - 1.0) < 0.01) return;

    switch (event.*) {
        .mouse_motion, .mouse_enter => |*motion| {
            motion.x *= scale_x;
            motion.y *= scale_y;
            motion.xrel *= scale_x;
            motion.yrel *= scale_y;
        },
        .mouse_button_down, .mouse_button_up => |*button| {
            button.x *= scale_x;
            button.y *= scale_y;
        },
        .mouse_wheel => |*wheel| {
            wheel.mouse_x *= scale_x;
            wheel.mouse_y *= scale_y;
        },
        else => {},
    }
}

fn processEvents(
    app: *palette.platform.App,
    window: *palette.platform.Window,
    renderer: *palette_frame_renderer.Renderer,
    state: *AppState,
    keyboard: *keybinds.NativeKeyboardConfig,
    ui_scale: f32,
    event_flags: *EventFlags,
    frame_sample: *profiler.FrameSample,
    wait_trace: *LoopWaitTrace,
    render_pacer: *const loop_pacing.FramePacer,
    presentation_demand: *const loop_pacing.PresentationDemand,
) bool {
    event_flags.* = .{};
    var event: palette.Event = undefined;

    if (!app.pollEvent(&event)) {
        const wait_timeout_ms = eventWaitTimeoutMs(state, renderer, render_pacer, presentation_demand);
        wait_trace.requested_timeout_ms = wait_timeout_ms;
        const wait_timeout_ns = renderer.boundWaitNs(
            @as(u64, @intCast(@max(wait_timeout_ms, 0))) * std.time.ns_per_ms,
            presentation_demand.pending,
        );
        const wait_start = profiler.nowNs();
        if (!app.waitEvent(&event, wait_timeout_ns)) {
            wait_trace.waited_ns +|= profiler.elapsedNs(wait_start);
            wait_trace.reason = .wait_timeout;
            // An idle window may get no events at all (macOS has no frame
            // callbacks), so the dev hooks must also run on the timeout path.
            return pollDevHooks(window, renderer, state, keyboard, ui_scale, event_flags, frame_sample);
        }
        wait_trace.waited_ns +|= profiler.elapsedNs(wait_start);
        wait_trace.reason = .wait_event;
        if (!dispatchEvent(window, renderer, state, keyboard, ui_scale, &event, event_flags, frame_sample)) return false;
    } else {
        wait_trace.reason = .event_already_queued;
        if (!dispatchEvent(window, renderer, state, keyboard, ui_scale, &event, event_flags, frame_sample)) return false;
    }

    while (app.pollEvent(&event)) {
        if (!dispatchEvent(window, renderer, state, keyboard, ui_scale, &event, event_flags, frame_sample)) return false;
    }

    return pollDevHooks(window, renderer, state, keyboard, ui_scale, event_flags, frame_sample);
}

/// VERDE_PALETTE_SNAPSHOT / VERDE_PALETTE_INJECT requests. Returns false when an
/// injected script quits the app.
fn pollDevHooks(
    window: *palette.platform.Window,
    renderer: *palette_frame_renderer.Renderer,
    state: *AppState,
    keyboard: *keybinds.NativeKeyboardConfig,
    ui_scale: f32,
    event_flags: *EventFlags,
    frame_sample: *profiler.FrameSample,
) bool {
    if (palette_frame_renderer.snapshotRequested()) event_flags.renderer_redraw = true;
    if (dev_inject.enabled()) {
        if (dev_inject.take(state.allocator)) |script| {
            defer state.allocator.free(script);
            var injector: Injector = .{ .window = window, .renderer = renderer, .state = state, .keyboard = keyboard, .ui_scale = ui_scale, .event_flags = event_flags, .frame_sample = frame_sample };
            const logical = window.logicalSize();
            const pixel = window.pixelSize();
            const scale: f32 = if (logical.width == 0) 1 else @as(f32, @floatFromInt(pixel.width)) / @as(f32, @floatFromInt(logical.width));
            if (!dev_inject.run(script, .{ .context = &injector, .dispatch = Injector.dispatch, .window = window.id, .scale = scale, .cursor = @tagName(host.currentCursor()) })) return false;
        }
    }
    return true;
}

/// Feeds `VERDE_PALETTE_INJECT` events through the same path as platform events.
const Injector = struct {
    window: *palette.platform.Window,
    renderer: *palette_frame_renderer.Renderer,
    state: *AppState,
    keyboard: *keybinds.NativeKeyboardConfig,
    ui_scale: f32,
    event_flags: *EventFlags,
    frame_sample: *profiler.FrameSample,

    fn dispatch(context: *anyopaque, event: *palette.Event) bool {
        const self: *Injector = @ptrCast(@alignCast(context));
        return dispatchEvent(self.window, self.renderer, self.state, self.keyboard, self.ui_scale, event, self.event_flags, self.frame_sample);
    }
};

fn dispatchEvent(
    window: *palette.platform.Window,
    renderer: *palette_frame_renderer.Renderer,
    state: *AppState,
    keyboard: *keybinds.NativeKeyboardConfig,
    ui_scale: f32,
    event: *palette.Event,
    event_flags: *EventFlags,
    frame_sample: *profiler.FrameSample,
) bool {
    // The window renderer sees every event first (resize, frame pacing,
    // re-show); held-key tracking likewise.
    const renderer_needs_redraw = renderer.handleEvent(event.*);
    host.noteEvent(event.*);
    if (renderer_needs_redraw) event_flags.renderer_redraw = true;
    browser_wheel_forwarded = false;
    const keep_running = processOneEvent(window, state, keyboard, ui_scale, event, frame_sample);
    noteEventForRender(event, event_flags);
    return keep_running;
}

/// Set while dispatching a wheel event that the browser page consumed.
var browser_wheel_forwarded = false;

/// Layout inputs a retained frame must match to be replayed.
fn retainedFrameLayout(
    state: *AppState,
    framebuffer_width: c_int,
    framebuffer_height: c_int,
    scale: f32,
    now_ms: i64,
) palette_frame_renderer.RetainedFrame.Layout {
    var texture_id: u32 = 0;
    if (state.browser_textures_enabled and state.isBrowserVisible()) {
        if (state.browserState().controller.paneTexture()) |pane_texture| {
            if (pane_texture.isReady()) texture_id = @intCast(pane_texture.texture_id);
        }
    }
    return .{
        .framebuffer_width = framebuffer_width,
        .framebuffer_height = framebuffer_height,
        .ui_scale = scale,
        .browser_texture_id = texture_id,
        .mouse_x = state.transcript_controller.palette_mouse_x,
        .mouse_y = state.transcript_controller.palette_mouse_y,
        .now_ms = now_ms,
        .layout_sequence = loop_wakeup.layoutSequence(),
    };
}

fn noteEventForRender(event: *const palette.Event, flags: *EventFlags) void {
    switch (event.*) {
        .user => |value| {
            if (loop_wakeup.consume(value)) |sequence| flags.loop_wakeup_sequence = sequence;
            return;
        },
        // Frame callbacks only lift the presentation throttle: the pending
        // presentation demand retries on its own, so they are not input.
        .frame => return,
        .mouse_motion => |motion| if (noMouseButtonsPressed(motion.state)) {
            flags.has_mouse_motion = true;
            return;
        },
        .mouse_wheel => if (browser_wheel_forwarded) {
            flags.has_browser_wheel = true;
            return;
        },
        else => {},
    }
    flags.has_non_mouse_motion = true;
}

fn noMouseButtonsPressed(state: palette.event.ButtonState) bool {
    return !state.left and !state.middle and !state.right and !state.back and !state.forward;
}

fn shouldRenderMouseMotion(has_mouse_motion: bool, continuous_frames: bool, last_render_ms: *i64) bool {
    if (!has_mouse_motion or continuous_frames) return false;
    const now_ms: i64 = @intCast(@divTrunc(profiler.nowNs(), std.time.ns_per_ms));
    if (last_render_ms.* != 0 and now_ms - last_render_ms.* < MOUSE_MOTION_RENDER_INTERVAL_MS) return false;
    last_render_ms.* = now_ms;
    return true;
}

fn processOneEvent(
    window: *palette.platform.Window,
    state: *AppState,
    keyboard: *keybinds.NativeKeyboardConfig,
    ui_scale: f32,
    event: *palette.Event,
    frame_sample: *profiler.FrameSample,
) bool {
    // Cross-thread wakes carry no payload beyond their sequence, which
    // noteEventForRender already captured for display-rate coalescing.
    switch (event.*) {
        .user, .frame => return true,
        else => {},
    }
    const start = profiler.nowNs();
    normalizeMouseEventCoordinates(window, event);
    switch (event.*) {
        .mouse_motion, .mouse_button_down, .mouse_button_up, .mouse_wheel => {
            var input_fb_w: c_int = 0;
            var input_fb_h: c_int = 0;
            getWindowSizeInPixels(window, &input_fb_w, &input_fb_h);
            ui_layout.refreshPaletteModalHits(state, @floatFromInt(input_fb_w), @floatFromInt(input_fb_h));
        },
        else => {},
    }
    const keep_running = handleEvent(window, state, keyboard, ui_scale, event);
    if (!keep_running) {
        runtime_log.diagnostic("event requested shutdown type={s}", .{@tagName(event.*)});
    }
    frame_sample.add(.event_handling, profiler.elapsedNs(start));
    return keep_running;
}

const HotkeyPaneKind = enum { chat, terminal };

// Opens a new pane via hotkey. For the first four panes it routes through the
// 2x2 grid placement (gridNewPanePlacement); once the grid is full (or the
// workspace is maximized) it falls back to splitting the focused pane along the
// requested axis.
fn prefixSplitPaneKind(state: *const AppState, alternate: bool) HotkeyPaneKind {
    const default_kind: HotkeyPaneKind = switch (state.app_config.workspace_split_default_pane) {
        .chat => .chat,
        .terminal => .terminal,
    };
    if (!alternate) return default_kind;
    return switch (default_kind) {
        .chat => .terminal,
        .terminal => .chat,
    };
}

fn openHotkeyWorkspacePane(state: *AppState, kind: HotkeyPaneKind, fallback_axis: native_state.WorkspaceSplitAxis) bool {
    if (state.project_controller.projects.items.len == 0) return false;
    const project_index = state.project_controller.selected_index;
    if (state.project_controller.projects.items[project_index].workspace_layout.focused_pane_id == null) {
        return switch (kind) {
            .chat => blk: {
                state.createThreadForProject(project_index);
                break :blk true;
            },
            .terminal => state.openTerminalPaneForProjectIndex(project_index),
        };
    }
    if (workspace_panes_ui.gridNewPanePlacement(state)) |p| {
        return switch (kind) {
            .chat => state.splitCurrentProjectWorkspacePaneWithChatPlacement(p.pane_id, p.axis, p.new_after),
            .terminal => state.splitCurrentProjectWorkspacePaneWithTerminalPlacement(p.pane_id, p.axis, p.new_after),
        };
    }
    return switch (kind) {
        .chat => state.splitFocusedWorkspacePaneWithChatAxis(fallback_axis),
        .terminal => state.splitFocusedWorkspacePaneWithTerminalAxis(fallback_axis),
    };
}

// Prefix-created pane tile inside the focused scrolling item.
fn openPrefixTiledWorkspacePane(state: *AppState, kind: HotkeyPaneKind, axis: native_state.WorkspaceSplitAxis) bool {
    if (state.project_controller.projects.items.len == 0) return false;
    const project_index = state.project_controller.selected_index;
    const layout = &state.project_controller.projects.items[project_index].workspace_layout;
    const target_pane_id = layout.focused_pane_id orelse return openHotkeyWorkspacePane(state, kind, axis);
    return switch (kind) {
        .chat => state.splitCurrentProjectWorkspacePaneTiledWithChatPlacement(target_pane_id, axis, true),
        .terminal => state.splitCurrentProjectWorkspacePaneTiledWithTerminalPlacement(target_pane_id, axis, true),
    };
}

// The new-thread policy and pane placement are shared with the sidebar pencil
// action so both entry points honor the same setting.
fn openHotkeyWorkspaceChatThread(state: *AppState) bool {
    state.createThreadForProject(state.project_controller.selected_index);
    return true;
}

fn activeContinuousFrames(state: *AppState) bool {
    return state.isPickerPending() or
        state.lifecycle.persistenceNeedsFrames(platform_runtime.unixTimestampMs()) or
        currentTranscriptLayoutNeedsFrames(state) or
        state.transcriptTransitionNeedsContinuousFrames(platform_runtime.unixTimestampMs()) or
        state.transcriptMarkdownSelectionDragging() or
        workspace_panes_ui.isFocusAnimating() or
        workspace_panes_ui.isScrollAnimating() or
        // Tiled/zoomed pane rects ease for ~180ms after a layout change.
        workspace_panes_ui.isPaneMotionAnimating() or
        // Streamed reply text reveals a few characters per frame; the
        // tail-follow scroll eases behind it. Both are false when idle.
        state.streamRevealAnimating() or
        chat_panel_ui.isTailFollowAnimating() or
        ui_layout.isSidebarAnimating() or
        // Run-config stepper thumbs slide for ~160ms after a selection.
        state.runConfigStepperAnimating() or
        // Settings modal fades in/out for ~160ms.
        state.settingsModalAnimating() or
        // Notice toast slides in / fades out (~400ms total per notice).
        state.noticeToastAnimating();
}

fn currentTranscriptLayoutNeedsFrames(state: *const AppState) bool {
    if (state.project_controller.projects.items.len == 0) return false;
    // A strip-scoped zoom leaves other tabs visible, so only a full-workspace
    // zoom can hide every chat pane.
    if (state.currentProjectWorkspaceFullZoomPaneId()) |pane_id| {
        if (state.workspacePaneKindById(pane_id) != .chat) return false;
    } else if (!state.currentProject().workspace_layout.hasVisiblePaneKind(.chat)) {
        return false;
    }
    const thread = state.currentThread();
    return thread.messages.items.len > 0 and
        !thread.transcript_layout_valid and
        thread.transcript_layout_message_count > 0 and
        thread.transcript_layout_committed_height < thread.transcript_layout_requested_height;
}

fn continuousFrameIntervalMs(state: *AppState) i64 {
    return continuousFrameIntervalForActivity(pacingActivity(state));
}

// Sampled per-loop activity flags feeding tier selection. A plain struct so
// the pacing matrix is unit-testable without constructing an AppState.
const PacingActivity = struct {
    active_continuous: bool = false,
    sidebar_pulse: bool = false,
    pane_status_animating: bool = false,
    browser_visible: bool = false,
    terminal_burst: bool = false,
    pending_send: bool = false,
    pending_slash_command: bool = false,
    background_tasks: bool = false,
};

fn pacingActivity(state: *AppState) PacingActivity {
    return .{
        .active_continuous = activeContinuousFrames(state),
        .sidebar_pulse = state.sidebar_pulse_animating,
        .pane_status_animating = workspace_panes_ui.isPaneStatusAnimating(),
        .browser_visible = state.isBrowserVisible(),
        .terminal_burst = state.terminalActivityBurstActive(),
        .pending_send = state.pendingSendCount() > 0,
        .pending_slash_command = state.hasPendingSlashCommand(),
        .background_tasks = state.hasRunningBackgroundTasks(),
    };
}

fn continuousFrameIntervalForActivity(activity: PacingActivity) i64 {
    if (activity.active_continuous) return ACTIVE_WAIT_TIMEOUT_MS;
    // These long-lived indicators retain their existing smooth ~30fps tier.
    // Pane status borders are pure clock math (workspace_panes.zig) and look
    // identical at ~30fps, so they must not escalate to the 16ms tier — that
    // inversion forced ~60fps full-root rebuilds for the life of a working
    // pane. Pending sends without visible activity are intentionally absent:
    // work that is only on a background workspace steps its pip at the ~1Hz
    // pollSend repaint, while eventWaitBaseTimeoutMs keeps the 33ms wake for
    // daemon-turn polling and streamed deltas.
    if (activity.sidebar_pulse or activity.pane_status_animating or activity.pending_slash_command) {
        return PIP_PULSE_WAIT_TIMEOUT_MS;
    }
    return 0;
}

fn eventWaitTimeoutMs(
    state: *AppState,
    renderer: *palette_frame_renderer.Renderer,
    render_pacer: *const loop_pacing.FramePacer,
    presentation_demand: *const loop_pacing.PresentationDemand,
) c_int {
    const base_timeout_ms = eventWaitBaseTimeoutMs(state);
    // While the present loop is throttled (awaiting the frame callback, or a
    // free buffer) a due frame cannot be shown yet, and the pacer only counts
    // presented frames, so its deadlines would read "now" until then. Wait for
    // the `.frame` event, bounded by the throttle deadline (`boundWaitNs`).
    if (!renderer.ready()) return base_timeout_ms;
    const paced_timeout_ms = render_pacer.nextWaitTimeoutMs(monotonicMs(), base_timeout_ms, ACTIVE_WAIT_TIMEOUT_MS);
    return presentation_demand.nextWaitTimeoutMs(paced_timeout_ms, ACTIVE_WAIT_TIMEOUT_MS);
}

fn eventWaitBaseTimeoutMs(state: *AppState) c_int {
    const base = eventWaitBaseTimeoutForActivity(pacingActivity(state));
    // A held notice toast needs exactly one wake at its fade start; cap the
    // idle wait on that instead of pumping frames through the hold.
    if (state.noticeToastWakeMs()) |wake_ms| {
        return @intCast(@min(@as(i64, base), @max(wake_ms, 1)));
    }
    return base;
}

fn eventWaitBaseTimeoutForActivity(activity: PacingActivity) c_int {
    // A browser pane in the *current* workspace keeps the display-rate wake so
    // frame latency does not regress; a runtime owned by a background
    // workspace pushes loop_wakeup on new frames (linux_wpe.zig) and must not
    // pin the 16ms wake globally.
    if (activity.active_continuous or activity.browser_visible) return ACTIVE_WAIT_TIMEOUT_MS;
    // Terminal output only reaches the screen when the loop wakes and polls
    // (daemon sessions tail over an RPC; there is no fd to push a wake from).
    // Recent input starts the same display-rate window before ConPTY has an
    // echo ready, while output extends it for continuously redrawing TUIs.
    if (activity.terminal_burst) return ACTIVE_WAIT_TIMEOUT_MS;
    if (activity.sidebar_pulse or activity.pane_status_animating) return PIP_PULSE_WAIT_TIMEOUT_MS;
    // Pending turns keep the 30fps wake even without visible activity: daemon
    // -owned turns are pull-based (pollDaemonChatTurn), so this cadence is the
    // streaming latency floor, and pollSend's ~1Hz label repaint rides on it.
    if (activity.pending_send) return PENDING_SEND_WAIT_TIMEOUT_MS;
    if (activity.pending_slash_command) return SLASH_COMMAND_ANIMATION_WAIT_TIMEOUT_MS;
    if (activity.background_tasks) return BACKGROUND_TASK_WAIT_TIMEOUT_MS;
    return IDLE_WAIT_TIMEOUT_MS;
}

fn handleEvent(window: *palette.platform.Window, state: *AppState, keyboard: *keybinds.NativeKeyboardConfig, ui_scale: f32, event: *palette.Event) bool {
    // Deliberate-interaction events stamp input recency (tmux `window-size
    // latest`): terminal size re-assertion only fires near real user input,
    // so a focused-but-idle desktop cannot tug the shared PTY size away from
    // a web/mobile client. Focus gain counts as interaction so returning to
    // the GUI heals a drifted pane without a keypress; passive mouse motion
    // does not.
    switch (event.*) {
        .key_down, .text_input, .mouse_button_down, .mouse_wheel, .focus_gained => {
            state.last_user_input_ms = platform_runtime.unixTimestampMs();
        },
        else => {},
    }
    switch (event.*) {
        .quit => {
            runtime_log.diagnostic("shutdown requested by platform quit event", .{});
            return !closePreflightPassed(state);
        },
        .close_requested => |close_event| {
            const keep_running = handleWindowCloseRequested(window, state);
            runtime_log.diagnostic("window close requested keep_running={} window_id={d}", .{ keep_running, @intFromEnum(close_event.window) });
            return keep_running;
        },
        .window_hidden => {
            state.suspendBrowserForHostWindowHidden();
        },
        .window_shown => {
            state.resumeBrowserAfterHostWindowShown();
        },
        .system_theme_changed => {
            // Auto follows the OS appearance live; other sources ignore it.
            const source = ui_theme.effectiveThemeSource(state.app_config.theme_config.source, state.app_config.omarchy_detected);
            if (syncSystemAppearance() and source == .auto) applyAppConfigRuntime(state);
        },
        .focus_gained => {
            state.window_input_focus = true;
            _ = state.acknowledgeFocusedPaneCompletion();
            // Files may have been committed or edited outside Verde.
            state.refreshSelectedWorkspaceGitChanges(false);
        },
        .focus_lost => {
            state.window_input_focus = false;
            state.alt_shortcut_hints_visible = false;
            state.ctrl_shortcut_hints_visible = false;
            state.shift_shortcut_hints_visible = false;
            disarmPrefix(state);
            exitPrefixNavigate(state);
            ui_layout.resetCompanionInputCaptures(state);
            ui_layout.blurPaletteModalTextInput(state);
            state.blurCompanionComposer();
        },
        .key_down => |*key_event| {
            // Any new key-down supersedes a pending text_input swallow; the
            // swallow only ever targets the event immediately following the
            // chord-completing key.
            state.prefix_swallow_text_input = false;
            if (key_event.hidScancode() == .lalt or key_event.hidScancode() == .ralt) {
                state.alt_shortcut_hints_visible = true;
            }
            if (key_event.hidScancode() == .lctrl or key_event.hidScancode() == .rctrl) {
                state.ctrl_shortcut_hints_visible = true;
            }
            if (key_event.hidScancode() == .lshift or key_event.hidScancode() == .rshift) {
                state.shift_shortcut_hints_visible = true;
            }
            if (browserInputDebugEnabled()) {
                log.info(
                    "browser-input platform key_down key=0x{x} scancode={} focused={} visible={}",
                    .{ @intFromEnum(key_event.key), @intFromEnum(key_event.hidScancode()), state.isBrowserPaneFocused(), state.isBrowserVisible() },
                );
            }
            // Credential and first-contact trust are security boundaries, so
            // they own key-down before terminal selection, prefix chords, and
            // persistent Companion captures can act on the obscured surface.
            if ((state.runtimeCredentialModalOpen() or state.runtimeTrustProposal() != null) and
                ui_layout.handlePaletteKeyDown(state, key_event))
            {
                syncWindowTextInput(window, state);
                return true;
            }
            if (key_event.key == .escape and ui_layout.companionOwnsEscapeKey(state)) {
                _ = ui_layout.handleCompanionEscapeKey(state, true);
                syncWindowTextInput(window, state);
                return true;
            }
            if (state.isCompanionEnabled() and state.companion_controller.mission_control_open) {
                // True Palette modals remain above Mission Control. Otherwise
                // the full-window overlay owns keys before pane/browser input.
                if (ui_layout.handlePaletteKeyDown(state, key_event)) {
                    syncWindowTextInput(window, state);
                    return true;
                }
                if (key_event.key == .escape) {
                    _ = ui_layout.handleCompanionEscapeKey(state, true);
                } else if (state.companion_composer.focused) {
                    _ = state.routeCompanionComposerKeyDown(key_event);
                }
                syncWindowTextInput(window, state);
                return true;
            }
            if (terminal_panel_ui.handlePaletteKeyDown(state, key_event)) {
                syncWindowTextInput(window, state);
                return true;
            }
            // An armed prefix owns the next key outright, even above modals,
            // so a chord never half-completes into a text field.
            if (state.prefix_armed and handleArmedPrefixKeyDown(state, keyboard, key_event)) {
                syncWindowTextInput(window, state);
                return true;
            }
            if (state.prefix_navigate and handleNavigateKeyDown(state, keyboard, key_event)) {
                syncWindowTextInput(window, state);
                return true;
            }
            const raw_action = keyboard.actionForEvent(key_event);
            const action = if (raw_action == .companion and !state.isCompanionEnabled()) null else raw_action;
            // True modals own keys before the persistent Companion, while the
            // Companion visibility controls remain global across pane focus.
            if (ui_layout.handlePaletteKeyDown(state, key_event)) {
                syncWindowTextInput(window, state);
                return true;
            }
            // The ask-agent popover floats over panes and the side panel, so it
            // owns keys before any pane or panel body routing.
            if (agent_prompt_popover_ui.handleKeyDown(state, key_event)) {
                syncWindowTextInput(window, state);
                return true;
            }
            if (key_event.key == .escape and ui_layout.handleCompanionEscapeKey(state, true)) {
                syncWindowTextInput(window, state);
                return true;
            }
            // Arm only after true modals have declined the key so a modal
            // text field keeps its own Ctrl chords.
            if (keyboard.isPrefixKeyEvent(key_event)) {
                state.prefix_armed = true;
                state.markDirty();
                syncWindowTextInput(window, state);
                return true;
            }
            if (action == .companion) {
                handleKeyboardAction(state, keyboard, .companion);
                syncWindowTextInput(window, state);
                return true;
            }
            if (state.routeCompanionComposerKeyDown(key_event)) {
                syncWindowTextInput(window, state);
                return true;
            }
            if (workspace_panes_ui.handleEmptyWorkspaceKeyDown(state, key_event)) {
                syncWindowTextInput(window, state);
                return true;
            }
            // A focused side panel body (Changes / Files) owns navigation keys
            // before pane bindings, so Ctrl+W closes the panel, not a pane.
            if (side_panel_ui.handleKeyDown(state, key_event, action)) {
                syncWindowTextInput(window, state);
                return true;
            }
            if (file_viewer_ui.handleKeyDown(state, key_event)) {
                syncWindowTextInput(window, state);
                return true;
            }
            if (keyboard.workspaceActiveSelectIndexForEvent(key_event)) |active_ordinal| {
                if (sidebar_ui.focusAttentionClusterRowAtIndex(state, active_ordinal)) {
                    syncWindowTextInput(window, state);
                    return true;
                }
            }
            if (keyboard.workspacePaneSelectIndexForEvent(key_event)) |tab_ordinal| {
                if (sidebar_ui.selectOpenRowAtOrdinal(state, tab_ordinal)) {
                    syncWindowTextInput(window, state);
                    return true;
                }
            }
            // Pane-level bindings must stay app-owned even when an embedded
            // terminal has keyboard focus. Resolve them before terminal-owned
            // shortcut routing so Alt+Z zoom does not leak into TUIs such as
            // Codex, which treats it as a redraw/reset input.
            if (action) |resolved_workspace_action| {
                if (isWorkspacePaneAction(resolved_workspace_action) or isWorkspaceTraversalAction(resolved_workspace_action)) {
                    noteMacosWorkspaceCloseShortcut(key_event, resolved_workspace_action);
                    handleKeyboardAction(state, keyboard, resolved_workspace_action);
                    syncWindowTextInput(window, state);
                    return true;
                }
            }
            if (state.terminal_controller.focused and terminalOwnedShortcut(key_event)) {
                const terminal_key_handled = state.handleTerminalKeyDown(keyboard, key_event);
                state.noteTerminalKeyRouting(key_event, terminal_key_handled);
                if (terminal_key_handled) {
                    return true;
                }
            }
            const paste_shortcut = shouldPasteClipboardImage(state, key_event);
            logPasteShortcutEvent(state, key_event, paste_shortcut);
            if (paste_shortcut) {
                // Browser URL bar, modal text inputs, and the model picker's
                // search field handle their own paste further down the chain.
                // Don't intercept here when one of them owns focus.
                if (!state.browser_controller.address_focused and state.palette_modal_text_focus == .none and
                    !state.composer_controller.model_picker.isOpen() and
                    !state.composer_controller.directory_picker.isOpen() and
                    !state.composer_controller.runtime_picker.isOpen())
                {
                    if (state.attachClipboardImageToCurrentDraft()) return true;
                    if (state.pasteClipboardTextIntoPaletteComposer()) return true;
                }
            }
            // A focused browser pane reserves the conventional reload chord
            // for its active tab, ahead of any app-refresh override that
            // still binds plain Ctrl+R.
            if (handleBrowserReloadShortcut(state, key_event)) {
                syncWindowTextInput(window, state);
                return true;
            }
            // Ctrl+T / Ctrl+W open and close browser tabs, only while the
            // browser pane owns focus so terminals and chats keep the chords.
            if (handleBrowserTabShortcut(state, key_event)) {
                syncWindowTextInput(window, state);
                return true;
            }
            // Palette and config refresh must win from anywhere — including
            // while a TUI owns focus — so Ctrl+Shift+R is not typed into
            // Claude/Codex as a redraw chord.
            if (action) |resolved_action| {
                if (resolved_action == .command_palette or resolved_action == .refresh) {
                    handleKeyboardAction(state, keyboard, resolved_action);
                    syncWindowTextInput(window, state);
                    return true;
                }
            }
            if (handleGuiChatShortcut(state, keyboard, key_event)) {
                syncWindowTextInput(window, state);
                return true;
            }
            if (keyboard.workspaceShowAllForEvent(key_event)) {
                state.showAllWorkspacesInSidebar();
                syncWindowTextInput(window, state);
                return true;
            }
            if (keyboard.workspaceSelectIndexForEvent(key_event)) |workspace_ordinal| {
                if (workspace_ordinal < state.project_controller.projects.items.len) {
                    state.noteWorkspaceSwitchInput(workspace_ordinal, palette.clock.monotonicTimestampNs(), profiler.nowNs());
                }
                if (state.selectProjectScoped(workspace_ordinal)) {
                    syncWindowTextInput(window, state);
                    return true;
                }
            }
            if (handleFileSearchAccept(state, key_event)) {
                syncWindowTextInput(window, state);
                return true;
            }
            if (!state.composer_controller.composer.focused and keyboard.workspaceFocusPromptForEvent(key_event)) {
                if (state.focusPromptForFocusedChatWorkspacePane()) {
                    syncWindowTextInput(window, state);
                    return true;
                }
            }
            if (handleComposerBlurShortcut(state, key_event)) {
                syncWindowTextInput(window, state);
                return true;
            }
            if (handleTranscriptMarkdownCopyShortcut(state, key_event)) {
                return true;
            }
            if (state.routePaletteComposerKeyDown(key_event)) {
                syncWindowTextInput(window, state);
                return true;
            }
            // Pane-level bindings must stay app-owned even when a native webview
            // or embedded terminal has keyboard focus.
            if (action) |resolved_workspace_action| {
                if (isWorkspacePaneAction(resolved_workspace_action) or isWorkspaceTraversalAction(resolved_workspace_action)) {
                    noteMacosWorkspaceCloseShortcut(key_event, resolved_workspace_action);
                    handleKeyboardAction(state, keyboard, resolved_workspace_action);
                    syncWindowTextInput(window, state);
                    return true;
                }
            }
            const native_browser_focused = state.isNativeBrowserSurfaceFocused();
            if (native_browser_focused) {
                state.browser_controller.address_focused = false;
            }
            if (handleBrowserInspectorEscape(state, key_event)) {
                syncWindowTextInput(window, state);
                return true;
            }
            if (macosNativeBrowserShouldOwnKeyboard(state)) {
                syncWindowTextInput(window, state);
                return true;
            }
            if (!native_browser_focused and browser_ui.handlePaletteKeyDown(state, key_event)) {
                syncWindowTextInput(window, state);
                return true;
            }
            if (handleBrowserSelectAllShortcut(state, key_event)) {
                return true;
            }
            if (handleBrowserCopyCutShortcut(state, key_event)) {
                return true;
            }
            if (handleBrowserClipboardShortcut(state, key_event)) {
                return true;
            }
            if (native_browser_focused and !state.composer_controller.composer.focused) {
                syncWindowTextInput(window, state);
                return true;
            }
            if (state.isBrowserPaneFocused() and handleBrowserKeyboardEvent(state, key_event)) {
                return true;
            }
            if (action) |resolved_app_action| switch (resolved_app_action) {
                .toggle_terminal,
                .toggle_browser,
                .toggle_sidebar,
                .toggle_sidebar_hidden,
                .toggle_side_panel,
                .new_thread,
                .settings,
                => {
                    handleKeyboardAction(state, keyboard, resolved_app_action);
                    return true;
                },
                else => {},
            };
            const terminal_key_handled = state.handleTerminalKeyDown(keyboard, key_event);
            state.noteTerminalKeyRouting(key_event, terminal_key_handled);
            if (terminal_key_handled) {
                return true;
            }
            if (handleFontSizeShortcut(state, key_event)) {
                return true;
            }
            if (handleBrowserKeyboardEvent(state, key_event)) {
                return true;
            }
            if (handleFileSearchNavigation(state, key_event)) {
                return true;
            }
            if (handlePendingThreadFollowupShortcut(state, key_event)) {
                return true;
            }
            if (handleWorkspaceContextMenuShortcut(state, key_event)) {
                return true;
            }
            if (handleComposerFocusShortcut(state, key_event)) {
                return true;
            }
            if (handleTranscriptMarkdownSelectAllShortcut(state, key_event)) {
                return true;
            }
            if (key_event.repeat) {
                if (keyboard.transcriptScrollActionForEvent(key_event)) |repeat_action| {
                    handleKeyboardAction(state, keyboard, repeat_action);
                    return true;
                }
            }
            if (action) |resolved_action| {
                handleKeyboardAction(state, keyboard, resolved_action);
            }
        },
        .key_up => |*key_event| {
            if (key_event.hidScancode() == .lalt or key_event.hidScancode() == .ralt) {
                state.alt_shortcut_hints_visible = false;
            }
            if (key_event.hidScancode() == .lctrl or key_event.hidScancode() == .rctrl) {
                state.ctrl_shortcut_hints_visible = false;
            }
            if (key_event.hidScancode() == .lshift or key_event.hidScancode() == .rshift) {
                state.shift_shortcut_hints_visible = false;
            }
            if (browserInputDebugEnabled()) {
                log.info(
                    "browser-input platform key_up key=0x{x} scancode={} focused={} visible={}",
                    .{ @intFromEnum(key_event.key), @intFromEnum(key_event.hidScancode()), state.isBrowserPaneFocused(), state.isBrowserVisible() },
                );
            }
            if (key_event.key == .escape and ui_layout.handleCompanionEscapeKey(state, false)) {
                syncWindowTextInput(window, state);
                return true;
            }
            if (state.isCompanionEnabled() and state.companion_controller.mission_control_open) {
                syncWindowTextInput(window, state);
                return true;
            }
            if (state.isNativeBrowserSurfaceFocused()) {
                state.browser_controller.address_focused = false;
                syncWindowTextInput(window, state);
                return true;
            }
            if (macosNativeBrowserShouldOwnKeyboard(state)) {
                syncWindowTextInput(window, state);
                return true;
            }
            if (handleBrowserKeyboardEvent(state, key_event)) {
                return true;
            }
        },
        .text_input => |text_event| {
            if (state.prefix_swallow_text_input) {
                state.prefix_swallow_text_input = false;
                return true;
            }
            const text_input = text_event.text;
            if (state.prefix_help_search_active) {
                state.appendPrefixHelpQuery(text_input);
                state.markDirty();
                syncWindowTextInput(window, state);
                return true;
            }
            if (ui_layout.handlePaletteTextInput(state, text_input)) {
                syncWindowTextInput(window, state);
                return true;
            }
            if (agent_prompt_popover_ui.handleTextInput(state, text_input)) {
                syncWindowTextInput(window, state);
                return true;
            }
            if (state.isCompanionEnabled() and state.companion_controller.mission_control_open) {
                if (state.companion_composer.focused) _ = state.routeCompanionComposerTextInput(text_input);
                syncWindowTextInput(window, state);
                return true;
            }
            if (state.routeCompanionComposerTextInput(text_input)) {
                syncWindowTextInput(window, state);
                return true;
            }
            if (side_panel_ui.handleTextInput(state, text_input)) {
                syncWindowTextInput(window, state);
                return true;
            }
            if (file_viewer_ui.handleTextInput(state, text_input)) {
                syncWindowTextInput(window, state);
                return true;
            }
            if (state.routePaletteComposerTextInput(text_input)) {
                syncWindowTextInput(window, state);
                return true;
            }
            const native_browser_focused = state.isNativeBrowserSurfaceFocused();
            if (native_browser_focused) {
                state.browser_controller.address_focused = false;
                syncWindowTextInput(window, state);
                return true;
            }
            if (macosNativeBrowserShouldOwnKeyboard(state)) {
                syncWindowTextInput(window, state);
                return true;
            }
            if (browserInputDebugEnabled()) {
                log.info(
                    "browser-input platform text_input text_len={d} timestamp={} focused={} native_focused={} visible={}",
                    .{ text_input.len, palette.clock.monotonicTimestampNs(), state.isBrowserPaneFocused(), native_browser_focused, state.isBrowserVisible() },
                );
            }
            const browser_text_handled = state.handleBrowserKey(.{
                .key_code = 0,
                .text = text_input,
                .pressed = true,
            });
            if (browser_ui.handlePaletteTextInput(state, text_input)) {
                syncWindowTextInput(window, state);
                return true;
            }
            if (browser_text_handled) {
                return true;
            }
            const terminal_text_handled = state.handleTerminalTextInput(text_input);
            state.noteTerminalTextRouting(text_input, terminal_text_handled);
            if (terminal_text_handled) {
                return true;
            }
        },
        .mouse_motion => |*motion_event| {
            if (sidebar_ui.finishThreadDragIfMouseReleased(state, motion_event.x, motion_event.y, motion_event.state)) {
                syncWindowTextInput(window, state);
                return true;
            }
            state.notePaletteWorkspaceMouseMotion(motion_event.x, motion_event.y);
            ui_layout.updateThreadImportModalHover(state, motion_event.x, motion_event.y);
            ui_layout.updateCookieImportModalHover(state, motion_event.x, motion_event.y);
            ui_layout.updateCommitSheetHover(state, motion_event.x, motion_event.y);
            ui_layout.updateSettingsModalHover(state, motion_event.x, motion_event.y);
            ui_layout.updateCommandPaletteHover(state, motion_event.x, motion_event.y);
            const modal_owns_motion = ui_layout.handlePaletteMouseMotion(state, motion_event.x, motion_event.y);
            if (state.palette_modal_pointer_captured or modal_owns_motion) {
                return true;
            }
            if (agent_prompt_popover_ui.handleMouseMotion(state, motion_event.x, motion_event.y)) return true;
            if (ui_layout.handleCompanionMouseMotion(state, motion_event.x, motion_event.y, motion_event.state.left)) {
                return true;
            }
            // Composer popovers (model picker / run config) draw above the
            // panes, so their hover/drag routing must win over transcript and
            // pane motion handlers below.
            if (state.routeComposerPopoverMouseMotion(motion_event, ui_scale)) {
                return true;
            }
            chat_panel_ui.handleTranscriptPaletteMouseMotion(state);
            if (side_panel_ui.handleMouseMotion(state, motion_event.x, motion_event.y)) {
                return true;
            }
            workspace_strip_ui.handlePaletteMouseMotion(state, motion_event.x, motion_event.y);
            const ctrl_down = isCtrlPressed() or host.modState().ctrl;
            if (workspace_panes_ui.hasActivePaneDrag() and workspace_panes_ui.handlePaletteMouseMotion(state, motion_event.x, motion_event.y, motion_event.xrel, motion_event.yrel, ctrl_down)) {
                return true;
            }
            // Focus the workspace leaf before forwarding motion to its content.
            // Mouse-aware TUIs consume motion, which must not prevent hover focus.
            if (workspace_panes_ui.handlePaletteMouseMotion(state, motion_event.x, motion_event.y, motion_event.xrel, motion_event.yrel, ctrl_down)) {
                return true;
            }
            if (terminal_panel_ui.handlePaletteMouseMotion(state, motion_event.x, motion_event.y, motion_event.state)) {
                return true;
            }
            browser_ui.handlePaletteMouseMotion(state, motion_event.x, motion_event.y);
            sidebar_ui.handlePaletteMouseMotion(state, motion_event.x, motion_event.y);
            if (state.routePaletteComposerMouseMotion(motion_event, ui_scale)) {
                return true;
            }
            _ = state.handleBrowserMouse(browserMouseMotionEvent(motion_event));
        },
        .mouse_button_down, .mouse_button_up => |*button_event| {
            if (!button_event.down and ui_layout.companionOwnsPointerRelease(state, button_event.button)) {
                _ = ui_layout.handleCompanionMouseButton(state, button_event.x, button_event.y, button_event.button, false, button_event.clicks);
                syncWindowTextInput(window, state);
                return true;
            }
            if (button_event.button == 1 and !button_event.down and state.palette_modal_pointer_captured) {
                _ = ui_layout.handlePaletteMouseButton(state, button_event.x, button_event.y, false, button_event.clicks);
                state.palette_modal_pointer_captured = false;
                state.modal_text_drag_active = false;
                state.endImageModalPan();
                syncWindowTextInput(window, state);
                return true;
            }
            if (button_event.button == 1 and sidebar_ui.hasActiveThreadDrag()) {
                if (sidebar_ui.handlePaletteMouseButton(state, button_event.x, button_event.y, button_event.down)) {
                    syncWindowTextInput(window, state);
                    return true;
                }
            }
            if (button_event.button == 1 and ui_layout.handlePaletteMouseButton(state, button_event.x, button_event.y, button_event.down, button_event.clicks)) {
                if (button_event.down) state.palette_modal_pointer_captured = true;
                syncWindowTextInput(window, state);
                return true;
            }
            if (ui_layout.hasPaletteModal(state)) {
                syncWindowTextInput(window, state);
                return true;
            }
            if (button_event.button == 1 and agent_prompt_popover_ui.handleMouseButton(state, button_event.x, button_event.y, button_event.down, button_event.clicks)) {
                syncWindowTextInput(window, state);
                return true;
            }
            if (ui_layout.handleCompanionMouseButton(state, button_event.x, button_event.y, button_event.button, button_event.down, button_event.clicks)) {
                syncWindowTextInput(window, state);
                return true;
            }
            if (button_event.button == 1 and button_event.down) state.blurCompanionComposer();
            // Composer popovers overlay the panes; clicks on (or dismissing)
            // them must not fall through to workspace/transcript handlers.
            if (state.routeComposerPopoverMouseButton(button_event, ui_scale)) {
                syncWindowTextInput(window, state);
                return true;
            }
            // The sidebar context menu is a Palette overlay and can extend
            // across workspace panes when the rail is collapsed. Route its
            // clicks, and the right-click that opens it, before pane/browser
            // content so the visual top layer also owns pointer input.
            if (button_event.button == 1 and button_event.down and state.sidebar_context_menu_open and
                !sidebar_ui.pointerOverSidebar(button_event.x, button_event.y))
            {
                state.closeSidebarContextMenu();
            }
            if (button_event.button == 1 and button_event.down and state.sidebar_context_menu_open and
                sidebar_ui.handlePaletteMouseButton(state, button_event.x, button_event.y, button_event.down))
            {
                syncWindowTextInput(window, state);
                return true;
            }
            if (button_event.down and button_event.button == sidebar_ui.palette_mouse_button_secondary and
                sidebar_ui.handlePaletteSecondaryMouseButton(state, button_event.x, button_event.y, button_event.down))
            {
                syncWindowTextInput(window, state);
                return true;
            }
            if (button_event.button == 1 and debug_ui.handlePaletteMouseButton(state, button_event.x, button_event.y, button_event.down)) {
                syncWindowTextInput(window, state);
                return true;
            }
            // The workspace strip sits above the pane region while the sidebar
            // is collapsed/hidden; it owns its own rows before pane routing.
            if (button_event.button == 1 and workspace_strip_ui.handlePaletteMouseButton(state, button_event.x, button_event.y, button_event.down)) {
                syncWindowTextInput(window, state);
                return true;
            }
            // The approval card overlays the gap between transcript and
            // composer, so it must receive clicks before pane/browser routing.
            if (button_event.button == 1 and chat_panel_ui.handleApprovalPaletteMouseButton(state, button_event.x, button_event.y, button_event.down)) {
                syncWindowTextInput(window, state);
                return true;
            }
            // The git outcome card floats over the bottom of the workspace.
            if (button_event.button == 1 and ui_layout.handleGitToastMouseButton(state, button_event.x, button_event.y, button_event.down)) {
                syncWindowTextInput(window, state);
                return true;
            }
            // Running background-command cards occupy that same strip so Stop /
            // Output remain reachable after the stream commits.
            if (button_event.button == 1 and chat_panel_ui.handleBackgroundTaskPinMouseButton(
                state,
                button_event.x,
                button_event.y,
                button_event.down,
                button_event.clicks,
            )) {
                syncWindowTextInput(window, state);
                return true;
            }
            // Side panel chrome (view tabs, actions, resize grip) owns its hits;
            // the browser page and agent rows inside route below.
            if (button_event.button == 1 and side_panel_ui.handleMouseButton(state, button_event.x, button_event.y, button_event.down, button_event.clicks)) {
                syncWindowTextInput(window, state);
                return true;
            }
            // Linked-chat rows render in the side panel's Agents view.
            if (button_event.button == 1 and chat_panel_ui.handleLinkedChatsMouseButton(state, button_event.x, button_event.y, button_event.down)) {
                syncWindowTextInput(window, state);
                return true;
            }
            // Pane chrome overlays native browser and terminal content, so its
            // precise hits must be handled before either content surface.
            if (workspace_panes_ui.handlePaneChromeMouseButton(state, button_event.x, button_event.y, button_event.button, button_event.down)) {
                syncWindowTextInput(window, state);
                return true;
            }
            const ctrl_down = isCtrlPressed() or host.modState().ctrl;
            const shift_down = host.modState().shift;
            if (button_event.button == 1 and (ctrl_down or workspace_panes_ui.hasActivePaneDrag()) and
                workspace_panes_ui.handlePaletteMouseButton(state, button_event.x, button_event.y, button_event.button, button_event.down, ctrl_down, shift_down))
            {
                syncWindowTextInput(window, state);
                return true;
            }
            if (browserInputDebugEnabled()) {
                log.info(
                    "browser-input platform mouse_button down={} button={} x={d:.1} y={d:.1} contains={} focused={}",
                    .{
                        button_event.down,
                        button_event.button,
                        button_event.x,
                        button_event.y,
                        state.browserPaneContains(button_event.x, button_event.y),
                        state.isBrowserPaneFocused(),
                    },
                );
            }
            if (button_event.button == 1 and browser_ui.handlePaletteMouseButton(state, button_event.x, button_event.y, button_event.down, button_event.clicks)) {
                syncWindowTextInput(window, state);
                return true;
            }
            if (button_event.down and macosBrowserClickWillFocusNativeSurface(state, button_event.x, button_event.y)) {
                if (window.isTextInputActive()) {
                    window.stopTextInput();
                }
            }
            const handled = state.handleBrowserMouse(browserMouseButtonEvent(button_event));
            if (!handled and button_event.down) {
                state.unfocusBrowserPane();
            }
            if (handled) {
                syncWindowTextInput(window, state);
                return true;
            }
            // Workspace header (Open / Browser) must run before the sidebar rail so hits are never
            // swallowed by expanded sidebar geometry or rail chrome.
            if (button_event.button == 1 and chat_panel_ui.handleWorkspaceHeaderPaletteMouseButton(
                state,
                button_event.x,
                button_event.y,
                button_event.down,
            )) {
                syncWindowTextInput(window, state);
                return true;
            }
            if (workspace_panes_ui.handlePaletteMouseButton(state, button_event.x, button_event.y, button_event.button, button_event.down, ctrl_down, shift_down)) {
                syncWindowTextInput(window, state);
                return true;
            }
            if (button_event.button == 1 and sidebar_ui.handlePaletteMouseButton(state, button_event.x, button_event.y, button_event.down)) {
                syncWindowTextInput(window, state);
                return true;
            }
            if (button_event.button == 1 and chat_panel_ui.handleSlashCommandPaletteMouseButton(state, button_event.x, button_event.y, button_event.down)) {
                syncWindowTextInput(window, state);
                return true;
            }
            if (button_event.button == 1 and chat_panel_ui.handleFileSearchPaletteMouseButton(state, button_event.x, button_event.y, button_event.down)) {
                syncWindowTextInput(window, state);
                return true;
            }
            if (button_event.button == 1 and chat_panel_ui.handleTranscriptPaletteMouseButton(
                state,
                button_event.x,
                button_event.y,
                button_event.down,
                button_event.clicks,
            )) {
                syncWindowTextInput(window, state);
                return true;
            }
            if (button_event.button == 1 and state.handleComposerDraftImageClearMouseButton(button_event.x, button_event.y, button_event.down)) {
                syncWindowTextInput(window, state);
                return true;
            }
            if (button_event.button == 1 and chat_panel_ui.handleFollowupPinMouseButton(state, button_event.x, button_event.y, button_event.down, button_event.clicks)) {
                syncWindowTextInput(window, state);
                return true;
            }
            if (terminal_panel_ui.handlePaletteMouseButton(state, button_event.x, button_event.y, button_event.button, button_event.down)) {
                syncWindowTextInput(window, state);
                return true;
            }
            if (state.routePaletteComposerMouseButton(button_event, ui_scale)) {
                syncWindowTextInput(window, state);
                return true;
            }
            syncWindowTextInput(window, state);
        },
        .mouse_wheel => |*wheel_event| {
            var input_fb_w: c_int = 0;
            var input_fb_h: c_int = 0;
            getWindowSizeInPixels(window, &input_fb_w, &input_fb_h);
            if (ui_layout.handleCommandPaletteWheel(
                state,
                @floatFromInt(input_fb_w),
                @floatFromInt(input_fb_h),
                wheel_event.mouse_x,
                wheel_event.mouse_y,
                wheel_event.y,
            )) {
                return true;
            }
            if (ui_layout.handleCommitSheetWheel(
                state,
                @floatFromInt(input_fb_w),
                @floatFromInt(input_fb_h),
                wheel_event.mouse_x,
                wheel_event.mouse_y,
                wheel_event.y,
            )) {
                return true;
            }
            if (ui_layout.handleCookieImportWheel(
                state,
                @floatFromInt(input_fb_w),
                @floatFromInt(input_fb_h),
                wheel_event.mouse_x,
                wheel_event.mouse_y,
                wheel_event.y,
            )) {
                return true;
            }
            if (ui_layout.handleProviderOnboardingWheel(
                state,
                @floatFromInt(input_fb_w),
                @floatFromInt(input_fb_h),
                wheel_event.mouse_x,
                wheel_event.mouse_y,
                wheel_event.y,
            )) {
                return true;
            }
            if (ui_layout.handleSettingsModalWheel(
                state,
                @floatFromInt(input_fb_w),
                @floatFromInt(input_fb_h),
                wheel_event.mouse_x,
                wheel_event.mouse_y,
                wheel_event.y,
            )) {
                return true;
            }
            if (ui_layout.handleImageModalWheel(
                state,
                @floatFromInt(input_fb_w),
                @floatFromInt(input_fb_h),
                wheel_event.mouse_x,
                wheel_event.mouse_y,
                wheel_event.y,
            )) {
                return true;
            }
            if (ui_layout.hasPaletteModal(state)) return true;
            if (agent_prompt_popover_ui.handleWheel(state, wheel_event.mouse_x, wheel_event.mouse_y, wheel_event.y)) return true;
            if (routeCompanionWheel(state, wheel_event.mouse_x, wheel_event.mouse_y, wheel_event.y)) {
                return true;
            }
            // Composer popovers overlay the panes; scrolling their lists must
            // win over sidebar/terminal/transcript wheel handlers below.
            if (state.routeComposerPopoverWheel(wheel_event, ui_scale)) {
                return true;
            }
            if (sidebar_ui.handlePaletteWheel(wheel_event.mouse_x, wheel_event.mouse_y, wheel_event.y)) {
                return true;
            }
            if (side_panel_ui.handleWheel(state, wheel_event.mouse_x, wheel_event.mouse_y, wheel_event.y)) {
                return true;
            }
            if (workspace_panes_ui.handlePaletteWheel(
                state,
                wheel_event.mouse_x,
                wheel_event.mouse_y,
                wheel_event.x,
                wheel_event.y,
                isCtrlPressed() or host.modState().ctrl,
            )) {
                return true;
            }
            // The browser owns an explicit pane rectangle, while terminal,
            // transcript, and composer hit caches may retain overlapping data
            // from an earlier layout. Let the visible browser claim its region
            // before those pane-local caches consume the wheel event.
            if (state.handleBrowserMouse(browserMouseWheelEvent(wheel_event))) {
                browser_wheel_forwarded = true;
                return true;
            }
            if (terminal_panel_ui.handlePaletteWheel(state, wheel_event.mouse_x, wheel_event.mouse_y, wheel_event.y)) {
                return true;
            }
            if (chat_panel_ui.handleLinkedChatsWheel(state, wheel_event.mouse_x, wheel_event.mouse_y, wheel_event.y)) {
                return true;
            }
            if (chat_panel_ui.handleTranscriptPaletteWheel(state, wheel_event.mouse_x, wheel_event.mouse_y, wheel_event.y)) {
                return true;
            }
            if (state.routePaletteComposerWheel(wheel_event, ui_scale)) {
                return true;
            }
            if (state.handleComposerWheel(wheel_event)) {
                return true;
            }
            if (chat_panel_ui.handleFocusedTranscriptPaletteWheel(state, wheel_event.y)) {
                return true;
            }
        },
        else => {},
    }
    return true;
}

fn browserInputDebugEnabled() bool {
    return std.c.getenv("VERDE_BROWSER_INPUT_DEBUG") != null;
}

fn syncWindowTextInput(window: *palette.platform.Window, state: *AppState) void {
    if (macosNativeBrowserShouldOwnKeyboard(state)) {
        if (window.isTextInputActive()) window.stopTextInput();
        return;
    }
    const needs_text_input = state.terminal_controller.focused or
        state.prefix_help_search_active or
        state.composer_controller.composer.focused or
        (state.isCompanionEnabled() and state.companion_composer.focused) or
        // The model picker's embedded search field consumes typed characters
        // while the popover is open.
        state.composer_controller.model_picker.isOpen() or
        state.composer_controller.directory_picker.isOpen() or
        state.composer_controller.runtime_picker.isOpen() or
        state.browser_controller.address_focused or
        state.palette_modal_text_focus != .none or
        side_panel_ui.wantsTextInput(state) or
        agent_prompt_popover_ui.wantsTextInput() or
        file_viewer_ui.wantsTextInput(state) or
        (state.isBrowserPaneFocused() and !macosNativeBrowserShouldOwnKeyboard(state));
    if (!needs_text_input) {
        if (window.isTextInputActive()) window.stopTextInput();
        return;
    }
    if (window.isTextInputActive()) return;
    // Verde never positioned the IME candidate window under SDL either.
    window.startTextInput(.{});
    if (browserInputDebugEnabled()) {
        log.info("browser-input enabled platform text input for Verde-owned text focus", .{});
    }
}

fn handleBrowserKeyboardEvent(state: *AppState, event: *const palette.event.KeyEvent) bool {
    const key_code = browserKeyCodeForEvent(event) orelse return false;
    return state.handleBrowserKey(.{
        .key_code = key_code,
        .pressed = event.down,
        .ctrl = event.mod.ctrl,
        .shift = event.mod.shift,
        .alt = event.mod.alt,
        .super = event.mod.super,
    });
}

fn handleBrowserReloadShortcut(state: *AppState, event: *const palette.event.KeyEvent) bool {
    if (!state.isBrowserVisible()) return false;
    if (!state.isBrowserPaneFocused() and !state.browser_controller.address_focused) return false;
    if (!keybinds.isBrowserReloadEvent(event)) return false;
    state.reloadBrowser();
    return true;
}

fn handleBrowserTabShortcut(state: *AppState, event: *const palette.event.KeyEvent) bool {
    if (!state.isBrowserVisible()) return false;
    if (!state.isBrowserPaneFocused() and !state.browser_controller.address_focused) return false;
    if (keybinds.isBrowserNewTabEvent(event)) {
        browser_ui.blurAddress(state);
        state.createBrowserTab();
        return true;
    }
    if (keybinds.isBrowserCloseTabEvent(event)) {
        browser_ui.blurAddress(state);
        if (state.browserTabCount() > 0) state.closeBrowserTab(state.activeBrowserTabIndex());
        return true;
    }
    return false;
}

fn handleBrowserInspectorEscape(state: *AppState, event: *const palette.event.KeyEvent) bool {
    if (!state.isBrowserPaneFocused() or !state.isBrowserInspectorEnabled()) return false;
    if (!event.down or event.repeat) return false;
    if (event.key != .escape and event.hidScancode() != .escape) return false;
    state.browser_controller.inspector_menu_open = false;
    state.disableBrowserInspector(false);
    return true;
}

fn handleBrowserClipboardShortcut(state: *AppState, event: *const palette.event.KeyEvent) bool {
    if (state.isNativeBrowserSurfaceFocused()) return false;
    if (!state.isBrowserPaneFocused()) return false;
    if (!event.down or event.repeat) return false;
    if (!isPrimaryModifierPressed(event.mod)) return false;
    if (event.mod.alt) return false;
    if (event.hidScancode() != .v and event.key != .v) return false;

    const text = state.readClipboardTextForPaste() orelse return true;
    defer state.allocator.free(text);
    if (text.len == 0) return true;
    _ = state.handleBrowserKey(.{
        .key_code = 0,
        .text = text,
        .pressed = true,
        .ctrl = event.mod.ctrl,
        .shift = event.mod.shift,
        .alt = event.mod.alt,
        .super = event.mod.super,
    });
    return true;
}

fn handleBrowserSelectAllShortcut(state: *AppState, event: *const palette.event.KeyEvent) bool {
    if (state.isNativeBrowserSurfaceFocused()) return false;
    if (!state.isBrowserPaneFocused()) return false;
    if (!event.down or event.repeat) return false;
    if (!isPrimaryModifierPressed(event.mod)) return false;
    if (event.mod.alt or event.mod.shift) return false;
    if (event.hidScancode() != .a and event.key != .a) return false;
    state.selectAllBrowserFocusedElement();
    return true;
}

fn handleBrowserCopyCutShortcut(state: *AppState, event: *const palette.event.KeyEvent) bool {
    if (state.isNativeBrowserSurfaceFocused()) return false;
    if (!state.isBrowserPaneFocused()) return false;
    if (!event.down or event.repeat) return false;
    if (!isPrimaryModifierPressed(event.mod)) return false;
    if (event.mod.alt or event.mod.shift) return false;
    const copy = event.hidScancode() == .c or event.key == .c;
    const cut = event.hidScancode() == .x or event.key == .x;
    if (!copy and !cut) return false;
    state.copyBrowserFocusedSelection(cut);
    return true;
}

fn browserMouseMotionEvent(event: *const palette.event.MotionEvent) browser_runtime.MouseEvent {
    return .{
        .x = event.x,
        .y = event.y,
    };
}

fn browserMouseButtonEvent(event: *const palette.event.ButtonEvent) browser_runtime.MouseEvent {
    return .{
        .x = event.x,
        .y = event.y,
        .button = switch (event.button) {
            1 => .left,
            2 => .middle,
            3 => .right,
            4 => .back,
            5 => .forward,
            else => null,
        },
        .pressed = event.down,
    };
}

fn browserMouseWheelEvent(event: *const palette.event.WheelEvent) browser_runtime.MouseEvent {
    return .{
        .x = event.mouse_x,
        .y = event.mouse_y,
        .wheel_x = event.x,
        .wheel_y = event.y,
    };
}

fn browserKeyCodeForEvent(event: *const palette.event.KeyEvent) ?u32 {
    return switch (event.key) {
        .@"return", .kp_enter => 0xff0d,
        .backspace => 0xff08,
        .tab => 0xff09,
        .escape => 0xff1b,
        .delete => 0xffff,
        .home => 0xff50,
        .left => 0xff51,
        .up => 0xff52,
        .right => 0xff53,
        .down => 0xff54,
        .pageup => 0xff55,
        .pagedown => 0xff56,
        .end => 0xff57,
        else => {
            // Chromium expects raw key down/up around printable text input, while the
            // text_input event still carries the actual composed UTF-8 characters.
            // Key codes keep SDL's values: printable keys report their unshifted
            // character, other keys their HID usage with bit 30 set.
            const key_code = legacyKeyCode(event);
            if (key_code > 0 and key_code <= 0x7f) return key_code;
            if (!event.mod.ctrl and !event.mod.alt and !event.mod.super) return null;
            return key_code;
        },
    };
}

/// The SDL3 `SDL_Keycode` value Verde's browser bridge was written against.
fn legacyKeyCode(event: *const palette.event.KeyEvent) u32 {
    if (event.key == .character) {
        const cp = event.shortcutCodepoint();
        if (cp != 0) return cp;
    } else if (printableAsciiForKey(event.key)) |ch| {
        return ch;
    }
    return @as(u32, @intFromEnum(event.hidScancode())) | 0x4000_0000;
}

const printable_ascii_by_key = blk: {
    var table = [_]u8{0} ** (@typeInfo(palette.event.Keycode).@"enum".fields.len);
    var ch: u8 = 0x20;
    while (ch <= 0x7e) : (ch += 1) {
        if (ch >= 'A' and ch <= 'Z') continue;
        const key = palette.event.Keycode.fromAscii(ch);
        if (key != .character) table[@intFromEnum(key)] = ch;
    }
    break :blk table;
};

fn printableAsciiForKey(key: palette.event.Keycode) ?u8 {
    const index = @intFromEnum(key);
    if (index >= printable_ascii_by_key.len) return null;
    const ch = printable_ascii_by_key[index];
    return if (ch == 0) null else ch;
}

fn keymodBits(modifier_state: palette.event.Mods) u16 {
    return @bitCast(modifier_state);
}

fn shouldPasteClipboardImage(state: *const AppState, event: *const palette.event.KeyEvent) bool {
    if (state.isBrowserPaneFocused() or state.browser_controller.address_focused or state.palette_modal_text_focus != .none) return false;
    if (state.terminal_controller.focused) return false;
    if (!event.down or event.repeat) return false;
    if (event.hidScancode() != .v and event.key != .v) return false;
    return isPrimaryModifierPressed(event.mod);
}

fn terminalOwnedShortcut(event: *const palette.event.KeyEvent) bool {
    if (!event.down) return false;
    if (event.mod.alt) return false;
    const ctrl = event.mod.ctrl;
    const shift = event.mod.shift;
    const gui = event.mod.super;
    return switch (event.hidScancode()) {
        // Copy/paste: Ctrl+C / Super+C / Ctrl+V / Super+V (with or without
        // shift). For copy, the panel's selection-aware handler intercepts
        // first; bare Ctrl+C with no selection falls through to the shell
        // as SIGINT.
        .c, .v => ctrl != gui,
        // Scroll combos require shift (chosen so they don't conflict with
        // shell history or terminal-internal shortcuts).
        .pageup, .pagedown => shift and !ctrl and !gui,
        .up, .down, .home, .end => shift and ctrl and !gui,
        else => false,
    };
}

fn logPasteShortcutEvent(state: *const AppState, event: *const palette.event.KeyEvent, matched: bool) void {
    if (event.hidScancode() != .v and event.key != .v) return;
    const mod_bits = keymodBits(event.mod);
    runtime_log.trace(
        "paste key event key={s} scancode={s} down={} repeat={} mod=0x{x} matched={} composer_focused={} palette_composer_focused={} browser_focused={} address_focused={} modal_focus={s}",
        .{
            @tagName(event.key),
            @tagName(event.hidScancode()),
            event.down,
            event.repeat,
            mod_bits,
            matched,
            state.composer_controller.focused,
            state.composer_controller.composer.focused,
            state.isBrowserPaneFocused(),
            state.browser_controller.address_focused,
            @tagName(state.palette_modal_text_focus),
        },
    );
}

fn handleFileSearchNavigation(state: *AppState, event: *const palette.event.KeyEvent) bool {
    if (!state.composer_controller.focused) return false;
    if (!state.hasActiveFileSearch()) return false;
    if (!event.down or event.repeat) return false;

    if (event.hidScancode() == .up or (event.hidScancode() == .p and isCtrlPressed())) {
        return state.moveFileSearchSelection(-1);
    }
    if (event.hidScancode() == .down or (event.hidScancode() == .n and isCtrlPressed())) {
        return state.moveFileSearchSelection(1);
    }
    return false;
}

fn handleFileSearchAccept(state: *AppState, event: *const palette.event.KeyEvent) bool {
    if (!state.composer_controller.focused) return false;
    if (!state.hasActiveFileSearch()) return false;
    if (!event.down or event.repeat) return false;
    if (event.mod.ctrl or
        event.mod.alt or
        event.mod.super or
        event.mod.shift)
    {
        return false;
    }
    if (event.hidScancode() != .tab and event.hidScancode() != .@"return" and event.hidScancode() != .kp_enter) return false;

    _ = state.acceptPrimaryFileSearchResult();
    return true;
}

fn handlePendingThreadFollowupShortcut(state: *AppState, event: *const palette.event.KeyEvent) bool {
    if (!state.composer_controller.focused) return false;
    if (!state.hasPendingStream()) return false;
    if (!event.down or event.repeat) return false;
    if (event.hidScancode() != .tab) return false;
    if (event.mod.ctrl or
        event.mod.alt or
        event.mod.super or
        event.mod.shift)
    {
        return false;
    }

    state.queueOrSteerDraftDuringSend();
    return true;
}

fn handleWorkspaceContextMenuShortcut(state: *AppState, event: *const palette.event.KeyEvent) bool {
    if (event.hidScancode() != .application and
        !(event.hidScancode() == .f10 and event.mod.shift))
    {
        return false;
    }
    if (event.mod.ctrl or
        event.mod.alt or
        event.mod.super)
    {
        return false;
    }
    return workspace_panes_ui.openFocusedChatPaneContextMenu(state);
}

fn handleGuiChatShortcut(
    state: *AppState,
    keyboard: *const keybinds.NativeKeyboardConfig,
    event: *const palette.event.KeyEvent,
) bool {
    const action = keyboard.chatActionForEvent(event) orelse return false;
    return handleGuiChatAction(state, action);
}

fn handleGuiChatAction(state: *AppState, action: keybinds.NativeChatAction) bool {
    if (state.terminal_controller.focused or state.isBrowserPaneFocused() or state.browser_controller.address_focused) return false;
    if (state.focusedWorkspacePaneKind() != .chat and state.focusedWorkspaceChatPaneId() == null) return false;
    switch (action) {
        .model_picker => state.togglePaletteModelPickerFromShortcut(),
        .run_config => state.toggleRunConfigPopoverFromShortcut(),
        .directory_picker => state.togglePaletteDirectoryPickerFromShortcut(),
    }
    return true;
}

fn disarmPrefix(state: *AppState) void {
    if (!state.prefix_armed and !state.prefix_help_visible) return;
    state.prefix_armed = false;
    state.prefix_help_visible = false;
    state.resetPrefixHelpInteraction();
    state.markDirty();
}

fn exitPrefixNavigate(state: *AppState) void {
    if (!state.prefix_navigate) return;
    state.prefix_navigate = false;
    state.prefix_help_visible = false;
    state.resetPrefixHelpInteraction();
    state.markDirty();
}

/// Workspace action menu: a bound action closes it, while unbound keys and modifiers leave it open.
fn handleNavigateKeyDown(
    state: *AppState,
    keyboard: *keybinds.NativeKeyboardConfig,
    event: *const palette.event.KeyEvent,
) bool {
    if (!event.down) return true;
    if (isModifierOnlyKey(event.hidScancode())) return true;
    if (state.prefix_help_visible and handlePrefixHelpKeyDown(state, keyboard, event)) return true;
    if (event.key == .escape) {
        exitPrefixNavigate(state);
        return true;
    }
    if (keyboard.isPrefixKeyEvent(event)) {
        exitPrefixNavigate(state);
        state.prefix_armed = true;
        state.markDirty();
        return true;
    }
    const target = keyboard.navigateTargetForEvent(event) orelse return true;
    state.prefix_swallow_text_input = true;
    exitPrefixNavigate(state);
    if (target != .navigate) dispatchPrefixTarget(state, keyboard, target);
    return true;
}

fn isModifierOnlyKey(scancode: palette.keyboard.Scancode) bool {
    return switch (scancode) {
        .lshift, .rshift, .lctrl, .rctrl, .lalt, .ralt, .lgui, .rgui => true,
        else => false,
    };
}

/// Second half of a tmux-style chord. Always consumes the key; the
/// send-prefix case (prefix pressed twice) is delivered straight to the
/// focused terminal here rather than falling through, because the normal
/// chain would just re-arm on the same chord.
fn handleArmedPrefixKeyDown(
    state: *AppState,
    keyboard: *keybinds.NativeKeyboardConfig,
    event: *const palette.event.KeyEvent,
) bool {
    if (!event.down) return true;
    // Holding Shift/Ctrl for the second key must not cancel the chord.
    if (isModifierOnlyKey(event.hidScancode())) return true;
    if (state.prefix_help_visible and handlePrefixHelpKeyDown(state, keyboard, event)) return true;
    if (event.repeat) return true;
    disarmPrefix(state);
    if (keyboard.isPrefixKeyEvent(event)) {
        if (state.terminal_controller.focused) {
            const handled = state.handleTerminalKeyDown(keyboard, event);
            state.noteTerminalKeyRouting(event, handled);
        }
        return true;
    }
    if (event.key == .escape) return true;
    const target = keyboard.prefixTargetForEvent(event) orelse {
        runtime_log.trace("prefix chord unbound key=0x{x} mod=0x{x}", .{ @intFromEnum(event.key), keymodBits(event.mod) });
        return true;
    };
    state.prefix_swallow_text_input = true;
    dispatchPrefixTarget(state, keyboard, target);
    return true;
}

/// Cheat-sheet keys: `/` opens a filter, arrows move the selection and Enter
/// runs it. While the filter is open every key belongs to it (typed text
/// arrives as text_input); otherwise unclaimed keys fall through to chords.
fn handlePrefixHelpKeyDown(
    state: *AppState,
    keyboard: *keybinds.NativeKeyboardConfig,
    event: *const palette.event.KeyEvent,
) bool {
    const plain = !event.mod.shift and
        !event.mod.ctrl and
        !event.mod.alt and
        !event.mod.super;
    switch (event.key) {
        .up => ui_layout.movePrefixHelpSelection(state, .up),
        .down => ui_layout.movePrefixHelpSelection(state, .down),
        .left => ui_layout.movePrefixHelpSelection(state, .left),
        .right => ui_layout.movePrefixHelpSelection(state, .right),
        .@"return", .kp_enter => {
            if (event.repeat) return true;
            const target = ui_layout.selectedPrefixHelpTarget(state) orelse return true;
            state.prefix_swallow_text_input = true;
            const navigate = state.prefix_navigate and !state.prefix_armed;
            if (navigate) exitPrefixNavigate(state) else disarmPrefix(state);
            if (!(navigate and target == .navigate)) dispatchPrefixTarget(state, keyboard, target);
            return true;
        },
        else => {
            if (state.prefix_help_search_active) {
                switch (event.key) {
                    .escape => state.prefix_help_search_active = false,
                    .backspace => if (!state.popPrefixHelpQuery()) {
                        state.prefix_help_search_active = false;
                    },
                    // Printable keys reach the query through text_input.
                    else => return true,
                }
            } else if (event.key == .slash and plain and !event.repeat) {
                state.prefix_help_search_active = true;
                // The `/` itself must not land in the new query.
                state.prefix_swallow_text_input = true;
            } else {
                return false;
            }
        },
    }
    state.markDirty();
    return true;
}

fn dispatchPrefixTarget(state: *AppState, keyboard: *keybinds.NativeKeyboardConfig, target: keybinds.PrefixTarget) void {
    switch (target) {
        .app => |action| {
            if (action == .companion and !state.isCompanionEnabled()) return;
            switch (action) {
                .workspace_split_chat_vertical => _ = openPrefixTiledWorkspacePane(state, .chat, .vertical),
                .workspace_split_chat_horizontal => _ = openPrefixTiledWorkspacePane(state, .chat, .horizontal),
                .workspace_split_terminal_vertical => _ = openPrefixTiledWorkspacePane(state, .terminal, .vertical),
                .workspace_split_terminal_horizontal => _ = openPrefixTiledWorkspacePane(state, .terminal, .horizontal),
                else => handleKeyboardAction(state, keyboard, action),
            }
        },
        .terminal => |action| _ = state.handleTerminalAction(action),
        .chat => |action| _ = handleGuiChatAction(state, action),
        .focus_prompt => _ = state.focusPromptForFocusedChatWorkspacePane(),
        .new_terminal => _ = state.openTerminalPaneForProjectIndex(state.project_controller.selected_index),
        .split_default_vertical => _ = openPrefixTiledWorkspacePane(state, prefixSplitPaneKind(state, false), .vertical),
        .split_default_horizontal => _ = openPrefixTiledWorkspacePane(state, prefixSplitPaneKind(state, false), .horizontal),
        .split_alternate_vertical => _ = openPrefixTiledWorkspacePane(state, prefixSplitPaneKind(state, true), .vertical),
        .split_alternate_horizontal => _ = openPrefixTiledWorkspacePane(state, prefixSplitPaneKind(state, true), .horizontal),
        .show_keybinds => {
            // Cheat sheet keeps the chord live so the next key still fires.
            state.prefix_armed = true;
            state.prefix_help_visible = true;
            state.resetPrefixHelpInteraction();
            state.markDirty();
        },
        .navigate => {
            state.prefix_navigate = true;
            state.prefix_help_visible = false;
            state.markDirty();
        },
        .workspace_select => |index| _ = state.selectProjectScoped(index),
        .pane_select => |index| _ = sidebar_ui.selectOpenRowAtOrdinal(state, index),
        .active_select => |index| _ = sidebar_ui.focusAttentionClusterRowAtIndex(state, index),
        .command => |command| state.runPrefixCommand(command),
    }
}

fn handleComposerFocusShortcut(state: *AppState, event: *const palette.event.KeyEvent) bool {
    if (state.composer_controller.focused) return false;
    if (!state.isTranscriptFocused()) return false;
    if (!event.down or event.repeat) return false;
    if (event.hidScancode() != .tab) return false;
    if (event.mod.ctrl or
        event.mod.alt or
        event.mod.super or
        event.mod.shift)
    {
        return false;
    }

    state.requestComposerFocus();
    return true;
}

fn handleComposerBlurShortcut(state: *AppState, event: *const palette.event.KeyEvent) bool {
    if (!state.composer_controller.focused) return false;
    if (state.focusedWorkspaceChatPaneId() == null) return false;
    if (state.terminal_controller.focused) return false;
    if (state.isBrowserPaneFocused() or state.browser_controller.address_focused) return false;
    if (state.palette_modal_text_focus != .none) return false;
    if (!event.down or event.repeat) return false;
    if (event.hidScancode() != .escape and event.key != .escape) return false;
    if (event.mod.ctrl or
        event.mod.alt or
        event.mod.super or
        event.mod.shift)
    {
        return false;
    }

    state.blurPaletteComposer();
    state.markDirty();
    return true;
}

fn handleTranscriptMarkdownSelectAllShortcut(state: *AppState, event: *const palette.event.KeyEvent) bool {
    if (!event.down or event.repeat) return false;
    const key_is_a = event.key == .a or event.hidScancode() == .a;
    if (!key_is_a) return false;
    if (!isPrimaryModifierPressed(event.mod)) return false;
    if (state.composer_controller.focused) return false;
    if (state.terminal_controller.focused) return false;
    if (state.isBrowserPaneFocused()) return false;
    const over_transcript = state.transcript_controller.palette_mouse_in_workspace and
        chat_panel_ui.pointerOverTranscript(state.transcript_controller.palette_mouse_x, state.transcript_controller.palette_mouse_y);
    if (!state.transcript_controller.focused and !state.transcriptMarkdownSelectionActive() and !over_transcript) {
        return false;
    }
    if (!chat_panel_ui.selectAllTranscriptMarkdownInThread(state)) return false;
    state.markDirty();
    return true;
}

/// Ctrl+C copies a highlighted transcript selection. Runs before the
/// composer key route so a focused-but-selection-less composer does not
/// swallow the copy; when the composer has its own selection it wins.
fn handleTranscriptMarkdownCopyShortcut(state: *AppState, event: *const palette.event.KeyEvent) bool {
    if (!event.down or event.repeat) return false;
    if (event.key != .c) return false;
    if (!isPrimaryModifierPressed(event.mod)) return false;
    if (event.mod.shift or event.mod.alt) return false;
    if (state.composer_controller.focused and state.composer_controller.composer.selection() != null) return false;
    if (state.terminal_controller.focused) return false;
    if (state.isBrowserPaneFocused()) return false;
    if (state.browser_controller.address_focused or state.palette_modal_text_focus != .none) return false;
    if (!state.transcriptMarkdownSelectionActive()) return false;

    // Shared with the context-menu copy so the "Copied selection." toast fires.
    workspace_panes_ui.copyTranscriptSelectionToClipboard(state);
    state.markDirty();
    return true;
}

fn isCtrlPressed() bool {
    return host.isKeyDown(.lctrl) or host.isKeyDown(.rctrl);
}

fn isPrimaryModifierPressed(modifier_state: palette.event.Mods) bool {
    if (builtin.os.tag != .macos) {
        return isCtrlPressed() or modifier_state.ctrl;
    }

    return modifier_state.super;
}

fn handleKeyboardAction(
    state: *AppState,
    keyboard: *keybinds.NativeKeyboardConfig,
    action: keybinds.NativeKeyboardAction,
) void {
    switch (action) {
        .refresh => reloadApplication(state, keyboard),
        .open_default => state.openCurrentProjectEditor(.configured),
        .open_editor => state.openCurrentProjectEditor(.configured),
        .new_thread => _ = openHotkeyWorkspaceChatThread(state),
        .add_workspace => state.openAddWorkspace(true),
        .add_workspace_tab => state.addWorkspaceTab(state.project_controller.selected_index, null),
        .add_workspace_tab_terminal => state.addWorkspaceTab(state.project_controller.selected_index, .terminal),
        .command_palette => {
            const scope_project = if (state.project_controller.projects.items.len > 0 and
                state.project_controller.projects.items[state.project_controller.selected_index].workspace_layout.visiblePaneCount() == 0)
                state.project_controller.selected_index
            else
                null;
            state.openCommandPalette(scope_project);
        },
        .settings => state.openSettingsModal(),
        .companion => state.toggleCompanion(),
        .toggle_sidebar => state.toggleSidebarCollapsed(),
        .toggle_sidebar_hidden => state.toggleSidebarHidden(),
        .toggle_side_panel => state.toggleSidePanel(),
        .workspace_show_all => state.showAllWorkspacesInSidebar(),
        .toggle_browser => state.toggleBrowser(),
        .toggle_terminal => state.toggleCurrentProjectTerminal(),
        .chat_up => if (canHandleTranscriptScrollAction(state)) {
            state.requestTranscriptLineScroll(-1);
        },
        .chat_down => if (canHandleTranscriptScrollAction(state)) {
            state.requestTranscriptLineScroll(1);
        },
        .chat_page_up => if (canHandleTranscriptScrollAction(state)) {
            state.requestTranscriptPageScroll(-1);
        },
        .chat_page_down => if (canHandleTranscriptScrollAction(state)) {
            state.requestTranscriptPageScroll(1);
        },
        .workspace_previous => _ = state.selectAdjacentProject(-1),
        .workspace_next => _ = state.selectAdjacentProject(1),
        .workspace_active_previous => _ = sidebar_ui.focusAdjacentAttentionClusterRow(state, -1),
        .workspace_active_next => _ = sidebar_ui.focusAdjacentAttentionClusterRow(state, 1),
        .workspace_pane_previous => _ = sidebar_ui.focusAdjacentOpenRow(state, false, true) or state.focusCurrentProjectWorkspacePaneInSidebarOrder(-1),
        .workspace_pane_next => _ = sidebar_ui.focusAdjacentOpenRow(state, true, true) or state.focusCurrentProjectWorkspacePaneInSidebarOrder(1),
        .workspace_split_chat_vertical => _ = openHotkeyWorkspacePane(state, .chat, .vertical),
        .workspace_split_chat_horizontal => _ = openHotkeyWorkspacePane(state, .chat, .horizontal),
        .workspace_split_terminal_vertical => _ = openHotkeyWorkspacePane(state, .terminal, .vertical),
        .workspace_split_terminal_horizontal => _ = openHotkeyWorkspacePane(state, .terminal, .horizontal),
        .workspace_toggle_maximize => _ = state.toggleFocusedWorkspacePaneMaximized(),
        .workspace_toggle_quick_pane => _ = state.toggleCurrentProjectQuickPane(),
        .workspace_close => _ = state.closeFocusedWorkspacePane(),
        .workspace_close_current => if (state.project_controller.selected_index < state.project_controller.projects.items.len) state.closeProjectAtIndex(state.project_controller.selected_index),
        .workspace_focus_left => _ = workspace_panes_ui.focusPaneInDirection(state, .left),
        .workspace_focus_right => _ = workspace_panes_ui.focusPaneInDirection(state, .right),
        .workspace_focus_up => _ = workspace_panes_ui.focusPaneInDirection(state, .up),
        .workspace_focus_down => _ = workspace_panes_ui.focusPaneInDirection(state, .down),
        .workspace_move_left => _ = workspace_panes_ui.movePaneInDirection(state, .left),
        .workspace_move_right => _ = workspace_panes_ui.movePaneInDirection(state, .right),
        .workspace_move_up => _ = workspace_panes_ui.movePaneInDirection(state, .up),
        .workspace_move_down => _ = workspace_panes_ui.movePaneInDirection(state, .down),
        .workspace_grow_left => _ = workspace_panes_ui.growPaneInDirection(state, .left),
        .workspace_grow_right => _ = workspace_panes_ui.growPaneInDirection(state, .right),
        .workspace_grow_up => _ = workspace_panes_ui.growPaneInDirection(state, .up),
        .workspace_grow_down => _ = workspace_panes_ui.growPaneInDirection(state, .down),
    }
}

fn isWorkspacePaneAction(action: keybinds.NativeKeyboardAction) bool {
    return switch (action) {
        .workspace_focus_left,
        .workspace_focus_right,
        .workspace_focus_up,
        .workspace_focus_down,
        .workspace_active_previous,
        .workspace_active_next,
        .workspace_pane_previous,
        .workspace_pane_next,
        .workspace_move_left,
        .workspace_move_right,
        .workspace_move_up,
        .workspace_move_down,
        .workspace_grow_left,
        .workspace_grow_right,
        .workspace_grow_up,
        .workspace_grow_down,
        .workspace_split_chat_vertical,
        .workspace_split_chat_horizontal,
        .workspace_split_terminal_vertical,
        .workspace_split_terminal_horizontal,
        .workspace_toggle_maximize,
        .workspace_toggle_quick_pane,
        .workspace_close,
        .workspace_close_current,
        => true,
        else => false,
    };
}

fn isWorkspaceTraversalAction(action: keybinds.NativeKeyboardAction) bool {
    return switch (action) {
        .workspace_previous,
        .workspace_next,
        => true,
        else => false,
    };
}

fn handleWindowCloseRequested(window: *palette.platform.Window, state: *AppState) bool {
    if (builtin.os.tag == .macos) {
        const now_ms = currentTimeMillis();
        if (macos_cmd_w_pane_close_until_ms >= now_ms) {
            macos_cmd_w_pane_close_until_ms = 0;
            return true;
        }
        if (host.modState().super) {
            _ = state.closeFocusedWorkspacePane();
            return true;
        }
        if (macos_launch_close_suppress_until_ms >= now_ms) {
            macos_launch_close_suppress_until_ms = 0;
            runtime_log.diagnostic("ignoring window close request during macOS launch grace", .{});
            return true;
        }
    }
    if (builtin.os.tag == .linux) {
        const now_ms = currentTimeMillis();
        if (state.isPickerPending()) {
            runtime_log.diagnostic("ignoring linux window close request while folder picker is pending", .{});
            return true;
        }
        runtime_log.diagnostic(
            "linux window close request flags focus={} visible={} suspended={} selected_project={d} focused_pane={?}",
            .{
                window.hasKeyboardFocus(),
                window.isVisible(),
                window.isSuspended(),
                state.project_controller.selected_index,
                if (state.project_controller.projects.items.len > state.project_controller.selected_index) state.currentProject().workspace_layout.focused_pane_id else null,
            },
        );
        if (state.shouldSuppressExternalOpenCloseRequest(now_ms)) {
            runtime_log.diagnostic("ignoring linux window close request after external open launch", .{});
            return true;
        }
        // Focus/visibility flags describe compositor presentation, not
        // whether a Wayland WM close request is genuine. In particular,
        // address-targeted closes for windows on another workspace arrive
        // hidden or suspended and often without keyboard focus. The explicit
        // picker and external-launch guards above retain the distinguishable
        // phantom-close protections; every other WM-delivered close is actionable.
    }
    if (builtin.os.tag == .linux) {
        // The durability handoff can legitimately outlive the compositor's
        // close budget for a very large dirty projection. Remove the window
        // first, but keep all state owners alive until the handoff succeeds.
        window.hide();
        if (host.app()) |app| app.sync() catch {};
    }
    if (!closePreflightPassed(state)) {
        if (builtin.os.tag == .linux) {
            window.show();
            if (host.app()) |app| app.sync() catch {};
        }
        return true;
    }
    if (builtin.os.tag == .macos) {
        _ = state.browser_controller.runtime.controller.hide() catch {};
        window.hide();
    }
    return false;
}

// Durability boundary shared by every graceful exit request. A failed handoff
// leaves the event loop, window, and controllers live for an interactive retry.
fn closePreflightPassed(state: anytype) bool {
    const started_at_ms = currentTimeMillis();
    runtime_log.diagnostic("close durability handoff begin", .{});
    if (@hasDecl(@TypeOf(state.*), "beginClosePreflight")) state.beginClosePreflight();
    state.handoffDirtyStateForShutdown() catch |err| {
        if (@hasDecl(@TypeOf(state.*), "cancelClosePreflight")) state.cancelClosePreflight();
        state.noteCloseDurabilityFailure(err);
        runtime_log.diagnostic("close durability handoff failed elapsed_ms={d}", .{currentTimeMillis() - started_at_ms});
        return false;
    };
    runtime_log.diagnostic("close durability handoff complete elapsed_ms={d}", .{currentTimeMillis() - started_at_ms});
    return true;
}

test "close preflight keeps loop live after real handoff failure" {
    const lifecycle_controller = @import("state/lifecycle_controller.zig");
    const db_types = @import("db/types.zig");
    const FakeStorage = struct {
        allocator: std.mem.Allocator,
        save_fails: bool = true,

        pub fn currentProjectionObservedRevision(_: *const @This()) u64 {
            return 1;
        }
        pub fn saveCaptured(self: *@This(), _: db_types.PersistedState, _: u64) !void {
            if (self.save_fails) return error.StoreUnavailable;
        }
        pub fn markPersistenceUnavailable(_: *@This()) void {}
        pub fn clearPendingStateSpoolBestEffort(_: *@This()) void {}
    };
    const FakeState = struct {
        lifecycle: lifecycle_controller.State = .{},
        storage: *FakeStorage,
        close_failure_notice: bool = false,
        daemon_stale: bool = true,
        spool_fails: bool = true,

        pub fn hasUnresolvedAdoptionRows(_: *@This()) bool {
            return false;
        }
        pub fn completePendingProjectionRepairBlocking(_: *@This()) !void {}
        pub fn buildPersistedState(_: *@This(), allocator: std.mem.Allocator) !db_types.LoadedState {
            return db_types.LoadedState.init(allocator);
        }
        pub fn clonePersistedState(_: *@This(), allocator: std.mem.Allocator, _: db_types.PersistedState) !db_types.LoadedState {
            return db_types.LoadedState.init(allocator);
        }
        pub fn spoolPendingStateForShutdown(self: *@This()) !void {
            if (self.spool_fails) return error.InjectedSpoolFailure;
        }
        fn handoffDirtyStateForShutdown(self: *@This()) !void {
            try lifecycle_controller.handoffDirtyStateForShutdown(self);
        }
        fn noteCloseDurabilityFailure(self: *@This(), _: anyerror) void {
            self.close_failure_notice = true;
        }
        pub fn clearCloseDurabilityNotice(self: *@This()) void {
            self.close_failure_notice = false;
        }
        fn sidebarNotice(self: *const @This()) []const u8 {
            if (self.close_failure_notice) return "Could not close";
            if (self.daemon_stale) return "Daemon sync stalled";
            return "";
        }
    };

    var storage: FakeStorage = .{ .allocator = std.testing.allocator };
    var state: FakeState = .{ .storage = &storage };
    state.lifecycle.dirty = true;
    defer state.lifecycle.deinit();
    try std.testing.expect(!closePreflightPassed(&state));
    try std.testing.expect(state.lifecycle.dirty);
    try std.testing.expectEqualStrings("Could not close", state.sidebarNotice());
    storage.save_fails = false;
    state.spool_fails = false;
    try std.testing.expect(closePreflightPassed(&state));
    try std.testing.expectEqualStrings("Daemon sync stalled", state.sidebarNotice());
}

test "successful event close preflight skips later frame polls" {
    const FakeState = struct {
        dirty_poll_executed: bool = false,

        fn handoffDirtyStateForShutdown(_: *@This()) !void {}
        fn noteCloseDurabilityFailure(_: *@This(), _: anyerror) void {}
        fn dirtyPoll(self: *@This()) void {
            self.dirty_poll_executed = true;
        }
    };

    const source = @embedFile("main.zig");
    const event_assignment = std.mem.indexOf(u8, source, "running = processEvents(").?;
    const frame_break = std.mem.indexOf(u8, source[event_assignment..], "if (!running) break;").?;
    const first_poll = std.mem.indexOf(u8, source[event_assignment..], "app_state.processDeferredProjectDirectoryBrowse();").?;
    try std.testing.expect(frame_break < first_poll);

    var state: FakeState = .{};
    const running_after_close_event = !closePreflightPassed(&state);
    if (running_after_close_event) state.dirtyPoll();
    try std.testing.expect(!state.dirty_poll_executed);
}

test "startup frame is submitted before the durable projection load" {
    const source = @embedFile("main.zig");
    const window_created = std.mem.indexOf(u8, source, "app.createWindow(").?;
    const early_show = window_created + std.mem.indexOf(u8, source[window_created..], "window.show();").?;
    const renderer_init = std.mem.indexOf(u8, source, "var palette_renderer = try").?;
    const startup_frame = std.mem.indexOf(u8, source, "renderStartupFrame(&palette_renderer").?;
    const app_state_load = std.mem.indexOf(u8, source, "var state = try AppState.init").?;
    try std.testing.expect(early_show < renderer_init);
    try std.testing.expect(startup_frame < app_state_load);
}

test "runtime service attaches after AppState reaches stable storage" {
    const source = @embedFile("main.zig");
    const app_state_load = std.mem.indexOf(u8, source, "var state = try AppState.init").?;
    const runtime_attach = std.mem.indexOf(u8, source, "attachRuntimeService(&state, allocator, init.io)").?;
    const defaults_load = std.mem.indexOf(u8, source, "state.loadWorkspaceRuntimeDefaults()").?;
    try std.testing.expect(app_state_load < runtime_attach);
    try std.testing.expect(runtime_attach < defaults_load);
}

test "runtime onboarding modals own keys before obscured terminal and prefix routes" {
    const source = @embedFile("main.zig");
    const runtime_modal_route = std.mem.indexOf(
        u8,
        source,
        "if ((state.runtimeCredentialModalOpen() or state.runtimeTrustProposal() != null)",
    ).?;
    const terminal_selection_route = std.mem.indexOfPos(
        u8,
        source,
        runtime_modal_route,
        "terminal_panel_ui.handlePaletteKeyDown",
    ).?;
    const prefix_route = std.mem.indexOfPos(
        u8,
        source,
        runtime_modal_route,
        "state.prefix_armed and handleArmedPrefixKeyDown",
    ).?;
    try std.testing.expect(runtime_modal_route < terminal_selection_route);
    try std.testing.expect(runtime_modal_route < prefix_route);
}

test "visual presentation and Linux window removal precede durability work" {
    const source = @embedFile("main.zig");
    const frame_submit = std.mem.indexOf(u8, source, "state.noteBrowserFramePresented();").?;
    const frame_flush = std.mem.indexOf(u8, source, "app_state.flushIfDirty();").?;
    try std.testing.expect(frame_submit < frame_flush);

    const linux_close = std.mem.indexOf(u8, source, "The durability handoff can legitimately outlive").?;
    const hide_window = linux_close + std.mem.indexOf(u8, source[linux_close..], "window.hide();").?;
    const close_handoff = linux_close + std.mem.indexOf(u8, source[linux_close..], "if (!closePreflightPassed(state))").?;
    try std.testing.expect(hide_window < close_handoff);
}

test "frame pacing tiers pace status pulses at 30fps and idle background sends" {
    // Tier inversion fix: a status-animating pane paces the 33ms pip tier,
    // never the 16ms active tier. This must be a *continuous* interval, not
    // only a wake timeout — a wake timeout bounds event-wait latency but
    // guarantees no repaint cadence, which visibly freezes the pulse.
    try std.testing.expectEqual(@as(i64, PIP_PULSE_WAIT_TIMEOUT_MS), continuousFrameIntervalForActivity(.{ .pane_status_animating = true }));
    try std.testing.expectEqual(@as(c_int, PIP_PULSE_WAIT_TIMEOUT_MS), eventWaitBaseTimeoutForActivity(.{ .pane_status_animating = true }));
    // The same working pane in a non-visible workspace (or with reduced
    // motion on) never sets pane_status_animating — workspace_panes.zig only
    // arms it while rendering a visible, motion-enabled pane — so background
    // work must not pin continuous rendering: a pending send alone renders
    // event-driven, but keeps the 30fps wake because daemon-owned turns
    // stream by polling on loop wakes.
    try std.testing.expectEqual(@as(i64, 0), continuousFrameIntervalForActivity(.{ .pending_send = true }));
    try std.testing.expectEqual(@as(i64, 0), continuousFrameIntervalForActivity(.{ .pending_send = true, .background_tasks = true }));
    try std.testing.expectEqual(@as(c_int, PENDING_SEND_WAIT_TIMEOUT_MS), eventWaitBaseTimeoutForActivity(.{ .pending_send = true }));
    // A pulsing pip on the current workspace still animates continuously.
    try std.testing.expectEqual(@as(i64, PIP_PULSE_WAIT_TIMEOUT_MS), continuousFrameIntervalForActivity(.{ .sidebar_pulse = true, .pending_send = true }));
    // The browser pins the display-rate wake only when it is in the current
    // workspace; elsewhere new frames arrive by loop_wakeup push.
    try std.testing.expectEqual(@as(c_int, ACTIVE_WAIT_TIMEOUT_MS), eventWaitBaseTimeoutForActivity(.{ .browser_visible = true }));
    try std.testing.expectEqual(@as(c_int, IDLE_WAIT_TIMEOUT_MS), eventWaitBaseTimeoutForActivity(.{}));
    // Active continuous animations (focus flash, sidebar slide, …) keep 16ms.
    try std.testing.expectEqual(@as(i64, ACTIVE_WAIT_TIMEOUT_MS), continuousFrameIntervalForActivity(.{ .active_continuous = true }));
}

fn noteMacosWorkspaceCloseShortcut(event: *const palette.event.KeyEvent, action: keybinds.NativeKeyboardAction) void {
    if (builtin.os.tag != .macos or action != .workspace_close) return;
    if (event.key != .w) return;
    if (!event.mod.super) return;
    if (event.mod.ctrl or
        event.mod.alt or
        event.mod.shift)
    {
        return;
    }
    macos_cmd_w_pane_close_until_ms = currentTimeMillis() + MACOS_CMD_W_CLOSE_SUPPRESS_MS;
}

fn currentTimeMillis() i64 {
    return platform_runtime.unixTimestampMs();
}

var termination_signal_requested: std.atomic.Value(bool) = .init(false);

/// SIGINT/SIGTERM request the same graceful, durability-checked exit as a
/// window close. The platform layer's own handling (signalfd plus a blocked
/// mask) stays off on POSIX because a blocked mask is inherited by the shells
/// and the session daemon Verde forks; Windows uses the platform's console
/// control handler instead.
fn installTerminationSignalHandlers() void {
    if (builtin.os.tag == .windows) return;
    const action: std.posix.Sigaction = .{
        .handler = .{ .handler = handleTerminationSignal },
        .mask = std.posix.sigemptyset(),
        .flags = std.posix.SA.RESTART,
    };
    std.posix.sigaction(.INT, &action, null);
    std.posix.sigaction(.TERM, &action, null);
}

fn handleTerminationSignal(_: std.posix.SIG) callconv(.c) void {
    // Async-signal-safe: a single atomic store. The main loop's event wait is
    // always bounded, so the flag is observed within one idle tick.
    termination_signal_requested.store(true, .release);
}

fn consumeTerminationSignal() bool {
    return termination_signal_requested.swap(false, .acq_rel);
}

fn desktopAppId() []const u8 {
    if (std.c.getenv("VERDE_APP_ID")) |value| {
        const id = std.mem.sliceTo(value, 0);
        if (id.len > 0) return id;
    }
    return DEFAULT_APP_ID;
}

fn readMacosClipboardImage(allocator: std.mem.Allocator) anyerror!?utils.ClipboardImageCapture {
    if (builtin.os.tag != .macos) {
        return null;
    } else {
        const app = host.app() orelse return null;
        const image = try app.getClipboardImage(allocator) orelse return null;
        return .{ .bytes = image.bytes, .mime = image.mime };
    }
}

fn postLoopWakeup(ctx: *anyopaque, value: u64) void {
    const app: *palette.platform.App = @ptrCast(@alignCast(ctx));
    app.wakeup(value);
}

fn activateMacosHostWindow(window: *palette.platform.Window) void {
    if (builtin.os.tag != .macos) return;
    window.show();
    window.activate("");
    if (host.app()) |app| app.sync() catch {};
}

fn macosNativeBrowserShouldOwnKeyboard(state: *AppState) bool {
    if (builtin.os.tag != .macos) return false;
    if (!state.isBrowserVisible() or !state.isBrowserPaneFocused()) return false;
    if (!state.browserPaneUsesNativeKeyboardSurface()) return false;
    if (state.composer_controller.composer.focused or state.composer_controller.focused) return false;
    if (state.browser_controller.address_focused or state.palette_modal_text_focus != .none) return false;
    return true;
}

fn macosBrowserClickWillFocusNativeSurface(state: *const AppState, x: f32, y: f32) bool {
    if (builtin.os.tag != .macos) return false;
    if (!state.isBrowserVisible()) return false;
    if (!state.browserPaneUsesNativeKeyboardSurface()) return false;
    if (state.palette_modal_text_focus != .none) return false;
    return state.browserPaneContains(x, y);
}

fn handleFontSizeShortcut(state: *AppState, event: *const palette.event.KeyEvent) bool {
    if (!event.down or event.repeat) return false;
    if (state.terminal_controller.focused) return false;
    if (!isPrimaryModifierPressed(event.mod)) return false;
    const delta: f32 = switch (event.key) {
        .kp_plus, .equals => 1.0,
        .minus, .kp_minus => -1.0,
        // Layouts with an unshifted '+' key (SDLK_PLUS under SDL).
        .character => if (event.shortcutCodepoint() == '+') 1.0 else return false,
        else => return false,
    };
    const current = state.app_config.font_size;
    const next = clampf(current + delta, app_config.MIN_FONT_SIZE, app_config.MAX_FONT_SIZE);
    if (@abs(next - current) < 0.01) return true;
    state.app_config.font_size = next;
    ui_theme.installFonts(
        CAL_SANS_BYTES[0..CAL_SANS_BYTES.len],
        NOTO_SANS_BOLD_BYTES[0..NOTO_SANS_BOLD_BYTES.len],
        NOTO_SANS_ITALIC_BYTES[0..NOTO_SANS_ITALIC_BYTES.len],
        NOTO_SANS_BOLD_ITALIC_BYTES[0..NOTO_SANS_BOLD_ITALIC_BYTES.len],
        CODICON_BYTES[0..CODICON_BYTES.len],
        NERD_SYMBOLS_BYTES[0..NERD_SYMBOLS_BYTES.len],
        next,
    );
    state.markDirty();
    return true;
}

fn canHandleTranscriptScrollAction(state: *const AppState) bool {
    if (state.project_controller.projects.items.len == 0) return false;
    if (state.isBrowserPaneFocused()) return false;
    if (state.terminal_controller.focused) return false;
    return !state.composer_controller.focused and state.palette_modal_text_focus == .none;
}

/// Reads the OS light/dark preference into the theme module. Unknown (for
/// example no appearance portal on Linux) keeps dark. Returns true on change.
fn syncSystemAppearance() bool {
    // Unknown (always the case on Wayland) keeps the dark default, as SDL's
    // SDL_SYSTEM_THEME_UNKNOWN did.
    const theme = if (host.app()) |app| app.systemTheme() else .unknown;
    const appearance: ui_theme.Appearance = if (theme == .light) .light else .dark;
    return ui_theme.setSystemAppearance(appearance);
}

fn applyAppConfigRuntime(state: *AppState) void {
    runtime_log.trace("apply app config runtime begin theme={s} font={d:.2} terminal_font={d:.2}", .{
        @tagName(state.app_config.theme_config.source),
        state.app_config.font_size,
        state.app_config.terminal_font_size,
    });
    ui_theme.applyConfigTheme(state.allocator, state.app_config.theme_config);
    ui_theme.installFonts(
        CAL_SANS_BYTES[0..CAL_SANS_BYTES.len],
        NOTO_SANS_BOLD_BYTES[0..NOTO_SANS_BOLD_BYTES.len],
        NOTO_SANS_ITALIC_BYTES[0..NOTO_SANS_ITALIC_BYTES.len],
        NOTO_SANS_BOLD_ITALIC_BYTES[0..NOTO_SANS_BOLD_ITALIC_BYTES.len],
        CODICON_BYTES[0..CODICON_BYTES.len],
        NERD_SYMBOLS_BYTES[0..NERD_SYMBOLS_BYTES.len],
        state.app_config.font_size,
    );
    state.applyTerminalFontSizesFromConfig();
    state.rethemeTerminalSessions() catch |err| {
        log.warn("failed to retheme terminal sessions: {s}", .{@errorName(err)});
    };
    // An armed browser inspector carries theme colors into the page; re-arm
    // so its overlay picks up the refreshed palette.
    if (state.browser_controller.runtime.inspectorEnabled() and state.canUseBrowserInspector() and state.isBrowserVisible()) {
        state.enableBrowserInspector(false);
    }
    state.markDirty();
    runtime_log.trace("apply app config runtime done", .{});
}

fn pollAppConfigFileChanges(state: *AppState, keyboard: *keybinds.NativeKeyboardConfig) void {
    const next_mtime = app_config.configFileMtime(state.allocator) catch return;
    if (state.app_config_file_mtime < 0) {
        state.app_config_file_mtime = next_mtime;
        return;
    }
    if (next_mtime == state.app_config_file_mtime) return;

    // Prefix bindings live in the same file as ui/theme. Reloading only
    // AppConfig left `keybinds.prefix.bindings` stale after an in-app edit.
    reloadApplication(state, keyboard);
}

/// Follows `omarchy-theme-set` live while the Omarchy source is selected, the
/// way Omarchy's own apps retint on a theme switch, so no Ctrl+R is needed.
fn pollOmarchyThemeChanges(state: *AppState) void {
    if (!ui_theme.omarchyThemeChanged(state.allocator, state.app_config.theme_config)) return;
    log.info("omarchy theme changed; reapplying palette", .{});
    applyAppConfigRuntime(state);
}

fn reloadApplication(state: *AppState, keyboard: *keybinds.NativeKeyboardConfig) void {
    const next_keyboard = keybinds.NativeKeyboardConfig.load(state.allocator) catch |err| {
        log.err("failed to refresh native keybinds: {s}", .{@errorName(err)});
        state.setSidebarNotice("Refresh failed: keybinds did not reload.");
        return;
    };
    const next_app_config = app_config.loadAppConfig(state.allocator) catch |err| {
        log.err("failed to refresh native app config: {s}", .{@errorName(err)});
        keyboard.deinit();
        keyboard.* = next_keyboard;
        state.setSidebarNotice("Refresh failed: config did not reload.");
        return;
    };
    keyboard.deinit();
    keyboard.* = next_keyboard;
    ui_theme.applyConfigTheme(state.allocator, next_app_config.theme_config);
    state.replaceAppConfig(next_app_config);
    state.app_config_file_mtime = app_config.configFileMtime(state.allocator) catch state.app_config_file_mtime;
    applyAppConfigRuntime(state);
    state.setSidebarNotice("Config, keybinds, and theme refreshed.");
}

/// The default build retains its existing backend. Optional native composition
/// transfers ownership only after the service attachment succeeds.
fn attachRuntimeService(app: *AppState, allocator: std.mem.Allocator, io: std.Io) !void {
    const integration: ?AppState.RuntimeIntegration = if (@import("runtime_integration_mode").enabled)
        try @import("runtime_integration").create(AppState, @import("runtime/connect_client.zig"), @import("runtime/manager.zig"), @import("runtime/connection.zig").TransportError, utils.openUrlInDefaultBrowser, allocator, io)
    else
        null;
    errdefer if (integration) |value| value.release_owner(value.context);
    try app.attachRuntimeServiceWithIntegration(io, integration);
}

/// Dev hook for isolated trials on a shared desktop (e.g. a Mac with a person
/// at the console): `VERDE_PALETTE_WINDOW=WxH[+X+Y]` opens a small window at a
/// fixed spot instead of one sized to the work area.
fn windowFrameOverrideFromEnv() ?WindowFrame {
    const value = std.c.getenv("VERDE_PALETTE_WINDOW") orelse return null;
    return parseWindowFrameOverride(std.mem.sliceTo(value, 0));
}

/// Parses `WxH` or `WxH+X+Y` (logical units). Null when malformed.
fn parseWindowFrameOverride(spec: []const u8) ?WindowFrame {
    var parts = std.mem.splitScalar(u8, spec, '+');
    const size = parts.next() orelse return null;
    const x_index = std.mem.indexOfScalar(u8, size, 'x') orelse return null;
    const w = std.fmt.parseInt(c_int, size[0..x_index], 10) catch return null;
    const h = std.fmt.parseInt(c_int, size[x_index + 1 ..], 10) catch return null;
    if (w < 200 or h < 150) return null;
    const x = if (parts.next()) |text| std.fmt.parseInt(c_int, text, 10) catch return null else 0;
    const y = if (parts.next()) |text| std.fmt.parseInt(c_int, text, 10) catch return null else 0;
    if (parts.next() != null) return null;
    return .{ .x = x, .y = y, .w = w, .h = h };
}

test "window frame override parses size and optional position" {
    const sized = parseWindowFrameOverride("900x600").?;
    try std.testing.expectEqual(@as(c_int, 900), sized.w);
    try std.testing.expectEqual(@as(c_int, 600), sized.h);
    try std.testing.expectEqual(@as(c_int, 0), sized.x);
    const placed = parseWindowFrameOverride("960x640+40+60").?;
    try std.testing.expectEqual(@as(c_int, 40), placed.x);
    try std.testing.expectEqual(@as(c_int, 60), placed.y);
    try std.testing.expect(parseWindowFrameOverride("") == null);
    try std.testing.expect(parseWindowFrameOverride("900") == null);
    try std.testing.expect(parseWindowFrameOverride("10x10") == null);
    try std.testing.expect(parseWindowFrameOverride("900x600+1+2+3") == null);
}

test "idle wait timeouts still poll the snapshot and inject dev hooks" {
    // macOS delivers no events to an idle window, so returning early on a wait
    // timeout left VERDE_PALETTE_SNAPSHOT / VERDE_PALETTE_INJECT requests unread.
    const source = @embedFile("main.zig");
    const timeout = std.mem.indexOf(u8, source, "wait_trace.reason = .wait_timeout;").?;
    const branch_end = std.mem.indexOfScalar(u8, source[timeout..], '}').?;
    try std.testing.expect(std.mem.indexOf(u8, source[timeout..][0..branch_end], "return pollDevHooks(") != null);
}

test "macOS text input is not deduplicated by arrival time" {
    // The palette AppKit backend emits one text_input per keyDown (via
    // NSTextInputClient). The SDL-era 30 ms duplicate filter dropped real
    // keystrokes: "ll" handled in one loop iteration, or key repeat at the
    // fastest macOS rate, lost every second character.
    const source = @embedFile("main.zig");
    const needle = "suppressDuplicate" ++ "MacosTextInput";
    try std.testing.expect(std.mem.indexOf(u8, source, needle) == null);
}
