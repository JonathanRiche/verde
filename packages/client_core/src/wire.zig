//! Local revision-1 wire shapes. Tagged unions are flattened by the native codecs.
//! Engine state is deliberately excluded; counters on the wire are decimal strings.
const std = @import("std");
const host = @import("host.zig");
pub const Config = host.Config;
pub const Lifecycle = host.Lifecycle;
pub const LocalError = host.LocalError;
pub const Operation = host.Operation;
pub const TransportFailure = host.TransportFailure;
pub const PlatformFailure = host.PlatformFailure;
pub const Header = struct { name: []const u8, value: []const u8 };
pub const Tls = struct { origin: []const u8, spki_sha256: []const u8 };
pub const VtModes = struct { application_cursor: bool, bracketed_paste: bool };
pub const AttachmentInput = struct { local_id: []const u8, name: []const u8, mime: []const u8, byte_size: []const u8, bytes_base64: []const u8 };
pub const Event = union(enum) {
    sign_out: struct { api_version: u32 = 1, now_ms: i64, wall_time_ms: i64, intent_id: []const u8, host_id: []const u8 },
    forget_host: struct { api_version: u32 = 1, now_ms: i64, wall_time_ms: i64, intent_id: []const u8, host_id: []const u8 },
    start: struct { api_version: u32 = 1, now_ms: i64, wall_time_ms: i64, foreground: bool, network_available: bool },
    foreground: struct { api_version: u32 = 1, now_ms: i64, wall_time_ms: i64 },
    background: struct { api_version: u32 = 1, now_ms: i64, wall_time_ms: i64 },
    shutdown: struct { api_version: u32 = 1, now_ms: i64, wall_time_ms: i64 },
    network_changed: struct { api_version: u32 = 1, now_ms: i64, wall_time_ms: i64, available: bool, network_id: []const u8 },
    http_response: struct { api_version: u32 = 1, now_ms: i64, wall_time_ms: i64, effect_id: []const u8, generation: []const u8, status: ?u16, headers: []const Header, body_base64: ?[]const u8, @"error": ?TransportFailure },
    ws_open: struct { api_version: u32 = 1, now_ms: i64, wall_time_ms: i64, socket_id: []const u8, generation: []const u8, protocol: []const u8 },
    ws_message: struct { api_version: u32 = 1, now_ms: i64, wall_time_ms: i64, socket_id: []const u8, generation: []const u8, text: []const u8 },
    ws_closed: struct { api_version: u32 = 1, now_ms: i64, wall_time_ms: i64, socket_id: []const u8, generation: []const u8, code: ?u16, clean: bool, @"error": ?TransportFailure },
    timer_fired: struct { api_version: u32 = 1, now_ms: i64, wall_time_ms: i64, timer_id: []const u8, generation: []const u8 },
    secure_store_value: struct { api_version: u32 = 1, now_ms: i64, wall_time_ms: i64, effect_id: []const u8, generation: []const u8, key: []const u8, value_base64: ?[]const u8, @"error": ?PlatformFailure },
    secure_store_done: struct { api_version: u32 = 1, now_ms: i64, wall_time_ms: i64, effect_id: []const u8, generation: []const u8, key: []const u8, @"error": ?PlatformFailure },
    tls_peer: struct { api_version: u32 = 1, now_ms: i64, wall_time_ms: i64, effect_id: []const u8, generation: []const u8, origin: []const u8, spki_sha256: []const u8, system_trusted: bool },
    terminal_applied: struct { api_version: u32 = 1, now_ms: i64, wall_time_ms: i64, effect_id: []const u8, generation: []const u8, terminal_id: []const u8, grid_revision: []const u8, @"error": ?PlatformFailure },
    terminal_reply: struct { api_version: u32 = 1, now_ms: i64, wall_time_ms: i64, terminal_id: []const u8, bytes_base64: []const u8 },
    pair: struct { api_version: u32 = 1, now_ms: i64, wall_time_ms: i64, intent_id: []const u8, link: []const u8, device_label: []const u8, client_nonce: []const u8 },
    trust_decision: struct { api_version: u32 = 1, now_ms: i64, wall_time_ms: i64, intent_id: []const u8, proposal_id: []const u8, accept: bool },
    retry_connection: struct { api_version: u32 = 1, now_ms: i64, wall_time_ms: i64, intent_id: []const u8 },
    focus: struct { api_version: u32 = 1, now_ms: i64, wall_time_ms: i64, intent_id: []const u8, workspace_id: ?[]const u8, thread_id: ?[]const u8, terminal_id: ?[]const u8 },
    history_search: struct { api_version: u32 = 1, now_ms: i64, wall_time_ms: i64, intent_id: []const u8, query: []const u8, workspace_id: ?[]const u8 },
    history_load_more: struct { api_version: u32 = 1, now_ms: i64, wall_time_ms: i64, intent_id: []const u8 },
    shell_confirm: struct { api_version: u32 = 1, now_ms: i64, wall_time_ms: i64, intent_id: []const u8, confirmation_id: []const u8, accept: bool },
    terminal_create: struct { api_version: u32 = 1, now_ms: i64, wall_time_ms: i64, intent_id: []const u8, workspace_id: []const u8, cwd: ?[]const u8, cols: u16, rows: u16 },
    thread_open: struct { api_version: u32 = 1, now_ms: i64, wall_time_ms: i64, intent_id: []const u8, workspace_id: []const u8, thread_id: []const u8 },
    thread_load_older: struct { api_version: u32 = 1, now_ms: i64, wall_time_ms: i64, intent_id: []const u8, workspace_id: []const u8, thread_id: []const u8 },
    draft_set: struct { api_version: u32 = 1, now_ms: i64, wall_time_ms: i64, intent_id: []const u8, workspace_id: []const u8, thread_id: []const u8, text: []const u8, attachments: []const AttachmentInput },
    composer_select: struct { api_version: u32 = 1, now_ms: i64, wall_time_ms: i64, intent_id: []const u8, workspace_id: []const u8, thread_id: []const u8, provider: ?[]const u8, model: ?[]const u8, effort: ?[]const u8, access: ?[]const u8, speed: ?[]const u8 },
    send: struct { api_version: u32 = 1, now_ms: i64, wall_time_ms: i64, intent_id: []const u8, workspace_id: []const u8, thread_id: []const u8, draft_revision: []const u8 },
    turn_cancel: struct { api_version: u32 = 1, now_ms: i64, wall_time_ms: i64, intent_id: []const u8, workspace_id: []const u8, thread_id: []const u8, turn_id: []const u8 },
    followup_submit: struct { api_version: u32 = 1, now_ms: i64, wall_time_ms: i64, intent_id: []const u8, workspace_id: []const u8, thread_id: []const u8, draft_revision: []const u8, kind: enum { queue, steer } },
    followup_retry: struct { api_version: u32 = 1, now_ms: i64, wall_time_ms: i64, intent_id: []const u8, workspace_id: []const u8, thread_id: []const u8, followup_id: []const u8 },
    followup_pull_back: struct { api_version: u32 = 1, now_ms: i64, wall_time_ms: i64, intent_id: []const u8, workspace_id: []const u8, thread_id: []const u8, followup_id: []const u8 },
    followup_cancel: struct { api_version: u32 = 1, now_ms: i64, wall_time_ms: i64, intent_id: []const u8, workspace_id: []const u8, thread_id: []const u8, followup_id: []const u8 },
    approval_decide: struct { api_version: u32 = 1, now_ms: i64, wall_time_ms: i64, intent_id: []const u8, workspace_id: []const u8, thread_id: []const u8, turn_id: []const u8, call_id: []const u8, decision: enum { approve, deny } },
    shell_prepare: struct { api_version: u32 = 1, now_ms: i64, wall_time_ms: i64, intent_id: []const u8, workspace_id: []const u8, thread_id: []const u8, command: []const u8 },
    slash_search: struct { api_version: u32 = 1, now_ms: i64, wall_time_ms: i64, intent_id: []const u8, workspace_id: []const u8, thread_id: []const u8, query: []const u8 },
    slash_run: struct { api_version: u32 = 1, now_ms: i64, wall_time_ms: i64, intent_id: []const u8, workspace_id: []const u8, thread_id: []const u8, command: []const u8, args: []const u8 },
    mention_search: struct { api_version: u32 = 1, now_ms: i64, wall_time_ms: i64, intent_id: []const u8, workspace_id: []const u8, thread_id: []const u8, query: []const u8 },
    terminal_attach: struct { api_version: u32 = 1, now_ms: i64, wall_time_ms: i64, intent_id: []const u8, terminal_id: []const u8 },
    terminal_detach: struct { api_version: u32 = 1, now_ms: i64, wall_time_ms: i64, intent_id: []const u8, terminal_id: []const u8 },
    terminal_kill: struct { api_version: u32 = 1, now_ms: i64, wall_time_ms: i64, intent_id: []const u8, terminal_id: []const u8 },
    terminal_resize: struct { api_version: u32 = 1, now_ms: i64, wall_time_ms: i64, intent_id: []const u8, terminal_id: []const u8, cols: u16, rows: u16 },
    terminal_input: struct { api_version: u32 = 1, now_ms: i64, wall_time_ms: i64, intent_id: []const u8, terminal_id: []const u8, vt_modes: VtModes, input: struct { kind: enum { text, key, paste }, text: ?[]const u8 = null, key: ?[]const u8 = null, ctrl: bool, alt: bool, shift: bool } },
};
pub const Effect = union(enum) {
    http_request: struct { effect_id: []const u8, generation: []const u8, method: []const u8, url: []const u8, headers: []const Header, body_base64: ?[]const u8, timeout_ms: u32, max_response_bytes: u32, tls: Tls },
    http_cancel: struct { effect_id: []const u8, generation: []const u8, request_id: []const u8 },
    ws_open: struct { effect_id: []const u8, generation: []const u8, url: []const u8, protocols: []const []const u8, tls: Tls, max_message_bytes: u32 },
    ws_send: struct { effect_id: []const u8, generation: []const u8, socket_id: []const u8, text: []const u8 },
    ws_close: struct { effect_id: []const u8, generation: []const u8, socket_id: []const u8, code: u16 },
    set_timer: struct { effect_id: []const u8, generation: []const u8, timer_id: []const u8, delay_ms: u32, purpose: []const u8 },
    cancel_timer: struct { effect_id: []const u8, generation: []const u8, timer_id: []const u8 },
    secure_store_get: struct { effect_id: []const u8, generation: []const u8, key: []const u8 },
    secure_store_put: struct { effect_id: []const u8, generation: []const u8, key: []const u8, value_base64: []const u8 },
    secure_store_delete: struct { effect_id: []const u8, generation: []const u8, key: []const u8 },
    state_changed: struct { effect_id: []const u8, generation: []const u8, revision: []const u8, scopes: []const []const u8 },
    notify: struct { effect_id: []const u8, generation: []const u8, notification_id: []const u8, kind: []const u8, title: []const u8, body: []const u8, target: struct { host_id: []const u8, workspace_id: ?[]const u8, thread_id: ?[]const u8 }, actions: []const []const u8 },
    log: struct { effect_id: []const u8, generation: []const u8, level: []const u8, code: []const u8, fields: std.json.Value },
    tls_probe: struct { effect_id: []const u8, generation: []const u8, origin: []const u8 },
    terminal_output: struct { effect_id: []const u8, generation: []const u8, terminal_id: []const u8, reset: bool, bytes_base64: []const u8, next_offset: []const u8 },
};
pub const EffectBatch = struct { api_version: u32, revision: []const u8, effects: []const Effect };
pub const TrustProposal = struct { id: []const u8, origin: []const u8, spki_sha256: []const u8, runtime_id: ?[]const u8 };
pub const HostView = struct {
    host_id: []const u8,
    label: []const u8,
    https_url: ?[]const u8,
    runtime_id: ?[]const u8,
    instance_id: ?[]const u8,
    phase: []const u8,
    lifecycle: Lifecycle,
    auth_state: []const u8,
    sync_state: []const u8,
    capabilities: []const []const u8,
    scopes: []const []const u8,
    retry_at_ms: ?i64,
    trust_proposal: ?TrustProposal,
    update_required: bool,
    @"error": ?LocalError,
};
pub const HostsView = struct { items: []const HostView, operations: []const Operation };
const projection = @import("projection.zig");
pub const HomeView = struct { items: []const projection.Pane, loading: bool, stale: bool, incomplete_scopes: []const []const u8, @"error": ?LocalError };
pub const HistoryView = struct { query: []const u8, items: []const projection.ThreadSummary, next_cursor: ?[]const u8, loading: bool, @"error": ?LocalError };
pub const WorkspacesView = struct { items: []const projection.Workspace, loading: bool, stale: bool, @"error": ?LocalError, history: HistoryView };
pub fn Query(comptime T: type) type {
    return struct { api_version: u32, revision: []const u8, data: ?T, @"error": ?LocalError };
}
