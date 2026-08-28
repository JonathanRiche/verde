//! Owned, non-secret connection profiles for desktop-managed Verde runtimes.

const std = @import("std");

pub const CURRENT_VERSION: u8 = 1;
pub const DEFAULT_SSH_PORT: u16 = 22;
pub const DEFAULT_REMOTE_GATEWAY_PORT: u16 = 7420;
pub const MAX_PROFILES: usize = 64;

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
const VERSION_ONE_LOCAL_TRANSPORT_FIELDS = [_][]const u8{"kind"};
const VERSION_ONE_SSH_TRANSPORT_FIELDS = [_][]const u8{
    "kind",
    "host",
    "user",
    "port",
    "remote_gateway_port",
};

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

pub const Transport = union(enum) {
    local_socket,
    ssh_tunnel: SshTunnel,

    pub fn deinit(self: *Transport, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .local_socket => {},
            .ssh_tunnel => |*ssh| ssh.deinit(allocator),
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
            .local_socket => return false,
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
        1 => try validateVersionOneSchema(parsed.value),
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

fn validateVersionOneSchema(root: std.json.Value) !void {
    if (root != .object) return error.InvalidProfileDocument;
    try validateAllowedFields(&root.object, &VERSION_ONE_DOCUMENT_FIELDS);

    const profiles_value = root.object.get("profiles") orelse return error.InvalidProfileDocument;
    if (profiles_value != .array) return error.InvalidProfileDocument;
    for (profiles_value.array.items) |profile_value| {
        if (profile_value != .object) return error.InvalidProfile;
        try validateAllowedFields(&profile_value.object, &VERSION_ONE_PROFILE_FIELDS);

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
        } else {
            return error.UnsupportedProfileTransport;
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

    if (std.mem.eql(u8, kind, "local_socket") or
        (version == 0 and std.mem.eql(u8, kind, "local")))
    {
        return .{
            .id = owned_id,
            .label = owned_label,
            .expected_runtime_id = owned_runtime_id,
            .expected_instance_id = owned_instance_id,
            .transport = .local_socket,
        };
    }
    if (!std.mem.eql(u8, kind, "ssh_tunnel") and
        !(version == 0 and std.mem.eql(u8, kind, "ssh")))
    {
        return error.UnsupportedProfileTransport;
    }

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
    };
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
            },
            .ssh_tunnel => |ssh| try validateCanonicalSsh(ssh),
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
    try std.testing.expect(std.mem.indexOf(u8, canonical, "\"version\": 1") != null);
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
        try std.testing.expect(std.mem.indexOf(u8, canonical, "\"version\": 1") != null);
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
        \\{"version":1,"profiles":[{"id":"profile-0123456789abcdef0123456789abcdef","label":"One","transport":{"kind":"local_socket"}},{"id":"profile-0123456789abcdef0123456789abcdef","label":"Two","transport":{"kind":"ssh_tunnel","host":"vm"}}]}
        ,
    };
    for (invalid_payloads) |payload| {
        try std.testing.expectError(error.InvalidProfileDocument, normalizeValidationError(payload));
    }
    try std.testing.expectError(
        error.UnsupportedProfileVersion,
        decodeAlloc(std.testing.allocator, "{\"version\":2,\"profiles\":[]}"),
    );
}

fn normalizeValidationError(payload: []const u8) !void {
    var decoded = decodeAlloc(std.testing.allocator, payload) catch return error.InvalidProfileDocument;
    decoded.deinit(std.testing.allocator);
}
