//! Truevision TGA: colour-mapped, true-colour and grey images, raw or
//! run-length encoded, at 8, 15, 16, 24 and 32 bits, top-down or
//! bottom-up. 15 and 16-bit colour is read as RGB without alpha.

const std = @import("std");
const common = @import("common.zig");
const postprocess = @import("postprocess.zig");

const Source = common.Source;
const Error = common.Error;

/// The components a pixel of `bits_per_pixel` bits decodes to, 0 for a
/// size this decoder does not read. `is_rgb16` is set for 15 and 16-bit
/// colour, which is stored as 5 bits per channel.
fn getComp(bits_per_pixel: u8, is_grey: bool, is_rgb16: ?*bool) u3 {
    if (is_rgb16) |flag| flag.* = false;
    switch (bits_per_pixel) {
        8 => return 1,
        15, 16 => {
            if (bits_per_pixel == 16 and is_grey) return 2;
            if (is_rgb16) |flag| flag.* = true;
            return 3;
        },
        24, 32 => return @intCast(bits_per_pixel / 8),
        else => return 0,
    }
}

/// The size and components of the image, without decoding it. Leaves the
/// source after the header when it is valid, and rewinds otherwise.
pub fn info(source: *Source) ?common.Info {
    _ = source.get8(); // image ID length
    const colormap_type = source.get8();
    if (colormap_type > 1) {
        // Only true-colour and colour-mapped images.
        source.rewind();
        return null;
    }
    const image_type = source.get8();
    var colormap_bpp: u8 = 0;
    if (colormap_type == 1) {
        if (image_type != 1 and image_type != 9) {
            source.rewind();
            return null;
        }
        source.skip(4); // first entry index and entry count
        const entry_bits = source.get8();
        if (entry_bits != 8 and entry_bits != 15 and entry_bits != 16 and entry_bits != 24 and
            entry_bits != 32)
        {
            source.rewind();
            return null;
        }
        source.skip(4); // x and y origin
        colormap_bpp = entry_bits;
    } else {
        if (image_type != 2 and image_type != 3 and image_type != 10 and image_type != 11) {
            source.rewind();
            return null;
        }
        source.skip(9); // colour map specification and x and y origin
    }
    const width = source.get16le();
    if (width < 1) {
        source.rewind();
        return null;
    }
    const height = source.get16le();
    if (height < 1) {
        source.rewind();
        return null;
    }
    const bits_per_pixel = source.get8();
    _ = source.get8(); // image descriptor
    var comp: u3 = 0;
    if (colormap_bpp != 0) {
        // With a colour map, the pixel size is that of an index.
        if (bits_per_pixel != 8 and bits_per_pixel != 16) {
            source.rewind();
            return null;
        }
        comp = getComp(colormap_bpp, false, null);
    } else {
        comp = getComp(bits_per_pixel, image_type == 3 or image_type == 11, null);
    }
    if (comp == 0) {
        source.rewind();
        return null;
    }
    return .{ .width = width, .height = height, .channels_in_file = comp };
}

/// Whether the header is one this decoder reads. TGA has no signature, so
/// this is tried after every other format. Rewinds.
pub fn detect(source: *Source) bool {
    const found = detectRaw(source);
    source.rewind();
    return found;
}

fn detectRaw(source: *Source) bool {
    _ = source.get8(); // image ID length
    const colormap_type = source.get8();
    if (colormap_type > 1) return false;
    const image_type = source.get8();
    if (colormap_type == 1) {
        if (image_type != 1 and image_type != 9) return false;
        source.skip(4); // first entry index and entry count
        if (!validBits(source.get8())) return false;
        source.skip(4); // x and y origin
    } else {
        if (image_type != 2 and image_type != 3 and image_type != 10 and image_type != 11) {
            return false;
        }
        source.skip(9); // colour map specification and x and y origin
    }
    if (source.get16le() < 1) return false; // width
    if (source.get16le() < 1) return false; // height
    const bits_per_pixel = source.get8();
    // With a colour map, the pixel size is that of an index.
    if (colormap_type == 1 and bits_per_pixel != 8 and bits_per_pixel != 16) return false;
    return validBits(bits_per_pixel);
}

fn validBits(bits: u8) bool {
    return switch (bits) {
        8, 15, 16, 24, 32 => true,
        else => false,
    };
}

/// Reads a 15 or 16-bit pixel as RGB, its top bit ignored.
fn readRgb16(source: *Source, out: *[3]u8) void {
    const px = source.get16le();
    const r: u32 = (px >> 10) & 31;
    const g: u32 = (px >> 5) & 31;
    const b: u32 = px & 31;
    out[0] = @intCast((r * 255) / 31);
    out[1] = @intCast((g * 255) / 31);
    out[2] = @intCast((b * 255) / 31);
}

