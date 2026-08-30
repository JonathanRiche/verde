//! Desktop-owned state and actions for the Settings › Runtimes & connections
//! surface and the method-first connection wizard (SSH administrator token,
//! account-free Pair, or a Connect control plane). The controller talks only
//! to the shared runtime Service (profile store, manager, RPC); it never
//! spawns the Verde CLI and never holds a runtime bearer — the masked
//! credential modal in `state.zig` remains the sole UI-owned token copy. The
//! one-time pairing code is the single exception: it is held masked in a
//! zeroed buffer only until the exchange starts, then wiped.

const std = @import("std");
const access_protocol = @import("headless").access_protocol;
const connect_client = @import("../runtime/connect_client.zig");
const profile = @import("../runtime/profile.zig");
const RuntimeService = @import("../runtime/service.zig");

const log = std.log.scoped(.native_runtime_connections);

/// Wizard field capacities mirror the profile validators so a value that fits
/// the buffer is never rejected solely for length after trimming.
pub const LABEL_CAPACITY: usize = 80;
pub const HOST_CAPACITY: usize = 255;
pub const USER_CAPACITY: usize = 64;
pub const PORT_CAPACITY: usize = 5;
pub const GRANT_ID_CAPACITY: usize = access_protocol.GRANT_ID_HEX_BYTES;
pub const PAIRING_CODE_CAPACITY: usize = access_protocol.SECRET_HEX_BYTES;
pub const DEVICE_LABEL_CAPACITY: usize = access_protocol.MAX_DEVICE_LABEL_BYTES;
pub const URL_CAPACITY: usize = profile.MAX_URL_BYTES;
pub const PAIR_LINK_PREFIX: []const u8 = "verde://pair?";
const NOTICE_CAPACITY: usize = 256;
/// Bounded so a hostile or huge manifest cannot grow the settings card
/// without limit; extra rows are reported as a count.
pub const MAX_READINESS_ROWS: usize = 12;

pub const WizardMode = enum { add, edit };
/// Which access method the wizard is configuring. Only Connect needs an
/// account (on the control plane's identity provider).
pub const WizardMethod = enum {
    ssh,
    pair,
    connect,

    pub fn title(self: WizardMethod) []const u8 {
        return switch (self) {
            .ssh => "SSH with administrator token",
            .pair => "Direct / Tailnet (Pair code)",
            .connect => "Connect through a control plane (account required)",
        };
    }

    pub fn description(self: WizardMethod) []const u8 {
        return switch (self) {
            .ssh => "Forward the daemon over SSH and enter its gateway token each session.",
            .pair => "Connect to an HTTPS runtime or Tailscale Serve URL and keep a revocable device credential.",
            .connect => "Sign in to a self-hosted Verde Connect URL and pick a linked runtime. Verde Cloud later.",
        };
    }
};
pub const WizardStep = enum {
    /// Method chooser shown first for new connections.
    method,
    /// SSH and Direct / Tailnet Pair endpoint fields.
    form,
    /// Saved profile with live status and connect/retry.
    testing,
    /// Pair: grant id, one-time code, device label.
    pair_grant,
    /// Pair: runtime identity returned by the exchange awaits confirmation.
    pair_confirm,
    /// Connect: control-plane URL, discovery, sign-in, inventory selection.
    connect_setup,
};
pub const WizardField = enum { label, host, user, ssh_port, gateway_port, grant_id, pairing_code, device_label, control_plane_url };
/// Connect sign-in and bootstrap progress mirrored into the connection wizard.
pub const ConnectPhase = connect_client.Phase;

/// Row actions encoded into one `settings_runtime_action` hit index as
/// `(row << ACTION_BITS) | action`. Row 0 is Local; rows 1.. are profiles in
/// picker order.
pub const RowAction = enum(u8) {
    expand,
    connect,
    retry,
    disable,
    forget_token,
    edit,
    remove,
    remove_confirm,
    remove_cancel,
    copy_diagnostics,
    set_workspace_default,
    add_connection,
    /// Paired profiles: drop the device reference and credential.
    forget_device,
    /// Paired profiles: start (or repeat) the one-time grant exchange.
    pair_device,
    /// Connect profiles: reopen sign-in and runtime selection.
    choose_runtime,
};
pub const ACTION_BITS: u6 = 8;

pub fn encodeRowAction(row: usize, action: RowAction) usize {
    return (row << ACTION_BITS) | @intFromEnum(action);
}

pub const DecodedRowAction = struct { row: usize, action: RowAction };

pub fn decodeRowAction(index: usize) ?DecodedRowAction {
    const raw: usize = index & ((@as(usize, 1) << ACTION_BITS) - 1);
    if (raw >= @typeInfo(RowAction).@"enum".fields.len) return null;
    return .{ .row = index >> ACTION_BITS, .action = @enumFromInt(raw) };
}

pub const ReadinessState = enum { idle, loading, loaded, failed, unsupported, not_ready };

pub const RepositoryRow = struct {
    repository_id: []u8,
    label: []u8,
    /// Runtime-local checkout root reported by the daemon; never a path the
    /// desktop guessed or typed locally.
    root_path: ?[]u8,
    availability: []u8,
    is_default: bool,

    fn deinit(self: *RepositoryRow, allocator: std.mem.Allocator) void {
        allocator.free(self.repository_id);
        allocator.free(self.label);
        if (self.root_path) |value| allocator.free(value);
        allocator.free(self.availability);
        self.* = undefined;
    }
};

pub const ProviderRow = struct {
    label: []u8,
    state: []u8,
    authentication: []u8,
    native_chat: bool,
    terminal_tui: bool,
    mcp: bool,
    lifecycle: bool,
    remediation_label: ?[]u8,
    /// Space-joined command for display only. The desktop has no safe remote
    /// execution surface, so this is shown as guidance and never run.
    remediation_command: ?[]u8,

    fn deinit(self: *ProviderRow, allocator: std.mem.Allocator) void {
        allocator.free(self.label);
        allocator.free(self.state);
        allocator.free(self.authentication);
        if (self.remediation_label) |value| allocator.free(value);
        if (self.remediation_command) |value| allocator.free(value);
        self.* = undefined;
    }
};

pub const State = struct {
    wizard_open: bool = false,
    wizard_mode: WizardMode = .add,
    wizard_method: WizardMethod = .ssh,
    wizard_step: WizardStep = .method,
    /// Profile being edited, or the profile just created by the wizard.
    wizard_profile_id: ?[]u8 = null,
    label_storage: [LABEL_CAPACITY + 1:0]u8 = std.mem.zeroes([LABEL_CAPACITY + 1:0]u8),
    label_cursor: usize = 0,
    host_storage: [HOST_CAPACITY + 1:0]u8 = std.mem.zeroes([HOST_CAPACITY + 1:0]u8),
    host_cursor: usize = 0,
    user_storage: [USER_CAPACITY + 1:0]u8 = std.mem.zeroes([USER_CAPACITY + 1:0]u8),
    user_cursor: usize = 0,
    ssh_port_storage: [PORT_CAPACITY + 1:0]u8 = std.mem.zeroes([PORT_CAPACITY + 1:0]u8),
    ssh_port_cursor: usize = 0,
    gateway_port_storage: [PORT_CAPACITY + 1:0]u8 = std.mem.zeroes([PORT_CAPACITY + 1:0]u8),
    gateway_port_cursor: usize = 0,
    grant_id_storage: [GRANT_ID_CAPACITY + 1:0]u8 = std.mem.zeroes([GRANT_ID_CAPACITY + 1:0]u8),
    grant_id_cursor: usize = 0,
    /// One-time pairing code. Rendered masked, wiped with `secureZero` as
    /// soon as the exchange starts or the wizard closes; never logged.
    pairing_code_storage: [PAIRING_CODE_CAPACITY + 1:0]u8 = std.mem.zeroes([PAIRING_CODE_CAPACITY + 1:0]u8),
    pairing_code_cursor: usize = 0,
    device_label_storage: [DEVICE_LABEL_CAPACITY + 1:0]u8 = std.mem.zeroes([DEVICE_LABEL_CAPACITY + 1:0]u8),
    device_label_cursor: usize = 0,
    control_plane_url_storage: [URL_CAPACITY + 1:0]u8 = std.mem.zeroes([URL_CAPACITY + 1:0]u8),
    control_plane_url_cursor: usize = 0,
    /// True once `beginPairing` accepted the grant; the poll advances to
    /// confirmation or reports the failure.
    pairing_exchange_started: bool = false,
    /// Live Connect session for the wizard's control-plane step.
    connect_session: ?*connect_client.Session = null,
    connect_phase: connect_client.Phase = .idle,
    connect_failure: ?connect_client.Failure = null,
    connect_login_open: bool = false,
    connect_device_flow_advertised: bool = false,
    connect_issuer: ?[]u8 = null,
    connect_runtimes: std.ArrayList(ConnectRuntimeRow) = .empty,
    connect_runtimes_truncated: usize = 0,
    connect_selected: ?usize = null,
    wizard_notice_storage: [NOTICE_CAPACITY:0]u8 = std.mem.zeroes([NOTICE_CAPACITY:0]u8),
    /// Remove requires a second explicit click on the same row.
    remove_confirm_profile_id: ?[]u8 = null,
    /// The row whose repository/provider readiness is shown. Null shows
    /// Local's details.
    expanded_profile_id: ?[]u8 = null,
    readiness_profile_id: ?[]u8 = null,
    manifest_ticket: ?RuntimeService.RpcTicket = null,
    providers_ticket: ?RuntimeService.RpcTicket = null,
    manifest_state: ReadinessState = .idle,
    providers_state: ReadinessState = .idle,
    repositories: std.ArrayList(RepositoryRow) = .empty,
    repositories_truncated: usize = 0,
    providers: std.ArrayList(ProviderRow) = .empty,
    providers_truncated: usize = 0,
    card_notice_storage: [NOTICE_CAPACITY:0]u8 = std.mem.zeroes([NOTICE_CAPACITY:0]u8),

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        if (self.wizard_profile_id) |value| allocator.free(value);
        if (self.remove_confirm_profile_id) |value| allocator.free(value);
        if (self.expanded_profile_id) |value| allocator.free(value);
        if (self.readiness_profile_id) |value| allocator.free(value);
        clearReadinessRows(self, allocator);
        self.repositories.deinit(allocator);
        self.providers.deinit(allocator);
        destroyConnectSession(self, allocator);
        self.connect_runtimes.deinit(allocator);
        std.crypto.secureZero(u8, &self.pairing_code_storage);
        self.* = undefined;
    }

    pub fn connectRuntimeAt(self: *const State, index: usize) ?*const ConnectRuntimeRow {
        if (index >= self.connect_runtimes.items.len) return null;
        return &self.connect_runtimes.items[index];
    }

    pub fn wizardNotice(self: *const State) []const u8 {
        return std.mem.sliceTo(self.wizard_notice_storage[0..], 0);
    }

    pub fn cardNotice(self: *const State) []const u8 {
        return std.mem.sliceTo(self.card_notice_storage[0..], 0);
    }

    pub fn fieldValue(self: *const State, field: WizardField) []const u8 {
        return switch (field) {
            .label => std.mem.sliceTo(self.label_storage[0..], 0),
            .host => std.mem.sliceTo(self.host_storage[0..], 0),
            .user => std.mem.sliceTo(self.user_storage[0..], 0),
            .ssh_port => std.mem.sliceTo(self.ssh_port_storage[0..], 0),
            .gateway_port => std.mem.sliceTo(self.gateway_port_storage[0..], 0),
            .grant_id => std.mem.sliceTo(self.grant_id_storage[0..], 0),
            .pairing_code => std.mem.sliceTo(self.pairing_code_storage[0..], 0),
            .device_label => std.mem.sliceTo(self.device_label_storage[0..], 0),
            .control_plane_url => std.mem.sliceTo(self.control_plane_url_storage[0..], 0),
        };
    }

    pub fn fieldBuffer(self: *State, field: WizardField) [:0]u8 {
        return switch (field) {
            .label => self.label_storage[0..self.label_storage.len :0],
            .host => self.host_storage[0..self.host_storage.len :0],
            .user => self.user_storage[0..self.user_storage.len :0],
            .ssh_port => self.ssh_port_storage[0..self.ssh_port_storage.len :0],
            .gateway_port => self.gateway_port_storage[0..self.gateway_port_storage.len :0],
            .grant_id => self.grant_id_storage[0..self.grant_id_storage.len :0],
            .pairing_code => self.pairing_code_storage[0..self.pairing_code_storage.len :0],
            .device_label => self.device_label_storage[0..self.device_label_storage.len :0],
            .control_plane_url => self.control_plane_url_storage[0..self.control_plane_url_storage.len :0],
        };
    }

    pub fn fieldCursor(self: *State, field: WizardField) *usize {
        return switch (field) {
            .label => &self.label_cursor,
            .host => &self.host_cursor,
            .user => &self.user_cursor,
            .ssh_port => &self.ssh_port_cursor,
            .gateway_port => &self.gateway_port_cursor,
            .grant_id => &self.grant_id_cursor,
            .pairing_code => &self.pairing_code_cursor,
            .device_label => &self.device_label_cursor,
            .control_plane_url => &self.control_plane_url_cursor,
        };
    }

    /// Fields visible on the current step, in Tab order.
    pub fn visibleFields(self: *const State) []const WizardField {
        return switch (self.wizard_step) {
            .form => if (self.wizard_method == .pair)
                &.{ .label, .control_plane_url }
            else
                &.{ .label, .host, .user, .ssh_port, .gateway_port },
            .pair_grant => &.{ .grant_id, .pairing_code, .device_label },
            .connect_setup => &.{ .label, .control_plane_url },
            .method, .testing, .pair_confirm => &.{},
        };
    }

    pub fn isRemoveConfirming(self: *const State, profile_id: []const u8) bool {
        const pending = self.remove_confirm_profile_id orelse return false;
        return std.mem.eql(u8, pending, profile_id);
    }

    pub fn isExpanded(self: *const State, profile_id: ?[]const u8) bool {
        const expanded = self.expanded_profile_id;
        if (profile_id == null) return expanded == null;
        const current = expanded orelse return false;
        return std.mem.eql(u8, current, profile_id.?);
    }
};

