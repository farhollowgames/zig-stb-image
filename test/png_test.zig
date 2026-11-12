//! The PNG decoder against the original: the corpora, hand-made images of
//! every colour type, bit depth, filter, interlacing and size, damaged
//! files, the iPhone options, and fuzzing.

const std = @import("std");
const stbi = @import("stb_image");
const oracle = @import("oracle.zig");
const fuzz = @import("fuzz.zig");
const corpus = @import("corpus.zig");
const deflate = @import("deflate.zig");
const png_file = @import("png_file.zig");

const gpa = std.testing.allocator;
const Image = png_file.Image;

fn chunk(kind: *const [4]u8, data: []const u8) png_file.Chunk {
    return .{ .kind = kind, .data = data };
}

fn expectCorpusSame(root: corpus.Root, dir: []const u8) !void {
    var set = try corpus.load(gpa, std.testing.io, root, dir, &.{".png"});
    defer set.deinit(gpa);
    try std.testing.expect(set.entries.len > 0);
    for (set.entries) |entry| try oracle.expectAllSame(gpa, entry.bytes, .{ .name = entry.name });
}

test "png: the PngSuite's primary images decode as in the original" {
    try expectCorpusSame(.stb, "tests/pngsuite/primary");
}

test "png: the PngSuite's check images decode as in the original" {
    try expectCorpusSame(.stb, "tests/pngsuite/primary_check");
}

test "png: the PngSuite's 16-bit images decode as in the original" {
    try expectCorpusSame(.stb, "tests/pngsuite/16bit");
}

test "png: the PngSuite's corrupt images fail as in the original" {
    try expectCorpusSame(.stb, "tests/pngsuite/corrupt");
}

test "png: the PngSuite's unused images decode as in the original" {
    try expectCorpusSame(.stb, "tests/pngsuite/unused");
}

test "png: the iPhone images decode as in the original, with and without conversion" {
    var set = try corpus.load(gpa, std.testing.io, .stb, "tests/pngsuite/iphone", &.{".png"});
    defer set.deinit(gpa);
    for (set.entries) |entry| {
        const label: oracle.Label = .{ .name = entry.name };
        try oracle.expectAllSame(gpa, entry.bytes, label);
        try expectIphoneOptionsSame(entry.bytes, label);
    }
}

test "png: image-rs's PNG images decode as in the original" {
    try expectCorpusSame(.image_rs, "tests/images/png");
}

test "png: libjpeg-turbo's PNG images decode as in the original" {
    try expectCorpusSame(.libjpeg_turbo, "testimages");
}

/// Every load of `bytes` with the iPhone conversion on, with and without
/// unpremultiplying.
fn expectIphoneOptionsSame(bytes: []const u8, label: oracle.Label) !void {
    for ([_]oracle.Bits{ .u8, .u16, .f32 }) |bits| {
        for (0..5) |comp| {
            for ([_]bool{ false, true }) |unpremultiply| {
                try oracle.expectLoadSame(gpa, bytes, .{ .bits = bits, .options = .{
                    .components = @fromBackingInt(@as(u3, @intCast(comp))),
                    .convert_iphone_png = true,
                    .unpremultiply = unpremultiply,
                } }, label, .same);
            }
        }
        try oracle.expectLoadSame(gpa, bytes, .{ .bits = bits, .options = .{
            .unpremultiply = true,
        } }, label, .same);
    }
}

/// The bit depths each colour type allows, and the ones it does not that
/// the original decodes anyway (colour types 2, 4 and 6 below 8 bits).
const combinations = [_]struct { color: u8, depths: []const u8 }{
    .{ .color = 0, .depths = &.{ 1, 2, 4, 8, 16 } },
    .{ .color = 2, .depths = &.{ 1, 2, 4, 8, 16 } },
    .{ .color = 3, .depths = &.{ 1, 2, 4, 8 } },
    .{ .color = 4, .depths = &.{ 1, 2, 4, 8, 16 } },
    .{ .color = 6, .depths = &.{ 1, 2, 4, 8, 16 } },
};

