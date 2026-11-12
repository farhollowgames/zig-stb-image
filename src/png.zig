//! stb_image's PNG decoder: every colour type at 1, 2, 4, 8 and 16 bits,
//! palettes and tRNS transparency, Adam7 interlacing, and Apple's iPhone
//! PNGs (CgBI: raw DEFLATE data, BGR order, premultiplied alpha). CRCs are
//! not checked and ancillary chunks are skipped, as in the original.

const std = @import("std");
const common = @import("common.zig");
const zlib = @import("zlib.zig");

const Source = common.Source;
const Error = common.Error;

/// `stbi__png_test`: whether the input starts with the PNG signature.
pub fn detect(source: *Source) bool {
    const found = if (checkHeader(source)) |_| true else |_| false;
    source.rewind();
    return found;
}

/// `stbi__png_load`: decodes the image, at 8 bits or, for 16-bit files, at
/// 16, with `request.req_comp` components if asked.
pub fn load(gpa: std.mem.Allocator, source: *Source, request: common.Request) Error!common.Decoded {
    var png: Png = .{ .source = source, .gpa = gpa, .options = request.options };
    defer png.deinit();
    try png.parse(.load, request.req_comp);
    const samples = png.out.?;
    png.out = null;

    const req_comp = request.req_comp;
    const out_n: u3 = @intCast(source.img_out_n);
    const x = source.img_x;
    const y = source.img_y;
    var pixels: common.Pixels = if (samples.wide)
        .{ .u16 = samples.wideSlice() }
    else
        .{ .u8 = samples.bytes };
    if (req_comp != 0 and req_comp != out_n) {
        pixels = switch (pixels) {
            .u8 => |bytes| .{ .u8 = try common.convertFormat(
                gpa,
                request.options.limits,
                bytes,
                out_n,
                req_comp,
                x,
                y,
            ) },
            .u16 => |wide| .{ .u16 = try common.convertFormat16(gpa, wide, out_n, req_comp, x, y) },
            .f32 => unreachable,
        };
        source.img_out_n = req_comp;
    }
    return .{
        .pixels = pixels,
        .width = x,
        .height = y,
        .channels_in_file = @intCast(source.img_n),
    };
}

/// `stbi__png_info`: the size and channel count from the chunks before the
/// first IDAT. Rewinds only on failure, as the original.
pub fn info(source: *Source) ?common.Info {
    var png: Png = .header(source);
    png.infoRaw() catch return null;
    return .{
        .width = source.img_x,
        .height = source.img_y,
        .channels_in_file = @intCast(source.img_n),
    };
}

/// `stbi__png_is16`.
pub fn is16(source: *Source) bool {
    var png: Png = .header(source);
    png.infoRaw() catch return false;
    if (png.depth != 16) {
        source.rewind();
        return false;
    }
    return true;
}

fn checkHeader(source: *Source) Error!void {
    const signature = [8]u8{ 137, 80, 78, 71, 13, 10, 26, 10 };
    for (signature) |byte| {
        if (source.get8() != byte) return source.fail(error.BadPngSignature);
    }
}

fn chunkType(comptime name: *const [4]u8) u32 {
    return std.mem.readInt(u32, name, .big);
}

const chunk_cgbi = chunkType("CgBI");
const chunk_ihdr = chunkType("IHDR");
const chunk_plte = chunkType("PLTE");
const chunk_trns = chunkType("tRNS");
const chunk_idat = chunkType("IDAT");
const chunk_iend = chunkType("IEND");

/// How far `stbi__parse_png_file` goes: the whole image, or the chunks up
/// to the first IDAT for the size and channel count.
const Scan = enum { load, header };

/// The factor that scales a grey sample of each bit depth to 0..255.
const depth_scale = [9]u8{ 0, 0xff, 0x55, 0, 0x11, 0, 0, 0, 0x01 };

const Filter = enum(u8) {
    none = 0,
    sub = 1,
    up = 2,
    avg = 3,
    paeth = 4,
    /// Average on the first row, where there is no row above.
    avg_first = 5,
};

/// The filter the first row uses in place of each, so it never reads the
/// row above: up becomes none, average reads only the left byte, and Paeth
/// with no row above is sub.
const first_row_filter = [5]Filter{ .none, .sub, .none, .avg_first, .sub };

