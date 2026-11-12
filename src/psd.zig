//! Photoshop PSD: the merged image of an RGB document, 8 or 16 bits per
//! channel, raw or PackBits-compressed. Only the first four channels are
//! read; a channel the file lacks is 0, or opaque for alpha.

const std = @import("std");
const common = @import("common.zig");

const Source = common.Source;
const Error = common.Error;

const signature = 0x38425053; // "8BPS"

/// Whether the input starts with the PSD signature. Rewinds.
pub fn detect(source: *Source) bool {
    const found = source.get32be() == signature;
    source.rewind();
    return found;
}

/// Decodes `pixel_count` bytes of PackBits data into every fourth byte of
/// `out`, starting at its first. False when a run passes the end.
fn decodeRle(source: *Source, out: []u8, pixel_count: usize) bool {
    var count: usize = 0;
    var p: usize = 0;
    while (count < pixel_count) {
        const left = pixel_count - count;
        var len: usize = source.get8();
        if (len == 128) {
            // No operation.
        } else if (len < 128) {
            // The next len + 1 bytes, as they are.
            len += 1;
            if (len > left) return false;
            count += len;
            for (0..len) |_| {
                out[p] = source.get8();
                p += 4;
            }
        } else {
            // The next byte, 257 - len times.
            len = 257 - len;
            if (len > left) return false;
            const value = source.get8();
            count += len;
            for (0..len) |_| {
                out[p] = value;
                p += 4;
            }
        }
    }
    return true;
}

pub fn load(gpa: std.mem.Allocator, source: *Source, request: common.Request) Error!common.Decoded {
    const limits = request.options.limits;
    if (source.get32be() != signature) return source.fail(error.NotPsd);
    if (source.get16be() != 1) return source.fail(error.WrongPsdVersion);
    source.skip(6); // reserved
    const channel_count = source.get16be();
    if (channel_count > 16) return source.fail(error.WrongPsdChannelCount);
    // The original holds the size in `int`s: past 2^31 they are negative,
    // which the size check refuses.
    const h: i32 = @bitCast(source.get32be());
    const w: i32 = @bitCast(source.get32be());
    if (h > limits.dimension_max) return source.fail(error.DimensionTooLarge);
    if (w > limits.dimension_max) return source.fail(error.DimensionTooLarge);
    const bitdepth = source.get16be();
    if (bitdepth != 8 and bitdepth != 16) return source.fail(error.UnsupportedPsdBitDepth);
    if (source.get16be() != 3) return source.fail(error.WrongPsdColorFormat); // RGB
    // The mode data, the image resources and the layers, each after its
    // length. A length past 2^31 is a negative skip, to the end.
    for (0..3) |_| source.skip(@as(i32, @bitCast(source.get32be())));
    const compression = source.get16be();
    if (compression > 1) return source.fail(error.PsdBadCompression);

    if (!common.sizesValid(limits, &.{ 4, w, h }, 0)) return source.fail(error.TooLargePsd);
    const width: u32 = @intCast(w);
    const height: u32 = @intCast(h);
    const pixel_count = @as(usize, width) * height;

    if (compression == 0 and bitdepth == 16 and request.bits_per_channel == 16) {
        // Allocated after the original's check of 8 bytes a pixel.
        if (!common.sizesValid(limits, &.{ 8, w, h }, 0)) return source.fail(error.OutOfMemory);
        const out = try gpa.alloc(u16, 4 * pixel_count);
        errdefer gpa.free(out);
        for (0..4) |channel| {
            const samples = out[channel..];
            if (channel >= channel_count) {
                const value: u16 = if (channel == 3) 65535 else 0;
                for (0..pixel_count) |i| samples[i * 4] = value;
            } else {
                for (0..pixel_count) |i| samples[i * 4] = source.get16be();
            }
        }
        if (channel_count >= 4) try removeWhiteMatte(u16, source, out);
        const pixels = if (request.req_comp != 0 and request.req_comp != 4)
            try common.convertFormat16(gpa, out, 4, request.req_comp, width, height)
        else
            out;
        return .{
            .pixels = .{ .u16 = pixels },
            .width = width,
            .height = height,
            .channels_in_file = 4,
        };
    }

    const out = try gpa.alloc(u8, 4 * pixel_count);
    errdefer gpa.free(out);
    if (compression != 0) {
        // Each row's compressed length, which the decoder does not need.
        source.skip(@as(i64, h) * channel_count * 2);
        for (0..4) |channel| {
            const samples = out[channel..];
            if (channel >= channel_count) {
                const value: u8 = if (channel == 3) 255 else 0;
                for (0..pixel_count) |i| samples[i * 4] = value;
            } else if (!decodeRle(source, samples, pixel_count)) {
                return source.fail(error.PsdBadRle);
            }
        }
    } else {
        for (0..4) |channel| {
            const samples = out[channel..];
            if (channel >= channel_count) {
                const value: u8 = if (channel == 3) 255 else 0;
                for (0..pixel_count) |i| samples[i * 4] = value;
            } else if (bitdepth == 16) {
                for (0..pixel_count) |i| samples[i * 4] = @intCast(source.get16be() >> 8);
            } else {
                for (0..pixel_count) |i| samples[i * 4] = source.get8();
            }
        }
    }
    if (channel_count >= 4) try removeWhiteMatte(u8, source, out);
    const pixels = if (request.req_comp != 0 and request.req_comp != 4)
        try common.convertFormat(gpa, limits, out, 4, request.req_comp, width, height)
    else
        out;
    return .{
        .pixels = .{ .u8 = pixels },
        .width = width,
        .height = height,
        .channels_in_file = 4,
    };
}