/// Validation result for the wizard form. `null` means every field is valid.
pub const ValidationError = struct { field: WizardField, message: []const u8 };

pub fn validateWizardForm(state: *const State) ?ValidationError {
    profile.validateLabel(state.fieldValue(.label)) catch {
        return .{ .field = .label, .message = "Enter a name (1–80 printable characters)." };
    };
    if (state.wizard_method == .pair) {
        if (state.wizard_mode == .add) {
            const link = state.fieldValue(.control_plane_url);
            if (!std.mem.startsWith(u8, link, PAIR_LINK_PREFIX)) {
                return .{ .field = .control_plane_url, .message = "Paste the complete verde://pair link from the runtime." };
            }
            return null;
        }
        profile.validateRuntimeHttpsOrigin(std.mem.trim(u8, state.fieldValue(.control_plane_url), &std.ascii.whitespace)) catch {
            return .{ .field = .control_plane_url, .message = "Enter the runtime as https://host[:port] (a Tailscale Serve URL works)." };
        };
        return null;
    }
    profile.validateSshHost(state.fieldValue(.host)) catch {
        return .{ .field = .host, .message = "Enter an SSH alias, hostname, or IP without spaces or shell characters." };
    };
    profile.validateSshUser(state.fieldValue(.user)) catch {
        return .{ .field = .user, .message = "SSH user may contain letters, digits, '_', '-', and '.'." };
    };
    if (parsePort(state.fieldValue(.ssh_port), profile.DEFAULT_SSH_PORT) == null) {
        return .{ .field = .ssh_port, .message = "SSH port must be 1–65535." };
    }
    if (parsePort(state.fieldValue(.gateway_port), profile.DEFAULT_REMOTE_GATEWAY_PORT) == null) {
        return .{ .field = .gateway_port, .message = "Gateway port must be 1–65535." };
    }
    return null;
}

/// Pair step validation against the shared access-protocol rules.
pub fn validatePairGrantForm(state: *const State) ?ValidationError {
    access_protocol.validateGrantId(state.fieldValue(.grant_id)) catch {
        return .{ .field = .grant_id, .message = "Grant id is the 32-character hex id printed by `verde-daemon pair create`." };
    };
    access_protocol.validateSecret(state.fieldValue(.pairing_code)) catch {
        return .{ .field = .pairing_code, .message = "Pairing code is the 64-character hex secret from the same grant." };
    };
    access_protocol.validateDeviceLabel(state.fieldValue(.device_label)) catch {
        return .{ .field = .device_label, .message = "Device label is 1–128 printable characters shown in the runtime's device list." };
    };
    return null;
}

/// Imports the frozen one-paste Pair URL. The fragment code is copied only to
/// the masked code buffer, then the source link staging buffer is wiped.
pub fn importPairLink(state: *State) !void {
    const link = state.fieldValue(.control_plane_url);
    if (!std.mem.startsWith(u8, link, PAIR_LINK_PREFIX)) return error.InvalidPairLink;
    const hash = std.mem.indexOfScalar(u8, link, '#') orelse return error.InvalidPairLink;
    if (std.mem.indexOfScalarPos(u8, link, hash + 1, '#') != null) return error.InvalidPairLink;
    const query = link[PAIR_LINK_PREFIX.len..hash];
    const fragment = link[hash + 1 ..];
    if (!std.mem.startsWith(u8, fragment, "code=") or std.mem.indexOfScalar(u8, fragment, '&') != null) {
        return error.InvalidPairLink;
    }
    const code = fragment["code=".len..];
    try access_protocol.validateSecret(code);

    var raw_host: ?[]const u8 = null;
    var grant_id: ?[]const u8 = null;
    var fields = std.mem.splitScalar(u8, query, '&');
    while (fields.next()) |field| {
        const eq = std.mem.indexOfScalar(u8, field, '=') orelse return error.InvalidPairLink;
        const name = field[0..eq];
        const value = field[eq + 1 ..];
        if (std.mem.eql(u8, name, "host")) {
            if (raw_host != null) return error.InvalidPairLink;
            raw_host = value;
        } else if (std.mem.eql(u8, name, "grant_id")) {
            if (grant_id != null) return error.InvalidPairLink;
            grant_id = value;
        } else return error.InvalidPairLink;
    }
    const encoded_host = raw_host orelse return error.InvalidPairLink;
    const grant = grant_id orelse return error.InvalidPairLink;
    try access_protocol.validateGrantId(grant);
    if (std.mem.indexOfScalar(u8, encoded_host, '%') == null or
        std.mem.indexOfAny(u8, encoded_host, ":/") != null)
    {
        return error.InvalidPairLink;
    }
    try validatePercentEncoding(encoded_host);
    var host_buffer: [URL_CAPACITY]u8 = undefined;
    if (encoded_host.len > host_buffer.len) return error.InvalidPairLink;
    @memcpy(host_buffer[0..encoded_host.len], encoded_host);
    const host = std.Uri.percentDecodeInPlace(host_buffer[0..encoded_host.len]);
    try profile.validateRuntimeHttpsOrigin(host);
    const uri = std.Uri.parse(host) catch return error.InvalidPairLink;
    if (uri.user != null or uri.password != null or uri.query != null or uri.fragment != null) return error.InvalidPairLink;
    const path = switch (uri.path) {
        .raw => |value| value,
        .percent_encoded => |value| value,
    };
    if (path.len != 0 and !std.mem.eql(u8, path, "/")) return error.InvalidPairLink;

    var grant_copy: [GRANT_ID_CAPACITY]u8 = undefined;
    @memcpy(grant_copy[0..grant.len], grant);
    var code_copy: [PAIRING_CODE_CAPACITY]u8 = undefined;
    defer std.crypto.secureZero(u8, &code_copy);
    @memcpy(code_copy[0..code.len], code);

    // All validation happens before mutation. Once accepted, erase the link
    // (including fragment), then retain only split values in their proper UI
    // buffers; the code buffer is rendered/edited as a secret.
    std.crypto.secureZero(u8, &state.control_plane_url_storage);
    fillZ(&state.control_plane_url_storage, std.mem.trimEnd(u8, host, "/"));
    fillZ(&state.grant_id_storage, grant_copy[0..grant.len]);
    fillZ(&state.pairing_code_storage, code_copy[0..code.len]);
    state.control_plane_url_cursor = state.fieldValue(.control_plane_url).len;
    state.grant_id_cursor = grant.len;
    state.pairing_code_cursor = code.len;
}

