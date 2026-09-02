//! CLI management for non-secret desktop runtime connection profiles.

const std = @import("std");

const output = @import("output.zig");
const profile = @import("../runtime/profile.zig");
const profile_store = @import("../runtime/profile_store.zig");
const workspace_runtime_defaults = @import("../runtime/workspace_runtime_defaults.zig");

pub const HandleResult = enum {
    handled,
    invalid_arguments,
};

const AddSshOptions = struct {
    label: []const u8,
    host: []const u8,
    user: ?[]const u8,
    ssh_port: u16,
    gateway_port: u16,
    expected_runtime_id: ?[]const u8,
    json: bool,
};

const RemoveOptions = struct {
    id: []const u8,
    json: bool,
};

const DefaultAction = union(enum) {
    show,
    set: []const u8,
    clear,
};

const DefaultOptions = struct {
    workspace_id: []const u8,
    action: DefaultAction,
    json: bool,
};

const DefaultResult = struct {
    configured_profile_id: ?[]u8,
    effective_profile_id: []u8,
    effective_label: []u8,
    stale: bool,
    changed: bool,

    fn deinit(self: *DefaultResult, allocator: std.mem.Allocator) void {
        if (self.configured_profile_id) |value| allocator.free(value);
        allocator.free(self.effective_profile_id);
        allocator.free(self.effective_label);
        self.* = undefined;
    }
};

