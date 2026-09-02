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
pub const FailureReason = manager_mod.FailureReason;
pub const CredentialHydration = manager_mod.CredentialHydration;
pub const RpcTicket = manager_mod.RpcTicket;
pub const RpcCallResult = manager_mod.RpcCallResult;
pub const classifyRpcFailure = manager_mod.classifyRpcFailure;
pub const classifyProviderStatus = manager_mod.classifyProviderStatus;
pub const RuntimePinProposal = manager_mod.RuntimePinProposal;
pub const PinAdoption = manager_mod.PinAdoption;
pub const TrustResult = pin_controller.CommitResult;

allocator: std.mem.Allocator,
io: std.Io,
profile_path: []u8,
runtime_manager: manager_mod.Manager,
/// Durable home for paired device credentials; profiles hold only refs.
credentials: credential_store.Store,
durable_credentials_requested: bool,

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
        .durable_credentials_requested = dependencies.durable_credentials,
    };
    self.hydrateStoredDeviceCredentials(loaded.items);
    self.resumeDesiredConnections(loaded.items, @intCast(std.Io.Clock.awake.now(io).toMilliseconds()));
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

// Loads each paired profile's device credential by reference and records the
// exact non-secret outcome for snapshots. Backend and validation failures are
// never collapsed into an ordinary missing credential.
fn hydrateStoredDeviceCredentials(self: *Self, profiles: []const profile.Profile) void {
    for (profiles) |configured| {
        const ref = switch (configured.access) {
            .paired_device => |device| device.credential_ref,
            .connect => |link| link.credential_ref,
            else => continue,
        } orelse {
            self.runtime_manager.noteCredentialHydration(configured.id, .missing) catch {};
            continue;
        };
        const credential = self.credentials.getAlloc(self.allocator, ref) catch |err| {
            const hydration: manager_mod.CredentialHydration = switch (err) {
                error.InvalidStoredCredential, error.InvalidCredentialRef => .invalid,
                else => .backend_unavailable,
            };
            self.runtime_manager.noteCredentialHydration(configured.id, hydration) catch {};
            continue;
        } orelse {
            const hydration: CredentialHydration =
                if (self.durable_credentials_requested and self.credentials.backend == .memory_only)
                    .backend_unavailable
                else
                    .missing;
            self.runtime_manager.noteCredentialHydration(configured.id, hydration) catch {};
            continue;
        };
        defer {
            std.crypto.secureZero(u8, credential);
            self.allocator.free(credential);
        }
        self.runtime_manager.hydrateDeviceCredential(configured.id, credential) catch {
            self.runtime_manager.noteCredentialHydration(configured.id, .invalid) catch {};
        };
    }
}

// Desired state is resumed only after a valid paired credential is hydrated.
// Each enable starts one connection attempt; terminal trust/auth/configuration
// failures remain stopped in the manager until explicit user action.
fn resumeDesiredConnections(self: *Self, profiles: []const profile.Profile, now_ms: u64) void {
    for (profiles) |configured| {
        if (!configured.desired_enabled or configured.access.kind() == .admin_token) continue;
        const current = self.runtime_manager.snapshot(configured.id) orelse continue;
        if (current.credential_hydration != .loaded) continue;
        self.runtime_manager.enable(configured.id, now_ms) catch {};
    }
}

pub const ConnectBootstrapResult = struct {
    runtime_id: []const u8,
    instance_id: []const u8,
    device_id: []const u8,
    device_credential: []const u8,
};

