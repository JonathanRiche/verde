//! Content-safe diagnostics shared by provider integrations.

const std = @import("std");
const runtime_log = @import("../runtime/log.zig");

/// Stable provider failure categories suitable for persisted diagnostics.
pub const ErrorCategory = enum {
    codex_compact_rpc,
    codex_review_rpc,
    codex_shell_rpc,
    codex_rpc,
    cursor_acp,
    claude_bridge,
};

const ERROR_FORMAT = "provider_error category={s} code={?d} payload_len={d}";

/// Records only metadata about an upstream provider failure. The raw payload is
/// accepted solely so its byte length can be measured; its content is never
/// passed to the runtime logger.
pub fn logError(category: ErrorCategory, code: ?i64, raw_payload: []const u8) void {
    runtime_log.diagnostic(ERROR_FORMAT, .{ @tagName(category), code, raw_payload.len });
}

fn formatErrorAlloc(
    allocator: std.mem.Allocator,
    category: ErrorCategory,
    code: ?i64,
    raw_payload: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(allocator, ERROR_FORMAT, .{ @tagName(category), code, raw_payload.len });
}

test "provider diagnostics never format raw error content" {
    const sentinel = "verde-provider-secret-sentinel";
    const formatted = try formatErrorAlloc(std.testing.allocator, .codex_rpc, -32000, sentinel);
    defer std.testing.allocator.free(formatted);

    try std.testing.expectEqualStrings(
        "provider_error category=codex_rpc code=-32000 payload_len=30",
        formatted,
    );
    try std.testing.expect(std.mem.indexOf(u8, formatted, sentinel) == null);
}
