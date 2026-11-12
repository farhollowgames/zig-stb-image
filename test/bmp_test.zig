//! BMP against the original: bmpsuite and other test files, hand-made
//! files of every header size, bit depth and mask, and fuzzing.

const std = @import("std");
const stbi = @import("stb_image");
const oracle = @import("oracle.zig");
const fuzz = @import("fuzz.zig");
const corpus = @import("corpus.zig");
const fuzz_options = @import("fuzz_options");

const gpa = std.testing.allocator;

/// Corpus files with pixels naming palette entries the original never
/// reads: it takes them from uninitialized stack memory, the port reads them
/// as zero. Among them every OS/2 file with a palette: the original reads
/// four entries fewer than such a file holds, none of a 1-bit palette.
const unset_entries = [_][]const u8{
    "tests/images/bmp/images/Core_1_Bit.bmp",
    "tests/images/bmp/images/Core_4_Bit.bmp",
    "tests/images/bmp/images/Core_8_Bit.bmp",
    "tests/images/bmp/images/pal8badindex.bmp",
    "tests/images/bmp/images/pal8os2sp.bmp",
};

fn namesUnsetEntries(name: []const u8) bool {
    for (unset_entries) |entry| {
        if (std.mem.eql(u8, entry, name)) return true;
    }
    return false;
}

fn corpusFiles() !corpus.Set {
    var bmpsuite = try corpus.load(gpa, std.testing.io, .image_rs, "tests/images/bmp", &.{".bmp"});
    defer bmpsuite.deinit(gpa);
    var turbo = try corpus.load(gpa, std.testing.io, .libjpeg_turbo, "testimages", &.{".bmp"});
    defer turbo.deinit(gpa);
    const entries = try gpa.alloc(corpus.Entry, bmpsuite.entries.len + turbo.entries.len);
    @memcpy(entries[0..bmpsuite.entries.len], bmpsuite.entries);
    @memcpy(entries[bmpsuite.entries.len..], turbo.entries);
    gpa.free(bmpsuite.entries);
    gpa.free(turbo.entries);
    bmpsuite.entries = &.{};
    turbo.entries = &.{};
    return .{ .entries = entries };
}

test "every BMP test file decodes as in the original" {
    var set = try corpusFiles();
    defer set.deinit(gpa);
    try std.testing.expect(set.entries.len > 60);
    var failures: usize = 0;
    for (set.entries) |entry| {
        const expect: oracle.Expect = if (namesUnsetEntries(entry.name)) .same_size else .same;
        oracle.expectAll(gpa, entry.bytes, .{ .name = entry.name }, expect) catch {
            failures += 1;
        };
    }
    try std.testing.expectEqual(0, failures);
}

/// An uncompressed palette BMP as read from its bytes by this test, apart
/// from the port: the palette entries the original reads, and each pixel's
/// index, top row first.
const PaletteImage = struct {
    width: u32,
    height: u32,
    palette: [256][3]u8,
    /// The entries the original reads; it reads the others from
    /// uninitialized stack memory.
    entries: u32,
    indices: []u8,

    fn read(bytes: []const u8) !PaletteImage {
        const offset = std.mem.readInt(u32, bytes[10..14], .little);
        const header_size = std.mem.readInt(u32, bytes[14..18], .little);
        var image: PaletteImage = undefined;
        var stored_height: i32 = undefined;
        var bpp: u32 = undefined;
        if (header_size == 12) {
            image.width = std.mem.readInt(u16, bytes[18..20], .little);
            stored_height = std.mem.readInt(u16, bytes[20..22], .little);
            bpp = std.mem.readInt(u16, bytes[24..26], .little);
        } else {
            image.width = std.mem.readInt(u32, bytes[18..22], .little);
            stored_height = std.mem.readInt(i32, bytes[22..26], .little);
            bpp = std.mem.readInt(u16, bytes[28..30], .little);
            try std.testing.expectEqual(0, std.mem.readInt(u32, bytes[30..34], .little));
        }
        image.height = @abs(stored_height);
        // The original's palette size, which counts an OS/2 header as 24
        // bytes, not 12.
        const count: i64 = if (header_size == 12)
            @divTrunc(@as(i64, offset) - 14 - 24, 3)
        else
            (@as(i64, offset) - 14 - header_size) >> 2;
        image.entries = @intCast(std.math.clamp(count, 0, 256));
        const entry_size: usize = if (header_size == 12) 3 else 4;
        for (0..image.entries) |i| {
            const entry = bytes[14 + header_size + i * entry_size ..][0..3];
            image.palette[i] = .{ entry[2], entry[1], entry[0] };
        }
        const row_bytes = (@as(usize, image.width) * bpp + 31) / 32 * 4;
        try std.testing.expect(offset + row_bytes * image.height <= bytes.len);
        image.indices = try gpa.alloc(u8, @as(usize, image.width) * image.height);
        for (0..image.height) |y| {
            const stored_row = if (stored_height > 0) image.height - 1 - y else y;
            const row = bytes[offset + stored_row * row_bytes ..][0..row_bytes];
            for (0..image.width) |x| {
                const bit = x * bpp;
                const byte = row[bit / 8];
                const shift: u3 = @intCast(8 - bpp - bit % 8);
                const field_max = (@as(u32, 1) << @intCast(bpp)) - 1;
                image.indices[y * image.width + x] = @intCast((byte >> shift) & field_max);
            }
        }
        return image;
    }

    fn deinit(image: PaletteImage) void {
        gpa.free(image.indices);
    }

    /// The index of output pixel `i`, the rows flipped or not.
    fn index(image: PaletteImage, i: usize, flip: bool) u8 {
        if (!flip) return image.indices[i];
        const y = i / image.width;
        const x = i % image.width;
        return image.indices[(image.height - 1 - y) * image.width + x];
    }
};

