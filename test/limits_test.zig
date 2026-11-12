//! `Limits.bytes_max` on the formats whose size checks it moves: BMP, TGA,
//! PSD and PNM. The original's limit is `INT_MAX`; a file whose image
//! passes it fails there before anything is allocated. With a smaller
//! `bytes_max`, a file whose image passes that limit must fail as the
//! original fails one past `INT_MAX`, and a file at the limit must load.

const std = @import("std");
const stbi = @import("stb_image");
const oracle = @import("oracle.zig");

const gpa = std.testing.allocator;

const Format = enum { bmp, tga, psd, pnm };

/// A `width` x `height` RGB image with its pixel data, or only its header
/// when `with_pixels` is false.
fn image(arena: std.mem.Allocator, format: Format, width: u32, height: u32, with_pixels: bool) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    const pixels = @as(usize, width) * height;
    switch (format) {
        .bmp => {
            const stride = (@as(usize, width) * 3 + 3) / 4 * 4;
            try w.writeAll("BM");
            try w.writeInt(u32, @truncate(54 + stride * height), .little);
            try w.writeInt(u32, 0, .little);
            try w.writeInt(u32, 54, .little);
            try w.writeInt(u32, 40, .little);
            try w.writeInt(i32, @intCast(width), .little);
            try w.writeInt(i32, @intCast(height), .little);
            try w.writeInt(u16, 1, .little);
            try w.writeInt(u16, 24, .little);
            for (0..6) |_| try w.writeInt(u32, 0, .little);
            if (with_pixels) {
                for (0..stride * height) |i| try w.writeByte(@truncate(i * 13));
            }
        },
        .tga => {
            try w.writeAll(&.{ 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0 });
            try w.writeInt(u16, @intCast(width), .little);
            try w.writeInt(u16, @intCast(height), .little);
            try w.writeAll(&.{ 24, 0 });
            if (with_pixels) {
                for (0..pixels * 3) |i| try w.writeByte(@truncate(i * 13));
            }
        },
        .psd => {
            try w.writeAll("8BPS");
            try w.writeInt(u16, 1, .big);
            try w.writeAll(&@as([6]u8, @splat(0)));
            try w.writeInt(u16, 3, .big);
            try w.writeInt(u32, height, .big);
            try w.writeInt(u32, width, .big);
            try w.writeInt(u16, 8, .big);
            try w.writeInt(u16, 3, .big);
            for (0..3) |_| try w.writeInt(u32, 0, .big);
            try w.writeInt(u16, 0, .big);
            if (with_pixels) {
                for (0..pixels * 3) |i| try w.writeByte(@truncate(i * 13));
            }
        },
        .pnm => {
            try w.print("P6\n{d} {d}\n255\n", .{ width, height });
            if (with_pixels) {
                for (0..pixels * 3) |i| try w.writeByte(@truncate(i * 13));
            }
        },
    }
    return out.written();
}

/// The bytes of the buffer the format checks against the limit, for an RGB
/// image: PSD decodes to 4 components first.
fn checkedBytes(format: Format, width: u32, height: u32) u64 {
    const comp: u64 = if (format == .psd) 4 else 3;
    return comp * width * height;
}

test "Limits.bytes_max: BMP, TGA, PSD and PNM past the limit fail as the original past INT_MAX" {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for (std.enums.values(Format)) |format| {
        const label: oracle.Label = .{ .name = @tagName(format) };
        // Past `INT_MAX`, within the dimension limit: the original's own
        // limit, which the port's default is.
        const huge = try image(arena, format, 0xffff, 0xb000, false);
        try std.testing.expect(checkedBytes(format, 0xffff, 0xb000) > std.math.maxInt(i32));
        try oracle.expectLoadSame(gpa, huge, .{}, label, .same);
        const past_int_max = stbi.loadFromMemory(u8, gpa, huge, .{});
        try std.testing.expect(std.meta.isError(past_int_max));
        const expected = if (past_int_max) |_| unreachable else |err| err;

        const width = 13;
        const height = 5;
        const bytes = try image(arena, format, width, height, true);
        const at_limit = checkedBytes(format, width, height);
        var full = try stbi.loadFromMemory(u8, gpa, bytes, .{});
        defer full.deinit(gpa);
        var limited = try stbi.loadFromMemory(u8, gpa, bytes, .{ .limits = .{ .bytes_max = at_limit } });
        defer limited.deinit(gpa);
        try std.testing.expectEqualSlices(u8, full.pixels, limited.pixels);
        try std.testing.expectError(
            expected,
            stbi.loadFromMemory(u8, gpa, bytes, .{ .limits = .{ .bytes_max = at_limit - 1 } }),
        );
    }
}

test "Limits.bytes_max: a conversion to more components is checked against the limit" {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // TGA, PSD and PNM decode to the file's components and then convert,
    // through `stbi__convert_format`'s checked allocation, which fails as
    // out of memory.
    for ([_]Format{ .tga, .pnm }) |format| {
        const bytes = try image(arena, format, 13, 5, true);
        const rgb = 3 * 13 * 5;
        const rgba = 4 * 13 * 5;
        var converted = try stbi.loadFromMemory(u8, gpa, bytes, .{
            .components = .rgba,
            .limits = .{ .bytes_max = rgba },
        });
        converted.deinit(gpa);
        try std.testing.expectError(error.OutOfMemory, stbi.loadFromMemory(u8, gpa, bytes, .{
            .components = .rgba,
            .limits = .{ .bytes_max = rgba - 1 },
        }));
        // The file's own size passes the check.
        var own = try stbi.loadFromMemory(u8, gpa, bytes, .{ .limits = .{ .bytes_max = rgb } });
        own.deinit(gpa);
    }
}

const deflate = @import("deflate.zig");
const png_file = @import("png_file.zig");

/// Records the largest block asked of it.
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
        l.largest = @max(l.largest, n);
        return l.child.rawResize(m, a, n, ra);
    }

    fn remap(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, n: usize, ra: usize) ?[*]u8 {
        const l: *Largest = @ptrCast(@alignCast(ctx));
        l.largest = @max(l.largest, n);
        return l.child.rawRemap(m, a, n, ra);
    }

    fn free(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, ra: usize) void {
        const l: *Largest = @ptrCast(@alignCast(ctx));
        l.child.rawFree(m, a, ra);
    }
};

test "Limits.bytes_max: a PNG's inflated data grows past it, as the original's grows past INT_MAX" {
    // A 1 x 1 grey PNG whose IDAT inflates to 8 MiB: a literal, then
    // matches of 258 at distance 1. The original keeps more pixel data
    // than the image needs, and so does the port.
    var w: deflate.BitWriter = .init(gpa);
    defer w.deinit();
    try w.byte(0x78);
    try w.byte(0x01);
    try w.bits(1, 1); // final
    try w.bits(1, 2); // fixed Huffman
    try w.code(0x30, 8); // literal 0
    for (0..(8 << 20) / 258) |_| {
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
    try oracle.expectLoadSame(gpa, bytes, .{}, .{ .name = "8 MiB inflate" }, .same);

    var largest: Largest = .{ .child = gpa };
    const limit = 1 << 20;
    var loaded = try stbi.loadFromMemory(u8, largest.allocator(), bytes, .{
        .limits = .{ .bytes_max = limit },
    });
    defer loaded.deinit(largest.allocator());
    try std.testing.expect(largest.largest > limit);
}