fn validatePercentEncoding(value: []const u8) !void {
    var index: usize = 0;
    while (index < value.len) : (index += 1) {
        if (value[index] != '%') continue;
        if (index + 2 >= value.len or !std.ascii.isHex(value[index + 1]) or !std.ascii.isHex(value[index + 2])) {
            return error.InvalidPairLink;
        }
        index += 2;
    }
}

/// Connect step validation: name plus a bare https:// control-plane URL.
pub fn validateConnectForm(state: *const State) ?ValidationError {
    profile.validateLabel(state.fieldValue(.label)) catch {
        return .{ .field = .label, .message = "Enter a name (1–80 printable characters)." };
    };
    const trimmed = std.mem.trim(u8, state.fieldValue(.control_plane_url), &std.ascii.whitespace);
    profile.validateHttpsUrl(trimmed) catch {
        return .{ .field = .control_plane_url, .message = "Enter the control plane as https://host[:port] with no credentials, query, or fragment." };
    };
    return null;
}

/// Empty means the documented default; anything else must be a valid port.
pub fn parsePort(value: []const u8, default: u16) ?u16 {
    const trimmed = std.mem.trim(u8, value, &std.ascii.whitespace);
    if (trimmed.len == 0) return default;
    const port = std.fmt.parseInt(u16, trimmed, 10) catch return null;
    profile.validatePort(port) catch return null;
    return port;
}

/// Port fields accept digits only so paste of "22\n" or "abc" cannot leave an
/// unparseable draft; the shared modal path already strips control bytes.
pub fn filterPortText(text: []const u8, out: []u8) []const u8 {
    var n: usize = 0;
    for (text) |byte| {
        if (!std.ascii.isDigit(byte) or n >= out.len) continue;
        out[n] = byte;
        n += 1;
    }
    return out[0..n];
}

pub fn wizardSshInput(state: *const State) profile.SshTunnelInput {
    const user = std.mem.trim(u8, state.fieldValue(.user), &std.ascii.whitespace);
    return .{
        .host = state.fieldValue(.host),
        .user = if (user.len == 0) null else user,
        .port = parsePort(state.fieldValue(.ssh_port), profile.DEFAULT_SSH_PORT) orelse profile.DEFAULT_SSH_PORT,
        .remote_gateway_port = parsePort(state.fieldValue(.gateway_port), profile.DEFAULT_REMOTE_GATEWAY_PORT) orelse profile.DEFAULT_REMOTE_GATEWAY_PORT,
    };
}

// ---------------------------------------------------------------------------
// Wizard lifecycle (self is *AppState)
// ---------------------------------------------------------------------------

/// Opens the wizard for a new runtime at the method chooser. Any prior draft
/// is discarded.
pub fn openRuntimeConnectionWizard(self: anytype) void {
    const rc = &self.runtime_connections;
    resetWizardFields(rc);
    destroyConnectSession(rc, self.allocator);
    setWizardProfileId(self, null);
    rc.wizard_mode = .add;
    rc.wizard_method = .ssh;
    rc.wizard_step = .method;
    rc.wizard_open = true;
    setNotice(&rc.wizard_notice_storage, "");
    self.closePaletteRuntimePicker();
    self.closePaletteModelPicker();
    self.closePaletteDirectoryPicker();
    self.closeRunConfigPopover();
    blurWizardField(self);
}

/// Method chooser selection: moves to that method's first input step.
pub fn chooseRuntimeWizardMethod(self: anytype, method: WizardMethod) void {
    const rc = &self.runtime_connections;
    if (!rc.wizard_open or rc.wizard_step != .method) return;
    rc.wizard_method = method;
    setNotice(&rc.wizard_notice_storage, "");
    switch (method) {
        .ssh, .pair => {
            rc.wizard_step = .form;
            focusWizardField(self, .label);
        },
        .connect => {
            rc.wizard_step = .connect_setup;
            focusWizardField(self, .label);
        },
    }
    self.markDirty();
}

/// Opens the wizard pre-filled with a saved profile's non-secret fields.
pub fn openRuntimeConnectionEditor(self: anytype, profile_id: []const u8) void {
    const service = self.runtime_service orelse return;
    const configured = service.runtime_manager.profileConst(profile_id) orelse {
        self.setSidebarNotice("That runtime is no longer configured.");
        return;
    };
    const rc = &self.runtime_connections;
    resetWizardFields(rc);
    destroyConnectSession(rc, self.allocator);
    fillZ(&rc.label_storage, configured.label);
    rc.wizard_method = switch (configured.access) {
        .admin_token => .ssh,
        .paired_device => .pair,
        .connect => .connect,
    };
    rc.wizard_step = .form;
    switch (configured.transport) {
        .ssh_tunnel => |ssh| {
            fillZ(&rc.host_storage, ssh.host);
            if (ssh.user) |user| fillZ(&rc.user_storage, user);
            var port_buf: [PORT_CAPACITY]u8 = undefined;
            fillZ(&rc.ssh_port_storage, std.fmt.bufPrint(&port_buf, "{d}", .{ssh.port}) catch "");
            fillZ(&rc.gateway_port_storage, std.fmt.bufPrint(&port_buf, "{d}", .{ssh.remote_gateway_port}) catch "");
        },
        .direct_https => |endpoint| {
            fillZ(&rc.control_plane_url_storage, endpoint.https_url orelse "");
        },
        .connect => {
            fillZ(&rc.control_plane_url_storage, configured.access.connect.control_plane_url);
            rc.wizard_step = .connect_setup;
        },
        .local_socket => {},
    }
    inline for (.{ .label, .host, .user, .ssh_port, .gateway_port, .control_plane_url }) |field| {
        rc.fieldCursor(field).* = rc.fieldValue(field).len;
    }
    setWizardProfileId(self, profile_id);
    rc.wizard_mode = .edit;
    rc.wizard_open = true;
    setNotice(&rc.wizard_notice_storage, "");
    focusWizardField(self, .label);
}

/// Opens the grant step for an existing paired profile (first pairing or a
/// re-pair that replaces the device).
pub fn openRuntimePairing(self: anytype, profile_id: []const u8) void {
    const service = self.runtime_service orelse return;
    const configured = service.runtime_manager.profileConst(profile_id) orelse {
        self.setSidebarNotice("That runtime is no longer configured.");
        return;
    };
    if (configured.access != .paired_device) return;
    const rc = &self.runtime_connections;
    resetWizardFields(rc);
    destroyConnectSession(rc, self.allocator);
    setWizardProfileId(self, profile_id);
    rc.wizard_mode = .edit;
    rc.wizard_method = .pair;
    rc.wizard_open = true;
    enterPairGrantStep(self, if (configured.access.paired_device.isPaired())
        "Re-pairing replaces this device's credential. Revoke the old device on the runtime afterwards."
    else
        "");
    self.closePaletteRuntimePicker();
}

pub fn cancelRuntimeConnectionWizard(self: anytype) void {
    const rc = &self.runtime_connections;
    abandonWizardPairing(self);
    destroyConnectSession(rc, self.allocator);
    rc.wizard_open = false;
    rc.wizard_step = .method;
    resetWizardFields(rc);
    setWizardProfileId(self, null);
    setNotice(&rc.wizard_notice_storage, "");
    blurWizardField(self);
    self.markDirty();
}

/// Back/Edit button: one step towards the beginning without losing the
/// saved profile.
pub fn runtimeConnectionWizardBack(self: anytype) void {
    const rc = &self.runtime_connections;
    switch (rc.wizard_step) {
        .method => {},
        .form, .connect_setup => {
            if (rc.wizard_mode == .add and rc.wizard_profile_id == null) {
                destroyConnectSession(rc, self.allocator);
                rc.wizard_step = .method;
                setNotice(&rc.wizard_notice_storage, "");
                blurWizardField(self);
            }
        },
        .testing => {
            const profile_id = rc.wizard_profile_id orelse {
                rc.wizard_step = .method;
                return;
            };
            const owned = self.allocator.dupe(u8, profile_id) catch return;
            defer self.allocator.free(owned);
            openRuntimeConnectionEditor(self, owned);
        },
        .pair_grant => {
            abandonWizardPairing(self);
            rc.wizard_step = .testing;
            blurWizardField(self);
        },
        .pair_confirm => {
            // Declining the identity wipes the exchanged credential; the
            // runtime still lists the device until revoked there.
            abandonWizardPairing(self);
            enterPairGrantStep(self, "Pairing canceled. The runtime may still list this device; revoke it there, then mint a new grant.");
        },
    }
    self.markDirty();
}

/// Primary button: validates the current step, persists through the shared
/// service, and advances. Never touches a runtime bearer.
pub fn submitRuntimeConnectionWizard(self: anytype) void {
    const rc = &self.runtime_connections;
    if (!rc.wizard_open) return;
    switch (rc.wizard_step) {
        .form => submitEndpointForm(self),
        .pair_grant => submitPairGrant(self),
        .pair_confirm => confirmPairing(self),
        .connect_setup => submitConnectSetup(self),
        .method, .testing => {},
    }
}