/// Photoshop blends the colour of a partly transparent pixel of the
/// merged image with white; this undoes it, in the original's float steps.
/// The original converts a result outside the sample's range to an
/// integer, which is undefined; the port refuses such a pixel.
fn removeWhiteMatte(comptime T: type, source: *Source, out: []T) Error!void {
    const max: f32 = std.math.maxInt(T);
    var i: usize = 0;
    while (i < out.len) : (i += 4) {
        const pixel = out[i..][0..4];
        if (pixel[3] != 0 and pixel[3] != std.math.maxInt(T)) {
            const a = @as(f32, @floatFromInt(pixel[3])) / max;
            const ra = 1.0 / a;
            const inv_a = max * (1 - ra);
            for (pixel[0..3]) |*sample| {
                const value = @as(f32, @floatFromInt(sample.*)) * ra + inv_a;
                if (!(value > -1.0 and value < max + 1.0)) return source.fail(error.PsdMatteOutOfRange);
                sample.* = @intFromFloat(value);
            }
        }
    }
}

/// The size of the image, without decoding it; the components are always
/// 4. The size is the stored one, as the original's `int`s. Leaves the
/// source after the header when it is valid, and rewinds otherwise.
pub fn info(source: *Source) ?common.Info {
    if (source.get32be() != signature) {
        source.rewind();
        return null;
    }
    if (source.get16be() != 1) {
        source.rewind();
        return null;
    }
    source.skip(6);
    const channel_count = source.get16be();
    if (channel_count > 16) {
        source.rewind();
        return null;
    }
    const height = source.get32be();
    const width = source.get32be();
    const depth = source.get16be();
    if (depth != 8 and depth != 16) {
        source.rewind();
        return null;
    }
    if (source.get16be() != 3) {
        source.rewind();
        return null;
    }
    return .{ .width = width, .height = height, .channels_in_file = 4 };
}

/// Whether the image has 16-bit samples. Leaves the source after the depth
/// when it does, and rewinds otherwise.
pub fn is16(source: *Source) bool {
    if (source.get32be() != signature) {
        source.rewind();
        return false;
    }
    if (source.get16be() != 1) {
        source.rewind();
        return false;
    }
    source.skip(6);
    const channel_count = source.get16be();
    if (channel_count > 16) {
        source.rewind();
        return false;
    }
    _ = source.get32be(); // height
    _ = source.get32be(); // width
    if (source.get16be() != 16) {
        source.rewind();
        return false;
    }
    return true;
}
