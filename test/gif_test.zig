//! GIF files against the original: the corpus, hand-made files of every
//! disposal method, palette, interlace and LZW code size, truncations, and
//! fuzzing, each as an image and as an animation.

const std = @import("std");
const stbi = @import("stb_image");
const oracle = @import("oracle.zig");
const fuzz_options = @import("fuzz_options");
const corpus = @import("corpus.zig");
const fuzz = @import("fuzz.zig");

const gpa = std.testing.allocator;

/// Why the port refuses an animation the original is unsafe on, if it
/// does: the errors stand for exactly those inputs.
fn refusedAnimation(bytes: []const u8) ?anyerror {
    var animation = stbi.loadGifFromMemory(gpa, bytes, .{}) catch |err| switch (err) {
        error.GifDisposeToPrevious, error.GifZeroAreaFrames => return err,
        else => return null,
    };
    animation.deinit(gpa);
    return null;
}

/// The animation options every hand-made file is loaded with.
const animation_options = [_]stbi.Options{
    .{},
    .{ .components = .grey },
    .{ .components = .grey_alpha },
    .{ .components = .rgb },
    .{ .components = .rgba },
    .{ .flip_vertically = true },
    .{ .flip_vertically = true, .components = .rgba },
    .{ .flip_vertically = true, .components = .rgb },
};

/// Every image load and query of `bytes`, and its animation under every
/// option, against the original; where the original's animation is
/// unsafe, the port refusing it.
fn expectGifAllSame(bytes: []const u8, label: oracle.Label) !void {
    try oracle.expectAllSame(gpa, bytes, label);
    if (refusedAnimation(bytes)) |_| {
        for (animation_options) |options| {
            if (stbi.loadGifFromMemory(gpa, bytes, options)) |animation| {
                var copy = animation;
                copy.deinit(gpa);
                label.print(
                    .{ .options = options },
                    "the port decoded an animation the original is unsafe on",
                    .{},
                );
                return error.TestUnexpectedResult;
            } else |_| {}
        }
        return;
    }
    for (animation_options) |options| try oracle.expectGifSame(gpa, bytes, options, label);
}

/// Encodes palette indices with LZW as a GIF raster expects: codes of
/// growing width, packed from the low bit, in sub-blocks of up to 255
/// bytes. It follows the original decoder's state to know each code's
/// width.
const LzwOptions = struct {
    /// Start with a clear code, as the original requires.
    clear_first: bool = true,
    /// End with the end code; otherwise an empty sub-block ends the data.
    end_code: bool = true,
    /// Clear the table when it is full; otherwise keep emitting codes of
    /// the widest size, as encoders with a deferred clear do.
    clear_when_full: bool = true,
    /// Emit every index as its own code, building no strings.
    literal_only: bool = false,
    /// Emit a clear code after this many codes, again and again.
    clear_every: ?u32 = null,
    /// The largest sub-block.
    block_size: u8 = 255,
};

const LzwWriter = struct {
    out: *std.ArrayList(u8),
    block: std.ArrayList(u8) = .empty,
    bits: u64 = 0,
    nbits: u6 = 0,
    block_size: u8,
    // The decoder's state: the next code it defines and its code width.
    min_size: u5,
    avail: u32 = 0,
    codesize: u5 = 0,
    after_clear: bool = true,

    fn emit(w: *LzwWriter, code: u32) !void {
        w.bits |= @as(u64, code) << w.nbits;
        w.nbits += w.codesize;
        while (w.nbits >= 8) {
            try w.byte(@truncate(w.bits));
            w.bits >>= 8;
            w.nbits -= 8;
        }
        const clear = @as(u32, 1) << w.min_size;
        if (code == clear) {
            w.codesize = w.min_size + 1;
            w.avail = clear + 2;
            w.after_clear = true;
            return;
        }
        if (!w.after_clear) w.avail += 1;
        w.after_clear = false;
        const mask = (@as(u32, 1) << w.codesize) - 1;
        if (w.avail & mask == 0 and w.avail <= 0x0fff) w.codesize += 1;
    }

    fn byte(w: *LzwWriter, b: u8) !void {
        try w.block.append(gpa, b);
        if (w.block.items.len == w.block_size) try w.flushBlock();
    }

    fn flushBlock(w: *LzwWriter) !void {
        if (w.block.items.len == 0) return;
        try w.out.append(gpa, @intCast(w.block.items.len));
        try w.out.appendSlice(gpa, w.block.items);
        w.block.clearRetainingCapacity();
    }

    fn finish(w: *LzwWriter) !void {
        if (w.nbits > 0) try w.byte(@truncate(w.bits));
        try w.flushBlock();
        try w.out.append(gpa, 0);
        w.block.deinit(gpa);
    }
};

