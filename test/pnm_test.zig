//! PNM against the original: the PGM, PPM and PBM test files, hand-made
//! headers with every maximum value, comment and number edge, and fuzzing.

const std = @import("std");
const stbi = @import("stb_image");
const oracle = @import("oracle.zig");
const fuzz = @import("fuzz.zig");
const corpus = @import("corpus.zig");

const gpa = std.testing.allocator;

const CorpusDir = struct { root: corpus.Root, dir: []const u8, extensions: []const []const u8 };

const corpus_dirs = [_]CorpusDir{
    .{ .root = .stb, .dir = "tests/pbm", .extensions = &.{ ".pgm", ".ppm" } },
    .{ .root = .libjpeg_turbo, .dir = "testimages", .extensions = &.{ ".pgm", ".ppm" } },
    .{
        .root = .image_rs,
        .dir = "tests/images/pbm",
        .extensions = &.{ ".pbm", ".pgm", ".ppm", ".pam" },
    },
};

/// Every test file, appended to `list`; the caller frees them.
fn corpusFiles(list: *std.ArrayList(corpus.Entry)) !void {
    for (corpus_dirs) |dir| {
        const set = try corpus.load(gpa, std.testing.io, dir.root, dir.dir, dir.extensions);
        defer gpa.free(set.entries);
        errdefer for (set.entries) |entry| {
            gpa.free(entry.name);
            gpa.free(entry.bytes);
        };
        try list.appendSlice(gpa, set.entries);
    }
}

fn freeEntries(list: *std.ArrayList(corpus.Entry)) void {
    for (list.items) |entry| {
        gpa.free(entry.name);
        gpa.free(entry.bytes);
    }
    list.deinit(gpa);
}

test "every PNM test file decodes or fails as in the original" {
    var files: std.ArrayList(corpus.Entry) = .empty;
    defer freeEntries(&files);
    try corpusFiles(&files);
    try std.testing.expect(files.items.len >= 10);
    var failures: usize = 0;
    for (files.items) |entry| {
        oracle.expectAllSame(gpa, entry.bytes, .{ .name = entry.name }) catch {
            failures += 1;
        };
    }
    try std.testing.expectEqual(0, failures);
}

/// `header` followed by `data_len` random bytes.
fn withData(rng: std.Random, header: []const u8, data_len: usize) ![]u8 {
    const bytes = try gpa.alloc(u8, header.len + data_len);
    @memcpy(bytes[0..header.len], header);
    rng.bytes(bytes[header.len..]);
    return bytes;
}

fn expectPnm(rng: std.Random, header: []const u8, data_len: usize, name: []const u8) !void {
    const bytes = try withData(rng, header, data_len);
    defer gpa.free(bytes);
    try oracle.expectAllSame(gpa, bytes, .{ .name = name });
}

test "both kinds at every maximum value and size decode or fail as in the original" {
    var prng: std.Random.DefaultPrng = .init(0x9a30_0001);
    const rng = prng.random();
    var header: [64]u8 = undefined;
    for ([_]u8{ '5', '6' }) |kind| {
        const comp: usize = if (kind == '6') 3 else 1;
        for ([_]u32{ 0, 1, 2, 15, 255, 256, 1023, 65535, 65536, 99999 }) |max_value| {
            for ([_][2]u32{ .{ 1, 1 }, .{ 3, 2 }, .{ 17, 5 } }) |size| {
                const text = try std.fmt.bufPrint(&header, "P{c}\n{d} {d}\n{d}\n", .{
                    kind, size[0], size[1], max_value,
                });
                const sample_size: usize = if (max_value > 255) 2 else 1;
                const data_len = comp * size[0] * size[1] * sample_size;
                try expectPnm(rng, text, data_len, "maximum value");
                // One byte short: the original refuses it as truncated.
                try expectPnm(rng, text, data_len - 1, "maximum value, short");
            }
        }
    }
}

test "whitespace and comments anywhere in the header decode as in the original" {
    var prng: std.Random.DefaultPrng = .init(0x9a30_0002);
    const rng = prng.random();
    const headers = [_][]const u8{
        "P5 3 2 255 ",
        "P5\t3\x0b2\x0c255\r",
        "P5#comment\n3 2 255\n",
        "P5\n#comment\r3#another\n2\n#\n255\n",
        "P5\n# one\n# two\n\n\n3\n\n2\n255\n",
        "P5   \t\n\r 3 # width\n 2 # height\n 255\n",
        "P6#\n3#\n2#\n255#\n",
        "P6 0003 0002 00255\n",
        "P5 3 2 255\n\n",
        "P5 3 2 255x",
        "P5\n3 2\n255", // no byte after the maximum value
        "P5\n3 2\n# a comment to the end",
        "P53 2 255\n",
        "P5 3 2",
        "P5 3",
        "P5",
        "P5 ",
        "P5 \n#",
    };
    for (headers) |header| {
        for ([_]usize{ 0, 6, 18, 40 }) |data_len| {
            try expectPnm(rng, header, data_len, "whitespace and comments");
        }
    }
}

test "numbers at the edge of an int, and past it, decode or fail as in the original" {
    var prng: std.Random.DefaultPrng = .init(0x9a30_0003);
    const rng = prng.random();
    // After 214748364 the original compares the next byte, digit or not,
    // with '7', as a signed char.
    const numbers = [_][]const u8{
        "0",
        "1",
        "16777216",
        "16777217",
        "21474836",
        "214748363",
        "214748364",
        "214748365",
        "2147483647",
        "2147483648",
        "4294967296",
        "9999999999",
        "00000000000000000001",
        "214748364:",
        "214748364\x80",
        "214748364\xff",
        "214748364 ",
    };
    var header: [128]u8 = undefined;
    for (numbers) |number| {
        for (0..3) |field| {
            const text = switch (field) {
                0 => try std.fmt.bufPrint(&header, "P5 {s} 1 255\n", .{number}),
                1 => try std.fmt.bufPrint(&header, "P5 1 {s} 255\n", .{number}),
                else => try std.fmt.bufPrint(&header, "P5 1 1 {s}\n", .{number}),
            };
            try expectPnm(rng, text, 16, "numbers");
        }
    }
}

