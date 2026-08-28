//! UI-independent ownership for configured desktop runtime connections.
//!
//! The service loads only the non-secret profile document, gives the manager
//! independent profile copies, and keeps bearer tokens process-local. First
//! contact is never trusted by polling: callers must display an owned proposal
//! and pass that exact proposal to `trustProposal` after user approval.

const Self = @This();

const std = @import("std");
const headless = @import("headless");
const connection = @import("connection.zig");
const credential_store = @import("credential_store.zig");
const manager_mod = @import("manager.zig");
const pin_controller = @import("pin_controller.zig");
const profile = @import("profile.zig");
const profile_store = @import("profile_store.zig");
const tunnel_supervisor = @import("ssh_tunnel_supervisor.zig");

pub const Dependencies = manager_mod.Dependencies;
pub const RuntimeSnapshot = manager_mod.RuntimeSnapshot;
pub const Snapshot = manager_mod.Snapshot;
pub const RpcTicket = manager_mod.RpcTicket;
pub const RpcCallResult = manager_mod.RpcCallResult;
pub const RuntimePinProposal = manager_mod.RuntimePinProposal;
pub const PinAdoption = manager_mod.PinAdoption;
pub const TrustResult = pin_controller.CommitResult;

allocator: std.mem.Allocator,
io: std.Io,
profile_path: []u8,
runtime_manager: manager_mod.Manager,
/// Durable home for paired device credentials; profiles hold only refs.
credentials: credential_store.Store,

/// Loads a path-explicit, non-secret profile document. The supplied `io` must
/// remain valid until `deinit`. Dependency contexts must honor the manager's
/// retain/release contract and can outlive `deinit` while a stopped worker is
/// reaped. The service owns the path, and the manager clones every loaded
/// profile before the load is freed.
pub fn init(
    allocator: std.mem.Allocator,
    io: std.Io,
    profile_path: []const u8,
    dependencies: Dependencies,
) !Self {
    const owned_path = try allocator.dupe(u8, profile_path);
    errdefer allocator.free(owned_path);
    var loaded = try profile_store.loadAtPath(allocator, io, profile_path);
    defer loaded.deinit(allocator);
    const runtime_manager = try manager_mod.Manager.init(
        allocator,
        io,
        loaded.items,
        dependencies,
    );
    var self: Self = .{
        .allocator = allocator,
        .io = io,
        .profile_path = owned_path,
        .runtime_manager = runtime_manager,
        .credentials = if (dependencies.durable_credentials)
            credential_store.Store.init(allocator, io)
        else
            credential_store.Store.initMemoryOnly(allocator, io),
    };
    self.hydrateStoredDeviceCredentials(loaded.items);
    return self;
}

pub fn deinit(self: *Self) void {
    self.runtime_manager.deinit();
    self.credentials.deinit();
    self.allocator.free(self.profile_path);
    self.* = undefined;
}

/// Reports where paired device credentials are kept so the UI can warn when
/// they will not survive a restart.
pub fn credentialBackend(self: *const Self) credential_store.Backend {
    return self.credentials.backend;
}

// Loads each paired profile's device credential by reference. A missing or
// unreadable credential simply leaves the profile "not loaded"; the UI then
// offers re-pairing instead of guessing.
fn hydrateStoredDeviceCredentials(self: *Self, profiles: []const profile.Profile) void {
    for (profiles) |configured| {
        const device = switch (configured.access) {
            .paired_device => |device| device,
            else => continue,
        };
        const ref = device.credential_ref orelse continue;
        const credential = (self.credentials.getAlloc(self.allocator, ref) catch null) orelse continue;
        defer {
            std.crypto.secureZero(u8, credential);
            self.allocator.free(credential);
        }
        self.runtime_manager.hydrateDeviceCredential(configured.id, credential) catch {};
    }
}

/// Copies a bearer token into process memory for one configured profile.
pub fn hydrateToken(self: *Self, profile_id: []const u8, token: []const u8) !void {
    return self.runtime_manager.hydrateToken(profile_id, token);
}

/// Wipes a hydrated token and invalidates every operation using its generation.
pub fn clearToken(self: *Self, profile_id: []const u8) !bool {
    return self.runtime_manager.clearToken(profile_id);
}

pub fn enable(self: *Self, profile_id: []const u8, now_ms: u64) !void {
    return self.runtime_manager.enable(profile_id, now_ms);
}

pub fn disable(self: *Self, profile_id: []const u8) !void {
    return self.runtime_manager.disable(profile_id);
}

pub fn retry(self: *Self, profile_id: []const u8, now_ms: u64) !void {
    return self.runtime_manager.retry(profile_id, now_ms);
}

/// Advances bounded owner-thread state. This never persists or acknowledges a
/// first-contact identity, even when a proposal is available.
pub fn poll(self: *Self, now_ms: u64) !void {
    return self.runtime_manager.poll(now_ms);
}

/// Returns a borrowed, secret-free row valid until the next service mutation.
pub fn snapshot(self: *const Self, profile_id: []const u8) ?Snapshot {
    return self.runtime_manager.snapshot(profile_id);
}

/// Allocates only a bounded row slice. Strings in each row remain borrowed and
/// the caller frees the slice with the allocator supplied here.
pub fn snapshotsAlloc(
    self: *const Self,
    allocator: std.mem.Allocator,
) ![]Snapshot {
    return self.runtime_manager.snapshotsAlloc(allocator);
}

/// Copies the currently verified first-contact identity for display. The
/// caller owns a non-null proposal and must call `deinit` on it.
pub fn pinProposalAlloc(
    self: *const Self,
    allocator: std.mem.Allocator,
    profile_id: []const u8,
) !?RuntimePinProposal {
    return self.runtime_manager.runtimePinProposalAlloc(allocator, profile_id);
}

/// Persists and adopts the exact proposal the user approved. A different
/// complete pair already on disk wins and produces `reconnect_required`; this
/// method never replaces that authoritative pair.
pub fn trustProposal(
    self: *Self,
    proposal: *const RuntimePinProposal,
) !TrustResult {
    return pin_controller.commitProposalAtPath(
        self.allocator,
        self.io,
        self.profile_path,
        &self.runtime_manager,
        proposal,
    );
}

