//! The differential tests: the original from `reference/` and the port on
//! the same inputs.

const std = @import("std");
const stbi = @import("stb_image");
const oracle = @import("oracle.zig");

test {
    _ = @import("core_test.zig");
    _ = @import("bmp_test.zig");
    _ = @import("tga_test.zig");
    _ = @import("psd_test.zig");
    _ = @import("pnm_test.zig");
}