test "the BMP test files naming unset palette entries read them as zero" {
    var set = try corpusFiles();
    defer set.deinit(gpa);
    var found: usize = 0;
    for (set.entries) |entry| {
        if (!namesUnsetEntries(entry.name)) continue;
        found += 1;
        const image = try PaletteImage.read(entry.bytes);
        defer image.deinit();
        var past: usize = 0;
        for (image.indices) |i| past += @intFromBool(i >= image.entries);
        try std.testing.expect(past > 0);

        // The port gives each read entry's colour and zero for the others,
        // opaque at four components.
        for ([_]stbi.Components{ .file, .rgb, .rgba }) |components| {
            for ([_]bool{ false, true }) |flip| {
                var loaded = try stbi.loadFromMemory(u8, gpa, entry.bytes, .{
                    .components = components,
                    .flip_vertically = flip,
                });
                defer loaded.deinit(gpa);
                const n = loaded.channels;
                for (0..image.indices.len) |i| {
                    const index = image.index(i, flip);
                    const read = index < image.entries;
                    const colour: [3]u8 = if (read) image.palette[index] else @splat(0);
                    const pixel = loaded.pixels[i * n ..][0..n];
                    try std.testing.expectEqualSlices(u8, &colour, pixel[0..3]);
                    if (n == 4) try std.testing.expectEqual(255, pixel[3]);
                }
            }
        }

        // Every pixel whose entry the original reads is the original's.
        if (fuzz_options.sanitize) continue;
        for (0..5) |comp| {
            for ([_]bool{ false, true }) |flip| {
                const request: oracle.Request = .{ .options = .{
                    .components = @fromBackingInt(@as(u3, @intCast(comp))),
                    .flip_vertically = flip,
                } };
                try expectReadEntriesSame(entry.bytes, request, image);
            }
        }
    }
    try std.testing.expectEqual(unset_entries.len, found);
}

/// Compares the port's 8-bit load with both builds of the original at the
/// pixels whose palette entry the original reads.
fn expectReadEntriesSame(bytes: []const u8, request: oracle.Request, image: PaletteImage) !void {
    var ours = try stbi.loadFromMemory(u8, gpa, bytes, request.options);
    defer ours.deinit(gpa);
    const n = ours.channels;
    const settings = request.settings();
    for ([_]oracle.Path{ .simd, .scalar }) |path| {
        var theirs: oracle.Result = undefined;
        oracle.loadFn(path)(bytes.ptr, bytes.len, 8, &settings, &theirs);
        defer oracle.freeFn(path)(theirs.pixels);
        try std.testing.expect(theirs.pixels != null);
        try std.testing.expectEqual(@as(c_int, @intCast(ours.width)), theirs.x);
        try std.testing.expectEqual(@as(c_int, @intCast(ours.height)), theirs.y);
        const original: [*]const u8 = @ptrCast(theirs.pixels.?);
        for (0..image.indices.len) |i| {
            if (image.index(i, request.options.flip_vertically) >= image.entries) continue;
            const pixel = ours.pixels[i * n ..][0..n];
            try std.testing.expectEqualSlices(u8, original[i * n ..][0..n], pixel);
        }
    }
}

/// Checks that every pixel of `bytes` loads as zero, opaque at four
/// components.
fn expectZeroPixels(bytes: []const u8) !void {
    for ([_]stbi.Components{ .rgb, .rgba }) |components| {
        var image = try stbi.loadFromMemory(u8, gpa, bytes, .{ .components = components });
        defer image.deinit(gpa);
        const n = image.channels;
        for (0..image.pixels.len / n) |i| {
            const pixel = image.pixels[i * n ..][0..n];
            try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0 }, pixel[0..3]);
            if (n == 4) try std.testing.expectEqual(255, pixel[3]);
        }
    }
}

// --------------------------------------------------------
// A small BMP writer
// --------------------------------------------------------

