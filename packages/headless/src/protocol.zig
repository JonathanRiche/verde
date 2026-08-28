//! Headless Verde protocol envelopes, versions, error codes, and capabilities.
//!
//! Pure allocator + std.json only. No sockets, pipes, or daemon imports.
//! Wire shape matches the existing sessionizer JSON-RPC envelope so core.*
//! methods stay byte-compatible with the daemon's beginOk / errorResponseAlloc.

const std = @import("std");
const access_protocol = @import("access_protocol.zig");
const runtime_identity = @import("runtime_identity.zig");

/// Current headless protocol version advertised by core.status / core.capabilities.
pub const HEADLESS_PROTOCOL_VERSION: u32 = 1;
/// Oldest headless protocol version this implementation understands.
pub const MIN_SUPPORTED_PROTOCOL_VERSION: u32 = 1;
/// Newest headless protocol version this implementation understands.
pub const MAX_SUPPORTED_PROTOCOL_VERSION: u32 = 1;

/// Network-safe runtime protocol version. The legacy scalar version above is
/// retained for existing local clients; new transports negotiate this pair.
pub const RUNTIME_PROTOCOL_MAJOR: u32 = 1;
pub const RUNTIME_PROTOCOL_MINOR: u32 = 0;
/// Conservative authenticated-transport envelope ceiling. The private Unix
/// socket parser may accept more, but every advertised runtime limit must also
/// fit through the loopback HTTP and WebSocket gateway.
pub const RUNTIME_MAX_MESSAGE_BYTES: usize = 1024 * 1024;

pub const RuntimeProtocolVersion = struct {
    major: u32 = RUNTIME_PROTOCOL_MAJOR,
    minor: u32 = RUNTIME_PROTOCOL_MINOR,
};

/// Limits advertised by the runtime handshake. Clients must still accept a
/// smaller per-operation limit returned by an individual method.
pub const RuntimeLimits = struct {
    max_request_bytes: usize = RUNTIME_MAX_MESSAGE_BYTES,
    max_response_bytes: usize = RUNTIME_MAX_MESSAGE_BYTES,
    max_attachment_bytes: usize = 50 * 1024 * 1024,
    max_parked_wait_ms: u32 = 25_000,
    default_page_items: u32 = 100,
    max_page_items: u32 = 200,
};

/// Runtime-qualified IDs prevent detached clients from confusing identical
/// local IDs returned by two simultaneously connected daemons.
pub const RuntimeWorkspaceId = struct { runtime_id: []const u8, workspace_id: []const u8 };
pub const RuntimeRepositoryId = struct { runtime_id: []const u8, workspace_id: []const u8, repository_id: []const u8 };
pub const RuntimeThreadId = runtime_identity.RuntimeThreadId;
pub const OwnedRuntimeThreadId = runtime_identity.OwnedRuntimeThreadId;
pub const RuntimePaneId = struct { runtime_id: []const u8, pane_id: []const u8 };
pub const RuntimeTurnId = struct { runtime_id: []const u8, turn_id: []const u8 };

/// Inclusive protocol-version range advertised by a client or daemon.
/// A range is valid only when `min <= max`.
pub const ProtocolRange = struct {
    min: u32,
    max: u32,
};

/// Validate an advertised inclusive protocol range.
/// Invalid ranges return `error.InvalidProtocolRange` before compatibility is considered.
pub fn validateProtocolRange(range: ProtocolRange) !void {
    if (range.min > range.max) return error.InvalidProtocolRange;
}

/// Select the highest version in the overlap between two inclusive ranges.
/// Both ranges are validated first; disjoint valid ranges return the distinct
/// `error.IncompatibleProtocolVersion` error.
pub fn negotiateProtocolVersion(client: ProtocolRange, daemon: ProtocolRange) !u32 {
    try validateProtocolRange(client);
    try validateProtocolRange(daemon);

    const overlap_min = @max(client.min, daemon.min);
    const overlap_max = @min(client.max, daemon.max);
    if (overlap_min > overlap_max) return error.IncompatibleProtocolVersion;
    return overlap_max;
}

/// Soft upper bound for a single envelope. Oversized input is rejected as invalid_request.
pub const MAX_MESSAGE_BYTES: usize = 8 * 1024 * 1024;

// Stable machine-readable error codes. Keep these strings frozen once published.
pub const ERR_INVALID_REQUEST: []const u8 = "invalid_request";
pub const ERR_UNKNOWN_METHOD: []const u8 = "unknown_method";
pub const ERR_INVALID_PARAMS: []const u8 = "invalid_params";
pub const ERR_CAPABILITY_UNAVAILABLE: []const u8 = "capability_unavailable";
pub const ERR_RESOURCE_NOT_FOUND: []const u8 = "resource_not_found";
pub const ERR_INTERNAL: []const u8 = "internal";
pub const ERR_CONFLICT: []const u8 = "conflict";
pub const ERR_INVALID_STATE: []const u8 = "invalid_state";
pub const ERR_STORE_BUSY: []const u8 = "store_busy";
pub const ERR_SCHEMA_TOO_NEW: []const u8 = "schema_too_new";
pub const ERR_STORE_CORRUPT: []const u8 = "store_corrupt";
pub const ERR_STORE_UNAVAILABLE: []const u8 = "store_unavailable";
/// A client cursor/sequence fell below a retention floor (journal ring or
/// compacted turn tail), or its bound page revision is no longer current.
/// Recovery is snapshot/page restart + reseed, not the refresh-and-reguard
/// reaction `conflict` implies (m4m5_decisions Q6). Error.data may carry
/// {floor_seq} (journal) or {compacted_before_seq} (tail).
pub const ERR_REVISION_EXPIRED: []const u8 = "revision_expired";
pub const ERR_RUNTIME_IDENTITY_MISSING: []const u8 = "runtime_identity_missing";
pub const ERR_RUNTIME_IDENTITY_MISMATCH: []const u8 = "runtime_identity_mismatch";
pub const ERR_PROTOCOL_INCOMPATIBLE: []const u8 = "protocol_incompatible";