const sizes = [_][2]u32{
    .{ 1, 1 }, .{ 1, 5 }, .{ 5, 1 },  .{ 2, 2 },  .{ 3, 3 },
    .{ 8, 8 }, .{ 9, 7 }, .{ 17, 4 }, .{ 33, 2 }, .{ 4, 9 },
};

/// A colour key for `image`: random samples, scaled down to the depth.
fn colourKey(arena: std.mem.Allocator, rng: std.Random, image: Image) ![]u8 {
    const n = png_file.channels(image.color);
    const key = try arena.alloc(u8, n * 2);
    for (0..n) |k| {
        const max: u16 = @truncate((@as(u32, 1) << @intCast(image.depth)) - 1);
        std.mem.writeInt(u16, key[k * 2 ..][0..2], rng.int(u16) & max, .big);
    }
    return key;
}

test "png: every colour type, bit depth, filter, interlacing and size decodes as in the original" {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var prng: std.Random.DefaultPrng = .init(0x9e3779b9);
    const rng = prng.random();
    for (combinations) |combination| {
        for (combination.depths) |depth| {
            for ([_]bool{ false, true }) |interlace| {
                for (sizes) |size| {
                    const image: Image = .{
                        .width = size[0],
                        .height = size[1],
                        .depth = depth,
                        .color = combination.color,
                        .interlace = interlace,
                    };
                    // Rows of the first filter rows only see their own
                    // first-row form; short images go through all five.
                    const offsets: usize = if (size[1] <= 2) 5 else 1;
                    for (0..offsets) |offset| {
                        var variants: [3]?[]const u8 = .{ null, null, null };
                        if (combination.color == 0 or combination.color == 2) {
                            variants[1] = try colourKey(arena, rng, image);
                        } else if (combination.color == 3) {
                            const entries = @as(usize, 1) << @intCast(depth);
                            const trns = try arena.alloc(u8, entries);
                            rng.bytes(trns);
                            variants[1] = trns;
                            variants[2] = trns[0 .. entries / 2 + 1];
                        }
                        for (variants, 0..) |trns, v| {
                            if (v > 0 and trns == null) continue;
                            const bytes = try png_file.random(arena, rng, image, .{
                                .trns = trns,
                                .filter_offset = offset,
                            });
                            const name = try std.fmt.allocPrint(arena, "colour {d} depth {d} " ++
                                "{d}x{d} interlace {} filter {d} trns {d}", .{
                                image.color, depth, size[0], size[1], interlace, offset, v,
                            });
                            try oracle.expectAllSame(gpa, bytes, .{ .name = name });
                        }
                    }
                }
            }
        }
    }
}

test "png: a tRNS colour key that matches pixels makes them transparent, as in the original" {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var prng: std.Random.DefaultPrng = .init(77);
    const rng = prng.random();
    // Rows of filter none and all-zero samples, keyed on zero.
    for ([_]u8{ 0, 2 }) |color| {
        for ([_]u8{ 1, 2, 4, 8, 16 }) |depth| {
            if (color == 2 and depth < 8) continue;
            const image: Image = .{ .width = 7, .height = 3, .depth = depth, .color = color };
            const raw = try arena.alloc(u8, (png_file.rowBytes(image, 7) + 1) * 3);
            @memset(raw, 0);
            raw[3] = 0xff;
            const key = try arena.alloc(u8, png_file.channels(color) * 2);
            @memset(key, 0);
            const bytes = try png_file.file(arena, &.{
                chunk("IHDR", &png_file.ihdr(image)),
                chunk("tRNS", key),
                .{ .kind = "IDAT", .data = try deflate.compress(arena, raw, .{}) },
                chunk("IEND", ""),
            });
            try oracle.expectAllSame(gpa, bytes, .{ .name = "matching key" });
        }
    }
    _ = rng;
}

