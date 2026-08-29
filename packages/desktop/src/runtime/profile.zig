//! Owned, non-secret connection profiles for desktop-managed Verde runtimes.

const std = @import("std");

/// Version 3 adds a directly reachable HTTPS/WSS transport. Older documents
/// remain readable and are rewritten only on the next normal profile save.
pub const CURRENT_VERSION: u8 = 3;
pub const DEFAULT_SSH_PORT: u16 = 22;
pub const DEFAULT_REMOTE_GATEWAY_PORT: u16 = 7420;
pub const MAX_PROFILES: usize = 64;
/// Credential references name an OS credential-store item; they are never
/// the secret itself. Bounded so a hostile document cannot grow the store.
pub const MAX_CREDENTIAL_REF_BYTES: usize = 160;
pub const MAX_URL_BYTES: usize = 2048;
/// Base64url SHA-256 without padding, as published in runtime descriptors.
pub const SPKI_SHA256_BASE64URL_BYTES: usize = 43;

const MAX_DOCUMENT_BYTES: usize = 256 * 1024;
const MAX_LABEL_BYTES: usize = 80;
const MAX_HOST_BYTES: usize = 255;
const MAX_USER_BYTES: usize = 64;
const PROFILE_ID_PREFIX = "profile-";
const PROFILE_ID_RANDOM_BYTES: usize = 16;
const RUNTIME_ID_BYTES: usize = 16;
const VERSION_ONE_DOCUMENT_FIELDS = [_][]const u8{ "version", "profiles" };
const VERSION_ONE_PROFILE_FIELDS = [_][]const u8{
    "id",
    "label",
    "expected_runtime_id",
    "expected_instance_id",
    "transport",
};
const VERSION_TWO_PROFILE_FIELDS = VERSION_ONE_PROFILE_FIELDS ++ [_][]const u8{"access"};
const VERSION_ONE_LOCAL_TRANSPORT_FIELDS = [_][]const u8{"kind"};
const VERSION_ONE_SSH_TRANSPORT_FIELDS = [_][]const u8{
    "kind",
    "host",
    "user",
    "port",
    "remote_gateway_port",
};
const VERSION_TWO_CONNECT_TRANSPORT_FIELDS = [_][]const u8{
    "kind",
    "https_url",
    "wss_url",
    "spki_sha256",
};
const VERSION_THREE_DIRECT_TRANSPORT_FIELDS = VERSION_TWO_CONNECT_TRANSPORT_FIELDS;
const ACCESS_ADMIN_TOKEN_FIELDS = [_][]const u8{"method"};
const ACCESS_PAIRED_DEVICE_FIELDS = [_][]const u8{ "method", "device_id", "credential_ref" };
const ACCESS_CONNECT_FIELDS = [_][]const u8{ "method", "control_plane_url", "link_id", "device_id", "credential_ref" };

pub const SshTunnelInput = struct {
    host: []const u8,
    user: ?[]const u8 = null,
    port: u16 = DEFAULT_SSH_PORT,
    remote_gateway_port: u16 = DEFAULT_REMOTE_GATEWAY_PORT,
};

pub const SshTunnel = struct {
    host: []u8,
    user: ?[]u8,
    port: u16,
    remote_gateway_port: u16,

    pub fn deinit(self: *SshTunnel, allocator: std.mem.Allocator) void {
        allocator.free(self.host);
        if (self.user) |user| allocator.free(user);
        self.* = undefined;
    }
};

/// Endpoint resolved from a Connect control-plane runtime descriptor. Every
/// field is optional until the user selects and bootstraps a runtime.
pub const ConnectTransport = struct {
    https_url: ?[]u8 = null,
    wss_url: ?[]u8 = null,
    spki_sha256: ?[]u8 = null,

    pub fn deinit(self: *ConnectTransport, allocator: std.mem.Allocator) void {
        if (self.https_url) |value| allocator.free(value);
        if (self.wss_url) |value| allocator.free(value);
        if (self.spki_sha256) |value| allocator.free(value);
        self.* = undefined;
    }
};

/// Direct, CA/hostname-verified runtime endpoint (including Tailscale Serve).
/// `spki_sha256` is descriptor trust metadata; Zig 0.16's HTTP client does not
/// expose the peer SPKI, so it is never treated as a replacement for PKIX.
pub const DirectTransport = ConnectTransport;

pub const Transport = union(enum) {
    local_socket,
    ssh_tunnel: SshTunnel,
    direct_https: DirectTransport,
    connect: ConnectTransport,

    pub fn deinit(self: *Transport, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .local_socket => {},
            .ssh_tunnel => |*ssh| ssh.deinit(allocator),
            .direct_https => |*endpoint| endpoint.deinit(allocator),
            .connect => |*endpoint| endpoint.deinit(allocator),
        }
        self.* = undefined;
    }
};

pub const AccessKind = enum { admin_token, paired_device, connect };

/// Account-free Pair result. Both fields are null until a grant exchange has
/// been confirmed; `credential_ref` names the OS credential-store item that
/// holds the device credential and is never the credential itself.
pub const PairedDevice = struct {
    device_id: ?[]u8 = null,
    credential_ref: ?[]u8 = null,

    pub fn isPaired(self: PairedDevice) bool {
        return self.device_id != null and self.credential_ref != null;
    }

    pub fn deinit(self: *PairedDevice, allocator: std.mem.Allocator) void {
        if (self.device_id) |value| allocator.free(value);
        if (self.credential_ref) |value| allocator.free(value);
        self.* = undefined;
    }
};

/// Connect control-plane link. The OIDC session itself is never persisted.
pub const ConnectLink = struct {
    control_plane_url: []u8,
    link_id: ?[]u8 = null,
    /// Runtime-local device created by `/auth/connect/bootstrap`; never the
    /// external control-plane `dev_…` identifier.
    device_id: ?[]u8 = null,
    credential_ref: ?[]u8 = null,

    pub fn hasRuntimeDevice(self: ConnectLink) bool {
        return self.device_id != null and self.credential_ref != null;
    }

    pub fn deinit(self: *ConnectLink, allocator: std.mem.Allocator) void {
        allocator.free(self.control_plane_url);
        if (self.link_id) |value| allocator.free(value);
        if (self.device_id) |value| allocator.free(value);
        if (self.credential_ref) |value| allocator.free(value);
        self.* = undefined;
    }
};

/// How the desktop authenticates to the runtime. Only references and public
/// identifiers live here; bearer, device, and OIDC material never do.
pub const Access = union(enum) {
    admin_token,
    paired_device: PairedDevice,
    connect: ConnectLink,

    pub fn kind(self: Access) AccessKind {
        return switch (self) {
            .admin_token => .admin_token,
            .paired_device => .paired_device,
            .connect => .connect,
        };
    }

    pub fn deinit(self: *Access, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .admin_token => {},
            .paired_device => |*device| device.deinit(allocator),
            .connect => |*link| link.deinit(allocator),
        }
        self.* = undefined;
    }
};