test "the largest sizes decode or fail as in the original" {
    var prng: std.Random.DefaultPrng = .init(0x9a30_0004);
    const rng = prng.random();
    const headers = [_][]const u8{
        "P5 16777216 1 255\n",
        "P5 1 16777216 255\n",
        "P5 16777217 1 255\n",
        "P5 1 16777217 255\n",
        "P6 16777216 1 65535\n",
        "P6 20000 20000 65535\n",
        "P6 16384 16384 255\n",
        "P5 46341 46341 255\n",
    };
    for (headers) |header| {
        // Short of the pixels: the original reads the size, then fails as
        // truncated without decoding.
        try expectPnm(rng, header, 64, "largest");
    }
    try expectPnm(rng, "P5 16777216 1 255\n", 1 << 24, "largest, whole");
}

test "a PNM cut short at every byte decodes or fails as in the original" {
    var prng: std.Random.DefaultPrng = .init(0x9a30_0005);
    const rng = prng.random();
    const headers = [_][]const u8{
        "P6\n# c\n4 3\n255\n",
        "P5 4 3 65535\n",
    };
    for (headers) |header| {
        const comp: usize = if (header[1] == '6') 3 else 1;
        const sample_size: usize = if (std.mem.indexOf(u8, header, "65535") != null) 2 else 1;
        const whole = try withData(rng, header, comp * 12 * sample_size);
        defer gpa.free(whole);
        for (0..whole.len + 1) |len| {
            try oracle.expectAllSame(gpa, whole[0..len], .{ .name = "cut short" });
        }
    }
}

test "other netpbm kinds are not read, as in the original" {
    var prng: std.Random.DefaultPrng = .init(0x9a30_0006);
    const rng = prng.random();
    const headers = [_][]const u8{
        "P1 3 2\n",
        "P2 3 2 255\n",
        "P3 3 2 255\n",
        "P4 3 2\n",
        "P7\n",
        "p5 3 2 255\n",
    };
    for (headers) |header| {
        try expectPnm(rng, header, 18, "other kinds");
    }
}

test "a 16-bit PNM gives its samples as stored, big-endian bytes in native words" {
    const bytes = "P5 2 1 65535\n\x12\x34\xab\xcd";
    var wide = try stbi.loadFromMemory(u16, gpa, bytes, .{});
    defer wide.deinit(gpa);
    const expected = [_]u16{
        std.mem.readInt(u16, "\x12\x34", .native),
        std.mem.readInt(u16, "\xab\xcd", .native),
    };
    try std.testing.expectEqualSlices(u16, &expected, wide.pixels);
    try std.testing.expect(stbi.is16BitFromMemory(bytes));
    try oracle.expectAllSame(gpa, bytes, .{ .name = "16-bit samples" });
}

fn handMadeSeeds(list: *std.ArrayList([]const u8), rng: std.Random) !void {
    const seeds = [_]struct { header: []const u8, data_len: usize }{
        .{ .header = "P5\n5 3\n255\n", .data_len = 15 },
        .{ .header = "P6 5 3 255\n", .data_len = 45 },
        .{ .header = "P5 5 3 65535\n", .data_len = 30 },
        .{ .header = "P6\n# a comment\n5 3\n# more\n1023\n", .data_len = 90 },
    };
    for (seeds) |seed| try list.append(gpa, try withData(rng, seed.header, seed.data_len));
}

const fuzz_config: fuzz.Config = .{
    .name = "pnm",
    .seed = 0x9a30_f000,
    .cases = 3000,
};

test "fuzz: mutated PNMs decode or fail as in the original" {
    var prng: std.Random.DefaultPrng = .init(0x9a30_0007);
    var files: std.ArrayList(corpus.Entry) = .empty;
    defer freeEntries(&files);
    try corpusFiles(&files);
    var hand_made: std.ArrayList([]const u8) = .empty;
    defer {
        for (hand_made.items) |input| gpa.free(input);
        hand_made.deinit(gpa);
    }
    try handMadeSeeds(&hand_made, prng.random());
    var inputs: std.ArrayList([]const u8) = .empty;
    defer inputs.deinit(gpa);
    for (files.items) |entry| try inputs.append(gpa, entry.bytes);
    try inputs.appendSlice(gpa, hand_made.items);
    try fuzz.run(gpa, fuzz_config, inputs.items);
}

fn decodeAll(allocator: std.mem.Allocator, bytes: []const u8) !void {
    for ([_]stbi.Components{ .file, .grey, .rgba }) |components| {
        var image = try stbi.loadFromMemory(u8, allocator, bytes, .{ .components = components });
        image.deinit(allocator);
        var wide = try stbi.loadFromMemory(u16, allocator, bytes, .{ .components = components });
        wide.deinit(allocator);
    }
}

test "a PNM decode frees everything when any allocation fails" {
    var prng: std.Random.DefaultPrng = .init(0x9a30_0008);
    const rng = prng.random();
    const files = [_]struct { header: []const u8, data_len: usize }{
        .{ .header = "P6 4 3 255\n", .data_len = 36 },
        .{ .header = "P5 4 3 65535\n", .data_len = 24 },
    };
    for (files) |file| {
        const bytes = try withData(rng, file.header, file.data_len);
        defer gpa.free(bytes);
        try std.testing.checkAllAllocationFailures(gpa, decodeAll, .{bytes});
    }
}