fn lzwEncode(
    out: *std.ArrayList(u8),
    min_size: u5,
    indices: []const u8,
    options: LzwOptions,
) !void {
    try out.append(gpa, min_size);
    const clear = @as(u32, 1) << min_size;
    var w: LzwWriter = .{
        .out = out,
        .block_size = options.block_size,
        .min_size = min_size,
        .codesize = min_size + 1,
        .avail = clear + 2,
    };
    const max_code: u32 = if (min_size == 12) code_limit - 1 else 4095;
    var table: std.AutoHashMap(u64, u32) = .init(gpa);
    defer table.deinit();
    var next = clear + 2;
    if (options.clear_first) try w.emit(clear);
    var codes: u32 = 0;
    if (indices.len > 0) {
        var prefix: u32 = indices[0];
        for (indices[1..]) |index| {
            const key = (@as(u64, prefix) << 8) | index;
            if (!options.literal_only) {
                if (table.get(key)) |code| {
                    prefix = code;
                    continue;
                }
            }
            try w.emit(prefix);
            codes += 1;
            if (options.clear_every) |every| {
                if (codes % every == 0) {
                    try w.emit(clear);
                    table.clearRetainingCapacity();
                    next = clear + 2;
                    prefix = index;
                    continue;
                }
            }
            if (next <= max_code) {
                try table.put(key, next);
                next += 1;
            } else if (options.clear_when_full) {
                try w.emit(clear);
                table.clearRetainingCapacity();
                next = clear + 2;
            }
            prefix = index;
        }
        try w.emit(prefix);
    }
    if (options.end_code) try w.emit(clear + 1);
    try w.finish();
}

const code_limit = 8192;

const Frame = struct {
    x: u16 = 0,
    y: u16 = 0,
    w: u16,
    h: u16,
    /// Palette indices, top row first, in display order.
    indices: []const u8,
    local_table: ?[]const [3]u8 = null,
    interlace: bool = false,
    min_size: u5 = 8,
    lzw: LzwOptions = .{},
    /// A graphic control extension before the frame.
    control: ?Control = null,
};

const Control = struct {
    dispose: u3 = 0,
    transparent: ?u8 = null,
    delay: u16 = 0,
};

/// Writes GIF files block by block.
const Writer = struct {
    bytes: std.ArrayList(u8) = .empty,

    fn deinit(w: *Writer) void {
        w.bytes.deinit(gpa);
    }

    fn add(w: *Writer, data: []const u8) !void {
        try w.bytes.appendSlice(gpa, data);
    }

    fn u16le(w: *Writer, v: u16) !void {
        try w.add(&.{ @truncate(v), @truncate(v >> 8) });
    }

    fn header(w: *Writer, width: u16, height: u16, global: ?[]const [3]u8, background: u8) !void {
        try w.add("GIF89a");
        try w.u16le(width);
        try w.u16le(height);
        try w.add(&.{ if (global) |table| 0x80 | tableBits(table.len) else 0, background, 0 });
        if (global) |table| try w.colorTable(table);
    }

    fn colorTable(w: *Writer, table: []const [3]u8) !void {
        for (table) |rgb| try w.add(&rgb);
    }

    fn control(w: *Writer, c: Control) !void {
        const flags: u8 = (@as(u8, c.dispose) << 2) | @intFromBool(c.transparent != null);
        try w.add(&.{ 0x21, 0xf9, 4, flags });
        try w.u16le(c.delay);
        try w.add(&.{ c.transparent orelse 0, 0 });
    }

    fn frame(w: *Writer, f: Frame) !void {
        if (f.control) |c| try w.control(c);
        try w.add(&.{0x2c});
        try w.u16le(f.x);
        try w.u16le(f.y);
        try w.u16le(f.w);
        try w.u16le(f.h);
        var flags: u8 = if (f.interlace) 0x40 else 0;
        if (f.local_table) |table| flags |= 0x80 | tableBits(table.len);
        try w.add(&.{flags});
        if (f.local_table) |table| try w.colorTable(table);
        const ordered = try gpa.alloc(u8, f.indices.len);
        defer gpa.free(ordered);
        if (f.interlace) interlaceRows(
            f.indices,
            ordered,
            f.w,
            f.h,
        ) else @memcpy(ordered, f.indices);
        try lzwEncode(&w.bytes, f.min_size, ordered, f.lzw);
    }

    fn trailer(w: *Writer) !void {
        try w.add(&.{0x3b});
    }
};