/// Decoded samples, as bytes. 16-bit samples are allocated as `u16`, in
/// the machine's byte order, so they can be handed out as such.
const Samples = struct {
    bytes: []u8,
    wide: bool,

    fn alloc(gpa: std.mem.Allocator, len: usize, wide: bool) Error!Samples {
        if (wide) {
            return .{ .bytes = std.mem.sliceAsBytes(try gpa.alloc(u16, len / 2)), .wide = true };
        }
        return .{ .bytes = try gpa.alloc(u8, len), .wide = false };
    }

    fn wideSlice(samples: Samples) []u16 {
        const aligned: []align(2) u8 = @alignCast(samples.bytes);
        return std.mem.bytesAsSlice(u16, aligned);
    }

    fn free(samples: Samples, gpa: std.mem.Allocator) void {
        if (samples.wide) gpa.free(samples.wideSlice()) else gpa.free(samples.bytes);
    }
};

/// `stbi__png`: a decode's buffers.
const Png = struct {
    source: *Source,
    gpa: std.mem.Allocator,
    options: *const common.Options,
    /// The IDAT chunks' data, joined.
    idata: std.ArrayList(u8) = .empty,
    /// The original allocates `idata` at the first IDAT chunk with data.
    has_idata: bool = false,
    out: ?Samples = null,
    depth: u8 = 0,

    const header_options: common.Options = .{};

    /// For a scan of the header, which never allocates.
    fn header(source: *Source) Png {
        return .{ .source = source, .gpa = .failing, .options = &header_options };
    }

    fn deinit(png: *Png) void {
        png.idata.deinit(png.gpa);
        if (png.out) |out| out.free(png.gpa);
        png.* = undefined;
    }

    /// `stbi__png_info_raw`.
    fn infoRaw(png: *Png) Error!void {
        png.parse(.header, 0) catch |err| {
            png.source.rewind();
            return err;
        };
    }

    /// `stbi__parse_png_file`: reads the chunks, and for `.load` decodes
    /// the image into `out`.
    fn parse(png: *Png, scan: Scan, req_comp: u3) Error!void {
        const s = png.source;
        const limits = png.options.limits;
        var palette: [1024]u8 = undefined;
        // The entries some PLTE chunk has set; a later, shorter PLTE leaves
        // the ones past it as they were, and the original reads them.
        var palette_set: u32 = 0;
        var pal_len: u32 = 0;
        var pal_img_n: u8 = 0;
        var has_trans = false;
        var tc: [3]u8 = @splat(0);
        var tc16: [3]u16 = @splat(0);
        var first = true;
        var interlace = false;
        var color: u8 = 0;
        var is_iphone = false;

        try checkHeader(s);
        while (true) {
            const length = s.get32be();
            const chunk = s.get32be();
            switch (chunk) {
                chunk_cgbi => {
                    is_iphone = true;
                    s.skip(@as(i32, @bitCast(length)));
                },
                chunk_ihdr => {
                    if (!first) return s.fail(error.MultipleIhdr);
                    first = false;
                    if (length != 13) return s.fail(error.BadIhdrLength);
                    s.img_x = s.get32be();
                    s.img_y = s.get32be();
                    if (s.img_y > limits.dimension_max) return s.fail(error.DimensionTooLarge);
                    if (s.img_x > limits.dimension_max) return s.fail(error.DimensionTooLarge);
                    png.depth = s.get8();
                    switch (png.depth) {
                        1, 2, 4, 8, 16 => {},
                        else => return s.fail(error.PngBadBitDepth),
                    }
                    color = s.get8();
                    if (color > 6) return s.fail(error.BadColorType);
                    if (color == 3 and png.depth == 16) return s.fail(error.BadColorType);
                    if (color == 3) {
                        pal_img_n = 3;
                    } else if (color & 1 != 0) {
                        return s.fail(error.BadColorType);
                    }
                    if (s.get8() != 0) return s.fail(error.BadCompressionMethod);
                    if (s.get8() != 0) return s.fail(error.BadPngFilterMethod);
                    const interlace_method = s.get8();
                    if (interlace_method > 1) return s.fail(error.BadPngInterlaceMethod);
                    interlace = interlace_method == 1;
                    if (s.img_x == 0 or s.img_y == 0) return s.fail(error.ZeroPixelPng);
                    if (pal_img_n == 0) {
                        const colour_n: u32 = if (color & 2 != 0) 3 else 1;
                        const n: u32 = colour_n + @intFromBool(color & 4 != 0);
                        s.img_n = @intCast(n);
                        if ((1 << 30) / s.img_x / n < s.img_y) return s.fail(error.ImageTooLarge);
                    } else {
                        // A palette image decodes to indices, one
                        // component, expanded at the end.
                        s.img_n = 1;
                        if ((1 << 30) / s.img_x / 4 < s.img_y) return s.fail(error.TooLargePng);
                    }
                    // A header scan reads on to see whether a tRNS follows.
                },
                chunk_plte => {
                    if (first) return s.fail(error.FirstNotIhdr);
                    if (length > 256 * 3) return s.fail(error.InvalidPlte);
                    pal_len = length / 3;
                    if (pal_len * 3 != length) return s.fail(error.InvalidPlte);
                    for (0..pal_len) |i| {
                        palette[i * 4 + 0] = s.get8();
                        palette[i * 4 + 1] = s.get8();
                        palette[i * 4 + 2] = s.get8();
                        palette[i * 4 + 3] = 255;
                    }
                    palette_set = @max(palette_set, pal_len);
                },
                chunk_trns => {
                    if (first) return s.fail(error.FirstNotIhdr);
                    if (png.has_idata) return s.fail(error.TrnsAfterIdat);
                    if (pal_img_n != 0) {
                        if (scan == .header) {
                            s.img_n = 4;
                            return;
                        }
                        if (pal_len == 0) return s.fail(error.TrnsBeforePlte);
                        if (length > pal_len) return s.fail(error.BadTrnsLength);
                        pal_img_n = 4;
                        for (0..length) |i| palette[i * 4 + 3] = s.get8();
                    } else {
                        if (s.img_n & 1 == 0) return s.fail(error.TrnsWithAlpha);
                        const key_length = @as(u32, @intCast(s.img_n)) * 2;
                        if (length != key_length) return s.fail(error.BadTrnsLength);
                        has_trans = true;
                        // A colour key gives the image an alpha channel.
                        if (scan == .header) {
                            s.img_n += 1;
                            return;
                        }
                        const keys: usize = @min(@as(usize, @intCast(s.img_n)), 3);
                        if (png.depth == 16) {
                            for (tc16[0..keys]) |*key| key.* = s.get16be();
                        } else {
                            // Only the low byte counts; scaled as grey
                            // samples are, in 8 bits.
                            for (tc[0..keys]) |*key| {
                                key.* = @truncate(s.get16be() & 255);
                                key.* *%= depth_scale[png.depth];
                            }
                        }
                    }
                },
                chunk_idat => {
                    if (first) return s.fail(error.FirstNotIhdr);
                    if (pal_img_n != 0 and pal_len == 0) return s.fail(error.NoPlte);
                    if (scan == .header) {
                        // The header scan stops at the first IDAT.
                        if (pal_img_n != 0) s.img_n = pal_img_n;
                        return;
                    }
                    if (length > 1 << 30) return s.fail(error.IdatSizeLimit);
                    // The original's `int` sum would turn negative.
                    const total = png.idata.items.len + length;
                    if (total > std.math.maxInt(i32)) return s.staleFailure();
                    if (length > 0) png.has_idata = true;
                    try png.readIdat(length);
                },
                chunk_iend => {
                    if (first) return s.fail(error.FirstNotIhdr);
                    if (scan != .load) return;
                    if (!png.has_idata) return s.fail(error.NoIdat);
                    try png.decode(.{
                        .req_comp = req_comp,
                        .color = color,
                        .interlace = interlace,
                        .is_iphone = is_iphone,
                        .pal_img_n = pal_img_n,
                        .has_trans = has_trans,
                        .tc = tc,
                        .tc16 = tc16,
                        .palette = &palette,
                        .palette_set = palette_set,
                    });
                    // The CRC of IEND.
                    _ = s.get32be();
                    return;
                },
                else => {
                    if (first) return s.fail(error.FirstNotIhdr);
                    // An unknown critical chunk (upper-case first letter)
                    // fails; ancillary ones are skipped.
                    if (chunk & (1 << 29) == 0) return s.fail(error.UnknownPngChunk);
                    s.skip(@as(i32, @bitCast(length)));
                },
            }
            // The chunk's CRC, not checked.
            _ = s.get32be();
        }
    }

    /// Appends an IDAT chunk's `length` bytes to `idata`. The original
    /// allocates the room before it reads; the port grows as the bytes
    /// arrive, so a chunk that claims more than the input has costs no
    /// memory.
    fn readIdat(png: *Png, length: u32) Error!void {
        const piece_max = 1 << 20;
        var left: usize = length;
        while (left > 0) {
            const n = @min(left, piece_max);
            try png.idata.ensureUnusedCapacity(png.gpa, n);
            if (!png.source.getn(png.idata.unusedCapacitySlice()[0..n])) {
                return png.source.fail(error.OutOfData);
            }
            png.idata.items.len += n;
            left -= n;
        }
    }

    const Decode = struct {
        req_comp: u3,
        color: u8,
        interlace: bool,
        is_iphone: bool,
        pal_img_n: u8,
        has_trans: bool,
        tc: [3]u8,
        tc16: [3]u16,
        palette: *const [1024]u8,
        palette_set: u32,
    };

    /// The IEND step of `stbi__parse_png_file`: inflates the IDAT data and
    /// builds the image.
    fn decode(png: *Png, d: Decode) Error!void {
        const s = png.source;
        const img_n: u32 = @intCast(s.img_n);
        // The original's guess at the inflated size, which it allocates at
        // once.
        const bpl = (@as(u64, s.img_x) * png.depth + 7) / 8;
        const raw_len = bpl * s.img_y * img_n + s.img_y;
        // Past `INT_MAX` the original's guess turns negative, and its
        // allocation fails.
        if (raw_len > std.math.maxInt(i32)) return s.staleFailure();
        const expanded = zlib.decodeGrowing(png.gpa, png.idata.items, .{
            .initial_size = @intCast(raw_len),
            .parse_header = !d.is_iphone,
        }) catch |err| switch (err) {
            error.NoReason => return s.staleFailure(),
            else => |e| return s.fail(e),
        };
        defer png.gpa.free(expanded.buffer);
        png.idata.clearAndFree(png.gpa);

        const req_comp: u32 = d.req_comp;
        if ((req_comp == img_n + 1 and req_comp != 3 and d.pal_img_n == 0) or d.has_trans) {
            s.img_out_n = @intCast(img_n + 1);
        } else {
            s.img_out_n = @intCast(img_n);
        }
        const out_n: u32 = @intCast(s.img_out_n);
        const inflated = expanded.buffer[0..expanded.len];
        png.out = try png.createImage(inflated, out_n, d.color, d.interlace);
        const out = png.out.?;
        const pixel_count = @as(usize, s.img_x) * s.img_y;
        if (d.has_trans) {
            if (png.depth == 16) {
                computeTransparency(u16, out.wideSlice(), pixel_count, d.tc16, out_n);
            } else {
                computeTransparency(u8, out.bytes, pixel_count, d.tc, out_n);
            }
        }
        if (d.is_iphone and png.options.convert_iphone_png and out_n > 2) {
            deIphone(out.bytes, pixel_count, out_n, png.options.unpremultiply);
        }
        if (d.pal_img_n != 0) {
            s.img_n = d.pal_img_n;
            s.img_out_n = d.pal_img_n;
            if (req_comp >= 3) s.img_out_n = @intCast(req_comp);
            try png.expandPalette(d.palette, d.palette_set, @intCast(s.img_out_n));
        } else if (d.has_trans) {
            s.img_n += 1;
        }
    }

    /// `stbi__create_png_image`: the image, de-interlaced if it is
    /// interlaced, with `out_n` components.
    fn createImage(
        png: *Png,
        data: []const u8,
        out_n: u32,
        color: u8,
        interlaced: bool,
    ) Error!Samples {
        const s = png.source;
        if (!interlaced) return png.createImageRaw(data, out_n, s.img_x, s.img_y, color);

        const bytes: u32 = if (png.depth == 16) 2 else 1;
        const out_bytes = out_n * bytes;
        const limits = png.options.limits;
        if (!common.sizesValid(limits, &.{ s.img_x, s.img_y, out_bytes }, 0)) {
            return s.fail(error.OutOfMemory);
        }
        const x_origin = [7]u32{ 0, 4, 0, 2, 0, 1, 0 };
        const y_origin = [7]u32{ 0, 0, 4, 0, 2, 0, 1 };
        const x_spacing = [7]u32{ 8, 8, 4, 4, 2, 2, 1 };
        const y_spacing = [7]u32{ 8, 8, 8, 4, 4, 2, 2 };
        const img_n: u64 = @intCast(s.img_n);

        // The original allocates the whole image first. The port does so
        // only when every pass has the bytes it needs; otherwise one of
        // them fails, and the image is never handed out.
        var needed: u64 = 0;
        for (0..7) |p| {
            const x = (s.img_x + x_spacing[p] - 1 - x_origin[p]) / x_spacing[p];
            const y = (s.img_y + y_spacing[p] - 1 - y_origin[p]) / y_spacing[p];
            if (x != 0 and y != 0) needed += ((((img_n * x * png.depth) + 7) >> 3) + 1) * y;
        }
        const final: ?Samples = if (needed <= data.len)
            try Samples.alloc(png.gpa, @as(usize, s.img_x) * s.img_y * out_bytes, png.depth == 16)
        else
            null;
        errdefer if (final) |image| image.free(png.gpa);

        var rest = data;
        for (0..7) |p| {
            const x = (s.img_x + x_spacing[p] - 1 - x_origin[p]) / x_spacing[p];
            const y = (s.img_y + y_spacing[p] - 1 - y_origin[p]) / y_spacing[p];
            if (x == 0 or y == 0) continue;
            const img_len: usize = @intCast(((((img_n * x * png.depth) + 7) >> 3) + 1) * y);
            const pass = try png.createImageRaw(rest, out_n, x, y, color);
            defer pass.free(png.gpa);
            if (final) |image| {
                for (0..y) |j| {
                    for (0..x) |i| {
                        const out_y = j * y_spacing[p] + y_origin[p];
                        const out_x = i * x_spacing[p] + x_origin[p];
                        const to = (out_y * s.img_x + out_x) * out_bytes;
                        const from = (j * x + i) * out_bytes;
                        @memcpy(image.bytes[to..][0..out_bytes], pass.bytes[from..][0..out_bytes]);
                    }
                }
            }
            rest = rest[img_len..];
        }
        // With too few bytes for every pass, a pass has failed above.
        return final orelse unreachable;
    }

    /// `stbi__create_png_image_raw`: unfilters `y` rows of `x` pixels from
    /// `raw` into an image of `out_n` components, adding opaque alpha when
    /// `out_n` is one more than the file's.
    fn createImageRaw(
        png: *Png,
        raw: []const u8,
        out_n: u32,
        x: u32,
        y: u32,
        color: u8,
    ) Error!Samples {
        const s = png.source;
        const limits = png.options.limits;
        const depth: u32 = png.depth;
        const bytes: u32 = if (depth == 16) 2 else 1;
        const img_n: u32 = @intCast(s.img_n);
        const output_bytes = out_n * bytes;
        const stride = @as(usize, x) * output_bytes;

        if (!common.sizesValid(limits, &.{ x, y, output_bytes }, 0)) {
            return s.fail(error.OutOfMemory);
        }
        if (!common.sizesValid(limits, &.{ img_n, x, depth }, 7)) return s.fail(error.TooLargePng);
        const img_width_bytes: usize = (@as(usize, img_n) * x * depth + 7) >> 3;
        const width_bytes: i64 = @intCast(img_width_bytes);
        if (!common.sizesValid(limits, &.{ width_bytes, y }, width_bytes)) {
            return s.fail(error.TooLargePng);
        }
        const img_len = (img_width_bytes + 1) * y;
        // More data than the image needs is accepted: some files end with
        // zeros.
        if (raw.len < img_len) return s.fail(error.NotEnoughPngPixels);

        // The original allocates the image before the checks above; the
        // port only once they pass.
        const out: Samples = try .alloc(png.gpa, stride * y, depth == 16);
        errdefer out.free(png.gpa);
        // Two rows, the current one and the one above, taking turns.
        const filter_buf = try png.gpa.alloc(u8, img_width_bytes * 2);
        defer png.gpa.free(filter_buf);

        // Below 8 bits a filter works on whole bytes.
        const filter_bytes: usize = if (depth < 8) 1 else img_n * bytes;
        const row_bytes = img_width_bytes;
        var raw_pos: usize = 0;
        for (0..y) |j| {
            const cur = filter_buf[(j & 1) * row_bytes ..][0..row_bytes];
            const prior = filter_buf[(~j & 1) * row_bytes ..][0..row_bytes];
            const dest = out.bytes[stride * j ..][0..stride];
            const filter_byte = raw[raw_pos];
            raw_pos += 1;
            if (filter_byte > 4) return s.fail(error.InvalidPngFilter);
            const filter: Filter = if (j == 0)
                first_row_filter[filter_byte]
            else
                @fromBackingInt(filter_byte);
            const in = raw[raw_pos..][0..row_bytes];
            unfilter(filter, cur, prior, in, filter_bytes);
            raw_pos += row_bytes;

            const samples = @as(usize, x) * img_n;
            switch (depth) {
                1, 2, 4 => {
                    // Grey samples are scaled to 0..255; palette indices and
                    // the samples of colour types that never come at these
                    // depths are left as they are, as in the original.
                    const scale: u8 = if (color == 0) depth_scale[depth] else 1;
                    expandBits(dest[0..samples], cur, @intCast(depth), scale);
                    if (img_n != out_n) alphaExpand8(dest, dest, x, img_n);
                },
                8 => {
                    if (img_n == out_n) {
                        @memcpy(dest[0..samples], cur[0..samples]);
                    } else {
                        alphaExpand8(dest, cur, x, img_n);
                    }
                },
                16 => expandWide(dest, cur, x, img_n, out_n),
                else => unreachable,
            }
        }
        return out;
    }

    /// `stbi__expand_png_palette`: each index replaced by its palette
    /// entry's first `pal_img_n` components.
    fn expandPalette(
        png: *Png,
        palette: *const [1024]u8,
        palette_set: u32,
        pal_img_n: u32,
    ) Error!void {
        const s = png.source;
        const pixel_count = @as(usize, s.img_x) * s.img_y;
        if (!common.sizesValid(png.options.limits, &.{ @intCast(pixel_count), pal_img_n }, 0)) {
            return s.fail(error.OutOfMemory);
        }
        const indices = png.out.?;
        const result = try png.gpa.alloc(u8, pixel_count * pal_img_n);
        errdefer png.gpa.free(result);
        for (indices.bytes[0..pixel_count], 0..) |index, i| {
            // The original reads its uninitialized stack for an entry no
            // PLTE chunk set; the port refuses the image.
            if (index >= palette_set) return s.fail(error.PngPaletteIndex);
            const entry = palette[@as(usize, index) * 4 ..][0..4];
            @memcpy(result[i * pal_img_n ..][0..pal_img_n], entry[0..pal_img_n]);
        }
        indices.free(png.gpa);
        png.out = .{ .bytes = result, .wide = false };
    }
};

