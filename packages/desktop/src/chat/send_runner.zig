//! UI-independent provider send runner used by daemon-owned chat turns.

const std = @import("std");
const harness = @import("../harness.zig");

const log = std.log.scoped(.chat_send_runner);

pub const FastMode = enum { off, on };
pub const AccessMode = enum { supervised, full_access };

pub const Request = struct {
    provider: harness.Provider,
    harness_kind: harness.HarnessKind,
    project_path: []const u8,
    prompt: []const u8,
    image_paths: []const []const u8 = &.{},
    provider_thread_id: ?[]const u8 = null,
    thread_title: []const u8 = "",
    model_ref: ?[]const u8 = null,
    reasoning_effort: ?harness.ReasoningEffort = null,
    opencode_reasoning_variant: ?[]const u8 = null,
    cursor_model_params_json: ?[]const u8 = null,
    fast_mode: FastMode = .off,
    access_mode: AccessMode = .full_access,
    remote_ssh_host: ?[]const u8 = null,
    remote_cwd: ?[]const u8 = null,
};

pub const Result = struct {
    provider_thread_id: []const u8,
    reply_text: []const u8,
};

pub const Sink = struct {
    context: ?*anyopaque = null,
    on_thread_id: ?*const fn (?*anyopaque, []const u8) void = null,
    on_turn_id: ?*const fn (?*anyopaque, []const u8) void = null,
    on_stream_delta: ?*const fn (?*anyopaque, []const u8) void = null,
    on_stream_event: ?*const fn (?*anyopaque, harness.StreamEvent) void = null,
    on_failure: ?*const fn (?*anyopaque, []const u8) void = null,
    on_should_stop: ?*const fn (?*anyopaque) bool = null,
    on_approval_request: ?*const fn (?*anyopaque, harness.ApprovalRequest) harness.ApprovalDecision = null,
};

pub fn run(allocator: std.mem.Allocator, request: Request, sink: Sink) !Result {
    if (request.harness_kind != .local_cli) return error.UnsupportedHarnessMode;
    if (request.remote_ssh_host != null and request.provider != .codex) return error.UnsupportedRemoteProvider;

    const request_cwd = request.remote_cwd orelse request.project_path;
    const provider_config = switch (request.provider) {
        .opencode => harness.ProviderConfig{ .opencode = .{
            .allocator = allocator,
            .working_directory = request_cwd,
            .launch_if_missing = true,
        } },
        .codex => harness.ProviderConfig{ .codex = .{
            .cwd = request_cwd,
            .launch_on_connect = true,
            .remote_ssh = if (request.remote_ssh_host) |host| .{ .host = host, .cwd = request_cwd } else null,
        } },
        .claude => harness.ProviderConfig{ .claude = .{ .cwd = request_cwd } },
        .cursor => harness.ProviderConfig{ .cursor = .{ .cwd = request_cwd, .model = request.model_ref } },
    };

    log.info("send starting provider={s} cwd={s} model_len={d} thread_id_len={d} prompt_len={d}", .{
        @tagName(request.provider),
        request_cwd,
        if (request.model_ref) |model| model.len else 0,
        if (request.provider_thread_id) |thread_id| thread_id.len else 0,
        request.prompt.len,
    });

    var client = try harness.connect(allocator, provider_config);
    defer client.deinit();

    const image_attachments = try allocator.alloc(harness.types.ImageAttachment, request.image_paths.len);
    defer allocator.free(image_attachments);
    for (request.image_paths, 0..) |path, index| image_attachments[index] = .{ .path = path };

    const send_result = try client.sendPrompt(allocator, .{
        .thread_id = request.provider_thread_id,
        .thread_title = request.thread_title,
        .prompt = request.prompt,
        .image = if (request.image_paths.len > 0) .{ .path = request.image_paths[0] } else null,
        .images = image_attachments,
        .cwd = request_cwd,
        .model = request.model_ref,
        .opencode_variant = if (request.provider == .opencode) request.opencode_reasoning_variant else null,
        .cursor_model_params_json = if (request.provider == .cursor) request.cursor_model_params_json else null,
        .reasoning_effort = if (request.provider == .opencode and request.opencode_reasoning_variant != null) null else request.reasoning_effort,
        .service_tier = serviceTierForMode(request.provider, request.fast_mode),
        .approval_policy = approvalPolicyForMode(request.access_mode),
        .sandbox_mode = sandboxModeForMode(request.provider, request.access_mode),
        .stream_context = sink.context,
        .on_thread_id = sink.on_thread_id,
        .on_turn_id = sink.on_turn_id,
        .on_stream_delta = sink.on_stream_delta,
        .on_stream_event = sink.on_stream_event,
        .on_failure = sink.on_failure,
        .on_should_stop = sink.on_should_stop,
        .on_approval_request = sink.on_approval_request,
    });

    return .{ .provider_thread_id = send_result.thread_id, .reply_text = send_result.reply_text };
}

fn approvalPolicyForMode(mode: AccessMode) ?harness.ApprovalPolicy {
    return switch (mode) {
        .full_access => .never,
        .supervised => .on_request,
    };
}

fn serviceTierForMode(provider: harness.Provider, fast_mode: FastMode) ?harness.ServiceTier {
    if (provider != .codex) return null;
    return switch (fast_mode) {
        .on => .fast,
        .off => null,
    };
}

fn sandboxModeForMode(provider: harness.Provider, mode: AccessMode) ?harness.SandboxMode {
    if (provider != .codex and provider != .claude) return null;
    return switch (mode) {
        .full_access => .danger_full_access,
        .supervised => .workspace_write,
    };
}