/// Handles desktop-owned runtime profiles and workspace defaults. Provider
/// and gateway credentials have no CLI flag and never enter either JSON store.
pub fn handle(
    allocator: std.mem.Allocator,
    out: output.Output,
    io: std.Io,
    argv: []const []const u8,
) !HandleResult {
    if (argv.len == 0 or hasHelp(argv)) {
        try printHelp(out);
        return if (argv.len == 0) .invalid_arguments else .handled;
    }

    const command = argv[0];
    if (std.mem.eql(u8, command, "help")) {
        try printHelp(out);
        return .handled;
    }
    if (std.mem.eql(u8, command, "path")) {
        if (!onlyJsonFlag(argv[1..])) return invalid(out, "runtime path accepts only --json");
        const path = try profile_store.pathAlloc(allocator);
        defer allocator.free(path);
        if (hasFlag(argv[1..], "--json")) {
            try out.jsonValue(allocator, .{ .path = path });
        } else {
            try out.stdout("{s}\n", .{path});
        }
        return .handled;
    }
    if (std.mem.eql(u8, command, "list")) {
        if (!onlyJsonFlag(argv[1..])) return invalid(out, "runtime list accepts only --json");
        var profiles = profile_store.load(allocator) catch |err| {
            try writeStoreError(out, err);
            return err;
        };
        defer profiles.deinit(allocator);
        try writeProfiles(allocator, out, profiles.items, hasFlag(argv[1..], "--json"));
        return .handled;
    }
    if (std.mem.eql(u8, command, "add-ssh")) {
        const options = parseAddSsh(argv[1..]) catch {
            return invalid(out, "runtime add-ssh requires --label and --host with valid options");
        };
        const path = try profile_store.pathAlloc(allocator);
        defer allocator.free(path);
        var mutation_lock = profile_store.acquireExclusiveAtPath(allocator, io, path) catch |err| {
            try writeStoreError(out, err);
            return err;
        };
        var mutation_lock_held = true;
        defer if (mutation_lock_held) mutation_lock.deinit();
        const profiles = profile_store.loadAtPath(allocator, io, path) catch |err| {
            try writeStoreError(out, err);
            return err;
        };
        var list = std.ArrayList(profile.Profile).fromOwnedSlice(profiles.items);
        defer {
            for (list.items) |*item| item.deinit(allocator);
            list.deinit(allocator);
        }
        if (list.items.len >= profile.MAX_PROFILES) {
            try out.stderr("runtime profile limit reached ({d})\n", .{profile.MAX_PROFILES});
            return error.TooManyProfiles;
        }
        {
            var created = profile.Profile.createSshTunnel(
                allocator,
                io,
                options.label,
                options.expected_runtime_id,
                .{
                    .host = options.host,
                    .user = options.user,
                    .port = options.ssh_port,
                    .remote_gateway_port = options.gateway_port,
                },
            ) catch |err| {
                try out.stderr("invalid SSH runtime profile: {s}\n", .{@errorName(err)});
                return err;
            };
            errdefer created.deinit(allocator);
            try list.append(allocator, created);
        }
        profile_store.saveAtPath(allocator, io, path, list.items) catch |err| {
            try writeStoreError(out, err);
            return err;
        };
        // Rendering may block on a pipe; persistence no longer needs exclusive
        // ownership once the atomic replacement has completed.
        mutation_lock.deinit();
        mutation_lock_held = false;
        if (options.json) {
            try writeProfiles(allocator, out, list.items, true);
        } else {
            const created = list.items[list.items.len - 1];
            try out.stdout("Added SSH runtime {s} ({s}).\n", .{ created.label, created.id });
        }
        return .handled;
    }
    if (std.mem.eql(u8, command, "remove")) {
        const options = parseRemove(argv[1..]) catch {
            return invalid(out, "runtime remove requires exactly one --id");
        };
        const path = try profile_store.pathAlloc(allocator);
        defer allocator.free(path);
        var mutation_lock = profile_store.acquireExclusiveAtPath(allocator, io, path) catch |err| {
            try writeStoreError(out, err);
            return err;
        };
        var mutation_lock_held = true;
        defer if (mutation_lock_held) mutation_lock.deinit();
        const profiles = profile_store.loadAtPath(allocator, io, path) catch |err| {
            try writeStoreError(out, err);
            return err;
        };
        var list = std.ArrayList(profile.Profile).fromOwnedSlice(profiles.items);
        defer {
            for (list.items) |*item| item.deinit(allocator);
            list.deinit(allocator);
        }
        const index = findProfile(list.items, options.id) orelse {
            try out.stderr("runtime profile not found: {s}\n", .{options.id});
            return error.RuntimeProfileNotFound;
        };
        var removed = list.orderedRemove(index);
        defer removed.deinit(allocator);
        profile_store.saveAtPath(allocator, io, path, list.items) catch |err| {
            try writeStoreError(out, err);
            return err;
        };
        // Rendering may block on a pipe; persistence no longer needs exclusive
        // ownership once the atomic replacement has completed.
        mutation_lock.deinit();
        mutation_lock_held = false;
        if (options.json) {
            try writeProfiles(allocator, out, list.items, true);
        } else {
            try out.stdout("Removed runtime profile {s} ({s}).\n", .{ removed.label, removed.id });
        }
        return .handled;
    }
    if (std.mem.eql(u8, command, "default")) {
        const options = parseDefault(argv[1..]) catch {
            return invalid(
                out,
                "runtime default requires --workspace and at most one of --profile or --clear",
            );
        };
        const defaults_path = try workspace_runtime_defaults.pathAlloc(allocator);
        defer allocator.free(defaults_path);
        const profiles_path = try profile_store.pathAlloc(allocator);
        defer allocator.free(profiles_path);
        var result = runDefaultAtPaths(
            allocator,
            io,
            defaults_path,
            profiles_path,
            options,
        ) catch |err| {
            if (err == error.RuntimeProfileNotFound) {
                const requested_profile = switch (options.action) {
                    .set => |profile_id| profile_id,
                    else => unreachable,
                };
                try out.stderr("runtime profile not found: {s}\n", .{requested_profile});
            } else {
                try out.stderr("workspace runtime default error: {s}\n", .{@errorName(err)});
            }
            return err;
        };
        defer result.deinit(allocator);
        try writeDefaultResult(allocator, out, options, result);
        return .handled;
    }

    try out.stderr("unknown runtime command: {s}\n", .{command});
    return .invalid_arguments;
}

