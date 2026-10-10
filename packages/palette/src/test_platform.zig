//! Test root for the platform (Wayland) workstream: `zig build test-wayland`.
//! Lives in src/ so platform code can import ../event.zig within one module.
test {
    _ = @import("platform/root.zig");
}
