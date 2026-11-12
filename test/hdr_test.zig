//! Radiance HDR files against the original: the corpus, hand-made files of
//! every header form and pixel encoding, truncations, and fuzzing.

const std = @import("std");
const stbi = @import("stb_image");
const oracle = @import("oracle.zig");
const corpus = @import("corpus.zig");
const fuzz = @import("fuzz.zig");

const gpa = std.testing.allocator;

/// Whether the port refuses `bytes` because its flat pixels end early,
/// where the original converts uninitialized memory. The decoder reaches
/// the same point whatever the request, so a float load from memory and
/// one through a reader decide it.
fn flatPixelsEndEarly(bytes: []const u8) bool {
    if (stbi.loadFromMemory(f32, gpa, bytes, .{})) |image| {
        var copy = image;
        copy.deinit(gpa);
    } else |err| if (err == error.HdrTruncated) return true;
    var reader: std.Io.Reader = .fixed(bytes);
    if (stbi.loadFromReader(f32, gpa, &reader, .{})) |image| {
        var copy = image;
        copy.deinit(gpa);
    } else |err| if (err == error.HdrTruncated) return true;
    return false;
}

/// Every load and query of `bytes` against the original, or, where its
/// flat pixels end early, the port refusing every load.
fn expectHdrSame(bytes: []const u8, label: oracle.Label) !void {
    if (!flatPixelsEndEarly(bytes)) return oracle.expectAllSame(gpa, bytes, label);
    try expectRefused(bytes, label);
}

fn expectRefused(bytes: []const u8, label: oracle.Label) !void {
    for ([_]oracle.Bits{ .u8, .u16, .f32 }) |bits| {
        for ([_]oracle.Via{ .memory, .callbacks }) |via| {
            try oracle.expectLoadSame(
                gpa,
                bytes,
                .{ .bits = bits, .via = via },
                label,
                .port_refuses,
            );
        }
    }
    for ([_]oracle.Query{ .info, .is_16_bit, .is_hdr }) |query| {
        try oracle.expectQuerySame(bytes, query, .memory, label);
    }
}

/// Writes HDR files: a header, then pixels flat or run-length encoded.
const Writer = struct {
    bytes: std.ArrayList(u8) = .empty,

    fn deinit(w: *Writer) void {
        w.bytes.deinit(gpa);
    }

    fn add(w: *Writer, data: []const u8) !void {
        try w.bytes.appendSlice(gpa, data);
    }

    fn print(w: *Writer, comptime fmt: []const u8, args: anytype) !void {
        try w.bytes.print(gpa, fmt, args);
    }

    fn header(w: *Writer, width: u32, height: u32) !void {
        try w.add("#?RADIANCE\n# made by the tests\nFORMAT=32-bit_rle_rgbe\nEXPOSURE=1.0\n\n");
        try w.print("-Y {d} +X {d}\n", .{ height, width });
    }

    /// One scanline in the run-length form: for each byte of the pixels,
    /// runs where at least `min_run` bytes repeat, literals elsewhere.
    fn rleScanline(w: *Writer, pixels: []const [4]u8, min_run: usize) !void {
        try w.add(&.{ 2, 2, @intCast(pixels.len >> 8), @intCast(pixels.len & 0xff) });
        for (0..4) |k| {
            var i: usize = 0;
            while (i < pixels.len) {
                var run: usize = 1;
                while (i + run < pixels.len and run < 127 and
                    pixels[i + run][k] == pixels[i][k]) run += 1;
                if (run >= min_run) {
                    try w.add(&.{ @intCast(128 + run), pixels[i][k] });
                    i += run;
                    continue;
                }
                // Literals up to the next run worth taking.
                var count: usize = 0;
                while (i + count < pixels.len and count < 128) : (count += 1) {
                    var ahead: usize = 1;
                    const at = i + count;
                    while (at + ahead < pixels.len and ahead < min_run and
                        pixels[at + ahead][k] == pixels[at][k]) ahead += 1;
                    if (ahead >= min_run) break;
                }
                if (count == 0) count = 1;
                try w.bytes.append(gpa, @intCast(count));
                for (pixels[i..][0..count]) |p| try w.bytes.append(gpa, p[k]);
                i += count;
            }
        }
    }
};

