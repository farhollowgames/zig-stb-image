//! Windows and OS/2 BMP: 1, 4 and 8-bit palettes, 16 and 32-bit pixels
//! with bit masks, and 24-bit pixels, stored bottom-up or top-down. The
//! compressed kinds (RLE, JPEG, PNG) are refused.

const std = @import("std");
const common = @import("common.zig");
const postprocess = @import("postprocess.zig");

const Source = common.Source;
const Error = common.Error;

/// Whether the input starts with a BMP file header and one of the info
/// header sizes this decoder reads. Rewinds.
pub fn detect(source: *Source) bool {
    const found = detectRaw(source);
    source.rewind();
    return found;
}

fn detectRaw(source: *Source) bool {
    if (source.get8() != 'B') return false;
    if (source.get8() != 'M') return false;
    _ = source.get32le(); // file size
    _ = source.get16le(); // reserved
    _ = source.get16le(); // reserved
    _ = source.get32le(); // pixel data offset
    return knownHeaderSize(source.get32le());
}

fn knownHeaderSize(size: u32) bool {
    return switch (size) {
        12, 40, 56, 108, 124 => true,
        else => false,
    };
}

/// The bit position of the highest set bit, -1 for zero.
fn highBit(z: u32) i32 {
    if (z == 0) return -1;
    return 31 - @as(i32, @clz(z));
}

const mul_table = [9]u32{ 0, 0xff, 0x55, 0x49, 0x11, 0x21, 0x41, 0x81, 0x01 };
const shift_table = [9]u5{ 0, 0, 0, 1, 0, 2, 4, 6, 0 };

/// The `bits`-bit field of `v` whose top bit `shift` moves to bit 7,
/// widened to 8 bits by repeating its bits, so a full field gives 255.
/// The callers pass masks of 1 to 8 bits, so the field fits in a byte.
fn shiftSigned(v: u32, shift: i32, bits: u32) u32 {
    var field = v;
    if (shift < 0) {
        field <<= @intCast(-shift);
    } else {
        field >>= @intCast(shift);
    }
    field >>= @intCast(8 - bits);
    return (field * mul_table[bits]) >> shift_table[bits];
}

const Header = struct {
    bpp: i32 = 0,
    offset: i32 = 0,
    size: i32 = 0,
    mr: u32 = 0,
    mg: u32 = 0,
    mb: u32 = 0,
    ma: u32 = 0,
    /// Every alpha value read, or-ed together; 0 at the end means a 32-bit
    /// image whose alpha channel is all zero, which is shown opaque.
    all_a: u32 = 255,
    /// The bytes of the file header and of the masks after a 40 or 56-byte
    /// info header, which the palette size and pixel offset leave out.
    extra_read: i32 = 14,
};

/// The default masks of uncompressed 16 and 32-bit pixels; false for a
/// compression whose masks are not known.
fn setMaskDefaults(header: *Header, compress: i32) bool {
    // Bit fields give the masks in the header.
    if (compress == 3) return true;
    if (compress == 0) {
        if (header.bpp == 16) {
            header.mr = 31 << 10;
            header.mg = 31 << 5;
            header.mb = 31 << 0;
        } else if (header.bpp == 32) {
            header.mr = 0xff << 16;
            header.mg = 0xff << 8;
            header.mb = 0xff << 0;
            header.ma = 0xff << 24;
            header.all_a = 0;
        } else {
            header.mr = 0;
            header.mg = 0;
            header.mb = 0;
            header.ma = 0;
        }
        return true;
    }
    return false;
}