pub const Profile = struct {
    id: []u8,
    label: []u8,
    expected_runtime_id: ?[]u8,
    expected_instance_id: ?[]u8 = null,
    transport: Transport,
    access: Access = .admin_token,

    /// Creates a local-socket profile with an identity that remains stable
    /// after the profile document is encoded and loaded again.
    pub fn createLocal(
        allocator: std.mem.Allocator,
        io: std.Io,
        label: []const u8,
        expected_runtime_id: ?[]const u8,
    ) !Profile {
        const id = try generateIdAlloc(allocator, io);
        errdefer allocator.free(id);
        const owned_label = try sanitizedLabelAlloc(allocator, label);
        errdefer allocator.free(owned_label);
        const owned_runtime_id = try ownedExpectedRuntimeIdAlloc(allocator, expected_runtime_id);
        return .{
            .id = id,
            .label = owned_label,
            .expected_runtime_id = owned_runtime_id,
            .expected_instance_id = null,
            .transport = .local_socket,
        };
    }

    /// Creates an SSH-forwarded profile. Authentication remains entirely in
    /// the user's SSH configuration and the future secret store.
    pub fn createSshTunnel(
        allocator: std.mem.Allocator,
        io: std.Io,
        label: []const u8,
        expected_runtime_id: ?[]const u8,
        input: SshTunnelInput,
    ) !Profile {
        const id = try generateIdAlloc(allocator, io);
        errdefer allocator.free(id);
        const owned_label = try sanitizedLabelAlloc(allocator, label);
        errdefer allocator.free(owned_label);
        const owned_runtime_id = try ownedExpectedRuntimeIdAlloc(allocator, expected_runtime_id);
        errdefer if (owned_runtime_id) |value| allocator.free(value);
        return .{
            .id = id,
            .label = owned_label,
            .expected_runtime_id = owned_runtime_id,
            .expected_instance_id = null,
            .transport = .{ .ssh_tunnel = try ownedSshTunnel(allocator, input) },
        };
    }

    /// Creates an SSH-forwarded profile that authenticates with a paired
    /// device instead of the administrator token. The device fields stay
    /// null until a one-time grant exchange has been confirmed.
    pub fn createPairedSshTunnel(
        allocator: std.mem.Allocator,
        io: std.Io,
        label: []const u8,
        input: SshTunnelInput,
    ) !Profile {
        var created = try createSshTunnel(allocator, io, label, null, input);
        created.access = .{ .paired_device = .{} };
        return created;
    }

    /// Creates an account-free Pair profile for a directly reachable HTTPS
    /// runtime. Identity is adopted only after the exchange confirmation.
    pub fn createPairedDirect(
        allocator: std.mem.Allocator,
        io: std.Io,
        label: []const u8,
        https_url: []const u8,
        wss_url: ?[]const u8,
    ) !Profile {
        const id = try generateIdAlloc(allocator, io);
        errdefer allocator.free(id);
        const owned_label = try sanitizedLabelAlloc(allocator, label);
        errdefer allocator.free(owned_label);
        const owned_https = try sanitizedRuntimeHttpsOriginAlloc(allocator, https_url);
        errdefer allocator.free(owned_https);
        const owned_wss = if (wss_url) |value| blk: {
            try validateRuntimeWssUrl(value);
            try validateRuntimeEndpointPair(owned_https, value);
            break :blk try allocator.dupe(u8, value);
        } else null;
        return .{
            .id = id,
            .label = owned_label,
            .expected_runtime_id = null,
            .expected_instance_id = null,
            .transport = .{ .direct_https = .{ .https_url = owned_https, .wss_url = owned_wss } },
            .access = .{ .paired_device = .{} },
        };
    }

    /// Creates a Connect profile bound to one self-hosted control plane. The
    /// runtime endpoint is filled in later from the signed-in inventory.
    pub fn createConnect(
        allocator: std.mem.Allocator,
        io: std.Io,
        label: []const u8,
        control_plane_url: []const u8,
    ) !Profile {
        const id = try generateIdAlloc(allocator, io);
        errdefer allocator.free(id);
        const owned_label = try sanitizedLabelAlloc(allocator, label);
        errdefer allocator.free(owned_label);
        const owned_url = try sanitizedHttpsUrlAlloc(allocator, control_plane_url);
        return .{
            .id = id,
            .label = owned_label,
            .expected_runtime_id = null,
            .expected_instance_id = null,
            .transport = .{ .connect = .{} },
            .access = .{ .connect = .{ .control_plane_url = owned_url } },
        };
    }

    /// Records a confirmed pairing. Fails without mutation unless the profile
    /// uses paired-device access; the credential itself is never accepted.
    pub fn setPairedDevice(
        self: *Profile,
        allocator: std.mem.Allocator,
        device_id: []const u8,
        credential_ref: []const u8,
    ) !void {
        const device = switch (self.access) {
            .paired_device => |*value| value,
            else => return error.ProfileAccessMismatch,
        };
        try validateDeviceId(device_id);
        try validateCredentialRef(credential_ref);
        const owned_device_id = try allocator.dupe(u8, device_id);
        errdefer allocator.free(owned_device_id);
        const owned_ref = try allocator.dupe(u8, credential_ref);
        if (device.device_id) |previous| allocator.free(previous);
        if (device.credential_ref) |previous| allocator.free(previous);
        device.device_id = owned_device_id;
        device.credential_ref = owned_ref;
    }

    /// Forgets the device reference so the profile reads as "not paired".
    /// Callers delete the referenced credential-store item separately.
    pub fn clearPairedDevice(self: *Profile, allocator: std.mem.Allocator) !void {
        const device = switch (self.access) {
            .paired_device => |*value| value,
            else => return error.ProfileAccessMismatch,
        };
        if (device.device_id) |previous| allocator.free(previous);
        if (device.credential_ref) |previous| allocator.free(previous);
        device.* = .{};
    }

    /// Stores the runtime descriptor the user selected from Connect inventory.
    pub fn setConnectEndpoint(
        self: *Profile,
        allocator: std.mem.Allocator,
        https_url: []const u8,
        wss_url: []const u8,
        spki_sha256: []const u8,
        link_id: []const u8,
    ) !void {
        const endpoint = switch (self.transport) {
            .connect => |*value| value,
            else => return error.ProfileAccessMismatch,
        };
        const link = switch (self.access) {
            .connect => |*value| value,
            else => return error.ProfileAccessMismatch,
        };
        try validateRuntimeWssUrl(wss_url);
        try validateSpkiSha256(spki_sha256);
        try validateLinkId(link_id);
        const owned_https = try sanitizedRuntimeHttpsOriginAlloc(allocator, https_url);
        errdefer allocator.free(owned_https);
        try validateRuntimeEndpointPair(owned_https, wss_url);
        const owned_wss = try allocator.dupe(u8, wss_url);
        errdefer allocator.free(owned_wss);
        const owned_spki = try allocator.dupe(u8, spki_sha256);
        errdefer allocator.free(owned_spki);
        const owned_link = try allocator.dupe(u8, link_id);
        var next: ConnectTransport = .{ .https_url = owned_https, .wss_url = owned_wss, .spki_sha256 = owned_spki };
        endpoint.deinit(allocator);
        endpoint.* = next;
        next = undefined;
        if (link.link_id) |previous| allocator.free(previous);
        link.link_id = owned_link;
        if (link.device_id) |previous| allocator.free(previous);
        if (link.credential_ref) |previous| allocator.free(previous);
        link.device_id = null;
        link.credential_ref = null;
    }

    pub fn setConnectRuntimeDevice(
        self: *Profile,
        allocator: std.mem.Allocator,
        device_id: []const u8,
        credential_ref: []const u8,
    ) !void {
        const link = switch (self.access) {
            .connect => |*value| value,
            else => return error.ProfileAccessMismatch,
        };
        try validateDeviceId(device_id);
        try validateCredentialRef(credential_ref);
        const owned_id = try allocator.dupe(u8, device_id);
        errdefer allocator.free(owned_id);
        const owned_ref = try allocator.dupe(u8, credential_ref);
        if (link.device_id) |value| allocator.free(value);
        if (link.credential_ref) |value| allocator.free(value);
        link.device_id = owned_id;
        link.credential_ref = owned_ref;
    }

    /// True when the Connect profile already points at this control plane.
    pub fn sameControlPlane(self: Profile, control_plane_url: []const u8) bool {
        return switch (self.access) {
            .connect => |link| std.mem.eql(u8, link.control_plane_url, std.mem.trimEnd(u8, std.mem.trim(u8, control_plane_url, &std.ascii.whitespace), "/")),
            else => false,
        };
    }

    /// Re-points a Connect profile at another control plane. The selected
    /// runtime endpoint, link, and identity pin belong to the old plane and
    /// are dropped so no trust carries over.
    pub fn setControlPlaneUrl(self: *Profile, allocator: std.mem.Allocator, control_plane_url: []const u8) !void {
        const endpoint = switch (self.transport) {
            .connect => |*value| value,
            else => return error.ProfileAccessMismatch,
        };
        const link = switch (self.access) {
            .connect => |*value| value,
            else => return error.ProfileAccessMismatch,
        };
        const owned_url = try sanitizedHttpsUrlAlloc(allocator, control_plane_url);
        allocator.free(link.control_plane_url);
        link.control_plane_url = owned_url;
        if (link.link_id) |previous| allocator.free(previous);
        link.link_id = null;
        if (link.device_id) |previous| allocator.free(previous);
        if (link.credential_ref) |previous| allocator.free(previous);
        link.device_id = null;
        link.credential_ref = null;
        endpoint.deinit(allocator);
        endpoint.* = .{};
        try self.setExpectedIdentity(allocator, null, null);
    }

    /// Replaces the pinned daemon identity without disturbing the existing
    /// pin if validation or allocation fails. Passing null clears the pin.
    pub fn setExpectedRuntimeId(
        self: *Profile,
        allocator: std.mem.Allocator,
        expected_runtime_id: ?[]const u8,
    ) !void {
        return self.setExpectedIdentity(allocator, expected_runtime_id, null);
    }

    /// Atomically replaces the durable runtime/instance identity pair. A
    /// runtime-only value is accepted solely for legacy migration and remains
    /// non-ready until an explicit trust flow persists the instance too.
    pub fn setExpectedIdentity(
        self: *Profile,
        allocator: std.mem.Allocator,
        expected_runtime_id: ?[]const u8,
        expected_instance_id: ?[]const u8,
    ) !void {
        if (expected_runtime_id == null and expected_instance_id != null) {
            return error.InvalidExpectedIdentityPair;
        }
        const next_runtime = try ownedExpectedRuntimeIdAlloc(allocator, expected_runtime_id);
        errdefer if (next_runtime) |value| allocator.free(value);
        const next_instance = try ownedExpectedInstanceIdAlloc(allocator, expected_instance_id);
        if (self.expected_runtime_id) |previous| allocator.free(previous);
        if (self.expected_instance_id) |previous| allocator.free(previous);
        self.expected_runtime_id = next_runtime;
        self.expected_instance_id = next_instance;
    }

    /// Replaces the display label; the stored value is left untouched on error.
    pub fn setLabel(self: *Profile, allocator: std.mem.Allocator, label: []const u8) !void {
        const owned_label = try sanitizedLabelAlloc(allocator, label);
        allocator.free(self.label);
        self.label = owned_label;
    }

    /// Replaces the SSH endpoint. Callers decide what an endpoint change means
    /// for the durable identity pin; this only swaps validated transport data.
    pub fn replaceSshTunnel(self: *Profile, allocator: std.mem.Allocator, input: SshTunnelInput) !void {
        var next = try ownedSshTunnel(allocator, input);
        errdefer next.deinit(allocator);
        self.transport.deinit(allocator);
        self.transport = .{ .ssh_tunnel = next };
    }

    /// True when both profiles reach the same SSH endpoint. Labels and pins
    /// are ignored because they do not change which peer is contacted.
    pub fn sameSshEndpoint(self: Profile, input: SshTunnelInput) bool {
        const ssh = switch (self.transport) {
            .local_socket, .direct_https, .connect => return false,
            .ssh_tunnel => |value| value,
        };
        const input_user = if (input.user) |value| std.mem.trim(u8, value, &std.ascii.whitespace) else null;
        const users_equal = if (ssh.user) |current|
            input_user != null and std.mem.eql(u8, current, input_user.?)
        else
            input_user == null or input_user.?.len == 0;
        return std.mem.eql(u8, ssh.host, std.mem.trim(u8, input.host, &std.ascii.whitespace)) and
            users_equal and ssh.port == input.port and ssh.remote_gateway_port == input.remote_gateway_port;
    }

    pub fn deinit(self: *Profile, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.label);
        if (self.expected_runtime_id) |runtime_id| allocator.free(runtime_id);
        if (self.expected_instance_id) |instance_id| allocator.free(instance_id);
        self.transport.deinit(allocator);
        self.access.deinit(allocator);
        self.* = undefined;
    }
};