/// The size field of a colour table of `len` entries, a power of two.
fn tableBits(len: usize) u8 {
    return @intCast(std.math.log2_int(usize, len) - 1);
}

/// The rows of an interlaced frame in the order they are stored: every
/// eighth from 0, every eighth from 4, every fourth from 2, every second
/// from 1.
fn interlaceRows(indices: []const u8, out: []u8, w: u16, h: u16) void {
    var at: usize = 0;
    const passes = [_][2]usize{ .{ 0, 8 }, .{ 4, 8 }, .{ 2, 4 }, .{ 1, 2 } };
    for (passes) |pass| {
        var row = pass[0];
        while (row < h) : (row += pass[1]) {
            @memcpy(out[at..][0..w], indices[row * w ..][0..w]);
            at += w;
        }
    }
}

/// A palette of `len` colours, no two alike.
fn palette(len: usize, seed: u8) [256][3]u8 {
    var table: [256][3]u8 = undefined;
    for (&table, 0..) |*rgb, i| {
        const v: u8 = @truncate(i);
        rgb.* = .{ v *% 3 +% seed, v *% 7 +% 1, 255 - v };
    }
    _ = len;
    return table;
}

/// Indices below `colours` in a pattern of runs and repeats, so LZW builds
/// strings.
fn pattern(out: []u8, colours: u32, seed: u64) void {
    var prng: std.Random.DefaultPrng = .init(seed);
    const rng = prng.random();
    for (out, 0..) |*index, i| {
        index.* = @intCast(if (i % 5 < 2) (i / 7) % colours else rng.uintLessThan(u32, colours));
    }
}

fn indicesFor(w: u16, h: u16, colours: u32, seed: u64) ![]u8 {
    const out = try gpa.alloc(u8, @as(usize, w) * h);
    pattern(out, colours, seed);
    return out;
}

/// A single-frame GIF.
fn makeSimple(w: u16, h: u16, frame: Frame, global_len: ?usize, background: u8) ![]u8 {
    var writer: Writer = .{};
    errdefer writer.deinit();
    const table = palette(256, 0);
    try writer.header(w, h, if (global_len) |len| table[0..len] else null, background);
    try writer.frame(frame);
    try writer.trailer();
    return writer.bytes.toOwnedSlice(gpa);
}

test "the GIF corpus decodes as in the original" {
    var count: usize = 0;
    for ([_][]const u8{ "tests/images/gif", "tests/regression/gif" }) |dir| {
        var set = try corpus.load(gpa, std.testing.io, .image_rs, dir, &.{".gif"});
        defer set.deinit(gpa);
        for (set.entries) |entry| try expectGifAllSame(entry.bytes, .{ .name = entry.name });
        count += set.entries.len;
    }
    try std.testing.expect(count >= 13);
}

test "a 1x1 GIF and GIFs of every LZW code size decode as in the original" {
    for (0..13) |size| {
        const min_size: u5 = @intCast(size);
        const colours: u32 = @min(256, @as(u32, 1) << min_size);
        for ([_][2]u16{ .{ 1, 1 }, .{ 5, 3 }, .{ 33, 17 } }) |dims| {
            const indices = try indicesFor(dims[0], dims[1], colours, size);
            defer gpa.free(indices);
            const global_len = @max(2, std.math.ceilPowerOfTwoAssert(u32, colours));
            const bytes = try makeSimple(dims[0], dims[1], .{
                .w = dims[0],
                .h = dims[1],
                .indices = indices,
                .min_size = min_size,
            }, global_len, 0);
            defer gpa.free(bytes);
            try expectGifAllSame(bytes, .{ .name = "code size" });
        }
    }
}