const Bmp = struct {
    header_size: u32 = 40,
    width: i32,
    height: i32,
    planes: u16 = 1,
    bpp: u16,
    compress: u32 = 0,
    /// Written after a 40 or 56-byte header with bit fields (the first
    /// three), and in every V4 and V5 header (all four).
    masks: [4]u32 = .{ 0, 0, 0, 0 },
    /// Palette entries, 3 bytes each after a 12-byte header, 4 otherwise.
    palette_entries: u32 = 0,
    /// Bytes between the palette and the pixels.
    gap: u32 = 0,
    /// The pixel data offset; by default where the pixels start.
    offset: ?u32 = null,
    /// The pixel rows as stored, padding included.
    pixels: []const u8,
    /// Zeros for the palette and the gap, instead of random bytes.
    zero_fill: bool = false,

    /// Where the pixels start.
    fn start(b: Bmp) u32 {
        const entry_size: u32 = if (b.header_size == 12) 3 else 4;
        var masks_size: u32 = 0;
        if ((b.header_size == 40 or b.header_size == 56) and b.compress == 3) masks_size = 12;
        const total = @as(u64, 14) + b.header_size + masks_size +
            @as(u64, b.palette_entries) * entry_size + b.gap;
        // An unknown header size gives an offset of any value.
        return @truncate(total);
    }
};

fn put(list: *std.ArrayList(u8), comptime T: type, value: T) !void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .little);
    try list.appendSlice(gpa, &bytes);
}

fn encodeBmp(b: Bmp, rng: std.Random) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(gpa);
    const entry_size: u32 = if (b.header_size == 12) 3 else 4;
    const masks_size: u32 = if ((b.header_size == 40 or b.header_size == 56) and b.compress == 3)
        12
    else
        0;
    const start = b.start();
    try list.appendSlice(gpa, "BM");
    try put(&list, u32, start + @as(u32, @intCast(b.pixels.len)));
    try put(&list, u32, 0);
    try put(&list, u32, b.offset orelse start);
    try put(&list, u32, b.header_size);
    if (b.header_size == 12) {
        try put(&list, u16, @truncate(@as(u32, @bitCast(b.width))));
        try put(&list, u16, @truncate(@as(u32, @bitCast(b.height))));
        try put(&list, u16, b.planes);
        try put(&list, u16, b.bpp);
    } else {
        try put(&list, i32, b.width);
        try put(&list, i32, b.height);
        try put(&list, u16, b.planes);
        try put(&list, u16, b.bpp);
        try put(&list, u32, b.compress);
        try put(&list, u32, @intCast(b.pixels.len));
        try put(&list, u32, 2835);
        try put(&list, u32, 2835);
        try put(&list, u32, b.palette_entries);
        try put(&list, u32, 0);
        if (b.header_size == 56) {
            for (b.masks) |mask| try put(&list, u32, mask);
        } else if (b.header_size >= 108) {
            for (b.masks) |mask| try put(&list, u32, mask);
            try put(&list, u32, 0x73524742); // sRGB
            for (0..12) |_| try put(&list, u32, rng.int(u32));
            if (b.header_size == 124) {
                for (0..4) |_| try put(&list, u32, 0);
            }
        }
        if (masks_size != 0) {
            for (b.masks[0..3]) |mask| try put(&list, u32, mask);
        }
    }
    for (0..b.palette_entries) |_| {
        var entry: [4]u8 = @splat(0);
        if (!b.zero_fill) rng.bytes(&entry);
        try list.appendSlice(gpa, entry[0..entry_size]);
    }
    for (0..b.gap) |_| try list.append(gpa, if (b.zero_fill) 0 else rng.int(u8));
    try list.appendSlice(gpa, b.pixels);
    return list.toOwnedSlice(gpa);
}

fn rowBytes(width: u32, bpp: u32) usize {
    return (@as(usize, width) * bpp + 31) / 32 * 4;
}

/// Random rows for a `width` by `height` image of `bpp` bits; palette
/// indices stay below `index_limit`.
fn randomPixels(rng: std.Random, width: u32, height: u32, bpp: u32, index_limit: u32) ![]u8 {
    const row = rowBytes(width, bpp);
    const pixels = try gpa.alloc(u8, row * height);
    rng.bytes(pixels);
    if (bpp < 16) {
        const per_byte = 8 / bpp;
        const field_max = (@as(u32, 1) << @intCast(bpp)) - 1;
        for (pixels) |*byte| {
            var value: u32 = 0;
            for (0..per_byte) |_| {
                const index = rng.uintLessThan(u32, @max(1, @min(index_limit, field_max + 1)));
                value = (value << @intCast(bpp)) | index;
            }
            byte.* = @intCast(value);
        }
    }
    return pixels;
}