/// Typed protocol error carried inside a response envelope.
pub const Error = struct {
    code: []const u8,
    message: []const u8,
    /// Optional structured details; omitted from the wire when absent.
    data: ?std.json.Value = null,
};

/// Stable names for independently negotiable optional runtime features.
pub const CapabilityFeature = enum {
    terminal_grid,
    browser_session_state,
    browser_create,
    browser_navigation,
    browser_history,
    browser_javascript_eval,
    browser_dom_inspection,
    browser_selector_actions,
    browser_form_input,
    browser_low_level_pointer,
    browser_screenshot,
    browser_lifecycle_restart,
    browser_lifecycle_reset,
    browser_frame_streaming,
    browser_downloads,
    browser_uploads,

    /// Stable wire name used in errors and capability-gating diagnostics.
    pub fn wireName(self: CapabilityFeature) []const u8 {
        return switch (self) {
            .terminal_grid => "terminal_grid",
            .browser_session_state => "browser.session_state",
            .browser_create => "browser.create",
            .browser_navigation => "browser.navigation",
            .browser_history => "browser.history",
            .browser_javascript_eval => "browser.javascript_eval",
            .browser_dom_inspection => "browser.dom_inspection",
            .browser_selector_actions => "browser.selector_actions",
            .browser_form_input => "browser.form_input",
            .browser_low_level_pointer => "browser.low_level_pointer",
            .browser_screenshot => "browser.screenshot",
            .browser_lifecycle_restart => "browser.lifecycle_restart",
            .browser_lifecycle_reset => "browser.lifecycle_reset",
            .browser_frame_streaming => "browser.frame_streaming",
            .browser_downloads => "browser.downloads",
            .browser_uploads => "browser.uploads",
        };
    }

    fn unavailableMessage(self: CapabilityFeature) []const u8 {
        return switch (self) {
            .terminal_grid => "terminal_grid capability is unavailable",
            .browser_session_state => "browser.session_state capability is unavailable",
            .browser_create => "browser.create capability is unavailable",
            .browser_navigation => "browser.navigation capability is unavailable",
            .browser_history => "browser.history capability is unavailable",
            .browser_javascript_eval => "browser.javascript_eval capability is unavailable",
            .browser_dom_inspection => "browser.dom_inspection capability is unavailable",
            .browser_selector_actions => "browser.selector_actions capability is unavailable",
            .browser_form_input => "browser.form_input capability is unavailable",
            .browser_low_level_pointer => "browser.low_level_pointer capability is unavailable",
            .browser_screenshot => "browser.screenshot capability is unavailable",
            .browser_lifecycle_restart => "browser.lifecycle_restart capability is unavailable",
            .browser_lifecycle_reset => "browser.lifecycle_reset capability is unavailable",
            .browser_frame_streaming => "browser.frame_streaming capability is unavailable",
            .browser_downloads => "browser.downloads capability is unavailable",
            .browser_uploads => "browser.uploads capability is unavailable",
        };
    }
};

/// Independently advertised features of a browser-session adapter.
pub const BrowserFeatures = struct {
    session_state: bool = false,
    create: bool = false,
    navigation: bool = false,
    history: bool = false,
    javascript_eval: bool = false,
    dom_inspection: bool = false,
    selector_actions: bool = false,
    form_input: bool = false,
    low_level_pointer: bool = false,
    screenshot: bool = false,
    lifecycle_restart: bool = false,
    lifecycle_reset: bool = false,
    frame_streaming: bool = false,
    downloads: bool = false,
    uploads: bool = false,

    pub fn any(self: BrowserFeatures) bool {
        return self.session_state or
            self.create or
            self.navigation or
            self.history or
            self.javascript_eval or
            self.dom_inspection or
            self.selector_actions or
            self.form_input or
            self.low_level_pointer or
            self.screenshot or
            self.lifecycle_restart or
            self.lifecycle_reset or
            self.frame_streaming or
            self.downloads or
            self.uploads;
    }

    pub fn isAvailable(self: BrowserFeatures, feature: CapabilityFeature) bool {
        return switch (feature) {
            .terminal_grid => false,
            .browser_session_state => self.session_state,
            .browser_create => self.create,
            .browser_navigation => self.navigation,
            .browser_history => self.history,
            .browser_javascript_eval => self.javascript_eval,
            .browser_dom_inspection => self.dom_inspection,
            .browser_selector_actions => self.selector_actions,
            .browser_form_input => self.form_input,
            .browser_low_level_pointer => self.low_level_pointer,
            .browser_screenshot => self.screenshot,
            .browser_lifecycle_restart => self.lifecycle_restart,
            .browser_lifecycle_reset => self.lifecycle_reset,
            .browser_frame_streaming => self.frame_streaming,
            .browser_downloads => self.downloads,
            .browser_uploads => self.uploads,
        };
    }
};