/// Undoes `filter` on one row: `in` into `cur`, with `prior` the row
/// above and `filter_bytes` the distance to the byte on the left.
fn unfilter(
    filter: Filter,
    cur: []u8,
    prior: []const u8,
    in: []const u8,
    filter_bytes: usize,
) void {
    const nk = cur.len;
    switch (filter) {
        .none => @memcpy(cur, in),
        .sub => {
            @memcpy(cur[0..filter_bytes], in[0..filter_bytes]);
            for (filter_bytes..nk) |k| cur[k] = in[k] +% cur[k - filter_bytes];
        },
        .up => for (cur, in, prior) |*c, i, p| {
            c.* = i +% p;
        },
        .avg => {
            for (0..filter_bytes) |k| cur[k] = in[k] +% (prior[k] >> 1);
            for (filter_bytes..nk) |k| {
                const average: u8 = @intCast((@as(u16, prior[k]) + cur[k - filter_bytes]) >> 1);
                cur[k] = in[k] +% average;
            }
        },
        .paeth => {
            for (0..filter_bytes) |k| cur[k] = in[k] +% prior[k];
            for (filter_bytes..nk) |k| {
                cur[k] = in[k] +% paeth(cur[k - filter_bytes], prior[k], prior[k - filter_bytes]);
            }
        },
        .avg_first => {
            @memcpy(cur[0..filter_bytes], in[0..filter_bytes]);
            for (filter_bytes..nk) |k| cur[k] = in[k] +% (cur[k - filter_bytes] >> 1);
        },
    }
}

