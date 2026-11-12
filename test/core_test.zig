//! What every format shares: detection, the failure for unknown input,
//! empty input, and the readers.

const std = @import("std");
const oracle = @import("oracle.zig");

const gpa = std.testing.allocator;

test "unknown and empty inputs fail as in the original" {
    const inputs = [_][]const u8{ "", "x", "not an image at all", &@as([300]u8, @splat(0)) };
    for (inputs) |bytes| {
        try oracle.expectAllSame(gpa, bytes, .{ .name = "unknown" });
    }
}