/// Aggregate browser-adapter state plus its authoritative granular feature set.
pub const BrowserCapabilities = struct {
    available: bool = false,
    features: BrowserFeatures = .{},

    pub fn init(features: BrowserFeatures) BrowserCapabilities {
        return .{ .available = features.any(), .features = features };
    }
};

/// Construct a stable capability_unavailable protocol error for one feature.
pub fn capabilityUnavailable(feature: CapabilityFeature) Error {
    return .{
        .code = ERR_CAPABILITY_UNAVAILABLE,
        .message = feature.unavailableMessage(),
    };
}

/// Capabilities currently offered by the headless core. Phase 1 only claims terminal_raw.
pub const Capabilities = struct {
    terminal_raw: bool = true,
    terminal_grid: bool = false,
    /// M4-P5: advertised together with the MCP/CLI daemon-direct chat flip.
    /// The M4-P4 authority flip (durable-before-consume) landed first; this
    /// advertisement is what daemon-direct clients gate on — an old daemon
    /// that serialized `chat:false` is rejected with capability_unavailable
    /// and never silently re-routed through Live.
    chat: bool = true,
    processes: bool = false,
    leases: bool = false,
    browser_execution: bool = false,
    browser_presentation: bool = false,
    browser: BrowserCapabilities = .{},
    /// Daemon-owned durable state store. Stays false through Phase 2; the
    /// production flip to true is a Phase 3 decision (dormant-store contract).
    store: bool = false,
    /// Composite scoped core.snapshot reads. The field default stays false so
    /// decoding an old-daemon shape cannot invent support; `phase1` is the
    /// current-daemon advertisement and flips it explicitly below.
    snapshots: bool = false,
    /// Change-journal cursor reads. As above, absence on an old daemon decodes
    /// false while the current-daemon constructor advertises the routed read.
    changes: bool = false,
    /// Push streaming (core.subscribe). Stays false through all of M5 (Q8);
    /// the names are reserved but undispatched.
    subscriptions: bool = false,
    /// Bounded daemon-owned read surfaces used by detached/remote clients.
    workspace_pagination: bool = false,
    thread_pagination: bool = false,
    message_pagination: bool = false,
    /// Runtime-scoped installation/authentication inventory for all provider surfaces.
    provider_status: bool = false,
    /// One-repository compatibility projection with stable repository IDs.
    repository_projection: bool = false,
    /// Full bounded multi-repository manifest reads and receipt-backed CRUD.
    /// The field default remains false so old daemon shapes fail closed.
    repository_manifests: bool = false,

    /// Query the authoritative granular availability of an optional feature.
    pub fn isFeatureAvailable(self: Capabilities, feature: CapabilityFeature) bool {
        return switch (feature) {
            .terminal_grid => self.terminal_grid,
            else => self.browser.available and self.browser.features.isAvailable(feature),
        };
    }

    /// Construct capabilities with coarse browser_execution derived for old clients.
    pub fn withBrowser(features: BrowserFeatures, browser_presentation: bool) Capabilities {
        const browser: BrowserCapabilities = .init(features);
        return .{
            .browser_execution = browser.available,
            .browser_presentation = browser_presentation,
            .browser = browser,
        };
    }

    pub fn phase1() Capabilities {
        return .{
            .terminal_raw = true,
            .terminal_grid = false,
            // M4-P5 flip: chat advertised in the same commit that makes the
            // MCP/CLI chat tools daemon-direct (design "Phase M4-P5").
            .chat = true,
            .processes = false,
            .leases = false,
            .browser_execution = false,
            .browser_presentation = false,
            .browser = .{},
            .store = false,
            // M5-P5 atomic external flip: daemon dispatch for both reads was
            // proven through P2-P4 before these two flags became observable.
            .snapshots = true,
            .changes = true,
            .subscriptions = false,
            .workspace_pagination = true,
            .thread_pagination = true,
            .message_pagination = true,
            .provider_status = true,
            .repository_projection = true,
            .repository_manifests = true,
        };
    }
};

/// Runtime features that remain available without an attached durable store.
pub const RUNTIME_CAPABILITY_NAMES_BASE = [_][]const u8{
    "rpc.target.v1",
    "core.snapshot.v1",
    "core.changes.v1",
    "chat.turns.v1",
    "pty.raw.v1",
    "workspaces.page.v1",
    "threads.page.v1",
    "messages.page.v1",
    "providers.status.v1",
    "repositories.compat.v1",
};

/// Complete current-daemon feature set when the durable store is attached.
pub const RUNTIME_CAPABILITY_NAMES = RUNTIME_CAPABILITY_NAMES_BASE ++
    [_][]const u8{
        "repositories.manifest.v1",
        "chat.repository_route.v1",
        access_protocol.PAIR_RUNTIME_CAPABILITY,
    };

/// Runtime generation a remote JSON-RPC request intends to reach. Keeping
/// this at the envelope level lets the daemon reject a stale or misdirected
/// request before any method-specific params are decoded or acted upon.
pub const RequestTarget = struct {
    runtime_id: []const u8,
    instance_id: []const u8,
};

/// Result payload for `core.status`.
pub const StatusResult = struct {
    runtime_id: []const u8 = "",
    instance_id: []const u8 = "",
    server_version: []const u8 = "",
    protocol: RuntimeProtocolVersion = .{},
    runtime_capabilities: []const []const u8 = &.{},
    limits: RuntimeLimits = .{},
    headless_protocol_version: u32,
    min_supported: u32,
    max_supported: u32,
    /// Sessionizer RPC protocol version (daemon-owned sessions / chat turns).
    protocol_version: u32,
    pid: u32,
    session_count: usize,
    chat_turn_count: usize,
    capabilities: Capabilities,
};