/// `stbi__paeth`: the Paeth predictor in the original's branch-free form,
/// which equals the PNG specification's.
fn paeth(a: u8, b: u8, c: u8) u8 {
    const thresh = @as(i32, c) * 3 - (@as(i32, a) + b);
    const lo: i32 = @min(a, b);
    const hi: i32 = @max(a, b);
    const t0: i32 = if (hi <= thresh) lo else c;
    const t1 = if (thresh <= lo) hi else t0;
    return @intCast(t1);
}

/// Unpacks samples of `depth` bits, high bits first, one per byte of
/// `dest`, times `scale`.
fn expandBits(dest: []u8, packed_bytes: []const u8, depth: u3, scale: u8) void {
    const per_byte = 8 / @as(usize, depth);
    const shift: u3 = @intCast(8 - @as(u4, depth));
    var inb: u8 = 0;
    var in_pos: usize = 0;
    for (dest, 0..) |*out, i| {
        if (i % per_byte == 0) {
            inb = packed_bytes[in_pos];
            in_pos += 1;
        }
        out.* = scale *% (inb >> shift);
        inb <<= depth;
    }
}

/// `stbi__create_png_alpha_expand8`: `x` pixels of 1 or 3 components from
/// `src` to `dest` with an opaque alpha added. Works backwards, so `dest`
/// may be `src`.
fn alphaExpand8(dest: []u8, src: []const u8, x: u32, img_n: u32) void {
    var i: usize = x;
    if (img_n == 1) {
        while (i > 0) {
            i -= 1;
            dest[i * 2 + 1] = 255;
            dest[i * 2 + 0] = src[i];
        }
    } else {
        while (i > 0) {
            i -= 1;
            dest[i * 4 + 3] = 255;
            dest[i * 4 + 2] = src[i * 3 + 2];
            dest[i * 4 + 1] = src[i * 3 + 1];
            dest[i * 4 + 0] = src[i * 3 + 0];
        }
    }
}

