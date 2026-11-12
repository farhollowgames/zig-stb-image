//! Binary PGM (P5) and PPM (P6), 8 bits per sample, or 16 bits when the
//! maximum value passes 255. Samples are not scaled to the maximum value,
//! and 16-bit samples are copied as stored, big-endian, into native words.

const std = @import("std");
const common = @import("common.zig");

const Source = common.Source;
const Error = common.Error;

/// Whether the input starts with "P5" or "P6". Rewinds only when it does
/// not.
pub fn detect(source: *Source) bool {
    const p = source.get8();
    const t = source.get8();
    if (p != 'P' or (t != '5' and t != '6')) {
        source.rewind();
        return false;
    }
    return true;
}

pub fn load(gpa: std.mem.Allocator, source: *Source, request: common.Request) Error!common.Decoded {
    const limits = request.options.limits;
    var img_n: u8 = 0;
    const bits = readHeader(source, &source.img_x, &source.img_y, &img_n);
    if (bits == 0) return source.staleFailure();
    source.img_n = img_n;
    const x = source.img_x;
    const y = source.img_y;
    if (y > limits.dimension_max) return source.fail(error.DimensionTooLarge);
    if (x > limits.dimension_max) return source.fail(error.DimensionTooLarge);
    if (!common.sizesValid(limits, &.{ img_n, x, y, bits / 8 }, 0)) {
        return source.fail(error.TooLargePnm);
    }
    const comp: u3 = @intCast(img_n);
    const req_comp = request.req_comp;
    if (bits == 16) {
        const out = try gpa.alloc(u16, @as(usize, img_n) * x * y);
        if (!source.getn(std.mem.sliceAsBytes(out))) {
            gpa.free(out);
            return source.fail(error.BadPnm);
        }
        const pixels = if (req_comp != 0 and req_comp != comp)
            try common.convertFormat16(gpa, out, comp, req_comp, x, y)
        else
            out;
        return .{
            .pixels = .{ .u16 = pixels },
            .width = x,
            .height = y,
            .channels_in_file = img_n,
        };
    }
    const out = try gpa.alloc(u8, @as(usize, img_n) * x * y);
    if (!source.getn(out)) {
        gpa.free(out);
        return source.fail(error.BadPnm);
    }
    const pixels = if (req_comp != 0 and req_comp != comp)
        try common.convertFormat(gpa, limits, out, comp, req_comp, x, y)
    else
        out;
    return .{
        .pixels = .{ .u8 = pixels },
        .width = x,
        .height = y,
        .channels_in_file = img_n,
    };
}

fn isSpace(c: u8) bool {
    return switch (c) {
        ' ', '\t', '\n', 0x0b, 0x0c, '\r' => true,
        else => false,
    };
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

/// Skips whitespace and `#` comments, which run to the end of their line.
/// `c` is the byte read last, and is left at the first byte after them.
fn skipWhitespace(source: *Source, c: *u8) void {
    while (true) {
        while (!source.atEof() and isSpace(c.*)) c.* = source.get8();
        if (source.atEof() or c.* != '#') break;
        while (!source.atEof() and c.* != '\n' and c.* != '\r') c.* = source.get8();
    }
}

/// Reads a decimal number starting at `c`. A number that may not fit in
/// an `int` gives 0 and the overflow reason: the check is made after each
/// digit, on whether one more digit could overflow, whatever follows.
fn getInteger(source: *Source, c: *u8) u32 {
    var value: u32 = 0;
    while (!source.atEof() and isDigit(c.*)) {
        value = value * 10 + (c.* - '0');
        c.* = source.get8();
        // `c` is a C `char`, signed: bytes from 0x80 compare below '7'.
        const next: i8 = @bitCast(c.*);
        if (value > 214748364 or (value == 214748364 and next > '7')) {
            source.reason = error.PnmIntegerOverflow;
            return 0;
        }
    }
    return value;
}

/// Reads the header: the size into `x` and `y`, the components into
/// `comp`. Gives the bits per sample, 8 or 16, or 0 when the header is not
/// one this decoder reads. Rewinds first, and again only when the
/// signature is wrong.
fn readHeader(source: *Source, x: *u32, y: *u32, comp: *u8) u8 {
    source.rewind();
    const p = source.get8();
    const t = source.get8();
    if (p != 'P' or (t != '5' and t != '6')) {
        source.rewind();
        return 0;
    }
    comp.* = if (t == '6') 3 else 1;
    var c = source.get8();
    skipWhitespace(source, &c);
    x.* = getInteger(source, &c);
    if (x.* == 0) {
        source.reason = error.InvalidPnmWidth;
        return 0;
    }
    skipWhitespace(source, &c);
    y.* = getInteger(source, &c);
    if (y.* == 0) {
        source.reason = error.InvalidPnmWidth;
        return 0;
    }
    skipWhitespace(source, &c);
    const max_value = getInteger(source, &c);
    if (max_value > 65535) {
        source.reason = error.PnmMaxValueTooLarge;
        return 0;
    }
    return if (max_value > 255) 16 else 8;
}

/// The size and components of the image, without decoding it.
pub fn info(source: *Source) ?common.Info {
    var x: u32 = 0;
    var y: u32 = 0;
    var comp: u8 = 0;
    if (readHeader(source, &x, &y, &comp) == 0) return null;
    return .{ .width = x, .height = y, .channels_in_file = comp };
}

/// Whether the maximum value asks for 16-bit samples.
pub fn is16(source: *Source) bool {
    var x: u32 = 0;
    var y: u32 = 0;
    var comp: u8 = 0;
    return readHeader(source, &x, &y, &comp) == 16;
}