/// Result payload for `core.capabilities`.
pub const CapabilitiesResult = struct {
    runtime_id: []const u8 = "",
    instance_id: []const u8 = "",
    server_version: []const u8 = "",
    protocol: RuntimeProtocolVersion = .{},
    runtime_capabilities: []const []const u8 = &.{},
    limits: RuntimeLimits = .{},
    headless_protocol_version: u32,
    min_supported: u32,
    max_supported: u32,
    capabilities: Capabilities,
};

/// Typed request envelope. Params stay as dynamic JSON for tolerant readers.
pub const Request = struct {
    id: u64,
    method: []const u8,
    params: std.json.Value = .null,
    target: ?RequestTarget = null,
};

/// Typed response envelope: exactly one of result or err is present.
///
/// `id` is null only for uncorrelated daemon error paths. Successful responses
/// always have a numeric id; request-aware clients must correlate numeric ids.
pub const Response = struct {
    id: ?u64,
    result: ?std.json.Value = null,
    err: ?Error = null,

    pub fn isOk(self: Response) bool {
        return self.err == null;
    }
};

/// Encode a request matching the sessionizer client shape (id/method/params).
/// Field order is part of the compatibility contract with existing callers.
pub fn encodeRequest(allocator: std.mem.Allocator, id: u64, method: []const u8, params: anytype) ![]u8 {
    return encodeRequestEnvelope(allocator, id, method, params, null);
}

/// Encode a request pinned to one verified runtime generation. Invalid or
/// incomplete identities are rejected before any bytes reach a transport.
pub fn encodeTargetedRequest(
    allocator: std.mem.Allocator,
    id: u64,
    method: []const u8,
    params: anytype,
    target: RequestTarget,
) ![]u8 {
    try validateRequestTarget(target);
    return encodeRequestEnvelope(allocator, id, method, params, target);
}

fn encodeRequestEnvelope(
    allocator: std.mem.Allocator,
    id: u64,
    method: []const u8,
    params: anytype,
    target: ?RequestTarget,
) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var s: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
    try s.beginObject();
    try s.objectField("id");
    try s.write(id);
    try s.objectField("method");
    try s.write(method);
    try s.objectField("params");
    try s.write(params);
    if (target) |request_target| {
        try s.objectField("target");
        try s.write(request_target);
    }
    try s.endObject();
    return try writer.toOwnedSlice();
}

/// Decode and validate an optional top-level target value. Unknown target
/// members remain additive; the two identity fields are mandatory and
/// canonical whenever the envelope contains `target`.
pub fn parseRequestTarget(value: std.json.Value) !RequestTarget {
    if (value != .object) return error.RuntimeIdentityMissing;
    const runtime_id = jsonString(value.object.get("runtime_id") orelse .null) orelse
        return error.RuntimeIdentityMissing;
    const instance_id = jsonString(value.object.get("instance_id") orelse .null) orelse
        return error.RuntimeIdentityMissing;
    const target: RequestTarget = .{
        .runtime_id = runtime_id,
        .instance_id = instance_id,
    };
    try validateRequestTarget(target);
    return target;
}

/// Runtime and instance identities are canonical 128-bit lowercase hex.
pub fn validateRequestTarget(target: RequestTarget) !void {
    try validateIdentityPart(target.runtime_id);
    try validateIdentityPart(target.instance_id);
}

fn validateIdentityPart(value: []const u8) !void {
    if (value.len != 32) return error.RuntimeIdentityMissing;
    for (value) |byte| {
        if (!std.ascii.isHex(byte) or std.ascii.isUpper(byte)) {
            return error.RuntimeIdentityMissing;
        }
    }
}

/// Encode an ok response envelope (jsonrpc + id + result).
pub fn encodeOkResponse(allocator: std.mem.Allocator, id: u64, result: anytype) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var s: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
    try s.beginObject();
    try s.objectField("jsonrpc");
    try s.write("2.0");
    try s.objectField("id");
    try s.write(id);
    try s.objectField("result");
    try s.write(result);
    try s.endObject();
    return try writer.toOwnedSlice();
}

/// Encode an error response envelope (jsonrpc + id + error{code,message,data}).
pub fn encodeErrorResponse(allocator: std.mem.Allocator, id: u64, code: []const u8, message: []const u8) ![]u8 {
    return encodeErrorResponseWithData(allocator, id, code, message, null);
}

/// Encode an error response envelope with optional structured error details.
pub fn encodeErrorResponseWithData(
    allocator: std.mem.Allocator,
    id: u64,
    code: []const u8,
    message: []const u8,
    data: ?std.json.Value,
) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var s: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
    try s.beginObject();
    try s.objectField("jsonrpc");
    try s.write("2.0");
    try s.objectField("id");
    try s.write(id);
    try s.objectField("error");
    try s.beginObject();
    try s.objectField("code");
    try s.write(code);
    try s.objectField("message");
    try s.write(message);
    if (data) |payload| {
        try s.objectField("data");
        try s.write(payload);
    }
    try s.endObject();
    try s.endObject();
    return try writer.toOwnedSlice();
}

pub const ParsedRequest = struct {
    arena_parsed: std.json.Parsed(std.json.Value),
    request: Request,

    pub fn deinit(self: *ParsedRequest) void {
        self.arena_parsed.deinit();
        self.* = undefined;
    }
};