fn submitEndpointForm(self: anytype) void {
    const rc = &self.runtime_connections;
    if (validateWizardForm(rc)) |failure| {
        setNotice(&rc.wizard_notice_storage, failure.message);
        focusWizardField(self, failure.field);
        self.markDirty();
        return;
    }
    const service = self.runtime_service orelse {
        setNotice(&rc.wizard_notice_storage, "Runtime service is unavailable.");
        return;
    };
    if (rc.wizard_method == .pair) return submitDirectPairForm(self, service);
    const input: RuntimeService.SshProfileInput = .{
        .label = rc.fieldValue(.label),
        .ssh = wizardSshInput(rc),
    };
    switch (rc.wizard_mode) {
        .add => {
            const id = (if (rc.wizard_method == .pair)
                service.createPairedProfile(self.allocator, input)
            else
                service.createSshProfile(self.allocator, input)) catch |err| {
                setNotice(&rc.wizard_notice_storage, saveFailureMessage(err));
                log.warn("runtime profile create failed: {s}", .{@errorName(err)});
                self.markDirty();
                return;
            };
            defer self.allocator.free(id);
            self.appendRuntimePickerProfile(id) catch |err| {
                log.warn("runtime picker append failed: {s}", .{@errorName(err)});
            };
            setWizardProfileId(self, id);
            self.syncPaletteRuntimePicker();
            if (rc.wizard_method == .pair) {
                enterPairGrantStep(self, "Saved. Enter the one-time grant from `verde-daemon pair create` on the runtime host.");
                self.markDirty();
                return;
            }
            setNotice(&rc.wizard_notice_storage, "Saved. Connect to verify the daemon identity.");
        },
        .edit => {
            const profile_id = rc.wizard_profile_id orelse return;
            const replacement = service.updateSshProfile(profile_id, input) catch |err| {
                setNotice(&rc.wizard_notice_storage, saveFailureMessage(err));
                log.warn("runtime profile update failed: {s}", .{@errorName(err)});
                self.markDirty();
                return;
            };
            setNotice(&rc.wizard_notice_storage, switch (replacement) {
                .label_only => "Saved.",
                .endpoint_changed => "Endpoint changed: saved trust was cleared and the daemon identity must be verified again.",
            });
            if (replacement == .endpoint_changed) invalidateReadiness(self, profile_id);
        },
    }
    rc.wizard_step = .testing;
    blurWizardField(self);
    self.syncPaletteRuntimePicker();
    self.markDirty();
}

fn submitDirectPairForm(self: anytype, service: *RuntimeService) void {
    const rc = &self.runtime_connections;
    if (rc.wizard_mode == .add) importPairLink(rc) catch {
        setNotice(&rc.wizard_notice_storage, "Paste the complete verde://pair link. Manual host, grant ID, and code entry is available after import.");
        focusWizardField(self, .control_plane_url);
        self.markDirty();
        return;
    };
    const url = std.mem.trim(u8, rc.fieldValue(.control_plane_url), &std.ascii.whitespace);
    switch (rc.wizard_mode) {
        .add => {
            const id = service.createDirectPairedProfile(self.allocator, rc.fieldValue(.label), url) catch |err| {
                setNotice(&rc.wizard_notice_storage, saveFailureMessage(err));
                log.warn("direct paired runtime profile create failed: {s}", .{@errorName(err)});
                self.markDirty();
                return;
            };
            defer self.allocator.free(id);
            self.appendRuntimePickerProfile(id) catch {};
            setWizardProfileId(self, id);
            self.syncPaletteRuntimePicker();
            enterPairGrantStep(self, "HTTPS endpoint saved. Enter the grant ID and masked one-time code from `verde-server pair create`.");
        },
        .edit => {
            const profile_id = rc.wizard_profile_id orelse return;
            const replacement = service.updateDirectPairedProfile(profile_id, rc.fieldValue(.label), url) catch |err| {
                setNotice(&rc.wizard_notice_storage, saveFailureMessage(err));
                log.warn("direct paired runtime profile update failed: {s}", .{@errorName(err)});
                self.markDirty();
                return;
            };
            if (replacement == .endpoint_changed) invalidateReadiness(self, profile_id);
            rc.wizard_step = .testing;
            setNotice(&rc.wizard_notice_storage, if (replacement == .endpoint_changed)
                "Endpoint changed. The old credential and identity trust were cleared; pair again."
            else
                "Saved.");
        },
    }
    blurWizardField(self);
    self.markDirty();
}

fn enterPairGrantStep(self: anytype, notice: []const u8) void {
    const rc = &self.runtime_connections;
    rc.wizard_step = .pair_grant;
    rc.pairing_exchange_started = false;
    setNotice(&rc.wizard_notice_storage, notice);
    focusWizardField(self, .grant_id);
}

/// Hands the grant to the manager and wipes the local copy of the code.
fn submitPairGrant(self: anytype) void {
    const rc = &self.runtime_connections;
    if (rc.pairing_exchange_started) return;
    if (validatePairGrantForm(rc)) |failure| {
        setNotice(&rc.wizard_notice_storage, failure.message);
        focusWizardField(self, failure.field);
        self.markDirty();
        return;
    }
    const service = self.runtime_service orelse {
        setNotice(&rc.wizard_notice_storage, "Runtime service is unavailable.");
        return;
    };
    const profile_id = rc.wizard_profile_id orelse return;
    service.beginPairing(profile_id, .{
        .grant_id = rc.fieldValue(.grant_id),
        .pairing_token = rc.fieldValue(.pairing_code),
        .device_label = rc.fieldValue(.device_label),
    }, self.runtimeNowMs()) catch |err| {
        setNotice(&rc.wizard_notice_storage, pairingFailureMessage(err));
        log.warn("pairing start failed: {s}", .{@errorName(err)});
        self.markDirty();
        return;
    };
    std.crypto.secureZero(u8, &rc.pairing_code_storage);
    rc.pairing_code_cursor = 0;
    rc.pairing_exchange_started = true;
    invalidateReadiness(self, profile_id);
    setNotice(&rc.wizard_notice_storage, "Exchanging the grant over SSH…");
    blurWizardField(self);
    self.markDirty();
}

/// Persists the device reference plus the exchanged identity pin and starts
/// the first authenticated connection.
fn confirmPairing(self: anytype) void {
    const rc = &self.runtime_connections;
    const service = self.runtime_service orelse return;
    const profile_id = rc.wizard_profile_id orelse return;
    const commit = service.commitPairing(profile_id, self.runtimeNowMs()) catch |err| {
        setNotice(&rc.wizard_notice_storage, pairingFailureMessage(err));
        log.warn("pairing commit failed: {s}", .{@errorName(err)});
        self.markDirty();
        return;
    };
    rc.pairing_exchange_started = false;
    rc.wizard_step = .testing;
    setNotice(&rc.wizard_notice_storage, if (commit.durable)
        "Device paired. The credential is stored in the OS keyring by reference; the profile file holds no secret."
    else
        "Device paired for this session only: no OS keyring is available, so you must pair again after relaunch.");
    invalidateReadiness(self, profile_id);
    self.syncPaletteRuntimePicker();
    self.markDirty();
}

fn abandonWizardPairing(self: anytype) void {
    const rc = &self.runtime_connections;
    if (!rc.pairing_exchange_started) return;
    rc.pairing_exchange_started = false;
    const service = self.runtime_service orelse return;
    const profile_id = rc.wizard_profile_id orelse return;
    service.abandonPairing(profile_id) catch |err| {
        log.warn("pairing abandon failed: {s}", .{@errorName(err)});
    };
}

/// Connect step primary action, driven by the session phase: save and
/// discover, sign in, then adopt the selected runtime.
fn submitConnectSetup(self: anytype) void {
    const rc = &self.runtime_connections;
    const service = self.runtime_service orelse {
        setNotice(&rc.wizard_notice_storage, "Runtime service is unavailable.");
        return;
    };
    if (rc.connect_session == null or rc.connect_phase == .failed or rc.connect_phase == .idle) {
        if (validateConnectForm(rc)) |failure| {
            setNotice(&rc.wizard_notice_storage, failure.message);
            focusWizardField(self, failure.field);
            self.markDirty();
            return;
        }
        const url = std.mem.trim(u8, rc.fieldValue(.control_plane_url), &std.ascii.whitespace);
        if (rc.wizard_profile_id) |profile_id| {
            const replacement = service.updateConnectProfile(profile_id, rc.fieldValue(.label), url) catch |err| {
                setNotice(&rc.wizard_notice_storage, saveFailureMessage(err));
                self.markDirty();
                return;
            };
            if (replacement == .endpoint_changed) invalidateReadiness(self, profile_id);
        } else {
            const id = service.createConnectProfile(self.allocator, rc.fieldValue(.label), url) catch |err| {
                setNotice(&rc.wizard_notice_storage, saveFailureMessage(err));
                log.warn("connect profile create failed: {s}", .{@errorName(err)});
                self.markDirty();
                return;
            };
            defer self.allocator.free(id);
            self.appendRuntimePickerProfile(id) catch |err| {
                log.warn("runtime picker append failed: {s}", .{@errorName(err)});
            };
            setWizardProfileId(self, id);
            self.syncPaletteRuntimePicker();
        }
        destroyConnectSession(rc, self.allocator);
        rc.connect_session = connect_client.Session.start(self.allocator, url) catch |err| {
            setNotice(&rc.wizard_notice_storage, if (err == error.OutOfMemory) "Out of memory." else "Enter the control plane as https://host[:port].");
            self.markDirty();
            return;
        };
        rc.connect_phase = .discovering;
        rc.connect_failure = null;
        setNotice(&rc.wizard_notice_storage, "Saved. Checking the control plane's discovery document…");
        blurWizardField(self);
        self.markDirty();
        return;
    }
    const session = rc.connect_session.?;
    switch (rc.connect_phase) {
        .discovered => {
            if (session.signIn()) {
                rc.connect_phase = .signing_in;
                setNotice(&rc.wizard_notice_storage, "Opening the system browser for sign-in (PKCE, loopback redirect)…");
            }
        },
        .signed_in => {
            if (session.loadInventory()) rc.connect_phase = .loading_inventory;
        },
        .inventory_loaded => adoptSelectedConnectRuntime(self, service),
        .discovering, .signing_in, .loading_inventory, .bootstrapping, .bootstrap_ready, .idle, .failed => {},
    }
    self.markDirty();
}

fn adoptSelectedConnectRuntime(self: anytype, service: *RuntimeService) void {
    const rc = &self.runtime_connections;
    const profile_id = rc.wizard_profile_id orelse return;
    const index = rc.connect_selected orelse {
        setNotice(&rc.wizard_notice_storage, "Select a linked runtime first.");
        return;
    };
    const row = rc.connectRuntimeAt(index) orelse return;
    service.selectConnectRuntime(profile_id, .{
        .link_id = row.link_id,
        .runtime_id = row.runtime_id,
        .instance_id = row.instance_id,
        .https_url = row.https_url,
        .wss_url = row.wss_url,
        .spki_sha256 = row.spki_sha256,
    }) catch |err| {
        setNotice(&rc.wizard_notice_storage, saveFailureMessage(err));
        log.warn("connect runtime selection failed: {s}", .{@errorName(err)});
        return;
    };
    const session = rc.connect_session orelse return;
    if (!session.bootstrap(index, rc.fieldValue(.label))) {
        setNotice(&rc.wizard_notice_storage, "Could not start the signed runtime bootstrap. Sign in again and retry.");
        return;
    }
    rc.connect_phase = .bootstrapping;
    setNotice(&rc.wizard_notice_storage, "Endpoint saved. Requesting a signed grant and creating the runtime-local device…");
    blurWizardField(self);
    self.syncPaletteRuntimePicker();
}