pub fn printHelp(out: output.Output) !void {
    try out.stdout(
        \\Usage:
        \\  verde runtime path [--json]
        \\  verde runtime list [--json]
        \\  verde runtime add-ssh --label <label> --host <ssh-host> [options]
        \\  verde runtime remove --id <profile-id> [--json]
        \\  verde runtime default --workspace <id> [--profile <local|profile-id> | --clear] [--json]
        \\
        \\SSH options:
        \\  --user <user>                    SSH user (otherwise use SSH config)
        \\  --ssh-port <port>                SSH port (default: 22)
        \\  --gateway-port <port>            Remote loopback gateway port (default: 7420)
        \\  --expected-runtime-id <id>       Pin a previously verified runtime identity
        \\  --json                           Print the non-secret profile document
        \\
        \\Local is built in and is not stored as a user profile. SSH authentication
        \\comes from the user's normal SSH configuration. Gateway and provider tokens
        \\are never accepted on the command line or written to runtime-profiles.json.
        \\A workspace default applies to new threads only; each thread may still select
        \\Local or another configured runtime independently.
        \\
    , .{});
}

fn parseAddSsh(argv: []const []const u8) !AddSshOptions {
    var label: ?[]const u8 = null;
    var host: ?[]const u8 = null;
    var user: ?[]const u8 = null;
    var ssh_port: u16 = profile.DEFAULT_SSH_PORT;
    var gateway_port: u16 = profile.DEFAULT_REMOTE_GATEWAY_PORT;
    var ssh_port_set = false;
    var gateway_port_set = false;
    var expected_runtime_id: ?[]const u8 = null;
    var json = false;

    var index: usize = 0;
    while (index < argv.len) {
        const arg = argv[index];
        if (std.mem.eql(u8, arg, "--json")) {
            if (json) return error.DuplicateOption;
            json = true;
            index += 1;
            continue;
        }
        const value = optionValue(argv, &index) orelse return error.MissingOptionValue;
        if (std.mem.eql(u8, arg, "--label")) {
            if (label != null) return error.DuplicateOption;
            label = value;
        } else if (std.mem.eql(u8, arg, "--host")) {
            if (host != null) return error.DuplicateOption;
            host = value;
        } else if (std.mem.eql(u8, arg, "--user")) {
            if (user != null) return error.DuplicateOption;
            user = value;
        } else if (std.mem.eql(u8, arg, "--ssh-port")) {
            if (ssh_port_set) return error.DuplicateOption;
            ssh_port = try parsePort(value);
            ssh_port_set = true;
        } else if (std.mem.eql(u8, arg, "--gateway-port")) {
            if (gateway_port_set) return error.DuplicateOption;
            gateway_port = try parsePort(value);
            gateway_port_set = true;
        } else if (std.mem.eql(u8, arg, "--expected-runtime-id")) {
            if (expected_runtime_id != null) return error.DuplicateOption;
            expected_runtime_id = value;
        } else {
            return error.UnknownOption;
        }
    }
    return .{
        .label = label orelse return error.MissingLabel,
        .host = host orelse return error.MissingHost,
        .user = user,
        .ssh_port = ssh_port,
        .gateway_port = gateway_port,
        .expected_runtime_id = expected_runtime_id,
        .json = json,
    };
}

fn parseRemove(argv: []const []const u8) !RemoveOptions {
    var id: ?[]const u8 = null;
    var json = false;
    var index: usize = 0;
    while (index < argv.len) {
        const arg = argv[index];
        if (std.mem.eql(u8, arg, "--json")) {
            if (json) return error.DuplicateOption;
            json = true;
            index += 1;
            continue;
        }
        const value = optionValue(argv, &index) orelse return error.MissingOptionValue;
        if (!std.mem.eql(u8, arg, "--id") or id != null) return error.InvalidOption;
        id = value;
    }
    return .{ .id = id orelse return error.MissingId, .json = json };
}

