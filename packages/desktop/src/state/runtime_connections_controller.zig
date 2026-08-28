//! Desktop-owned state and actions for the Settings › Runtimes & connections
//! surface and the SSH connection wizard. The controller talks only to the
//! shared runtime Service (profile store, manager, RPC); it never spawns the
//! Verde CLI and never holds bearer material — the masked credential modal in
//! `state.zig` remains the sole UI-owned token copy.

const std = @import("std");
const profile = @import("../runtime/profile.zig");
const RuntimeService = @import("../runtime/service.zig");

const log = std.log.scoped(.native_runtime_connections);

/// Wizard field capacities mirror the profile validators so a value that fits
/// the buffer is never rejected solely for length after trimming.
pub const LABEL_CAPACITY: usize = 80;
pub const HOST_CAPACITY: usize = 255;
pub const USER_CAPACITY: usize = 64;
pub const PORT_CAPACITY: usize = 5;
const NOTICE_CAPACITY: usize = 256;
/// Bounded so a hostile or huge manifest cannot grow the settings card
/// without limit; extra rows are reported as a count.
pub const MAX_READINESS_ROWS: usize = 12;

pub const WizardMode = enum { add, edit };
pub const WizardStep = enum { form, testing };
pub const WizardField = enum { label, host, user, ssh_port, gateway_port };

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
    wizard_step: WizardStep = .form,
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
        self.* = undefined;
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
        };
    }

    pub fn fieldBuffer(self: *State, field: WizardField) [:0]u8 {
        return switch (field) {
            .label => self.label_storage[0..self.label_storage.len :0],
            .host => self.host_storage[0..self.host_storage.len :0],
            .user => self.user_storage[0..self.user_storage.len :0],
            .ssh_port => self.ssh_port_storage[0..self.ssh_port_storage.len :0],
            .gateway_port => self.gateway_port_storage[0..self.gateway_port_storage.len :0],
        };
    }

    pub fn fieldCursor(self: *State, field: WizardField) *usize {
        return switch (field) {
            .label => &self.label_cursor,
            .host => &self.host_cursor,
            .user => &self.user_cursor,
            .ssh_port => &self.ssh_port_cursor,
            .gateway_port => &self.gateway_port_cursor,
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

/// Opens the wizard for a new runtime. Any prior draft is discarded.
pub fn openRuntimeConnectionWizard(self: anytype) void {
    const rc = &self.runtime_connections;
    resetWizardFields(rc);
    setWizardProfileId(self, null);
    rc.wizard_mode = .add;
    rc.wizard_step = .form;
    rc.wizard_open = true;
    setNotice(&rc.wizard_notice_storage, "");
    self.closePaletteRuntimePicker();
    self.closePaletteModelPicker();
    self.closePaletteDirectoryPicker();
    self.closeRunConfigPopover();
    focusWizardField(self, .label);
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
    fillZ(&rc.label_storage, configured.label);
    switch (configured.transport) {
        .ssh_tunnel => |ssh| {
            fillZ(&rc.host_storage, ssh.host);
            if (ssh.user) |user| fillZ(&rc.user_storage, user);
            var port_buf: [PORT_CAPACITY]u8 = undefined;
            fillZ(&rc.ssh_port_storage, std.fmt.bufPrint(&port_buf, "{d}", .{ssh.port}) catch "");
            fillZ(&rc.gateway_port_storage, std.fmt.bufPrint(&port_buf, "{d}", .{ssh.remote_gateway_port}) catch "");
        },
        .local_socket => {},
    }
    rc.label_cursor = rc.fieldValue(.label).len;
    rc.host_cursor = rc.fieldValue(.host).len;
    rc.user_cursor = rc.fieldValue(.user).len;
    rc.ssh_port_cursor = rc.fieldValue(.ssh_port).len;
    rc.gateway_port_cursor = rc.fieldValue(.gateway_port).len;
    setWizardProfileId(self, profile_id);
    rc.wizard_mode = .edit;
    rc.wizard_step = .form;
    rc.wizard_open = true;
    setNotice(&rc.wizard_notice_storage, "");
    focusWizardField(self, .label);
}

pub fn cancelRuntimeConnectionWizard(self: anytype) void {
    const rc = &self.runtime_connections;
    rc.wizard_open = false;
    rc.wizard_step = .form;
    resetWizardFields(rc);
    setWizardProfileId(self, null);
    setNotice(&rc.wizard_notice_storage, "");
    blurWizardField(self);
    self.markDirty();
}

/// From the connect step, returns to the form to edit the saved profile.
pub fn runtimeConnectionWizardBack(self: anytype) void {
    const rc = &self.runtime_connections;
    if (rc.wizard_step != .testing) return;
    const profile_id = rc.wizard_profile_id orelse {
        rc.wizard_step = .form;
        return;
    };
    const owned = self.allocator.dupe(u8, profile_id) catch return;
    defer self.allocator.free(owned);
    openRuntimeConnectionEditor(self, owned);
}

/// Validates, persists through the shared service, and advances to the
/// connect step. Never touches bearer material.
pub fn submitRuntimeConnectionWizard(self: anytype) void {
    const rc = &self.runtime_connections;
    if (!rc.wizard_open or rc.wizard_step != .form) return;
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
    const input: RuntimeService.SshProfileInput = .{
        .label = rc.fieldValue(.label),
        .ssh = wizardSshInput(rc),
    };
    switch (rc.wizard_mode) {
        .add => {
            const id = service.createSshProfile(self.allocator, input) catch |err| {
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

/// Connect/retry from the wizard's connect step.
pub fn runtimeConnectionWizardConnect(self: anytype) void {
    const profile_id = self.runtime_connections.wizard_profile_id orelse return;
    self.connectRuntimeProfileFromPicker(profile_id);
    self.markDirty();
}

pub fn focusWizardField(self: anytype, field: WizardField) void {
    self.palette_modal_text_focus = switch (field) {
        .label => .runtime_wizard_label,
        .host => .runtime_wizard_host,
        .user => .runtime_wizard_user,
        .ssh_port => .runtime_wizard_ssh_port,
        .gateway_port => .runtime_wizard_gateway_port,
    };
    self.modal_text_selection_anchor = null;
    self.modal_text_drag_active = false;
}

/// Tab / Shift+Tab order through the form.
pub fn cycleWizardField(self: anytype, backwards: bool) void {
    const current: ?WizardField = switch (self.palette_modal_text_focus) {
        .runtime_wizard_label => .label,
        .runtime_wizard_host => .host,
        .runtime_wizard_user => .user,
        .runtime_wizard_ssh_port => .ssh_port,
        .runtime_wizard_gateway_port => .gateway_port,
        else => null,
    };
    const fields = [_]WizardField{ .label, .host, .user, .ssh_port, .gateway_port };
    const index: usize = if (current) |value| @intFromEnum(value) else if (backwards) 0 else fields.len - 1;
    const next = if (backwards) (index + fields.len - 1) % fields.len else (index + 1) % fields.len;
    focusWizardField(self, fields[next]);
}

fn blurWizardField(self: anytype) void {
    switch (self.palette_modal_text_focus) {
        .runtime_wizard_label,
        .runtime_wizard_host,
        .runtime_wizard_user,
        .runtime_wizard_ssh_port,
        .runtime_wizard_gateway_port,
        => {
            self.palette_modal_text_focus = .none;
            self.modal_text_selection_anchor = null;
            self.modal_text_drag_active = false;
        },
        else => {},
    }
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
        error.TooManyProfiles => "The runtime list is full (64).",
        error.UnknownRuntimeProfile => "That runtime no longer exists in the profile store.",
        error.WouldBlock, error.Locked => "Another Verde process is editing runtimes. Try again.",
        else => "Could not save the runtime profile.",
    };
}

fn resetWizardFields(rc: *State) void {
    @memset(&rc.label_storage, 0);
    @memset(&rc.host_storage, 0);
    @memset(&rc.user_storage, 0);
    @memset(&rc.ssh_port_storage, 0);
    @memset(&rc.gateway_port_storage, 0);
    rc.label_cursor = 0;
    rc.host_cursor = 0;
    rc.user_cursor = 0;
    rc.ssh_port_cursor = 0;
    rc.gateway_port_cursor = 0;
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
    // The wizard has fields for label/host/user/ports only; a token field
    // would need its own zeroing and masking path and must stay in state.zig.
    const fields = @typeInfo(State).@"struct".fields;
    inline for (fields) |field| {
        try std.testing.expect(std.mem.indexOf(u8, field.name, "token") == null);
        try std.testing.expect(std.mem.indexOf(u8, field.name, "bearer") == null);
        try std.testing.expect(std.mem.indexOf(u8, field.name, "secret") == null);
    }
}