pub const ProfileReplacement = manager_mod.ProfileReplacement;

/// Non-secret input for creating or editing a runtime reached over SSH.
pub const SshProfileInput = struct {
    label: []const u8,
    ssh: profile.SshTunnelInput,
};

/// Creates one runtime profile under the cross-process store lock, rereads the
/// authoritative document, and adopts the persisted copy. The returned id is
/// owned by the caller. Bearer tokens never pass through this path.
pub fn createSshProfile(self: *Self, allocator: std.mem.Allocator, input: SshProfileInput) ![]u8 {
    var lock = try profile_store.acquireExclusiveAtPath(self.allocator, self.io, self.profile_path);
    defer lock.deinit();
    var loaded = try profile_store.loadAtPath(self.allocator, self.io, self.profile_path);
    defer loaded.deinit(self.allocator);
    if (loaded.items.len >= profile.MAX_PROFILES) return error.TooManyProfiles;

    var created = try profile.Profile.createSshTunnel(
        self.allocator,
        self.io,
        input.label,
        null,
        input.ssh,
    );
    defer created.deinit(self.allocator);
    const next = try self.allocator.alloc(profile.Profile, loaded.items.len + 1);
    defer self.allocator.free(next);
    @memcpy(next[0..loaded.items.len], loaded.items);
    next[loaded.items.len] = created;
    try profile_store.saveAtPath(self.allocator, self.io, self.profile_path, next);

    var authoritative = try profile_store.loadAtPath(self.allocator, self.io, self.profile_path);
    defer authoritative.deinit(self.allocator);
    const persisted = findProfile(authoritative.items, created.id) orelse return error.RuntimeProfileNotPersisted;
    try self.runtime_manager.addProfile(persisted.*);
    return allocator.dupe(u8, persisted.id);
}

/// Creates an SSH-forwarded profile that will authenticate with a paired
/// device. No device exists until `beginPairing` → `commitPairing` succeeds.
pub fn createPairedProfile(self: *Self, allocator: std.mem.Allocator, input: SshProfileInput) ![]u8 {
    var created = try profile.Profile.createPairedSshTunnel(self.allocator, self.io, input.label, input.ssh);
    defer created.deinit(self.allocator);
    return self.persistNewProfile(allocator, created);
}

/// Creates a Connect profile bound to one self-hosted control plane. The
/// runtime endpoint is selected later from the signed-in inventory.
pub fn createConnectProfile(
    self: *Self,
    allocator: std.mem.Allocator,
    label: []const u8,
    control_plane_url: []const u8,
) ![]u8 {
    var created = try profile.Profile.createConnect(self.allocator, self.io, label, control_plane_url);
    defer created.deinit(self.allocator);
    return self.persistNewProfile(allocator, created);
}

fn persistNewProfile(self: *Self, allocator: std.mem.Allocator, created: profile.Profile) ![]u8 {
    var lock = try profile_store.acquireExclusiveAtPath(self.allocator, self.io, self.profile_path);
    defer lock.deinit();
    var loaded = try profile_store.loadAtPath(self.allocator, self.io, self.profile_path);
    defer loaded.deinit(self.allocator);
    if (loaded.items.len >= profile.MAX_PROFILES) return error.TooManyProfiles;
    const next = try self.allocator.alloc(profile.Profile, loaded.items.len + 1);
    defer self.allocator.free(next);
    @memcpy(next[0..loaded.items.len], loaded.items);
    next[loaded.items.len] = created;
    try profile_store.saveAtPath(self.allocator, self.io, self.profile_path, next);

    var authoritative = try profile_store.loadAtPath(self.allocator, self.io, self.profile_path);
    defer authoritative.deinit(self.allocator);
    const persisted = findProfile(authoritative.items, created.id) orelse return error.RuntimeProfileNotPersisted;
    try self.runtime_manager.addProfile(persisted.*);
    return allocator.dupe(u8, persisted.id);
}

pub const PairingInput = manager_mod.PairingInput;
pub const PairingResult = manager_mod.PairingResult;

/// Starts exchanging a one-time grant over the profile's SSH tunnel. The
/// secret is copied into the manager and never touches the profile store.
pub fn beginPairing(self: *Self, profile_id: []const u8, input: PairingInput, now_ms: u64) !void {
    return self.runtime_manager.beginPairing(profile_id, input, now_ms);
}

pub fn abandonPairing(self: *Self, profile_id: []const u8) !void {
    return self.runtime_manager.abandonPairing(profile_id);
}

pub fn pairingResult(self: *const Self, profile_id: []const u8) ?PairingResult {
    return self.runtime_manager.pairingResult(profile_id);
}

pub const PairingCommit = struct {
    /// False when the credential is held in memory only (keyring unavailable
    /// or write failed); the pairing must be repeated after a restart.
    durable: bool,
};

/// Persists the confirmed device reference plus the exchanged identity pin
/// under the store lock, stores the credential by reference, then lets the
/// manager start a normal authenticated attempt against the pinned identity.
pub fn commitPairing(self: *Self, profile_id: []const u8, now_ms: u64) !PairingCommit {
    const result = self.runtime_manager.pairingResult(profile_id) orelse return error.PairingNotConfirmed;
    const ref = try credential_store.deviceRefAlloc(self.allocator, profile_id);
    defer self.allocator.free(ref);

    var lock = try profile_store.acquireExclusiveAtPath(self.allocator, self.io, self.profile_path);
    defer lock.deinit();
    var loaded = try profile_store.loadAtPath(self.allocator, self.io, self.profile_path);
    defer loaded.deinit(self.allocator);
    const configured = findProfile(loaded.items, profile_id) orelse return error.UnknownRuntimeProfile;
    try configured.setPairedDevice(self.allocator, result.device_id, ref);
    try configured.setExpectedIdentity(self.allocator, result.runtime_id, result.instance_id);
    try profile_store.saveAtPath(self.allocator, self.io, self.profile_path, loaded.items);

    var durable = self.credentials.backend.durable();
    {
        var key_buffer: manager_mod.DeviceSecretKeyBuffer = undefined;
        const credential = self.runtime_manager.secrets.get(manager_mod.deviceSecretKey(&key_buffer, profile_id)) orelse
            return error.MissingRuntimeCredential;
        self.credentials.put(ref, credential) catch |err| switch (err) {
            error.CredentialStoreUnavailable => durable = false,
            else => return err,
        };
    }

    var authoritative = try profile_store.loadAtPath(self.allocator, self.io, self.profile_path);
    defer authoritative.deinit(self.allocator);
    const persisted = findProfile(authoritative.items, profile_id) orelse return error.RuntimeProfileNotPersisted;
    try self.runtime_manager.completePairing(persisted.*, now_ms);
    return .{ .durable = durable };
}

