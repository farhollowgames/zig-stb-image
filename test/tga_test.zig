//! TGA against the original: the TGA test suite, hand-made files of every
//! image type, depth, origin and run-length packet, and fuzzing.

const std = @import("std");
const stbi = @import("stb_image");
const oracle = @import("oracle.zig");
const fuzz = @import("fuzz.zig");
const corpus = @import("corpus.zig");

const gpa = std.testing.allocator;

test "every TGA test file decodes as in the original" {
    var set = try corpus.load(gpa, std.testing.io, .image_rs, "tests/images/tga", &.{".tga"});
    defer set.deinit(gpa);
    try std.testing.expect(set.entries.len >= 18);
    var failures: usize = 0;
    for (set.entries) |entry| {
        oracle.expectAllSame(gpa, entry.bytes, .{ .name = entry.name }) catch {
            failures += 1;
        };
    }
    try std.testing.expectEqual(0, failures);
}

// --------------------------------------------------------
// A small TGA writer
// --------------------------------------------------------

const Tga = struct {
    id: []const u8 = "",
    colormap_type: u8 = 0,
    image_type: u8,
    palette_start: u16 = 0,
    palette_len: u16 = 0,
    palette_bits: u8 = 0,
    width: u16,
    height: u16,
    bpp: u8,
    descriptor: u8 = 0,
    /// Everything after the ID: the colour map and the pixels.
    body: []const u8,
};

fn put16(list: *std.ArrayList(u8), value: u16) !void {
    var bytes: [2]u8 = undefined;
    std.mem.writeInt(u16, &bytes, value, .little);
    try list.appendSlice(gpa, &bytes);
}

fn encodeTga(t: Tga) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(gpa);
    try list.append(gpa, @intCast(t.id.len));
    try list.append(gpa, t.colormap_type);
    try list.append(gpa, t.image_type);
    try put16(&list, t.palette_start);
    try put16(&list, t.palette_len);
    try list.append(gpa, t.palette_bits);
    try put16(&list, 0); // x origin
    try put16(&list, 0); // y origin
    try put16(&list, t.width);
    try put16(&list, t.height);
    try list.append(gpa, t.bpp);
    try list.append(gpa, t.descriptor);
    try list.appendSlice(gpa, t.id);
    try list.appendSlice(gpa, t.body);
    return list.toOwnedSlice(gpa);
}

fn bytesPerEntry(bits: u8) usize {
    return (@as(usize, bits) + 7) / 8;
}

/// One pixel's bytes: an index below `index_limit` (and now and then past
/// it) for colour-mapped images, random bytes otherwise.
fn randomPixel(rng: std.Random, pixel: []u8, indexed: bool, index_limit: u16) void {
    rng.bytes(pixel);
    if (!indexed) return;
    var index: u16 = rng.uintLessThan(u16, @max(index_limit, 1));
    if (rng.uintLessThan(u32, 16) == 0) index = index_limit +| rng.int(u8);
    if (pixel.len == 1) {
        pixel[0] = @truncate(index);
    } else {
        std.mem.writeInt(u16, pixel[0..2], index, .little);
    }
}

/// Pixels for `count` pixels of `pixel_size` bytes, raw or as run-length
/// packets of random kinds and lengths that cross rows.
fn randomPixels(
    rng: std.Random,
    count: usize,
    pixel_size: usize,
    rle: bool,
    indexed: bool,
    index_limit: u16,
) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(gpa);
    var buffer: [4]u8 = undefined;
    const one = buffer[0..pixel_size];
    if (!rle) {
        for (0..count) |_| {
            randomPixel(rng, one, indexed, index_limit);
            try list.appendSlice(gpa, one);
        }
        return list.toOwnedSlice(gpa);
    }
    var done: usize = 0;
    while (done < count) {
        const len = 1 + rng.uintLessThan(usize, 128);
        const repeat = rng.boolean();
        try list.append(gpa, @intCast((len - 1) | (if (repeat) @as(usize, 0x80) else 0)));
        if (repeat) {
            randomPixel(rng, one, indexed, index_limit);
            try list.appendSlice(gpa, one);
        } else {
            for (0..len) |_| {
                randomPixel(rng, one, indexed, index_limit);
                try list.appendSlice(gpa, one);
            }
        }
        done += len;
    }
    return list.toOwnedSlice(gpa);
}

const Kind = struct {
    image_type: u8,
    bpp: u8,
    palette_bits: u8 = 0,
};

