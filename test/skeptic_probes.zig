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

const deflate = @import("deflate.zig");

/// Records the largest single block asked of it.
const Largest = struct {
    child: std.mem.Allocator,
    largest: usize = 0,

    fn allocator(l: *Largest) std.mem.Allocator {
        return .{ .ptr = l, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }
    fn alloc(ctx: *anyopaque, len: usize, a: std.mem.Alignment, ra: usize) ?[*]u8 {
        const l: *Largest = @ptrCast(@alignCast(ctx));
        l.largest = @max(l.largest, len);
        return l.child.rawAlloc(len, a, ra);
    }
    fn resize(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, n: usize, ra: usize) bool {
        const l: *Largest = @ptrCast(@alignCast(ctx));
        const ok = l.child.rawResize(m, a, n, ra);
        if (ok) l.largest = @max(l.largest, n);
        return ok;
    }
    fn remap(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, n: usize, ra: usize) ?[*]u8 {
        const l: *Largest = @ptrCast(@alignCast(ctx));
        const p = l.child.rawRemap(m, a, n, ra);
        if (p != null) l.largest = @max(l.largest, n);
        return p;
    }
    fn free(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, ra: usize) void {
        const l: *Largest = @ptrCast(@alignCast(ctx));
        l.child.rawFree(m, a, ra);
    }
};

test "skeptic: Limits.bytes_max bounds what a PNG decode allocates" {
    // A 1x1 grey PNG whose IDAT inflates to about 64 MiB: one fixed-Huffman
    // block of a literal and then matches of 258 at distance 1.
    var w: deflate.BitWriter = .init(gpa);
    defer w.deinit();
    try w.byte(0x78);
    try w.byte(0x01);
    try w.bits(1, 1); // final
    try w.bits(1, 2); // fixed Huffman
    try w.code(0x30, 8); // literal 0
    for (0..(64 << 20) / 258) |_| {
        try w.code(0b11000101, 8); // length 258
        try w.code(0, 5); // distance 1
    }
    try w.code(0, 7); // end of block
    const stream = try w.finish();
    defer gpa.free(stream);
    const header = png_file.ihdr(.{ .width = 1, .height = 1 });
    const bytes = try png_file.file(gpa, &.{
        .{ .kind = "IHDR", .data = &header },
        .{ .kind = "IDAT", .data = stream },
        .{ .kind = "IEND" },
    });
    defer gpa.free(bytes);
    var largest: Largest = .{ .child = gpa };
    const limit = 1 << 20;
    var image = try stbi.loadFromMemory(u8, largest.allocator(), bytes, .{
        .limits = .{ .bytes_max = limit },
    });
    defer image.deinit(largest.allocator());
    std.debug.print("\nlargest block: {d} bytes, bytes_max {d}\n", .{ largest.largest, limit });
    try std.testing.expect(largest.largest <= limit);
}