/// Selects one inventory row on the Connect step.
pub fn selectRuntimeWizardConnectRuntime(self: anytype, index: usize) void {
    const rc = &self.runtime_connections;
    if (rc.wizard_step != .connect_setup or rc.connectRuntimeAt(index) == null) return;
    rc.connect_selected = index;
    self.markDirty();
}

/// Middle button: connect/retry on the status step, decline on pairing
/// confirmation, sign out on the Connect step.
pub fn runtimeConnectionWizardConnect(self: anytype) void {
    const rc = &self.runtime_connections;
    switch (rc.wizard_step) {
        .testing => {
            const profile_id = rc.wizard_profile_id orelse return;
            if (self.runtime_service) |service| {
                if (service.runtime_manager.profileConst(profile_id)) |configured| {
                    if (configured.access == .paired_device and !configured.access.paired_device.isPaired()) {
                        enterPairGrantStep(self, "");
                        self.markDirty();
                        return;
                    }
                }
            }
            self.connectRuntimeProfileFromPicker(profile_id);
        },
        .pair_confirm => runtimeConnectionWizardBack(self),
        .connect_setup => {
            if (rc.connect_session) |session| {
                session.signOut();
                clearConnectRuntimes(rc, self.allocator);
                rc.connect_phase = .discovered;
                setNotice(&rc.wizard_notice_storage, "Signed out. The OIDC token was wiped from memory.");
            }
        },
        .method, .form, .pair_grant => {},
    }
    self.markDirty();
}

pub fn focusWizardField(self: anytype, field: WizardField) void {
    self.palette_modal_text_focus = switch (field) {
        .label => .runtime_wizard_label,
        .host => .runtime_wizard_host,
        .user => .runtime_wizard_user,
        .ssh_port => .runtime_wizard_ssh_port,
        .gateway_port => .runtime_wizard_gateway_port,
        .grant_id => .runtime_wizard_grant_id,
        .pairing_code => .runtime_wizard_pairing_code,
        .device_label => .runtime_wizard_device_label,
        .control_plane_url => .runtime_wizard_control_plane_url,
    };
    self.modal_text_selection_anchor = null;
    self.modal_text_drag_active = false;
}

pub fn focusedWizardField(focus: anytype) ?WizardField {
    return switch (focus) {
        .runtime_wizard_label => .label,
        .runtime_wizard_host => .host,
        .runtime_wizard_user => .user,
        .runtime_wizard_ssh_port => .ssh_port,
        .runtime_wizard_gateway_port => .gateway_port,
        .runtime_wizard_grant_id => .grant_id,
        .runtime_wizard_pairing_code => .pairing_code,
        .runtime_wizard_device_label => .device_label,
        .runtime_wizard_control_plane_url => .control_plane_url,
        else => null,
    };
}

/// Tab / Shift+Tab order through the current step's fields.
pub fn cycleWizardField(self: anytype, backwards: bool) void {
    const rc = &self.runtime_connections;
    const fields = rc.visibleFields();
    if (fields.len == 0) return;
    const current = focusedWizardField(self.palette_modal_text_focus);
    var index: ?usize = null;
    if (current) |value| {
        for (fields, 0..) |candidate, position| if (candidate == value) {
            index = position;
        };
    }
    const next = if (index) |position|
        (if (backwards) (position + fields.len - 1) % fields.len else (position + 1) % fields.len)
    else if (backwards) fields.len - 1 else 0;
    focusWizardField(self, fields[next]);
}

fn blurWizardField(self: anytype) void {
    if (focusedWizardField(self.palette_modal_text_focus) == null) return;
    self.palette_modal_text_focus = .none;
    self.modal_text_selection_anchor = null;
    self.modal_text_drag_active = false;
}

// ---------------------------------------------------------------------------
// Wizard polling: pairing exchange progress and the Connect session
// ---------------------------------------------------------------------------

/// Advances the open wizard from background progress. Returns true on change.
pub fn pollRuntimeConnectionWizard(self: anytype) bool {
    const rc = &self.runtime_connections;
    if (!rc.wizard_open) return false;
    return switch (rc.wizard_step) {
        .pair_grant => pollPairingExchange(self),
        .connect_setup => pollConnectSession(self),
        else => false,
    };
}

fn pollPairingExchange(self: anytype) bool {
    const rc = &self.runtime_connections;
    if (!rc.pairing_exchange_started) return false;
    const service = self.runtime_service orelse return false;
    const profile_id = rc.wizard_profile_id orelse return false;
    const snapshot = service.snapshot(profile_id) orelse return false;
    if (snapshot.pairing_state == .awaiting_confirmation) {
        rc.wizard_step = .pair_confirm;
        setNotice(&rc.wizard_notice_storage, "Compare both IDs with `verde-daemon identity` on the runtime host before confirming.");
        blurWizardField(self);
        return true;
    }
    if (snapshot.phase == .disabled or snapshot.phase == .failed) {
        rc.pairing_exchange_started = false;
        setNotice(&rc.wizard_notice_storage, if (snapshot.failure) |failure| pairingSnapshotFailureMessage(failure) else "The exchange stopped before completing. Try again.");
        focusWizardField(self, .grant_id);
        return true;
    }
    return false;
}

fn pollConnectSession(self: anytype) bool {
    const rc = &self.runtime_connections;
    const session = rc.connect_session orelse return false;
    const snapshot = session.poll();
    var changed = snapshot.phase != rc.connect_phase or snapshot.failure != rc.connect_failure or snapshot.login_url_open != rc.connect_login_open;
    rc.connect_phase = snapshot.phase;
    rc.connect_failure = snapshot.failure;
    rc.connect_login_open = snapshot.login_url_open;
    rc.connect_device_flow_advertised = snapshot.device_flow_advertised;
    if (snapshot.phase == .bootstrap_ready) {
        if (session.takeBootstrapResult()) |owned_result| {
            var result = owned_result;
            defer result.deinit();
            const service = self.runtime_service orelse return changed;
            const profile_id = rc.wizard_profile_id orelse return changed;
            const committed = service.commitConnectBootstrap(profile_id, .{
                .runtime_id = result.runtime_id,
                .instance_id = result.instance_id,
                .device_id = result.device_id,
                .device_credential = result.device_credential,
            }, self.runtimeNowMs()) catch |err| {
                destroyConnectSession(rc, self.allocator);
                rc.connect_phase = .failed;
                rc.connect_failure = null;
                setNotice(&rc.wizard_notice_storage, saveFailureMessage(err));
                return true;
            };
            destroyConnectSession(rc, self.allocator);
            invalidateReadiness(self, profile_id);
            rc.wizard_step = .testing;
            setNotice(&rc.wizard_notice_storage, if (committed.durable)
                "Connected. OIDC, signed grant, and device-key staging were wiped; the runtime-local credential is in the secret store."
            else
                "Connected, but this platform could keep the runtime-local credential only in memory.");
            blurWizardField(self);
            self.syncPaletteRuntimePicker();
            return true;
        }
    }
    if (!optionalStringsEqual(rc.connect_issuer, snapshot.issuer)) {
        if (rc.connect_issuer) |value| self.allocator.free(value);
        rc.connect_issuer = if (snapshot.issuer) |value| self.allocator.dupe(u8, value) catch null else null;
        changed = true;
    }
    if (snapshot.runtimes.len != rc.connect_runtimes.items.len or snapshot.runtimes_truncated != rc.connect_runtimes_truncated) {
        clearConnectRuntimes(rc, self.allocator);
        for (snapshot.runtimes) |row| {
            const copy = ConnectRuntimeRow.clone(self.allocator, row) catch break;
            rc.connect_runtimes.append(self.allocator, copy) catch {
                var owned = copy;
                owned.deinit(self.allocator);
                break;
            };
        }
        rc.connect_runtimes_truncated = snapshot.runtimes_truncated;
        if (rc.connect_runtimes.items.len == 1) rc.connect_selected = 0;
        changed = true;
    }
    if (changed) {
        if (snapshot.failure) |failure| {
            setNotice(&rc.wizard_notice_storage, failure.message());
        } else switch (snapshot.phase) {
            .discovered => setNotice(&rc.wizard_notice_storage, "Discovery verified. Sign in with the control plane's identity provider to list your runtimes."),
            .signed_in => {
                // Inventory needs no further user input; fetch it right away.
                if (session.loadInventory()) rc.connect_phase = .loading_inventory;
                setNotice(&rc.wizard_notice_storage, "Signed in. Loading linked runtimes…");
            },
            .inventory_loaded => setNotice(&rc.wizard_notice_storage, if (rc.connect_runtimes.items.len == 0)
                "No runtimes are linked to this account yet. Link one with `verde-daemon connect link` on the runtime host."
            else
                "Select the runtime to use with this profile."),
            .bootstrapping => setNotice(&rc.wizard_notice_storage, "Requesting and consuming the signed Connect bootstrap…"),
            .bootstrap_ready => {},
            .signing_in => {},
            .discovering, .loading_inventory, .idle, .failed => {},
        }
    }
    return changed;
}

