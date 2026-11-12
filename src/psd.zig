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
            var scratch: [128]u8 = undefined;
            const run = source.takeBuffered(len) orelse blk: {
                source.readBytes(scratch[0..len]);
                break :blk scratch[0..len];
            };
            for (run) |byte| {
                out[p] = byte;
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

    const layout: Layout = .{
        .channel_count = channel_count,
        .height = height,
        .pixel_count = pixel_count,
        .bitdepth = bitdepth,
    };
    if (compression == 0 and bitdepth == 16 and request.bits_per_channel == 16) {
        // Allocated after the original's check of 8 bytes a pixel.
        if (!common.sizesValid(limits, &.{ 8, w, h }, 0)) return source.fail(error.OutOfMemory);
        const out = try gpa.alloc(u16, 4 * pixel_count);
        decodeRaw16(source, layout, out) catch |err| {
            gpa.free(out);
            return err;
        };
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
    const decoded = if (compression != 0)
        decodeRle8(source, layout, out)
    else
        decodeRaw8(source, layout, out);
    decoded catch |err| {
        gpa.free(out);
        return err;
    };
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

const Layout = struct {
    channel_count: u16,
    height: u32,
    pixel_count: usize,
    bitdepth: u16,
};

/// The samples of one channel, every fourth from its first; none in an
/// image of no pixels.
fn channelSamples(comptime T: type, out: []T, channel: usize) []T {
    return out[@min(channel, out.len)..];
}

/// Raw 16-bit samples into 16-bit pixels.
fn decodeRaw16(source: *Source, layout: Layout, out: []u16) Error!void {
    for (0..4) |channel| {
        const samples = channelSamples(u16, out, channel);
        if (channel >= layout.channel_count) {
            const value: u16 = if (channel == 3) 65535 else 0;
            for (0..layout.pixel_count) |i| samples[i * 4] = value;
        } else {
            for (0..layout.pixel_count) |i| samples[i * 4] = source.get16be();
        }
    }
    if (layout.channel_count >= 4) try removeWhiteMatte(u16, source, out);
}

/// Raw 8 or 16-bit samples into 8-bit pixels, the top byte of a 16-bit
/// sample.
fn decodeRaw8(source: *Source, layout: Layout, out: []u8) Error!void {
    const read: usize = @min(layout.channel_count, 4);
    if (layout.bitdepth == 16) {
        if (source.takeBuffered(2 * read * layout.pixel_count)) |planes| {
            interleavePlanes(2, planes, read, out);
            if (layout.channel_count >= 4) try removeWhiteMatte(u8, source, out);
            return;
        }
    } else if (source.takeBuffered(read * layout.pixel_count)) |planes| {
        interleavePlanes(1, planes, read, out);
        if (layout.channel_count >= 4) try removeWhiteMatte(u8, source, out);
        return;
    }
    // Planes past the buffer: one sample at a time, through the reader or
    // as zeros past the end.
    for (0..4) |channel| {
        const samples = channelSamples(u8, out, channel);
        if (channel >= layout.channel_count) {
            const value: u8 = if (channel == 3) 255 else 0;
            for (0..layout.pixel_count) |i| samples[i * 4] = value;
        } else {
            // A piece at a time, read as `get8` reads it; of a 16-bit
            // sample, the top byte.
            const size: usize = if (layout.bitdepth == 16) 2 else 1;
            var scratch: [1024]u8 = undefined;
            const piece = scratch.len / size;
            var i: usize = 0;
            while (i < layout.pixel_count) : (i += piece) {
                const n = @min(piece, layout.pixel_count - i);
                source.readBytes(scratch[0 .. n * size]);
                for (0..n) |j| samples[(i + j) * 4] = scratch[j * size];
            }
        }
    }
    if (layout.channel_count >= 4) try removeWhiteMatte(u8, source, out);
}

/// `planes` holds `read` channels of `out.len / 4` samples of `size`
/// bytes, big-endian; this puts each sample's top byte in its channel of
/// the four-byte pixels of `out`, 16 pixels at a time. A channel past
/// `read` is 0, or 255 for alpha.
fn interleavePlanes(comptime size: usize, planes: []const u8, read: usize, out: []u8) void {
    switch (read) {
        inline 0...4 => |r| interleaveRead(size, r, planes, out),
        else => unreachable,
    }
}

fn interleaveRead(comptime size: usize, comptime read: usize, planes: []const u8, out: []u8) void {
    const lanes = 16;
    const pixel_count = out.len / 4;
    const defaults = [4]u8{ 0, 0, 0, 255 };
    var i: usize = 0;
    // Fixed-size loops, which the compiler turns into vector code.
    while (i + lanes <= pixel_count) : (i += lanes) {
        var block: [4 * lanes]u8 = undefined;
        inline for (0..4) |c| {
            if (c < read) {
                const samples = planes[(c * pixel_count + i) * size ..][0 .. lanes * size];
                inline for (0..lanes) |k| block[k * 4 + c] = samples[k * size];
            } else {
                inline for (0..lanes) |k| block[k * 4 + c] = defaults[c];
            }
        }
        out[i * 4 ..][0 .. lanes * 4].* = block;
    }
    for (i..pixel_count) |k| {
        inline for (0..4) |c| {
            out[k * 4 + c] = if (c < read) planes[(c * pixel_count + k) * size] else defaults[c];
        }
    }
}

/// PackBits data into 8-bit pixels. The original decodes bytes at either
/// depth.
fn decodeRle8(source: *Source, layout: Layout, out: []u8) Error!void {
    // Each row's compressed length, which the decoder does not need.
    source.skip(@as(i64, layout.height) * layout.channel_count * 2);
    for (0..4) |channel| {
        const samples = channelSamples(u8, out, channel);
        if (channel >= layout.channel_count) {
            const value: u8 = if (channel == 3) 255 else 0;
            for (0..layout.pixel_count) |i| samples[i * 4] = value;
        } else if (!decodeRle(source, samples, layout.pixel_count)) {
            return source.fail(error.PsdBadRle);
        }
    }
    if (layout.channel_count >= 4) try removeWhiteMatte(u8, source, out);
}

/// Photoshop blends the colour of a partly transparent pixel of the
/// merged image with white; this undoes it, in the original's float steps.
/// The original converts a result outside the sample's range to an
/// integer, which is undefined; the port refuses such a pixel.
fn removeWhiteMatte(comptime T: type, source: *Source, out: []T) Error!void {
    const max: f32 = std.math.maxInt(T);
    var i: usize = 0;
    while (i + 4 * matte_lanes <= out.len) : (i += 4 * matte_lanes) {
        const block = out[i..][0 .. 4 * matte_lanes];
        if (!removeWhiteMatteBlock(T, block)) return source.fail(error.PsdMatteOutOfRange);
    }
    while (i < out.len) : (i += 4) {
        const pixel = out[i..][0..4];
        if (pixel[3] != 0 and pixel[3] != std.math.maxInt(T)) {
            const a = @as(f32, @floatFromInt(pixel[3])) / max;
            const ra = 1.0 / a;
            const inv_a = max * (1 - ra);
            for (pixel[0..3]) |*sample| {
                const value = @as(f32, @floatFromInt(sample.*)) * ra + inv_a;
                if (!(value > -1.0 and value < max + 1.0)) {
                    return source.fail(error.PsdMatteOutOfRange);
                }
                sample.* = @intFromFloat(value);
            }
        }
    }
}

/// The pixels `removeWhiteMatteBlock` works on at once.
const matte_lanes = 16;

/// The lanes of one channel of `matte_lanes` four-sample pixels.
fn channelLanes(comptime channel: usize) @Vector(matte_lanes, i32) {
    var mask: [matte_lanes]i32 = undefined;
    for (&mask, 0..) |*m, k| m.* = @intCast(k * 4 + channel);
    return mask;
}

/// Each pixel's lane of a channel, repeated over its four samples.
const spread_lanes: @Vector(4 * matte_lanes, i32) = blk: {
    var mask: [4 * matte_lanes]i32 = undefined;
    for (&mask, 0..) |*m, j| m.* = @intCast(j / 4);
    break :blk mask;
};

/// Which samples of `matte_lanes` pixels are of `channel`.
fn isChannel(comptime channel: usize) @Vector(4 * matte_lanes, bool) {
    var mask: [4 * matte_lanes]bool = undefined;
    for (&mask, 0..) |*m, j| m.* = j % 4 == channel;
    return mask;
}

/// `removeWhiteMatte` on `matte_lanes` pixels, with the same float steps in
/// vector lanes. False when a result falls outside the sample's range.
fn removeWhiteMatteBlock(comptime T: type, block: *[4 * matte_lanes]T) bool {
    const Floats = @Vector(matte_lanes, f32);
    const Samples = @Vector(matte_lanes, T);
    const max: Floats = @splat(std.math.maxInt(T));
    const pixels: @Vector(4 * matte_lanes, T) = block.*;
    const alpha: Samples = @shuffle(T, pixels, undefined, channelLanes(3));
    const partial = @select(
        bool,
        alpha != @as(Samples, @splat(0)),
        alpha != @as(Samples, @splat(std.math.maxInt(T))),
        @as(@Vector(matte_lanes, bool), @splat(false)),
    );
    if (!@reduce(.Or, partial)) return true;
    const a = @as(Floats, @floatFromInt(alpha)) / max;
    const ra = @as(Floats, @splat(1.0)) / a;
    const inv_a = max * (@as(Floats, @splat(1.0)) - ra);
    var result = pixels;
    inline for (0..3) |channel| {
        const samples: Samples = @shuffle(T, pixels, undefined, channelLanes(channel));
        const floats: Floats = @floatFromInt(samples);
        const value = floats * ra + inv_a;
        // NaN fails both comparisons, as in the scalar check.
        const in_range = @select(
            bool,
            value > @as(Floats, @splat(-1.0)),
            value < max + @as(Floats, @splat(1.0)),
            @as(@Vector(matte_lanes, bool), @splat(false)),
        );
        const bad = @select(bool, partial, !in_range, @as(@Vector(matte_lanes, bool), @splat(false)));
        if (@reduce(.Or, bad)) return false;
        // Opaque and fully transparent pixels keep their samples.
        const converted: Samples = @intFromFloat(@select(f32, partial, value, floats));
        const spread = @shuffle(T, converted, undefined, spread_lanes);
        result = @select(T, isChannel(channel), spread, result);
    }
    block.* = result;
    return true;
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

/// Whether the image has 16-bit samples, as the original's GCC and Clang
/// builds tell it. Leaves the source after the depth when it does, and
/// rewinds otherwise.
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
    // The original means to skip the height and width here, but outside
    // MSVC its `STBI_NOTUSED` does not evaluate the reads, so the depth it
    // checks is the top half of the height. The port does as those builds.
    if (source.get16be() != 16) {
        source.rewind();
        return false;
    }
    return true;
}