/// Adopts a runtime-local device returned once by the public Connect bootstrap
/// endpoint. The external Connect device id is deliberately not accepted.
pub fn commitConnectBootstrap(
    self: *Self,
    profile_id: []const u8,
    result: ConnectBootstrapResult,
    now_ms: u64,
) !PairingCommit {
    try connection.validateRuntimeId(result.runtime_id);
    try connection.validateRuntimeId(result.instance_id);
    try profile.validateDeviceId(result.device_id);
    try headless.access_protocol.validateSecret(result.device_credential);
    const ref = try credential_store.deviceRefAlloc(self.allocator, profile_id);
    defer self.allocator.free(ref);

    var lock = try profile_store.acquireExclusiveAtPath(self.allocator, self.io, self.profile_path);
    defer lock.deinit();
    var loaded = try profile_store.loadAtPath(self.allocator, self.io, self.profile_path);
    defer loaded.deinit(self.allocator);
    const configured = findProfile(loaded.items, profile_id) orelse return error.UnknownRuntimeProfile;
    if (configured.access != .connect) return error.ProfileAccessMismatch;
    const expected_runtime = configured.expected_runtime_id orelse return error.RuntimeIdentityNotPinned;
    const expected_instance = configured.expected_instance_id orelse return error.RuntimeIdentityNotPinned;
    if (!std.mem.eql(u8, expected_runtime, result.runtime_id) or
        !std.mem.eql(u8, expected_instance, result.instance_id)) return error.PairingIdentityMismatch;
    try configured.setConnectRuntimeDevice(self.allocator, result.device_id, ref);
    configured.desired_enabled = true;

    var durable = self.credentials.backend.durable();
    self.credentials.put(ref, result.device_credential) catch |err| switch (err) {
        error.CredentialStoreUnavailable => durable = false,
        else => return err,
    };
    profile_store.saveAtPath(self.allocator, self.io, self.profile_path, loaded.items) catch |save_err| {
        _ = self.credentials.remove(ref) catch return error.CredentialCleanupIncomplete;
        return save_err;
    };
    var authoritative = try profile_store.loadAtPath(self.allocator, self.io, self.profile_path);
    defer authoritative.deinit(self.allocator);
    const persisted = findProfile(authoritative.items, profile_id) orelse return error.RuntimeProfileNotPersisted;
    _ = try self.runtime_manager.replaceProfile(persisted.*);
    try self.runtime_manager.hydrateDeviceCredential(profile_id, result.device_credential);
    try self.runtime_manager.enable(profile_id, now_ms);
    return .{ .durable = durable };
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
    try self.setDesiredEnabled(profile_id, true);
    return self.runtime_manager.enable(profile_id, now_ms);
}

pub fn disable(self: *Self, profile_id: []const u8) !void {
    try self.setDesiredEnabled(profile_id, false);
    return self.runtime_manager.disable(profile_id);
}

pub fn retry(self: *Self, profile_id: []const u8, now_ms: u64) !void {
    return self.runtime_manager.retry(profile_id, now_ms);
}

/// Invalidates an open session and immediately starts a fresh attempt while
/// preserving the user's desired-enabled setting. This is the manual recovery
/// path for a connected session whose repository/provider readiness is stale.
pub fn reconnect(self: *Self, profile_id: []const u8, now_ms: u64) !void {
    try self.setDesiredEnabled(profile_id, true);
    try self.runtime_manager.disable(profile_id);
    return self.runtime_manager.enable(profile_id, now_ms);
}