/// UI copy of one inventory row so rendering never borrows worker memory.
pub const ConnectRuntimeRow = struct {
    link_id: []u8,
    runtime_id: []u8,
    instance_id: []u8,
    https_url: []u8,
    wss_url: []u8,
    spki_sha256: []u8,

    fn clone(allocator: std.mem.Allocator, row: connect_client.RuntimeRow) !ConnectRuntimeRow {
        var out: ConnectRuntimeRow = undefined;
        out.link_id = try allocator.dupe(u8, row.link_id);
        errdefer allocator.free(out.link_id);
        out.runtime_id = try allocator.dupe(u8, row.runtime_id);
        errdefer allocator.free(out.runtime_id);
        out.instance_id = try allocator.dupe(u8, row.instance_id);
        errdefer allocator.free(out.instance_id);
        out.https_url = try allocator.dupe(u8, row.https_url);
        errdefer allocator.free(out.https_url);
        out.wss_url = try allocator.dupe(u8, row.wss_url);
        errdefer allocator.free(out.wss_url);
        out.spki_sha256 = try allocator.dupe(u8, row.spki_sha256);
        return out;
    }

    fn deinit(self: *ConnectRuntimeRow, allocator: std.mem.Allocator) void {
        allocator.free(self.link_id);
        allocator.free(self.runtime_id);
        allocator.free(self.instance_id);
        allocator.free(self.https_url);
        allocator.free(self.wss_url);
        allocator.free(self.spki_sha256);
        self.* = undefined;
    }
};

fn clearConnectRuntimes(rc: *State, allocator: std.mem.Allocator) void {
    for (rc.connect_runtimes.items) |*row| row.deinit(allocator);
    rc.connect_runtimes.clearRetainingCapacity();
    rc.connect_runtimes_truncated = 0;
    rc.connect_selected = null;
}

fn destroyConnectSession(rc: *State, allocator: std.mem.Allocator) void {
    if (rc.connect_session) |session| session.destroy();
    rc.connect_session = null;
    rc.connect_phase = .idle;
    rc.connect_failure = null;
    rc.connect_login_open = false;
    rc.connect_device_flow_advertised = false;
    if (rc.connect_issuer) |value| allocator.free(value);
    rc.connect_issuer = null;
    clearConnectRuntimes(rc, allocator);
}

fn optionalStringsEqual(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

// ---------------------------------------------------------------------------
// Row actions
// ---------------------------------------------------------------------------

/// Applies one encoded settings-card action. Row 0 is Local.
pub fn applyRuntimeRowAction(self: anytype, index: usize) void {
    const decoded = decodeRowAction(index) orelse return;
    const rc = &self.runtime_connections;
    if (decoded.action == .add_connection) {
        openRuntimeConnectionWizard(self);
        return;
    }
    if (decoded.row == 0) {
        switch (decoded.action) {
            .expand => setExpandedProfile(self, null),
            .set_workspace_default => self.useLocalAsWorkspaceRuntimeDefault(),
            else => {},
        }
        self.markDirty();
        return;
    }
    const profile_index = decoded.row - 1;
    if (profile_index >= self.runtime_picker_profiles.items.len) return;
    // Copy: actions below may mutate the profile list.
    const profile_id = self.allocator.dupe(u8, self.runtime_picker_profiles.items[profile_index].profile_id) catch return;
    defer self.allocator.free(profile_id);
    const service = self.runtime_service orelse return;
    const now_ms = self.runtimeNowMs();

    if (decoded.action != .remove_confirm and decoded.action != .remove) clearRemoveConfirm(self);
    switch (decoded.action) {
        .expand => setExpandedProfile(self, profile_id),
        .connect, .retry => self.connectRuntimeProfileFromPicker(profile_id),
        .disable => {
            service.disable(profile_id) catch |err| {
                log.warn("runtime disable failed: {s}", .{@errorName(err)});
                setNotice(&rc.card_notice_storage, "Could not disable that runtime.");
            };
            invalidateReadiness(self, profile_id);
        },
        .forget_token => {
            const clean = self.revokeRuntimeProfileCredential(profile_id);
            invalidateReadiness(self, profile_id);
            setNotice(&rc.card_notice_storage, if (clean)
                "Credential forgotten. It was never written to disk."
            else
                "Credential forgotten; connection cleanup will finish in the background.");
        },
        .edit => openRuntimeConnectionEditor(self, profile_id),
        .forget_device => {
            const held = service.forgetDevice(profile_id) catch |err| {
                log.warn("forget device failed: {s}", .{@errorName(err)});
                setNotice(&rc.card_notice_storage, "Could not forget the paired device.");
                return;
            };
            invalidateReadiness(self, profile_id);
            self.syncPaletteRuntimePicker();
            setNotice(&rc.card_notice_storage, if (held)
                "Device forgotten and its credential deleted here. Revoke the device on the runtime to finish."
            else
                "Device reference forgotten. Revoke the device on the runtime to finish.");
        },
        .pair_device => openRuntimePairing(self, profile_id),
        .choose_runtime => openRuntimeConnectionEditor(self, profile_id),
        .remove => {
            if (rc.remove_confirm_profile_id) |pending| self.allocator.free(pending);
            rc.remove_confirm_profile_id = self.allocator.dupe(u8, profile_id) catch null;
        },
        .remove_cancel => clearRemoveConfirm(self),
        .remove_confirm => {
            if (!rc.isRemoveConfirming(profile_id)) return;
            clearRemoveConfirm(self);
            _ = service.removeProfile(profile_id) catch |err| {
                log.warn("runtime remove failed: {s}", .{@errorName(err)});
                setNotice(&rc.card_notice_storage, "Could not remove that runtime.");
                return;
            };
            if (rc.isExpanded(profile_id)) setExpandedProfile(self, null);
            invalidateReadiness(self, profile_id);
            self.removeRuntimePickerProfile(profile_id);
            self.syncPaletteRuntimePicker();
            setNotice(&rc.card_notice_storage, "Runtime removed. Chats already pinned to it stay locked and show as unavailable.");
        },
        .copy_diagnostics => {
            const text = service.redactedDiagnosticsAlloc(self.allocator, profile_id) catch |err| {
                log.warn("runtime diagnostics failed: {s}", .{@errorName(err)});
                setNotice(&rc.card_notice_storage, "Could not build diagnostics.");
                return;
            };
            defer self.allocator.free(text);
            setNotice(&rc.card_notice_storage, if (self.setClipboardText(text))
                "Redacted diagnostics copied (no credential material)."
            else
                "Could not access the clipboard.");
        },
        .set_workspace_default => {
            const workspace_id = self.currentWorkspaceIdForRuntimeDefault() orelse return;
            self.persistWorkspaceRuntimeDefault(workspace_id, profile_id) catch |err| {
                log.warn("workspace runtime default failed: {s}", .{@errorName(err)});
                setNotice(&rc.card_notice_storage, "Could not save the workspace default.");
                return;
            };
            setNotice(&rc.card_notice_storage, "Future chats in this workspace will use this runtime. Existing drafts and started chats are unchanged.");
        },
        .add_connection => unreachable,
    }
    _ = now_ms;
    self.markDirty();
}

fn clearRemoveConfirm(self: anytype) void {
    const rc = &self.runtime_connections;
    if (rc.remove_confirm_profile_id) |pending| self.allocator.free(pending);
    rc.remove_confirm_profile_id = null;
}

fn setExpandedProfile(self: anytype, profile_id: ?[]const u8) void {
    const rc = &self.runtime_connections;
    if (rc.expanded_profile_id) |current| self.allocator.free(current);
    rc.expanded_profile_id = if (profile_id) |value| self.allocator.dupe(u8, value) catch null else null;
}

// ---------------------------------------------------------------------------
// Readiness (repository bindings + provider inventory) over existing RPCs
// ---------------------------------------------------------------------------

/// Advances readiness for the expanded runtime. Starts RPCs when the runtime
/// is execution-ready and drains finished tickets. Returns true on change.
pub fn pollRuntimeConnectionsReadiness(self: anytype) bool {
    if (!self.settings_controller.modal_visible) return false;
    const rc = &self.runtime_connections;
    const profile_id = rc.expanded_profile_id orelse return false;
    const service = self.runtime_service orelse return false;
    var changed = false;

    if (rc.readiness_profile_id == null or !std.mem.eql(u8, rc.readiness_profile_id.?, profile_id)) {
        resetReadiness(self);
        rc.readiness_profile_id = self.allocator.dupe(u8, profile_id) catch return false;
        changed = true;
    }

    const snapshot = service.snapshot(profile_id) orelse return changed;
    if (!snapshot.execution_ready) {
        if (rc.manifest_state != .not_ready or rc.providers_state != .not_ready) {
            // A lost generation invalidates prior answers; tickets for the
            // old generation resolve as canceled and are dropped below.
            clearReadinessRows(rc, self.allocator);
            rc.manifest_state = .not_ready;
            rc.providers_state = .not_ready;
            changed = true;
        }
        drainCanceled(self, service);
        return changed;
    }

    if (rc.manifest_state == .idle or rc.manifest_state == .not_ready) {
        if (!snapshot.repository_manifest_capable) {
            rc.manifest_state = .unsupported;
        } else if (self.currentWorkspaceIdForRuntimeDefault()) |workspace_id| {
            rc.manifest_ticket = service.beginRpc(profile_id, "workspace.repository.manifest.get", .{ .workspace_id = workspace_id }) catch null;
            rc.manifest_state = if (rc.manifest_ticket != null) .loading else .failed;
        } else {
            rc.manifest_state = .failed;
        }
        changed = true;
    }
    if (rc.providers_state == .idle or rc.providers_state == .not_ready) {
        rc.providers_ticket = service.beginRpc(profile_id, "providers.status", .{}) catch null;
        rc.providers_state = if (rc.providers_ticket != null) .loading else .failed;
        changed = true;
    }

    if (rc.manifest_ticket) |ticket| {
        if (takeResult(service, ticket)) |maybe| {
            if (maybe) |result| {
                var owned = result;
                defer owned.deinit();
                rc.manifest_ticket = null;
                rc.manifest_state = switch (owned) {
                    .response => |response| blk: {
                        const runtime_id = if (snapshot.runtime) |runtime| runtime.runtime_id else "";
                        parseManifest(self, response.json, runtime_id) catch |err| {
                            log.warn("repository manifest parse failed: {s}", .{@errorName(err)});
                            break :blk .failed;
                        };
                        break :blk .loaded;
                    },
                    .failed, .canceled => .failed,
                };
                changed = true;
            }
        } else {
            rc.manifest_ticket = null;
            rc.manifest_state = .failed;
            changed = true;
        }
    }
    if (rc.providers_ticket) |ticket| {
        if (takeResult(service, ticket)) |maybe| {
            if (maybe) |result| {
                var owned = result;
                defer owned.deinit();
                rc.providers_ticket = null;
                rc.providers_state = switch (owned) {
                    .response => |response| blk: {
                        parseProviders(self, response.json) catch |err| {
                            log.warn("provider status parse failed: {s}", .{@errorName(err)});
                            break :blk .failed;
                        };
                        break :blk .loaded;
                    },
                    .failed, .canceled => .failed,
                };
                changed = true;
            }
        } else {
            rc.providers_ticket = null;
            rc.providers_state = .failed;
            changed = true;
        }
    }
    return changed;
}

/// Returns null when the take itself failed, `?null` while still in flight.
fn takeResult(service: *RuntimeService, ticket: RuntimeService.RpcTicket) ??RuntimeService.RpcCallResult {
    return service.takeRpcResult(ticket) catch |err| {
        log.warn("runtime readiness rpc take failed: {s}", .{@errorName(err)});
        return null;
    };
}

fn drainCanceled(self: anytype, service: *RuntimeService) void {
    const rc = &self.runtime_connections;
    if (rc.manifest_ticket) |ticket| {
        if (takeResult(service, ticket)) |maybe| {
            if (maybe) |result| {
                var owned = result;
                owned.deinit();
                rc.manifest_ticket = null;
            }
        } else rc.manifest_ticket = null;
    }
    if (rc.providers_ticket) |ticket| {
        if (takeResult(service, ticket)) |maybe| {
            if (maybe) |result| {
                var owned = result;
                owned.deinit();
                rc.providers_ticket = null;
            }
        } else rc.providers_ticket = null;
    }
}

/// Drops cached readiness for a profile whose generation or endpoint changed.
pub fn invalidateReadiness(self: anytype, profile_id: []const u8) void {
    const rc = &self.runtime_connections;
    const current = rc.readiness_profile_id orelse return;
    if (!std.mem.eql(u8, current, profile_id)) return;
    clearReadinessRows(rc, self.allocator);
    rc.manifest_state = .idle;
    rc.providers_state = .idle;
}

fn resetReadiness(self: anytype) void {
    const rc = &self.runtime_connections;
    if (rc.readiness_profile_id) |value| self.allocator.free(value);
    rc.readiness_profile_id = null;
    clearReadinessRows(rc, self.allocator);
    rc.manifest_state = .idle;
    rc.providers_state = .idle;
    // In-flight tickets stay owned by the manager until taken; they are
    // drained on the next poll for whichever profile is expanded.
}

fn clearReadinessRows(rc: *State, allocator: std.mem.Allocator) void {
    for (rc.repositories.items) |*row| row.deinit(allocator);
    rc.repositories.clearRetainingCapacity();
    for (rc.providers.items) |*row| row.deinit(allocator);
    rc.providers.clearRetainingCapacity();
    rc.repositories_truncated = 0;
    rc.providers_truncated = 0;
}

fn parseManifest(self: anytype, json: []const u8, runtime_id: []const u8) !void {
    const rc = &self.runtime_connections;
    var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, json, .{});
    defer parsed.deinit();
    const result = try jsonRpcResult(parsed.value);
    if (result != .object) return error.InvalidDaemonResponse;
    const default_id = stringField(result.object, "default_repository_id") orelse "";
    const repositories = result.object.get("repositories") orelse return error.InvalidDaemonResponse;
    if (repositories != .array) return error.InvalidDaemonResponse;
    clearReadinessRows(rc, self.allocator);
    for (repositories.array.items) |item| {
        if (item != .object) continue;
        if (rc.repositories.items.len >= MAX_READINESS_ROWS) {
            rc.repositories_truncated += 1;
            continue;
        }
        const repository_id = stringField(item.object, "repository_id") orelse continue;
        const label = stringField(item.object, "label") orelse repository_id;
        var root_path: ?[]const u8 = null;
        var availability: []const u8 = "unbound";
        if (item.object.get("bindings")) |bindings| {
            if (bindings == .array) for (bindings.array.items) |binding| {
                if (binding != .object) continue;
                const binding_runtime = stringField(binding.object, "runtime_id") orelse continue;
                if (!std.mem.eql(u8, binding_runtime, runtime_id)) continue;
                root_path = stringField(binding.object, "root_path");
                availability = stringField(binding.object, "availability") orelse "available";
                break;
            };
        }
        var row: RepositoryRow = .{
            .repository_id = try self.allocator.dupe(u8, repository_id),
            .label = undefined,
            .root_path = null,
            .availability = undefined,
            .is_default = std.mem.eql(u8, repository_id, default_id),
        };
        errdefer self.allocator.free(row.repository_id);
        row.label = try self.allocator.dupe(u8, label);
        errdefer self.allocator.free(row.label);
        row.availability = try self.allocator.dupe(u8, availability);
        errdefer self.allocator.free(row.availability);
        if (root_path) |value| row.root_path = try self.allocator.dupe(u8, value);
        try rc.repositories.append(self.allocator, row);
    }
}

