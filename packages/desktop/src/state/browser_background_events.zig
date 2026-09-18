//! Browser lifecycle reduction for runtimes which do not own desktop presentation.

const std = @import("std");
const readiness = @import("../browser/readiness.zig");
const Event = @import("../browser/types.zig").Event;
const BrowserTabRef = @import("browser_pane.zig").BrowserTabRef;
const BridgePolicy = @import("../browser/bridge_policy.zig").Policy;

/// Applies document state only. Returns whether persisted pane metadata changed.
/// Clipboard, inspector actions, cursor, menus and desktop focus have no background owner.
pub fn apply(runtime: anytype, tab: ?*BrowserTabRef, allocator: std.mem.Allocator, event: Event, bridge_policy: BridgePolicy) bool {
    switch (event) {
        .opened => {
            runtime.status = readiness.afterEvent(runtime.status, .opened, if (tab) |value| value.loading else runtime.status == .opening);
            if (runtime.status != .failed) runtime.setLastError(null) catch {};
        },
        .closed => {
            if (!runtime.consumeSuppressedClosedEvent()) runtime.status = .hidden;
        },
        .navigated => |url| {
            if (std.mem.trim(u8, url, &std.ascii.whitespace).len == 0) return false;
            runtime.status = readiness.afterEvent(runtime.status, .navigated, false);
            runtime.setCurrentUrl(url) catch {};
            runtime.setAddress(url);
            if (runtime.status != .failed) runtime.setLastError(null) catch {};
            if (tab) |value| {
                if (runtime.status != .failed) {
                    value.loading = true;
                    value.load_failed = false;
                }
                if (std.mem.eql(u8, url, "about:blank") and value.url != null and
                    !std.mem.eql(u8, value.url.?, "about:blank")) return false;
                value.recordNavigation(allocator, url) catch return false;
                return true;
            }
        },
        .title_changed => |title| {
            runtime.setCurrentTitle(title) catch {};
            if (tab) |value| {
                value.setTitle(allocator, title) catch return false;
                return true;
            }
        },
        .document_loaded => {
            runtime.status = readiness.afterEvent(runtime.status, .document_loaded, false);
            if (runtime.status != .failed) if (tab) |value| {
                value.loading = false;
                value.load_failed = false;
            };
        },
        .eval_result => |result| {
            if (!runtime.consumeSuppressedEvalResult()) runtime.setLastEvalResult(result) catch {};
        },
        .failed => |message| {
            runtime.status = .failed;
            runtime.setLastError(message) catch {};
            if (tab) |value| {
                value.loading = false;
                value.load_failed = true;
            }
        },
        .js_message => |message| {
            // Preserve ordinary bridge results without executing privileged UI actions.
            if (std.mem.indexOf(u8, message, "\"source\":\"verde-browser-clipboard\"") != null or
                std.mem.indexOf(u8, message, "\"source\":\"verde-inspector\"") != null) return false;
            if (bridge_policy.allowsHostMessaging(runtime.current_url orelse runtime.addressInput())) {
                runtime.setLastJsMessage(message) catch {};
            } else {
                runtime.setLastError("Browser bridge message rejected by origin policy.") catch {};
            }
        },
        .cursor_changed, .context_menu, .context_menu_dismissed => {},
    }
    return false;
}
