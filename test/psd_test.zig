//! PSD against the original: the psd-tools test files, hand-made files of
//! every channel count, depth and compression, PackBits runs of every
//! length byte, the 16-bit request, and fuzzing.

const std = @import("std");
const stbi = @import("stb_image");
const oracle = @import("oracle.zig");
const fuzz = @import("fuzz.zig");
const corpus = @import("corpus.zig");

const gpa = std.testing.allocator;

/// Test files whose merged image has a pixel colour below its white matte:
/// the original converts the out-of-range result to an integer, which is
/// undefined, and the port refuses the file.
const refused = [_][]const u8{};

fn isRefused(name: []const u8) bool {
    for (refused) |entry| {
        if (std.mem.eql(u8, entry, name)) return true;
    }
    return false;
}

fn corpusFiles() !corpus.Set {
    return corpus.load(gpa, std.testing.io, .psd_tools, "tests/psd_files", &.{ ".psd", ".psb" });
}

test "every PSD and PSB test file decodes or fails as in the original" {
    var set = try corpusFiles();
    defer set.deinit(gpa);
    try std.testing.expect(set.entries.len > 300);
    var failures: usize = 0;
    for (set.entries) |entry| {
        const expect: oracle.Expect = if (isRefused(entry.name)) .port_refuses else .same;
        oracle.expectAll(gpa, entry.bytes, .{ .name = entry.name }, expect) catch {
            failures += 1;
        };
    }
    try std.testing.expectEqual(0, failures);
}

test "the PSD test files the port refuses have colours outside their matte" {
    var set = try corpusFiles();
    defer set.deinit(gpa);
    var found: usize = 0;
    for (set.entries) |entry| {
        if (!isRefused(entry.name)) continue;
        found += 1;
        const result = stbi.loadFromMemory(u8, gpa, entry.bytes, .{});
        try std.testing.expectError(error.PsdMatteOutOfRange, result);
    }
    try std.testing.expectEqual(refused.len, found);
}

// --------------------------------------------------------
// A small PSD writer
// --------------------------------------------------------

const Psd = struct {
    version: u16 = 1,
    channels: u16,
    height: u32,
    width: u32,
    depth: u16,
    mode: u16 = 3,
    /// The lengths of the mode data, image resources and layers sections;
    /// each section is that many bytes of 0xee, up to 64.
    sections: [3]u32 = .{ 0, 0, 0 },
    compression: u16,
    /// The image data after the compression field.
    data: []const u8,
};

fn put(list: *std.ArrayList(u8), comptime T: type, value: T) !void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .big);
    try list.appendSlice(gpa, &bytes);
}

fn encodePsd(p: Psd) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(gpa);
    try list.appendSlice(gpa, "8BPS");
    try put(&list, u16, p.version);
    try list.appendSlice(gpa, &@as([6]u8, @splat(0)));
    try put(&list, u16, p.channels);
    try put(&list, u32, p.height);
    try put(&list, u32, p.width);
    try put(&list, u16, p.depth);
    try put(&list, u16, p.mode);
    for (p.sections) |len| {
        try put(&list, u32, len);
        for (0..@min(len, 64)) |_| try list.append(gpa, 0xee);
    }
    try put(&list, u16, p.compression);
    try list.appendSlice(gpa, p.data);
    return list.toOwnedSlice(gpa);
}

/// The decoded samples of `channels` channels of `pixel_count` pixels,
/// channel after channel. With four channels or more, every colour is at
/// or above its white matte, so removing it stays in range, also at the
/// top byte of a 16-bit sample.
fn makeSamples(rng: std.Random, channels: u16, pixel_count: usize, max: u16) ![]u16 {
    const samples = try gpa.alloc(u16, @as(usize, channels) * pixel_count);
    for (samples) |*sample| sample.* = rng.uintAtMost(u16, max);
    if (channels < 4) return samples;
    const alpha = samples[3 * pixel_count ..][0..pixel_count];
    for (alpha) |*a| {
        switch (rng.uintLessThan(u32, 4)) {
            0 => a.* = 0,
            1 => a.* = max,
            else => {},
        }
    }
    for (0..3) |channel| {
        const colour = samples[channel * pixel_count ..][0..pixel_count];
        for (colour, alpha) |*c, a| {
            // A pixel fully transparent or opaque keeps its colour.
            var low: u32 = 0;
            if (a != 0 and a != max) low = max - a;
            if (max == 65535) {
                const top: u32 = a >> 8;
                if (top != 0 and top != 255) low = @max(low, (255 - top) << 8);
            }
            c.* = @intCast(low + rng.uintAtMost(u32, max - low));
        }
    }
    return samples;
}