fn parseProviders(self: anytype, json: []const u8) !void {
    const rc = &self.runtime_connections;
    var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, json, .{});
    defer parsed.deinit();
    const result = try jsonRpcResult(parsed.value);
    if (result != .object) return error.InvalidDaemonResponse;
    const providers = result.object.get("providers") orelse return error.InvalidDaemonResponse;
    if (providers != .array) return error.InvalidDaemonResponse;
    for (rc.providers.items) |*row| row.deinit(self.allocator);
    rc.providers.clearRetainingCapacity();
    rc.providers_truncated = 0;
    for (providers.array.items) |item| {
        if (item != .object) continue;
        if (rc.providers.items.len >= MAX_READINESS_ROWS) {
            rc.providers_truncated += 1;
            continue;
        }
        const label = stringField(item.object, "label") orelse stringField(item.object, "provider") orelse continue;
        var row: ProviderRow = .{
            .label = try self.allocator.dupe(u8, label),
            .state = undefined,
            .authentication = undefined,
            .native_chat = false,
            .terminal_tui = false,
            .mcp = false,
            .lifecycle = false,
            .remediation_label = null,
            .remediation_command = null,
        };
        errdefer self.allocator.free(row.label);
        row.state = try self.allocator.dupe(u8, stringField(item.object, "state") orelse "unknown");
        errdefer self.allocator.free(row.state);
        row.authentication = try self.allocator.dupe(u8, stringField(item.object, "authentication") orelse "unknown");
        errdefer self.allocator.free(row.authentication);
        if (item.object.get("surfaces")) |surfaces| if (surfaces == .object) {
            row.native_chat = boolField(surfaces.object, "native_chat");
            row.terminal_tui = boolField(surfaces.object, "terminal_tui");
            row.mcp = boolField(surfaces.object, "mcp");
            row.lifecycle = boolField(surfaces.object, "lifecycle");
        };
        if (item.object.get("remediation")) |remediation| if (remediation == .object) {
            if (stringField(remediation.object, "label")) |value| row.remediation_label = try self.allocator.dupe(u8, value);
            if (remediation.object.get("command")) |command| if (command == .array) {
                row.remediation_command = try joinStrings(self.allocator, command.array.items);
            };
        };
        errdefer if (row.remediation_label) |value| self.allocator.free(value);
        errdefer if (row.remediation_command) |value| self.allocator.free(value);
        try rc.providers.append(self.allocator, row);
    }
}

fn joinStrings(allocator: std.mem.Allocator, items: []const std.json.Value) !?[]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var wrote = false;
    for (items) |item| {
        if (item != .string) continue;
        if (wrote) try out.writer.writeByte(' ');
        try out.writer.writeAll(item.string);
        wrote = true;
    }
    if (!wrote) {
        out.deinit();
        return null;
    }
    return try out.toOwnedSlice();
}

fn jsonRpcResult(value: std.json.Value) !std.json.Value {
    if (value != .object) return error.InvalidDaemonResponse;
    if (value.object.get("error")) |_| return error.DaemonRequestFailed;
    return value.object.get("result") orelse return error.InvalidDaemonResponse;
}

fn stringField(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return if (value == .string) value.string else null;
}

fn boolField(object: std.json.ObjectMap, key: []const u8) bool {
    const value = object.get(key) orelse return false;
    return value == .bool and value.bool;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn saveFailureMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.InvalidProfileLabel => "Enter a name (1–80 printable characters).",
        error.InvalidSshHost => "Enter an SSH alias, hostname, or IP without spaces or shell characters.",
        error.InvalidSshUser => "SSH user may contain letters, digits, '_', '-', and '.'.",
        error.InvalidPort => "Ports must be 1–65535.",
        error.InvalidUrl, error.UrlTooLong => "Enter the control plane as https://host[:port] with no credentials, query, or fragment.",
        error.TooManyProfiles => "The runtime list is full (64).",
        error.UnknownRuntimeProfile => "That runtime no longer exists in the profile store.",
        error.ProfileAccessMismatch => "That runtime uses a different access method.",
        error.WouldBlock, error.Locked => "Another Verde process is editing runtimes. Try again.",
        error.NotDir, error.AccessDenied, error.ReadOnlyFileSystem => "Could not write runtime profiles in Verde's config directory. Check that ~/.config/verde points to a writable directory.",
        error.NoSpaceLeft, error.DiskQuota => "Could not save the runtime profile. Free some disk space and try again.",
        else => "Could not save the runtime profile.",
    };
}

fn pairingFailureMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.InvalidGrantId, error.InvalidAccessSecret, error.DeviceLabelRequired, error.DeviceLabelTooLong, error.InvalidDeviceLabel => "Check the grant id, pairing code, and device label.",
        error.UnsupportedRuntimeTransport => "Pairing is available for SSH-forwarded and Direct / Tailnet runtimes.",
        error.ProfileAccessMismatch => "That runtime uses a different access method.",
        error.PairingNotConfirmed, error.PairingGrantMissing => "The exchange has not completed yet.",
        error.PairingIdentityMismatch => "The runtime's identity differs from the saved pin. Forget the device or edit the connection before re-pairing.",
        error.MissingRuntimeCredential => "The exchanged credential was lost. Pair again with a new grant.",
        error.UnknownRuntimeProfile => "That runtime no longer exists in the profile store.",
        error.WouldBlock, error.Locked => "Another Verde process is editing runtimes. Try again.",
        else => "Pairing could not be started.",
    };
}