fn setDesiredEnabled(self: *Self, profile_id: []const u8, desired_enabled: bool) !void {
    var lock = try profile_store.acquireExclusiveAtPath(self.allocator, self.io, self.profile_path);
    defer lock.deinit();
    var loaded = try profile_store.loadAtPath(self.allocator, self.io, self.profile_path);
    defer loaded.deinit(self.allocator);
    const configured = findProfile(loaded.items, profile_id) orelse return error.UnknownRuntimeProfile;
    if (configured.access.kind() == .admin_token) return;
    if (configured.desired_enabled == desired_enabled) return;
    configured.desired_enabled = desired_enabled;
    try profile_store.saveAtPath(self.allocator, self.io, self.profile_path, loaded.items);
    _ = try self.runtime_manager.replaceProfile(configured.*);
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

/// Creates a directly reachable HTTPS Pair profile. The URL is non-secret;
/// the one-time code and resulting device credential never enter the profile.
pub fn createDirectPairedProfile(
    self: *Self,
    allocator: std.mem.Allocator,
    label: []const u8,
    https_url: []const u8,
) ![]u8 {
    var created = try profile.Profile.createPairedDirect(self.allocator, self.io, label, https_url, null);
    defer created.deinit(self.allocator);
    return self.persistNewProfile(allocator, created);
}

pub fn updateDirectPairedProfile(
    self: *Self,
    profile_id: []const u8,
    label: []const u8,
    https_url: []const u8,
) !ProfileReplacement {
    var lock = try profile_store.acquireExclusiveAtPath(self.allocator, self.io, self.profile_path);
    defer lock.deinit();
    var loaded = try profile_store.loadAtPath(self.allocator, self.io, self.profile_path);
    defer loaded.deinit(self.allocator);
    const configured = findProfile(loaded.items, profile_id) orelse return error.UnknownRuntimeProfile;
    if (configured.transport != .direct_https or configured.access != .paired_device) return error.ProfileAccessMismatch;
    const canonical = try profile.sanitizedRuntimeHttpsOriginAlloc(self.allocator, https_url);
    defer self.allocator.free(canonical);
    const changed = !std.mem.eql(u8, configured.transport.direct_https.https_url.?, canonical);
    const previous_ref = if (changed and configured.access.paired_device.credential_ref != null)
        try self.allocator.dupe(u8, configured.access.paired_device.credential_ref.?)
    else
        null;
    defer if (previous_ref) |value| self.allocator.free(value);
    try configured.setLabel(self.allocator, label);
    if (changed) {
        var endpoint: profile.DirectTransport = .{ .https_url = try self.allocator.dupe(u8, canonical) };
        configured.transport.direct_https.deinit(self.allocator);
        configured.transport.direct_https = endpoint;
        endpoint = undefined;
        try configured.setExpectedIdentity(self.allocator, null, null);
        try configured.clearPairedDevice(self.allocator);
        configured.desired_enabled = false;
    }
    if (previous_ref) |value| _ = try self.credentials.remove(value);
    try profile_store.saveAtPath(self.allocator, self.io, self.profile_path, loaded.items);
    var authoritative = try profile_store.loadAtPath(self.allocator, self.io, self.profile_path);
    defer authoritative.deinit(self.allocator);
    const persisted = findProfile(authoritative.items, profile_id) orelse return error.RuntimeProfileNotPersisted;
    const replacement = try self.runtime_manager.replaceProfile(persisted.*);
    return replacement;
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

/// Stores the credential by reference before persisting the confirmed device
/// reference and exchanged identity pin, then lets the
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
    configured.desired_enabled = true;

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
    profile_store.saveAtPath(self.allocator, self.io, self.profile_path, loaded.items) catch |save_err| {
        _ = self.credentials.remove(ref) catch return error.CredentialCleanupIncomplete;
        return save_err;
    };

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
    var held = false;
    if (ref_copy) |ref| {
        held = try self.credentials.remove(ref);
    }
    try configured.clearPairedDevice(self.allocator);
    configured.desired_enabled = false;
    try profile_store.saveAtPath(self.allocator, self.io, self.profile_path, loaded.items);

    held = (try self.runtime_manager.clearDeviceCredential(profile_id)) or held;
    var authoritative = try profile_store.loadAtPath(self.allocator, self.io, self.profile_path);
    defer authoritative.deinit(self.allocator);
    const persisted = findProfile(authoritative.items, profile_id) orelse return error.RuntimeProfileNotPersisted;
    _ = try self.runtime_manager.replaceProfile(persisted.*);
    return held;
}

/// Edits non-secret fields. An endpoint change treats the destination as a new
/// peer: paired-device metadata and credentials, the identity pin, desired
/// state, and the live generation are all cleared. Administrator tokens are
/// process-only and are wiped when the manager replaces the endpoint.
pub fn updateSshProfile(self: *Self, profile_id: []const u8, input: SshProfileInput) !ProfileReplacement {
    var lock = try profile_store.acquireExclusiveAtPath(self.allocator, self.io, self.profile_path);
    defer lock.deinit();
    var loaded = try profile_store.loadAtPath(self.allocator, self.io, self.profile_path);
    defer loaded.deinit(self.allocator);
    const configured = findProfile(loaded.items, profile_id) orelse return error.UnknownRuntimeProfile;

    const endpoint_changed = !configured.sameSshEndpoint(input.ssh);
    const previous_ref = if (endpoint_changed and configured.access == .paired_device and
        configured.access.paired_device.credential_ref != null)
        try self.allocator.dupe(u8, configured.access.paired_device.credential_ref.?)
    else
        null;
    defer if (previous_ref) |value| self.allocator.free(value);
    try configured.setLabel(self.allocator, input.label);
    if (endpoint_changed) {
        try configured.replaceSshTunnel(self.allocator, input.ssh);
        try configured.setExpectedIdentity(self.allocator, null, null);
        if (configured.access == .paired_device) try configured.clearPairedDevice(self.allocator);
        configured.desired_enabled = false;
    }
    // Keep the durable reference intact when keyring cleanup cannot complete;
    // the user can retry instead of being told a possibly-live secret is gone.
    if (previous_ref) |value| _ = try self.credentials.remove(value);
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
    const plane_changed = !configured.sameControlPlane(control_plane_url);
    const previous_ref = if (plane_changed and configured.access.connect.credential_ref != null)
        try self.allocator.dupe(u8, configured.access.connect.credential_ref.?)
    else
        null;
    defer if (previous_ref) |value| self.allocator.free(value);
    try configured.setLabel(self.allocator, label);
    if (plane_changed) {
        try configured.setControlPlaneUrl(self.allocator, control_plane_url);
        configured.desired_enabled = false;
    }
    if (previous_ref) |value| _ = try self.credentials.remove(value);
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

/// Persists the selected endpoint metadata, link id, and advertised
/// runtime/instance identity. Bootstrap must return that exact identity before
/// the runtime-local credential is adopted.
pub fn selectConnectRuntime(self: *Self, profile_id: []const u8, selection: ConnectRuntimeSelection) !void {
    var lock = try profile_store.acquireExclusiveAtPath(self.allocator, self.io, self.profile_path);
    defer lock.deinit();
    var loaded = try profile_store.loadAtPath(self.allocator, self.io, self.profile_path);
    defer loaded.deinit(self.allocator);
    const configured = findProfile(loaded.items, profile_id) orelse return error.UnknownRuntimeProfile;
    const previous_ref = if (configured.access == .connect and configured.access.connect.credential_ref != null)
        try self.allocator.dupe(u8, configured.access.connect.credential_ref.?)
    else
        null;
    defer if (previous_ref) |value| self.allocator.free(value);
    try configured.setConnectEndpoint(self.allocator, selection.https_url, selection.wss_url, selection.spki_sha256, selection.link_id);
    try configured.setExpectedIdentity(self.allocator, selection.runtime_id, selection.instance_id);
    configured.desired_enabled = false;
    if (previous_ref) |value| _ = try self.credentials.remove(value);
    // Fail closed before durable adoption. Building the replacement entry can
    // still allocate after the save; the old generation and both live secret
    // forms must already be unusable if that allocation fails.
    _ = try self.runtime_manager.clearDeviceCredential(profile_id);
    try profile_store.saveAtPath(self.allocator, self.io, self.profile_path, loaded.items);

    var authoritative = try profile_store.loadAtPath(self.allocator, self.io, self.profile_path);
    defer authoritative.deinit(self.allocator);
    const persisted = findProfile(authoritative.items, profile_id) orelse return error.RuntimeProfileNotPersisted;
    try self.runtime_manager.replaceConnectPeer(persisted.*);
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
        // Delete first: on failure the profile retains the only durable cleanup
        // reference and the caller receives an actionable error.
        if (configured.access == .paired_device) {
            if (configured.access.paired_device.credential_ref) |ref| _ = try self.credentials.remove(ref);
        } else if (configured.access == .connect) {
            if (configured.access.connect.credential_ref) |ref| _ = try self.credentials.remove(ref);
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
    self.resumeDesiredConnections(loaded.items, @intCast(std.Io.Clock.awake.now(self.io).toMilliseconds()));
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
        .direct_https => |endpoint| try w.print(
            "transport: direct_https https_url={s} wss_url={s} spki_sha256={s}\n",
            .{ endpoint.https_url orelse "<missing>", endpoint.wss_url orelse "<derived>", endpoint.spki_sha256 orelse "<pkix-only>" },
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
            "access: connect control_plane_url={s} link_id={s} runtime_device_id={s} credential_ref={s} device_credential={s}\ncredential_store: {s}\n",
            .{
                link.control_plane_url,
                link.link_id orelse "<none>",
                link.device_id orelse "<not bootstrapped>",
                link.credential_ref orelse "<none>",
                if (snap.device_credential_held) "held in memory (<redacted>)" else "not loaded",
                self.credentials.backend.description(),
            },
        ),
    }
    try w.print("phase: {s}\nfailure: {s}\ntunnel: {s}\n", .{
        @tagName(snap.phase),
        if (snap.failure) |failure| @tagName(failure) else "none",
        @tagName(snap.tunnel_lifecycle),
    });
    try w.print("failure_reason: {s}\nautomatic_retry_scheduled: {}\nretry_attempt: {d}\ndesired_enabled: {}\ncredential_hydration: {s}\n", .{
        if (snap.failure_reason) |reason| @tagName(reason) else "none",
        snap.automatic_retry_scheduled,
        snap.retry_attempt,
        snap.desired_enabled,
        @tagName(snap.credential_hydration),
    });
    if (snap.retry_at_ms) |retry_at_ms| {
        try w.print("retry_at_ms: {d}\n", .{retry_at_ms});
    } else {
        try w.writeAll("retry_at_ms: none\n");
    }
    if (snap.last_successful_connection_ms) |connected_at_ms| {
        try w.print("last_successful_connection_ms: {d}\n", .{connected_at_ms});
    } else {
        try w.writeAll("last_successful_connection_ms: none\n");
    }
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
const TEST_DEVICE_CREDENTIAL =
    "0123456789abcdef0123456789abcdef" ++
    "fedcba9876543210fedcba9876543210";
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

const TEST_ATTACHMENT_ID = "aabbccddeeff00112233445566778899";

const TestRpc = struct {
    retained: std.atomic.Value(usize) = .init(0),
    targeted_calls: std.atomic.Value(usize) = .init(0),
    repository_route_calls: std.atomic.Value(usize) = .init(0),
    attachment_create_calls: std.atomic.Value(usize) = .init(0),
    attachment_append_calls: std.atomic.Value(usize) = .init(0),
    attachment_commit_calls: std.atomic.Value(usize) = .init(0),
    attachment_turn_reference_calls: std.atomic.Value(usize) = .init(0),
    valid_targets: std.atomic.Value(bool) = .init(true),
    valid_repository_route: std.atomic.Value(bool) = .init(true),
    valid_attachment_flow: std.atomic.Value(bool) = .init(true),

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
        target: manager_mod.TransportTarget,
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

        const runtime_id = switch (target) {
            .loopback => |port| if (port == 43_127) TEST_RUNTIME_A else TEST_RUNTIME_B,
            .direct_https => TEST_RUNTIME_A,
        };
        if (parsed.request.target) |request_target| {
            _ = self.targeted_calls.fetchAdd(1, .acq_rel);
            if (!std.mem.eql(u8, request_target.runtime_id, runtime_id) or
                !std.mem.eql(u8, request_target.instance_id, TEST_INSTANCE_A))
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
            // Repository turns may reference staged uploads only as opaque
            // IDs — never as desktop filesystem paths anywhere in the frame.
            if (valid) {
                if (params.object.get("attachments")) |attachments| {
                    if (attachments == .array and attachments.array.items.len != 0) {
                        _ = self.attachment_turn_reference_calls.fetchAdd(1, .acq_rel);
                        for (attachments.array.items) |entry| {
                            const ok = entry == .string and std.mem.eql(u8, entry.string, TEST_ATTACHMENT_ID);
                            if (!ok) self.valid_attachment_flow.store(false, .release);
                        }
                    }
                }
                if (std.mem.indexOf(u8, rpc_json, "/desktop/") != null) {
                    self.valid_attachment_flow.store(false, .release);
                }
            }
        }
        if (std.mem.eql(u8, parsed.request.method, "chat.attachment.create")) {
            _ = self.attachment_create_calls.fetchAdd(1, .acq_rel);
            const params = parsed.request.params;
            const valid = params == .object and
                params.object.get("mime") != null and
                params.object.get("byte_size") != null and
                params.object.get("path") == null and
                std.mem.indexOf(u8, rpc_json, "/desktop/") == null;
            if (!valid) self.valid_attachment_flow.store(false, .release);
            return headless.encodeOkResponse(allocator, parsed.request.id, .{
                .attachment_id = TEST_ATTACHMENT_ID,
                .max_chunk_bytes = 48_000,
            }) catch error.OutOfMemory;
        }
        if (std.mem.eql(u8, parsed.request.method, "chat.attachment.append")) {
            _ = self.attachment_append_calls.fetchAdd(1, .acq_rel);
            const params = parsed.request.params;
            const id_value = if (params == .object) params.object.get("attachment_id") orelse std.json.Value.null else std.json.Value.null;
            const valid = params == .object and
                id_value == .string and
                std.mem.eql(u8, id_value.string, TEST_ATTACHMENT_ID) and
                params.object.get("offset") != null and
                params.object.get("data") != null;
            if (!valid) self.valid_attachment_flow.store(false, .release);
            return headless.encodeOkResponse(allocator, parsed.request.id, .{
                .received_bytes = 16,
            }) catch error.OutOfMemory;
        }
        if (std.mem.eql(u8, parsed.request.method, "chat.attachment.commit")) {
            _ = self.attachment_commit_calls.fetchAdd(1, .acq_rel);
            const params = parsed.request.params;
            const id_value = if (params == .object) params.object.get("attachment_id") orelse std.json.Value.null else std.json.Value.null;
            const valid = id_value == .string and std.mem.eql(u8, id_value.string, TEST_ATTACHMENT_ID);
            if (!valid) self.valid_attachment_flow.store(false, .release);
            return headless.encodeOkResponse(allocator, parsed.request.id, .{
                .attachment_id = TEST_ATTACHMENT_ID,
                .byte_size = 16,
                .mime = "image/png",
            }) catch error.OutOfMemory;
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
            manager_mod.CHAT_ATTACHMENT_CAPABILITY,
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
    if (service.beginRpc(configured.id, "core.snapshot", .{})) |_| {
        return error.OldConnectCredentialAuthorizedRpc;
    } else |err| {
        try std.testing.expectEqual(error.RuntimeNotExecutionReady, err);
    }
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
    try std.testing.expect(ready.chat_attachment_capable);
    try std.testing.expectEqual(@as(usize, 1_048_576), ready.max_attachment_bytes);
    try std.testing.expectEqual(@as(usize, 65_536), ready.max_request_bytes);
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

    // Staged attachment upload chain: create -> append -> commit, then a
    // repository turn that references only the returned opaque id. The fake
    // runtime asserts no desktop-local path or legacy image params leak
    // through any frame in the chain.
    const create_ticket = try service.beginRpc(configured.id, "chat.attachment.create", .{
        .mime = "image/png",
        .byte_size = 16,
    });
    var create_result = try waitForRpcResult(&service, create_ticket);
    defer create_result.deinit();
    switch (create_result) {
        .response => {},
        .failed, .canceled => return error.TestExpectedRpcResponse,
    }
    const append_ticket = try service.beginRpc(configured.id, "chat.attachment.append", .{
        .attachment_id = TEST_ATTACHMENT_ID,
        .offset = 0,
        .data = "iVBORw0KGgoAAAANSUhEUg==",
    });
    var append_result = try waitForRpcResult(&service, append_ticket);
    defer append_result.deinit();
    const commit_ticket = try service.beginRpc(configured.id, "chat.attachment.commit", .{
        .attachment_id = TEST_ATTACHMENT_ID,
    });
    var commit_result = try waitForRpcResult(&service, commit_ticket);
    defer commit_result.deinit();
    const attachment_ids: []const []const u8 = &.{TEST_ATTACHMENT_ID};
    const attachment_turn_ticket = try service.beginRpc(configured.id, "chat.turn.start", .{
        .turn_id = "route-turn-attach",
        .workspace_id = "workspace",
        .local_thread_id = "thread",
        .repository_id = "repo-api",
        .relative_cwd = "services/api",
        .provider = "codex",
        .harness = "local_cli",
        .prompt = "describe this image",
        .provider_thread_id = null,
        .thread_title = "Routed",
        .model_ref = null,
        .reasoning_effort = null,
        .opencode_reasoning_variant = null,
        .cursor_model_params_json = null,
        .fast_mode = false,
        .access_mode = "supervised",
        .message_id = "route-message-attach",
        .attachments = attachment_ids,
    });
    var attachment_turn_result = try waitForRpcResult(&service, attachment_turn_ticket);
    defer attachment_turn_result.deinit();
    try std.testing.expectEqual(@as(usize, 1), rpc.attachment_create_calls.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), rpc.attachment_append_calls.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), rpc.attachment_commit_calls.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), rpc.attachment_turn_reference_calls.load(.acquire));
    try std.testing.expect(rpc.valid_attachment_flow.load(.acquire));
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

test "desired paired runtime resumes only after restart credential hydration" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try testPathAlloc(allocator, tmp.dir);
    defer allocator.free(path);

    var configured = try profile.Profile.createPairedSshTunnel(
        allocator,
        std.testing.io,
        "Remembered VM",
        .{ .host = "runtime.example", .user = "verde" },
    );
    defer configured.deinit(allocator);
    const credential_ref = try credential_store.deviceRefAlloc(allocator, configured.id);
    defer allocator.free(credential_ref);
    try configured.setPairedDevice(allocator, "0123456789abcdef0123456789abcdef", credential_ref);
    try configured.setExpectedIdentity(allocator, TEST_RUNTIME_A, TEST_INSTANCE_A);
    try profile_store.saveAtPath(allocator, std.testing.io, path, &.{configured});

    var first_ports: TestPorts = .{ .values = &.{43_127} };
    var first_tunnel: TestTunnel = .{};
    var first_rpc: TestRpc = .{};
    var first = try Self.init(
        allocator,
        std.testing.io,
        path,
        testDependencies(&first_ports, &first_tunnel, &first_rpc),
    );
    try first.credentials.put(credential_ref, TEST_DEVICE_CREDENTIAL);
    first.hydrateStoredDeviceCredentials(&.{configured});
    try first.enable(configured.id, 1_000);
    try std.testing.expect(first.snapshot(configured.id).?.desired_enabled);
    try first.runtime_manager.disable(configured.id);
    try waitForCleanup(&first, configured.id);
    first.deinit();

    var persisted = try profile_store.loadAtPath(allocator, std.testing.io, path);
    defer persisted.deinit(allocator);
    try std.testing.expect(persisted.items[0].desired_enabled);

    var second_ports: TestPorts = .{ .values = &.{43_128} };
    var second_tunnel: TestTunnel = .{};
    var second_rpc: TestRpc = .{};
    var second = try Self.init(
        allocator,
        std.testing.io,
        path,
        testDependencies(&second_ports, &second_tunnel, &second_rpc),
    );
    defer {
        second.runtime_manager.disable(configured.id) catch {};
        waitForCleanup(&second, configured.id) catch {};
        second.deinit();
    }
    const before_hydration = second.snapshot(configured.id).?;
    try std.testing.expectEqual(connection.Phase.disabled, before_hydration.phase);
    try std.testing.expectEqual(CredentialHydration.missing, before_hydration.credential_hydration);
    try std.testing.expectEqual(FailureReason.authentication_required, before_hydration.failure_reason.?);
    try std.testing.expect(before_hydration.desired_enabled);

    try second.credentials.put(credential_ref, TEST_DEVICE_CREDENTIAL);
    second.hydrateStoredDeviceCredentials(persisted.items);
    second.resumeDesiredConnections(persisted.items, 2_000);
    const resumed = second.snapshot(configured.id).?;
    try std.testing.expectEqual(connection.Phase.connecting, resumed.phase);
    try std.testing.expectEqual(CredentialHydration.loaded, resumed.credential_hydration);
    try std.testing.expect(resumed.desired_enabled);
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

test "paired SSH endpoint edit reloads without the old device credential" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try testPathAlloc(allocator, tmp.dir);
    defer allocator.free(path);

    var configured = try profile.Profile.createPairedSshTunnel(
        allocator,
        std.testing.io,
        "Paired VM",
        .{ .host = "old.example", .user = "verde" },
    );
    defer configured.deinit(allocator);
    const credential_ref = try credential_store.deviceRefAlloc(allocator, configured.id);
    defer allocator.free(credential_ref);
    try configured.setPairedDevice(allocator, "0123456789abcdef0123456789abcdef", credential_ref);
    try configured.setExpectedIdentity(allocator, TEST_RUNTIME_A, TEST_INSTANCE_A);
    configured.desired_enabled = true;
    try profile_store.saveAtPath(allocator, std.testing.io, path, &.{configured});

    var ports: TestPorts = .{ .values = &.{43_144} };
    var tunnel: TestTunnel = .{};
    var rpc: TestRpc = .{};
    var service = try Self.init(allocator, std.testing.io, path, testDependencies(&ports, &tunnel, &rpc));
    defer service.deinit();
    try service.credentials.put(credential_ref, TEST_DEVICE_CREDENTIAL);
    service.hydrateStoredDeviceCredentials(&.{configured});
    try std.testing.expect(service.snapshot(configured.id).?.device_credential_held);

    try std.testing.expectEqual(ProfileReplacement.endpoint_changed, try service.updateSshProfile(configured.id, .{
        .label = "Paired VM",
        .ssh = .{ .host = "new.example", .user = "verde" },
    }));
    try std.testing.expect((try service.credentials.getAlloc(allocator, credential_ref)) == null);

    var persisted = try profile_store.loadAtPath(allocator, std.testing.io, path);
    defer persisted.deinit(allocator);
    const edited = persisted.items[0];
    try std.testing.expectEqualStrings("new.example", edited.transport.ssh_tunnel.host);
    try std.testing.expect(edited.access.paired_device.device_id == null);
    try std.testing.expect(edited.access.paired_device.credential_ref == null);
    try std.testing.expect(edited.expected_runtime_id == null);
    try std.testing.expect(edited.expected_instance_id == null);
    try std.testing.expect(!edited.desired_enabled);

    try service.reloadProfiles();
    const reloaded = service.snapshot(configured.id).?;
    try std.testing.expect(!reloaded.device_credential_held);
    try std.testing.expectEqual(CredentialHydration.missing, reloaded.credential_hydration);
    // Missing start credentials are rejected before a tunnel or access-token
    // mint task can be created for the replacement endpoint.
    try std.testing.expectError(error.MissingRuntimeCredential, service.enable(configured.id, 2_000));
    try std.testing.expectEqual(connection.Phase.disabled, service.snapshot(configured.id).?.phase);
}

test "Connect reselection at the same endpoint invalidates the old peer and credentials" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try testPathAlloc(allocator, tmp.dir);
    defer allocator.free(path);

    const https_url = "https://runtime.example";
    const wss_url = "wss://runtime.example/ws";
    const spki_sha256 = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
    var configured = try profile.Profile.createConnect(
        allocator,
        std.testing.io,
        "Connect VM",
        "https://control.example",
    );
    defer configured.deinit(allocator);
    try configured.setConnectEndpoint(
        allocator,
        https_url,
        wss_url,
        spki_sha256,
        "lnk_0123456789abcdef0123456789abcdef",
    );
    try configured.setExpectedIdentity(allocator, TEST_RUNTIME_A, TEST_INSTANCE_A);
    const credential_ref = try credential_store.deviceRefAlloc(allocator, configured.id);
    defer allocator.free(credential_ref);
    try configured.setConnectRuntimeDevice(
        allocator,
        "0123456789abcdef0123456789abcdef",
        credential_ref,
    );
    configured.desired_enabled = true;
    try profile_store.saveAtPath(allocator, std.testing.io, path, &.{configured});

    var ports: TestPorts = .{ .values = &.{43_145} };
    var tunnel: TestTunnel = .{};
    var rpc: TestRpc = .{};
    var service = try Self.init(allocator, std.testing.io, path, testDependencies(&ports, &tunnel, &rpc));
    defer service.deinit();
    try service.credentials.put(credential_ref, TEST_DEVICE_CREDENTIAL);
    service.hydrateStoredDeviceCredentials(&.{configured});
    try service.hydrateToken(configured.id, TEST_TOKEN);
    if (!service.snapshot(configured.id).?.credential_held) return error.OldConnectBearerNotLoaded;
    try service.enable(configured.id, 1_000);
    const old_peer = service.snapshot(configured.id).?;
    if (old_peer.phase == .disabled) return error.OldConnectGenerationNotStarted;
    if (!old_peer.device_credential_held) return error.OldConnectDeviceCredentialNotLoaded;
    try std.testing.expectEqualStrings(TEST_RUNTIME_A, service.runtime_manager.expectedRuntimeId(configured.id).?);
    try std.testing.expectEqualStrings(TEST_INSTANCE_A, service.runtime_manager.expectedInstanceId(configured.id).?);

    try service.selectConnectRuntime(configured.id, .{
        .link_id = "lnk_fedcba9876543210fedcba9876543210",
        .runtime_id = TEST_RUNTIME_B,
        .instance_id = TEST_INSTANCE_B,
        .https_url = https_url,
        .wss_url = wss_url,
        .spki_sha256 = spki_sha256,
    });
    if ((try service.credentials.getAlloc(allocator, credential_ref)) != null) {
        return error.OldConnectCredentialStillStored;
    }
    const selected = service.snapshot(configured.id).?;
    try std.testing.expectEqual(connection.Phase.disabled, selected.phase);
    if (selected.runtime != null) return error.OldConnectIdentityStillLive;
    if (selected.execution_ready) return error.OldConnectGenerationStillReady;
    if (selected.device_credential_held) return error.OldConnectDeviceCredentialStillLive;
    if (selected.credential_held) return error.OldConnectBearerStillLive;
    try std.testing.expectEqual(CredentialHydration.missing, selected.credential_hydration);
    try std.testing.expectEqualStrings(TEST_RUNTIME_B, service.runtime_manager.expectedRuntimeId(configured.id).?);
    try std.testing.expectEqualStrings(TEST_INSTANCE_B, service.runtime_manager.expectedInstanceId(configured.id).?);
    if (service.beginRpc(configured.id, "core.snapshot", .{})) |_| {
        return error.OldConnectCredentialAuthorizedRpc;
    } else |err| {
        try std.testing.expectEqual(error.RuntimeNotExecutionReady, err);
    }

    try service.reloadProfiles();
    const reloaded = service.snapshot(configured.id).?;
    try std.testing.expectEqual(connection.Phase.disabled, reloaded.phase);
    if (reloaded.runtime != null) return error.OldConnectIdentityRestoredOnReload;
    if (reloaded.device_credential_held) return error.OldConnectDeviceCredentialRestoredOnReload;
    if (reloaded.credential_held) return error.OldConnectBearerRestoredOnReload;
    try std.testing.expectEqualStrings(TEST_RUNTIME_B, service.runtime_manager.expectedRuntimeId(configured.id).?);
    try std.testing.expectEqualStrings(TEST_INSTANCE_B, service.runtime_manager.expectedInstanceId(configured.id).?);
    // No device credential survives to mint a bearer for the new link, even
    // though its transport URLs are byte-for-byte identical to the old peer.
    if (service.enable(configured.id, 2_000)) {
        return error.OldConnectCredentialMintedAfterReload;
    } else |err| {
        try std.testing.expectEqual(error.MissingRuntimeCredential, err);
    }
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