pub const OwnedProfiles = struct {
    items: []Profile,

    pub fn deinit(self: *OwnedProfiles, allocator: std.mem.Allocator) void {
        for (self.items) |*profile| profile.deinit(allocator);
        allocator.free(self.items);
        self.* = undefined;
    }
};

/// Generates an opaque profile identity. The caller owns the returned slice.
pub fn generateIdAlloc(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    var random_bytes: [PROFILE_ID_RANDOM_BYTES]u8 = undefined;
    try io.randomSecure(&random_bytes);
    const hex = std.fmt.bytesToHex(random_bytes, .lower);
    return std.fmt.allocPrint(allocator, PROFILE_ID_PREFIX ++ "{s}", .{@as([]const u8, &hex)});
}

/// Encodes only the non-secret profile schema. Callers own the returned JSON.
pub fn encodeAlloc(allocator: std.mem.Allocator, profiles: []const Profile) ![]u8 {
    try validateProfileSlice(profiles);

    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var stringify: std.json.Stringify = .{
        .writer = &writer.writer,
        .options = .{ .whitespace = .indent_2 },
    };
    try stringify.beginObject();
    try stringify.objectField("version");
    try stringify.write(CURRENT_VERSION);
    try stringify.objectField("profiles");
    try stringify.beginArray();
    for (profiles) |profile| {
        try stringify.beginObject();
        try stringify.objectField("id");
        try stringify.write(profile.id);
        try stringify.objectField("label");
        try stringify.write(profile.label);
        if (profile.expected_runtime_id) |runtime_id| {
            try stringify.objectField("expected_runtime_id");
            try stringify.write(runtime_id);
        }
        if (profile.expected_instance_id) |instance_id| {
            try stringify.objectField("expected_instance_id");
            try stringify.write(instance_id);
        }
        try stringify.objectField("transport");
        try stringify.beginObject();
        switch (profile.transport) {
            .local_socket => {
                try stringify.objectField("kind");
                try stringify.write("local_socket");
            },
            .ssh_tunnel => |ssh| {
                try stringify.objectField("kind");
                try stringify.write("ssh_tunnel");
                try stringify.objectField("host");
                try stringify.write(ssh.host);
                if (ssh.user) |user| {
                    try stringify.objectField("user");
                    try stringify.write(user);
                }
                try stringify.objectField("port");
                try stringify.write(ssh.port);
                try stringify.objectField("remote_gateway_port");
                try stringify.write(ssh.remote_gateway_port);
            },
            .direct_https, .connect => |endpoint| {
                try stringify.objectField("kind");
                try stringify.write(if (profile.transport == .direct_https) "direct_https" else "connect");
                if (endpoint.https_url) |value| {
                    try stringify.objectField("https_url");
                    try stringify.write(value);
                }
                if (endpoint.wss_url) |value| {
                    try stringify.objectField("wss_url");
                    try stringify.write(value);
                }
                if (endpoint.spki_sha256) |value| {
                    try stringify.objectField("spki_sha256");
                    try stringify.write(value);
                }
            },
        }
        try stringify.endObject();
        try stringify.objectField("access");
        try stringify.beginObject();
        try stringify.objectField("method");
        switch (profile.access) {
            .admin_token => try stringify.write("admin"),
            .paired_device => |device| {
                try stringify.write("paired_device");
                if (device.device_id) |value| {
                    try stringify.objectField("device_id");
                    try stringify.write(value);
                }
                if (device.credential_ref) |value| {
                    try stringify.objectField("credential_ref");
                    try stringify.write(value);
                }
            },
            .connect => |link| {
                try stringify.write("connect");
                try stringify.objectField("control_plane_url");
                try stringify.write(link.control_plane_url);
                if (link.link_id) |value| {
                    try stringify.objectField("link_id");
                    try stringify.write(value);
                }
                if (link.device_id) |value| {
                    try stringify.objectField("device_id");
                    try stringify.write(value);
                }
                if (link.credential_ref) |value| {
                    try stringify.objectField("credential_ref");
                    try stringify.write(value);
                }
            },
        }
        try stringify.endObject();
        try stringify.endObject();
    }
    try stringify.endArray();
    try stringify.endObject();
    return try writer.toOwnedSlice();
}

/// Decodes the strict current schema plus the field-compatible
/// unversioned/version-0 migration shape. Unknown fields are ignored only for
/// version 0, then omitted by `encodeAlloc`.
pub fn decodeAlloc(allocator: std.mem.Allocator, bytes: []const u8) !OwnedProfiles {
    if (bytes.len == 0 or bytes.len > MAX_DOCUMENT_BYTES) return error.InvalidProfileDocument;

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{
        .allocate = .alloc_always,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidProfileDocument,
    };
    defer parsed.deinit();

    if (containsForbiddenField(parsed.value)) return error.SecretFieldForbidden;

    const document = try documentProfiles(parsed.value);
    if (document.version > CURRENT_VERSION) return error.UnsupportedProfileVersion;
    switch (document.version) {
        0 => {},
        1, 2, 3 => try validateVersionedSchema(parsed.value, document.version),
        else => return error.UnsupportedProfileVersion,
    }
    if (document.values.items.len > MAX_PROFILES) return error.TooManyProfiles;

    var profiles: std.ArrayList(Profile) = .empty;
    errdefer {
        for (profiles.items) |*profile| profile.deinit(allocator);
        profiles.deinit(allocator);
    }
    try profiles.ensureTotalCapacity(allocator, document.values.items.len);
    for (document.values.items) |value| {
        var profile = try profileFromValue(allocator, value, document.version);
        const duplicate_id = hasDuplicateProfileId(profiles.items, profile.id);
        const duplicate_local = profile.transport == .local_socket and hasLocalProfile(profiles.items);
        if (duplicate_id or duplicate_local) {
            profile.deinit(allocator);
            return if (duplicate_id) error.DuplicateProfileId else error.DuplicateLocalProfile;
        }
        profiles.appendAssumeCapacity(profile);
    }
    // Apply the same cross-field invariants used before encoding. Individual
    // field parsing alone cannot prove a Direct endpoint is present or that
    // its HTTPS and WebSocket authorities match.
    try validateProfileSlice(profiles.items);
    return .{ .items = try profiles.toOwnedSlice(allocator) };
}

/// Returns a bounded diagnostic message that never includes source JSON or
/// credential values from a rejected document.
pub fn redactedErrorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.SecretFieldForbidden => "runtime profile contains forbidden secret material (<redacted>)",
        error.UnknownProfileField => "runtime profile contains unsupported fields (<redacted>)",
        error.UnsupportedProfileVersion => "runtime profile version is not supported",
        error.TooManyProfiles => "runtime profile list exceeds the supported limit",
        else => "runtime profile document is invalid",
    };
}

const DocumentProfiles = struct {
    version: u8,
    values: std.json.Array,
};

fn documentProfiles(root: std.json.Value) !DocumentProfiles {
    return switch (root) {
        // Bare arrays and objects without a version predate schema versioning;
        // keep treating both as v0 migration input for installed users.
        .array => |values| .{ .version = 0, .values = values },
        .object => |object| blk: {
            const version = if (object.get("version")) |value| try parseVersion(value) else 0;
            const profiles = object.get("profiles") orelse return error.InvalidProfileDocument;
            if (profiles != .array) return error.InvalidProfileDocument;
            break :blk .{ .version = version, .values = profiles.array };
        },
        else => error.InvalidProfileDocument,
    };
}

fn parseVersion(value: std.json.Value) !u8 {
    if (value != .integer or value.integer < 0 or value.integer > std.math.maxInt(u8)) {
        return error.InvalidProfileDocument;
    }
    return @intCast(value.integer);
}