/// Reads the file header and the info header into `header` and the size
/// into `source.img_x` and `source.img_y`, the height as stored (negative
/// for top-down images).
fn parseHeader(source: *Source, header: *Header) Error!void {
    if (source.get8() != 'B' or source.get8() != 'M') return source.fail(error.NotBmp);
    _ = source.get32le(); // file size
    _ = source.get16le(); // reserved
    _ = source.get16le(); // reserved
    header.offset = @bitCast(source.get32le());
    header.size = @bitCast(source.get32le());
    header.mr = 0;
    header.mg = 0;
    header.mb = 0;
    header.ma = 0;
    header.extra_read = 14;

    if (header.offset < 0) return source.fail(error.BadBmp);
    const size = header.size;
    if (!knownHeaderSize(@bitCast(size))) return source.fail(error.UnknownBmp);
    if (size == 12) {
        source.img_x = source.get16le();
        source.img_y = source.get16le();
    } else {
        source.img_x = source.get32le();
        source.img_y = source.get32le();
    }
    if (source.get16le() != 1) return source.fail(error.BadBmp); // planes
    header.bpp = source.get16le();
    if (size == 12) return;

    const compress: i32 = @bitCast(source.get32le());
    if (compress == 1 or compress == 2) return source.fail(error.BmpRle);
    if (compress >= 4) return source.fail(error.BmpJpegPng);
    // Bit fields need 16 or 32-bit pixels.
    if (compress == 3 and header.bpp != 16 and header.bpp != 32) {
        return source.fail(error.BadBmp);
    }
    _ = source.get32le(); // image size
    _ = source.get32le(); // horizontal resolution
    _ = source.get32le(); // vertical resolution
    _ = source.get32le(); // colours used
    _ = source.get32le(); // important colours
    if (size == 40 or size == 56) {
        if (size == 56) {
            for (0..4) |_| _ = source.get32le();
        }
        if (header.bpp == 16 or header.bpp == 32) {
            if (compress == 0) {
                _ = setMaskDefaults(header, compress);
            } else if (compress == 3) {
                header.mr = source.get32le();
                header.mg = source.get32le();
                header.mb = source.get32le();
                header.extra_read += 12;
                // Three equal masks select no colour; Photoshop writes
                // such files and Paint refuses them.
                if (header.mr == header.mg and header.mg == header.mb) {
                    return source.fail(error.BadBmp);
                }
            } else return source.fail(error.BadBmp);
        }
    } else {
        // The V4 and V5 headers hold the masks whatever the compression;
        // the defaults replace them unless the compression is bit fields.
        header.mr = source.get32le();
        header.mg = source.get32le();
        header.mb = source.get32le();
        header.ma = source.get32le();
        if (compress != 3) _ = setMaskDefaults(header, compress);
        _ = source.get32le(); // colour space
        for (0..12) |_| _ = source.get32le(); // colour space end points and gamma
        if (size == 124) {
            _ = source.get32le(); // rendering intent
            _ = source.get32le(); // profile offset
            _ = source.get32le(); // profile size
            _ = source.get32le(); // reserved
        }
    }
}

fn componentsInFile(header: Header) u3 {
    if (header.bpp == 24 and header.ma == 0xff000000) return 3;
    return if (header.ma != 0) 4 else 3;
}