test "png: iPhone PNGs convert to RGB and unpremultiply as in the original" {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var prng: std.Random.DefaultPrng = .init(0x1f0e);
    const rng = prng.random();
    for ([_]u8{ 0, 2, 3, 4, 6 }) |color| {
        for ([_]u8{ 8, 16 }) |depth| {
            if (color == 3 and depth == 16) continue;
            for ([_]bool{ false, true }) |interlace| {
                const image: Image = .{
                    .width = 6,
                    .height = 5,
                    .depth = depth,
                    .color = color,
                    .interlace = interlace,
                };
                var trns_options = [_]?[]const u8{ null, null };
                if (color == 2) trns_options[1] = try colourKey(arena, rng, image);
                for (trns_options, 0..) |trns, v| {
                    if (v > 0 and trns == null) continue;
                    const options: png_file.Options = .{ .cgbi = true, .trns = trns };
                    const bytes = try png_file.random(arena, rng, image, options);
                    const format = "iphone {d} depth {d} interlace {}";
                    const name = try std.fmt.allocPrint(arena, format, .{
                        color, depth, interlace,
                    });
                    const label: oracle.Label = .{ .name = name };
                    try oracle.expectAllSame(gpa, bytes, label);
                    try expectIphoneOptionsSame(bytes, label);
                }
            }
        }
    }
}

/// A grey 8-bit image's chunks, for the damaged-file tests: `raw` rows
/// in one IDAT chunk.
fn greyFile(arena: std.mem.Allocator, image: Image, raw: []const u8) ![]u8 {
    return png_file.file(arena, &.{
        chunk("IHDR", &png_file.ihdr(image)),
        .{ .kind = "IDAT", .data = try deflate.compress(arena, raw, .{}) },
        chunk("IEND", ""),
    });
}

fn expectSomeSame(bytes: []const u8, label: oracle.Label) !void {
    for ([_]oracle.Bits{ .u8, .u16, .f32 }) |bits| {
        try oracle.expectLoadSame(gpa, bytes, .{ .bits = bits }, label, .same);
        const rgba: oracle.Request = .{ .bits = bits, .options = .{ .components = .rgba } };
        try oracle.expectLoadSame(gpa, bytes, rgba, label, .same);
    }
    try oracle.expectLoadSame(gpa, bytes, .{ .via = .callbacks }, label, .same);
    for ([_]oracle.Query{ .info, .is_16_bit }) |query| {
        for ([_]oracle.Via{ .memory, .callbacks }) |via| {
            try oracle.expectQuerySame(bytes, query, via, label);
        }
    }
}

