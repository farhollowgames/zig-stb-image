//! Softimage PIC files against the original. There is no public PIC
//! corpus, so an encoder here writes every packet type and channel layout,
//! and the fuzzing starts from its files.

const std = @import("std");
const stbi = @import("stb_image");
const oracle = @import("oracle.zig");
const fuzz = @import("fuzz.zig");

const gpa = std.testing.allocator;

const red = 0x80;
const green = 0x40;
const blue = 0x20;
const alpha = 0x10;

/// The failures of the packets and the scanlines. After them the original
/// converts its null image: safely only when 4 components come out.
fn isCoreFailure(err: anyerror) bool {
    return switch (err) {
        error.PicTooManyPackets,
        error.PicShortPackets,
        error.PicPacketNot8Bit,
        error.PicBadPacketType,
        error.PicShortValue,
        error.PicShortPureCount,
        error.PicShortMixedCount,
        error.PicScanlineOverrun,
        => true,
        else => false,
    };
}

/// Whether the packets or the scanlines of `bytes` fail, read from memory
/// or through a reader, which see the end of the input differently.
fn coreFails(bytes: []const u8) bool {
    if (stbi.loadFromMemory(u8, gpa, bytes, .{ .components = .rgba })) |image| {
        var copy = image;
        copy.deinit(gpa);
    } else |err| if (isCoreFailure(err)) return true;
    var reader: std.Io.Reader = .fixed(bytes);
    if (stbi.loadFromReader(u8, gpa, &reader, .{ .components = .rgba })) |image| {
        var copy = image;
        copy.deinit(gpa);
    } else |err| if (isCoreFailure(err)) return true;
    return false;
}

/// What the original gives on a load of `components` from `bytes`, whose
/// packets or scanlines fail, through `via`. It converts the null image it
/// is left with: 4 components fail, as nothing is converted. With no
/// pixels, 1 to 3 give an empty image, and so does the file's 3 when the
/// packets have set it; with nothing asked for before then it uses the
/// caller's `*comp`, which the port refuses. With pixels, every conversion
/// reads the null image, which the port refuses.
fn failedLoad(bytes: []const u8, components: stbi.Components, via: oracle.Via) oracle.Expect {
    if (components == .rgba) return .same;
    if (std.mem.readInt(u16, bytes[92..94], .big) != 0 and
        std.mem.readInt(u16, bytes[94..96], .big) != 0) return .port_refuses;
    if (components != .file) return .same;
    var reader: std.Io.Reader = .fixed(bytes);
    const rgba = if (via == .memory)
        stbi.loadFromMemory(u8, gpa, bytes, .{ .components = .rgba })
    else
        stbi.loadFromReader(u8, gpa, &reader, .{ .components = .rgba });
    if (rgba) |image| {
        var copy = image;
        copy.deinit(gpa);
        return .same;
    } else |err| return switch (err) {
        error.PicTooManyPackets, error.PicShortPackets, error.PicPacketNot8Bit => .port_refuses,
        else => .same,
    };
}

/// Every load and query of `bytes` against the original. Where the packets
/// or scanlines fail, the loads the original converts safely are compared,
/// and the port must refuse the others (see `failedLoad`).
fn expectPicSame(bytes: []const u8, label: oracle.Label) !void {
    if (!coreFails(bytes)) return oracle.expectAllSame(gpa, bytes, label);
    for ([_]oracle.Bits{ .u8, .u16, .f32 }) |bits| {
        for (std.enums.values(stbi.Components)) |components| {
            try oracle.expectLoadSame(
                gpa,
                bytes,
                .{ .bits = bits, .options = .{ .components = components } },
                label,
                failedLoad(bytes, components, .memory),
            );
        }
        for ([_]oracle.Via{ .callbacks, .file }) |via| {
            for ([_]stbi.Components{ .rgb, .rgba, .file }) |components| {
                try oracle.expectLoadSame(
                    gpa,
                    bytes,
                    .{ .bits = bits, .via = via, .options = .{ .components = components } },
                    label,
                    failedLoad(bytes, components, via),
                );
            }
        }
    }
    for ([_]oracle.Query{ .info, .is_16_bit, .is_hdr }) |query| {
        for ([_]oracle.Via{ .memory, .callbacks, .file }) |via| {
            try oracle.expectQuerySame(bytes, query, via, label);
        }
    }
}

