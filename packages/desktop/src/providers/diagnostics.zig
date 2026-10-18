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
    fx_acp,
    grok_acp,
    custom_acp,
    claude_bridge,
    pi_rpc,
};

const ERROR_FORMAT = "provider_error category={s} code={?d} payload_len={d}";

/// Records only metadata about an upstream provider failure. The raw payload is
/// accepted solely so its byte length can be measured; its content is never
/// passed to the runtime logger.
pub fn logError(category: ErrorCategory, code: ?i64, raw_payload: []const u8) void {
    runtime_log.diagnostic(ERROR_FORMAT, .{ @tagName(category), code, raw_payload.len });
}
