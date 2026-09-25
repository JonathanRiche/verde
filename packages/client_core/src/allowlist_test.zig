//! K-13 paired RPC allowlist coverage.
//!
//! The core has no method constant table; callers pass inline wire names. This
//! test derives the list of every RPC the core can send by parsing its own
//! non-test sources, then requires `requiredScopeMaskForRpc(method) != null`
//! for each. A new caller therefore fails here until A-17's allowlist maps it,
//! without a second hand-maintained inventory to keep in sync.
//!
//! Collected call sites:
//! - `*.request(tx, "<method>", ...)` and bare `request` inside `rpc.zig`: the
//!   K-08 `/api/rpc` sink.
//! - the `forwarders` below, which receive a method and pass it to the sink.
//! - struct initializers with a dotted `.method = "<ns>.<name>"` literal: RPC
//!   envelopes the core encodes itself, such as WebSocket feed controls.
//!
//! A sink call with any other non-literal method fails as unresolved, as does a
//! forwarder that no longer exists, so renames cannot silently shrink the list.
//!
//! Intentional exemptions, all outside `/api/rpc` and the RPC allowlist:
//! - Auth HTTP endpoints in `auth.zig`: public discovery GET
//!   (`/.well-known/verde-runtime`), the unauthenticated pair exchange, the
//!   credential-to-token POST and the bearer-to-WebSocket-ticket POST.
//! - `auth_rpc.zig` re-emits an already encoded envelope after a 401 refresh;
//!   it never chooses a method.
//! - Incoming WebSocket messages (`core.hello`, `core.snapshot`,
//!   `core.changes`) are notifications, not requests.
//! Only `rpc.zig` and `auth_rpc.zig` may name the `/api/rpc` endpoint.
const std = @import("std");
const access = @import("headless").access_protocol;
const Ast = std.zig.Ast;
const eq = std.mem.eql;

const Forwarder = struct {
    file: []const u8,
    /// Wrapper whose callers supply the method.
    name: []const u8,
    method_arg: usize,
    /// Non-literal method expression the wrapper passes to `rpc.request`.
    forwarded: []const u8,
};

const forwarders = [_]Forwarder{
    .{ .file = "chat.zig", .name = "call", .method_arg = 3, .forwarded = "method" },
    .{ .file = "terminal_pump.zig", .name = "queue", .method_arg = 2, .forwarded = "action.method" },
};

const rpc_endpoint_files = [_][]const u8{ "rpc.zig", "auth_rpc.zig" };

test "every RPC the core can send has a paired-device allowlist entry" {
    const a = std.testing.allocator;
    var audit: Audit = .{ .allocator = a };
    defer audit.deinit();
    try audit.scanSources();

    var failed = false;
    for (forwarders, audit.forwarder_calls, audit.forwarder_sites) |forwarder, calls, sites| {
        if (calls == 0 or sites == 0) {
            std.debug.print("\nstale RPC forwarder {s}:{s} (callers {d}, forwarding sites {d})\n", .{ forwarder.file, forwarder.name, calls, sites });
            failed = true;
        }
    }
    if (audit.methods.items.len == 0 or !audit.contains("core.status")) {
        std.debug.print("\nRPC audit found no handshake call; sink detection is broken\n", .{});
        failed = true;
    }
    for (audit.methods.items) |method| {
        if (access.requiredScopeMaskForRpc(method) == null) {
            std.debug.print("\nunmapped core RPC: {s}\n", .{method});
            failed = true;
        }
    }
    if (failed) return error.UnmappedCoreRpc;
}

test "WebSocket delta opt-in is mapped directly under the core.changes scope" {
    // K-16 sends `core.changes.mode` on the feed socket; the gateway answers it
    // locally but authorizes it through the same allowlist, with no alias.
    try std.testing.expectEqual(access.requiredScopeMaskForRpc("core.changes").?, access.requiredScopeMaskForRpc("core.changes.mode").?);
}