fn parseDefault(argv: []const []const u8) !DefaultOptions {
    var workspace_id: ?[]const u8 = null;
    var profile_id: ?[]const u8 = null;
    var clear = false;
    var json = false;
    var index: usize = 0;
    while (index < argv.len) {
        const arg = argv[index];
        if (std.mem.eql(u8, arg, "--json")) {
            if (json) return error.DuplicateOption;
            json = true;
            index += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--clear")) {
            if (clear) return error.DuplicateOption;
            clear = true;
            index += 1;
            continue;
        }
        const value = optionValue(argv, &index) orelse return error.MissingOptionValue;
        if (std.mem.eql(u8, arg, "--workspace")) {
            if (workspace_id != null) return error.DuplicateOption;
            workspace_id = value;
        } else if (std.mem.eql(u8, arg, "--profile")) {
            if (profile_id != null) return error.DuplicateOption;
            profile_id = value;
        } else {
            return error.UnknownOption;
        }
    }
    if (clear and profile_id != null) return error.ConflictingOptions;
    return .{
        .workspace_id = workspace_id orelse return error.MissingWorkspace,
        .action = if (clear)
            .clear
        else if (profile_id) |value|
            .{ .set = value }
        else
            .show,
        .json = json,
    };
}

fn runDefaultAtPaths(
    allocator: std.mem.Allocator,
    io: std.Io,
    defaults_path: []const u8,
    profiles_path: []const u8,
    options: DefaultOptions,
) !DefaultResult {
    const changed = switch (options.action) {
        .show => false,
        .set => |profile_id| blk: {
            if (!std.mem.eql(u8, profile_id, workspace_runtime_defaults.LOCAL_PROFILE_ID)) {
                try requireProfileAtPath(allocator, io, profiles_path, profile_id);
            }
            const mutation = try workspace_runtime_defaults.upsertAtPath(
                allocator,
                io,
                defaults_path,
                options.workspace_id,
                profile_id,
            );
            break :blk mutation != .unchanged;
        },
        .clear => try workspace_runtime_defaults.removeAtPath(
            allocator,
            io,
            defaults_path,
            options.workspace_id,
        ),
    };
    var result = try resolveDefaultAtPaths(
        allocator,
        io,
        defaults_path,
        profiles_path,
        options.workspace_id,
    );
    result.changed = changed;
    return result;
}

fn resolveDefaultAtPaths(
    allocator: std.mem.Allocator,
    io: std.Io,
    defaults_path: []const u8,
    profiles_path: []const u8,
    workspace_id: []const u8,
) !DefaultResult {
    const configured_profile_id = try workspace_runtime_defaults.lookupAtPath(
        allocator,
        io,
        defaults_path,
        workspace_id,
    );
    errdefer if (configured_profile_id) |value| allocator.free(value);
    const selected_id: []const u8 = if (configured_profile_id) |value|
        value
    else
        workspace_runtime_defaults.LOCAL_PROFILE_ID;
    if (std.mem.eql(u8, selected_id, workspace_runtime_defaults.LOCAL_PROFILE_ID)) {
        const effective_profile_id = try allocator.dupe(
            u8,
            workspace_runtime_defaults.LOCAL_PROFILE_ID,
        );
        errdefer allocator.free(effective_profile_id);
        return .{
            .configured_profile_id = configured_profile_id,
            .effective_profile_id = effective_profile_id,
            .effective_label = try allocator.dupe(u8, "Local"),
            .stale = false,
            .changed = false,
        };
    }

    var profiles = try profile_store.loadAtPath(allocator, io, profiles_path);
    defer profiles.deinit(allocator);
    if (findProfile(profiles.items, selected_id)) |index| {
        const effective_profile_id = try allocator.dupe(u8, selected_id);
        errdefer allocator.free(effective_profile_id);
        return .{
            .configured_profile_id = configured_profile_id,
            .effective_profile_id = effective_profile_id,
            .effective_label = try allocator.dupe(u8, profiles.items[index].label),
            .stale = false,
            .changed = false,
        };
    }

    const effective_profile_id = try allocator.dupe(
        u8,
        workspace_runtime_defaults.LOCAL_PROFILE_ID,
    );
    errdefer allocator.free(effective_profile_id);
    return .{
        .configured_profile_id = configured_profile_id,
        .effective_profile_id = effective_profile_id,
        .effective_label = try allocator.dupe(u8, "Local"),
        .stale = true,
        .changed = false,
    };
}

