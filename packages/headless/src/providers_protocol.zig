//! Runtime-scoped provider installation and authentication inventory DTOs.
//!
//! Surface flags intentionally preserve Verde's distinct native-chat, MCP,
//! and terminal integration sets. Strings are used for probe/auth states so
//! older clients can tolerate a newer daemon state without enum decode failure.

const std = @import("std");

pub const METHOD_PROVIDERS_STATUS: []const u8 = "providers.status";

/// Named empty request object; an anonymous `.{}` encodes as the JSON tuple
/// `[]`, which the daemon correctly rejects for object-shaped parameters.
pub const StatusRequest = struct {};

pub const ProviderSurfaces = struct {
    native_chat: bool = false,
    terminal_tui: bool = false,
    mcp: bool = false,
    lifecycle: bool = false,
};

pub const Remediation = struct {
    kind: []const u8,
    label: []const u8,
    command: []const []const u8 = &.{},
};

pub const ProviderStatus = struct {
    provider: []const u8,
    label: []const u8,
    surfaces: ProviderSurfaces,
    installed: bool,
    state: []const u8,
    authentication: []const u8,
    executable_path: ?[]const u8 = null,
    version: ?[]const u8 = null,
    account_label: ?[]const u8 = null,
    auth_kind: ?[]const u8 = null,
    remediation: ?Remediation = null,
};

pub const StatusResult = struct {
    runtime_id: []const u8,
    instance_id: []const u8,
    probed_at_ms: i64,
    providers: []const ProviderStatus,
};

test "provider inventory DTO preserves distinct surfaces" {
    const rows = [_]ProviderStatus{
        .{
            .provider = "codex",
            .label = "Codex",
            .surfaces = .{ .native_chat = true, .terminal_tui = true, .mcp = true, .lifecycle = true },
            .installed = true,
            .state = "ready",
            .authentication = "authenticated",
        },
        .{
            .provider = "amp",
            .label = "Amp",
            .surfaces = .{ .terminal_tui = true, .mcp = true, .lifecycle = true },
            .installed = false,
            .state = "missing",
            .authentication = "unknown",
        },
    };
    const encoded = try std.json.Stringify.valueAlloc(std.testing.allocator, StatusResult{
        .runtime_id = "runtime-a",
        .instance_id = "instance-a",
        .probed_at_ms = 1,
        .providers = &rows,
    }, .{});
    defer std.testing.allocator.free(encoded);
    var parsed = try std.json.parseFromSlice(StatusResult, std.testing.allocator, encoded, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expect(parsed.value.providers[0].surfaces.native_chat);
    try std.testing.expect(!parsed.value.providers[1].surfaces.native_chat);
    try std.testing.expect(parsed.value.providers[1].surfaces.mcp);
}

test "provider status request encodes as an object" {
    const encoded = try std.json.Stringify.valueAlloc(
        std.testing.allocator,
        StatusRequest{},
        .{},
    );
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualStrings("{}", encoded);
}