/// A pattern of RGBE pixels with runs and noise, every exponent included.
fn pattern(pixels: [][4]u8, seed: u64) void {
    var prng: std.Random.DefaultPrng = .init(seed);
    const rng = prng.random();
    for (pixels, 0..) |*p, i| {
        if (i % 7 < 3) {
            p.* = .{ 200, 100, 50, @intCast(128 + i % 9) };
        } else {
            p.* = .{ rng.int(u8), rng.int(u8), rng.int(u8), @intCast(i % 256) };
        }
    }
}

fn makeRle(width: u32, height: u32, min_run: usize, seed: u64) ![]u8 {
    var w: Writer = .{};
    errdefer w.deinit();
    try w.header(width, height);
    const pixels = try gpa.alloc([4]u8, width);
    defer gpa.free(pixels);
    for (0..height) |row| {
        pattern(pixels, seed + row);
        try w.rleScanline(pixels, min_run);
    }
    return w.bytes.toOwnedSlice(gpa);
}

fn makeFlat(width: u32, height: u32, seed: u64) ![]u8 {
    var w: Writer = .{};
    errdefer w.deinit();
    try w.header(width, height);
    const pixels = try gpa.alloc([4]u8, @as(usize, width) * height);
    defer gpa.free(pixels);
    pattern(pixels, seed);
    for (pixels) |p| try w.add(&p);
    return w.bytes.toOwnedSlice(gpa);
}

test "the HDR corpus decodes as in the original" {
    var set = try corpus.load(gpa, std.testing.io, .image_rs, "tests/images/hdr", &.{".hdr"});
    defer set.deinit(gpa);
    try std.testing.expect(set.entries.len >= 4);
    for (set.entries) |entry| try expectHdrSame(entry.bytes, .{ .name = entry.name });
    var exr = try corpus.load(gpa, std.testing.io, .image_rs, "tests/images/exr", &.{".hdr"});
    defer exr.deinit(gpa);
    for (exr.entries) |entry| try expectHdrSame(entry.bytes, .{ .name = entry.name });
}

test "run-length encoded HDR files of many sizes decode as in the original" {
    const sizes = [_][2]u32{
        .{ 8, 1 },
        .{ 8, 3 },
        .{ 9, 2 },
        .{ 31, 5 },
        .{ 128, 4 },
        .{ 300, 2 },
        .{ 32767, 1 },
    };
    for (sizes) |size| {
        for ([_]usize{ 2, 3, 200 }) |min_run| {
            const bytes = try makeRle(size[0], size[1], min_run, size[0]);
            defer gpa.free(bytes);
            try expectHdrSame(bytes, .{ .name = "rle" });
        }
    }
}

test "flat HDR files, narrower than 8 or 32768 and wider, decode as in the original" {
    const sizes = [_][2]u32{
        .{ 1, 1 },
        .{ 7, 3 },
        .{ 2, 9 },
        .{ 32768, 1 },
        .{ 32769, 2 },
        .{ 0, 5 },
        .{ 5, 0 },
    };
    for (sizes) |size| {
        const bytes = try makeFlat(size[0], size[1], 77);
        defer gpa.free(bytes);
        try expectHdrSame(bytes, .{ .name = "flat" });
    }
}