fn expectBmp(b: Bmp, rng: std.Random, name: []const u8) !void {
    const bytes = try encodeBmp(b, rng);
    defer gpa.free(bytes);
    try oracle.expectAllSame(gpa, bytes, .{ .name = name });
}

test "every header size and bit depth decodes as in the original" {
    var prng: std.Random.DefaultPrng = .init(0xb3b0_0001);
    const rng = prng.random();
    const sizes = [_][2]u32{ .{ 1, 1 }, .{ 3, 2 }, .{ 7, 5 }, .{ 33, 3 } };
    for ([_]u32{ 12, 40, 56, 108, 124 }) |header_size| {
        for ([_]u16{ 1, 4, 8, 16, 24, 32 }) |bpp| {
            for (sizes) |size| {
                for ([_]bool{ false, true }) |top_down| {
                    const palette: u32 = if (bpp < 16) (@as(u32, 1) << @intCast(bpp)) else 0;
                    // The original reads four entries fewer from an OS/2
                    // header than it holds.
                    const extra: u32 = if (header_size == 12 and bpp < 16) 4 else 0;
                    const pixels = try randomPixels(rng, size[0], size[1], bpp, palette);
                    defer gpa.free(pixels);
                    const height: i32 = @intCast(size[1]);
                    try expectBmp(.{
                        .header_size = header_size,
                        .width = @intCast(size[0]),
                        .height = if (top_down and header_size != 12) -height else height,
                        .bpp = bpp,
                        .palette_entries = palette + extra,
                        .pixels = pixels,
                    }, rng, "header size and depth");
                }
            }
        }
    }
}

test "bit field masks of every width decode as in the original" {
    var prng: std.Random.DefaultPrng = .init(0xb3b0_0002);
    const rng = prng.random();
    const mask_sets = [_][4]u32{
        .{ 0xf800, 0x07e0, 0x001f, 0 }, // 565
        .{ 0x7c00, 0x03e0, 0x001f, 0x8000 }, // 1555
        .{ 0x0f00, 0x00f0, 0x000f, 0xf000 }, // 4444
        .{ 0x8000, 0x4000, 0x2000, 0x1000 }, // one bit each
        .{ 0xc000, 0x0003, 0x0300, 0x0030 }, // two bits each, out of order
        .{ 0x00ff0000, 0x0000ff00, 0x000000ff, 0xff000000 }, // the easy 32-bit case
        .{ 0x00ff0000, 0x0000ff00, 0x000000ff, 0 }, // no alpha
        .{ 0x000000ff, 0x0000ff00, 0x00ff0000, 0xff000000 }, // RGBA order
        .{ 0x3ff00000, 0x000ffc00, 0x000003ff, 0xc0000000 }, // 10 bits: refused
        .{ 0x80000001, 0x00010010, 0x01000100, 0 }, // scattered bits
        .{ 0x7f000000, 0x00fe0000, 0x0001fc00, 0x000003f8 }, // seven bits each
        .{ 0x00000001, 0x00000002, 0x00000004, 0x00000008 }, // low bits
        .{ 0, 0x0000ff00, 0x000000ff, 0 }, // a zero mask: refused
        .{ 0x00ff, 0x00ff, 0x00ff, 0 }, // equal masks: refused
        .{ 0xffffffff, 0xffffffff, 0x0000ffff, 0 }, // 32 bits: refused
    };
    for ([_]u32{ 40, 56, 108, 124 }) |header_size| {
        for ([_]u16{ 16, 32 }) |bpp| {
            for (mask_sets) |masks| {
                for ([_]bool{ false, true }) |zero_alpha| {
                    const pixels = try randomPixels(rng, 5, 3, bpp, 0);
                    defer gpa.free(pixels);
                    if (zero_alpha) {
                        // Alpha all zero, which the original shows opaque.
                        const alpha_mask = if (header_size >= 108) masks[3] else 0;
                        var i: usize = 0;
                        while (i + bpp / 8 <= pixels.len) : (i += bpp / 8) {
                            if (bpp == 16) {
                                const v = std.mem.readInt(u16, pixels[i..][0..2], .little);
                                const kept: u16 = @truncate(v & ~alpha_mask);
                                std.mem.writeInt(u16, pixels[i..][0..2], kept, .little);
                            } else {
                                const v = std.mem.readInt(u32, pixels[i..][0..4], .little);
                                std.mem.writeInt(u32, pixels[i..][0..4], v & ~alpha_mask, .little);
                            }
                        }
                    }
                    try expectBmp(.{
                        .header_size = header_size,
                        .width = 5,
                        .height = 3,
                        .bpp = bpp,
                        .compress = 3,
                        .masks = masks,
                        .pixels = pixels,
                    }, rng, "bit fields");
                }
            }
        }
    }
}

