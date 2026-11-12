//! The differential tests: the original from `reference/` and the port on
//! the same inputs.

const std = @import("std");
const stbi = @import("stb_image");
const oracle = @import("oracle.zig");

test {
    _ = @import("core_test.zig");
    _ = @import("pow_test.zig");
    _ = @import("hdr_test.zig");
    _ = @import("gif_test.zig");
    _ = @import("pic_test.zig");
}