fn validateVersionedSchema(root: std.json.Value, version: u8) !void {
    if (root != .object) return error.InvalidProfileDocument;
    try validateAllowedFields(&root.object, &VERSION_ONE_DOCUMENT_FIELDS);

    const profiles_value = root.object.get("profiles") orelse return error.InvalidProfileDocument;
    if (profiles_value != .array) return error.InvalidProfileDocument;
    for (profiles_value.array.items) |profile_value| {
        if (profile_value != .object) return error.InvalidProfile;
        try validateAllowedFields(
            &profile_value.object,
            if (version >= 2) &VERSION_TWO_PROFILE_FIELDS else &VERSION_ONE_PROFILE_FIELDS,
        );

        const transport_value = profile_value.object.get("transport") orelse return error.InvalidProfile;
        if (transport_value != .object) return error.InvalidProfile;
        const kind = try requiredString(&transport_value.object, "kind");
        if (std.mem.eql(u8, kind, "local_socket")) {
            try validateAllowedFields(
                &transport_value.object,
                &VERSION_ONE_LOCAL_TRANSPORT_FIELDS,
            );
        } else if (std.mem.eql(u8, kind, "ssh_tunnel")) {
            try validateAllowedFields(
                &transport_value.object,
                &VERSION_ONE_SSH_TRANSPORT_FIELDS,
            );
        } else if (version >= 2 and std.mem.eql(u8, kind, "connect")) {
            try validateAllowedFields(
                &transport_value.object,
                &VERSION_TWO_CONNECT_TRANSPORT_FIELDS,
            );
        } else if (version >= 3 and std.mem.eql(u8, kind, "direct_https")) {
            try validateAllowedFields(&transport_value.object, &VERSION_THREE_DIRECT_TRANSPORT_FIELDS);
        } else {
            return error.UnsupportedProfileTransport;
        }

        if (profile_value.object.get("access")) |access_value| {
            if (access_value != .object) return error.InvalidProfile;
            const method = try requiredString(&access_value.object, "method");
            if (std.mem.eql(u8, method, "admin")) {
                try validateAllowedFields(&access_value.object, &ACCESS_ADMIN_TOKEN_FIELDS);
            } else if (std.mem.eql(u8, method, "paired_device")) {
                try validateAllowedFields(&access_value.object, &ACCESS_PAIRED_DEVICE_FIELDS);
            } else if (std.mem.eql(u8, method, "connect")) {
                try validateAllowedFields(&access_value.object, &ACCESS_CONNECT_FIELDS);
            } else {
                return error.UnsupportedProfileAccess;
            }
        }
    }
}

fn validateAllowedFields(
    object: *const std.json.ObjectMap,
    allowed_fields: []const []const u8,
) !void {
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        for (allowed_fields) |allowed| {
            if (std.mem.eql(u8, entry.key_ptr.*, allowed)) break;
        } else return error.UnknownProfileField;
    }
}

fn profileFromValue(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    version: u8,
) !Profile {
    if (value != .object) return error.InvalidProfile;
    const object = &value.object;
    const id = try requiredString(object, "id");
    if (!validProfileId(id)) return error.InvalidProfileId;
    const label = try requiredString(object, "label");
    const expected_runtime_id = try optionalString(object, "expected_runtime_id");
    const expected_instance_id = try optionalString(object, "expected_instance_id");
    if (expected_runtime_id == null and expected_instance_id != null) {
        return error.InvalidExpectedIdentityPair;
    }

    const transport_object = if (object.get("transport")) |transport_value| blk: {
        if (transport_value != .object) return error.InvalidProfile;
        break :blk transport_value.object;
    } else if (version == 0)
        object.*
    else
        return error.InvalidProfile;
    const kind = try requiredString(&transport_object, "kind");

    const owned_id = try allocator.dupe(u8, id);
    errdefer allocator.free(owned_id);
    const owned_label = try sanitizedLabelAlloc(allocator, label);
    errdefer allocator.free(owned_label);
    const owned_runtime_id = try ownedExpectedRuntimeIdAlloc(allocator, expected_runtime_id);
    errdefer if (owned_runtime_id) |runtime_id| allocator.free(runtime_id);
    const owned_instance_id = try ownedExpectedInstanceIdAlloc(allocator, expected_instance_id);
    errdefer if (owned_instance_id) |instance_id| allocator.free(instance_id);
    var owned_access = try accessFromValue(allocator, object, version);
    errdefer owned_access.deinit(allocator);

    if (std.mem.eql(u8, kind, "local_socket") or
        (version == 0 and std.mem.eql(u8, kind, "local")))
    {
        if (owned_access != .admin_token) return error.InvalidProfile;
        return .{
            .id = owned_id,
            .label = owned_label,
            .expected_runtime_id = owned_runtime_id,
            .expected_instance_id = owned_instance_id,
            .transport = .local_socket,
            .access = owned_access,
        };
    }
    if (version >= 2 and (std.mem.eql(u8, kind, "connect") or
        (version >= 3 and std.mem.eql(u8, kind, "direct_https"))))
    {
        const is_connect = std.mem.eql(u8, kind, "connect");
        if ((is_connect and owned_access != .connect) or (!is_connect and owned_access == .connect)) return error.InvalidProfile;
        var endpoint: ConnectTransport = .{};
        errdefer endpoint.deinit(allocator);
        if (try optionalString(&transport_object, "https_url")) |raw| {
            endpoint.https_url = try sanitizedRuntimeHttpsOriginAlloc(allocator, raw);
        }
        if (try optionalString(&transport_object, "wss_url")) |raw| {
            try validateRuntimeWssUrl(raw);
            endpoint.wss_url = try allocator.dupe(u8, raw);
        }
        if (try optionalString(&transport_object, "spki_sha256")) |raw| {
            try validateSpkiSha256(raw);
            endpoint.spki_sha256 = try allocator.dupe(u8, raw);
        }
        return .{
            .id = owned_id,
            .label = owned_label,
            .expected_runtime_id = owned_runtime_id,
            .expected_instance_id = owned_instance_id,
            .transport = if (is_connect) .{ .connect = endpoint } else .{ .direct_https = endpoint },
            .access = owned_access,
        };
    }
    if (!std.mem.eql(u8, kind, "ssh_tunnel") and
        !(version == 0 and std.mem.eql(u8, kind, "ssh")))
    {
        return error.UnsupportedProfileTransport;
    }
    if (owned_access == .connect) return error.InvalidProfile;

    const host = try firstRequiredString(&transport_object, &.{ "host", "hostname" });
    const user = try optionalString(&transport_object, "user");
    const port = try firstPort(&transport_object, &.{ "port", "ssh_port" }, DEFAULT_SSH_PORT);
    const remote_gateway_port = try firstPort(
        &transport_object,
        &.{ "remote_gateway_port", "remote_port" },
        DEFAULT_REMOTE_GATEWAY_PORT,
    );
    return .{
        .id = owned_id,
        .label = owned_label,
        .expected_runtime_id = owned_runtime_id,
        .expected_instance_id = owned_instance_id,
        .transport = .{ .ssh_tunnel = try ownedSshTunnel(allocator, .{
            .host = host,
            .user = user,
            .port = port,
            .remote_gateway_port = remote_gateway_port,
        }) },
        .access = owned_access,
    };
}

/// Decodes the optional non-secret `access` object. Missing means the
/// administrator-token method that every earlier document implied.
fn accessFromValue(allocator: std.mem.Allocator, object: *const std.json.ObjectMap, version: u8) !Access {
    const access_value = object.get("access") orelse return .admin_token;
    if (version < 2 or access_value != .object) return error.InvalidProfile;
    const access_object = &access_value.object;
    const method = try requiredString(access_object, "method");
    if (std.mem.eql(u8, method, "admin")) return .admin_token;
    if (std.mem.eql(u8, method, "paired_device")) {
        const device_id = try optionalString(access_object, "device_id");
        const credential_ref = try optionalString(access_object, "credential_ref");
        // A half-recorded pairing is unusable and must not look paired.
        if ((device_id == null) != (credential_ref == null)) return error.InvalidProfile;
        var device: PairedDevice = .{};
        errdefer device.deinit(allocator);
        if (device_id) |value| {
            try validateDeviceId(value);
            device.device_id = try allocator.dupe(u8, value);
        }
        if (credential_ref) |value| {
            try validateCredentialRef(value);
            device.credential_ref = try allocator.dupe(u8, value);
        }
        return .{ .paired_device = device };
    }
    if (std.mem.eql(u8, method, "connect")) {
        const control_plane_url = try requiredString(access_object, "control_plane_url");
        const owned_url = try sanitizedHttpsUrlAlloc(allocator, control_plane_url);
        errdefer allocator.free(owned_url);
        var link: ConnectLink = .{ .control_plane_url = owned_url };
        if (try optionalString(access_object, "link_id")) |value| {
            try validateLinkId(value);
            link.link_id = try allocator.dupe(u8, value);
        }
        if (try optionalString(access_object, "device_id")) |value| {
            try validateDeviceId(value);
            link.device_id = try allocator.dupe(u8, value);
        }
        if (try optionalString(access_object, "credential_ref")) |value| {
            try validateCredentialRef(value);
            link.credential_ref = try allocator.dupe(u8, value);
        }
        if ((link.device_id == null) != (link.credential_ref == null)) return error.InvalidProfile;
        return .{ .connect = link };
    }
    return error.UnsupportedProfileAccess;
}

