//! Document readiness transitions shared by browser lifecycle event handling.

const std = @import("std");
const Status = @import("types.zig").Status;

pub const Event = enum { opened, navigated, document_loaded };

/// Visibility and URI notifications do not complete a pending navigation.
/// A URI notification can also be a same-document history change, which must
/// not make an already usable document wait for a load event that never comes.
pub fn afterEvent(status: Status, event: Event, document_loading: bool) Status {
    if (status == .failed) return .failed;
    return switch (event) {
        .opened => if (document_loading) .opening else .ready,
        .navigated => if (status == .opening) .opening else .ready,
        .document_loaded => if (status == .hidden) .hidden else .ready,
    };
}

test "restart then reset stays opening until each replacement document loads" {
    var status: Status = .ready;
    for (0..2) |_| {
        status = .opening;
        // A cold runtime may report visibility before or after its URI.
        for ([_]Event{ .opened, .navigated, .opened }) |event| {
            status = afterEvent(status, event, true);
            try std.testing.expectEqual(Status.opening, status);
        }
        status = afterEvent(status, .document_loaded, true);
        try std.testing.expectEqual(Status.ready, status);
    }
}

test "showing a loaded document and same-document navigation remain ready" {
    try std.testing.expectEqual(Status.ready, afterEvent(.opening, .opened, false));
    try std.testing.expectEqual(Status.ready, afterEvent(.ready, .navigated, false));
}

test "late lifecycle events cannot erase a navigation failure" {
    for ([_]Event{ .opened, .navigated, .document_loaded }) |event| {
        try std.testing.expectEqual(Status.failed, afterEvent(.failed, event, false));
    }
}

test "load completion after closing does not reopen the runtime" {
    try std.testing.expectEqual(Status.hidden, afterEvent(.hidden, .document_loaded, true));
}