/// Unpairs: forgets the device reference on disk, deletes the credential from
/// the store and memory, and invalidates the live generation. The runtime
/// keeps its device record until revoked there. Returns whether a credential
/// was actually held.
pub fn forgetDevice(self: *Self, profile_id: []const u8) !bool {
    var lock = try profile_store.acquireExclusiveAtPath(self.allocator, self.io, self.profile_path);
    defer lock.deinit();
    var loaded = try profile_store.loadAtPath(self.allocator, self.io, self.profile_path);
    defer loaded.deinit(self.allocator);
    const configured = findProfile(loaded.items, profile_id) orelse return error.UnknownRuntimeProfile;
    const ref_copy: ?[]u8 = switch (configured.access) {
        .paired_device => |device| if (device.credential_ref) |ref| try self.allocator.dupe(u8, ref) else null,
        else => return error.ProfileAccessMismatch,
    };
    defer if (ref_copy) |ref| self.allocator.free(ref);
    try configured.clearPairedDevice(self.allocator);
    try profile_store.saveAtPath(self.allocator, self.io, self.profile_path, loaded.items);

    var held = try self.runtime_manager.clearDeviceCredential(profile_id);
    if (ref_copy) |ref| {
        held = (self.credentials.remove(ref) catch false) or held;
    }
    var authoritative = try profile_store.loadAtPath(self.allocator, self.io, self.profile_path);
    defer authoritative.deinit(self.allocator);
    const persisted = findProfile(authoritative.items, profile_id) orelse return error.RuntimeProfileNotPersisted;
    _ = try self.runtime_manager.replaceProfile(persisted.*);
    return held;
}

/// Edits non-secret fields. An endpoint change clears the durable identity pin
/// on disk and invalidates the live generation so trust is never carried over
/// to a different peer; a label-only edit keeps the connection as is.
pub fn updateSshProfile(self: *Self, profile_id: []const u8, input: SshProfileInput) !ProfileReplacement {
    var lock = try profile_store.acquireExclusiveAtPath(self.allocator, self.io, self.profile_path);
    defer lock.deinit();
    var loaded = try profile_store.loadAtPath(self.allocator, self.io, self.profile_path);
    defer loaded.deinit(self.allocator);
    const configured = findProfile(loaded.items, profile_id) orelse return error.UnknownRuntimeProfile;

    const endpoint_changed = !configured.sameSshEndpoint(input.ssh);
    try configured.setLabel(self.allocator, input.label);
    if (endpoint_changed) {
        try configured.replaceSshTunnel(self.allocator, input.ssh);
        try configured.setExpectedIdentity(self.allocator, null, null);
    }
    try profile_store.saveAtPath(self.allocator, self.io, self.profile_path, loaded.items);

    var authoritative = try profile_store.loadAtPath(self.allocator, self.io, self.profile_path);
    defer authoritative.deinit(self.allocator);
    const persisted = findProfile(authoritative.items, profile_id) orelse return error.RuntimeProfileNotPersisted;
    return self.runtime_manager.replaceProfile(persisted.*);
}

/// Edits a Connect profile's label and control plane. Changing the plane
/// drops the selected endpoint, link, and pin; label-only edits keep them.
pub fn updateConnectProfile(self: *Self, profile_id: []const u8, label: []const u8, control_plane_url: []const u8) !ProfileReplacement {
    var lock = try profile_store.acquireExclusiveAtPath(self.allocator, self.io, self.profile_path);
    defer lock.deinit();
    var loaded = try profile_store.loadAtPath(self.allocator, self.io, self.profile_path);
    defer loaded.deinit(self.allocator);
    const configured = findProfile(loaded.items, profile_id) orelse return error.UnknownRuntimeProfile;
    if (configured.access != .connect) return error.ProfileAccessMismatch;
    try configured.setLabel(self.allocator, label);
    if (!configured.sameControlPlane(control_plane_url)) try configured.setControlPlaneUrl(self.allocator, control_plane_url);
    try profile_store.saveAtPath(self.allocator, self.io, self.profile_path, loaded.items);

    var authoritative = try profile_store.loadAtPath(self.allocator, self.io, self.profile_path);
    defer authoritative.deinit(self.allocator);
    const persisted = findProfile(authoritative.items, profile_id) orelse return error.RuntimeProfileNotPersisted;
    return self.runtime_manager.replaceProfile(persisted.*);
}

/// Non-secret runtime descriptor chosen from the signed-in Connect inventory.
pub const ConnectRuntimeSelection = struct {
    link_id: []const u8,
    runtime_id: []const u8,
    instance_id: []const u8,
    https_url: []const u8,
    wss_url: []const u8,
    spki_sha256: []const u8,
};

/// Persists the selected endpoint identity (URLs, SPKI pin, link id, and the
/// advertised runtime/instance pair). The live entry is re-added without
/// trust because no handshake has verified that pair yet.
pub fn selectConnectRuntime(self: *Self, profile_id: []const u8, selection: ConnectRuntimeSelection) !void {
    var lock = try profile_store.acquireExclusiveAtPath(self.allocator, self.io, self.profile_path);
    defer lock.deinit();
    var loaded = try profile_store.loadAtPath(self.allocator, self.io, self.profile_path);
    defer loaded.deinit(self.allocator);
    const configured = findProfile(loaded.items, profile_id) orelse return error.UnknownRuntimeProfile;
    try configured.setConnectEndpoint(self.allocator, selection.https_url, selection.wss_url, selection.spki_sha256, selection.link_id);
    try configured.setExpectedIdentity(self.allocator, selection.runtime_id, selection.instance_id);
    try profile_store.saveAtPath(self.allocator, self.io, self.profile_path, loaded.items);

    var authoritative = try profile_store.loadAtPath(self.allocator, self.io, self.profile_path);
    defer authoritative.deinit(self.allocator);
    const persisted = findProfile(authoritative.items, profile_id) orelse return error.RuntimeProfileNotPersisted;
    _ = try self.runtime_manager.replaceProfile(persisted.*);
}

