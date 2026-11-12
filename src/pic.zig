//! Softimage PIC, as stb_image's `stbi__pic_*` read it: a 104-byte header,
//! up to ten channel packets, then each scanline as one run of data per
//! packet, uncompressed, run-length encoded or mixed.

const std = @import("std");
const common = @import("common.zig");

const Source = common.Source;
const Error = common.Error;

/// A packet's channels are one bit each, from the highest: red, green,
/// blue, alpha.
const alpha_bit = 0x10;

const Packet = struct {
    size: u8,
    type: u8,
    channel: u8,
};

const max_packets = 10;

fn is4(source: *Source, bytes: *const [4]u8) bool {
    for (bytes) |b| {
        if (source.get8() != b) return false;
    }
    return true;
}

fn testCore(source: *Source) bool {
    if (!is4(source, "\x53\x80\xF6\x34")) return false;
    for (0..84) |_| _ = source.get8();
    return is4(source, "PICT");
}

/// `stbi__pic_test`: the magic number, and `PICT` 88 bytes on.
pub fn detect(source: *Source) bool {
    const found = testCore(source);
    source.rewind();
    return found;
}

/// `stbi__readval`: the bytes of the channels `channel` names, into
/// `dest`.
fn readValue(source: *Source, channel: u8, dest: *[4]u8) Error!void {
    var mask: u8 = 0x80;
    for (dest) |*byte| {
        if (channel & mask != 0) {
            if (source.atEof()) return source.fail(error.PicShortValue);
            byte.* = source.get8();
        }
        mask >>= 1;
    }
}

/// `stbi__copyval`.
fn copyValue(channel: u8, dest: *[4]u8, value: *const [4]u8) void {
    var mask: u8 = 0x80;
    for (dest, value) |*byte, v| {
        if (channel & mask != 0) byte.* = v;
        mask >>= 1;
    }
}

/// The packets of the header. `comp` gets 4 when one of them holds alpha,
/// 3 otherwise.
fn readPackets(source: *Source, packets: *[max_packets]Packet, comp: *u3) Error![]const Packet {
    var count: usize = 0;
    var channels: u8 = 0;
    while (true) {
        if (count == max_packets) return source.fail(error.PicTooManyPackets);
        const chained = source.get8();
        const packet: Packet = .{
            .size = source.get8(),
            .type = source.get8(),
            .channel = source.get8(),
        };
        packets[count] = packet;
        count += 1;
        channels |= packet.channel;
        if (source.atEof()) return source.fail(error.PicShortPackets);
        if (packet.size != 8) return source.fail(error.PicPacketNot8Bit);
        if (chained == 0) break;
    }
    comp.* = if (channels & alpha_bit != 0) 4 else 3;
    return packets[0..count];
}

/// `stbi__pic_load_core`'s scanlines into `result`, RGBA.
fn readScanlines(
    source: *Source,
    packets: []const Packet,
    width: usize,
    height: usize,
    result: []u8,
) Error!void {
    for (0..height) |y| {
        for (packets) |packet| {
            const row = result[y * width * 4 ..][0 .. width * 4];
            switch (packet.type) {
                0 => {
                    // Uncompressed.
                    for (0..width) |x| try readValue(source, packet.channel, row[x * 4 ..][0..4]);
                },
                1 => {
                    // Runs only: a count, then the value to repeat.
                    var x: usize = 0;
                    while (x < width) {
                        var count: usize = source.get8();
                        if (source.atEof()) return source.fail(error.PicShortPureCount);
                        count = @min(count, width - x);
                        var value: [4]u8 = undefined;
                        try readValue(source, packet.channel, &value);
                        for (0..count) |_| {
                            copyValue(packet.channel, row[x * 4 ..][0..4], &value);
                            x += 1;
                        }
                    }
                },
                2 => {
                    // Runs and literals: a count of 128 or more is a run, of
                    // 16 bits after it when it is 128 itself.
                    var x: usize = 0;
                    while (x < width) {
                        var count: usize = source.get8();
                        if (source.atEof()) return source.fail(error.PicShortMixedCount);
                        if (count >= 128) {
                            if (count == 128) count = source.get16be() else count -= 127;
                            if (count > width - x) return source.fail(error.PicScanlineOverrun);
                            var value: [4]u8 = undefined;
                            try readValue(source, packet.channel, &value);
                            for (0..count) |_| {
                                copyValue(packet.channel, row[x * 4 ..][0..4], &value);
                                x += 1;
                            }
                        } else {
                            count += 1;
                            if (count > width - x) return source.fail(error.PicScanlineOverrun);
                            for (0..count) |_| {
                                try readValue(source, packet.channel, row[x * 4 ..][0..4]);
                                x += 1;
                            }
                        }
                    }
                },
                else => return source.fail(error.PicBadPacketType),
            }
        }
    }
}

