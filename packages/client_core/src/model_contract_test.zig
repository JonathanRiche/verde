//! Checks the exported schema against real K-06 boundary output.
const std = @import("std");
const wire = @import("wire.zig");
const host = @import("host.zig");
const a = std.testing.allocator;

// Native codecs flatten tagged unions: discriminate first, then decode payload.
fn checkEffect(value: std.json.Value) !void {
    const tag = value.object.get("type").?.string;
    inline for (@typeInfo(wire.Effect).@"union".fields) |field| {
        if (std.mem.eql(u8, tag, field.name)) {
            const decoded = try std.json.parseFromValue(field.type, a, value, .{ .ignore_unknown_fields = true });
            defer decoded.deinit();
            return;
        }
    }
    return error.UnregisteredEffect;
}

test "exported native models decode real host queries and effects" {
    const config: wire.Config = .{
        .api_version = 1,
        .host_id = "model-fixture",
        .label = "Fixture",
        .https_url = null,
        .wss_url = null,
        .client_revision = 1,
        .session_nonce = "00000000000000000000000000000000",
        .jitter_seed = std.math.maxInt(u64),
    };
    const input = try std.json.Stringify.valueAlloc(a, config, .{});
    defer a.free(input);
    var h = try host.Host.init(a, input);
    defer h.deinit();
    const output = try h.handle(
        \\{"api_version":1,"type":"start","now_ms":0,"wall_time_ms":0,"foreground":true,"network_available":true}
    , a);
    defer a.free(output);
    const batch = try std.json.parseFromSlice(std.json.Value, a, output, .{});
    defer batch.deinit();
    for (batch.value.object.get("effects").?.array.items) |effect| try checkEffect(effect);
    inline for (.{ .{ "hosts", wire.HostsView }, .{ "home", wire.HomeView }, .{ "workspaces", wire.WorkspacesView } }) |entry| {
        const query = try h.query(entry[0], a);
        defer a.free(query);
        const decoded = try std.json.parseFromSlice(wire.Query(entry[1]), a, query, .{});
        defer decoded.deinit();
        try std.testing.expect(decoded.value.data != null);
        try std.testing.expect(decoded.value.@"error" == null);
    }
}
