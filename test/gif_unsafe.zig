//! The GIF fuzz cases the original is unsafe on: animations with a
//! frame that restores the one before last, or of no pixels with several
//! frames.
//! The cases at the default fuzz seed the port refuses for these reasons.

const fuzz = @import("fuzz.zig");

pub const unsafe: []const fuzz.Unsafe = &cases(.gif, &.{
    2,    143,  247,  272,  324,  568,  834,  846,  866,  954,  974,  1035,
    1132, 1227, 1290, 1304, 1322, 1353, 1359, 1687, 1798, 1882, 1923, 1937,
    1957,
});

fn cases(comptime call: fuzz.Call, comptime numbers: []const u32) [numbers.len]fuzz.Unsafe {
    var list: [numbers.len]fuzz.Unsafe = undefined;
    for (&list, numbers) |*entry, number| entry.* = .{ .case = number, .call = call };
    return list;
}