test "GIF LZW streams of every shape decode or fail as in the original" {
    const w = 64;
    const h = 40;
    const indices = try indicesFor(w, h, 16, 3);
    defer gpa.free(indices);
    const shapes = [_]LzwOptions{
        .{ .clear_first = false },
        .{ .end_code = false },
        .{ .literal_only = true },
        .{ .clear_every = 1 },
        .{ .clear_every = 7 },
        .{ .block_size = 1 },
        .{ .block_size = 3, .end_code = false },
    };
    for (shapes) |shape| {
        for ([_]u5{ 2, 4, 8 }) |min_size| {
            const bytes = try makeSimple(
                w,
                h,
                .{ .w = w, .h = h, .indices = indices, .min_size = min_size, .lzw = shape },
                16,
                0,
            );
            defer gpa.free(bytes);
            try expectGifAllSame(bytes, .{ .name = "lzw shape" });
        }
    }
}

test "GIF code tables that fill up decode or fail as in the original" {
    // Noise in 256 colours fills the 4096 codes, then the table is cleared,
    // or with a deferred clear runs past the original's 8192 codes.
    const w = 300;
    const h = 200;
    var noise: [w * h]u8 = undefined;
    var prng: std.Random.DefaultPrng = .init(11);
    prng.random().bytes(&noise);
    for ([_]bool{ true, false }) |clear_when_full| {
        for ([_]u5{ 8, 12 }) |min_size| {
            const bytes = try makeSimple(w, h, .{
                .w = w,
                .h = h,
                .indices = &noise,
                .min_size = min_size,
                .lzw = .{ .clear_when_full = clear_when_full, .literal_only = !clear_when_full },
            }, 256, 0);
            defer gpa.free(bytes);
            try expectGifAllSame(bytes, .{ .name = "full table" });
        }
    }
}

test "corrupt GIF rasters fail as in the original" {
    const prefix = "GIF89a\x04\x00\x02\x00\x80\x00\x00\x00\x00\x00\xff\xff\xff" ++
        "\x2c\x00\x00\x00\x00\x04\x00\x02\x00\x00";
    const rasters = [_][]const u8{
        "\x0d\x02\x00\x00", // code size 13
        "\x0c\x02\x00\x10\x00\x3b", // code size 12, a clear code
        "\x02\x01\x01\x00\x3b", // no clear code first: a literal
        "\x02\x01\x0c\x00\x3b", // a clear code, then code 1 of 3 bits: fine
        "\x02\x02\x3c\x07\x00\x3b", // a clear code, then a code past the table
        "\x02\x02\x34\x00\x00\x3b", // a clear code, then the next code to define
        "\x02\x00\x3b", // an empty raster
        "\x00\x02\x02\x00\x00\x3b", // code size 0
        "\x01\x02\x05\x00\x00\x3b", // code size 1
        "\x02\x01\x05\x00\x3b", // the end code at once
        "\x02\x03\x44\x01\x05\x00\x3b", // end code with data left in the block
        "\x02\x02\x44\x01\x02\x05\x05\x00\x3b", // end code, then more sub-blocks
    };
    for (rasters) |raster| {
        const bytes = try std.mem.concat(gpa, u8, &.{ prefix, raster });
        defer gpa.free(bytes);
        try expectGifAllSame(bytes, .{ .name = "raster" });
    }
}

test "interlaced GIF frames of every height decode as in the original" {
    for (1..18) |height| {
        const h: u16 = @intCast(height);
        const indices = try indicesFor(7, h, 8, height);
        defer gpa.free(indices);
        const bytes = try makeSimple(
            9,
            h + 2,
            .{ .x = 1, .y = 1, .w = 7, .h = h, .indices = indices, .interlace = true },
            8,
            0,
        );
        defer gpa.free(bytes);
        try expectGifAllSame(bytes, .{ .name = "interlaced" });
    }
}