fn requireProfileAtPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    profiles_path: []const u8,
    profile_id: []const u8,
) !void {
    var profiles = try profile_store.loadAtPath(allocator, io, profiles_path);
    defer profiles.deinit(allocator);
    if (findProfile(profiles.items, profile_id) == null) return error.RuntimeProfileNotFound;
}

fn writeDefaultResult(
    allocator: std.mem.Allocator,
    out: output.Output,
    options: DefaultOptions,
    result: DefaultResult,
) !void {
    const action_name = @tagName(std.meta.activeTag(options.action));
    if (options.json) {
        try out.jsonValue(allocator, .{
            .workspace_id = options.workspace_id,
            .action = action_name,
            .changed = result.changed,
            .configured_profile_id = result.configured_profile_id,
            .effective_profile_id = result.effective_profile_id,
            .effective_label = result.effective_label,
            .stale = result.stale,
        });
        return;
    }

    switch (options.action) {
        .show => {
            if (result.stale) {
                try out.stdout(
                    "Workspace {s} saved default {s} is unavailable; new threads use Local.\n",
                    .{ options.workspace_id, result.configured_profile_id.? },
                );
            } else if (result.configured_profile_id == null) {
                try out.stdout(
                    "Workspace {s} uses Local for new threads (no saved default).\n",
                    .{options.workspace_id},
                );
            } else {
                try out.stdout(
                    "Workspace {s} default for new threads: {s} ({s}).\n",
                    .{ options.workspace_id, result.effective_label, result.effective_profile_id },
                );
            }
        },
        .set => {
            if (result.changed) {
                try out.stdout(
                    "Set workspace {s} default for new threads to {s} ({s}).\n",
                    .{ options.workspace_id, result.effective_label, result.effective_profile_id },
                );
            } else {
                try out.stdout(
                    "Workspace {s} already defaults new threads to {s} ({s}).\n",
                    .{ options.workspace_id, result.effective_label, result.effective_profile_id },
                );
            }
        },
        .clear => {
            if (result.changed) {
                try out.stdout(
                    "Cleared workspace {s} runtime default; new threads use Local unless overridden.\n",
                    .{options.workspace_id},
                );
            } else {
                try out.stdout(
                    "Workspace {s} has no saved runtime default; new threads use Local unless overridden.\n",
                    .{options.workspace_id},
                );
            }
        },
    }
}

fn optionValue(argv: []const []const u8, index: *usize) ?[]const u8 {
    if (!std.mem.startsWith(u8, argv[index.*], "--") or index.* + 1 >= argv.len) return null;
    const value = argv[index.* + 1];
    if (std.mem.startsWith(u8, value, "--")) return null;
    index.* += 2;
    return value;
}

fn parsePort(value: []const u8) !u16 {
    const port = try std.fmt.parseInt(u16, value, 10);
    if (port == 0) return error.InvalidPort;
    return port;
}

fn writeProfiles(
    allocator: std.mem.Allocator,
    out: output.Output,
    profiles: []const profile.Profile,
    json: bool,
) !void {
    if (json) {
        const encoded = try profile.encodeAlloc(allocator, profiles);
        defer allocator.free(encoded);
        try out.stdout("{s}\n", .{encoded});
        return;
    }
    if (profiles.len == 0) {
        try out.stdout("No configured runtime profiles. Local is always available.\n", .{});
        return;
    }
    for (profiles) |item| switch (item.transport) {
        .local_socket => try out.stdout("{s}\t{s}\tlocal_socket\n", .{ item.id, item.label }),
        .ssh_tunnel => |ssh| try out.stdout(
            "{s}\t{s}\tssh://{s}{s}{s}:{d}\tgateway=127.0.0.1:{d}\n",
            .{
                item.id,
                item.label,
                if (ssh.user != null) ssh.user.? else "",
                if (ssh.user != null) "@" else "",
                ssh.host,
                ssh.port,
                ssh.remote_gateway_port,
            },
        ),
        .direct_https => |endpoint| try out.stdout(
            "{s}\t{s}\tdirect_https\t{s}\n",
            .{ item.id, item.label, endpoint.https_url orelse "<missing endpoint>" },
        ),
        .connect => |endpoint| try out.stdout(
            "{s}\t{s}\tconnect\t{s}\n",
            .{ item.id, item.label, endpoint.https_url orelse "<no runtime selected>" },
        ),
    };
}