test "uncompressed 32-bit images with all-zero alpha decode opaque as in the original" {
    var prng: std.Random.DefaultPrng = .init(0xb3b0_0003);
    const rng = prng.random();
    for ([_]u32{ 40, 56, 108, 124 }) |header_size| {
        for ([_]bool{ false, true }) |zero_alpha| {
            const pixels = try randomPixels(rng, 4, 4, 32, 0);
            defer gpa.free(pixels);
            if (zero_alpha) {
                var i: usize = 3;
                while (i < pixels.len) : (i += 4) pixels[i] = 0;
            }
            try expectBmp(.{
                .header_size = header_size,
                .width = 4,
                .height = -4,
                .bpp = 32,
                .masks = .{ 1, 2, 4, 8 },
                .pixels = pixels,
            }, rng, "zero alpha");
        }
    }
}

test "palette sizes from none to past 256 decode or fail as in the original" {
    var prng: std.Random.DefaultPrng = .init(0xb3b0_0004);
    const rng = prng.random();
    for ([_]u32{ 12, 40, 124 }) |header_size| {
        for ([_]u16{ 1, 4, 8 }) |bpp| {
            for ([_]u32{ 0, 1, 2, 4, 5, 16, 255, 256, 257, 300 }) |entries| {
                // The original reads four entries fewer from an OS/2
                // header than it holds; with fewer than four, every pixel
                // names one past the palette, which has a test of its own.
                if (header_size == 12 and entries < 4) continue;
                const usable = if (header_size == 12) entries - 4 else entries;
                const pixels = try randomPixels(rng, 6, 2, bpp, usable);
                defer gpa.free(pixels);
                try expectBmp(.{
                    .header_size = header_size,
                    .width = 6,
                    .height = 2,
                    .bpp = bpp,
                    .palette_entries = entries,
                    .pixels = pixels,
                }, rng, "palette size");
            }
        }
    }
}

test "a pixel naming an entry past the palette reads as zero" {
    var prng: std.Random.DefaultPrng = .init(0xb3b0_0005);
    const rng = prng.random();
    const cases = [_]struct { header_size: u32, bpp: u16, entries: u32 }{
        .{ .header_size = 40, .bpp = 8, .entries = 2 },
        .{ .header_size = 40, .bpp = 4, .entries = 3 },
        .{ .header_size = 40, .bpp = 1, .entries = 1 },
        // An OS/2 palette of 2 entries: the original counts -2 of them.
        .{ .header_size = 12, .bpp = 8, .entries = 2 },
        // An OS/2 palette of 256 entries: the last four are past it.
        .{ .header_size = 12, .bpp = 8, .entries = 256 },
    };
    for (cases) |case| {
        const pixels = try randomPixels(rng, 4, 2, case.bpp, 256);
        defer gpa.free(pixels);
        @memset(pixels, 0xff);
        const bytes = try encodeBmp(.{
            .header_size = case.header_size,
            .width = 4,
            .height = 2,
            .bpp = case.bpp,
            .palette_entries = case.entries,
            .pixels = pixels,
        }, rng);
        defer gpa.free(bytes);
        try oracle.expectAll(gpa, bytes, .{ .name = "index past palette" }, .same_size);
        try expectZeroPixels(bytes);
    }
}

/// Whether the original reads a palette entry it never wrote from a file
/// of zero palette and pixel bytes: every pixel names entry 0, which it
/// has not read when the palette count it takes from the offset is
/// negative.
fn readsPastPalette(b: Bmp) bool {
    if (b.bpp != 1 and b.bpp != 4 and b.bpp != 8) return false;
    if (b.width == 0 or b.height == 0) return false;
    const offset: i64 = @as(i32, @bitCast(b.offset orelse b.start()));
    if (offset < 0) return false;
    const count = if (b.header_size == 12)
        @divTrunc(offset - 38, 3)
    else
        (offset - 14 - b.header_size) >> 2;
    return count < 0;
}