test "GIF palettes, transparency and the background decode as in the original" {
    const indices = try indicesFor(6, 4, 4, 1);
    defer gpa.free(indices);
    const local = palette(256, 77);
    const cases = [_]struct { frame: Frame, global: ?usize, background: u8 }{
        .{ .frame = .{ .w = 6, .h = 4, .indices = indices }, .global = 4, .background = 0 },
        .{
            .frame = .{ .w = 6, .h = 4, .indices = indices, .local_table = local[0..4] },
            .global = null,
            .background = 0,
        },
        .{
            .frame = .{ .w = 6, .h = 4, .indices = indices, .local_table = local[0..8] },
            .global = 2,
            .background = 1,
        },
        .{
            .frame = .{ .w = 6, .h = 4, .indices = indices },
            .global = null,
            .background = 0,
        }, // no table
        .{
            .frame = .{ .w = 6, .h = 4, .indices = indices, .control = .{ .transparent = 2 } },
            .global = 4,
            .background = 0,
        },
        .{
            .frame = .{
                .w = 6,
                .h = 4,
                .indices = indices,
                .control = .{ .transparent = 2 },
                .local_table = local[0..4],
            },
            .global = 4,
            .background = 0,
        },
        .{
            .frame = .{ .x = 1, .y = 1, .w = 3, .h = 2, .indices = indices[0..6] },
            .global = 4,
            .background = 3,
        },
        .{
            .frame = .{
                .x = 1,
                .y = 1,
                .w = 3,
                .h = 2,
                .indices = indices[0..6],
                .control = .{ .transparent = 3 },
            },
            .global = 4,
            .background = 3,
        },
        .{
            .frame = .{ .x = 1, .y = 1, .w = 3, .h = 2, .indices = indices[0..6] },
            .global = 4,
            .background = 200,
        },
        .{
            .frame = .{ .w = 6, .h = 4, .indices = indices, .control = .{ .transparent = 0 } },
            .global = 4,
            .background = 0,
        },
    };
    for (cases) |case| {
        const bytes = try makeSimple(8, 6, case.frame, case.global, case.background);
        defer gpa.free(bytes);
        try expectGifAllSame(bytes, .{ .name = "palette" });
    }
}

test "GIF frames of no size and off the canvas decode or fail as in the original" {
    const indices = try indicesFor(4, 4, 4, 2);
    defer gpa.free(indices);
    const frames = [_]Frame{
        .{ .w = 0, .h = 3, .indices = &.{} },
        .{ .w = 3, .h = 0, .indices = &.{} },
        .{ .x = 5, .y = 5, .w = 0, .h = 0, .indices = &.{} },
        .{ .x = 6, .w = 0, .h = 1, .indices = &.{} },
        .{ .x = 5, .w = 2, .h = 1, .indices = indices[0..2] },
        .{ .y = 5, .w = 1, .h = 2, .indices = indices[0..2] },
        .{ .x = 0xffff, .w = 2, .h = 1, .indices = indices[0..2] },
        .{ .w = 4, .h = 4, .indices = indices[0..3] }, // fewer pixels than the frame
        .{ .w = 2, .h = 2, .indices = indices[0..9] }, // more
    };
    for (frames) |frame| {
        const bytes = try makeSimple(6, 6, frame, 4, 1);
        defer gpa.free(bytes);
        try expectGifAllSame(bytes, .{ .name = "frame size" });
    }
}

/// An animation of `count` frames over an 8x6 canvas, each frame a
/// rectangle that moves, with the disposal method `dispose` on each.
fn makeAnimation(count: u16, dispose: u3, transparent: ?u8, interlace: bool) ![]u8 {
    var writer: Writer = .{};
    errdefer writer.deinit();
    const table = palette(256, 5);
    try writer.header(8, 6, table[0..8], 2);
    for (0..count) |i| {
        const n: u16 = @intCast(i);
        const indices = try indicesFor(4, 3, 8, i);
        defer gpa.free(indices);
        try writer.frame(.{
            .x = n % 5,
            .y = n % 4,
            .w = 4,
            .h = 3,
            .indices = indices,
            .interlace = interlace,
            .control = .{ .dispose = dispose, .transparent = transparent, .delay = n * 7 },
        });
    }
    try writer.trailer();
    return writer.bytes.toOwnedSlice(gpa);
}

test "GIF animations with every disposal method decode as in the original" {
    for (0..8) |method| {
        for ([_]u16{ 1, 2, 3, 5 }) |count| {
            for ([_]?u8{ null, 3 }) |transparent| {
                const bytes = try makeAnimation(count, @intCast(method), transparent, method == 1);
                defer gpa.free(bytes);
                try expectGifAllSame(bytes, .{ .name = "dispose" });
            }
        }
    }
}

