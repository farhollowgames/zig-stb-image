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

test "fuzz: short random inputs fail as in the original" {
    const inputs = [_][]const u8{ "", "\x89PNG", "\xff\xd8\xff", "BM", "GIF89a", "8BPS", "P5\n" };
    try @import("fuzz.zig").run(gpa, .{ .name = "short inputs", .seed = 0x5eed_0001 }, &inputs);
}