test "png: damaged headers and chunks fail with the original's reasons" {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const good: Image = .{ .width = 4, .height = 3 };
    const raw = "\x00abcd\x01efgh\x02ijkl";
    const idat = try deflate.compress(arena, raw, .{});
    const header = png_file.ihdr(good);
    const palette_header = png_file.ihdr(.{ .width = 4, .height = 3, .color = 3 });
    const grey_alpha_header = png_file.ihdr(.{ .width = 4, .height = 3, .color = 4 });
    const plte = "\x10\x20\x30\x40\x50\x60\x70\x80\x90";
    var long_header: [14]u8 = @splat(0);
    @memcpy(long_header[0..13], &header);

    const Case = []const png_file.Chunk;
    const ihdr_chunk: png_file.Chunk = chunk("IHDR", &header);
    const idat_chunk: png_file.Chunk = chunk("IDAT", idat);
    const iend_chunk: png_file.Chunk = chunk("IEND", "");
    var cases: std.ArrayList(Case) = .empty;
    const list = [_]Case{
        &.{ ihdr_chunk, idat_chunk, iend_chunk },
        &.{ ihdr_chunk, ihdr_chunk, idat_chunk, iend_chunk },
        &.{ chunk("IHDR", header[0..12]), idat_chunk, iend_chunk },
        &.{ chunk("IHDR", &long_header), idat_chunk, iend_chunk },
        &.{ idat_chunk, iend_chunk },
        &.{ chunk("PLTE", plte), ihdr_chunk, idat_chunk, iend_chunk },
        &.{ chunk("tRNS", "\x00\x01"), ihdr_chunk, idat_chunk, iend_chunk },
        &.{iend_chunk},
        &.{ chunk("teXt", "x"), ihdr_chunk, idat_chunk, iend_chunk },
        &.{ chunk("CgBI", "\x50\x00\x20\x06"), ihdr_chunk, idat_chunk, iend_chunk },
        &.{ ihdr_chunk, iend_chunk },
        &.{ ihdr_chunk, chunk("IDAT", ""), chunk("IDAT", ""), iend_chunk },
        &.{ ihdr_chunk, chunk("IDAT", ""), chunk("tRNS", "\x00\x01"), idat_chunk, iend_chunk },
        &.{ ihdr_chunk, idat_chunk, chunk("tRNS", "\x00\x01"), iend_chunk },
        &.{ ihdr_chunk, chunk("tRNS", "\x00\x01\x00"), idat_chunk, iend_chunk },
        &.{ chunk("IHDR", &grey_alpha_header), chunk("tRNS", "\x00\x01"), idat_chunk, iend_chunk },
        &.{ chunk("IHDR", &palette_header), idat_chunk, iend_chunk },
        &.{
            chunk("IHDR", &palette_header),
            chunk("tRNS", "\x01"),
            chunk("PLTE", plte),
            idat_chunk,
            iend_chunk,
        },
        &.{
            chunk("IHDR", &palette_header),
            chunk("PLTE", plte),
            chunk("tRNS", "\x01\x02\x03\x04"),
            idat_chunk,
            iend_chunk,
        },
        &.{ chunk("IHDR", &palette_header), chunk("PLTE", plte[0..8]), idat_chunk, iend_chunk },
        &.{
            chunk("IHDR", &palette_header),
            chunk("PLTE", &(@as([769]u8, @splat(0)))),
            idat_chunk,
            iend_chunk,
        },
        &.{
            chunk("IHDR", &palette_header),
            chunk("PLTE", &(@as([768]u8, @splat(0)))),
            idat_chunk,
            iend_chunk,
        },
        &.{ chunk("IHDR", &palette_header), chunk("PLTE", ""), idat_chunk, iend_chunk },
        &.{ ihdr_chunk, chunk("ABCD", "x"), idat_chunk, iend_chunk },
        &.{ ihdr_chunk, chunk("AB\x00D", "x"), idat_chunk, iend_chunk },
        &.{ ihdr_chunk, chunk("\x00BCD", "x"), idat_chunk, iend_chunk },
        &.{ ihdr_chunk, chunk("abcd", "x"), idat_chunk, iend_chunk },
        &.{ ihdr_chunk, .{ .kind = "abcd", .length = 0xffff_ffff }, idat_chunk, iend_chunk },
        &.{ ihdr_chunk, .{ .kind = "abcd", .length = 0x7fff_ffff }, idat_chunk, iend_chunk },
        &.{ ihdr_chunk, .{ .kind = "CgBI", .length = 0x8000_0000 }, idat_chunk, iend_chunk },
        &.{ ihdr_chunk, .{ .kind = "IDAT", .data = idat, .length = 1 << 30 }, iend_chunk },
        &.{ ihdr_chunk, .{ .kind = "IDAT", .data = idat, .length = (1 << 30) + 1 }, iend_chunk },
        &.{
            ihdr_chunk,
            .{ .kind = "IDAT", .data = idat, .length = @intCast(idat.len + 1) },
            iend_chunk,
        },
        &.{
            ihdr_chunk,
            .{ .kind = "IDAT", .data = idat, .crc = 0x1234_5678 },
            .{ .kind = "IEND", .crc = 0 },
        },
        &.{ ihdr_chunk, idat_chunk },
        &.{ ihdr_chunk, idat_chunk, iend_chunk, ihdr_chunk },
        &.{ ihdr_chunk, chunk("IDAT", idat[0..2]), chunk("IDAT", idat[2..]), iend_chunk },
        &.{ ihdr_chunk, chunk("IDAT", idat[0 .. idat.len - 6]), iend_chunk },
        &.{ ihdr_chunk, chunk("IDAT", idat[0..4]), iend_chunk },
    };
    try cases.appendSlice(arena, &list);

    // Every bad value of each IHDR field.
    const bad_fields = [_]struct { at: usize, value: u8 }{
        .{ .at = 8, .value = 0 },  .{ .at = 8, .value = 3 },  .{ .at = 8, .value = 32 },
        .{ .at = 9, .value = 1 },  .{ .at = 9, .value = 5 },  .{ .at = 9, .value = 7 },
        .{ .at = 10, .value = 1 }, .{ .at = 11, .value = 1 }, .{ .at = 12, .value = 2 },
        .{ .at = 0, .value = 0 },
    };
    for (bad_fields) |field| {
        const bad = try arena.dupe(u8, &header);
        bad[field.at] = field.value;
        if (field.at == 0) @memset(bad[0..4], 0);
        try cases.append(arena, try arena.dupe(png_file.Chunk, &.{
            chunk("IHDR", bad),
            idat_chunk,
            iend_chunk,
        }));
    }
    const palette16 = try arena.dupe(u8, &palette_header);
    palette16[8] = 16;
    try cases.append(arena, try arena.dupe(png_file.Chunk, &.{
        chunk("IHDR", palette16),
        idat_chunk,
        iend_chunk,
    }));
    const zero_height = try arena.dupe(u8, &header);
    @memset(zero_height[4..8], 0);
    try cases.append(arena, try arena.dupe(png_file.Chunk, &.{
        chunk("IHDR", zero_height),
        idat_chunk,
        iend_chunk,
    }));

    // Raw data with an invalid filter type, on the first row and a later
    // one, and too few bytes.
    const bad_raws = [_][]const u8{
        "\x05abcd\x00efgh\x00ijkl",
        "\x00abcd\x00efgh\xffijkl",
        "\x00abcd\x00efgh\x00ijk",
    };
    for (bad_raws) |bad_raw| {
        const data = try deflate.compress(arena, bad_raw, .{});
        const chunks = [_]png_file.Chunk{ ihdr_chunk, chunk("IDAT", data), iend_chunk };
        try cases.append(arena, try arena.dupe(png_file.Chunk, &chunks));
    }
    // A zlib error of each kind through IDAT.
    const zlib_errors = [_][]const u8{
        "\x78\x9d\x03\x00",
        "\x78\xbb\x03\x00",
        "\x79\x18\x03\x00",
        "\x78\x01\x07\x00",
        "\x78\x01",
    };
    for (zlib_errors) |data| {
        const chunks = [_]png_file.Chunk{ ihdr_chunk, chunk("IDAT", data), iend_chunk };
        try cases.append(arena, try arena.dupe(png_file.Chunk, &chunks));
    }

    for (cases.items, 0..) |chunks, i| {
        const bytes = try png_file.file(arena, chunks);
        const name = try std.fmt.allocPrint(arena, "damaged case {d}", .{i});
        try oracle.expectAllSame(gpa, bytes, .{ .name = name });
    }
    // Not a PNG: each byte of the signature wrong.
    const bytes = try png_file.file(arena, &.{ ihdr_chunk, idat_chunk, iend_chunk });
    for (0..8) |at| {
        const bad = try arena.dupe(u8, bytes);
        bad[at] ^= 0x40;
        try expectSomeSame(bad, .{ .name = "bad signature" });
    }
}