pub fn load(gpa: std.mem.Allocator, source: *Source, request: common.Request) Error!common.Decoded {
    const limits = request.options.limits;
    var header: Header = .{};
    try parseHeader(source, &header);

    const stored_height: i32 = @bitCast(source.img_y);
    // The original takes abs() of the stored height, which is undefined
    // for the most negative int; as a size it is too large anyway.
    if (stored_height == std.math.minInt(i32)) return source.fail(error.DimensionTooLarge);
    const bottom_up = stored_height > 0;
    source.img_y = @abs(stored_height);
    if (source.img_y > limits.dimension_max) return source.fail(error.DimensionTooLarge);
    if (source.img_x > limits.dimension_max) return source.fail(error.DimensionTooLarge);

    var palette_len: i32 = 0;
    if (header.size == 12) {
        // The original counts the OS/2 header as 24 bytes here, not 12, so
        // it reads four palette entries fewer than the file has.
        if (header.bpp < 24) palette_len = @divTrunc(header.offset - header.extra_read - 24, 3);
    } else {
        if (header.bpp < 16) palette_len = (header.offset - header.extra_read - header.size) >> 2;
    }
    if (palette_len == 0) {
        // Some bytes may follow the headers, but an offset before their
        // end, or far past it, marks the file as malformed.
        const read_so_far: i64 = @intCast(source.bytesRead());
        const header_limit = 1024;
        const extra_data_limit = 256 * 4;
        if (read_so_far <= 0 or read_so_far > header_limit) return source.fail(error.BadBmpHeader);
        if (header.offset < read_so_far or header.offset - read_so_far > extra_data_limit) {
            return source.fail(error.BadBmpOffset);
        }
        source.skip(header.offset - read_so_far);
    }

    const img_n = componentsInFile(header);
    source.img_n = img_n;
    const req_comp = request.req_comp;
    // 3 and 4 components decode directly; 1 and 2 are converted after.
    const target: u3 = if (req_comp >= 3) req_comp else img_n;
    const size = [_]i64{ target, source.img_x, source.img_y };
    if (!common.sizesValid(limits, &size, 0)) return source.fail(error.TooLargeBmp);
    const out = try common.allocChecked(u8, gpa, limits, &size, 0);
    decodePixels(source, header, palette_len, target, out) catch |err| {
        gpa.free(out);
        return err;
    };
    if (bottom_up) postprocess.verticalFlip(u8, out, source.img_x, source.img_y, target);

    const pixels = if (req_comp != 0 and req_comp != target)
        try common.convertFormat(gpa, limits, out, target, req_comp, source.img_x, source.img_y)
    else
        out;
    return .{
        .pixels = .{ .u8 = pixels },
        .width = source.img_x,
        .height = source.img_y,
        .channels_in_file = img_n,
    };
}

fn decodePixels(
    source: *Source,
    header: Header,
    palette_len: i32,
    target: u3,
    out: []u8,
) Error!void {
    var all_a = header.all_a;
    if (header.bpp < 16) {
        if (palette_len == 0 or palette_len > 256) return source.fail(error.InvalidBmp);
        try decodePalette(source, header, palette_len, target, out);
    } else {
        source.skip(header.offset - header.extra_read - header.size);
        try decodeMasked(source, header, target, out, &all_a);
    }
    // An alpha channel of all zeros is taken as no alpha at all.
    if (target == 4 and all_a == 0) {
        var i: usize = 3;
        while (i < out.len) : (i += 4) out[i] = 255;
    }
}

/// The bytes that pad a row of `row_bytes` to a multiple of four.
fn padding(row_bytes: u64) u32 {
    return @intCast((4 - row_bytes % 4) % 4);
}

fn decodeMasked(
    source: *Source,
    header: Header,
    target: u3,
    out: []u8,
    all_a: *u32,
) Error!void {
    const width: u64 = source.img_x;
    const height: u64 = source.img_y;
    const row_bytes: u64 = switch (header.bpp) {
        24 => 3 * width,
        16 => 2 * width,
        // 32-bit rows need no padding.
        else => 0,
    };
    const pad = padding(row_bytes);
    const mr = header.mr;
    const mg = header.mg;
    const mb = header.mb;
    const ma = header.ma;
    const Layout = enum { masked, bgr, bgra };
    var layout: Layout = .masked;
    if (header.bpp == 24) {
        layout = .bgr;
    } else if (header.bpp == 32) {
        if (mb == 0xff and mg == 0xff00 and mr == 0x00ff0000 and ma == 0xff000000) layout = .bgra;
    }
    var shifts: [4]i32 = @splat(0);
    var counts: [4]u32 = @splat(0);
    if (layout == .masked) {
        if (mr == 0 or mg == 0 or mb == 0) return source.fail(error.BadBmpMasks);
        // The shift that puts each mask's high bit at bit 7.
        for ([4]u32{ mr, mg, mb, ma }, &shifts, &counts) |mask, *shift, *count| {
            shift.* = highBit(mask) - 7;
            count.* = @popCount(mask);
        }
        for (counts) |count| {
            if (count > 8) return source.fail(error.BadBmpMasks);
        }
    }
    var z: usize = 0;
    for (0..height) |_| {
        if (layout != .masked) {
            for (0..width) |_| {
                out[z + 2] = source.get8();
                out[z + 1] = source.get8();
                out[z + 0] = source.get8();
                z += 3;
                const a: u8 = if (layout == .bgra) source.get8() else 255;
                all_a.* |= a;
                if (target == 4) {
                    out[z] = a;
                    z += 1;
                }
            }
        } else {
            for (0..width) |_| {
                const v: u32 = if (header.bpp == 16) source.get16le() else source.get32le();
                out[z + 0] = @truncate(shiftSigned(v & mr, shifts[0], counts[0]));
                out[z + 1] = @truncate(shiftSigned(v & mg, shifts[1], counts[1]));
                out[z + 2] = @truncate(shiftSigned(v & mb, shifts[2], counts[2]));
                z += 3;
                const a: u32 = if (ma != 0) shiftSigned(v & ma, shifts[3], counts[3]) else 255;
                all_a.* |= a;
                if (target == 4) {
                    out[z] = @truncate(a);
                    z += 1;
                }
            }
        }
        source.skip(pad);
    }
}

