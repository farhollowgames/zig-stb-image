//! Builds PNG files for the tests: chunks with their lengths and CRCs
//! (either may be overridden), and images of random filtered rows of any
//! colour type, bit depth and size, interlaced or not. Test-only code.

const std = @import("std");
const deflate = @import("deflate.zig");

pub const signature = "\x89PNG\r\n\x1a\n";

pub const Chunk = struct {
    kind: *const [4]u8,
    data: []const u8 = "",
    /// Written in place of the data's length.
    length: ?u32 = null,
    /// Written in place of the right CRC.
    crc: ?u32 = null,
};

/// The signature and `chunks`; the caller frees the result.
pub fn file(gpa: std.mem.Allocator, chunks: []const Chunk) ![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(gpa);
    try bytes.appendSlice(gpa, signature);
    for (chunks) |chunk| {
        var word: [4]u8 = undefined;
        std.mem.writeInt(u32, &word, chunk.length orelse @intCast(chunk.data.len), .big);
        try bytes.appendSlice(gpa, &word);
        try bytes.appendSlice(gpa, chunk.kind);
        try bytes.appendSlice(gpa, chunk.data);
        var crc: std.hash.Crc32 = .init();
        crc.update(chunk.kind);
        crc.update(chunk.data);
        std.mem.writeInt(u32, &word, chunk.crc orelse crc.final(), .big);
        try bytes.appendSlice(gpa, &word);
    }
    return bytes.toOwnedSlice(gpa);
}

pub const Image = struct {
    width: u32,
    height: u32,
    depth: u8 = 8,
    color: u8 = 0,
    interlace: bool = false,
};

pub fn ihdr(image: Image) [13]u8 {
    var data: [13]u8 = undefined;
    std.mem.writeInt(u32, data[0..4], image.width, .big);
    std.mem.writeInt(u32, data[4..8], image.height, .big);
    data[8] = image.depth;
    data[9] = image.color;
    data[10] = 0;
    data[11] = 0;
    data[12] = @intFromBool(image.interlace);
    return data;
}

/// The samples per pixel of a colour type.
pub fn channels(color: u8) u32 {
    return switch (color) {
        0, 3 => 1,
        2 => 3,
        4 => 2,
        6 => 4,
        else => 1,
    };
}

const x_origin = [7]u32{ 0, 4, 0, 2, 0, 1, 0 };
const y_origin = [7]u32{ 0, 0, 4, 0, 2, 0, 1 };
const x_spacing = [7]u32{ 8, 8, 4, 4, 2, 2, 1 };
const y_spacing = [7]u32{ 8, 8, 8, 4, 4, 2, 2 };

/// The size of each pass, or the one image when not interlaced.
pub fn passes(image: Image) [7][2]u32 {
    var sizes: [7][2]u32 = @splat(.{ 0, 0 });
    if (!image.interlace) {
        sizes[0] = .{ image.width, image.height };
        return sizes;
    }
    for (&sizes, 0..) |*size, p| {
        size.* = .{
            (image.width + x_spacing[p] - 1 - x_origin[p]) / x_spacing[p],
            (image.height + y_spacing[p] - 1 - y_origin[p]) / y_spacing[p],
        };
    }
    return sizes;
}

/// The bytes of one row of `width` pixels.
pub fn rowBytes(image: Image, width: u32) usize {
    return (@as(usize, channels(image.color)) * width * image.depth + 7) / 8;
}

/// Random rows, each after a filter byte that cycles through the five
/// filters from `filter_offset` (or is `filter` for every row).
pub fn rawData(
    gpa: std.mem.Allocator,
    rng: std.Random,
    image: Image,
    filter_offset: usize,
    filter: ?u8,
) ![]u8 {
    var raw: std.ArrayList(u8) = .empty;
    errdefer raw.deinit(gpa);
    var row: usize = 0;
    for (passes(image)) |size| {
        if (size[0] == 0 or size[1] == 0) continue;
        const len = rowBytes(image, size[0]);
        for (0..size[1]) |_| {
            try raw.append(gpa, filter orelse @intCast((row + filter_offset) % 5));
            row += 1;
            const start = raw.items.len;
            try raw.resize(gpa, start + len);
            rng.bytes(raw.items[start..]);
        }
    }
    return raw.toOwnedSlice(gpa);
}

pub const Options = struct {
    plte: ?[]const u8 = null,
    trns: ?[]const u8 = null,
    /// An iPhone PNG: a CgBI chunk first, and raw DEFLATE data.
    cgbi: bool = false,
    kind: deflate.BlockKind = .dynamic,
    filter_offset: usize = 0,
    filter: ?u8 = null,
};

/// A whole PNG of `image` with random pixels. For palette images without
/// a `plte`, a full palette of `2^depth` random entries.
pub fn random(gpa: std.mem.Allocator, rng: std.Random, image: Image, options: Options) ![]u8 {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var chunks: std.ArrayList(Chunk) = .empty;
    if (options.cgbi) try chunks.append(arena, .{ .kind = "CgBI", .data = "\x50\x00\x20\x06" });
    const header = try arena.dupe(u8, &ihdr(image));
    try chunks.append(arena, .{ .kind = "IHDR", .data = header });
    if (options.plte) |plte| {
        try chunks.append(arena, .{ .kind = "PLTE", .data = plte });
    } else if (image.color == 3) {
        const entries = @as(usize, 1) << @intCast(@min(image.depth, 8));
        const plte = try arena.alloc(u8, entries * 3);
        rng.bytes(plte);
        try chunks.append(arena, .{ .kind = "PLTE", .data = plte });
    }
    if (options.trns) |trns| try chunks.append(arena, .{ .kind = "tRNS", .data = trns });
    const raw = try rawData(arena, rng, image, options.filter_offset, options.filter);
    const compressed = try deflate.compress(arena, raw, .{ .zlib = !options.cgbi, .kind = options.kind });
    try chunks.append(arena, .{ .kind = "IDAT", .data = compressed });
    try chunks.append(arena, .{ .kind = "IEND" });
    return file(gpa, chunks.items);
}