test "png: every truncation of a file fails or decodes as in the original" {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var prng: std.Random.DefaultPrng = .init(5);
    const rng = prng.random();
    const files = [_][]const u8{
        try png_file.random(arena, rng, .{
            .width = 5,
            .height = 4,
            .depth = 2,
            .color = 3,
            .interlace = true,
        }, .{
            .trns = "\x10\x80",
        }),
        try png_file.random(arena, rng, .{ .width = 3, .height = 3, .depth = 16, .color = 6 }, .{}),
        try png_file.random(arena, rng, .{ .width = 4, .height = 2, .color = 2 }, .{
            .cgbi = true,
            .kind = .stored,
        }),
    };
    for (files) |file| {
        for (0..file.len) |n| try expectSomeSame(file[0..n], .{ .name = "truncated", .case = n });
    }
}

test "png: IDAT data in many chunks, among ancillary chunks, decodes as in the original" {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var prng: std.Random.DefaultPrng = .init(6);
    const rng = prng.random();
    const image: Image = .{ .width = 13, .height = 11, .color = 6, .interlace = true };
    const raw = try png_file.rawData(arena, rng, image, 0, null);
    for ([_]deflate.BlockKind{ .stored, .fixed, .dynamic }) |kind| {
        const data = try deflate.compress(arena, raw, .{ .kind = kind, .block_size = 97 });
        var chunks: std.ArrayList(png_file.Chunk) = .empty;
        try chunks.append(arena, chunk("IHDR", &png_file.ihdr(image)));
        var at: usize = 0;
        var piece: usize = 1;
        while (at < data.len) : (piece += 1) {
            const n = @min(piece, data.len - at);
            try chunks.append(arena, chunk("IDAT", data[at..][0..n]));
            if (piece % 3 == 0) try chunks.append(arena, chunk("tEXt", "Comment\x00hi"));
            if (piece % 4 == 0) try chunks.append(arena, chunk("IDAT", ""));
            at += n;
        }
        try chunks.append(arena, chunk("IEND", ""));
        try chunks.append(arena, chunk("zzzz", "after the end"));
        const bytes = try png_file.file(arena, chunks.items);
        try oracle.expectAllSame(gpa, bytes, .{ .name = "split IDAT" });
    }
}