pub const ParsedResponse = struct {
    arena_parsed: std.json.Parsed(std.json.Value),
    response: Response,

    pub fn deinit(self: *ParsedResponse) void {
        self.arena_parsed.deinit();
        self.* = undefined;
    }
};

/// Parse a request envelope. Unknown fields are ignored; bad/oversized JSON is invalid_request.
pub fn parseRequest(allocator: std.mem.Allocator, json_bytes: []const u8) !ParsedRequest {
    try rejectOversizedOrEmpty(json_bytes);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json_bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch return error.InvalidRequest;
    errdefer parsed.deinit();

    if (parsed.value != .object) return error.InvalidRequest;
    const obj = parsed.value.object;
    const id = jsonU64(obj.get("id") orelse .null) orelse return error.InvalidRequest;
    const method = jsonString(obj.get("method") orelse .null) orelse return error.InvalidRequest;
    const params = obj.get("params") orelse .null;
    const target = if (obj.get("target")) |value|
        try parseRequestTarget(value)
    else
        null;

    return .{
        .arena_parsed = parsed,
        .request = .{
            .id = id,
            .method = method,
            .params = params,
            .target = target,
        },
    };
}

/// Parse a JSON-RPC 2.0 response envelope. Unknown fields are ignored;
/// malformed/oversized envelopes are invalid_request. Exactly one of `result`
/// and `error` must be present. A null id is accepted only for an error envelope.
pub fn parseResponse(allocator: std.mem.Allocator, json_bytes: []const u8) !ParsedResponse {
    try rejectOversizedOrEmpty(json_bytes);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json_bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch return error.InvalidRequest;
    errdefer parsed.deinit();

    if (parsed.value != .object) return error.InvalidRequest;
    const obj = parsed.value.object;
    const jsonrpc = jsonString(obj.get("jsonrpc") orelse .null) orelse return error.InvalidRequest;
    if (!std.mem.eql(u8, jsonrpc, "2.0")) return error.InvalidRequest;

    const id_value = obj.get("id") orelse return error.InvalidRequest;
    const result_value = obj.get("result");
    const error_value = obj.get("error");
    if ((result_value == null) == (error_value == null)) return error.InvalidRequest;

    if (error_value) |err_value| {
        const id = try jsonOptionalU64(id_value);
        if (err_value != .object) return error.InvalidRequest;
        const code = jsonString(err_value.object.get("code") orelse .null) orelse return error.InvalidRequest;
        const message = jsonString(err_value.object.get("message") orelse .null) orelse "";
        const data = err_value.object.get("data");
        return .{
            .arena_parsed = parsed,
            .response = .{
                .id = id,
                .err = .{ .code = code, .message = message, .data = data },
            },
        };
    }

    const id = (try jsonOptionalU64(id_value)) orelse return error.InvalidRequest;
    return .{
        .arena_parsed = parsed,
        .response = .{
            .id = id,
            .result = result_value.?,
        },
    };
}

fn rejectOversizedOrEmpty(json_bytes: []const u8) !void {
    if (json_bytes.len == 0 or json_bytes.len > MAX_MESSAGE_BYTES) return error.InvalidRequest;
}