/// Raw image data of `samples`: bytes, or big-endian 16-bit words.
fn rawData(samples: []const u16, depth: u16) ![]u8 {
    const size: usize = depth / 8;
    const data = try gpa.alloc(u8, samples.len * size);
    for (samples, 0..) |sample, i| {
        if (size == 1) {
            data[i] = @intCast(sample);
        } else {
            std.mem.writeInt(u16, data[i * 2 ..][0..2], sample, .big);
        }
    }
    return data;
}

/// PackBits data of byte `samples`, channel after channel, behind a table
/// of row lengths: literal and repeated runs of random lengths that cross
/// rows, and now and then a no-op byte.
fn rleData(rng: std.Random, samples: []const u16, channels: u16, height: u32) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(gpa);
    for (0..@as(usize, height) * channels) |_| try put(&list, u16, rng.int(u16));
    const pixel_count = samples.len / @max(channels, 1);
    for (0..channels) |channel| {
        const values = samples[channel * pixel_count ..][0..pixel_count];
        var i: usize = 0;
        while (i < values.len) {
            if (rng.uintLessThan(u32, 16) == 0) try list.append(gpa, 128);
            var run: usize = 1;
            while (i + run < values.len and run < 128 and values[i + run] == values[i]) run += 1;
            if (run >= 2 and rng.uintLessThan(u32, 4) != 0) {
                const len = 2 + rng.uintLessThan(usize, run - 1);
                try list.append(gpa, @intCast(257 - len));
                try list.append(gpa, @intCast(values[i]));
                i += len;
            } else {
                const len = @min(1 + rng.uintLessThan(usize, 128), values.len - i);
                try list.append(gpa, @intCast(len - 1));
                for (values[i..][0..len]) |value| try list.append(gpa, @intCast(value));
                i += len;
            }
        }
    }
    return list.toOwnedSlice(gpa);
}

/// Byte samples with runs, so the PackBits data has repeats.
fn makeRunSamples(rng: std.Random, channels: u16, pixel_count: usize) ![]u16 {
    const samples = try makeSamples(rng, channels, pixel_count, 255);
    var i: usize = 0;
    while (i < pixel_count) {
        const len = @min(1 + rng.uintLessThan(usize, 200), pixel_count - i);
        if (rng.boolean()) {
            for (0..channels) |channel| {
                const values = samples[channel * pixel_count ..][i..][0..len];
                // The run's largest colour is above the matte of each pixel.
                var top: u16 = 0;
                for (values) |value| top = @max(top, value);
                if (channel == 3) top = values[0];
                @memset(values, top);
            }
        }
        i += len;
    }
    if (channels >= 4) {
        // A run of one alpha over colours made for others can fall below
        // the matte; raise every colour to its pixel's matte again.
        const alpha = samples[3 * pixel_count ..][0..pixel_count];
        for (0..3) |channel| {
            for (samples[channel * pixel_count ..][0..pixel_count], alpha) |*c, a| {
                if (a != 0) c.* = @max(c.*, 255 - a);
            }
        }
    }
    return samples;
}

fn makePsd(rng: std.Random, channels: u16, width: u32, height: u32, depth: u16, rle: bool) ![]u8 {
    const pixel_count = @as(usize, width) * height;
    // PackBits data is bytes at either depth.
    const samples = if (rle)
        try makeRunSamples(rng, channels, pixel_count)
    else
        try makeSamples(rng, channels, pixel_count, if (depth == 16) 65535 else 255);
    defer gpa.free(samples);
    const data = if (rle)
        try rleData(rng, samples, channels, height)
    else
        try rawData(samples, depth);
    defer gpa.free(data);
    return encodePsd(.{
        .channels = channels,
        .height = height,
        .width = width,
        .depth = depth,
        .compression = @intFromBool(rle),
        .data = data,
    });
}

test "channel counts 0 to 56 at both depths and compressions decode or fail as in the original" {
    var prng: std.Random.DefaultPrng = .init(0x95d0_0001);
    const rng = prng.random();
    for (0..57) |channels| {
        for ([_]u16{ 8, 16 }) |depth| {
            for ([_]bool{ false, true }) |rle| {
                for ([_][2]u32{ .{ 1, 1 }, .{ 7, 5 } }) |size| {
                    const count: u16 = @intCast(channels);
                    const bytes = try makePsd(rng, count, size[0], size[1], depth, rle);
                    defer gpa.free(bytes);
                    try oracle.expectAllSame(gpa, bytes, .{ .name = "channels" });
                }
            }
        }
    }
}