/// Removes the profile from disk and from the live manager, wiping any
/// process-memory token. Returns whether a token was forgotten.
pub fn removeProfile(self: *Self, profile_id: []const u8) !bool {
    var lock = try profile_store.acquireExclusiveAtPath(self.allocator, self.io, self.profile_path);
    defer lock.deinit();
    var loaded = try profile_store.loadAtPath(self.allocator, self.io, self.profile_path);
    defer loaded.deinit(self.allocator);

    var kept: std.ArrayList(profile.Profile) = .empty;
    defer kept.deinit(self.allocator);
    for (loaded.items) |configured| {
        if (!std.mem.eql(u8, configured.id, profile_id)) {
            try kept.append(self.allocator, configured);
            continue;
        }
        // Removing a paired profile must not leave its credential behind.
        if (configured.access == .paired_device) {
            if (configured.access.paired_device.credential_ref) |ref| _ = self.credentials.remove(ref) catch false;
        }
    }
    if (kept.items.len == loaded.items.len and self.runtime_manager.profileConst(profile_id) == null) {
        return error.UnknownRuntimeProfile;
    }
    try profile_store.saveAtPath(self.allocator, self.io, self.profile_path, kept.items);
    if (self.runtime_manager.profileConst(profile_id) == null) return false;
    return self.runtime_manager.removeProfile(profile_id);
}

/// Resynchronizes the live manager with the on-disk document after another
/// process (CLI) edited it. Disk is authoritative: vanished profiles are
/// removed, new ones added, and changed endpoints re-verified.
pub fn reloadProfiles(self: *Self) !void {
    var loaded = try profile_store.loadAtPath(self.allocator, self.io, self.profile_path);
    defer loaded.deinit(self.allocator);
    const live_ids = try self.runtime_manager.profileIdsAlloc(self.allocator);
    defer self.allocator.free(live_ids);
    for (live_ids) |live_id| {
        if (findProfile(loaded.items, live_id) == null) _ = try self.runtime_manager.removeProfile(live_id);
    }
    for (loaded.items) |configured| {
        if (self.runtime_manager.profileConst(configured.id) == null) {
            try self.runtime_manager.addProfile(configured);
        } else {
            _ = try self.runtime_manager.replaceProfile(configured);
        }
    }
    self.hydrateStoredDeviceCredentials(loaded.items);
}

/// Formats secret-free diagnostics for clipboard/bug reports. Includes the
/// non-secret endpoint, state, and identity pins but never a bearer token.
pub fn redactedDiagnosticsAlloc(self: *const Self, allocator: std.mem.Allocator, profile_id: []const u8) ![]u8 {
    const snap = self.snapshot(profile_id) orelse return error.UnknownRuntimeProfile;
    const configured = self.runtime_manager.profileConst(profile_id) orelse return error.UnknownRuntimeProfile;
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    try w.print("verde runtime diagnostics (redacted)\nprofile_id: {s}\nlabel: {s}\n", .{ snap.profile_id, snap.label });
    switch (configured.transport) {
        .local_socket => try w.writeAll("transport: local_socket\n"),
        .ssh_tunnel => |ssh| try w.print(
            "transport: ssh_tunnel host={s} user={s} ssh_port={d} gateway_port={d}\n",
            .{ ssh.host, ssh.user orelse "<default>", ssh.port, ssh.remote_gateway_port },
        ),
        .connect => |endpoint| try w.print(
            "transport: connect https_url={s} wss_url={s} spki_sha256={s}\n",
            .{
                endpoint.https_url orelse "<unselected>",
                endpoint.wss_url orelse "<unselected>",
                endpoint.spki_sha256 orelse "<unselected>",
            },
        ),
    }
    // Access details are references and identifiers only; credentials and
    // access tokens are reported as presence, never as values.
    switch (configured.access) {
        .admin_token => try w.writeAll("access: admin_token\n"),
        .paired_device => |device| try w.print(
            "access: paired_device device_id={s} credential_ref={s} device_credential={s} pairing={s}\ncredential_store: {s}\n",
            .{
                device.device_id orelse "<not paired>",
                device.credential_ref orelse "<none>",
                if (snap.device_credential_held) "held in memory (<redacted>)" else "not loaded",
                @tagName(snap.pairing_state),
                self.credentials.backend.description(),
            },
        ),
        .connect => |link| try w.print(
            "access: connect control_plane_url={s} link_id={s}\n",
            .{ link.control_plane_url, link.link_id orelse "<none>" },
        ),
    }
    try w.print("phase: {s}\nfailure: {s}\ntunnel: {s}\n", .{
        @tagName(snap.phase),
        if (snap.failure) |failure| @tagName(failure) else "none",
        @tagName(snap.tunnel_lifecycle),
    });
    try w.print("credential: {s}\n", .{if (self.runtime_manager.secrets.get(profile_id) != null) "held in memory (<redacted>)" else "not provided"});
    try w.print("pinned_runtime_id: {s}\npinned_instance_id: {s}\n", .{
        configured.expected_runtime_id orelse "<unpinned>",
        configured.expected_instance_id orelse "<unpinned>",
    });
    if (snap.runtime) |runtime| {
        try w.print("verified_runtime_id: {s}\nverified_instance_id: {s}\nserver_version: {s}\nprotocol: {d}.{d}\n", .{
            runtime.runtime_id, runtime.instance_id, runtime.server_version, runtime.protocol_major, runtime.protocol_minor,
        });
    }
    try w.print("verified_matches_pin: {}\nexecution_ready: {}\nrepository_manifest_capable: {}\n", .{
        snap.verified_runtime_matches_pin, snap.execution_ready, snap.repository_manifest_capable,
    });
    return out.toOwnedSlice();
}

fn findProfile(profiles: []profile.Profile, profile_id: []const u8) ?*profile.Profile {
    for (profiles) |*configured| {
        if (std.mem.eql(u8, configured.id, profile_id)) return configured;
    }
    return null;
}