/// Device IDs are the runtime-issued 32-character lowercase hex identifiers.
pub fn validateDeviceId(value: []const u8) !void {
    if (!validRuntimeId(value)) return error.InvalidDeviceId;
}

/// Credential references are opaque store keys: printable ASCII without
/// whitespace so they are safe in argv-free store lookups and diagnostics.
pub fn validateCredentialRef(value: []const u8) !void {
    if (value.len == 0 or value.len > MAX_CREDENTIAL_REF_BYTES) return error.InvalidCredentialRef;
    for (value) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and std.mem.indexOfScalar(u8, "._:/-", byte) == null) {
            return error.InvalidCredentialRef;
        }
    }
}

/// Control-plane and runtime HTTPS URLs: scheme-pinned, bounded, and free of
/// whitespace, control bytes, fragments, and embedded credentials.
pub fn validateHttpsUrl(value: []const u8) !void {
    try validateUrlWithScheme(value, "https://");
    const uri = std.Uri.parse(value) catch return error.InvalidUrl;
    if (!std.mem.eql(u8, uri.scheme, "https") or uri.host == null or uri.host.?.isEmpty() or
        uri.user != null or uri.password != null or uri.query != null or uri.fragment != null)
    {
        return error.InvalidUrl;
    }
}

pub fn validateWssUrl(value: []const u8) !void {
    try validateUrlWithScheme(value, "wss://");
    const uri = std.Uri.parse(value) catch return error.InvalidUrl;
    if (!std.mem.eql(u8, uri.scheme, "wss") or uri.host == null or uri.host.?.isEmpty() or
        uri.user != null or uri.password != null or uri.query != null or uri.fragment != null)
    {
        return error.InvalidUrl;
    }
}

/// Runtime HTTPS endpoints are origins, not general base URLs. A root slash
/// is accepted as input only so it can be normalized away before persistence.
pub fn validateRuntimeHttpsOrigin(value: []const u8) !void {
    if (!std.mem.startsWith(u8, value, "https://")) return error.InvalidUrl;
    try validateHttpsUrl(value);
    const uri = std.Uri.parse(value) catch return error.InvalidUrl;
    if (uri.query != null or uri.fragment != null or uri.user != null or uri.password != null) return error.InvalidUrl;
    const path = uriComponentSlice(uri.path);
    if (path.len != 0 and !std.mem.eql(u8, path, "/")) return error.InvalidUrl;
}

/// Runtime descriptors expose one WebSocket endpoint at `/ws` on the same
/// authority as the HTTPS origin.
pub fn validateRuntimeWssUrl(value: []const u8) !void {
    if (!std.mem.startsWith(u8, value, "wss://")) return error.InvalidUrl;
    try validateWssUrl(value);
    const uri = std.Uri.parse(value) catch return error.InvalidUrl;
    if (uri.query != null or uri.fragment != null or uri.user != null or uri.password != null) return error.InvalidUrl;
    if (!std.mem.eql(u8, uriComponentSlice(uri.path), "/ws")) return error.InvalidUrl;
}

pub fn validateRuntimeEndpointPair(https_origin: []const u8, wss_url: []const u8) !void {
    try validateRuntimeHttpsOrigin(https_origin);
    try validateRuntimeWssUrl(wss_url);
    const https_authority = urlAuthority(https_origin, "https://") orelse return error.InvalidUrl;
    const wss_authority = urlAuthority(wss_url, "wss://") orelse return error.InvalidUrl;
    if (!std.ascii.eqlIgnoreCase(https_authority, wss_authority)) return error.InvalidUrl;
}

fn uriComponentSlice(component: std.Uri.Component) []const u8 {
    return switch (component) {
        .raw => |value| value,
        .percent_encoded => |value| value,
    };
}

fn urlAuthority(value: []const u8, scheme: []const u8) ?[]const u8 {
    if (!std.ascii.startsWithIgnoreCase(value, scheme)) return null;
    const end = std.mem.findAnyPos(u8, value, scheme.len, "/?#") orelse value.len;
    return value[scheme.len..end];
}

fn validateUrlWithScheme(value: []const u8, scheme: []const u8) !void {
    if (value.len <= scheme.len or value.len > MAX_URL_BYTES) return error.InvalidUrl;
    if (!std.ascii.startsWithIgnoreCase(value, scheme)) return error.InvalidUrl;
    const authority_end = std.mem.indexOfScalarPos(u8, value, scheme.len, '/') orelse value.len;
    const authority = value[scheme.len..authority_end];
    if (authority.len == 0 or std.mem.indexOfScalar(u8, authority, '@') != null) return error.InvalidUrl;
    for (value) |byte| {
        if (byte <= 0x20 or byte >= 0x7f or byte == '#' or byte == '"' or byte == '\'' or byte == '\\') {
            return error.InvalidUrl;
        }
    }
}

pub fn validateSpkiSha256(value: []const u8) !void {
    if (value.len != SPKI_SHA256_BASE64URL_BYTES) return error.InvalidSpkiSha256;
    for (value) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_') return error.InvalidSpkiSha256;
    }
}

pub fn validateLinkId(value: []const u8) !void {
    if (!std.mem.startsWith(u8, value, "lnk_") or !validRuntimeId(value["lnk_".len..])) {
        return error.InvalidLinkId;
    }
}

pub fn sanitizedHttpsUrlAlloc(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var trimmed = std.mem.trim(u8, value, &std.ascii.whitespace);
    // A trailing slash would otherwise produce `//.well-known` on discovery.
    while (trimmed.len > "https://".len and trimmed[trimmed.len - 1] == '/') trimmed = trimmed[0 .. trimmed.len - 1];
    try validateHttpsUrl(trimmed);
    return allocator.dupe(u8, trimmed);
}

pub fn sanitizedRuntimeHttpsOriginAlloc(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var trimmed = std.mem.trim(u8, value, &std.ascii.whitespace);
    while (trimmed.len > "https://".len and trimmed[trimmed.len - 1] == '/') trimmed = trimmed[0 .. trimmed.len - 1];
    try validateRuntimeHttpsOrigin(trimmed);
    return allocator.dupe(u8, trimmed);
}

/// Field-level validators shared with UI forms so inline feedback matches
/// exactly what the store would reject. Inputs are trimmed like the setters.
pub fn validateLabel(value: []const u8) !void {
    const trimmed = std.mem.trim(u8, value, &std.ascii.whitespace);
    if (trimmed.len == 0 or trimmed.len > MAX_LABEL_BYTES or !std.unicode.utf8ValidateSlice(trimmed)) {
        return error.InvalidProfileLabel;
    }
    for (trimmed) |byte| if (std.ascii.isControl(byte)) return error.InvalidProfileLabel;
}

pub fn validateSshHost(value: []const u8) !void {
    return validateHost(std.mem.trim(u8, value, &std.ascii.whitespace));
}

/// An empty user is valid and means "use SSH config / current user".
pub fn validateSshUser(value: []const u8) !void {
    const trimmed = std.mem.trim(u8, value, &std.ascii.whitespace);
    if (trimmed.len == 0) return;
    return validateUser(trimmed);
}

pub fn validatePort(port: u16) !void {
    if (port == 0) return error.InvalidPort;
}

fn ownedSshTunnel(allocator: std.mem.Allocator, input: SshTunnelInput) !SshTunnel {
    if (input.port == 0 or input.remote_gateway_port == 0) return error.InvalidPort;

    const host = try sanitizedHostAlloc(allocator, input.host);
    errdefer allocator.free(host);
    const user = if (input.user) |value| try sanitizedUserAlloc(allocator, value) else null;
    errdefer if (user) |value| allocator.free(value);
    return .{
        .host = host,
        .user = user,
        .port = input.port,
        .remote_gateway_port = input.remote_gateway_port,
    };
}

fn ownedExpectedRuntimeIdAlloc(
    allocator: std.mem.Allocator,
    value: ?[]const u8,
) !?[]u8 {
    const runtime_id = value orelse return null;
    if (!validRuntimeId(runtime_id)) return error.InvalidExpectedRuntimeId;
    return try allocator.dupe(u8, runtime_id);
}

fn ownedExpectedInstanceIdAlloc(
    allocator: std.mem.Allocator,
    value: ?[]const u8,
) !?[]u8 {
    const instance_id = value orelse return null;
    if (!validRuntimeId(instance_id)) return error.InvalidExpectedInstanceId;
    return try allocator.dupe(u8, instance_id);
}

fn sanitizedLabelAlloc(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    try validateLabel(value);
    return allocator.dupe(u8, std.mem.trim(u8, value, &std.ascii.whitespace));
}

fn sanitizedHostAlloc(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, value, &std.ascii.whitespace);
    try validateHost(trimmed);
    return allocator.dupe(u8, trimmed);
}

fn validateHost(value: []const u8) !void {
    if (value.len == 0 or value.len > MAX_HOST_BYTES or value[0] == '-') {
        return error.InvalidSshHost;
    }
    for (value) |byte| {
        // SSH config may expand %h inside ProxyCommand/LocalCommand, so even a
        // direct argv host must not contain shell syntax. This conservative
        // ASCII set covers DNS, numeric IPv4/IPv6, and common aliases. Percent
        // is excluded because OpenSSH itself treats it as a config token sigil.
        if (!std.ascii.isAlphanumeric(byte) and
            std.mem.indexOfScalar(u8, "._-:[]", byte) == null)
        {
            return error.InvalidSshHost;
        }
    }
}