pub fn load(gpa: std.mem.Allocator, source: *Source, request: common.Request) Error!common.Decoded {
    const limits = request.options.limits;
    const id_length = source.get8();
    const indexed = source.get8() != 0;
    var image_type = source.get8();
    const palette_start = source.get16le();
    const palette_len = source.get16le();
    const palette_bits = source.get8();
    _ = source.get16le(); // x origin
    _ = source.get16le(); // y origin
    const width = source.get16le();
    const height = source.get16le();
    const bits_per_pixel = source.get8();
    const descriptor = source.get8();

    if (height > limits.dimension_max) return source.fail(error.DimensionTooLarge);
    if (width > limits.dimension_max) return source.fail(error.DimensionTooLarge);

    var is_rle = false;
    if (image_type >= 8) {
        image_type -= 8;
        is_rle = true;
    }
    // Bit 5 of the descriptor marks a top-down image.
    const bottom_up = (descriptor >> 5) & 1 == 0;

    var rgb16 = false;
    const comp = if (indexed)
        getComp(palette_bits, false, &rgb16)
    else
        getComp(bits_per_pixel, image_type == 3, &rgb16);
    if (comp == 0) return source.fail(error.BadTgaFormat);

    const size = [_]i64{ width, height, comp };
    if (!common.sizesValid(limits, &size, 0)) return source.fail(error.TooLargeTga);
    const data = try common.allocChecked(u8, gpa, limits, &size, 0);
    const header: Header = .{
        .indexed = indexed,
        .is_rle = is_rle,
        .rgb16 = rgb16,
        .bottom_up = bottom_up,
        .index_bits = bits_per_pixel,
        .comp = comp,
        .width = width,
        .height = height,
        .palette_start = palette_start,
        .palette_len = palette_len,
    };
    source.skip(id_length);
    decodeImage(gpa, source, limits, header, data) catch |err| {
        gpa.free(data);
        return err;
    };

    // The file stores BGR; 15 and 16-bit pixels were read as RGB already.
    if (comp >= 3 and !rgb16) {
        var i: usize = 0;
        while (i < data.len) : (i += comp) std.mem.swap(u8, &data[i], &data[i + 2]);
    }

    const pixels = if (request.req_comp != 0 and request.req_comp != comp)
        try common.convertFormat(gpa, limits, data, comp, request.req_comp, width, height)
    else
        data;
    return .{
        .pixels = .{ .u8 = pixels },
        .width = width,
        .height = height,
        .channels_in_file = comp,
    };
}

const Header = struct {
    indexed: bool,
    is_rle: bool,
    rgb16: bool,
    bottom_up: bool,
    /// The size of a colour map index, 8 or 16 bits.
    index_bits: u8,
    comp: u3,
    width: u16,
    height: u16,
    palette_start: u16,
    palette_len: u16,
};

/// Decodes the colour map and the pixels into `data`, top row first.
fn decodeImage(
    gpa: std.mem.Allocator,
    source: *Source,
    limits: common.Limits,
    header: Header,
    data: []u8,
) Error!void {
    const row_len = @as(usize, header.width) * header.comp;
    if (!header.indexed and !header.is_rle and !header.rgb16) {
        for (0..header.height) |i| {
            const row = if (header.bottom_up) header.height - i - 1 else i;
            // The original leaves a row it cannot read whole as it found
            // it, uninitialized; the port refuses the image.
            if (!source.getn(data[row * row_len ..][0..row_len])) {
                return source.fail(error.TgaTruncated);
            }
        }
        return;
    }
    var palette: []u8 = &.{};
    defer gpa.free(palette);
    if (header.indexed) {
        if (header.palette_len == 0) return source.fail(error.BadTgaPalette);
        source.skip(header.palette_start);
        const palette_size = [_]i64{ header.palette_len, header.comp };
        palette = try common.allocChecked(u8, gpa, limits, &palette_size, 0);
        if (header.rgb16) {
            for (0..header.palette_len) |i| readRgb16(source, palette[i * 3 ..][0..3]);
        } else if (!source.getn(palette)) {
            return source.fail(error.BadTgaPalette);
        }
    }
    decodePixels(source, header, palette, data);
    if (header.bottom_up) {
        postprocess.verticalFlip(u8, data, header.width, header.height, header.comp);
    }
}

/// Decodes every pixel of a colour-mapped, run-length encoded or 15 and
/// 16-bit image into `data`, in file order.
fn decodePixels(source: *Source, header: Header, palette: []const u8, data: []u8) void {
    const comp = header.comp;
    const entries = palette.len / comp;
    var raw: [4]u8 = @splat(0);
    var rle_count: u32 = 0;
    var rle_repeating = false;
    var read_next_pixel = true;
    var i: usize = 0;
    while (i < data.len) : (i += comp) {
        if (header.is_rle) {
            if (rle_count == 0) {
                const command = source.get8();
                rle_count = 1 + @as(u32, command & 127);
                rle_repeating = command >> 7 != 0;
                read_next_pixel = true;
            } else if (!rle_repeating) {
                read_next_pixel = true;
            }
        } else {
            read_next_pixel = true;
        }
        if (read_next_pixel) {
            if (header.indexed) {
                var index: usize = if (header.index_bits == 8) source.get8() else source.get16le();
                // An index past the colour map reads the first entry.
                if (index >= entries) index = 0;
                @memcpy(raw[0..comp], palette[index * comp ..][0..comp]);
            } else if (header.rgb16) {
                readRgb16(source, raw[0..3]);
            } else {
                for (raw[0..comp]) |*byte| byte.* = source.get8();
            }
            read_next_pixel = false;
        }
        @memcpy(data[i..][0..comp], raw[0..comp]);
        if (header.is_rle) rle_count -= 1;
    }
}