const Packet = struct {
    type: u8,
    channel: u8,
    size: u8 = 8,
};

/// How the run-length packets are written.
const Style = struct {
    /// Pure runs: also write runs of 0 and runs longer than what is left.
    odd_counts: bool = false,
    /// Mixed runs: write long runs with the 16-bit count.
    long_runs: bool = true,
};

const Writer = struct {
    bytes: std.ArrayList(u8) = .empty,

    fn deinit(w: *Writer) void {
        w.bytes.deinit(gpa);
    }

    fn add(w: *Writer, data: []const u8) !void {
        try w.bytes.appendSlice(gpa, data);
    }

    fn header(w: *Writer, width: u16, height: u16) !void {
        try w.add("\x53\x80\xF6\x34");
        try w.add("\x40\x43\x33\x33"); // the version, a float
        var comment: [80]u8 = @splat(0);
        @memcpy(comment[0..13], "made by tests");
        try w.add(&comment);
        try w.add("PICT");
        try w.add(
            &.{ @intCast(width >> 8), @truncate(width), @intCast(height >> 8), @truncate(height) },
        );
        try w.add("\x3f\x80\x00\x00\x00\x03\x00\x00"); // ratio 1.0, both fields, pad
    }

    fn packets(w: *Writer, list: []const Packet) !void {
        for (list, 0..) |packet, i| {
            try w.add(
                &.{ @intFromBool(i + 1 < list.len), packet.size, packet.type, packet.channel },
            );
        }
    }

    /// The bytes of the channels `channel` names, of one pixel.
    fn value(w: *Writer, channel: u8, pixel: [4]u8) !void {
        var mask: u8 = 0x80;
        for (pixel) |byte| {
            if (channel & mask != 0) try w.bytes.append(gpa, byte);
            mask >>= 1;
        }
    }

    fn scanlines(
        w: *Writer,
        image: []const [4]u8,
        width: usize,
        list: []const Packet,
        style: Style,
    ) !void {
        if (width == 0) return;
        const height = image.len / width;
        for (0..height) |y| {
            const row = image[y * width ..][0..width];
            for (list) |packet| try w.packetRow(row, packet, style);
        }
    }

    fn same(channel: u8, a: [4]u8, b: [4]u8) bool {
        var mask: u8 = 0x80;
        for (a, b) |x, y| {
            if (channel & mask != 0 and x != y) return false;
            mask >>= 1;
        }
        return true;
    }

    fn runLength(row: []const [4]u8, at: usize, channel: u8, max: usize) usize {
        var run: usize = 1;
        while (at + run < row.len and run < max and same(channel, row[at], row[at + run])) run += 1;
        return run;
    }

    fn packetRow(w: *Writer, row: []const [4]u8, packet: Packet, style: Style) !void {
        switch (packet.type) {
            0 => for (row) |pixel| try w.value(packet.channel, pixel),
            1 => {
                var x: usize = 0;
                var n: usize = 0;
                while (x < row.len) : (n += 1) {
                    if (style.odd_counts and n % 5 == 1) {
                        // A run of 0 writes nothing.
                        try w.bytes.append(gpa, 0);
                        try w.value(packet.channel, row[x]);
                        continue;
                    }
                    const run = runLength(row, x, packet.channel, 255);
                    const count = if (style.odd_counts and x + run == row.len) 255 else run;
                    try w.bytes.append(gpa, @intCast(count));
                    try w.value(packet.channel, row[x]);
                    x += run;
                }
            },
            2 => {
                var x: usize = 0;
                while (x < row.len) {
                    const max: usize = if (style.long_runs) 65535 else 128;
                    const run = runLength(row, x, packet.channel, max);
                    if (run >= 2) {
                        if (run > 128) {
                            try w.add(&.{ 128, @intCast(run >> 8), @truncate(run) });
                        } else {
                            try w.bytes.append(gpa, @intCast(run + 127));
                        }
                        try w.value(packet.channel, row[x]);
                        x += run;
                        continue;
                    }
                    var count: usize = 1;
                    while (x + count < row.len and count < 128 and
                        runLength(row, x + count, packet.channel, 2) < 2) count += 1;
                    try w.bytes.append(gpa, @intCast(count - 1));
                    for (row[x..][0..count]) |pixel| try w.value(packet.channel, pixel);
                    x += count;
                }
            },
            else => {},
        }
    }
};