test "a GIF that restores to the previous frame once two frames are out is refused" {
    // The original reads the frame to restore from before its buffer. It
    // disposes of a frame when it reads on after it, so after the second
    // frame, even when only the trailer follows.
    for ([_]u16{ 2, 3 }) |count| {
        const bytes = try makeAnimation(count, 3, null, false);
        defer gpa.free(bytes);
        try std.testing.expectError(
            error.GifDisposeToPrevious,
            stbi.loadGifFromMemory(gpa, bytes, .{}),
        );
        try oracle.expectAllSame(gpa, bytes, .{ .name = "dispose 3, image" });
    }
    // On the first frame it restores to the background instead, as in the
    // original.
    var writer: Writer = .{};
    defer writer.deinit();
    const table = palette(256, 5);
    try writer.header(4, 4, table[0..4], 1);
    const indices = try indicesFor(4, 4, 4, 1);
    defer gpa.free(indices);
    try writer.frame(
        .{ .x = 1, .w = 3, .h = 4, .indices = indices[0..12], .control = .{ .dispose = 3 } },
    );
    try writer.frame(.{ .w = 2, .h = 2, .indices = indices[0..4], .control = .{ .dispose = 1 } });
    try writer.frame(.{ .w = 4, .h = 1, .indices = indices[0..4], .control = .{ .dispose = 2 } });
    try writer.trailer();
    try expectGifAllSame(writer.bytes.items, .{ .name = "dispose 3 on the first frame" });
}

test "a GIF restoring to the previous frame after an empty frame decodes as in the original" {
    // Restoring reads nothing where the last frame drew nothing.
    var writer: Writer = .{};
    defer writer.deinit();
    const table = palette(256, 5);
    try writer.header(4, 4, table[0..4], 0);
    const indices = try indicesFor(4, 4, 4, 1);
    defer gpa.free(indices);
    try writer.frame(.{ .w = 4, .h = 4, .indices = indices, .control = .{ .dispose = 3 } });
    try writer.frame(.{ .w = 0, .h = 4, .indices = &.{}, .control = .{ .dispose = 3 } });
    try writer.frame(.{ .w = 2, .h = 2, .indices = indices[0..4], .control = .{ .dispose = 1 } });
    try writer.trailer();
    try std.testing.expect(refusedAnimation(writer.bytes.items) == null);
    try expectGifAllSame(writer.bytes.items, .{ .name = "dispose 3 after an empty frame" });
}

test "a GIF animation of no pixels and more than one frame is refused" {
    // The original reallocates its frames to no bytes, then frees them twice.
    var writer: Writer = .{};
    defer writer.deinit();
    const table = palette(256, 5);
    try writer.header(0, 0, table[0..2], 0);
    try writer.frame(.{ .w = 0, .h = 0, .indices = &.{} });
    try writer.frame(.{ .w = 0, .h = 0, .indices = &.{} });
    try writer.trailer();
    try std.testing.expectError(
        error.GifZeroAreaFrames,
        stbi.loadGifFromMemory(gpa, writer.bytes.items, .{}),
    );
    try oracle.expectAllSame(gpa, writer.bytes.items, .{ .name = "no pixels, image" });
    // Only the sanitizer run, which calls the original in child processes,
    // can load the animation with the original.
    if (fuzz_options.sanitize) {
        try oracle.expectGifSame(gpa, writer.bytes.items, .{}, .{ .name = "no pixels, animation" });
    }
    // One frame of no pixels is an empty animation, as in the original.
    const one = try makeSimple(0, 3, .{ .w = 0, .h = 0, .indices = &.{} }, 2, 0);
    defer gpa.free(one);
    try expectGifAllSame(one, .{ .name = "no pixels, one frame" });
}

test "a flipped GIF animation of fewer than 4 components is refused" {
    // The original flips it as 4 components, past the end of its buffer.
    const bytes = try makeAnimation(2, 1, null, false);
    defer gpa.free(bytes);
    for ([_]stbi.Components{ .grey, .grey_alpha, .rgb }) |components| {
        try std.testing.expectError(error.GifFlipComponents, stbi.loadGifFromMemory(gpa, bytes, .{
            .flip_vertically = true,
            .components = components,
        }));
    }
    // A single row has nothing to swap.
    const row = try makeSimple(5, 1, .{ .w = 5, .h = 1, .indices = "\x00\x01\x02\x03\x00" }, 4, 0);
    defer gpa.free(row);
    try oracle.expectGifSame(
        gpa,
        row,
        .{ .flip_vertically = true, .components = .rgb },
        .{ .name = "one row" },
    );
}

