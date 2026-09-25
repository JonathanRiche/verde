//! Server-side adapter for the web chat connection picker; never exports credentials.

const std = @import("std");
const Service = @import("runtime/service.zig");
const profiles = @import("runtime/profile_store.zig");
const defaults = @import("runtime/workspace_runtime_defaults.zig");

pub const Router = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    service: ?Service = null,
    abandoned: ?Service.RpcTicket = null,
    profiles_refreshed_at: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Router {
        return .{ .allocator = allocator, .io = io };
    }

    pub fn deinit(self: *Router) void {
        if (self.service) |*service| service.deinit();
    }

    fn readyService(self: *Router) !*Service {
        if (self.service == null) {
            const path = try profiles.pathAlloc(self.allocator);
            defer self.allocator.free(path);
            self.service = try Service.init(self.allocator, self.io, path, .{});
        }
        const service = &self.service.?;
        try service.poll(self.now());
        if (self.abandoned) |ticket| {
            if (try service.takeRpcResult(ticket)) |result| {
                var owned = result;
                owned.deinit();
                self.abandoned = null;
            }
        }
        return service;
    }

    fn now(self: *Router) u64 {
        return @intCast(std.Io.Clock.awake.now(self.io).toMilliseconds());
    }

    pub fn catalog(self: *Router) ![]u8 {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        const service = try self.readyService();
        if (self.now() -| self.profiles_refreshed_at > 30_000) {
            try service.reloadProfiles();
            self.profiles_refreshed_at = self.now();
        }
        const snapshots = try service.snapshotsAlloc(self.allocator);
        defer self.allocator.free(snapshots);
        const path = try defaults.pathAlloc(self.allocator);
        defer self.allocator.free(path);
        var workspace_defaults = try defaults.loadAtPath(self.allocator, self.io, path);
        defer workspace_defaults.deinit(self.allocator);
        const Row = struct { profile_id: []const u8, label: []const u8, phase: []const u8, ready: bool, runtime_id: ?[]const u8, failure: ?[]const u8 };
        var rows: std.ArrayList(Row) = .empty;
        defer rows.deinit(self.allocator);
        for (snapshots) |snapshot| {
            try rows.append(self.allocator, .{
                .profile_id = snapshot.profile_id,
                .label = snapshot.label,
                .phase = @tagName(snapshot.phase),
                .ready = snapshot.execution_ready,
                .runtime_id = if (snapshot.runtime) |runtime| runtime.runtime_id else null,
                .failure = if (snapshot.failure_reason) |reason| @tagName(reason) else null,
            });
        }
        return std.json.Stringify.valueAlloc(self.allocator, .{ .connections = rows.items, .defaults = workspace_defaults.items }, .{});
    }

    /// Pins each call to the catalog identity as well as the manager's saved pins.
    pub fn call(self: *Router, profile_id: []const u8, runtime_id: []const u8, method: []const u8, params: std.json.Value) ![]u8 {
        if (!allowedMethod(method)) return error.UnsupportedRemoteMethod;
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        const service = try self.readyService();
        if (self.abandoned != null) return error.RuntimeRpcBusy;
        const snapshot = service.snapshot(profile_id) orelse return error.UnknownRuntimeProfile;
        if (!snapshot.execution_ready) return error.RuntimeNotExecutionReady;
        const runtime = snapshot.runtime orelse return error.RuntimeNotExecutionReady;
        if (!std.mem.eql(u8, runtime.runtime_id, runtime_id)) return error.RuntimeIdentityChanged;
        const ticket = try service.beginRpc(profile_id, method, params);
        var pending = true;
        errdefer if (pending) {
            self.abandoned = ticket;
        };
        const deadline = self.now() + 30_000;
        while (self.now() < deadline) {
            try service.poll(self.now());
            if (try service.takeRpcResult(ticket)) |result| {
                pending = false;
                var owned = result;
                defer owned.deinit();
                return switch (owned) {
                    .response => |response| self.allocator.dupe(u8, response.json),
                    .failed => error.RemoteConnectionFailed,
                    .canceled => error.RemoteRequestCanceled,
                };
            }
            try std.Io.sleep(self.io, .fromMilliseconds(20), .awake);
        }
        return error.RemoteRequestTimedOut;
    }
};

pub fn allowedMethod(method: []const u8) bool {
    inline for (.{ "chat.turn.start", "chat.turn.list", "chat.turn.tail", "chat.turn.cancel", "chat.turn.approve", "chat.turn.steer", "chat.followup", "chat.thread.get", "workspace.repository.manifest.get", "workspace.files.search", "workspace.directory.list", "workspace.close", "provider.models.list", "providers.status", "chat.message.list", "provider.slash.list", "provider.slash.run", "provider.thread.sync", "chat.shell.run", "chat.attachment.create", "chat.attachment.append", "chat.attachment.commit" }) |allowed| {
        if (std.mem.eql(u8, method, allowed)) return true;
    }
    return false;
}

test "web runtime routing exposes only chat execution and repository inspection" {
    try std.testing.expect(allowedMethod("chat.turn.start"));
    try std.testing.expect(allowedMethod("chat.turn.cancel"));
    try std.testing.expect(allowedMethod("chat.attachment.append"));
    try std.testing.expect(allowedMethod("provider.slash.run"));
    try std.testing.expect(allowedMethod("chat.shell.run"));
    try std.testing.expect(!allowedMethod("access.pairing.create"));
    try std.testing.expect(!allowedMethod("workspace.repository.binding.upsert"));
}