test "png: more pixel data than the image needs is ignored, as in the original" {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var prng: std.Random.DefaultPrng = .init(8);
    const rng = prng.random();
    for ([_]bool{ false, true }) |interlace| {
        const image: Image = .{ .width = 6, .height = 6, .color = 2, .interlace = interlace };
        const raw = try png_file.rawData(arena, rng, image, 0, null);
        const longer = try arena.alloc(u8, raw.len + 50);
        @memcpy(longer[0..raw.len], raw);
        @memset(longer[raw.len..], 0);
        const bytes = try greyFile(arena, image, longer);
        try oracle.expectAllSame(gpa, bytes, .{ .name = "extra data" });
    }
}

test "png: the largest dimensions decode or fail as in the original" {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const max = 1 << 24;
    // One row of the widest image, all zeros.
    const raw = try arena.alloc(u8, 2 * max);
    @memset(raw, 0);
    const widest = try greyFile(arena, .{ .width = max, .height = 1 }, raw[0 .. max + 1]);
    try oracle.expectLoadSame(gpa, widest, .{}, .{ .name = "widest" }, .same);
    try oracle.expectLoadSame(gpa, widest, .{ .bits = .u16 }, .{ .name = "widest" }, .same);
    try oracle.expectQuerySame(widest, .info, .memory, .{ .name = "widest" });
    const tallest = try greyFile(arena, .{ .width = 1, .height = max }, raw[0 .. 2 * max]);
    try oracle.expectLoadSame(gpa, tallest, .{}, .{ .name = "tallest" }, .same);

    const tiny = try deflate.compress(arena, "\x00\x00", .{});
    const headers = [_]Image{
        .{ .width = max + 1, .height = 1 },
        .{ .width = 1, .height = max + 1 },
        .{ .width = max, .height = max },
        .{ .width = max, .height = 64 },
        .{ .width = max, .height = 65 },
        .{ .width = max, .height = 17, .color = 3 },
        .{ .width = max, .height = 16, .color = 3 },
        // 16-bit images at the original's int limit for the inflated size:
        // past it the original's allocation fails without a reason.
        .{ .width = 32768, .height = 32768, .depth = 16 },
        .{ .width = 32767, .height = 32768, .depth = 16 },
        .{ .width = 16384, .height = 16384, .depth = 16, .color = 2 },
    };
    for (headers, 0..) |image, i| {
        var chunks: std.ArrayList(png_file.Chunk) = .empty;
        try chunks.append(arena, chunk("IHDR", &png_file.ihdr(image)));
        if (image.color == 3) try chunks.append(arena, chunk("PLTE", "\x00\x00\x00"));
        try chunks.append(arena, chunk("IDAT", tiny));
        try chunks.append(arena, chunk("IEND", ""));
        const bytes = try png_file.file(arena, chunks.items);
        const label: oracle.Label = .{ .name = "large header", .case = i };
        try oracle.expectLoadSame(gpa, bytes, .{}, label, .same);
        try oracle.expectLoadSame(gpa, bytes, .{ .bits = .f32 }, label, .same);
        const grey_alpha: oracle.Request = .{ .options = .{ .components = .grey_alpha } };
        try oracle.expectLoadSame(gpa, bytes, grey_alpha, label, .same);
        try oracle.expectQuerySame(bytes, .info, .memory, label);
        try oracle.expectQuerySame(bytes, .is_16_bit, .memory, label);
    }
}