/// RGBA pixels with runs, gradients and noise.
fn pattern(pixels: [][4]u8, width: usize, seed: u64) void {
    var prng: std.Random.DefaultPrng = .init(seed);
    const rng = prng.random();
    for (pixels, 0..) |*p, i| {
        const x = if (width == 0) 0 else i % width;
        p.* = if (x % 11 < 6)
            .{ 10, 200, 30, 255 }
        else if (x % 11 < 8)
            .{ @truncate(i), @truncate(i * 3), @truncate(x), @truncate(i / 3) }
        else
            .{ rng.int(u8), rng.int(u8), rng.int(u8), rng.int(u8) };
    }
}

fn makePic(width: u16, height: u16, list: []const Packet, style: Style, seed: u64) ![]u8 {
    var w: Writer = .{};
    errdefer w.deinit();
    try w.header(width, height);
    try w.packets(list);
    const image = try gpa.alloc([4]u8, @as(usize, width) * height);
    defer gpa.free(image);
    pattern(image, width, seed);
    try w.scanlines(image, width, list, style);
    return w.bytes.toOwnedSlice(gpa);
}

const layouts = [_][]const Packet{
    &.{.{ .type = 0, .channel = red | green | blue }},
    &.{.{ .type = 0, .channel = red | green | blue | alpha }},
    &.{.{ .type = 1, .channel = red | green | blue }},
    &.{.{ .type = 2, .channel = red | green | blue }},
    &.{.{ .type = 1, .channel = red | green | blue | alpha }},
    &.{.{ .type = 2, .channel = red | green | blue | alpha }},
    &.{ .{ .type = 2, .channel = red | green | blue }, .{ .type = 2, .channel = alpha } },
    &.{ .{ .type = 0, .channel = red | green | blue }, .{ .type = 1, .channel = alpha } },
    &.{
        .{ .type = 0, .channel = red },
        .{ .type = 1, .channel = green },
        .{ .type = 2, .channel = blue },
        .{ .type = 0, .channel = alpha },
    },
    // The same channel in two packets: the later one wins.
    &.{ .{ .type = 2, .channel = red | green | blue | alpha }, .{ .type = 0, .channel = green } },
    // Channels missing: they stay 255.
    &.{.{ .type = 2, .channel = red | blue }},
    &.{.{ .type = 0, .channel = 0 }},
    &.{.{ .type = 1, .channel = 0 }},
    // Low bits name no channel.
    &.{.{ .type = 2, .channel = red | green | blue | 0x0f }},
    &.{
        .{ .type = 0, .channel = red },
        .{ .type = 0, .channel = green },
        .{ .type = 0, .channel = blue },
        .{ .type = 0, .channel = alpha },
        .{ .type = 1, .channel = red },
        .{ .type = 1, .channel = green },
        .{ .type = 1, .channel = blue },
        .{ .type = 2, .channel = alpha },
        .{ .type = 2, .channel = red },
        .{ .type = 2, .channel = green },
    },
};

test "PIC files of every packet type and channel layout decode as in the original" {
    const sizes = [_][2]u16{ .{ 1, 1 }, .{ 5, 3 }, .{ 37, 4 }, .{ 300, 2 } };
    for (layouts) |layout| {
        for (sizes) |size| {
            for ([_]Style{ .{}, .{ .odd_counts = true, .long_runs = false } }) |style| {
                const bytes = try makePic(size[0], size[1], layout, style, size[0]);
                defer gpa.free(bytes);
                try expectPicSame(bytes, .{ .name = "layout" });
            }
        }
    }
}

test "PIC files of no width or height decode as in the original" {
    // Those that end after the packets fail there, before the channels are
    // set; those with bad packet types and more bytes fail in the
    // scanlines, after, when there are scanlines to read.
    const bad_types = [_][]const Packet{
        &.{.{ .type = 3, .channel = red | green | blue }},
        &.{.{ .type = 3, .channel = red | green | blue | alpha }},
    };
    for ([_][2]u16{ .{ 0, 3 }, .{ 3, 0 }, .{ 0, 0 } }) |size| {
        for (layouts[0..4] ++ bad_types) |layout| {
            for ([_][]const u8{ "", "\x00\x01\x02\x03" }) |after| {
                const image = try makePic(size[0], size[1], layout, .{}, 1);
                defer gpa.free(image);
                const bytes = try std.mem.concat(gpa, u8, &.{ image, after });
                defer gpa.free(bytes);
                try expectPicSame(bytes, .{ .name = "empty" });
            }
        }
    }
}