fn pairingSnapshotFailureMessage(failure: @import("../runtime/manager.zig").Failure) []const u8 {
    return switch (failure) {
        .pairing_rejected => "The runtime refused this grant (expired, revoked, or already used). Mint a new one with `verde-daemon pair create`.",
        .rate_limited => "The runtime is rate limiting pairing from this device. Wait a minute, then try again.",
        .identity => "The exchanged runtime identity does not match the saved pin. Edit the connection or forget the device before re-pairing.",
        .network, .no_loopback_port, .tunnel_spawn, .tunnel_readiness, .tunnel_wait, .tunnel_exited => "The SSH forward to the runtime failed. Check the host, user, and gateway port.",
        .authentication => "The runtime rejected the exchanged device credential.",
        .protocol => "The runtime answered with an invalid pairing response.",
        .resource => "Out of memory while pairing.",
        .missing_credential => "Pairing needs a valid grant or saved device credential.",
        .unsupported_transport => "Pairing needs an SSH relay or Direct / Tailnet HTTPS runtime.",
    };
}

fn resetWizardFields(rc: *State) void {
    @memset(&rc.label_storage, 0);
    @memset(&rc.host_storage, 0);
    @memset(&rc.user_storage, 0);
    @memset(&rc.ssh_port_storage, 0);
    @memset(&rc.gateway_port_storage, 0);
    @memset(&rc.grant_id_storage, 0);
    std.crypto.secureZero(u8, &rc.pairing_code_storage);
    @memset(&rc.device_label_storage, 0);
    // In Direct add mode this buffer may still contain the self-contained
    // Pair link fragment, so clear it as secret staging on every exit/reset.
    std.crypto.secureZero(u8, &rc.control_plane_url_storage);
    rc.label_cursor = 0;
    rc.host_cursor = 0;
    rc.user_cursor = 0;
    rc.ssh_port_cursor = 0;
    rc.gateway_port_cursor = 0;
    rc.grant_id_cursor = 0;
    rc.pairing_code_cursor = 0;
    rc.device_label_cursor = 0;
    rc.control_plane_url_cursor = 0;
    rc.pairing_exchange_started = false;
}

fn setWizardProfileId(self: anytype, profile_id: ?[]const u8) void {
    const rc = &self.runtime_connections;
    const next = if (profile_id) |value| self.allocator.dupe(u8, value) catch null else null;
    if (rc.wizard_profile_id) |current| self.allocator.free(current);
    rc.wizard_profile_id = next;
}

fn fillZ(storage: anytype, value: []const u8) void {
    @memset(storage, 0);
    const len = @min(value.len, storage.len - 1);
    @memcpy(storage[0..len], value[0..len]);
}

fn setNotice(storage: *[NOTICE_CAPACITY:0]u8, value: []const u8) void {
    fillZ(storage, value);
}

pub fn setCardNotice(self: anytype, value: []const u8) void {
    setNotice(&self.runtime_connections.card_notice_storage, value);
}

// ---------------------------------------------------------------------------
// Tests: pure state/validation seams with no AppState dependency
// ---------------------------------------------------------------------------

test "row action encoding round-trips every action for the last profile row" {
    inline for (@typeInfo(RowAction).@"enum".fields) |field| {
        const action: RowAction = @enumFromInt(field.value);
        const decoded = decodeRowAction(encodeRowAction(profile.MAX_PROFILES, action)).?;
        try std.testing.expectEqual(profile.MAX_PROFILES, decoded.row);
        try std.testing.expectEqual(action, decoded.action);
    }
    try std.testing.expect(decodeRowAction(255) == null);
}

test "wizard validation reports the first invalid field and accepts defaults" {
    var rc: State = .{};
    try std.testing.expectEqual(WizardField.label, validateWizardForm(&rc).?.field);
    fillZ(&rc.label_storage, "Build VM");
    try std.testing.expectEqual(WizardField.host, validateWizardForm(&rc).?.field);
    fillZ(&rc.host_storage, "-bad");
    try std.testing.expectEqual(WizardField.host, validateWizardForm(&rc).?.field);
    fillZ(&rc.host_storage, "build.example");
    try std.testing.expect(validateWizardForm(&rc) == null);
    fillZ(&rc.user_storage, "bad user");
    try std.testing.expectEqual(WizardField.user, validateWizardForm(&rc).?.field);
    fillZ(&rc.user_storage, "verde");
    fillZ(&rc.ssh_port_storage, "0");
    try std.testing.expectEqual(WizardField.ssh_port, validateWizardForm(&rc).?.field);
    fillZ(&rc.ssh_port_storage, "2222");
    fillZ(&rc.gateway_port_storage, "99999");
    try std.testing.expectEqual(WizardField.gateway_port, validateWizardForm(&rc).?.field);
    fillZ(&rc.gateway_port_storage, "");
    try std.testing.expect(validateWizardForm(&rc) == null);
    const input = wizardSshInput(&rc);
    try std.testing.expectEqualStrings("build.example", input.host);
    try std.testing.expectEqualStrings("verde", input.user.?);
    try std.testing.expectEqual(@as(u16, 2222), input.port);
    try std.testing.expectEqual(profile.DEFAULT_REMOTE_GATEWAY_PORT, input.remote_gateway_port);
}

test "port text filter drops every non-digit byte" {
    var out: [8]u8 = undefined;
    try std.testing.expectEqualStrings("2222", filterPortText("2\t2a2\n2", &out));
    try std.testing.expectEqualStrings("", filterPortText("abc", &out));
}

test "wizard state never stores bearer material" {
    // Runtime bearers stay in state.zig's masked credential modal. The only
    // secret the wizard holds is the one-time pairing code, which has its own
    // zeroing path (checked below) and is masked when rendered.
    const fields = @typeInfo(State).@"struct".fields;
    inline for (fields) |field| {
        try std.testing.expect(std.mem.indexOf(u8, field.name, "token") == null);
        try std.testing.expect(std.mem.indexOf(u8, field.name, "bearer") == null);
        try std.testing.expect(std.mem.indexOf(u8, field.name, "secret") == null);
    }
}

test "pair grant validation follows the access protocol and reset wipes the code" {
    var rc: State = .{};
    try std.testing.expectEqual(WizardField.grant_id, validatePairGrantForm(&rc).?.field);
    fillZ(&rc.grant_id_storage, "0123456789abcdef0123456789abcdef");
    try std.testing.expectEqual(WizardField.pairing_code, validatePairGrantForm(&rc).?.field);
    fillZ(&rc.pairing_code_storage, "ab" ** 32);
    try std.testing.expectEqual(WizardField.device_label, validatePairGrantForm(&rc).?.field);
    fillZ(&rc.device_label_storage, "Laptop");
    try std.testing.expect(validatePairGrantForm(&rc) == null);
    rc.pairing_exchange_started = true;
    resetWizardFields(&rc);
    try std.testing.expect(!rc.pairing_exchange_started);
    for (rc.pairing_code_storage) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    try std.testing.expectEqual(@as(usize, 0), rc.fieldValue(.pairing_code).len);
}

test "connect form validation rejects non-https control planes" {
    var rc: State = .{};
    fillZ(&rc.label_storage, "Team plane");
    fillZ(&rc.control_plane_url_storage, "http://connect.example");
    try std.testing.expectEqual(WizardField.control_plane_url, validateConnectForm(&rc).?.field);
    fillZ(&rc.control_plane_url_storage, "https://user@connect.example");
    try std.testing.expectEqual(WizardField.control_plane_url, validateConnectForm(&rc).?.field);
    fillZ(&rc.control_plane_url_storage, "https://connect.example?tenant=one");
    try std.testing.expectEqual(WizardField.control_plane_url, validateConnectForm(&rc).?.field);
    fillZ(&rc.control_plane_url_storage, "  https://connect.example:8443/  ");
    try std.testing.expect(validateConnectForm(&rc) == null);
}

test "Pair link import is exact and wipes fragment staging" {
    var rc: State = .{};
    defer rc.deinit(std.testing.allocator);
    const grant = "0123456789abcdef0123456789abcdef";
    const code = "ab" ** 32;
    fillZ(&rc.control_plane_url_storage, "verde://pair?host=https%3A%2F%2Fruntime.example&grant_id=" ++ grant ++ "#code=" ++ code);
    try importPairLink(&rc);
    try std.testing.expectEqualStrings("https://runtime.example", rc.fieldValue(.control_plane_url));
    try std.testing.expectEqualStrings(grant, rc.fieldValue(.grant_id));
    try std.testing.expectEqualStrings(code, rc.fieldValue(.pairing_code));
}

test "Pair link rejects query secrets duplicates and non-origin hosts" {
    var rc: State = .{};
    defer rc.deinit(std.testing.allocator);
    const grant = "0123456789abcdef0123456789abcdef";
    const code = "ab" ** 32;
    const invalid = [_][]const u8{
        "verde://pair?host=https%3A%2F%2Fruntime.example&grant_id=" ++ grant ++ "&code=" ++ code ++ "#code=" ++ code,
        "verde://pair?host=https%3A%2F%2Fruntime.example&host=https%3A%2F%2Fother.example&grant_id=" ++ grant ++ "#code=" ++ code,
        "verde://pair?host=https%3A%2F%2Fuser%40runtime.example&grant_id=" ++ grant ++ "#code=" ++ code,
        "verde://pair?host=https%3A%2F%2Fruntime.example%2Fpath&grant_id=" ++ grant ++ "#code=" ++ code,
        "https://runtime.example/?grant_id=" ++ grant ++ "#code=" ++ code,
    };
    for (invalid) |value| {
        fillZ(&rc.control_plane_url_storage, value);
        try std.testing.expectError(error.InvalidPairLink, importPairLink(&rc));
    }
}

test "visible fields follow the wizard step so Tab never reaches hidden inputs" {
    var rc: State = .{};
    rc.wizard_step = .method;
    try std.testing.expectEqual(@as(usize, 0), rc.visibleFields().len);
    rc.wizard_step = .pair_grant;
    try std.testing.expectEqualSlices(WizardField, &.{ .grant_id, .pairing_code, .device_label }, rc.visibleFields());
    rc.wizard_step = .connect_setup;
    try std.testing.expectEqualSlices(WizardField, &.{ .label, .control_plane_url }, rc.visibleFields());
}