const Audit = struct {
    allocator: std.mem.Allocator,
    methods: std.ArrayList([]const u8) = .empty,
    forwarder_calls: [forwarders.len]usize = @splat(0),
    forwarder_sites: [forwarders.len]usize = @splat(0),
    failed: bool = false,

    fn deinit(self: *Audit) void {
        for (self.methods.items) |method| self.allocator.free(method);
        self.methods.deinit(self.allocator);
    }

    fn contains(self: *const Audit, method: []const u8) bool {
        for (self.methods.items) |listed| if (eq(u8, listed, method)) return true;
        return false;
    }

    /// Test-only source I/O: the whole `src` tree is scanned so a new module
    /// needs no registration here. The run step's cwd is the package root.
    fn scanSources(self: *Audit) !void {
        const io = std.testing.io;
        var dir = try std.Io.Dir.cwd().openDir(io, "src", .{ .iterate = true });
        defer dir.close(io);
        var walker = try dir.walk(self.allocator);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
            if (isTestSource(entry.basename)) continue;
            const bytes = try dir.readFileAlloc(io, entry.path, self.allocator, .limited(4 * 1024 * 1024));
            defer self.allocator.free(bytes);
            const source = try self.allocator.dupeZ(u8, bytes);
            defer self.allocator.free(source);
            var tree = try Ast.parse(self.allocator, source, .zig);
            defer tree.deinit(self.allocator);
            try std.testing.expectEqual(@as(usize, 0), tree.errors.len);
            try self.scanFile(&tree, entry.path, entry.basename);
        }
        if (self.failed) return error.UnresolvedCoreRpc;
    }

    fn scanFile(self: *Audit, tree: *const Ast, path: []const u8, basename: []const u8) !void {
        var tests: std.ArrayList([2]Ast.TokenIndex) = .empty;
        defer tests.deinit(self.allocator);
        for (0..tree.nodes.len) |index| {
            const node: Ast.Node.Index = @enumFromInt(index);
            if (tree.nodeTag(node) == .test_decl) try tests.append(self.allocator, .{ tree.firstToken(node), tree.lastToken(node) });
        }

        for (0..tree.nodes.len) |index| {
            const node: Ast.Node.Index = @enumFromInt(index);
            if (tree.nodeTag(node) == .string_literal) {
                if (std.mem.indexOf(u8, tree.getNodeSource(node), "/api/rpc") != null and !inTest(tests.items, tree.firstToken(node)) and !isEndpointFile(basename)) {
                    std.debug.print("\n{s} names /api/rpc; send RPCs through rpc.request\n", .{path});
                    self.failed = true;
                }
                continue;
            }
            var init_buffer: [2]Ast.Node.Index = undefined;
            if (tree.fullStructInit(&init_buffer, node)) |init| {
                if (inTest(tests.items, tree.firstToken(node))) continue;
                for (init.ast.fields) |field| {
                    if (!eq(u8, tree.tokenSlice(tree.firstToken(field) - 2), "method") or tree.nodeTag(field) != .string_literal) continue;
                    const method = try std.zig.string_literal.parseAlloc(self.allocator, tree.getNodeSource(field));
                    defer self.allocator.free(method);
                    if (std.mem.indexOfScalar(u8, method, '.') != null) try self.add(method);
                }
                continue;
            }
            var call_buffer: [1]Ast.Node.Index = undefined;
            const call = tree.fullCall(&call_buffer, node) orelse continue;
            if (inTest(tests.items, tree.firstToken(node))) continue;
            const callee = tree.getNodeSource(call.ast.fn_expr);
            const method_arg = if (std.mem.endsWith(u8, callee, ".request") or (eq(u8, basename, "rpc.zig") and eq(u8, callee, "request")))
                1
            else if (forwarderIndex(basename, callee)) |i| blk: {
                self.forwarder_calls[i] += 1;
                break :blk forwarders[i].method_arg;
            } else continue;
            if (call.ast.params.len <= method_arg) {
                std.debug.print("\nRPC call without a method in {s}: {s}\n", .{ path, callee });
                self.failed = true;
                continue;
            }
            const arg = call.ast.params[method_arg];
            if (tree.nodeTag(arg) == .string_literal) {
                const method = try std.zig.string_literal.parseAlloc(self.allocator, tree.getNodeSource(arg));
                defer self.allocator.free(method);
                try self.add(method);
            } else if (forwardingIndex(basename, callee, tree.getNodeSource(arg))) |i| {
                self.forwarder_sites[i] += 1;
            } else {
                std.debug.print("\nunresolved RPC method in {s}: {s}\n", .{ path, tree.getNodeSource(arg) });
                self.failed = true;
            }
        }
    }

    fn add(self: *Audit, method: []const u8) !void {
        if (self.contains(method)) return;
        const owned = try self.allocator.dupe(u8, method);
        errdefer self.allocator.free(owned);
        try self.methods.append(self.allocator, owned);
    }
};

fn forwarderIndex(basename: []const u8, callee: []const u8) ?usize {
    for (forwarders, 0..) |forwarder, i| {
        if (eq(u8, forwarder.file, basename) and eq(u8, forwarder.name, callee)) return i;
    }
    return null;
}

fn forwardingIndex(basename: []const u8, callee: []const u8, expression: []const u8) ?usize {
    if (!std.mem.endsWith(u8, callee, ".request")) return null;
    for (forwarders, 0..) |forwarder, i| {
        if (eq(u8, forwarder.file, basename) and eq(u8, forwarder.forwarded, expression)) return i;
    }
    return null;
}

fn isTestSource(basename: []const u8) bool {
    return std.mem.endsWith(u8, basename, "_test.zig") or std.mem.endsWith(u8, basename, "_tests.zig") or
        std.mem.endsWith(u8, basename, "harness.zig");
}

fn isEndpointFile(basename: []const u8) bool {
    for (rpc_endpoint_files) |file| if (eq(u8, file, basename)) return true;
    return false;
}

fn inTest(tests: []const [2]Ast.TokenIndex, token: Ast.TokenIndex) bool {
    for (tests) |range| if (token >= range[0] and token <= range[1]) return true;
    return false;
}