const eleven_packets: [11]Packet = @splat(.{ .type = 0, .channel = green });

test "PIC packet lists fail as in the original" {
    const lists = [_][]const Packet{
        &eleven_packets,
        &.{.{ .type = 0, .channel = red | green | blue, .size = 7 }},
        &.{.{ .type = 0, .channel = red | green | blue, .size = 16 }},
        &.{.{ .type = 3, .channel = red | green | blue }},
        &.{ .{ .type = 0, .channel = red | green }, .{ .type = 255, .channel = blue } },
    };
    for (lists) |list| {
        const bytes = try makePic(4, 2, list, .{}, 3);
        defer gpa.free(bytes);
        try expectPicSame(bytes, .{ .name = "packets" });
    }
}

test "PIC scanlines that overrun or end early fail as in the original" {
    var w: Writer = .{};
    defer w.deinit();
    try w.header(4, 1);
    const prefix_len = w.bytes.items.len;
    const rows = [_]struct { packet: Packet, data: []const u8 }{
        .{
            .packet = .{ .type = 2, .channel = red },
            .data = &.{ 130, 9, 3, 1, 2, 3, 4 },
        }, // a run of 3, literals of 4
        .{
            .packet = .{ .type = 2, .channel = red },
            .data = &.{ 4, 1, 2, 3, 4, 5 },
        }, // literals of 5
        .{
            .packet = .{ .type = 2, .channel = red },
            .data = &.{ 128, 0, 5, 7 },
        }, // a long run of 5
        .{
            .packet = .{ .type = 2, .channel = red },
            .data = &.{ 128, 0, 0, 7, 128, 0, 4, 8 },
        }, // a long run of 0
        .{
            .packet = .{ .type = 1, .channel = red },
            .data = &.{ 9, 3 },
        }, // a pure run past the end
        .{ .packet = .{ .type = 1, .channel = red }, .data = &.{ 0, 3, 0, 4, 4, 5 } },
        .{ .packet = .{ .type = 1, .channel = red }, .data = &.{2} },
        .{ .packet = .{ .type = 2, .channel = red }, .data = &.{ 1, 5 } },
        .{ .packet = .{ .type = 0, .channel = red | alpha }, .data = &.{ 1, 2, 3 } },
    };
    for (rows) |row| {
        w.bytes.shrinkRetainingCapacity(prefix_len);
        try w.packets(&.{row.packet});
        try w.add(row.data);
        try expectPicSame(w.bytes.items, .{ .name = "scanline" });
    }
}

test "a PIC file truncated at every byte fails or decodes as in the original" {
    const files = [_][]u8{
        try makePic(5, 2, layouts[6], .{}, 4),
        try makePic(3, 2, layouts[8], .{ .odd_counts = true }, 5),
    };
    defer for (files) |file| gpa.free(file);
    for (files) |file| {
        for (0..file.len) |len| try expectPicSame(file[0..len], .{ .name = "truncated" });
    }
}

test "PIC headers and info are read as in the original" {
    const base = try makePic(6, 4, layouts[3], .{}, 6);
    defer gpa.free(base);
    // Edits at the header's fields.
    const edits = [_]struct { at: usize, bytes: []const u8 }{
        .{ .at = 0, .bytes = "\x54" }, // the magic number
        .{ .at = 88, .bytes = "PICS" },
        .{ .at = 92, .bytes = "\x7f\xff\x7f\xff" }, // too large to decode
        .{ .at = 92, .bytes = "\x40\x00\x40\x01" }, // over the info's 2^28 pixels
        .{ .at = 92, .bytes = "\x00\x00\xff\xff" },
        .{ .at = 92, .bytes = "\xff\xff\x00\x00" },
        .{
            .at = 104,
            .bytes = "\x01\x08\x02\xe0" ++ "\x01\x08\x02\x10" ++ "\x00\x08\x00\x10",
        }, // chained packets
    };
    for (edits) |edit| {
        const bytes = try gpa.dupe(u8, base);
        defer gpa.free(bytes);
        @memcpy(bytes[edit.at..][0..edit.bytes.len], edit.bytes);
        try expectPicSame(bytes, .{ .name = "header" });
    }
}