/// Every image type with every pixel size the original reads.
fn kinds(list: *std.ArrayList(Kind)) !void {
    for ([_]u8{ 1, 9 }) |image_type| {
        for ([_]u8{ 8, 15, 16, 24, 32 }) |palette_bits| {
            for ([_]u8{ 8, 16 }) |bpp| {
                try list.append(gpa, .{
                    .image_type = image_type,
                    .bpp = bpp,
                    .palette_bits = palette_bits,
                });
            }
        }
    }
    for ([_]u8{ 2, 3, 10, 11 }) |image_type| {
        for ([_]u8{ 8, 15, 16, 24, 32 }) |bpp| {
            try list.append(gpa, .{ .image_type = image_type, .bpp = bpp });
        }
    }
}

fn makeTga(rng: std.Random, kind: Kind, width: u16, height: u16, descriptor: u8) ![]u8 {
    const indexed = kind.image_type == 1 or kind.image_type == 9;
    const rle = kind.image_type >= 8;
    const palette_len: u16 = if (indexed) 1 + rng.uintLessThan(u16, 40) else 0;
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    if (indexed) {
        const palette = try gpa.alloc(u8, palette_len * bytesPerEntry(kind.palette_bits));
        defer gpa.free(palette);
        rng.bytes(palette);
        try body.appendSlice(gpa, palette);
    }
    const pixels = try randomPixels(
        rng,
        @as(usize, width) * height,
        bytesPerEntry(kind.bpp),
        rle,
        indexed,
        palette_len,
    );
    defer gpa.free(pixels);
    try body.appendSlice(gpa, pixels);
    return encodeTga(.{
        .colormap_type = @intFromBool(indexed),
        .image_type = kind.image_type,
        .palette_len = palette_len,
        .palette_bits = kind.palette_bits,
        .width = width,
        .height = height,
        .bpp = kind.bpp,
        .descriptor = descriptor,
        .body = body.items,
    });
}

test "every image type, depth and origin decodes as in the original" {
    var prng: std.Random.DefaultPrng = .init(0x7a6a_0001);
    const rng = prng.random();
    var list: std.ArrayList(Kind) = .empty;
    defer list.deinit(gpa);
    try kinds(&list);
    const sizes = [_][2]u16{ .{ 1, 1 }, .{ 5, 3 }, .{ 33, 7 } };
    for (list.items) |kind| {
        for (sizes) |size| {
            // Bits 4 and 5 give the four origins; the low bits count alpha.
            for ([_]u8{ 0x00, 0x10, 0x20, 0x30, 0x08, 0xff }) |descriptor| {
                const bytes = try makeTga(rng, kind, size[0], size[1], descriptor);
                defer gpa.free(bytes);
                try oracle.expectAllSame(gpa, bytes, .{ .name = "type and depth" });
            }
        }
    }
}

test "run-length packets of every length and kind decode as in the original" {
    var prng: std.Random.DefaultPrng = .init(0x7a6a_0002);
    const rng = prng.random();
    for ([_]u8{ 9, 10, 11 }) |image_type| {
        const bpp: u8 = if (image_type == 9) 8 else 24;
        const pixel_size = bytesPerEntry(bpp);
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(gpa);
        if (image_type == 9) {
            var palette: [256 * 3]u8 = undefined;
            rng.bytes(&palette);
            try body.appendSlice(gpa, &palette);
        }
        // Every packet header, so runs start and end anywhere in a row.
        var count: usize = 0;
        for (0..256) |header| {
            const len = (header & 127) + 1;
            try body.append(gpa, @intCast(header));
            const values = if (header >= 128) 1 else len;
            for (0..values * pixel_size) |_| try body.append(gpa, rng.int(u8));
            count += len;
        }
        // 33 by 1000 pixels: the packets cover 16,512 and the rest of the
        // image reads zeros past the end.
        const bytes = try encodeTga(.{
            .colormap_type = @intFromBool(image_type == 9),
            .image_type = image_type,
            .palette_len = if (image_type == 9) 256 else 0,
            .palette_bits = if (image_type == 9) 24 else 0,
            .width = 33,
            .height = 1000,
            .bpp = bpp,
            .body = body.items,
        });
        defer gpa.free(bytes);
        try std.testing.expectEqual(16512, count);
        try oracle.expectAllSame(gpa, bytes, .{ .name = "every packet" });
    }
}

