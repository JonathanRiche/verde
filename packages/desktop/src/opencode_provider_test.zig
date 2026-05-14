const std = @import("std");
const opencode = @import("providers/opencode.zig");

test "compile OpenCode provider declarations" {
    std.testing.refAllDecls(opencode);
}