test "an HDR file in the old run-length form is read flat after its first pixel" {
    // Wide enough for the run-length form, but the scanline does not start
    // with 2, 2: the original reads the whole image flat.
    for ([_][4]u8{ .{ 1, 2, 3, 130 }, .{ 2, 2, 0x80, 129 }, .{ 2, 1, 5, 140 } }) |start| {
        var w: Writer = .{};
        defer w.deinit();
        try w.header(16, 3);
        try w.add(&start);
        var pixels: [16 * 3 - 1][4]u8 = undefined;
        pattern(&pixels, 5);
        for (pixels) |p| try w.add(&p);
        try expectHdrSame(w.bytes.items, .{ .name = "old rle" });
    }
    // A run-length scanline, then one in the old form: the rest is flat
    // pixels from the first one on.
    var w: Writer = .{};
    defer w.deinit();
    try w.header(10, 3);
    var line: [10][4]u8 = undefined;
    pattern(&line, 9);
    try w.rleScanline(&line, 2);
    try w.add(&.{ 9, 9, 9, 129 });
    var pixels: [10 * 3 - 1][4]u8 = undefined;
    pattern(&pixels, 10);
    for (pixels) |p| try w.add(&p);
    try expectHdrSame(w.bytes.items, .{ .name = "old rle second line" });
}

test "bad HDR runs and scanline lengths fail as in the original" {
    const base = try makeRle(12, 2, 3, 1);
    defer gpa.free(base);
    const data = std.mem.indexOf(u8, base, "+X 12\n").? + 6;
    const cases = [_][]const u8{
        &.{ 2, 2, 0, 11 }, // a scanline length that is not the width
        &.{ 2, 2, 0x7f, 0xff }, // likewise, at the most
        &.{ 2, 2, 0, 12, 0 }, // a zero count
        &.{ 2, 2, 0, 12, 128 + 13, 1 }, // a run past the width
        &.{ 2, 2, 0, 12, 13 }, // literals past the width
        &.{ 2, 2, 0, 12, 128, 1 }, // a run of 0 is a literal of 128, past the width
    };
    for (cases) |case| {
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(gpa);
        try bytes.appendSlice(gpa, base[0..data]);
        try bytes.appendSlice(gpa, case);
        try bytes.appendSlice(gpa, base[data + case.len ..]);
        try expectHdrSame(bytes.items, .{ .name = "bad rle" });
    }
}