test "png: a smaller dimension limit refuses larger images" {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var prng: std.Random.DefaultPrng = .init(9);
    const bytes = try png_file.random(arena, prng.random(), .{ .width = 9, .height = 8 }, .{});
    var image = try stbi.loadFromMemory(u8, gpa, bytes, .{ .limits = .{ .dimension_max = 9 } });
    image.deinit(gpa);
    try std.testing.expectError(
        error.DimensionTooLarge,
        stbi.loadFromMemory(u8, gpa, bytes, .{ .limits = .{ .dimension_max = 8 } }),
    );
    try std.testing.expectError(
        error.OutOfMemory,
        stbi.loadFromMemory(u8, gpa, bytes, .{ .limits = .{ .bytes_max = 71 } }),
    );
}

test "png: palette indices past every PLTE are refused, where the original reads garbage" {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const image: Image = .{ .width = 4, .height = 1, .color = 3 };
    const header = png_file.ihdr(image);
    const plte = "\x10\x20\x30\x40\x50\x60\x70\x80\x90";
    const past = try deflate.compress(arena, "\x00\x00\x01\x02\x03", .{});
    const within = try deflate.compress(arena, "\x00\x00\x01\x02\x02", .{});
    const refused = [_][]const png_file.Chunk{
        &.{ chunk("IHDR", &header), chunk("PLTE", plte), chunk("IDAT", past), chunk("IEND", "") },
        &.{
            chunk("IHDR", &png_file.ihdr(.{ .width = 9, .height = 1, .color = 3, .depth = 1 })),
            chunk("PLTE", plte[0..3]),
            .{ .kind = "IDAT", .data = try deflate.compress(arena, "\x00\xff\x80", .{}) },
            chunk("IEND", ""),
        },
    };
    for (refused) |chunks| {
        const bytes = try png_file.file(arena, chunks);
        for ([_]stbi.Components{ .file, .rgb, .rgba, .grey }) |components| {
            const request: oracle.Request = .{ .options = .{ .components = components } };
            const label: oracle.Label = .{ .name = "index past the palette" };
            try oracle.expectLoadSame(gpa, bytes, request, label, .port_refuses);
        }
        const result = stbi.loadFromMemory(u8, gpa, bytes, .{});
        try std.testing.expectError(error.PngPaletteIndex, result);
    }
    // A shorter PLTE after a longer one leaves the longer one's entries,
    // which the original reads: the port gives the same.
    const same = [_][]const png_file.Chunk{
        &.{ chunk("IHDR", &header), chunk("PLTE", plte), chunk("IDAT", within), chunk("IEND", "") },
        &.{
            chunk("IHDR", &header),
            chunk("PLTE", plte),
            chunk("PLTE", plte[0..3]),
            chunk("IDAT", within),
            chunk("IEND", ""),
        },
        &.{
            chunk("IHDR", &header),
            chunk("PLTE", plte),
            chunk("tRNS", "\x01\x02\x03"),
            chunk("PLTE", plte[3..]),
            chunk("IDAT", within),
            chunk("IEND", ""),
        },
        &.{
            chunk("IHDR", &header),
            chunk("PLTE", plte),
            chunk("IDAT", within),
            chunk("PLTE", plte[0..3]),
            chunk("IEND", ""),
        },
    };
    for (same) |chunks| {
        try oracle.expectAllSame(gpa, try png_file.file(arena, chunks), .{ .name = "second PLTE" });
    }
}