test "colour maps empty, short, offset and overrun decode or fail as in the original" {
    var prng: std.Random.DefaultPrng = .init(0x7a6a_0003);
    const rng = prng.random();
    var palette: [600]u8 = undefined;
    rng.bytes(&palette);
    var indices: [24]u8 = undefined;
    rng.bytes(&indices);
    const Case = struct {
        palette_len: u16,
        palette_start: u16,
        palette_bits: u8,
        palette_bytes: usize,
    };
    const cases = [_]Case{
        .{ .palette_len = 0, .palette_start = 0, .palette_bits = 24, .palette_bytes = 0 },
        .{ .palette_len = 1, .palette_start = 0, .palette_bits = 24, .palette_bytes = 3 },
        .{ .palette_len = 200, .palette_start = 0, .palette_bits = 24, .palette_bytes = 600 },
        .{ .palette_len = 200, .palette_start = 0, .palette_bits = 32, .palette_bytes = 600 },
        .{ .palette_len = 300, .palette_start = 0, .palette_bits = 16, .palette_bytes = 400 },
        .{ .palette_len = 10, .palette_start = 7, .palette_bits = 8, .palette_bytes = 17 },
        .{ .palette_len = 10, .palette_start = 600, .palette_bits = 24, .palette_bytes = 30 },
        .{ .palette_len = 65535, .palette_start = 0, .palette_bits = 32, .palette_bytes = 600 },
        .{ .palette_len = 65535, .palette_start = 0, .palette_bits = 15, .palette_bytes = 600 },
    };
    for (cases) |case| {
        for ([_]u8{ 1, 9 }) |image_type| {
            var body: std.ArrayList(u8) = .empty;
            defer body.deinit(gpa);
            try body.appendSlice(gpa, palette[0..case.palette_bytes]);
            try body.appendSlice(gpa, &indices);
            const bytes = try encodeTga(.{
                .colormap_type = 1,
                .image_type = image_type,
                .palette_start = case.palette_start,
                .palette_len = case.palette_len,
                .palette_bits = case.palette_bits,
                .width = 4,
                .height = 3,
                .bpp = 8,
                .body = body.items,
            });
            defer gpa.free(bytes);
            try oracle.expectAllSame(gpa, bytes, .{ .name = "colour map" });
        }
    }
}

test "headers the original does not read are refused as in the original" {
    var body: [64]u8 = undefined;
    @memset(&body, 0x5a);
    const id: [255]u8 = @splat('i');
    const rgb: Tga = .{ .image_type = 2, .width = 2, .height = 2, .bpp = 24, .body = &body };
    var mapped = rgb;
    mapped.colormap_type = 1;
    mapped.image_type = 1;
    mapped.bpp = 8;
    mapped.palette_len = 4;
    mapped.palette_bits = 24;
    var cases: [15]Tga = @splat(rgb);
    cases[0].colormap_type = 2;
    cases[1] = mapped;
    cases[1].image_type = 2;
    cases[2].image_type = 1;
    cases[3] = mapped;
    cases[3].bpp = 24;
    cases[4] = mapped;
    cases[4].palette_bits = 12;
    cases[5].image_type = 0;
    cases[6].image_type = 4;
    cases[7].image_type = 12;
    cases[8].width = 0;
    cases[9].height = 0;
    cases[10].bpp = 0;
    cases[11].bpp = 7;
    cases[12].bpp = 33;
    cases[13].image_type = 3;
    cases[13].bpp = 16;
    cases[14].id = &id;
    cases[14].bpp = 32;
    for (cases) |case| {
        const bytes = try encodeTga(case);
        defer gpa.free(bytes);
        try oracle.expectAllSame(gpa, bytes, .{ .name = "header" });
    }
}

test "the largest sizes decode or fail as in the original" {
    var prng: std.Random.DefaultPrng = .init(0x7a6a_0004);
    const rng = prng.random();
    const sizes = [_][2]u16{ .{ 65535, 1 }, .{ 1, 65535 }, .{ 65535, 65535 }, .{ 40000, 60000 } };
    for (sizes) |size| {
        for ([_]u8{ 3, 10, 11 }) |image_type| {
            // A few run-length packets; the rest reads zeros.
            var body: [64]u8 = undefined;
            rng.bytes(&body);
            const bytes = try encodeTga(.{
                .image_type = image_type,
                .width = size[0],
                .height = size[1],
                .bpp = if (image_type == 11) 8 else 24,
                .descriptor = 0x20,
                .body = &body,
            });
            defer gpa.free(bytes);
            const pixels = @as(u64, size[0]) * size[1];
            // A raw image that big is refused for its missing rows.
            const fits = pixels * 3 <= std.math.maxInt(i32);
            const expect: oracle.Expect = if (image_type == 3 and fits) .port_refuses else .same;
            try oracle.expectAll(gpa, bytes, .{ .name = "largest" }, expect);
        }
    }
}