test "larger images with long runs decode as in the original" {
    var prng: std.Random.DefaultPrng = .init(0x95d0_0002);
    const rng = prng.random();
    for ([_]u16{ 3, 4, 5 }) |channels| {
        for ([_]u16{ 8, 16 }) |depth| {
            for ([_]bool{ false, true }) |rle| {
                const bytes = try makePsd(rng, channels, 61, 47, depth, rle);
                defer gpa.free(bytes);
                try oracle.expectAllSame(gpa, bytes, .{ .name = "larger" });
            }
        }
    }
}

test "PackBits runs of every length byte decode as in the original" {
    var prng: std.Random.DefaultPrng = .init(0x95d0_0003);
    const rng = prng.random();
    var channel: std.ArrayList(u8) = .empty;
    defer channel.deinit(gpa);
    var count: usize = 0;
    for (0..256) |header| {
        try channel.append(gpa, @intCast(header));
        if (header < 128) {
            for (0..header + 1) |_| try channel.append(gpa, rng.int(u8));
            count += header + 1;
        } else if (header > 128) {
            try channel.append(gpa, rng.int(u8));
            count += 257 - header;
        }
    }
    // 16,511 bytes a channel: an image of 11 by 1,501.
    try std.testing.expectEqual(11 * 1501, count);
    for ([_]u16{ 8, 16 }) |depth| {
        var data: std.ArrayList(u8) = .empty;
        defer data.deinit(gpa);
        for (0..1501 * 3) |_| try put(&data, u16, 0);
        for (0..3) |_| try data.appendSlice(gpa, channel.items);
        const bytes = try encodePsd(.{
            .channels = 3,
            .height = 1501,
            .width = 11,
            .depth = depth,
            .compression = 1,
            .data = data.items,
        });
        defer gpa.free(bytes);
        try oracle.expectAllSame(gpa, bytes, .{ .name = "every length byte" });
    }
}

test "PackBits runs past a channel's end fail as in the original" {
    var prng: std.Random.DefaultPrng = .init(0x95d0_0004);
    const rng = prng.random();
    // A 3 by 2 image: six bytes a channel.
    const streams = [_][]const u8{
        &.{ 6, 1, 2, 3, 4, 5, 6, 7 }, // a literal of 7
        &.{ 257 - 7, 9 }, // a repeat of 7
        &.{ 4, 1, 2, 3, 4, 5, 257 - 2, 9 }, // 5 then a repeat of 2
        &.{ 128, 128, 257 - 6, 3 }, // no-ops, then exactly six
        &.{ 0x81, 1 }, // a repeat of 128
        &.{}, // nothing: zeros past the end are literals of one
    };
    for (streams) |stream| {
        var data: std.ArrayList(u8) = .empty;
        defer data.deinit(gpa);
        for (0..2 * 3) |_| try put(&data, u16, rng.int(u16));
        for (0..3) |_| try data.appendSlice(gpa, stream);
        const bytes = try encodePsd(.{
            .channels = 3,
            .height = 2,
            .width = 3,
            .depth = 8,
            .compression = 1,
            .data = data.items,
        });
        defer gpa.free(bytes);
        try oracle.expectAllSame(gpa, bytes, .{ .name = "runs past the end" });
    }
}

test "versions, depths, modes, compressions and section lengths decode or fail as in the original" {
    var prng: std.Random.DefaultPrng = .init(0x95d0_0005);
    const rng = prng.random();
    const samples = try makeSamples(rng, 3, 6, 255);
    defer gpa.free(samples);
    const data = try rawData(samples, 8);
    defer gpa.free(data);
    const base: Psd = .{
        .channels = 3,
        .height = 2,
        .width = 3,
        .depth = 8,
        .compression = 0,
        .data = data,
    };
    var cases: std.ArrayList(Psd) = .empty;
    defer cases.deinit(gpa);
    for ([_]u16{ 0, 2, 3, 0xffff }) |version| {
        var p = base;
        p.version = version;
        try cases.append(gpa, p);
    }
    for ([_]u16{ 0, 1, 2, 4, 7, 15, 17, 32, 0xffff }) |depth| {
        var p = base;
        p.depth = depth;
        try cases.append(gpa, p);
    }
    for ([_]u16{ 0, 1, 2, 4, 7, 8, 9, 0xffff }) |mode| {
        var p = base;
        p.mode = mode;
        try cases.append(gpa, p);
    }
    for ([_]u16{ 2, 3, 0x8000, 0xffff }) |compression| {
        var p = base;
        p.compression = compression;
        try cases.append(gpa, p);
    }
    const lengths = [_]u32{ 1, 13, 64, 65, 1000, 0x7fffffff, 0x80000000, 0xffffffff };
    for (lengths) |len| {
        for (0..3) |section| {
            var p = base;
            p.sections[section] = len;
            try cases.append(gpa, p);
        }
    }
    for (cases.items) |p| {
        const bytes = try encodePsd(p);
        defer gpa.free(bytes);
        try oracle.expectAllSame(gpa, bytes, .{ .name = "header fields" });
    }
}

