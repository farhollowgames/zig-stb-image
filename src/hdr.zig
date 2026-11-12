//! Radiance RGBE files (`.hdr`), as stb_image's `stbi__hdr_*` read them:
//! a text header, then pixels of a shared exponent, flat or run-length
//! encoded by scanline, decoded to floats.

const std = @import("std");
const common = @import("common.zig");

const Source = common.Source;
const Error = common.Error;

/// stb_image reads header lines into a buffer of this size.
const line_buffer_len = 1024;

/// `stbi__hdr_test`: the file starts with one of the two signatures.
pub fn detect(source: *Source) bool {
    var found = testCore(source, "#?RADIANCE\n");
    source.rewind();
    if (!found) {
        found = testCore(source, "#?RGBE\n");
        source.rewind();
    }
    return found;
}

fn testCore(source: *Source, signature: []const u8) bool {
    for (signature) |c| {
        if (source.get8() != c) return false;
    }
    source.rewind();
    return true;
}

/// `stbi__hdr_gettoken`: the next line without its newline, cut at 1023
/// bytes (the rest of a longer line is skipped) and, as the C string it is
/// there, at its first NUL. The last byte of the input ends the line without
/// being part of it.
fn getToken(source: *Source, buffer: *[line_buffer_len]u8) []const u8 {
    var len: usize = 0;
    var c = source.get8();
    while (!source.atEof() and c != '\n') {
        buffer[len] = c;
        len += 1;
        if (len == line_buffer_len - 1) {
            while (!source.atEof() and source.get8() != '\n') {}
            break;
        }
        c = source.get8();
    }
    const line = buffer[0..len];
    return line[0 .. std.mem.indexOfScalar(u8, line, 0) orelse len];
}

const Parsed = struct {
    value: i64,
    rest: []const u8,
};

/// C's `strtol(text, &end, 10)`: leading white space, a sign, then digits,
/// saturating at the range of a 64-bit `long`. Without digits the value is
/// 0 and nothing is consumed.
fn strtol(text: []const u8) Parsed {
    var at: usize = 0;
    while (at < text.len and isSpace(text[at])) at += 1;
    var negative = false;
    if (at < text.len and (text[at] == '+' or text[at] == '-')) {
        negative = text[at] == '-';
        at += 1;
    }
    const digits_start = at;
    const limit: u64 = if (negative) 1 << 63 else (1 << 63) - 1;
    var magnitude: u64 = 0;
    while (at < text.len and std.ascii.isDigit(text[at])) : (at += 1) {
        const digit = text[at] - '0';
        if (magnitude > (limit - digit) / 10) {
            magnitude = limit;
        } else {
            magnitude = magnitude * 10 + digit;
        }
    }
    if (at == digits_start) return .{ .value = 0, .rest = text };
    const value: i64 = if (negative) @bitCast(0 -% magnitude) else @intCast(magnitude);
    return .{ .value = value, .rest = text[at..] };
}

fn isSpace(c: u8) bool {
    return c == ' ' or (c >= '\t' and c <= '\r');
}

/// The size line, `-Y <height> +X <width>`, each number as C's
/// `(int) strtol(...)` gives it.
const Size = struct {
    width: i32,
    height: i32,
};

fn parseSize(line: []const u8) ?Size {
    if (!std.mem.startsWith(u8, line, "-Y ")) return null;
    const height = strtol(line[3..]);
    var rest = height.rest;
    while (rest.len > 0 and rest[0] == ' ') rest = rest[1..];
    if (!std.mem.startsWith(u8, rest, "+X ")) return null;
    const width = strtol(rest[3..]);
    return .{ .width = @truncate(width.value), .height = @truncate(height.value) };
}

/// Reads the header lines up to the first empty one; whether one of them
/// names the format stb_image decodes.
fn readFormatLines(source: *Source, buffer: *[line_buffer_len]u8) bool {
    var valid = false;
    while (true) {
        const token = getToken(source, buffer);
        if (token.len == 0) break;
        if (std.mem.eql(u8, token, "FORMAT=32-bit_rle_rgbe")) valid = true;
    }
    return valid;
}

/// `stbi__hdr_load`: floats of `req_comp` components, or 3 when none are
/// asked for.
pub fn load(
    gpa: std.mem.Allocator,
    source: *Source,
    request: common.Request,
) Error!common.Decoded {
    const limits = request.options.limits;
    var buffer: [line_buffer_len]u8 = undefined;
    const header = getToken(source, &buffer);
    if (!std.mem.eql(u8, header, "#?RADIANCE") and !std.mem.eql(u8, header, "#?RGBE")) {
        return source.fail(error.NotHdr);
    }
    if (!readFormatLines(source, &buffer)) return source.fail(error.UnsupportedHdrFormat);
    const size = parseSize(getToken(source, &buffer)) orelse
        return source.fail(error.UnsupportedHdrLayout);
    if (size.height > limits.dimension_max) return source.fail(error.DimensionTooLarge);
    if (size.width > limits.dimension_max) return source.fail(error.DimensionTooLarge);

    const comp: u3 = if (request.req_comp == 0) 3 else request.req_comp;
    if (!common.sizesValid(limits, &.{ size.width, size.height, comp, @sizeOf(f32) }, 0)) {
        return source.fail(error.TooLargeHdr);
    }
    const width: usize = @intCast(size.width);
    const height: usize = @intCast(size.height);
    const data = try gpa.alloc(f32, width * height * comp);
    errdefer gpa.free(data);

    if (width < 8 or width >= 32768) {
        try readFlat(source, data, comp, 0);
    } else {
        try readRle(gpa, source, data, width, comp, limits);
    }
    return .{
        .pixels = .{ .f32 = data },
        .width = @intCast(width),
        .height = @intCast(height),
        .channels_in_file = 3,
    };
}

