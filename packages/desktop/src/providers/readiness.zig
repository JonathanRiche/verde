//! UI-independent provider installation and authentication readiness probes.

const std = @import("std");
const db_types = @import("../db/types.zig");
const harness = @import("harness.zig");
const process_env = @import("../platform/env.zig");

const log = std.log.scoped(.provider_readiness);
const Provider = db_types.Provider;

pub const ProviderReadiness = enum {
    checking,
    missing,
    signed_out,
    ready,
    unavailable,
};

/// Probe provider-native authentication without intentionally launching a
/// persistent provider server. Run this only on a disposable UI worker: some
/// third-party CLI handshakes do not offer a cancellable deadline.
pub fn detectProviderReadiness(provider: Provider) ProviderReadiness {
    const executable_ready = switch (provider) {
        .codex => process_env.commandExists("codex"),
        .opencode => process_env.commandExists("opencode2"),
        .claude => process_env.commandExists("node") and process_env.commandExists("claude"),
        .cursor => process_env.commandExists("agent"),
        .pi => process_env.commandExists("pi"),
        .fx => process_env.commandExists("fx"),
        .grok => process_env.commandExists("grok"),
    };
    if (!executable_ready) return .missing;

    const provider_config = switch (provider) {
        .codex => harness.ProviderConfig{ .codex = .{ .launch_on_connect = false } },
        .opencode => harness.ProviderConfig{ .opencode = .{
            .allocator = std.heap.page_allocator,
            .working_directory = null,
            .launch_if_missing = false,
        } },
        .claude => harness.ProviderConfig{ .claude = .{} },
        .cursor => harness.ProviderConfig{ .cursor = .{} },
        .pi => harness.ProviderConfig{ .pi = .{} },
        .fx => harness.ProviderConfig{ .fx = .{} },
        .grok => harness.ProviderConfig{ .grok = .{} },
    };
    var client = harness.connect(std.heap.page_allocator, provider_config) catch |err| {
        log.warn("provider readiness connect failed provider={s}: {s}", .{ @tagName(provider), @errorName(err) });
        return if (err == error.FileNotFound) .missing else .unavailable;
    };
    defer client.deinit();

    const auth_state = client.authState() catch |err| {
        log.warn("provider readiness auth failed provider={s}: {s}", .{ @tagName(provider), @errorName(err) });
        return if (err == error.FileNotFound) .missing else .unavailable;
    };
    return switch (auth_state) {
        .signed_in => .ready,
        .signed_out => .signed_out,
        .unknown, .pending => .unavailable,
    };
}