test "the largest sizes decode or fail as in the original" {
    const max: u32 = 1 << 24;
    const sizes = [_][2]u32{
        .{ max, 1 },
        .{ 1, max },
        .{ max + 1, 1 },
        .{ 1, max + 1 },
        .{ 0, 0 },
        .{ 0, 5 },
        .{ 0x80000000, 1 },
        .{ 1, 0x80000000 },
        .{ 0xffffffff, 0xffffffff },
        .{ 0x10000, 0x10000 },
    };
    for (sizes) |size| {
        for ([_]u16{ 0, 1 }) |compression| {
            const bytes = try encodePsd(.{
                .channels = 3,
                .width = size[0],
                .height = size[1],
                .depth = 8,
                .compression = compression,
                .data = &.{},
            });
            defer gpa.free(bytes);
            try oracle.expectAllSame(gpa, bytes, .{ .name = "largest" });
        }
    }
}

test "a 16-bit image too large for 8 bytes a pixel fails as out of memory, as in the original" {
    // 4 bytes a pixel fit in an int, 8 do not.
    const bytes = try encodePsd(.{
        .channels = 3,
        .width = 1 << 24,
        .height = 20,
        .depth = 16,
        .compression = 0,
        .data = &.{},
    });
    defer gpa.free(bytes);
    try oracle.expectLoadSame(gpa, bytes, .{ .bits = .u16 }, .{ .name = "8 bytes a pixel" }, .same);
    const result = stbi.loadFromMemory(u16, gpa, bytes, .{});
    try std.testing.expectError(error.OutOfMemory, result);
}

test "a 16-bit load of a raw 16-bit PSD gives the stored samples" {
    var prng: std.Random.DefaultPrng = .init(0x95d0_0006);
    const rng = prng.random();
    const samples = try makeSamples(rng, 3, 12, 65535);
    defer gpa.free(samples);
    const data = try rawData(samples, 16);
    defer gpa.free(data);
    const bytes = try encodePsd(.{
        .channels = 3,
        .height = 3,
        .width = 4,
        .depth = 16,
        .compression = 0,
        .data = data,
    });
    defer gpa.free(bytes);
    var wide = try stbi.loadFromMemory(u16, gpa, bytes, .{});
    defer wide.deinit(gpa);
    var narrow = try stbi.loadFromMemory(u8, gpa, bytes, .{});
    defer narrow.deinit(gpa);
    try std.testing.expectEqual(4, wide.channels);
    for (0..12) |i| {
        for (0..3) |channel| {
            const stored = samples[channel * 12 + i];
            try std.testing.expectEqual(stored, wide.pixels[i * 4 + channel]);
            try std.testing.expectEqual(stored >> 8, narrow.pixels[i * 4 + channel]);
        }
        try std.testing.expectEqual(65535, wide.pixels[i * 4 + 3]);
    }
    try oracle.expectAllSame(gpa, bytes, .{ .name = "16-bit request" });
}

test "the 16-bit query reads the depth where the original's GCC and Clang builds read it" {
    // The query takes the top half of the height as the depth.
    for ([_]u32{ 1, 0x000f_ffff, 0x0010_0000, 0x0010_ffff, 0x0011_0000 }) |height| {
        for ([_]u16{ 8, 16 }) |depth| {
            const bytes = try encodePsd(.{
                .channels = 3,
                .height = height,
                .width = 1,
                .depth = depth,
                .compression = 0,
                .data = &.{},
            });
            defer gpa.free(bytes);
            const top_half = height >> 16 == 16;
            try std.testing.expectEqual(top_half, stbi.is16BitFromMemory(bytes));
            for ([_]oracle.Via{ .memory, .callbacks, .file }) |via| {
                try oracle.expectQuerySame(bytes, .is_16_bit, via, .{ .name = "16-bit query" });
            }
        }
    }
}