fn sanitizedUserAlloc(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, value, &std.ascii.whitespace);
    try validateUser(trimmed);
    return allocator.dupe(u8, trimmed);
}

fn validateUser(value: []const u8) !void {
    if (value.len == 0 or value.len > MAX_USER_BYTES or value[0] == '-') return error.InvalidSshUser;
    for (value) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-' and byte != '.') {
            return error.InvalidSshUser;
        }
    }
}

fn validateProfileSlice(profiles: []const Profile) !void {
    if (profiles.len > MAX_PROFILES) return error.TooManyProfiles;
    var local_seen = false;
    for (profiles, 0..) |profile, index| {
        if (!validProfileId(profile.id)) return error.InvalidProfileId;
        try validateCanonicalLabel(profile.label);
        if (profile.expected_runtime_id) |runtime_id| {
            if (!validRuntimeId(runtime_id)) return error.InvalidExpectedRuntimeId;
        }
        if (profile.expected_instance_id) |instance_id| {
            if (profile.expected_runtime_id == null) return error.InvalidExpectedIdentityPair;
            if (!validRuntimeId(instance_id)) return error.InvalidExpectedInstanceId;
        }
        for (profiles[0..index]) |previous| {
            if (std.mem.eql(u8, previous.id, profile.id)) return error.DuplicateProfileId;
        }
        switch (profile.transport) {
            .local_socket => {
                if (local_seen) return error.DuplicateLocalProfile;
                local_seen = true;
                if (profile.access != .admin_token) return error.InvalidProfile;
            },
            .ssh_tunnel => |ssh| {
                try validateCanonicalSsh(ssh);
                if (profile.access == .connect) return error.InvalidProfile;
            },
            .direct_https => |endpoint| {
                if (profile.access == .connect) return error.InvalidProfile;
                const https_url = endpoint.https_url orelse return error.InvalidProfile;
                try validateRuntimeHttpsOrigin(https_url);
                if (endpoint.wss_url) |value| try validateRuntimeEndpointPair(https_url, value);
                if (endpoint.spki_sha256) |value| try validateSpkiSha256(value);
            },
            .connect => |endpoint| {
                if (profile.access != .connect) return error.InvalidProfile;
                if (endpoint.https_url) |value| try validateRuntimeHttpsOrigin(value);
                if (endpoint.wss_url) |value| {
                    const https_url = endpoint.https_url orelse return error.InvalidProfile;
                    try validateRuntimeEndpointPair(https_url, value);
                }
                if (endpoint.spki_sha256) |value| try validateSpkiSha256(value);
            },
        }
        switch (profile.access) {
            .admin_token => {},
            .paired_device => |device| {
                if ((device.device_id == null) != (device.credential_ref == null)) return error.InvalidProfile;
                if (device.device_id) |value| try validateDeviceId(value);
                if (device.credential_ref) |value| try validateCredentialRef(value);
            },
            .connect => |link| {
                try validateHttpsUrl(link.control_plane_url);
                if (link.link_id) |value| try validateLinkId(value);
                if ((link.device_id == null) != (link.credential_ref == null)) return error.InvalidProfile;
                if (link.device_id) |value| try validateDeviceId(value);
                if (link.credential_ref) |value| try validateCredentialRef(value);
            },
        }
    }
}

fn validateCanonicalLabel(value: []const u8) !void {
    const trimmed = std.mem.trim(u8, value, &std.ascii.whitespace);
    if (trimmed.len != value.len or value.len == 0 or value.len > MAX_LABEL_BYTES or
        !std.unicode.utf8ValidateSlice(value))
    {
        return error.InvalidProfileLabel;
    }
    for (value) |byte| if (std.ascii.isControl(byte)) return error.InvalidProfileLabel;
}

fn validateCanonicalSsh(ssh: SshTunnel) !void {
    if (ssh.port == 0 or ssh.remote_gateway_port == 0) return error.InvalidPort;
    if (std.mem.trim(u8, ssh.host, &std.ascii.whitespace).len != ssh.host.len) return error.InvalidSshHost;
    try validateHost(ssh.host);
    if (ssh.user) |user| {
        if (std.mem.trim(u8, user, &std.ascii.whitespace).len != user.len) return error.InvalidSshUser;
        try validateUser(user);
    }
}

fn validProfileId(value: []const u8) bool {
    if (value.len != PROFILE_ID_PREFIX.len + PROFILE_ID_RANDOM_BYTES * 2 or
        !std.mem.startsWith(u8, value, PROFILE_ID_PREFIX))
    {
        return false;
    }
    for (value[PROFILE_ID_PREFIX.len..]) |byte| {
        if (!std.ascii.isHex(byte) or std.ascii.isUpper(byte)) return false;
    }
    return true;
}

fn validRuntimeId(value: []const u8) bool {
    if (value.len != RUNTIME_ID_BYTES * 2) return false;
    for (value) |byte| {
        if (!std.ascii.isHex(byte) or std.ascii.isUpper(byte)) return false;
    }
    return true;
}

fn requiredString(object: *const std.json.ObjectMap, key: []const u8) ![]const u8 {
    const value = object.get(key) orelse return error.InvalidProfile;
    if (value != .string) return error.InvalidProfile;
    return value.string;
}

fn firstRequiredString(object: *const std.json.ObjectMap, keys: []const []const u8) ![]const u8 {
    for (keys) |key| {
        if (object.get(key)) |value| {
            if (value != .string) return error.InvalidProfile;
            return value.string;
        }
    }
    return error.InvalidProfile;
}

fn optionalString(object: *const std.json.ObjectMap, key: []const u8) !?[]const u8 {
    const value = object.get(key) orelse return null;
    if (value == .null) return null;
    if (value != .string) return error.InvalidProfile;
    return value.string;
}

fn firstPort(object: *const std.json.ObjectMap, keys: []const []const u8, default: u16) !u16 {
    for (keys) |key| {
        if (object.get(key)) |value| {
            if (value != .integer or value.integer <= 0 or value.integer > std.math.maxInt(u16)) {
                return error.InvalidPort;
            }
            return @intCast(value.integer);
        }
    }
    return default;
}

fn hasDuplicateProfileId(profiles: []const Profile, id: []const u8) bool {
    for (profiles) |profile| if (std.mem.eql(u8, profile.id, id)) return true;
    return false;
}

fn hasLocalProfile(profiles: []const Profile) bool {
    for (profiles) |profile| if (profile.transport == .local_socket) return true;
    return false;
}

fn containsForbiddenField(value: std.json.Value) bool {
    switch (value) {
        .array => |array| for (array.items) |item| {
            if (containsForbiddenField(item)) return true;
        },
        .object => |object| {
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                if (forbiddenFieldName(entry.key_ptr.*) or containsForbiddenField(entry.value_ptr.*)) {
                    return true;
                }
            }
        },
        else => {},
    }
    return false;
}

fn forbiddenFieldName(key: []const u8) bool {
    const forbidden = [_][]const u8{
        "token",
        "gatewaytoken",
        "providertoken",
        "accesstoken",
        "refreshtoken",
        "bearer",
        "bearertoken",
        "password",
        "passphrase",
        "privatekey",
        "privatekeycontents",
        "secret",
        "apikey",
        "authorization",
        "cookie",
        "sessioncookie",
    };
    for (forbidden) |candidate| {
        if (normalizedKeyEquals(key, candidate)) return true;
    }
    return false;
}

fn normalizedKeyEquals(key: []const u8, normalized: []const u8) bool {
    var index: usize = 0;
    for (key) |byte| {
        if (!std.ascii.isAlphanumeric(byte)) continue;
        if (index >= normalized.len or std.ascii.toLower(byte) != normalized[index]) return false;
        index += 1;
    }
    return index == normalized.len;
}

test "generated profile ids are opaque lowercase random values" {
    const allocator = std.testing.allocator;
    const first = try generateIdAlloc(allocator, std.testing.io);
    defer allocator.free(first);
    const second = try generateIdAlloc(allocator, std.testing.io);
    defer allocator.free(second);

    try std.testing.expect(validProfileId(first));
    try std.testing.expect(validProfileId(second));
    try std.testing.expect(!std.mem.eql(u8, first, second));
}