/// Flat pixels, four bytes each, from pixel `first` to the end. The original
/// converts a pixel it could not read from uninitialized memory; the port
/// refuses the file there.
fn readFlat(source: *Source, data: []f32, comp: u3, first: usize) Error!void {
    var pixel = first;
    while (pixel * comp < data.len) : (pixel += 1) {
        var rgbe: [4]u8 = undefined;
        if (!source.getn(&rgbe)) return source.fail(error.HdrTruncated);
        convert(data[pixel * comp ..][0..comp], rgbe, comp);
    }
}

/// Run-length encoded scanlines: each starts with 2, 2 and its width in 15
/// bits, then holds the four bytes of every pixel as four sequences of runs
/// and literals. A scanline without that start is the old flat form: the
/// original decodes it as the first pixel of the image and reads every pixel
/// after that flat, on whichever scanline it came.
fn readRle(
    gpa: std.mem.Allocator,
    source: *Source,
    data: []f32,
    width: usize,
    comp: u3,
    limits: common.Limits,
) Error!void {
    var scanline: ?[]u8 = null;
    defer if (scanline) |line| gpa.free(line);
    const height = data.len / (width * comp);
    for (0..height) |row| {
        const c1 = source.get8();
        const c2 = source.get8();
        const len_high = source.get8();
        if (c1 != 2 or c2 != 2 or len_high & 0x80 != 0) {
            const rgbe = [4]u8{ c1, c2, len_high, source.get8() };
            convert(data[0..comp], rgbe, comp);
            return readFlat(source, data, comp, 1);
        }
        const len = (@as(u32, len_high) << 8) | source.get8();
        if (len != width) return source.fail(error.BadHdrScanlineLength);
        const line = scanline orelse blk: {
            scanline = try common.allocChecked(u8, gpa, limits, &.{ @intCast(width), 4 }, 0);
            break :blk scanline.?;
        };
        for (0..4) |k| {
            var i: usize = 0;
            while (i < width) {
                const left = width - i;
                var count: usize = source.get8();
                if (count > 128) {
                    const value = source.get8();
                    count -= 128;
                    if (count == 0 or count > left) return source.fail(error.HdrBadRle);
                    for (0..count) |_| {
                        line[i * 4 + k] = value;
                        i += 1;
                    }
                } else {
                    if (count == 0 or count > left) return source.fail(error.HdrBadRle);
                    for (0..count) |_| {
                        line[i * 4 + k] = source.get8();
                        i += 1;
                    }
                }
            }
        }
        for (0..width) |i| {
            convert(data[(row * width + i) * comp ..][0..comp], line[i * 4 ..][0..4].*, comp);
        }
    }
}

/// `stbi__hdr_convert`: one RGBE pixel to `comp` floats; grey is the mean
/// of the three, alpha 1.
fn convert(output: []f32, rgbe: [4]u8, comp: u3) void {
    if (rgbe[3] != 0) {
        const f1 = std.math.ldexp(@as(f32, 1.0), @as(i32, rgbe[3]) - (128 + 8));
        if (comp <= 2) {
            const sum: u32 = @as(u32, rgbe[0]) + rgbe[1] + rgbe[2];
            output[0] = @as(f32, @floatFromInt(sum)) * f1 / 3;
        } else {
            for (0..3) |c| output[c] = @as(f32, @floatFromInt(rgbe[c])) * f1;
        }
        if (comp == 2) output[1] = 1;
        if (comp == 4) output[3] = 1;
    } else {
        switch (comp) {
            4 => output[0..4].* = .{ 0, 0, 0, 1 },
            3 => output[0..3].* = .{ 0, 0, 0 },
            2 => output[0..2].* = .{ 0, 1 },
            1 => output[0] = 0,
            else => unreachable,
        }
    }
}

/// `stbi__hdr_info`. The original also reports a negative size, which
/// `Info` cannot hold: the port refuses those files.
pub fn info(source: *Source) ?common.Info {
    if (!detect(source)) {
        source.rewind();
        return null;
    }
    var buffer: [line_buffer_len]u8 = undefined;
    if (!readFormatLines(source, &buffer)) {
        source.rewind();
        return null;
    }
    const size = parseSize(getToken(source, &buffer)) orelse {
        source.rewind();
        return null;
    };
    if (size.width < 0 or size.height < 0) {
        source.rewind();
        return null;
    }
    return .{
        .width = @intCast(size.width),
        .height = @intCast(size.height),
        .channels_in_file = 3,
    };
}

test strtol {
    try std.testing.expectEqual(@as(i64, 42), strtol("  42 +X").value);
    try std.testing.expectEqualStrings(" +X", strtol("  42 +X").rest);
    try std.testing.expectEqual(@as(i64, -7), strtol("-7").value);
    try std.testing.expectEqualStrings("x", strtol("x").rest);
    try std.testing.expectEqualStrings(" -", strtol(" -").rest);
    const max = std.math.maxInt(i64);
    const min = std.math.minInt(i64);
    try std.testing.expectEqual(@as(i64, max), strtol("99999999999999999999").value);
    try std.testing.expectEqual(@as(i64, min), strtol("-99999999999999999999").value);
    try std.testing.expectEqual(@as(i64, min), strtol("-9223372036854775808").value);
}
