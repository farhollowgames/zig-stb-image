//! Probes by the skeptic: inputs and calls that try to break the port's
//! claims. Each test states what the claim says should happen.

const std = @import("std");
const stbi = @import("stb_image");

const gpa = std.testing.allocator;
const io = std.testing.io;

/// A 16 x 16 binary PGM followed by bytes the decoder never reads, as most
/// real files have (a PNG's last CRC, say).
fn pgm(comptime max: []const u8, comptime sample_bytes: usize) [15 + max.len + 256 * sample_bytes + 64]u8 {
    var bytes: [15 + max.len + 256 * sample_bytes + 64]u8 = undefined;
    const header = "P5\n16 16\n" ++ max ++ "\n";
    @memcpy(bytes[0..header.len], header);
    for (bytes[header.len..], 0..) |*b, i| b.* = @truncate(i * 7);
    return bytes;
}

fn writeTmp(tmp: *std.testing.TmpDir, name: []const u8, data: []const u8) !void {
    try tmp.dir.writeFile(io, .{ .sub_path = name, .data = data });
}

test "skeptic: loadFromPath decodes a file as loadFromMemory does" {
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

test "skeptic: loadFromPath decodes 16-bit samples" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bytes = pgm("65535", 2);
    try writeTmp(&tmp, "a.pgm", &bytes);
    var image = try stbi.loadFromPath(u16, gpa, io, tmp.dir, "a.pgm", .{});
    defer image.deinit(gpa);
}

test "skeptic: infoFromPath gives the size" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bytes = pgm("255", 1);
    try writeTmp(&tmp, "a.pgm", &bytes);
    const info = try stbi.infoFromPath(io, tmp.dir, "a.pgm");
    try std.testing.expectEqual(16, info.width);
}

test "skeptic: is16BitFromPath sees a 16-bit PGM" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bytes = pgm("65535", 2);
    try writeTmp(&tmp, "a.pgm", &bytes);
    try std.testing.expect(try stbi.is16BitFromPath(io, tmp.dir, "a.pgm"));
}

test "skeptic: isHdrFromPath sees an HDR file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const header = "#?RADIANCE\nFORMAT=32-bit_rle_rgbe\n\n-Y 1 +X 1\n";
    const bytes = header ++ [_]u8{ 128, 128, 128, 129 } ++ @as([200]u8, @splat(0));
    try writeTmp(&tmp, "a.hdr", bytes);
    try std.testing.expect(stbi.isHdrFromMemory(bytes));
    try std.testing.expect(stbi.isHdrFromPath(io, tmp.dir, "a.hdr"));
}

const png_file = @import("png_file.zig");

test "skeptic: loadFromPath decodes a PNG as loadFromMemory does" {
    var prng: std.Random.DefaultPrng = .init(1);
    const bytes = try png_file.random(gpa, prng.random(), .{ .width = 8, .height = 8, .color = 2 }, .{});
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

test "skeptic: loadFromFile on a streaming reader decodes a PNG, as stbi_load_from_file on a pipe does" {
    var prng: std.Random.DefaultPrng = .init(1);
    const bytes = try png_file.random(gpa, prng.random(), .{ .width = 8, .height = 8, .color = 2 }, .{});
    defer gpa.free(bytes);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTmp(&tmp, "a.png", bytes);
    const file = try tmp.dir.openFile(io, "a.png", .{});
    defer file.close(io);
    var buffer: [512]u8 = undefined;
    var reader = file.readerStreaming(io, &buffer);
    var image = try stbi.loadFromFile(u8, gpa, &reader, .{});
    defer image.deinit(gpa);
}


test "skeptic: loadFromPath decodes a PNG followed by bytes it does not read" {
    var prng: std.Random.DefaultPrng = .init(1);
    const image_bytes = try png_file.random(gpa, prng.random(), .{ .width = 8, .height = 8, .color = 2 }, .{});
    defer gpa.free(image_bytes);
    // A TGA 2.0 footer, the frames after a GIF's first, or any trailer
    // leave bytes in the last buffer the same way.
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