test "owned profiles sanitize fields and round trip stable ids" {
    const allocator = std.testing.allocator;
    var local = try Profile.createLocal(allocator, std.testing.io, "  Local  ", null);
    defer local.deinit(allocator);
    var remote = try Profile.createSshTunnel(
        allocator,
        std.testing.io,
        "  Build VM  ",
        "0123456789abcdef0123456789abcdef",
        .{
            .host = "  devbox.example  ",
            .user = "  verde  ",
            .port = 2202,
            .remote_gateway_port = 7421,
        },
    );
    defer remote.deinit(allocator);
    try remote.setExpectedIdentity(
        allocator,
        "0123456789abcdef0123456789abcdef",
        "00112233445566778899aabbccddeeff",
    );

    const encoded = try encodeAlloc(allocator, &.{ local, remote });
    defer allocator.free(encoded);
    var decoded = try decodeAlloc(allocator, encoded);
    defer decoded.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), decoded.items.len);
    try std.testing.expectEqualStrings(local.id, decoded.items[0].id);
    try std.testing.expectEqualStrings("Local", decoded.items[0].label);
    try std.testing.expectEqualStrings(remote.id, decoded.items[1].id);
    try std.testing.expectEqualStrings("Build VM", decoded.items[1].label);
    try std.testing.expectEqualStrings(
        "0123456789abcdef0123456789abcdef",
        decoded.items[1].expected_runtime_id.?,
    );
    try std.testing.expectEqualStrings(
        "00112233445566778899aabbccddeeff",
        decoded.items[1].expected_instance_id.?,
    );
    const ssh = decoded.items[1].transport.ssh_tunnel;
    try std.testing.expectEqualStrings("devbox.example", ssh.host);
    try std.testing.expectEqualStrings("verde", ssh.user.?);
    try std.testing.expectEqual(@as(u16, 2202), ssh.port);
    try std.testing.expectEqual(@as(u16, 7421), ssh.remote_gateway_port);

    try std.testing.expectError(
        error.InvalidExpectedRuntimeId,
        remote.setExpectedRuntimeId(allocator, "invalid"),
    );
    try std.testing.expectEqualStrings(
        "0123456789abcdef0123456789abcdef",
        remote.expected_runtime_id.?,
    );
    try std.testing.expectError(
        error.InvalidExpectedInstanceId,
        remote.setExpectedIdentity(
            allocator,
            "0123456789abcdef0123456789abcdef",
            "invalid",
        ),
    );
    try std.testing.expectEqualStrings(
        "00112233445566778899aabbccddeeff",
        remote.expected_instance_id.?,
    );
    try remote.setExpectedIdentity(allocator, null, null);
    try std.testing.expect(remote.expected_runtime_id == null);
    try std.testing.expect(remote.expected_instance_id == null);
}

test "legacy documents and unknown fields decode without being persisted" {
    const allocator = std.testing.allocator;
    const legacy =
        \\{
        \\  "version": 0,
        \\  "future_document_field": {"mode":"later"},
        \\  "profiles": [{
        \\    "id": "profile-0123456789abcdef0123456789abcdef",
        \\    "label": "  Lab VM  ",
        \\    "kind": "ssh",
        \\    "hostname": "  lab.example  ",
        \\    "user": "  alice  ",
        \\    "ssh_port": 2222,
        \\    "remote_port": 7440,
        \\    "credential_ref": "os-keyring://verde/lab",
        \\    "future_profile_field": {"client_secret":"sentinel-legacy"}
        \\  }]
        \\}
    ;
    var decoded = try decodeAlloc(allocator, legacy);
    defer decoded.deinit(allocator);
    const ssh = decoded.items[0].transport.ssh_tunnel;
    try std.testing.expectEqualStrings("Lab VM", decoded.items[0].label);
    try std.testing.expectEqualStrings("lab.example", ssh.host);
    try std.testing.expectEqual(@as(u16, 2222), ssh.port);
    try std.testing.expectEqual(@as(u16, 7440), ssh.remote_gateway_port);

    const canonical = try encodeAlloc(allocator, decoded.items);
    defer allocator.free(canonical);
    try std.testing.expect(std.mem.indexOf(u8, canonical, "future_document_field") == null);
    try std.testing.expect(std.mem.indexOf(u8, canonical, "future_profile_field") == null);
    try std.testing.expect(std.mem.indexOf(u8, canonical, "credential_ref") == null);
    try std.testing.expect(std.mem.indexOf(u8, canonical, "sentinel-legacy") == null);
    try std.testing.expect(std.mem.indexOf(u8, canonical, "\"version\": 3") != null);
}

test "unversioned objects and arrays retain version zero migration behavior" {
    const payloads = [_][]const u8{
        \\{"future_document_field":{"client_secret":"sentinel-document"},"profiles":[{"id":"profile-0123456789abcdef0123456789abcdef","label":"VM","kind":"ssh","hostname":"vm","future_profile_field":{"client_secret":"sentinel-profile"}}]}
        ,
        \\[{"id":"profile-0123456789abcdef0123456789abcdef","label":"Local","kind":"local","future_profile_field":{"client_secret":"sentinel-array"}}]
        ,
    };
    for (payloads) |payload| {
        var decoded = try decodeAlloc(std.testing.allocator, payload);
        defer decoded.deinit(std.testing.allocator);
        const canonical = try encodeAlloc(std.testing.allocator, decoded.items);
        defer std.testing.allocator.free(canonical);
        try std.testing.expect(std.mem.indexOf(u8, canonical, "future_") == null);
        try std.testing.expect(std.mem.indexOf(u8, canonical, "sentinel-") == null);
        try std.testing.expect(std.mem.indexOf(u8, canonical, "\"version\": 3") != null);
    }
}

test "version one rejects unknown fields at every schema level" {
    const payloads = [_][]const u8{
        \\{"version":1,"profiles":[],"future_document_field":{"client_secret":"sentinel-document"}}
        ,
        \\{"version":1,"profiles":[{"id":"profile-0123456789abcdef0123456789abcdef","label":"VM","transport":{"kind":"local_socket"},"future_profile_field":{"client_secret":"sentinel-profile"}}]}
        ,
        \\{"version":1,"profiles":[{"id":"profile-0123456789abcdef0123456789abcdef","label":"VM","transport":{"kind":"ssh_tunnel","host":"vm","future_transport_field":{"client_secret":"sentinel-transport"}}}]}
        ,
        \\{"version":1,"profiles":[{"id":"profile-0123456789abcdef0123456789abcdef","label":"VM","transport":{"kind":"local_socket","host":"must-not-be-accepted-for-local"}}]}
        ,
    };
    for (payloads) |payload| {
        try std.testing.expectError(
            error.UnknownProfileField,
            decodeAlloc(std.testing.allocator, payload),
        );
    }

    const message = redactedErrorMessage(error.UnknownProfileField);
    try std.testing.expect(std.mem.indexOf(u8, message, "sentinel") == null);
    try std.testing.expect(std.mem.indexOf(u8, message, "client_secret") == null);
}

test "secret-bearing fields are rejected and diagnostics are redacted" {
    const payloads = [_][]const u8{
        \\{"version":1,"token":"sentinel-token","profiles":[]}
        ,
        \\{"version":1,"profiles":[{"id":"profile-0123456789abcdef0123456789abcdef","label":"VM","transport":{"kind":"ssh_tunnel","host":"vm","password":"sentinel-password"}}]}
        ,
        \\{"version":1,"profiles":[{"id":"profile-0123456789abcdef0123456789abcdef","label":"VM","transport":{"kind":"ssh_tunnel","host":"vm","future":{"private-key-contents":"sentinel-private-key"}}}]}
        ,
        \\{"version":1,"profiles":[{"id":"profile-0123456789abcdef0123456789abcdef","label":"VM","transport":{"kind":"ssh_tunnel","host":"vm","Authorization":"Bearer sentinel-authorization"}}]}
        ,
    };
    for (payloads) |payload| {
        try std.testing.expectError(error.SecretFieldForbidden, decodeAlloc(std.testing.allocator, payload));
    }

    const message = redactedErrorMessage(error.SecretFieldForbidden);
    try std.testing.expect(std.mem.indexOf(u8, message, "<redacted>") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, "sentinel") == null);
}