test "every HDR header form is read as in the original" {
    const headers = [_][]const u8{
        "#?RADIANCE\nFORMAT=32-bit_rle_rgbe\n\n-Y 2 +X 3\n",
        "#?RGBE\nFORMAT=32-bit_rle_rgbe\n\n-Y 2 +X 3\n",
        "#?RADIANCE\n\n-Y 2 +X 3\n", // no format line
        "#?RADIANCE\nFORMAT=32-bit_rle_xyze\n\n-Y 2 +X 3\n",
        "#?RADIANCE\nFORMAT=32-bit_rle_rgbe \n\n-Y 2 +X 3\n",
        "#?RADIANCE\nFORMAT=32-bit_rle_rgbe\n\n+Y 2 +X 3\n",
        "#?RADIANCE\nFORMAT=32-bit_rle_rgbe\n\n-Y 2 -X 3\n",
        "#?RADIANCE\nFORMAT=32-bit_rle_rgbe\n\n-Y 2   +X 3\n",
        "#?RADIANCE\nFORMAT=32-bit_rle_rgbe\n\n-Y   2 +X    3 junk\n",
        "#?RADIANCE\nFORMAT=32-bit_rle_rgbe\n\n-Y +2 +X +3\n",
        "#?RADIANCE\nFORMAT=32-bit_rle_rgbe\n\n-Y x +X 3\n",
        "#?RADIANCE\nFORMAT=32-bit_rle_rgbe\n\n-Y 2 +X\n",
        "#?RADIANCE\nFORMAT=32-bit_rle_rgbe\n\n-Y 2 +X x\n",
        "#?RADIANCE\nFORMAT=32-bit_rle_rgbe\n\n-Y 4294967298 +X 3\n", // wraps to 2
        "#?RADIANCE\nFORMAT=32-bit_rle_rgbe\n\n-Y 16777217 +X 3\n",
        "#?RADIANCE\nFORMAT=32-bit_rle_rgbe\n\n-Y 2 +X 16777217\n",
        "#?RADIANCE\nFORMAT=32-bit_rle_rgbe\n\n-Y 60000 +X 60000\n",
        "#?RADIANCE\nFORMAT=32-bit_rle_rgbe\x00junk\n\n-Y 2 +X 3\n", // a NUL ends the line
        "#?RADIANCE\x00\nFORMAT=32-bit_rle_rgbe\n\n-Y 2 +X 3\n",
        "#?RADIANCE\n\x00comment\nFORMAT=32-bit_rle_rgbe\n\n-Y 2 +X 3\n",
        "#?RADIANCE \nFORMAT=32-bit_rle_rgbe\n\n-Y 2 +X 3\n",
        "#?RADIANCE\r\nFORMAT=32-bit_rle_rgbe\n\n-Y 2 +X 3\n",
        "#?RADIANC\nFORMAT=32-bit_rle_rgbe\n\n-Y 2 +X 3\n",
    };
    for (headers) |header| {
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(gpa);
        try bytes.appendSlice(gpa, header);
        for (0..6 * 4) |i| try bytes.append(gpa, @intCast(i * 37 % 256));
        try expectHdrSame(bytes.items, .{ .name = header });
    }
    // The original's info reports these sizes as negative; the port's info
    // refuses them, and both loads fail.
    const negative = [_][]const u8{
        "#?RADIANCE\nFORMAT=32-bit_rle_rgbe\n\n-Y -2 +X 3\n",
        "#?RADIANCE\nFORMAT=32-bit_rle_rgbe\n\n-Y 2 +X 99999999999999999999\n",
        "#?RADIANCE\nFORMAT=32-bit_rle_rgbe\n\n-Y 2 +X 2147483648\n",
    };
    for (negative) |header| {
        const label: oracle.Label = .{ .name = header };
        for ([_]oracle.Bits{ .u8, .u16, .f32 }) |bits| {
            try oracle.expectLoadSame(gpa, header, .{ .bits = bits }, label, .same);
        }
        try oracle.expectQuerySame(header, .is_hdr, .memory, label);
        try std.testing.expectError(error.UnknownImageType, stbi.infoFromMemory(header));
    }
}

test "HDR header lines of 1023 bytes and more are cut as in the original" {
    for ([_]usize{ 1021, 1022, 1023, 1024, 3000 }) |len| {
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(gpa);
        try bytes.appendSlice(gpa, "#?RADIANCE\n#");
        try bytes.appendNTimes(gpa, 'x', len - 1);
        try bytes.appendSlice(
            gpa,
            "\nFORMAT=32-bit_rle_rgbe\n\n-Y 1 +X 2\n\x01\x02\x03\x80\x04\x05\x06\x81",
        );
        try expectHdrSame(bytes.items, .{ .name = "long line" });
        // The format line itself past the cut.
        bytes.clearRetainingCapacity();
        try bytes.appendSlice(gpa, "#?RADIANCE\n");
        try bytes.appendNTimes(gpa, 'F', len);
        try bytes.appendSlice(
            gpa,
            "FORMAT=32-bit_rle_rgbe\n\n-Y 1 +X 2\n\x01\x02\x03\x80\x04\x05\x06\x81",
        );
        try expectHdrSame(bytes.items, .{ .name = "long format line" });
    }
}

test "an HDR file truncated at every byte fails or decodes as in the original" {
    const files = [_][]u8{ try makeRle(9, 2, 2, 3), try makeFlat(3, 2, 4) };
    defer for (files) |file| gpa.free(file);
    for (files) |file| {
        for (0..file.len) |len| try expectHdrSame(file[0..len], .{ .name = "truncated" });
    }
}

test "an HDR file whose flat pixels end early is refused" {
    const bytes = try makeFlat(3, 2, 4);
    defer gpa.free(bytes);
    try std.testing.expectError(
        error.HdrTruncated,
        stbi.loadFromMemory(f32, gpa, bytes[0 .. bytes.len - 1], .{}),
    );
    try std.testing.expectError(
        error.HdrTruncated,
        stbi.loadFromMemory(u8, gpa, bytes[0 .. bytes.len - 4], .{}),
    );
}