/// Starts one manager-targeted RPC. This is the only execution entry point and
/// succeeds only when `snapshot(profile_id).?.execution_ready` is true.
pub fn beginRpc(
    self: *Self,
    profile_id: []const u8,
    method: []const u8,
    params: anytype,
) !RpcTicket {
    return self.runtime_manager.beginRpc(profile_id, method, params);
}

/// Returns null while the RPC is active. A non-null result transfers ownership
/// to the caller, which must call `RpcCallResult.deinit` exactly once even for
/// a method-level JSON-RPC error response.
pub fn takeRpcResult(
    self: *Self,
    ticket: RpcTicket,
) !?RpcCallResult {
    return self.runtime_manager.takeRpcResult(ticket);
}

const TEST_TOKEN = "0123456789abcdef0123456789abcdef";
const TEST_RUNTIME_A = "0123456789abcdef0123456789abcdef";
const TEST_RUNTIME_B = "fedcba9876543210fedcba9876543210";
const TEST_INSTANCE_A = "00112233445566778899aabbccddeeff";
const TEST_INSTANCE_B = "ffeeddccbbaa99887766554433221100";

const TestPorts = struct {
    values: []const u16,
    index: usize = 0,

    fn select(raw_context: ?*anyopaque, _: std.Io) anyerror!u16 {
        const self: *TestPorts = @ptrCast(@alignCast(raw_context.?));
        if (self.values.len == 0) return error.NoTestPort;
        const selected = self.values[@min(self.index, self.values.len - 1)];
        if (self.index < self.values.len - 1) self.index += 1;
        return selected;
    }
};

const TestTunnel = struct {
    allow_ready: std.atomic.Value(bool) = .init(false),
    retained: std.atomic.Value(usize) = .init(0),

    fn retain(raw_context: ?*anyopaque) void {
        const self: *TestTunnel = @ptrCast(@alignCast(raw_context.?));
        _ = self.retained.fetchAdd(1, .acq_rel);
    }

    fn release(raw_context: ?*anyopaque) void {
        const self: *TestTunnel = @ptrCast(@alignCast(raw_context.?));
        _ = self.retained.fetchSub(1, .acq_rel);
    }

    fn run(
        raw_context: ?*anyopaque,
        io: std.Io,
        _: []const []const u8,
        _: u16,
        control: tunnel_supervisor.Control,
    ) tunnel_supervisor.Outcome {
        const self: *TestTunnel = @ptrCast(@alignCast(raw_context.?));
        control.markSpawned(31_001);
        while (!self.allow_ready.load(.acquire)) {
            if (control.stopRequested()) return .stopped;
            std.Io.sleep(io, .fromMilliseconds(1), .awake) catch {};
        }
        control.markForwardReady(31_001);
        while (!control.stopRequested()) {
            std.Io.sleep(io, .fromMilliseconds(1), .awake) catch {};
        }
        return .stopped;
    }

    fn backend(self: *TestTunnel) tunnel_supervisor.Backend {
        return .{
            .context = self,
            .run = run,
            .retain_context = retain,
            .release_context = release,
        };
    }
};

const TestRpc = struct {
    retained: std.atomic.Value(usize) = .init(0),
    targeted_calls: std.atomic.Value(usize) = .init(0),
    repository_route_calls: std.atomic.Value(usize) = .init(0),
    valid_targets: std.atomic.Value(bool) = .init(true),
    valid_repository_route: std.atomic.Value(bool) = .init(true),

    fn retain(raw_context: ?*anyopaque) void {
        const self: *TestRpc = @ptrCast(@alignCast(raw_context.?));
        _ = self.retained.fetchAdd(1, .acq_rel);
    }

    fn release(raw_context: ?*anyopaque) void {
        const self: *TestRpc = @ptrCast(@alignCast(raw_context.?));
        _ = self.retained.fetchSub(1, .acq_rel);
    }

    fn call(
        raw_context: ?*anyopaque,
        allocator: std.mem.Allocator,
        local_port: u16,
        bearer_token: []const u8,
        rpc_json: []const u8,
    ) connection.TransportError![]u8 {
        const self: *TestRpc = @ptrCast(@alignCast(raw_context.?));
        if (!std.mem.eql(u8, bearer_token, TEST_TOKEN)) {
            self.valid_targets.store(false, .release);
        }
        var parsed = headless.protocol.parseRequest(allocator, rpc_json) catch {
            self.valid_targets.store(false, .release);
            return error.ProtocolRejected;
        };
        defer parsed.deinit();

        const runtime_id = if (local_port == 43_127) TEST_RUNTIME_A else TEST_RUNTIME_B;
        if (parsed.request.target) |target| {
            _ = self.targeted_calls.fetchAdd(1, .acq_rel);
            if (!std.mem.eql(u8, target.runtime_id, runtime_id) or
                !std.mem.eql(u8, target.instance_id, TEST_INSTANCE_A))
            {
                self.valid_targets.store(false, .release);
            }
        } else if (!std.mem.eql(u8, parsed.request.method, "core.status")) {
            self.valid_targets.store(false, .release);
        }

        if (std.mem.eql(u8, parsed.request.method, "core.status")) {
            return headless.encodeOkResponse(
                allocator,
                parsed.request.id,
                testStatus(runtime_id),
            ) catch error.OutOfMemory;
        }
        if (std.mem.eql(u8, parsed.request.method, "chat.turn.start")) {
            _ = self.repository_route_calls.fetchAdd(1, .acq_rel);
            const params = parsed.request.params;
            const valid = params == .object and
                params.object.get("workspace_id") != null and
                params.object.get("repository_id") != null and
                params.object.get("relative_cwd") != null and
                params.object.get("project_path") == null and
                params.object.get("cwd") == null and
                params.object.get("image_paths") == null and
                params.object.get("images") == null;
            if (!valid) self.valid_repository_route.store(false, .release);
        }
        return headless.encodeOkResponse(
            allocator,
            parsed.request.id,
            .{ .accepted = true },
        ) catch error.OutOfMemory;
    }

    fn backend(self: *TestRpc) manager_mod.RpcBackend {
        return .{
            .context = self,
            .call = call,
            .retain_context = retain,
            .release_context = release,
        };
    }
};