fn writeStoreError(out: output.Output, err: anyerror) !void {
    try out.stderr("runtime profile store error: {s}\n", .{profile.redactedErrorMessage(err)});
}

fn invalid(out: output.Output, message: []const u8) !HandleResult {
    try out.stderr("{s}\n", .{message});
    return .invalid_arguments;
}

fn hasHelp(argv: []const []const u8) bool {
    return hasFlag(argv, "--help") or hasFlag(argv, "-h");
}

fn hasFlag(argv: []const []const u8, wanted: []const u8) bool {
    for (argv) |arg| if (std.mem.eql(u8, arg, wanted)) return true;
    return false;
}

fn onlyJsonFlag(argv: []const []const u8) bool {
    if (argv.len > 1) return false;
    return argv.len == 0 or std.mem.eql(u8, argv[0], "--json");
}

fn findProfile(profiles: []const profile.Profile, id: []const u8) ?usize {
    for (profiles, 0..) |item, index| {
        if (std.mem.eql(u8, item.id, id)) return index;
    }
    return null;
}

test "runtime add-ssh parsing is strict and secret flags are rejected" {
    const parsed = try parseAddSsh(&.{
        "--label",               "Build VM",
        "--host",                "devbox",
        "--user",                "verde",
        "--ssh-port",            "2202",
        "--gateway-port",        "7421",
        "--expected-runtime-id", "0123456789abcdef0123456789abcdef",
        "--json",
    });
    try std.testing.expectEqualStrings("Build VM", parsed.label);
    try std.testing.expectEqualStrings("devbox", parsed.host);
    try std.testing.expectEqual(@as(u16, 2202), parsed.ssh_port);
    try std.testing.expectEqual(@as(u16, 7421), parsed.gateway_port);
    try std.testing.expect(parsed.json);

    try std.testing.expectError(error.UnknownOption, parseAddSsh(&.{
        "--label", "Build VM",
        "--host",  "devbox",
        "--token", "must-not-enter-argv",
    }));
    try std.testing.expectError(error.MissingOptionValue, parseAddSsh(&.{
        "--label", "Build VM",
        "--host",
    }));
    try std.testing.expectError(error.InvalidPort, parseAddSsh(&.{
        "--label",    "Build VM",
        "--host",     "devbox",
        "--ssh-port", "0",
    }));
}

test "runtime remove parsing requires one id" {
    const parsed = try parseRemove(&.{ "--id", "profile-0123456789abcdef0123456789abcdef", "--json" });
    try std.testing.expectEqualStrings("profile-0123456789abcdef0123456789abcdef", parsed.id);
    try std.testing.expect(parsed.json);
    try std.testing.expectError(error.MissingId, parseRemove(&.{}));
    try std.testing.expectError(error.InvalidOption, parseRemove(&.{ "--id", "one", "--id", "two" }));
}

test "runtime default parsing is strict and never accepts secrets" {
    const show = try parseDefault(&.{ "--workspace", "workspace-one", "--json" });
    try std.testing.expectEqualStrings("workspace-one", show.workspace_id);
    try std.testing.expectEqual(.show, std.meta.activeTag(show.action));
    try std.testing.expect(show.json);

    const set = try parseDefault(&.{
        "--profile",
        "profile-0123456789abcdef0123456789abcdef",
        "--workspace",
        "workspace-one",
    });
    try std.testing.expectEqualStrings(
        "profile-0123456789abcdef0123456789abcdef",
        set.action.set,
    );

    const clear = try parseDefault(&.{ "--clear", "--workspace", "workspace-one" });
    try std.testing.expectEqual(.clear, std.meta.activeTag(clear.action));
    try std.testing.expectError(error.MissingWorkspace, parseDefault(&.{}));
    try std.testing.expectError(error.ConflictingOptions, parseDefault(&.{
        "--workspace",
        "workspace-one",
        "--profile",
        "local",
        "--clear",
    }));
    try std.testing.expectError(error.UnknownOption, parseDefault(&.{
        "--workspace",
        "workspace-one",
        "--token",
        "must-not-enter-argv",
    }));
}