fn jsonString(value: std.json.Value) ?[]const u8 {
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn jsonU64(value: std.json.Value) ?u64 {
    return switch (value) {
        .integer => |int| if (int >= 0) @intCast(int) else null,
        .number_string => |text| std.fmt.parseInt(u64, text, 10) catch null,
        else => null,
    };
}

/// Response ids may be a non-negative integer or JSON null (daemon internal errors).
fn jsonOptionalU64(value: std.json.Value) !?u64 {
    return switch (value) {
        .null => null,
        .integer => |int| if (int >= 0) @as(u64, @intCast(int)) else error.InvalidRequest,
        .number_string => |text| std.fmt.parseInt(u64, text, 10) catch return error.InvalidRequest,
        else => error.InvalidRequest,
    };
}

test "envelope round-trip encode/decode request and ok response" {
    const allocator = std.testing.allocator;
    const req_json = try encodeRequest(allocator, 42, "core.status", .{ .extra = true });
    defer allocator.free(req_json);

    var parsed_req = try parseRequest(allocator, req_json);
    defer parsed_req.deinit();
    try std.testing.expectEqual(@as(u64, 42), parsed_req.request.id);
    try std.testing.expectEqualStrings("core.status", parsed_req.request.method);
    // Unknown params fields are retained in the dynamic value for the dispatcher to ignore.
    try std.testing.expect(parsed_req.request.params == .object);
    try std.testing.expect(parsed_req.request.target == null);

    const status: StatusResult = .{
        .runtime_id = "runtime-a",
        .instance_id = "instance-a",
        .server_version = "0.1.0",
        .runtime_capabilities = &RUNTIME_CAPABILITY_NAMES,
        .headless_protocol_version = HEADLESS_PROTOCOL_VERSION,
        .min_supported = MIN_SUPPORTED_PROTOCOL_VERSION,
        .max_supported = MAX_SUPPORTED_PROTOCOL_VERSION,
        .protocol_version = 18,
        .pid = 1234,
        .session_count = 2,
        .chat_turn_count = 1,
        .capabilities = .phase1(),
    };
    const ok_json = try encodeOkResponse(allocator, 42, status);
    defer allocator.free(ok_json);

    var parsed_ok = try parseResponse(allocator, ok_json);
    defer parsed_ok.deinit();
    try std.testing.expect(parsed_ok.response.isOk());
    try std.testing.expectEqual(@as(?u64, 42), parsed_ok.response.id);
    const result = parsed_ok.response.result.?;
    try std.testing.expect(result == .object);
    try std.testing.expectEqual(
        @as(i64, HEADLESS_PROTOCOL_VERSION),
        result.object.get("headless_protocol_version").?.integer,
    );
    try std.testing.expectEqual(@as(i64, 18), result.object.get("protocol_version").?.integer);
    try std.testing.expectEqualStrings("runtime-a", result.object.get("runtime_id").?.string);
    try std.testing.expectEqual(@as(i64, RUNTIME_PROTOCOL_MAJOR), result.object.get("protocol").?.object.get("major").?.integer);
}

test "legacy request encoding remains byte compatible" {
    const encoded = try encodeRequest(std.testing.allocator, 7, "core.status", .{ .probe = true });
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualStrings(
        "{\"id\":7,\"method\":\"core.status\",\"params\":{\"probe\":true}}",
        encoded,
    );
}

test "targeted request encoding parses a canonical runtime pair" {
    const target: RequestTarget = .{
        .runtime_id = "0123456789abcdef0123456789abcdef",
        .instance_id = "00112233445566778899aabbccddeeff",
    };
    const encoded = try encodeTargetedRequest(
        std.testing.allocator,
        8,
        "core.snapshot",
        .{ .scopes = [_][]const u8{"workspaces"} },
        target,
    );
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualStrings(
        "{\"id\":8,\"method\":\"core.snapshot\",\"params\":{\"scopes\":[\"workspaces\"]},\"target\":{\"runtime_id\":\"0123456789abcdef0123456789abcdef\",\"instance_id\":\"00112233445566778899aabbccddeeff\"}}",
        encoded,
    );

    var parsed = try parseRequest(std.testing.allocator, encoded);
    defer parsed.deinit();
    try std.testing.expect(parsed.request.target != null);
    try std.testing.expectEqualStrings(target.runtime_id, parsed.request.target.?.runtime_id);
    try std.testing.expectEqualStrings(target.instance_id, parsed.request.target.?.instance_id);
}

test "request target validation rejects incomplete and noncanonical pairs" {
    try std.testing.expectError(
        error.RuntimeIdentityMissing,
        encodeTargetedRequest(std.testing.allocator, 1, "core.status", .{}, .{
            .runtime_id = "short",
            .instance_id = "00112233445566778899aabbccddeeff",
        }),
    );

    const invalid_requests = [_][]const u8{
        "{\"id\":1,\"method\":\"core.status\",\"params\":{},\"target\":null}",
        "{\"id\":1,\"method\":\"core.status\",\"params\":{},\"target\":{\"runtime_id\":\"0123456789abcdef0123456789abcdef\"}}",
        "{\"id\":1,\"method\":\"core.status\",\"params\":{},\"target\":{\"runtime_id\":\"0123456789ABCDEF0123456789ABCDEF\",\"instance_id\":\"00112233445566778899aabbccddeeff\"}}",
        "{\"id\":1,\"method\":\"core.status\",\"params\":{},\"target\":{\"runtime_id\":\"0123456789abcdef0123456789abcdef\",\"instance_id\":7}}",
    };
    for (invalid_requests) |request| {
        try std.testing.expectError(
            error.RuntimeIdentityMissing,
            parseRequest(std.testing.allocator, request),
        );
    }
}

test "runtime capabilities advertise request target validation" {
    var found = false;
    for (RUNTIME_CAPABILITY_NAMES) |capability| {
        if (std.mem.eql(u8, capability, "rpc.target.v1")) found = true;
    }
    try std.testing.expect(found);
}

test "store-backed runtimes advertise complete Pair transport enforcement" {
    var found_store_backed = false;
    for (RUNTIME_CAPABILITY_NAMES) |capability| {
        if (std.mem.eql(u8, capability, access_protocol.PAIR_RUNTIME_CAPABILITY)) {
            found_store_backed = true;
        }
    }
    var found_base = false;
    for (RUNTIME_CAPABILITY_NAMES_BASE) |capability| {
        if (std.mem.eql(u8, capability, access_protocol.PAIR_RUNTIME_CAPABILITY)) found_base = true;
    }
    try std.testing.expect(found_store_backed);
    try std.testing.expect(!found_base);
}

test "parseResponse reads error envelopes" {
    const allocator = std.testing.allocator;
    const err_json = try encodeErrorResponse(allocator, 7, ERR_UNKNOWN_METHOD, "nope");
    defer allocator.free(err_json);

    var parsed = try parseResponse(allocator, err_json);
    defer parsed.deinit();
    try std.testing.expect(!parsed.response.isOk());
    try std.testing.expectEqual(@as(?u64, 7), parsed.response.id);
    try std.testing.expectEqualStrings(ERR_UNKNOWN_METHOD, parsed.response.err.?.code);
    try std.testing.expectEqualStrings("nope", parsed.response.err.?.message);
}

test "error response without data remains byte compatible" {
    const allocator = std.testing.allocator;
    const err_json = try encodeErrorResponse(allocator, 7, ERR_UNKNOWN_METHOD, "nope");
    defer allocator.free(err_json);

    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":7,\"error\":{\"code\":\"unknown_method\",\"message\":\"nope\"}}",
        err_json,
    );
}