fn testStatus(runtime_id: []const u8) headless.StatusResult {
    return .{
        .runtime_id = runtime_id,
        .instance_id = TEST_INSTANCE_A,
        .server_version = "1.2.3",
        .protocol = .{ .major = headless.protocol.RUNTIME_PROTOCOL_MAJOR, .minor = 4 },
        .runtime_capabilities = &.{
            "rpc.target.v1",
            "core.snapshot.v1",
            manager_mod.REPOSITORY_MANIFEST_CAPABILITY,
            manager_mod.REPOSITORY_CHAT_ROUTE_CAPABILITY,
        },
        .limits = .{
            .max_request_bytes = 65_536,
            .max_response_bytes = 131_072,
            .max_attachment_bytes = 1_048_576,
            .max_parked_wait_ms = 9_000,
            .default_page_items = 25,
            .max_page_items = 75,
        },
        .headless_protocol_version = headless.HEADLESS_PROTOCOL_VERSION,
        .min_supported = headless.MIN_SUPPORTED_PROTOCOL_VERSION,
        .max_supported = headless.MAX_SUPPORTED_PROTOCOL_VERSION,
        .protocol_version = 26,
        .pid = 42,
        .session_count = 2,
        .chat_turn_count = 3,
        .capabilities = headless.Capabilities.phase1(),
    };
}

fn testPathAlloc(allocator: std.mem.Allocator, dir: std.Io.Dir) ![]u8 {
    var absolute_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const absolute_len = try dir.realPath(std.testing.io, &absolute_buffer);
    return std.fs.path.join(allocator, &.{
        absolute_buffer[0..absolute_len],
        profile_store.FILE_NAME,
    });
}

fn testDependencies(
    ports: *TestPorts,
    tunnel: *TestTunnel,
    rpc: *TestRpc,
) Dependencies {
    return .{
        .port_selector = .{ .context = ports, .select = TestPorts.select },
        .tunnel_backend = tunnel.backend(),
        .rpc_backend = rpc.backend(),
        .durable_credentials = false,
    };
}

fn waitForPhase(
    service: *Self,
    profile_id: []const u8,
    expected: connection.Phase,
) !void {
    for (0..2_000) |iteration| {
        try service.poll(1_000 + iteration);
        if (service.snapshot(profile_id).?.phase == expected) return;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    }
    return error.TestExpectedRuntimePhase;
}

fn waitForExecutionReady(service: *Self, profile_id: []const u8) !void {
    for (0..2_000) |iteration| {
        try service.poll(10_000 + iteration);
        if (service.snapshot(profile_id).?.execution_ready) return;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    }
    return error.TestExpectedExecutionReady;
}

fn waitForCleanup(service: *Self, profile_id: []const u8) !void {
    for (0..2_000) |iteration| {
        try service.poll(30_000 + iteration);
        const current = service.snapshot(profile_id).?;
        if (current.local_port == null and current.tunnel_lifecycle == .stopped) return;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    }
    return error.TestExpectedRuntimeCleanup;
}

fn waitForRpcResult(
    service: *Self,
    ticket: RpcTicket,
) !RpcCallResult {
    for (0..2_000) |iteration| {
        try service.poll(20_000 + iteration);
        if (try service.takeRpcResult(ticket)) |result| return result;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    }
    return error.TestExpectedRuntimeRpcResult;
}

test "service reports first contact without trusting until explicit approval" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try testPathAlloc(allocator, tmp.dir);
    defer allocator.free(path);

    var configured = try profile.Profile.createSshTunnel(
        allocator,
        std.testing.io,
        "Build VM",
        null,
        .{ .host = "runtime.example", .user = "verde" },
    );
    defer configured.deinit(allocator);
    try profile_store.saveAtPath(allocator, std.testing.io, path, &.{configured});

    var ports: TestPorts = .{ .values = &.{43_127} };
    var tunnel: TestTunnel = .{};
    tunnel.allow_ready.store(true, .release);
    var rpc: TestRpc = .{};
    var service = try Self.init(
        allocator,
        std.testing.io,
        path,
        testDependencies(&ports, &tunnel, &rpc),
    );
    defer {
        service.disable(configured.id) catch {};
        waitForCleanup(&service, configured.id) catch {};
        service.deinit();
    }
    try service.hydrateToken(configured.id, TEST_TOKEN);
    try service.enable(configured.id, 0);
    try waitForPhase(&service, configured.id, .awaiting_trust);

    const pending = service.snapshot(configured.id).?;
    try std.testing.expect(pending.identity_pin_required);
    try std.testing.expect(!pending.execution_ready);
    try std.testing.expectError(
        error.RuntimeNotExecutionReady,
        service.beginRpc(configured.id, "core.snapshot", .{}),
    );
    for (0..10) |iteration| try service.poll(5_000 + iteration);
    var before_approval = try profile_store.loadAtPath(allocator, std.testing.io, path);
    defer before_approval.deinit(allocator);
    try std.testing.expect(before_approval.items[0].expected_runtime_id == null);
    try std.testing.expect(before_approval.items[0].expected_instance_id == null);

    var proposal = (try service.pinProposalAlloc(allocator, configured.id)).?;
    defer proposal.deinit();
    try std.testing.expectEqualStrings(TEST_RUNTIME_A, proposal.runtime_id);
    try std.testing.expectEqualStrings(TEST_INSTANCE_A, proposal.instance_id);
    const committed = try service.trustProposal(&proposal);
    try std.testing.expectEqual(PinAdoption.committed_current, committed.adoption);
    try std.testing.expect(committed.wrote_profile);

    try waitForExecutionReady(&service, configured.id);
    const ready = service.snapshot(configured.id).?;
    try std.testing.expect(ready.execution_ready);
    try std.testing.expect(ready.verified_runtime_matches_pin);
    try std.testing.expect(ready.repository_manifest_capable);
    try std.testing.expect(ready.repository_chat_route_capable);
    const ticket = try service.beginRpc(configured.id, "core.snapshot", .{});
    var result = try waitForRpcResult(&service, ticket);
    defer result.deinit();
    switch (result) {
        .response => {},
        .failed, .canceled => return error.TestExpectedRpcResponse,
    }
    try std.testing.expect(rpc.valid_targets.load(.acquire));
    try std.testing.expect(rpc.targeted_calls.load(.acquire) >= 2);
    const route_ticket = try service.beginRpc(configured.id, "chat.turn.start", .{
        .turn_id = "route-turn",
        .workspace_id = "workspace",
        .local_thread_id = "thread",
        .repository_id = "repo-api",
        .relative_cwd = "services/api",
        .provider = "codex",
        .harness = "local_cli",
        .prompt = "hello",
        .provider_thread_id = null,
        .thread_title = "Routed",
        .model_ref = null,
        .reasoning_effort = null,
        .opencode_reasoning_variant = null,
        .cursor_model_params_json = null,
        .fast_mode = false,
        .access_mode = "supervised",
        .message_id = "route-message",
    });
    var route_result = try waitForRpcResult(&service, route_ticket);
    defer route_result.deinit();
    try std.testing.expectEqual(@as(usize, 1), rpc.repository_route_calls.load(.acquire));
    try std.testing.expect(rpc.valid_repository_route.load(.acquire));
    try service.disable(configured.id);
    try waitForCleanup(&service, configured.id);
    try std.testing.expectEqual(@as(usize, 0), tunnel.retained.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), rpc.retained.load(.acquire));
}