test "runtime default requires configured profiles and resolves stale mappings to Local" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var absolute_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const absolute_len = try tmp.dir.realPath(std.testing.io, &absolute_buffer);
    const root_path = absolute_buffer[0..absolute_len];
    const defaults_path = try std.fs.path.join(
        allocator,
        &.{ root_path, workspace_runtime_defaults.FILE_NAME },
    );
    defer allocator.free(defaults_path);
    const profiles_path = try std.fs.path.join(allocator, &.{ root_path, profile_store.FILE_NAME });
    defer allocator.free(profiles_path);

    var configured = try profile.Profile.createSshTunnel(
        allocator,
        std.testing.io,
        "Build VM",
        null,
        .{ .host = "build-vm" },
    );
    defer configured.deinit(allocator);
    try profile_store.saveAtPath(allocator, std.testing.io, profiles_path, &.{configured});

    var set_result = try runDefaultAtPaths(
        allocator,
        std.testing.io,
        defaults_path,
        profiles_path,
        .{
            .workspace_id = "workspace-one",
            .action = .{ .set = configured.id },
            .json = false,
        },
    );
    defer set_result.deinit(allocator);
    try std.testing.expect(set_result.changed);
    try std.testing.expect(!set_result.stale);
    try std.testing.expectEqualStrings(configured.id, set_result.configured_profile_id.?);
    try std.testing.expectEqualStrings(configured.id, set_result.effective_profile_id);
    try std.testing.expectEqualStrings("Build VM", set_result.effective_label);

    try std.testing.expectError(error.RuntimeProfileNotFound, runDefaultAtPaths(
        allocator,
        std.testing.io,
        defaults_path,
        profiles_path,
        .{
            .workspace_id = "workspace-two",
            .action = .{ .set = "profile-ffffffffffffffffffffffffffffffff" },
            .json = false,
        },
    ));
    try std.testing.expect((try workspace_runtime_defaults.lookupAtPath(
        allocator,
        std.testing.io,
        defaults_path,
        "workspace-two",
    )) == null);

    try profile_store.saveAtPath(allocator, std.testing.io, profiles_path, &.{});
    var stale_result = try runDefaultAtPaths(
        allocator,
        std.testing.io,
        defaults_path,
        profiles_path,
        .{
            .workspace_id = "workspace-one",
            .action = .show,
            .json = false,
        },
    );
    defer stale_result.deinit(allocator);
    try std.testing.expect(stale_result.stale);
    try std.testing.expectEqualStrings(configured.id, stale_result.configured_profile_id.?);
    try std.testing.expectEqualStrings("local", stale_result.effective_profile_id);

    var cleared_result = try runDefaultAtPaths(
        allocator,
        std.testing.io,
        defaults_path,
        profiles_path,
        .{
            .workspace_id = "workspace-one",
            .action = .clear,
            .json = false,
        },
    );
    defer cleared_result.deinit(allocator);
    try std.testing.expect(cleared_result.changed);
    try std.testing.expect(cleared_result.configured_profile_id == null);
    try std.testing.expectEqualStrings("local", cleared_result.effective_profile_id);

    var local_result = try runDefaultAtPaths(
        allocator,
        std.testing.io,
        defaults_path,
        profiles_path,
        .{
            .workspace_id = "workspace-one",
            .action = .{ .set = "local" },
            .json = false,
        },
    );
    defer local_result.deinit(allocator);
    try std.testing.expect(local_result.changed);
    try std.testing.expectEqualStrings("local", local_result.configured_profile_id.?);
    try std.testing.expectEqualStrings("local", local_result.effective_profile_id);
}