/// `stbi__pic_load`: the image converted to `req_comp` components, or to
/// the file's 3 or 4.
///
/// When the packets or the scanlines fail, the original converts the null
/// image it is left with to the requested components, or to the file's
/// when none are asked for: 4 give the failure, as nothing is converted.
/// With no pixels, 1 to 3 convert nothing and give an empty image, as the
/// port does; its `channels_in_file` is the file's 3 or 4 if the packets
/// set it, else 0 where the original leaves the caller's `*comp`. With
/// pixels it reads the null image, and with nothing asked for before the
/// packets set the file's components it uses the caller's `*comp` (an
/// assert in a debug build): the port returns the failure in these.
pub fn load(
    gpa: std.mem.Allocator,
    source: *Source,
    request: common.Request,
) Error!common.Decoded {
    const limits = request.options.limits;
    for (0..92) |_| _ = source.get8();
    const x: u32 = source.get16be();
    const y: u32 = source.get16be();
    if (y > limits.dimension_max) return source.fail(error.DimensionTooLarge);
    if (x > limits.dimension_max) return source.fail(error.DimensionTooLarge);
    if (source.atEof()) return source.fail(error.PicShortHeader);
    if (!common.sizesValid(limits, &.{ x, y, 4 }, 0)) return source.fail(error.TooLargePic);

    _ = source.get32be(); // the aspect ratio
    _ = source.get16be(); // the fields
    _ = source.get16be(); // padding

    // The image is read as RGBA, opaque white where no packet writes.
    const result = try common.allocChecked(u8, gpa, limits, &.{ x, y, 4 }, 0);
    var comp: u3 = 0;
    @memset(result, 0xff);
    var packets: [max_packets]Packet = undefined;
    const core: Error!void = if (readPackets(source, &packets, &comp)) |used|
        readScanlines(source, used, x, y, result)
    else |err|
        err;
    const req_comp = if (request.req_comp == 0) comp else request.req_comp;
    core catch |err| if (@as(u64, x) * y != 0 or req_comp == 0 or req_comp == 4) {
        gpa.free(result);
        return err;
    };
    return .{
        .pixels = .{ .u8 = try common.convertFormat(gpa, limits, result, 4, req_comp, x, y) },
        .width = x,
        .height = y,
        .channels_in_file = comp,
    };
}

/// `stbi__pic_info`. After ten chained packets the original fails without
/// rewinding, as the port does: in a build without PNM, whose info rewinds
/// first, the HDR signature test after it reads on from the packets.
pub fn info(source: *Source) ?common.Info {
    if (!is4(source, "\x53\x80\xF6\x34")) {
        source.rewind();
        return null;
    }
    source.skip(88);
    const x: u32 = source.get16be();
    const y: u32 = source.get16be();
    if (source.atEof()) {
        source.rewind();
        return null;
    }
    if (x != 0 and (1 << 28) / x < y) {
        source.rewind();
        return null;
    }
    source.skip(8);

    var count: usize = 0;
    var channels: u8 = 0;
    while (true) {
        if (count == max_packets) return null;
        count += 1;
        const chained = source.get8();
        const size = source.get8();
        _ = source.get8(); // the type
        channels |= source.get8();
        if (source.atEof() or size != 8) {
            source.rewind();
            return null;
        }
        if (chained == 0) break;
    }
    return .{
        .width = x,
        .height = y,
        .channels_in_file = if (channels & alpha_bit != 0) 4 else 3,
    };
}