test "complete conflicting disk pin wins approval transaction and reconnects" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try testPathAlloc(allocator, tmp.dir);
    defer allocator.free(path);

    var configured = try profile.Profile.createSshTunnel(
        allocator,
        std.testing.io,
        "Conflict VM",
        null,
        .{ .host = "runtime.example" },
    );
    defer configured.deinit(allocator);
    try profile_store.saveAtPath(allocator, std.testing.io, path, &.{configured});

    var ports: TestPorts = .{ .values = &.{43_127} };
    var tunnel: TestTunnel = .{};
    tunnel.allow_ready.store(true, .release);
    var rpc: TestRpc = .{};
    var service = try Self.init(
        allocator,
        std.testing.io,
        path,
        testDependencies(&ports, &tunnel, &rpc),
    );
    defer {
        service.disable(configured.id) catch {};
        waitForCleanup(&service, configured.id) catch {};
        service.deinit();
    }
    try service.hydrateToken(configured.id, TEST_TOKEN);
    try service.enable(configured.id, 0);
    try waitForPhase(&service, configured.id, .awaiting_trust);
    var proposal = (try service.pinProposalAlloc(allocator, configured.id)).?;
    defer proposal.deinit();

    try configured.setExpectedIdentity(allocator, TEST_RUNTIME_B, TEST_INSTANCE_B);
    try profile_store.saveAtPath(allocator, std.testing.io, path, &.{configured});
    const committed = try service.trustProposal(&proposal);
    try std.testing.expectEqual(PinAdoption.reconnect_required, committed.adoption);
    try std.testing.expect(!committed.wrote_profile);
    var authoritative = try profile_store.loadAtPath(allocator, std.testing.io, path);
    defer authoritative.deinit(allocator);
    try std.testing.expectEqualStrings(
        TEST_RUNTIME_B,
        authoritative.items[0].expected_runtime_id.?,
    );
    try std.testing.expectEqualStrings(
        TEST_INSTANCE_B,
        authoritative.items[0].expected_instance_id.?,
    );
    try std.testing.expect(!service.snapshot(configured.id).?.execution_ready);
    try service.disable(configured.id);
    try waitForCleanup(&service, configured.id);
}

test "service owns secret lifecycle independently from persisted profiles" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try testPathAlloc(allocator, tmp.dir);
    defer allocator.free(path);

    var configured = try profile.Profile.createSshTunnel(
        allocator,
        std.testing.io,
        "Credential VM",
        null,
        .{ .host = "runtime.example" },
    );
    defer configured.deinit(allocator);
    try profile_store.saveAtPath(allocator, std.testing.io, path, &.{configured});

    var ports: TestPorts = .{ .values = &.{43_127} };
    var tunnel: TestTunnel = .{};
    var rpc: TestRpc = .{};
    var service = try Self.init(
        allocator,
        std.testing.io,
        path,
        testDependencies(&ports, &tunnel, &rpc),
    );
    defer {
        service.disable(configured.id) catch {};
        waitForCleanup(&service, configured.id) catch {};
        service.deinit();
    }
    try std.testing.expectError(
        error.MissingRuntimeCredential,
        service.enable(configured.id, 0),
    );
    try service.hydrateToken(configured.id, TEST_TOKEN);
    try service.enable(configured.id, 1);
    try std.testing.expectEqual(connection.Phase.connecting, service.snapshot(configured.id).?.phase);
    try std.testing.expect(try service.clearToken(configured.id));
    try std.testing.expectEqual(connection.Phase.disabled, service.snapshot(configured.id).?.phase);
    try std.testing.expect(!(try service.clearToken(configured.id)));
    try waitForCleanup(&service, configured.id);

    var persisted = try profile_store.loadAtPath(allocator, std.testing.io, path);
    defer persisted.deinit(allocator);
    try std.testing.expect(persisted.items[0].expected_runtime_id == null);
}

test "service exposes bounded snapshots for multiple independently owned profiles" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try testPathAlloc(allocator, tmp.dir);
    defer allocator.free(path);

    var first = try profile.Profile.createSshTunnel(
        allocator,
        std.testing.io,
        "First VM",
        null,
        .{ .host = "first.example" },
    );
    defer first.deinit(allocator);
    var second = try profile.Profile.createSshTunnel(
        allocator,
        std.testing.io,
        "Second VM",
        null,
        .{ .host = "second.example" },
    );
    defer second.deinit(allocator);
    try profile_store.saveAtPath(allocator, std.testing.io, path, &.{ first, second });

    var service = try Self.init(allocator, std.testing.io, path, .{});
    defer service.deinit();
    const snapshots = try service.snapshotsAlloc(allocator);
    defer allocator.free(snapshots);
    try std.testing.expectEqual(@as(usize, 2), snapshots.len);
    try std.testing.expectEqualStrings(first.id, snapshots[0].profile_id);
    try std.testing.expectEqualStrings("First VM", snapshots[0].label);
    try std.testing.expectEqualStrings(second.id, snapshots[1].profile_id);
    try std.testing.expectEqualStrings("Second VM", snapshots[1].label);
}

