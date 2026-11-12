//! The differential tests: the original from `reference/` and the port on
//! the same inputs.

const std = @import("std");
const stbi = @import("stb_image");
const oracle = @import("oracle.zig");
const fuzz_options = @import("fuzz_options");

test {
    _ = @import("core_test.zig");
    _ = @import("file_test.zig");
    _ = @import("limits_test.zig");
    _ = @import("zlib_test.zig");
    _ = @import("png_test.zig");
    _ = @import("settings_test.zig");
    // The pow tests call only the C library, which the sanitizer run does
    // not check.
    if (!fuzz_options.sanitize) _ = @import("pow_test.zig");
    _ = @import("hdr_test.zig");
    _ = @import("gif_test.zig");
    _ = @import("pic_test.zig");
    _ = @import("bmp_test.zig");
    _ = @import("tga_test.zig");
    _ = @import("psd_test.zig");
    _ = @import("pnm_test.zig");
    _ = @import("jpeg_test.zig");
}