/// Small files of every kind, for fuzzing.
fn fuzzSeeds(arena: std.mem.Allocator) ![]const []const u8 {
    var seeds: std.ArrayList([]const u8) = .empty;
    var prng: std.Random.DefaultPrng = .init(0xf022);
    const rng = prng.random();
    for (combinations) |combination| {
        for (combination.depths) |depth| {
            for ([_]bool{ false, true }) |interlace| {
                const color = combination.color;
                const image: Image = .{
                    .width = 5,
                    .height = 4,
                    .depth = depth,
                    .color = color,
                    .interlace = interlace,
                };
                var trns: ?[]const u8 = null;
                if (color == 0 or color == 2) trns = try colourKey(arena, rng, image);
                if (combination.color == 3) trns = "\x00\x80\xff";
                const plain: png_file.Options = .{ .trns = trns, .kind = .fixed };
                try seeds.append(arena, try png_file.random(arena, rng, image, plain));
                const iphone: png_file.Options = .{ .cgbi = true, .kind = .dynamic };
                try seeds.append(arena, try png_file.random(arena, rng, image, iphone));
            }
        }
    }
    var set = try corpus.load(gpa, std.testing.io, .stb, "tests/pngsuite", &.{".png"});
    defer set.deinit(gpa);
    for (set.entries) |entry| {
        if (entry.bytes.len < 1500) try seeds.append(arena, try arena.dupe(u8, entry.bytes));
    }
    return seeds.toOwnedSlice(arena);
}

test "fuzz: mutated PNGs decode or fail as in the original" {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try fuzz.run(gpa, .{ .name = "png", .seed = 0x5eed_3001, .cases = 3000 }, try fuzzSeeds(arena));
}

fn loadForFailures(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    components: stbi.Components,
) !void {
    var image = try stbi.loadFromMemory(u8, allocator, bytes, .{ .components = components });
    image.deinit(allocator);
    var wide = try stbi.loadFromMemory(u16, allocator, bytes, .{ .components = components });
    wide.deinit(allocator);
}

test "png: each allocation failure of a decode is reported and leaks nothing" {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var prng: std.Random.DefaultPrng = .init(10);
    const rng = prng.random();
    const File = struct { image: Image, trns: ?[]const u8, components: stbi.Components };
    const files = [_]File{
        .{
            .image = .{ .width = 9, .height = 7, .color = 3, .interlace = true },
            .trns = "\x00\x80",
            .components = .grey,
        },
        .{
            .image = .{ .width = 9, .height = 7, .color = 3, .depth = 4 },
            .trns = null,
            .components = .rgba,
        },
        .{
            .image = .{ .width = 6, .height = 5, .depth = 16, .color = 2, .interlace = true },
            .trns = "\x00\x01\x00\x02\x00\x03",
            .components = .grey,
        },
        .{
            .image = .{ .width = 6, .height = 5, .color = 0 },
            .trns = "\x00\x10",
            .components = .rgb,
        },
    };
    for (files) |f| {
        const bytes = try png_file.random(arena, rng, f.image, .{ .trns = f.trns });
        try std.testing.checkAllAllocationFailures(gpa, loadForFailures, .{ bytes, f.components });
    }
}