test "bad compressions, planes, offsets and depths fail as in the original" {
    var prng: std.Random.DefaultPrng = .init(0xb3b0_0006);
    const rng = prng.random();
    const pixels = try randomPixels(rng, 3, 3, 24, 0);
    defer gpa.free(pixels);
    const zeros: [36]u8 = @splat(0);
    const base: Bmp = .{ .width = 3, .height = 3, .bpp = 24, .pixels = pixels };
    var cases: std.ArrayList(Bmp) = .empty;
    defer cases.deinit(gpa);
    for ([_]u32{ 1, 2, 3, 4, 5, 6, 0x7fffffff, 0x80000000, 0xffffffff }) |compress| {
        var b = base;
        b.compress = compress;
        try cases.append(gpa, b);
        b.header_size = 124;
        try cases.append(gpa, b);
        b.bpp = 32;
        try cases.append(gpa, b);
        b.header_size = 40;
        try cases.append(gpa, b);
        b.bpp = 16;
        try cases.append(gpa, b);
    }
    for ([_]u16{ 0, 2, 3, 0xffff }) |planes| {
        var b = base;
        b.planes = planes;
        try cases.append(gpa, b);
    }
    const offsets = [_]u32{
        0,          1,          53,         54,
        55,         58,         54 + 1024,  54 + 1025,
        0x7fffffff, 0x80000000, 0xffffffff,
    };
    for (offsets) |offset| {
        var b = base;
        b.offset = offset;
        try cases.append(gpa, b);
        b.header_size = 12;
        try cases.append(gpa, b);
        b.header_size = 108;
        try cases.append(gpa, b);
        b.bpp = 8;
        b.palette_entries = 16;
        b.pixels = &zeros;
        b.zero_fill = true;
        try cases.append(gpa, b);
        b.header_size = 40;
        try cases.append(gpa, b);
        b.header_size = 12;
        try cases.append(gpa, b);
        b.bpp = 1;
        try cases.append(gpa, b);
    }
    for ([_]u16{ 0, 2, 3, 5, 7, 9, 15, 17, 23, 25, 31, 33, 48, 64, 0xffff }) |bpp| {
        for ([_]u32{ 12, 40, 108 }) |header_size| {
            for ([_]u32{ 0, 3 }) |compress| {
                var b = base;
                b.bpp = bpp;
                b.header_size = header_size;
                b.compress = compress;
                b.palette_entries = 16;
                b.masks = .{ 0xf00, 0x0f0, 0x00f, 0 };
                try cases.append(gpa, b);
            }
        }
    }
    for ([_]u32{ 4, 8, 32, 1024 }) |gap| {
        var b = base;
        b.gap = gap;
        try cases.append(gpa, b);
        b.bpp = 8;
        b.palette_entries = 256;
        b.pixels = &zeros;
        try cases.append(gpa, b);
    }
    for (cases.items) |b| {
        const bytes = try encodeBmp(b, rng);
        defer gpa.free(bytes);
        if (readsPastPalette(b)) {
            try oracle.expectAll(gpa, bytes, .{ .name = "bad header" }, .same_size);
            try expectZeroPixels(bytes);
        } else {
            try oracle.expectAll(gpa, bytes, .{ .name = "bad header" }, .same);
        }
    }
}

test "unknown header sizes are not BMPs, as in the original" {
    var prng: std.Random.DefaultPrng = .init(0xb3b0_0007);
    const rng = prng.random();
    const pixels = try randomPixels(rng, 2, 2, 24, 0);
    defer gpa.free(pixels);
    for ([_]u32{ 0, 11, 16, 41, 52, 64, 100, 125, 0xffffffff }) |header_size| {
        try expectBmp(.{
            .header_size = header_size,
            .width = 2,
            .height = 2,
            .bpp = 24,
            .pixels = pixels,
        }, rng, "unknown header size");
    }
}

test "the largest sizes decode or fail as in the original" {
    var prng: std.Random.DefaultPrng = .init(0xb3b0_0008);
    const rng = prng.random();
    const max: i32 = 1 << 24;
    const sizes = [_][2]i32{
        .{ max, 1 },
        .{ 1, max },
        .{ 1, -max },
        .{ max + 1, 1 },
        .{ 1, max + 1 },
        .{ 1, -max - 1 },
        .{ 0, 5 },
        .{ 5, 0 },
        .{ 0, 0 },
        .{ 0x10000, 0x10000 },
        .{ -1, 1 },
        .{ std.math.maxInt(i32), 1 },
    };
    for (sizes) |size| {
        for ([_]u16{ 1, 24 }) |bpp| {
            try expectBmp(.{
                .width = size[0],
                .height = size[1],
                .bpp = bpp,
                .palette_entries = if (bpp == 1) 2 else 0,
                .pixels = &.{},
            }, rng, "largest sizes");
        }
    }
    // OS/2 sizes are 16 bits.
    try expectBmp(.{
        .header_size = 12,
        .width = 0xffff,
        .height = 1,
        .bpp = 24,
        .pixels = &.{},
    }, rng, "largest OS/2 size");
}

test "a height of -2^31 is refused, where the original's abs() is undefined" {
    var prng: std.Random.DefaultPrng = .init(0xb3b0_0009);
    const bytes = try encodeBmp(.{
        .width = 1,
        .height = std.math.minInt(i32),
        .bpp = 24,
        .pixels = &.{},
    }, prng.random());
    defer gpa.free(bytes);
    try oracle.expectAll(gpa, bytes, .{ .name = "height -2^31" }, .port_refuses);
    try std.testing.expectError(error.DimensionTooLarge, stbi.loadFromMemory(u8, gpa, bytes, .{}));
}