test "GIF extensions and unknown blocks are read as in the original" {
    const screen = "GIF89a\x02\x00\x02\x00\x80\x00\x00\x10\x20\x30\x40\x50\x60";
    const image = "\x2c\x00\x00\x00\x00\x02\x00\x02\x00\x00\x02\x02\x84\x0a\x00";
    const middles = [_][]const u8{
        "\x21\xfe\x05hello\x00", // comment
        "\x21\xff\x0bNETSCAPE2.0\x03\x01\x00\x00\x00", // application
        "\x21\x01\x0c\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00", // plain text
        "\x21\xf9\x04\x09\x10\x00\x01\x00", // control: transparent 1, dispose 2
        "\x21\xf9\x05\x09\x10\x00\x01\x00\x00", // control of 5 bytes: skipped, rest read as tags
        "\x21\xf9\x03\x01\x02\x03\x00", // control of 3 bytes
        "\x21\xf9\x00\x00", // control of no bytes
        "\x21\xf9\x04\x01\xff\xff\x01\x00\x21\xf9\x04\x00\x05\x00\x00\x00", // two controls
        "\x21\xf9\x04\x01\x00\x00\x00\x02\x01\x00", // a control with more sub-blocks
        "\x00", // an unknown block
        "\x3b", // the trailer first
        "",
    };
    for (middles) |middle| {
        const bytes = try std.mem.concat(gpa, u8, &.{ screen, middle, image, "\x3b" });
        defer gpa.free(bytes);
        try expectGifAllSame(bytes, .{ .name = "extension" });
    }
}

test "GIF headers fail or decode as in the original" {
    const headers = [_][]const u8{
        "GIF87a\x01\x00\x01\x00\x00\x00\x00",
        "GIF88a\x01\x00\x01\x00\x00\x00\x00",
        "GIF89b\x01\x00\x01\x00\x00\x00\x00",
        "GIF8",
        "GIF89a",
        "GIF89a\x01\x00\x01\x00\x80",
        "GIF89a\xff\xff\xff\xff\x00\x00\x00", // 65535 square: too large
        "GIF89a\x00\x00\x00\x00\x00\x00\x00\x3b",
        "GIF89a\x01\x00\x01\x00\x00\x00\x00\x3b",
        "GIF89a\x01\x00\x01\x00\x87\x00\x00",
    };
    for (headers) |header| {
        try expectGifAllSame(header, .{ .name = "header" });
        const with_frame = try std.mem.concat(
            gpa,
            u8,
            &.{
                header,
                "\x2c\x00\x00\x00\x00\x01\x00\x01\x00\x80\x00\x00\x00\x00\x00\x00" ++
                    "\x02\x02\x44\x01\x00\x3b",
            },
        );
        defer gpa.free(with_frame);
        try expectGifAllSame(with_frame, .{ .name = "header with a frame" });
    }
}

test "GIF delays are given as in the original" {
    var writer: Writer = .{};
    defer writer.deinit();
    const table = palette(256, 5);
    try writer.header(3, 3, table[0..4], 0);
    const indices = try indicesFor(3, 3, 4, 1);
    defer gpa.free(indices);
    for ([_]?u16{ 0, 65535, null, 1, null, 300 }) |delay| {
        try writer.frame(
            .{
                .w = 3,
                .h = 3,
                .indices = indices,
                .control = if (delay) |d| .{ .delay = d } else null,
            },
        );
    }
    try writer.trailer();
    try expectGifAllSame(writer.bytes.items, .{ .name = "delays" });
    var animation = try stbi.loadGifFromMemory(gpa, writer.bytes.items, .{});
    defer animation.deinit(gpa);
    try std.testing.expectEqualSlices(
        i32,
        &.{ 0, 655350, 655350, 10, 10, 3000 },
        animation.delays_ms,
    );
}

test "a GIF animation that fails after its first frame keeps the frames before" {
    const bytes = try makeAnimation(4, 1, null, false);
    defer gpa.free(bytes);
    // Cut in the third frame, which starts where two frames end.
    const two = try makeAnimation(2, 1, null, false);
    defer gpa.free(two);
    const cut = two.len - 1 + 12;
    try expectGifAllSame(bytes[0..cut], .{ .name = "cut in frame 3" });
    var animation = try stbi.loadGifFromMemory(gpa, bytes[0..cut], .{});
    defer animation.deinit(gpa);
    try std.testing.expect(animation.frames >= 2);
}