test "HDR files load at other gammas and scales as in the original" {
    const bytes = try makeRle(64, 3, 2, 8);
    defer gpa.free(bytes);
    const settings = [_][2]f32{ .{ 1.0, 1.0 }, .{ 2.4, 0.5 }, .{ 0.7, 3.0 }, .{ 1.8, 0.01 } };
    for (settings) |s| {
        for ([_]oracle.Bits{ .u8, .u16 }) |bits| {
            for (0..5) |comp| {
                try oracle.expectLoadSame(gpa, bytes, .{ .bits = bits, .options = .{
                    .components = @fromBackingInt(@as(u3, @intCast(comp))),
                    .hdr_to_ldr_gamma = s[0],
                    .hdr_to_ldr_scale = s[1],
                } }, .{ .name = "gamma" }, .same);
            }
        }
    }
}

test "the HDR size limit refuses as the original's maximum dimension does" {
    const bytes = try makeRle(64, 3, 2, 8);
    defer gpa.free(bytes);
    try std.testing.expectError(error.DimensionTooLarge, stbi.loadFromMemory(f32, gpa, bytes, .{
        .limits = .{ .dimension_max = 63 },
    }));
    try std.testing.expectError(error.TooLargeHdr, stbi.loadFromMemory(f32, gpa, bytes, .{
        .limits = .{ .bytes_max = 64 * 3 * 3 * 4 - 1 },
    }));
}

fn loadForAllocationFailures(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    bits: oracle.Bits,
) !void {
    switch (bits) {
        inline else => |b| {
            const T = switch (b) {
                .u8 => u8,
                .u16 => u16,
                .f32 => f32,
            };
            var image = stbi.loadFromMemory(
                T,
                allocator,
                bytes,
                .{ .components = .grey_alpha },
            ) catch |err| {
                if (err == error.OutOfMemory) return err;
                return error.TestUnexpectedResult;
            };
            image.deinit(allocator);
        },
    }
}

test "an HDR load that runs out of memory at any allocation leaks nothing" {
    const bytes = try makeRle(16, 3, 2, 8);
    defer gpa.free(bytes);
    for ([_]oracle.Bits{ .u8, .u16, .f32 }) |bits| {
        try std.testing.checkAllAllocationFailures(
            gpa,
            loadForAllocationFailures,
            .{ bytes, bits },
        );
    }
}

/// The fuzz test's seeds: the corpus and hand-made files, in `arena`.
pub fn fuzzInputs(arena: std.mem.Allocator) ![]const []const u8 {
    const set = try corpus.load(arena, std.testing.io, .image_rs, "tests/images/hdr", &.{".hdr"});
    var inputs: std.ArrayList([]const u8) = .empty;
    for (set.entries) |entry| try inputs.append(arena, entry.bytes);
    const made = [_][]u8{
        try makeRle(9, 3, 2, 1), try makeRle(40, 2, 3, 2), try makeFlat(3, 3, 3),
        try makeFlat(1, 1, 4),
    };
    defer for (made) |bytes| gpa.free(bytes);
    for (made) |bytes| try inputs.append(arena, try arena.dupe(u8, bytes));
    return inputs.items;
}

/// Whether a fuzz case's load is one the original is undefined on: flat
/// pixels that end early.
pub fn unsafeCall(bytes: []const u8, request: oracle.Request) ?fuzz.Call {
    _ = request;
    return if (flatPixelsEndEarly(bytes)) .load else null;
}

test "fuzz: mutated HDR files decode as in the original" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    try fuzz.run(gpa, hdr_fuzz, try fuzzInputs(arena.allocator()));
}

pub const hdr_fuzz: fuzz.Config = .{
    .name = "hdr",
    .seed = 0x4d52_0001,
    .cases = 2000,
    .unsafe = @import("hdr_unsafe.zig").unsafe,
};