fn decodePalette(
    source: *Source,
    header: Header,
    palette_len: i32,
    target: u3,
    out: []u8,
) Error!void {
    const width: u64 = source.img_x;
    const height: u64 = source.img_y;
    // A negative palette size reads no entries.
    const entries: u32 = @intCast(@max(palette_len, 0));
    // The original reads an entry it never filled from uninitialized stack
    // memory; the port reads it as zero.
    var palette: [256][4]u8 = @splat(@splat(0));
    for (palette[0..entries]) |*entry| {
        entry[2] = source.get8();
        entry[1] = source.get8();
        entry[0] = source.get8();
        if (header.size != 12) _ = source.get8();
        entry[3] = 255;
    }
    const entry_size: i32 = if (header.size == 12) 3 else 4;
    source.skip(header.offset - header.extra_read - header.size - palette_len * entry_size);
    const row_bytes: u64 = switch (header.bpp) {
        1 => (width + 7) >> 3,
        4 => (width + 1) >> 1,
        8 => width,
        else => return source.fail(error.BadBmpBitsPerPixel),
    };
    const pad = padding(row_bytes);
    var z: usize = 0;
    if (header.bpp == 1) {
        for (0..height) |_| {
            var bit_offset: u3 = 7;
            var v = source.get8();
            for (0..width) |i| {
                const color = (v >> bit_offset) & 1;
                putEntry(&palette, color, target, out, &z);
                if (i + 1 == width) break;
                if (bit_offset == 0) {
                    bit_offset = 7;
                    v = source.get8();
                } else bit_offset -= 1;
            }
            source.skip(pad);
        }
    } else {
        for (0..height) |_| {
            var i: u64 = 0;
            while (i < width) : (i += 2) {
                var v = source.get8();
                var v2: u8 = 0;
                if (header.bpp == 4) {
                    v2 = v & 15;
                    v >>= 4;
                }
                putEntry(&palette, v, target, out, &z);
                if (i + 1 == width) break;
                v = if (header.bpp == 8) source.get8() else v2;
                putEntry(&palette, v, target, out, &z);
            }
            source.skip(pad);
        }
    }
}

/// Writes palette entry `index` as one pixel of `target` components.
inline fn putEntry(palette: *const [256][4]u8, index: u8, target: u3, out: []u8, z: *usize) void {
    const entry = palette[index];
    out[z.*..][0..3].* = entry[0..3].*;
    z.* += 3;
    if (target == 4) {
        out[z.*] = 255;
        z.* += 1;
    }
}

/// The size and components of the image, without decoding it. The height
/// is the stored one, as the original's `int`: a top-down image gives the
/// two's complement of its height. Leaves the source after the headers
/// when it finds them, and rewinds otherwise.
pub fn info(source: *Source) ?common.Info {
    var header: Header = .{};
    parseHeader(source, &header) catch {
        source.rewind();
        return null;
    };
    return .{
        .width = source.img_x,
        .height = source.img_y,
        .channels_in_file = componentsInFile(header),
    };
}