test "error data round trips as a structured JSON value" {
    const allocator = std.testing.allocator;
    var data_parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        "{\"expected_store_revision\":4,\"resource\":\"workspace\"}",
        .{},
    );
    defer data_parsed.deinit();

    const err_json = try encodeErrorResponseWithData(
        allocator,
        8,
        ERR_CONFLICT,
        "store revision conflict",
        data_parsed.value,
    );
    defer allocator.free(err_json);

    var parsed = try parseResponse(allocator, err_json);
    defer parsed.deinit();
    const err = parsed.response.err.?;
    try std.testing.expectEqualStrings(ERR_CONFLICT, err.code);
    try std.testing.expectEqualStrings("store revision conflict", err.message);
    try std.testing.expect(err.data != null);
    const data = err.data.?.object;
    try std.testing.expectEqual(@as(i64, 4), data.get("expected_store_revision").?.integer);
    try std.testing.expectEqualStrings("workspace", data.get("resource").?.string);
}

test "legacy error decoders tolerate the optional data field" {
    const LegacyError = struct {
        code: []const u8,
        message: []const u8,
    };
    const LegacyResponse = struct {
        jsonrpc: []const u8,
        id: u64,
        @"error": LegacyError,
    };
    const raw =
        "{\"jsonrpc\":\"2.0\",\"id\":9,\"error\":{\"code\":\"conflict\",\"message\":\"stale\",\"data\":{\"expected_store_revision\":4}}}";

    var parsed = try std.json.parseFromSlice(LegacyResponse, std.testing.allocator, raw, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    try std.testing.expectEqualStrings("conflict", parsed.value.@"error".code);
    try std.testing.expectEqualStrings("stale", parsed.value.@"error".message);
}

test "storage error codes retain their stable wire values" {
    try std.testing.expectEqualStrings("store_busy", ERR_STORE_BUSY);
    try std.testing.expectEqualStrings("schema_too_new", ERR_SCHEMA_TOO_NEW);
    try std.testing.expectEqualStrings("store_corrupt", ERR_STORE_CORRUPT);
    try std.testing.expectEqualStrings("store_unavailable", ERR_STORE_UNAVAILABLE);
    try std.testing.expectEqualStrings("revision_expired", ERR_REVISION_EXPIRED);
}

test "parseResponse accepts null id on error envelopes" {
    const allocator = std.testing.allocator;
    // Matches the daemon generic internal-error path (id: null).
    const err_json =
        \\{"jsonrpc":"2.0","id":null,"error":{"code":"internal_error","message":"OutOfMemory"}}
    ;
    var parsed = try parseResponse(allocator, err_json);
    defer parsed.deinit();
    try std.testing.expect(!parsed.response.isOk());
    try std.testing.expect(parsed.response.id == null);
    try std.testing.expectEqualStrings("internal_error", parsed.response.err.?.code);
    try std.testing.expectEqualStrings("OutOfMemory", parsed.response.err.?.message);
}

test "parseResponse rejects null id success envelopes" {
    try std.testing.expectError(
        error.InvalidRequest,
        parseResponse(std.testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":null,\"result\":{}}"),
    );
}

test "parseResponse rejects missing jsonrpc" {
    try std.testing.expectError(
        error.InvalidRequest,
        parseResponse(std.testing.allocator, "{\"id\":1,\"result\":{}}"),
    );
}

test "parseResponse rejects envelopes with result and error" {
    try std.testing.expectError(
        error.InvalidRequest,
        parseResponse(
            std.testing.allocator,
            "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{},\"error\":{\"code\":\"internal\",\"message\":\"nope\"}}",
        ),
    );
}

test "protocol range validation and negotiation" {
    try std.testing.expectError(
        error.InvalidProtocolRange,
        validateProtocolRange(.{ .min = 4, .max = 3 }),
    );
    try std.testing.expectError(
        error.IncompatibleProtocolVersion,
        negotiateProtocolVersion(.{ .min = 1, .max = 2 }, .{ .min = 3, .max = 4 }),
    );

    // The client range is newer but overlaps the daemon at version 4.
    try std.testing.expectEqual(
        @as(u32, 4),
        try negotiateProtocolVersion(.{ .min = 3, .max = 5 }, .{ .min = 1, .max = 4 }),
    );
    // The daemon range is newer but overlaps the client at version 4.
    try std.testing.expectEqual(
        @as(u32, 4),
        try negotiateProtocolVersion(.{ .min = 1, .max = 4 }, .{ .min = 3, .max = 6 }),
    );
    // A boundary-only overlap negotiates that exact version.
    try std.testing.expectEqual(
        @as(u32, 3),
        try negotiateProtocolVersion(.{ .min = 1, .max = 3 }, .{ .min = 3, .max = 5 }),
    );
}

test "advertised runtime envelope limits fit the bounded network gateway" {
    const limits: RuntimeLimits = .{};
    try std.testing.expectEqual(RUNTIME_MAX_MESSAGE_BYTES, limits.max_request_bytes);
    try std.testing.expectEqual(RUNTIME_MAX_MESSAGE_BYTES, limits.max_response_bytes);
    try std.testing.expect(RUNTIME_MAX_MESSAGE_BYTES < MAX_MESSAGE_BYTES);
}

test "invalid or empty JSON yields InvalidRequest" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidRequest, parseRequest(allocator, ""));
    try std.testing.expectError(error.InvalidRequest, parseRequest(allocator, "{not-json"));
    try std.testing.expectError(error.InvalidRequest, parseResponse(allocator, "[]"));
}