test "a TGA cut short decodes or fails as in the original, or is refused missing raw rows" {
    var prng: std.Random.DefaultPrng = .init(0x7a6a_0005);
    const rng = prng.random();
    const bases = [_]Kind{
        .{ .image_type = 1, .bpp = 8, .palette_bits = 24 },
        .{ .image_type = 9, .bpp = 16, .palette_bits = 16 },
        .{ .image_type = 2, .bpp = 24 },
        .{ .image_type = 2, .bpp = 16 },
        .{ .image_type = 3, .bpp = 8 },
        .{ .image_type = 10, .bpp = 32 },
        .{ .image_type = 11, .bpp = 16 },
    };
    for (bases) |kind| {
        const bytes = try makeTga(rng, kind, 3, 4, 0);
        defer gpa.free(bytes);
        const raw = (kind.image_type == 2 and kind.bpp != 16) or kind.image_type == 3;
        for (0..bytes.len + 1) |len| {
            // With the header whole up to the pixel size, the raw rows
            // the original cannot read stay uninitialized.
            const refused = raw and len >= 17 and len < bytes.len;
            const expect: oracle.Expect = if (refused) .port_refuses else .same;
            try oracle.expectAll(gpa, bytes[0..len], .{ .name = "cut short" }, expect);
            if (refused) {
                const result = stbi.loadFromMemory(u8, gpa, bytes[0..len], .{});
                try std.testing.expectError(error.TgaTruncated, result);
            }
        }
    }
}

fn handMadeSeeds(list: *std.ArrayList([]const u8), rng: std.Random) !void {
    var all: std.ArrayList(Kind) = .empty;
    defer all.deinit(gpa);
    try kinds(&all);
    for (all.items, 0..) |kind, i| {
        const descriptor: u8 = @intCast((i % 4) << 4);
        try list.append(gpa, try makeTga(rng, kind, 6, 5, descriptor));
    }
}

const fuzz_config: fuzz.Config = .{
    .name = "tga",
    .seed = 0x7a6a_f000,
    .cases = 3000,
    .unsafe = &tga_unsafe,
};

test "fuzz: mutated TGAs decode or fail as in the original" {
    var prng: std.Random.DefaultPrng = .init(0x7a6a_0006);
    var set = try corpus.load(gpa, std.testing.io, .image_rs, "tests/images/tga", &.{".tga"});
    defer set.deinit(gpa);
    var hand_made: std.ArrayList([]const u8) = .empty;
    defer {
        for (hand_made.items) |input| gpa.free(input);
        hand_made.deinit(gpa);
    }
    try handMadeSeeds(&hand_made, prng.random());
    var inputs: std.ArrayList([]const u8) = .empty;
    defer inputs.deinit(gpa);
    for (set.entries) |entry| try inputs.append(gpa, entry.bytes);
    try inputs.appendSlice(gpa, hand_made.items);
    try fuzz.run(gpa, fuzz_config, inputs.items);
    try fuzz.expectUnsafeRefused(gpa, fuzz_config, inputs.items, &.{error.TgaTruncated});
}

/// Fuzz cases on which the original leaves raw rows uninitialized, found
/// by running every case against it.
const tga_unsafe = fuzz.unsafeLoads(&.{
    47,   119,  128,  164,  174,  211,  217,  223,  230,  238,  251,  256,
    257,  350,  356,  375,  426,  437,  451,  471,  532,  541,  585,  621,
    622,  679,  694,  701,  720,  769,  817,  819,  871,  945,  1001, 1068,
    1127, 1131, 1167, 1241, 1288, 1298, 1344, 1347, 1383, 1416, 1443, 1501,
    1540, 1594, 1620, 1644, 1676, 1710, 1721, 1763, 1767, 1778, 1822, 1836,
    1853, 1882, 1915, 1930, 1958, 1964, 2002, 2114, 2123, 2136, 2152, 2157,
    2189, 2201, 2213, 2238, 2287, 2308, 2344, 2367, 2381, 2393, 2456, 2467,
    2480, 2525, 2528, 2537, 2553, 2583, 2603, 2659, 2664, 2666, 2765, 2774,
    2828, 2831, 2837, 2856, 2863, 2897, 2907, 2948, 2975,
});

fn decodeAll(allocator: std.mem.Allocator, bytes: []const u8) !void {
    for ([_]stbi.Components{ .file, .grey, .rgba }) |components| {
        var image = try stbi.loadFromMemory(u8, allocator, bytes, .{ .components = components });
        image.deinit(allocator);
        var wide = try stbi.loadFromMemory(u16, allocator, bytes, .{ .components = components });
        wide.deinit(allocator);
    }
}

test "a TGA decode frees everything when any allocation fails" {
    var prng: std.Random.DefaultPrng = .init(0x7a6a_0007);
    const rng = prng.random();
    for ([_]Kind{
        .{ .image_type = 1, .bpp = 8, .palette_bits = 24 },
        .{ .image_type = 2, .bpp = 32 },
        .{ .image_type = 10, .bpp = 16 },
    }) |kind| {
        const bytes = try makeTga(rng, kind, 4, 3, 0x20);
        defer gpa.free(bytes);
        try std.testing.checkAllAllocationFailures(gpa, decodeAll, .{bytes});
    }
}