test "a BMP cut short at every byte of its headers decodes or fails as in the original" {
    var prng: std.Random.DefaultPrng = .init(0xb3b0_000a);
    const rng = prng.random();
    const bases = [_]struct { header_size: u32, bpp: u16, compress: u32, entries: u32 }{
        .{ .header_size = 40, .bpp = 24, .compress = 0, .entries = 0 },
        .{ .header_size = 40, .bpp = 16, .compress = 3, .entries = 0 },
        .{ .header_size = 56, .bpp = 32, .compress = 0, .entries = 0 },
        .{ .header_size = 124, .bpp = 32, .compress = 3, .entries = 0 },
        .{ .header_size = 12, .bpp = 8, .compress = 0, .entries = 12 },
        .{ .header_size = 108, .bpp = 4, .compress = 0, .entries = 16 },
    };
    for (bases) |base| {
        const usable = if (base.header_size == 12) base.entries - 4 else base.entries;
        const pixels = try randomPixels(rng, 3, 2, base.bpp, usable);
        defer gpa.free(pixels);
        const bytes = try encodeBmp(.{
            .header_size = base.header_size,
            .width = 3,
            .height = 2,
            .bpp = base.bpp,
            .compress = base.compress,
            .masks = .{ 0x7c00, 0x03e0, 0x001f, 0x8000 },
            .palette_entries = base.entries,
            .pixels = pixels,
        }, rng);
        defer gpa.free(bytes);
        for (0..bytes.len + 1) |len| {
            try oracle.expectAllSame(gpa, bytes[0..len], .{ .name = "cut short" });
        }
    }
}

fn handMadeSeeds(list: *std.ArrayList([]const u8), rng: std.Random) !void {
    for ([_]u32{ 12, 40, 56, 108, 124 }) |header_size| {
        for ([_]u16{ 1, 4, 8, 16, 24, 32 }) |bpp| {
            const palette: u32 = if (bpp < 16) (@as(u32, 1) << @intCast(bpp)) else 0;
            const extra: u32 = if (header_size == 12 and bpp < 16) 4 else 0;
            const pixels = try randomPixels(rng, 5, 3, bpp, palette);
            defer gpa.free(pixels);
            try list.append(gpa, try encodeBmp(.{
                .header_size = header_size,
                .width = 5,
                .height = if (header_size == 12) 3 else -3,
                .bpp = bpp,
                .compress = if ((bpp == 16 or bpp == 32) and header_size != 12) 3 else 0,
                .masks = .{ 0xf800, 0x07e0, 0x001f, 0 },
                .palette_entries = palette + extra,
                .pixels = pixels,
            }, rng));
        }
    }
}

const fuzz_config: fuzz.Config = .{
    .name = "bmp",
    .seed = 0xb3b0_f000,
    .cases = 3000,
    .unset_pixels = &bmp_unset_pixels,
    .compare_unset = expectReadEntriesOfCase,
};

test "fuzz: mutated BMPs decode or fail as in the original" {
    var prng: std.Random.DefaultPrng = .init(0xb3b0_000b);
    var set = try corpusFiles();
    defer set.deinit(gpa);
    var hand_made: std.ArrayList([]const u8) = .empty;
    defer {
        for (hand_made.items) |input| gpa.free(input);
        hand_made.deinit(gpa);
    }
    try handMadeSeeds(&hand_made, prng.random());
    var inputs: std.ArrayList([]const u8) = .empty;
    defer inputs.deinit(gpa);
    // The files naming unset palette entries are left out: most of their
    // cases could not be compared.
    for (set.entries) |entry| {
        if (!namesUnsetEntries(entry.name)) try inputs.append(gpa, entry.bytes);
    }
    try inputs.appendSlice(gpa, hand_made.items);
    try fuzz.run(gpa, fuzz_config, inputs.items);
}

/// Fuzz cases on which the original reads palette entries it never wrote,
/// found by running every case against it.
const bmp_unset_pixels = [_]u32{
    102,  205,  245,  287,  293,  302,  313,  318,  326,  352,  437,  486,
    488,  527,  729,  733,  792,  825,  849,  941,  1033, 1161, 1261, 1265,
    1346, 1425, 1541, 1571, 1600, 1614, 1702, 1734, 1824, 1960, 1973, 2011,
    2014, 2040, 2066, 2077, 2133, 2148, 2170, 2203, 2219, 2244, 2247, 2293,
    2383, 2396, 2414, 2524, 2599, 2629, 2630, 2670, 2702, 2727, 2763, 2893,
    2927,
};