test "a colour below its white matte is refused, where the original's conversion is undefined" {
    for ([_]u16{ 8, 16 }) |depth| {
        const max: u16 = if (depth == 16) 65535 else 255;
        // Half transparent black: the colour without the matte is -max.
        const samples = [_]u16{ 0, 0, 0, max / 2 + 1 };
        const data = try rawData(&samples, depth);
        defer gpa.free(data);
        const bytes = try encodePsd(.{
            .channels = 4,
            .height = 1,
            .width = 1,
            .depth = depth,
            .compression = 0,
            .data = data,
        });
        defer gpa.free(bytes);
        try oracle.expectAll(gpa, bytes, .{ .name = "below the matte" }, .port_refuses);
        const result = stbi.loadFromMemory(u8, gpa, bytes, .{});
        try std.testing.expectError(error.PsdMatteOutOfRange, result);
    }
}

test "a PSD cut short at every byte of its header decodes or fails as in the original" {
    var prng: std.Random.DefaultPrng = .init(0x95d0_0007);
    const rng = prng.random();
    for ([_]u16{ 8, 16 }) |depth| {
        for ([_]bool{ false, true }) |rle| {
            const whole = try makePsd(rng, 4, 3, 2, depth, rle);
            defer gpa.free(whole);
            for (0..whole.len + 1) |len| {
                try oracle.expectAllSame(gpa, whole[0..len], .{ .name = "cut short" });
            }
        }
    }
}

fn handMadeSeeds(list: *std.ArrayList([]const u8), rng: std.Random) !void {
    for ([_]u16{ 1, 3, 4, 5 }) |channels| {
        for ([_]u16{ 8, 16 }) |depth| {
            for ([_]bool{ false, true }) |rle| {
                try list.append(gpa, try makePsd(rng, channels, 9, 4, depth, rle));
            }
        }
    }
}

const fuzz_config: fuzz.Config = .{
    .name = "psd",
    .seed = 0x95d0_f000,
    .cases = 3000,
    .unsafe = &psd_unsafe,
};

test "fuzz: mutated PSDs decode or fail as in the original" {
    var prng: std.Random.DefaultPrng = .init(0x95d0_0008);
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
    // The small test files only: a mutated large file decodes slowly and
    // finds nothing the small ones miss.
    for (set.entries) |entry| {
        if (entry.bytes.len > 64 << 10 or isRefused(entry.name)) continue;
        try inputs.append(gpa, entry.bytes);
    }
    try inputs.appendSlice(gpa, hand_made.items);
    try fuzz.run(gpa, fuzz_config, inputs.items);
    try fuzz.expectUnsafeRefused(gpa, fuzz_config, inputs.items, &.{error.PsdMatteOutOfRange});
}

/// Fuzz cases with a colour below its white matte, on which the original's
/// conversion is undefined, found by running every case against it.
const psd_unsafe = fuzz.unsafeLoads(&.{
    66,   86,   153,  172,  207,  216,  322,  368,  391,  509,  567,  653,
    768,  978,  986,  1009, 1012, 1098, 1122, 1181, 1226, 1339, 1481, 1602,
    1619, 1743, 1899, 1921, 2027, 2052, 2097, 2238, 2257, 2328, 2379, 2390,
    2416, 2473, 2641, 2851, 2885, 2932, 2942, 2989, 2990,
});

fn decodeAll(allocator: std.mem.Allocator, bytes: []const u8) !void {
    for ([_]stbi.Components{ .file, .grey, .rgb }) |components| {
        var image = try stbi.loadFromMemory(u8, allocator, bytes, .{ .components = components });
        image.deinit(allocator);
        var wide = try stbi.loadFromMemory(u16, allocator, bytes, .{ .components = components });
        wide.deinit(allocator);
    }
}

test "a PSD decode frees everything when any allocation fails" {
    var prng: std.Random.DefaultPrng = .init(0x95d0_0009);
    const rng = prng.random();
    for ([_]u16{ 8, 16 }) |depth| {
        for ([_]bool{ false, true }) |rle| {
            const bytes = try makePsd(rng, 4, 3, 2, depth, rle);
            defer gpa.free(bytes);
            try std.testing.checkAllAllocationFailures(gpa, decodeAll, .{bytes});
        }
    }
}