/// 16-bit samples from big-endian bytes to the machine's order, with an
/// opaque alpha added when `out_n` is one more than `img_n`.
fn expandWide(dest: []u8, cur: []const u8, x: u32, img_n: u32, out_n: u32) void {
    const pixels: usize = x;
    for (0..pixels) |i| {
        for (0..img_n) |k| {
            const at = i * img_n + k;
            const sample = std.mem.readInt(u16, cur[at * 2 ..][0..2], .big);
            std.mem.writeInt(u16, dest[(i * out_n + k) * 2 ..][0..2], sample, .native);
        }
        if (out_n != img_n) {
            std.mem.writeInt(u16, dest[(i * out_n + img_n) * 2 ..][0..2], 0xffff, .native);
        }
    }
}

/// `stbi__compute_transparency` and `…16`: alpha 0 where a pixel matches
/// the colour key, in an image whose alpha is opaque so far.
fn computeTransparency(comptime T: type, out: []T, pixel_count: usize, tc: [3]T, out_n: u32) void {
    if (out_n == 2) {
        for (0..pixel_count) |i| {
            const p = out[i * 2 ..][0..2];
            p[1] = if (p[0] == tc[0]) 0 else std.math.maxInt(T);
        }
    } else {
        for (0..pixel_count) |i| {
            const p = out[i * 4 ..][0..4];
            if (p[0] == tc[0] and p[1] == tc[1] and p[2] == tc[2]) p[3] = 0;
        }
    }
}