/// For a fuzz case whose pixels name palette entries the original never
/// reads: every pixel whose entry it reads is compared with both builds of
/// the original, loaded from memory at the case's bit depth and options, and
/// every other pixel must be zero, opaque where there is alpha. A copy of
/// the case whose palette entries the original reads are all white tells
/// the pixels apart: loaded, a pixel is white where its entry was read.
fn expectReadEntriesOfCase(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    request: oracle.Request,
    label: oracle.Label,
) !void {
    if (fuzz_options.sanitize) return;
    const options = request.options;
    if (bytes.len < 18) return error.TestUnexpectedResult;
    // The palette follows the header; the original reads `psize` entries,
    // counted from the offset as `stbi__bmp_load` counts them.
    const offset: i64 = std.mem.readInt(i32, bytes[10..14], .little);
    const header_size = std.mem.readInt(u32, bytes[14..18], .little);
    const entry_size: usize = if (header_size == 12) 3 else 4;
    const psize: i64 = if (header_size == 12)
        @divTrunc(offset - 14 - 24, 3)
    else
        (offset - 14 - header_size) >> 2;
    const marked = try allocator.dupe(u8, bytes);
    defer allocator.free(marked);
    for (0..@intCast(std.math.clamp(psize, 0, 256))) |i| {
        for (0..3) |b| {
            const at = 14 + header_size + i * entry_size + b;
            if (at < marked.len) marked[at] = 0xff;
        }
    }
    var white = try stbi.loadFromMemory(u8, allocator, marked, .{
        .components = options.components,
        .flip_vertically = options.flip_vertically,
    });
    defer white.deinit(allocator);
    const n: usize = white.channels;
    const pixel_count = white.pixels.len / n;

    switch (request.bits) {
        inline else => |bits| {
            const T = switch (bits) {
                .u8 => u8,
                .u16 => u16,
                .f32 => f32,
            };
            const opaque_alpha: T = switch (T) {
                u8 => 255,
                u16 => 0xffff,
                f32 => 1.0,
                else => unreachable,
            };
            var ours = try stbi.loadFromMemory(T, allocator, bytes, options);
            defer ours.deinit(allocator);
            try std.testing.expectEqual(white.pixels.len, ours.pixels.len);
            const has_alpha = n == 2 or n == 4;
            var read: usize = 0;
            for (0..pixel_count) |i| {
                if (white.pixels[i * n] != 0) {
                    read += 1;
                    continue;
                }
                const pixel = ours.pixels[i * n ..][0..n];
                for (pixel, 0..) |sample, k| {
                    const expected: T = if (has_alpha and k == n - 1) opaque_alpha else 0;
                    if (!std.mem.eql(u8, std.mem.asBytes(&sample), std.mem.asBytes(&expected))) {
                        label.print(request, "pixel {d} names an unset entry, is not zero", .{i});
                        return error.TestUnexpectedResult;
                    }
                }
            }
            if (read == 0) return;
            var settings = request.settings();
            settings.via = @backingInt(oracle.Via.memory);
            const bits_arg: c_int = switch (bits) {
                .u8 => 8,
                .u16 => 16,
                .f32 => 32,
            };
            const ours_bytes = std.mem.sliceAsBytes(ours.pixels);
            const pixel_bytes = n * @sizeOf(T);
            for ([_]oracle.Path{ .simd, .scalar }) |path| {
                var theirs: oracle.Result = undefined;
                oracle.loadFn(path)(bytes.ptr, bytes.len, bits_arg, &settings, &theirs);
                defer oracle.freeFn(path)(theirs.pixels);
                const original: [*]const u8 = @ptrCast(theirs.pixels orelse {
                    label.print(request, "{t}: the original fails from memory", .{path});
                    return error.TestUnexpectedResult;
                });
                for (0..pixel_count) |i| {
                    if (white.pixels[i * n] == 0) continue;
                    const at = i * pixel_bytes;
                    if (!std.mem.eql(u8, original[at..][0..pixel_bytes], ours_bytes[at..][0..pixel_bytes])) {
                        label.print(request, "{t}: pixel {d}, whose entry is read, differs", .{ path, i });
                        return error.TestUnexpectedResult;
                    }
                }
            }
        },
    }
}

fn decodeAll(allocator: std.mem.Allocator, bytes: []const u8) !void {
    for ([_]stbi.Components{ .file, .grey, .rgba }) |components| {
        var image = try stbi.loadFromMemory(u8, allocator, bytes, .{ .components = components });
        image.deinit(allocator);
        var wide = try stbi.loadFromMemory(u16, allocator, bytes, .{ .components = components });
        wide.deinit(allocator);
    }
}

test "a BMP decode frees everything when any allocation fails" {
    var prng: std.Random.DefaultPrng = .init(0xb3b0_000c);
    const rng = prng.random();
    for ([_]u16{ 8, 24, 32 }) |bpp| {
        const pixels = try randomPixels(rng, 4, 3, bpp, 256);
        defer gpa.free(pixels);
        const bytes = try encodeBmp(.{
            .width = 4,
            .height = 3,
            .bpp = bpp,
            .palette_entries = if (bpp == 8) 256 else 0,
            .pixels = pixels,
        }, rng);
        defer gpa.free(bytes);
        try std.testing.checkAllAllocationFailures(gpa, decodeAll, .{bytes});
    }
}