test "profile validation rejects malformed identities endpoints and duplicates" {
    const invalid_payloads = [_][]const u8{
        \\{"version":1,"profiles":[{"id":"profile-ABCDEF","label":"VM","transport":{"kind":"local_socket"}}]}
        ,
        \\{"version":1,"profiles":[{"id":"profile-0123456789abcdef0123456789abcdef","label":" ","transport":{"kind":"local_socket"}}]}
        ,
        \\{"version":1,"profiles":[{"id":"profile-0123456789abcdef0123456789abcdef","label":"VM","transport":{"kind":"ssh_tunnel","host":"bad host"}}]}
        ,
        \\{"version":1,"profiles":[{"id":"profile-0123456789abcdef0123456789abcdef","label":"VM","transport":{"kind":"ssh_tunnel","host":"-oProxyCommand"}}]}
        ,
        \\{"version":1,"profiles":[{"id":"profile-0123456789abcdef0123456789abcdef","label":"VM","transport":{"kind":"ssh_tunnel","host":"vm;touch-pwn"}}]}
        ,
        \\{"version":1,"profiles":[{"id":"profile-0123456789abcdef0123456789abcdef","label":"VM","transport":{"kind":"ssh_tunnel","host":"vm$(touch-pwn)"}}]}
        ,
        \\{"version":1,"profiles":[{"id":"profile-0123456789abcdef0123456789abcdef","label":"VM","transport":{"kind":"ssh_tunnel","host":"vm`touch-pwn`"}}]}
        ,
        \\{"version":1,"profiles":[{"id":"profile-0123456789abcdef0123456789abcdef","label":"VM","transport":{"kind":"ssh_tunnel","host":"%h"}}]}
        ,
        \\{"version":1,"profiles":[{"id":"profile-0123456789abcdef0123456789abcdef","label":"VM","transport":{"kind":"ssh_tunnel","host":"vm%r"}}]}
        ,
        \\{"version":1,"profiles":[{"id":"profile-0123456789abcdef0123456789abcdef","label":"VM","transport":{"kind":"ssh_tunnel","host":"vm%p"}}]}
        ,
        \\{"version":1,"profiles":[{"id":"profile-0123456789abcdef0123456789abcdef","label":"VM","transport":{"kind":"ssh_tunnel","host":"%"}}]}
        ,
        \\{"version":1,"profiles":[{"id":"profile-0123456789abcdef0123456789abcdef","label":"VM","transport":{"kind":"ssh_tunnel","host":"vm","user":"-oProxyCommand"}}]}
        ,
        \\{"version":1,"profiles":[{"id":"profile-0123456789abcdef0123456789abcdef","label":"VM","transport":{"kind":"ssh_tunnel","host":"vm","port":0}}]}
        ,
        \\{"version":1,"profiles":[{"id":"profile-0123456789abcdef0123456789abcdef","label":"VM","expected_runtime_id":"NOT-A-RUNTIME-ID","transport":{"kind":"ssh_tunnel","host":"vm"}}]}
        ,
        \\{"version":1,"profiles":[{"id":"profile-0123456789abcdef0123456789abcdef","label":"VM","expected_instance_id":"00112233445566778899aabbccddeeff","transport":{"kind":"ssh_tunnel","host":"vm"}}]}
        ,
        \\{"version":1,"profiles":[{"id":"profile-0123456789abcdef0123456789abcdef","label":"VM","expected_runtime_id":"0123456789abcdef0123456789abcdef","expected_instance_id":"BAD-INSTANCE","transport":{"kind":"ssh_tunnel","host":"vm"}}]}
        ,
        \\{"version":3,"profiles":[{"id":"profile-0123456789abcdef0123456789abcdef","label":"Direct","transport":{"kind":"direct_https"},"access":{"method":"paired_device"}}]}
        ,
        \\{"version":3,"profiles":[{"id":"profile-0123456789abcdef0123456789abcdef","label":"Direct","transport":{"kind":"direct_https","https_url":"https://runtime.example","wss_url":"wss://other.example/ws"},"access":{"method":"paired_device"}}]}
        ,
        \\{"version":1,"profiles":[{"id":"profile-0123456789abcdef0123456789abcdef","label":"One","transport":{"kind":"local_socket"}},{"id":"profile-0123456789abcdef0123456789abcdef","label":"Two","transport":{"kind":"ssh_tunnel","host":"vm"}}]}
        ,
    };
    for (invalid_payloads) |payload| {
        try std.testing.expectError(error.InvalidProfileDocument, normalizeValidationError(payload));
    }
    try std.testing.expectError(
        error.UnsupportedProfileVersion,
        decodeAlloc(std.testing.allocator, "{\"version\":4,\"profiles\":[]}"),
    );
}

test "current version persists paired-device and connect access without secrets" {
    const allocator = std.testing.allocator;
    var paired = try Profile.createPairedSshTunnel(allocator, std.testing.io, "Paired VM", .{ .host = "vm.example" });
    defer paired.deinit(allocator);
    try std.testing.expect(!paired.access.paired_device.isPaired());
    try paired.setPairedDevice(
        allocator,
        "0123456789abcdef0123456789abcdef",
        "verde-runtime/profile-0123456789abcdef0123456789abcdef/device",
    );
    try paired.setExpectedIdentity(allocator, "0123456789abcdef0123456789abcdef", "00112233445566778899aabbccddeeff");
    var linked = try Profile.createConnect(allocator, std.testing.io, "Connect", " https://connect.example/ ");
    defer linked.deinit(allocator);
    try std.testing.expectEqualStrings("https://connect.example", linked.access.connect.control_plane_url);
    try linked.setConnectEndpoint(
        allocator,
        "https://rt.example:8443",
        "wss://rt.example:8443/ws",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "lnk_0123456789abcdef0123456789abcdef",
    );
    try linked.setExpectedIdentity(allocator, "fedcba9876543210fedcba9876543210", "00112233445566778899aabbccddeeff");
    try linked.setConnectRuntimeDevice(
        allocator,
        "89abcdef0123456789abcdef01234567",
        "verde-runtime/profile-fedcba9876543210fedcba9876543210/device",
    );

    const encoded = try encodeAlloc(allocator, &.{ paired, linked });
    defer allocator.free(encoded);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"method\": \"paired_device\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"credential_ref\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"kind\": \"connect\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "device_credential") == null);

    var decoded = try decodeAlloc(allocator, encoded);
    defer decoded.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), decoded.items.len);
    try std.testing.expectEqualStrings("0123456789abcdef0123456789abcdef", decoded.items[0].access.paired_device.device_id.?);
    try std.testing.expectEqualStrings("lnk_0123456789abcdef0123456789abcdef", decoded.items[1].access.connect.link_id.?);
    try std.testing.expectEqualStrings("wss://rt.example:8443/ws", decoded.items[1].transport.connect.wss_url.?);
    try std.testing.expectEqualStrings("89abcdef0123456789abcdef01234567", decoded.items[1].access.connect.device_id.?);
    try std.testing.expectEqualStrings("verde-runtime/profile-fedcba9876543210fedcba9876543210/device", decoded.items[1].access.connect.credential_ref.?);
    try std.testing.expectError(
        error.InvalidDeviceId,
        decoded.items[1].setConnectRuntimeDevice(allocator, "dev_0123456789abcdef0123456789abcdef", "verde-runtime/profile-fedcba9876543210fedcba9876543210/device"),
    );

    // Version 1 readers never accepted access objects or connect transports,
    // and half-recorded pairings are rejected rather than treated as paired.
    const rejected = [_][]const u8{
        \\{"version":1,"profiles":[{"id":"profile-0123456789abcdef0123456789abcdef","label":"VM","transport":{"kind":"ssh_tunnel","host":"vm"},"access":{"method":"admin"}}]}
        ,
        \\{"version":1,"profiles":[{"id":"profile-0123456789abcdef0123456789abcdef","label":"C","transport":{"kind":"connect"}}]}
        ,
        \\{"version":2,"profiles":[{"id":"profile-0123456789abcdef0123456789abcdef","label":"VM","transport":{"kind":"ssh_tunnel","host":"vm"},"access":{"method":"paired_device","device_id":"0123456789abcdef0123456789abcdef"}}]}
        ,
        \\{"version":2,"profiles":[{"id":"profile-0123456789abcdef0123456789abcdef","label":"VM","transport":{"kind":"ssh_tunnel","host":"vm"},"access":{"method":"paired_device","device_credential":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"}}]}
        ,
        \\{"version":2,"profiles":[{"id":"profile-0123456789abcdef0123456789abcdef","label":"C","transport":{"kind":"connect"},"access":{"method":"connect","control_plane_url":"http://plain.example"}}]}
        ,
        \\{"version":2,"profiles":[{"id":"profile-0123456789abcdef0123456789abcdef","label":"L","transport":{"kind":"local_socket"},"access":{"method":"paired_device"}}]}
        ,
    };
    for (rejected) |payload| {
        try std.testing.expectError(error.InvalidProfileDocument, normalizeValidationError(payload));
    }
}

test "version three direct HTTPS profile round trips without secret material" {
    const allocator = std.testing.allocator;
    var direct = try Profile.createPairedDirect(
        allocator,
        std.testing.io,
        "Tailnet runtime",
        "https://runtime.example/",
        "wss://runtime.example/ws",
    );
    defer direct.deinit(allocator);
    const encoded = try encodeAlloc(allocator, &.{direct});
    defer allocator.free(encoded);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"kind\": \"direct_https\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "pairing_token") == null);
    var decoded = try decodeAlloc(allocator, encoded);
    defer decoded.deinit(allocator);
    try std.testing.expectEqualStrings("https://runtime.example", decoded.items[0].transport.direct_https.https_url.?);
    try std.testing.expect(decoded.items[0].access == .paired_device);
}

test "runtime endpoints are exact origins with a same-authority websocket" {
    try validateRuntimeHttpsOrigin("https://runtime.example:8443");
    try validateRuntimeHttpsOrigin("https://runtime.example:8443/");
    try validateRuntimeEndpointPair("https://runtime.example:8443", "wss://runtime.example:8443/ws");
    try std.testing.expectError(error.InvalidUrl, validateRuntimeHttpsOrigin("https://runtime.example/base"));
    try std.testing.expectError(error.InvalidUrl, validateRuntimeHttpsOrigin("https://runtime.example?tenant=one"));
    try std.testing.expectError(error.InvalidUrl, validateRuntimeHttpsOrigin("https://user@runtime.example"));
    try std.testing.expectError(error.InvalidUrl, validateRuntimeHttpsOrigin("HTTPS://runtime.example"));
    try std.testing.expectError(error.InvalidUrl, validateRuntimeWssUrl("wss://runtime.example/socket"));
    try std.testing.expectError(
        error.InvalidUrl,
        validateRuntimeEndpointPair("https://runtime.example", "wss://other.example/ws"),
    );
}

fn normalizeValidationError(payload: []const u8) !void {
    var decoded = decodeAlloc(std.testing.allocator, payload) catch return error.InvalidProfileDocument;
    decoded.deinit(std.testing.allocator);
}