/// `stbi__de_iphone`: BGR(A) to RGB(A), and with `unpremultiply`, alpha
/// divided out. Works on bytes, also for 16-bit images, as the original:
/// there it changes the first `pixel_count * out_n` bytes.
fn deIphone(out: []u8, pixel_count: usize, out_n: u32, unpremultiply: bool) void {
    if (out_n == 3) {
        for (0..pixel_count) |i| {
            const p = out[i * 3 ..][0..3];
            std.mem.swap(u8, &p[0], &p[2]);
        }
    } else if (unpremultiply) {
        for (0..pixel_count) |i| {
            const p = out[i * 4 ..][0..4];
            const a: u32 = p[3];
            const t: u32 = p[0];
            if (a != 0) {
                const half = a / 2;
                // A colour above its alpha wraps, as in the original.
                p[0] = @truncate((@as(u32, p[2]) * 255 + half) / a);
                p[1] = @truncate((@as(u32, p[1]) * 255 + half) / a);
                p[2] = @truncate((t * 255 + half) / a);
            } else {
                std.mem.swap(u8, &p[0], &p[2]);
            }
        }
    } else {
        for (0..pixel_count) |i| {
            const p = out[i * 4 ..][0..4];
            std.mem.swap(u8, &p[0], &p[2]);
        }
    }
}