test "unknown fields in params are tolerated by request parse" {
    const allocator = std.testing.allocator;
    const raw =
        \\{"jsonrpc":"2.0","id":1,"method":"core.capabilities","params":{"future_flag":true,"nested":{"x":1}},"extra":"ignored"}
    ;
    var parsed = try parseRequest(allocator, raw);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("core.capabilities", parsed.request.method);
    try std.testing.expect(parsed.request.params.object.get("future_flag") != null);
}

test "old capability shape defaults every granular feature to unavailable" {
    const raw =
        \\{"headless_protocol_version":1,"min_supported":1,"max_supported":1,"capabilities":{"terminal_raw":true,"terminal_grid":false,"chat":false,"processes":false,"leases":false,"browser_execution":false,"browser_presentation":false}}
    ;
    var parsed = try std.json.parseFromSlice(CapabilitiesResult, std.testing.allocator, raw, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    inline for (std.meta.tags(CapabilityFeature)) |feature| {
        try std.testing.expect(!parsed.value.capabilities.isFeatureAvailable(feature));
    }
    try std.testing.expect(!parsed.value.capabilities.browser.available);
    // M4-P5: the old daemon serialized `chat:false` explicitly; the flipped
    // default-true must never resurrect chat on an old-shape parse — this is
    // the wire basis for the old-daemon capability_unavailable rejection.
    try std.testing.expect(!parsed.value.capabilities.chat);
    try std.testing.expect(!parsed.value.capabilities.store);
    try std.testing.expect(!parsed.value.capabilities.snapshots);
    try std.testing.expect(!parsed.value.capabilities.changes);
    try std.testing.expect(!parsed.value.capabilities.subscriptions);
    try std.testing.expect(!parsed.value.capabilities.workspace_pagination);
    try std.testing.expect(!parsed.value.capabilities.thread_pagination);
    try std.testing.expect(!parsed.value.capabilities.message_pagination);
    try std.testing.expect(!parsed.value.capabilities.provider_status);
    try std.testing.expect(!parsed.value.capabilities.repository_projection);
    try std.testing.expect(!parsed.value.capabilities.repository_manifests);
}

test "new granular capability shape round trips" {
    const capabilities: Capabilities = .withBrowser(.{
        .session_state = true,
        .navigation = true,
        .javascript_eval = true,
        .screenshot = true,
        .lifecycle_restart = true,
    }, true);
    const result: CapabilitiesResult = .{
        .headless_protocol_version = HEADLESS_PROTOCOL_VERSION,
        .min_supported = MIN_SUPPORTED_PROTOCOL_VERSION,
        .max_supported = MAX_SUPPORTED_PROTOCOL_VERSION,
        .capabilities = capabilities,
    };

    var writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer writer.deinit();
    var stringify: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
    try stringify.write(result);
    var parsed = try std.json.parseFromSlice(CapabilitiesResult, std.testing.allocator, writer.written(), .{});
    defer parsed.deinit();

    try std.testing.expect(parsed.value.capabilities.browser_execution);
    try std.testing.expect(parsed.value.capabilities.browser_presentation);
    try std.testing.expect(parsed.value.capabilities.browser.available);
    try std.testing.expect(parsed.value.capabilities.isFeatureAvailable(.browser_navigation));
    try std.testing.expect(parsed.value.capabilities.isFeatureAvailable(.browser_javascript_eval));
    try std.testing.expect(parsed.value.capabilities.isFeatureAvailable(.browser_screenshot));
    try std.testing.expect(parsed.value.capabilities.isFeatureAvailable(.browser_lifecycle_restart));
    try std.testing.expect(!parsed.value.capabilities.isFeatureAvailable(.browser_dom_inspection));
    try std.testing.expect(!parsed.value.capabilities.isFeatureAvailable(.terminal_grid));
    try std.testing.expect(!parsed.value.capabilities.store);
    try std.testing.expect(!parsed.value.capabilities.snapshots);
    try std.testing.expect(!parsed.value.capabilities.changes);
    try std.testing.expect(!parsed.value.capabilities.subscriptions);
}

test "granular feature and unavailable error helpers use stable names" {
    var capabilities: Capabilities = .phase1();
    // M4-P5 flip pin: chat is advertised (was false through M4-P4).
    try std.testing.expect(capabilities.chat);
    try std.testing.expect(!capabilities.store);
    try std.testing.expect(capabilities.snapshots);
    try std.testing.expect(capabilities.changes);
    try std.testing.expect(!capabilities.subscriptions);
    try std.testing.expect(capabilities.workspace_pagination);
    try std.testing.expect(capabilities.thread_pagination);
    try std.testing.expect(capabilities.message_pagination);
    try std.testing.expect(capabilities.provider_status);
    try std.testing.expect(capabilities.repository_projection);
    try std.testing.expect(capabilities.repository_manifests);
    capabilities.terminal_grid = true;
    try std.testing.expect(capabilities.isFeatureAvailable(.terminal_grid));
    try std.testing.expect(!capabilities.isFeatureAvailable(.browser_navigation));

    capabilities = .withBrowser(.{ .navigation = true }, false);
    try std.testing.expect(capabilities.isFeatureAvailable(.browser_navigation));
    try std.testing.expect(!capabilities.isFeatureAvailable(.browser_screenshot));
    try std.testing.expectEqualStrings("browser.navigation", CapabilityFeature.browser_navigation.wireName());

    const unavailable = capabilityUnavailable(.browser_screenshot);
    try std.testing.expectEqualStrings(ERR_CAPABILITY_UNAVAILABLE, unavailable.code);
    try std.testing.expectEqualStrings("browser.screenshot capability is unavailable", unavailable.message);
}
