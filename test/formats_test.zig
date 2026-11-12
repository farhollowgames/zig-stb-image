//! The format switches (`-Djpeg=false` and so on), run on builds of the
//! port with some formats left out: a file of a format left out is never
//! detected, so it fails as an unknown image type, and the files of the
//! formats built in still load.

const std = @import("std");
const stbi = @import("stb_image");
const corpus_paths = @import("corpus_paths");
const png_file = @import("png_file.zig");

const gpa = std.testing.allocator;

const Format = enum { jpeg, png, bmp, tga, psd, gif, hdr, pic, pnm };

fn enabled(format: Format) bool {
    return switch (format) {
        inline else => |f| @field(stbi.formats, @tagName(f)),
    };
}

/// A small file of `format`; JPEG's comes from the test corpus.
fn sample(arena: std.mem.Allocator, format: Format) ![]const u8 {
    switch (format) {
        .jpeg => {
            const path = try std.fs.path.join(arena, &.{
                corpus_paths.jpeg_decoder,
                "tests/reftest/images/progressive3.jpg",
            });
            return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, arena, .limited(1 << 20));
        },
        .png => {
            var prng: std.Random.DefaultPrng = .init(3);
            return png_file.random(arena, prng.random(), .{ .width = 3, .height = 2, .color = 2 }, .{});
        },
        .bmp => return comptime "BM" ++ le32(54 + 8) ++ le32(0) ++ le32(54) ++ le32(40) ++ le32(2) ++
            le32(1) ++ "\x01\x00\x18\x00" ++ @as([24]u8, @splat(0)) ++ "\x10\x20\x30\x40\x50\x60\x00\x00",
        .tga => return "\x00\x00\x02" ++ @as([9]u8, @splat(0)) ++ "\x02\x00\x01\x00\x18\x00" ++
            "\x10\x20\x30\x40\x50\x60",
        .psd => return comptime "8BPS\x00\x01" ++ @as([6]u8, @splat(0)) ++ "\x00\x03" ++ be32(1) ++ be32(2) ++
            "\x00\x08\x00\x03" ++ @as([12]u8, @splat(0)) ++ "\x00\x00" ++ "\x10\x20\x30\x40\x50\x60",
        // A 1 x 1 GIF with a two-colour palette.
        .gif => return "GIF89a\x01\x00\x01\x00\x80\x00\x00\x00\x00\x00\xff\xff\xff" ++
            ",\x00\x00\x00\x00\x01\x00\x01\x00\x00\x02\x02\x44\x01\x00;",
        .hdr => return "#?RADIANCE\nFORMAT=32-bit_rle_rgbe\n\n-Y 1 +X 2\n" ++
            "\x80\x40\x20\x81\x10\x20\x30\x82",
        // A 1 x 1 PIC: the header, one uncompressed RGBA packet, one pixel.
        .pic => return "\x53\x80\xf6\x34" ++ @as([84]u8, @splat(0)) ++ "PICT" ++ "\x00\x01\x00\x01" ++
            @as([8]u8, @splat(0)) ++ "\x00\x08\x00\xf0" ++ "\x10\x20\x30\x40",
        .pnm => return "P6\n2 1\n255\n\x10\x20\x30\x40\x50\x60",
    }
}

fn le32(comptime value: u32) [4]u8 {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .little);
    return bytes;
}

fn be32(comptime value: u32) [4]u8 {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .big);
    return bytes;
}

test "formats: a format left out of the build fails as an unknown image type, the others load" {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for (std.enums.values(Format)) |format| {
        const bytes = try sample(arena, format);
        expectFormat(format, bytes) catch |err| {
            std.debug.print("\n[{t}] built in: {}: {t}\n", .{ format, enabled(format), err });
            return err;
        };
    }
}

fn expectFormat(format: Format, bytes: []const u8) !void {
    if (enabled(format)) {
        var image = try stbi.loadFromMemory(u8, gpa, bytes, .{});
        image.deinit(gpa);
        var floats = try stbi.loadFromMemory(f32, gpa, bytes, .{});
        floats.deinit(gpa);
        _ = try stbi.infoFromMemory(bytes);
        try std.testing.expectEqual(format == .hdr, stbi.isHdrFromMemory(bytes));
    } else {
        try std.testing.expectError(error.UnknownImageType, stbi.loadFromMemory(u8, gpa, bytes, .{}));
        try std.testing.expectError(error.UnknownImageType, stbi.loadFromMemory(u16, gpa, bytes, .{}));
        try std.testing.expectError(error.UnknownImageType, stbi.loadFromMemory(f32, gpa, bytes, .{}));
        try std.testing.expectError(error.UnknownImageType, stbi.infoFromMemory(bytes));
        try std.testing.expect(!stbi.isHdrFromMemory(bytes));
        try std.testing.expect(!stbi.is16BitFromMemory(bytes));
    }
}