test "a GIF truncated at every byte fails or decodes as in the original" {
    const bytes = try makeAnimation(3, 2, 1, true);
    defer gpa.free(bytes);
    for (0..bytes.len) |len| try expectGifAllSame(bytes[0..len], .{ .name = "truncated" });
}

test "the GIF size limits refuse as the original's do" {
    const bytes = try makeAnimation(2, 1, null, false);
    defer gpa.free(bytes);
    try std.testing.expectError(error.DimensionTooLarge, stbi.loadFromMemory(u8, gpa, bytes, .{
        .limits = .{ .dimension_max = 7 },
    }));
    try std.testing.expectError(error.TooLargeGif, stbi.loadGifFromMemory(gpa, bytes, .{
        .limits = .{ .bytes_max = 8 * 6 * 4 - 1 },
    }));
    // Two frames of 192 bytes pass one frame's check but not the buffer's.
    try std.testing.expectError(error.OutOfMemory, stbi.loadGifFromMemory(gpa, bytes, .{
        .limits = .{ .bytes_max = 8 * 6 * 4 + 1 },
    }));
}

fn loadForAllocationFailures(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    animation: bool,
) !void {
    if (animation) {
        var result = stbi.loadGifFromMemory(allocator, bytes, .{ .components = .rgb }) catch |err| {
            if (err == error.OutOfMemory) return err;
            return error.TestUnexpectedResult;
        };
        result.deinit(allocator);
    } else {
        var image = stbi.loadFromMemory(
            f32,
            allocator,
            bytes,
            .{ .components = .grey },
        ) catch |err| {
            if (err == error.OutOfMemory) return err;
            return error.TestUnexpectedResult;
        };
        image.deinit(allocator);
    }
}

test "a GIF load that runs out of memory at any allocation leaks nothing" {
    const bytes = try makeAnimation(3, 1, null, false);
    defer gpa.free(bytes);
    for ([_]bool{ false, true }) |animation| {
        try std.testing.checkAllAllocationFailures(
            gpa,
            loadForAllocationFailures,
            .{ bytes, animation },
        );
    }
}

/// The fuzz test's seeds: the corpus and hand-made files, in `arena`.
pub fn fuzzInputs(arena: std.mem.Allocator) ![]const []const u8 {
    var inputs: std.ArrayList([]const u8) = .empty;
    for ([_][]const u8{ "tests/images/gif", "tests/regression/gif" }) |dir| {
        const set = try corpus.load(arena, std.testing.io, .image_rs, dir, &.{".gif"});
        for (set.entries) |entry| try inputs.append(arena, entry.bytes);
    }
    const indices = try indicesFor(9, 7, 16, 4);
    defer gpa.free(indices);
    const local = palette(256, 9);
    const made = [_][]u8{
        try makeAnimation(3, 2, 1, false),
        try makeAnimation(4, 1, null, true),
        try makeAnimation(2, 0, 3, false),
        try makeSimple(9, 7, .{ .w = 9, .h = 7, .indices = indices, .min_size = 4 }, 16, 2),
        try makeSimple(
            12,
            9,
            .{
                .x = 2,
                .y = 1,
                .w = 9,
                .h = 7,
                .indices = indices,
                .interlace = true,
                .local_table = local[0..16],
            },
            null,
            0,
        ),
    };
    defer for (made) |bytes| gpa.free(bytes);
    for (made) |bytes| try inputs.append(arena, try arena.dupe(u8, bytes));
    return inputs.items;
}

/// Whether a fuzz case's animation is one the original is unsafe on.
pub fn unsafeCall(bytes: []const u8, request: oracle.Request) ?fuzz.Call {
    _ = request;
    return if (refusedAnimation(bytes) != null) .gif else null;
}

test "fuzz: mutated GIF files decode as in the original, as images and animations" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    try fuzz.run(gpa, gif_fuzz, try fuzzInputs(arena.allocator()));
}

pub const gif_fuzz: fuzz.Config = .{
    .name = "gif",
    .seed = 0x6f1f_0001,
    .cases = 2000,
    .gif = true,
    .unsafe = @import("gif_unsafe.zig").unsafe,
};
