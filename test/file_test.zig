//! Loads and queries by path, and from files through readers that cannot
//! seek. `oracle.expectAll` compares both with the original on every file
//! it is given; these tests check them on files with bytes after the image,
//! as most real files have, and on each query by path.

const std = @import("std");
const stbi = @import("stb_image");
const png_file = @import("png_file.zig");

const gpa = std.testing.allocator;
const io = std.testing.io;

/// A 16 x 16 binary PGM followed by 64 bytes the decoder never reads.
fn pgm(comptime max: []const u8, comptime sample_bytes: usize) [15 + max.len + 256 * sample_bytes + 64]u8 {
    var bytes: [15 + max.len + 256 * sample_bytes + 64]u8 = undefined;
    const header = "P5\n16 16\n" ++ max ++ "\n";
    @memcpy(bytes[0..header.len], header);
    for (bytes[header.len..], 0..) |*b, i| b.* = @truncate(i * 7);
    return bytes;
}

/// An 8 x 8 RGB PNG.
fn png() ![]u8 {
    var prng: std.Random.DefaultPrng = .init(1);
    return png_file.random(gpa, prng.random(), .{ .width = 8, .height = 8, .color = 2 }, .{});
}

fn writeTmp(tmp: *std.testing.TmpDir, name: []const u8, data: []const u8) !void {
    try tmp.dir.writeFile(io, .{ .sub_path = name, .data = data });
}

test "files: loadFromPath decodes a PGM with bytes after it as loadFromMemory does" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bytes = pgm("255", 1);
    try writeTmp(&tmp, "a.pgm", &bytes);
    var expected = try stbi.loadFromMemory(u8, gpa, &bytes, .{});
    defer expected.deinit(gpa);
    var image = try stbi.loadFromPath(u8, gpa, io, tmp.dir, "a.pgm", .{});
    defer image.deinit(gpa);
    try std.testing.expectEqualSlices(u8, expected.pixels, image.pixels);
}

test "files: loadFromPath decodes 16-bit samples" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bytes = pgm("65535", 2);
    try writeTmp(&tmp, "a.pgm", &bytes);
    var expected = try stbi.loadFromMemory(u16, gpa, &bytes, .{});
    defer expected.deinit(gpa);
    var image = try stbi.loadFromPath(u16, gpa, io, tmp.dir, "a.pgm", .{});
    defer image.deinit(gpa);
    try std.testing.expectEqualSlices(u16, expected.pixels, image.pixels);
}

test "files: infoFromPath gives the size" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bytes = pgm("255", 1);
    try writeTmp(&tmp, "a.pgm", &bytes);
    const info = try stbi.infoFromPath(io, tmp.dir, "a.pgm");
    try std.testing.expectEqual(16, info.width);
    try std.testing.expectEqual(16, info.height);
    try std.testing.expectEqual(1, info.channels_in_file);
}

test "files: is16BitFromPath sees a 16-bit PGM" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bytes = pgm("65535", 2);
    try writeTmp(&tmp, "a.pgm", &bytes);
    try std.testing.expect(try stbi.is16BitFromPath(io, tmp.dir, "a.pgm"));
}

test "files: isHdrFromPath sees an HDR file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const header = "#?RADIANCE\nFORMAT=32-bit_rle_rgbe\n\n-Y 1 +X 1\n";
    const bytes = header ++ [_]u8{ 128, 128, 128, 129 } ++ @as([200]u8, @splat(0));
    try writeTmp(&tmp, "a.hdr", bytes);
    try std.testing.expect(stbi.isHdrFromMemory(bytes));
    try std.testing.expect(stbi.isHdrFromPath(io, tmp.dir, "a.hdr"));
}

test "files: loadFromPath decodes a PNG as loadFromMemory does" {
    const bytes = try png();
    defer gpa.free(bytes);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTmp(&tmp, "a.png", bytes);
    var expected = try stbi.loadFromMemory(u8, gpa, bytes, .{});
    defer expected.deinit(gpa);
    var image = try stbi.loadFromPath(u8, gpa, io, tmp.dir, "a.png", .{});
    defer image.deinit(gpa);
    try std.testing.expectEqualSlices(u8, expected.pixels, image.pixels);
}

test "files: loadFromPath decodes a PNG followed by bytes it does not read" {
    const image_bytes = try png();
    defer gpa.free(image_bytes);
    const bytes = try std.mem.concat(gpa, u8, &.{ image_bytes, "trailing bytes the decoder never reads" });
    defer gpa.free(bytes);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTmp(&tmp, "a.png", bytes);
    var expected = try stbi.loadFromMemory(u8, gpa, bytes, .{});
    defer expected.deinit(gpa);
    var image = try stbi.loadFromPath(u8, gpa, io, tmp.dir, "a.png", .{});
    defer image.deinit(gpa);
    try std.testing.expectEqualSlices(u8, expected.pixels, image.pixels);
}

test "files: loadFromFile and the file queries on a reader that cannot seek give their results" {
    // As the original's calls on a pipe, whose `fseek` back fails and is
    // ignored.
    const image_bytes = try png();
    defer gpa.free(image_bytes);
    const bytes = try std.mem.concat(gpa, u8, &.{ image_bytes, "trailing bytes" });
    defer gpa.free(bytes);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTmp(&tmp, "a.png", bytes);
    var expected = try stbi.loadFromMemory(u8, gpa, bytes, .{});
    defer expected.deinit(gpa);
    var buffer: [512]u8 = undefined;
    for (0..4) |call| {
        const file = try tmp.dir.openFile(io, "a.png", .{});
        defer file.close(io);
        var reader = file.readerStreaming(io, &buffer);
        switch (call) {
            0 => {
                var image = try stbi.loadFromFile(u8, gpa, &reader, .{});
                defer image.deinit(gpa);
                try std.testing.expectEqualSlices(u8, expected.pixels, image.pixels);
            },
            1 => try std.testing.expectEqual(8, (try stbi.infoFromFile(&reader)).width),
            2 => try std.testing.expect(!try stbi.is16BitFromFile(&reader)),
            3 => try std.testing.expect(!try stbi.isHdrFromFile(&reader)),
            else => unreachable,
        }
    }
}