test "PIC info after ten chained packets fails as the original's" {
    // The original fails there without rewinding; the PNM info after it
    // rewinds first, so nothing reads on from the packets.
    var w: Writer = .{};
    defer w.deinit();
    try w.header(2, 2);
    for (0..10) |_| try w.add(&.{ 1, 8, 0, red });
    try w.add("P6\n2 2\n255\n");
    try w.add(&@as([12]u8, @splat(0x55)));
    try expectPicSame(w.bytes.items, .{ .name = "info, ten packets" });
    try std.testing.expectError(error.UnknownImageType, stbi.infoFromMemory(w.bytes.items));
}

test "PIC loads refuse a scanline failure the original converts from a null image" {
    const bytes = try makePic(5, 2, layouts[3], .{}, 4);
    defer gpa.free(bytes);
    const cut = bytes[0 .. bytes.len - 3];
    for ([_]stbi.Components{ .file, .grey, .grey_alpha, .rgb }) |components| {
        try std.testing.expectError(
            error.PicShortMixedCount,
            stbi.loadFromMemory(u8, gpa, cut, .{ .components = components }),
        );
    }
    // With 4 components the original fails with the same reason.
    try oracle.expectLoadSame(
        gpa,
        cut,
        .{ .options = .{ .components = .rgba } },
        .{ .name = "cut" },
        .same,
    );
}

test "the PIC size limits refuse as the original's do" {
    const bytes = try makePic(6, 4, layouts[3], .{}, 6);
    defer gpa.free(bytes);
    try std.testing.expectError(error.DimensionTooLarge, stbi.loadFromMemory(u8, gpa, bytes, .{
        .limits = .{ .dimension_max = 5 },
    }));
    try std.testing.expectError(error.TooLargePic, stbi.loadFromMemory(u8, gpa, bytes, .{
        .limits = .{ .bytes_max = 6 * 4 * 4 - 1 },
    }));
}

fn loadForAllocationFailures(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    components: stbi.Components,
) !void {
    var image = stbi.loadFromMemory(
        f32,
        allocator,
        bytes,
        .{ .components = components },
    ) catch |err| {
        if (err == error.OutOfMemory) return err;
        return error.TestUnexpectedResult;
    };
    image.deinit(allocator);
}

test "a PIC load that runs out of memory at any allocation leaks nothing" {
    const bytes = try makePic(7, 3, layouts[6], .{}, 6);
    defer gpa.free(bytes);
    for ([_]stbi.Components{ .file, .rgba, .grey }) |components| {
        try std.testing.checkAllAllocationFailures(
            gpa,
            loadForAllocationFailures,
            .{ bytes, components },
        );
    }
}

/// The fuzz test's seeds: hand-made files of every layout, in `arena`.
pub fn fuzzInputs(arena: std.mem.Allocator) ![]const []const u8 {
    var inputs: std.ArrayList([]const u8) = .empty;
    for (layouts, 0..) |layout, i| {
        const style: Style = if (i % 2 == 0) .{} else .{ .odd_counts = true, .long_runs = false };
        const bytes = try makePic(@intCast(3 + i % 7), @intCast(1 + i % 3), layout, style, i);
        defer gpa.free(bytes);
        try inputs.append(arena, try arena.dupe(u8, bytes));
    }
    return inputs.items;
}

/// Whether a fuzz case's load is one the original is unsafe on: a failure
/// of the packets or scanlines, converted from a null image of some pixels
/// or with the caller's `*comp` (see `failedLoad`).
pub fn unsafeCall(bytes: []const u8, request: oracle.Request) ?fuzz.Call {
    if (!coreFails(bytes)) return null;
    const expect = failedLoad(bytes, request.options.components, request.via);
    return if (expect == .port_refuses) .load else null;
}

test "fuzz: mutated PIC files decode as in the original" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    try fuzz.run(gpa, pic_fuzz, try fuzzInputs(arena.allocator()));
}

pub const pic_fuzz: fuzz.Config = .{
    .name = "pic",
    .seed = 0x91c0_0001,
    .cases = 3000,
    .unsafe = @import("pic_unsafe.zig").unsafe,
};