test "service profile crud persists under lock and rereads authoritatively" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try testPathAlloc(allocator, tmp.dir);
    defer allocator.free(path);
    try profile_store.saveAtPath(allocator, std.testing.io, path, &.{});

    var ports: TestPorts = .{ .values = &.{43_140} };
    var tunnel: TestTunnel = .{};
    var rpc: TestRpc = .{};
    var service = try Self.init(allocator, std.testing.io, path, testDependencies(&ports, &tunnel, &rpc));
    defer service.deinit();

    try std.testing.expectError(error.InvalidSshHost, service.createSshProfile(allocator, .{
        .label = "Bad",
        .ssh = .{ .host = "-evil" },
    }));
    const id = try service.createSshProfile(allocator, .{
        .label = "  Build VM  ",
        .ssh = .{ .host = "runtime.example", .user = "verde", .port = 2222 },
    });
    defer allocator.free(id);
    try std.testing.expectEqualStrings("Build VM", service.snapshot(id).?.label);

    var on_disk = try profile_store.loadAtPath(allocator, std.testing.io, path);
    defer on_disk.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), on_disk.items.len);
    try std.testing.expectEqual(@as(u16, 2222), on_disk.items[0].transport.ssh_tunnel.port);

    // Label-only edit keeps the endpoint and does not touch identity.
    try std.testing.expectEqual(ProfileReplacement.label_only, try service.updateSshProfile(id, .{
        .label = "Build VM 2",
        .ssh = .{ .host = "runtime.example", .user = "verde", .port = 2222 },
    }));
    try std.testing.expectEqualStrings("Build VM 2", service.snapshot(id).?.label);

    const diagnostics = try service.redactedDiagnosticsAlloc(allocator, id);
    defer allocator.free(diagnostics);
    try std.testing.expect(std.mem.indexOf(u8, diagnostics, "runtime.example") != null);
    try std.testing.expect(std.mem.indexOf(u8, diagnostics, "not provided") != null);

    try std.testing.expect(!(try service.removeProfile(id)));
    try std.testing.expect(service.snapshot(id) == null);
    var after_remove = try profile_store.loadAtPath(allocator, std.testing.io, path);
    defer after_remove.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), after_remove.items.len);
    try std.testing.expectError(error.UnknownRuntimeProfile, service.removeProfile(id));
}

test "endpoint edit drops trust, invalidates generation, and forgets nothing silently" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try testPathAlloc(allocator, tmp.dir);
    defer allocator.free(path);

    var configured = try profile.Profile.createSshTunnel(
        allocator,
        std.testing.io,
        "Build VM",
        null,
        .{ .host = "runtime.example", .user = "verde" },
    );
    defer configured.deinit(allocator);
    try profile_store.saveAtPath(allocator, std.testing.io, path, &.{configured});

    var ports: TestPorts = .{ .values = &.{ 43_141, 43_142 } };
    var tunnel: TestTunnel = .{};
    tunnel.allow_ready.store(true, .release);
    var rpc: TestRpc = .{};
    var service = try Self.init(allocator, std.testing.io, path, testDependencies(&ports, &tunnel, &rpc));
    defer {
        service.disable(configured.id) catch {};
        waitForCleanup(&service, configured.id) catch {};
        service.deinit();
    }
    try service.hydrateToken(configured.id, TEST_TOKEN);
    try service.enable(configured.id, 0);
    try waitForPhase(&service, configured.id, .awaiting_trust);
    var proposal = (try service.pinProposalAlloc(allocator, configured.id)).?;
    defer proposal.deinit();
    _ = try service.trustProposal(&proposal);
    try waitForExecutionReady(&service, configured.id);

    const diagnostics = try service.redactedDiagnosticsAlloc(allocator, configured.id);
    defer allocator.free(diagnostics);
    try std.testing.expect(std.mem.indexOf(u8, diagnostics, TEST_TOKEN) == null);
    try std.testing.expect(std.mem.indexOf(u8, diagnostics, "<redacted>") != null);

    try std.testing.expectEqual(ProfileReplacement.endpoint_changed, try service.updateSshProfile(configured.id, .{
        .label = "Build VM",
        .ssh = .{ .host = "other.example", .user = "verde" },
    }));
    const replaced = service.snapshot(configured.id).?;
    try std.testing.expect(!replaced.execution_ready);
    try std.testing.expect(!replaced.verified_runtime_matches_pin);
    try std.testing.expectEqual(connection.Phase.disabled, replaced.phase);
    var on_disk = try profile_store.loadAtPath(allocator, std.testing.io, path);
    defer on_disk.deinit(allocator);
    try std.testing.expect(on_disk.items[0].expected_runtime_id == null);
    try std.testing.expect(on_disk.items[0].expected_instance_id == null);
    try std.testing.expectEqualStrings("other.example", on_disk.items[0].transport.ssh_tunnel.host);
    // The in-memory token was wiped with the old peer; re-enable must ask again.
    try std.testing.expectError(error.MissingRuntimeCredential, service.enable(configured.id, 1));
}

test "reloadProfiles adopts external store edits authoritatively" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try testPathAlloc(allocator, tmp.dir);
    defer allocator.free(path);
    var a = try profile.Profile.createSshTunnel(allocator, std.testing.io, "A", null, .{ .host = "a.example" });
    defer a.deinit(allocator);
    try profile_store.saveAtPath(allocator, std.testing.io, path, &.{a});

    var ports: TestPorts = .{ .values = &.{43_143} };
    var tunnel: TestTunnel = .{};
    var rpc: TestRpc = .{};
    var service = try Self.init(allocator, std.testing.io, path, testDependencies(&ports, &tunnel, &rpc));
    defer service.deinit();

    var b = try profile.Profile.createSshTunnel(allocator, std.testing.io, "B", null, .{ .host = "b.example" });
    defer b.deinit(allocator);
    try profile_store.saveAtPath(allocator, std.testing.io, path, &.{b});
    try service.reloadProfiles();
    try std.testing.expect(service.snapshot(a.id) == null);
    try std.testing.expectEqualStrings("B", service.snapshot(b.id).?.label);
}
