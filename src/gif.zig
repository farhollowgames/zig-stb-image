//! GIF, as stb_image's `stbi__gif_*` read it: the first frame for the
//! image loads, and every frame, each composited onto the ones before it,
//! for `loadAnimation`. Frames are RGBA.

const std = @import("std");
const common = @import("common.zig");

const Source = common.Source;
const Error = common.Error;

/// An LZW code: the code before it in the string (-1 for none), and the
/// first and last byte of its string.
const Code = struct {
    prefix: i16,
    first: u8,
    suffix: u8,
};

/// The most LZW codes a raster may define, as stb_image allows them.
const code_limit = 8192;

/// The logical screen of the header.
const Screen = struct {
    width: u32,
    height: u32,
    flags: u8,
    background_index: u8,
};

/// `stbi__gif`: the decoder's state across frames.
const Gif = struct {
    w: u32 = 0,
    h: u32 = 0,
    /// Whether the header has been read and the canvas made.
    started: bool = false,
    /// The canvas, RGBA.
    out: []u8 = &.{},
    /// The canvas as it was before the current frame was drawn.
    background: []u8 = &.{},
    /// Which pixels the current frame drew.
    history: []u8 = &.{},
    flags: u8 = 0,
    background_index: u8 = 0,
    /// The palette index the graphic control extension made transparent.
    transparent: i32 = 0,
    eflags: u8 = 0,
    /// The palettes, each entry blue, green, red, alpha.
    pal: [256][4]u8 = @splat(@splat(0)),
    lpal: [256][4]u8 = @splat(@splat(0)),
    local_table: bool = false,
    codes: [code_limit]Code = @splat(.{ .prefix = 0, .first = 0, .suffix = 0 }),
    // The frame's rectangle and the position of the next pixel, as byte
    // offsets into `out`; `step` is the distance between rows of the current
    // interlace pass and `parse` the passes left after it.
    parse: i64 = 0,
    step: i64 = 0,
    lflags: u8 = 0,
    start_x: i64 = 0,
    start_y: i64 = 0,
    max_x: i64 = 0,
    max_y: i64 = 0,
    cur_x: i64 = 0,
    cur_y: i64 = 0,
    line_size: i64 = 0,
    /// The delay of the last graphic control extension, in milliseconds.
    delay: i32 = 0,

    fn deinit(g: *Gif, gpa: std.mem.Allocator) void {
        gpa.free(g.out);
        gpa.free(g.background);
        gpa.free(g.history);
        g.out = &.{};
        g.background = &.{};
        g.history = &.{};
    }

    fn colorTable(g: *const Gif) *const [256][4]u8 {
        return if (g.local_table) &g.lpal else &g.pal;
    }
};

/// `stbi__gif_test`: the file starts with `GIF87a` or `GIF89a`.
pub fn detect(source: *Source) bool {
    const found = testRaw(source);
    source.rewind();
    return found;
}

fn testRaw(source: *Source) bool {
    if (source.get8() != 'G' or source.get8() != 'I' or source.get8() != 'F' or
        source.get8() != '8') return false;
    const version = source.get8();
    if (version != '9' and version != '7') return false;
    return source.get8() == 'a';
}

/// `stbi__gif_header` up to the global colour table. After the signature
/// the original sets its failure reason to the empty string, which a later
/// failure without a reason of its own reports.
fn readScreen(source: *Source, limits: common.Limits) Error!Screen {
    if (source.get8() != 'G' or source.get8() != 'I' or source.get8() != 'F' or
        source.get8() != '8') return source.fail(error.NotGif);
    const version = source.get8();
    if (version != '7' and version != '9') return source.fail(error.NotGif);
    if (source.get8() != 'a') return source.fail(error.NotGif);

    source.reason = error.EmptyReason;
    const screen: Screen = .{
        .width = source.get16le(),
        .height = source.get16le(),
        .flags = source.get8(),
        .background_index = source.get8(),
    };
    _ = source.get8(); // the pixel aspect ratio
    if (screen.width > limits.dimension_max) return source.fail(error.DimensionTooLarge);
    if (screen.height > limits.dimension_max) return source.fail(error.DimensionTooLarge);
    return screen;
}

fn parseColorTable(source: *Source, pal: *[256][4]u8, entries: u32, transparent: i32) void {
    for (pal[0..entries], 0..) |*entry, i| {
        entry[2] = source.get8();
        entry[1] = source.get8();
        entry[0] = source.get8();
        entry[3] = if (transparent == i) 0 else 255;
    }
}

/// `stbi__gif_info`: the screen's size, and 4 components.
pub fn info(source: *Source) ?common.Info {
    const screen = readScreen(source, .{}) catch {
        source.rewind();
        return null;
    };
    return .{ .width = screen.width, .height = screen.height, .channels_in_file = 4 };
}

/// `stbi__out_gif_code`: the string of `code` at the next pixels, in
/// order; the original recurses through the prefixes, the port walks them
/// into a buffer first.
fn outputCode(source: *Source, g: *Gif, code: u16) Error!void {
    // A code's prefix is always a lower code, so a string has at most
    // `code_limit` bytes.
    var string: [code_limit]u8 = undefined;
    var len: usize = 0;
    var at: i32 = code;
    while (true) {
        const entry = g.codes[@intCast(at)];
        string[len] = entry.suffix;
        len += 1;
        if (entry.prefix < 0) break;
        at = entry.prefix;
    }
    while (len > 0) {
        len -= 1;
        if (g.cur_y >= g.max_y) return;
        try outputPixel(source, g, string[len]);
    }
}

fn outputPixel(source: *Source, g: *Gif, index: u8) Error!void {
    const at: usize = @intCast(g.cur_x + g.cur_y);
    g.history[at / 4] = 1;
    const color = g.colorTable()[index];
    // Transparent pixels leave the canvas as it is.
    if (color[3] > 128) g.out[at..][0..4].* = .{ color[2], color[1], color[0], color[3] };
    g.cur_x += 4;
    if (g.cur_x >= g.max_x) {
        g.cur_x = g.start_x;
        // The original adds in `int`; past its range it is undefined.
        if (g.cur_y + g.step > std.math.maxInt(i32)) return source.fail(error.TooLargeGif);
        g.cur_y += g.step;
        while (g.cur_y >= g.max_y and g.parse > 0) {
            g.step = (@as(i64, 1) << @intCast(g.parse)) * g.line_size;
            g.cur_y = g.start_y + (g.step >> 1);
            g.parse -= 1;
        }
    }
}

/// `stbi__process_gif_raster`: the LZW data of one frame onto the canvas.
fn processRaster(source: *Source, g: *Gif) Error!void {
    const lzw_cs = source.get8();
    if (lzw_cs > 12) return source.staleFailure();
    const clear: u32 = @as(u32, 1) << @intCast(lzw_cs);
    var first = true;
    var codesize: u5 = @intCast(lzw_cs + 1);
    var codemask: u32 = (@as(u32, 1) << codesize) - 1;
    var bits: u32 = 0;
    var valid_bits: u5 = 0;
    for (g.codes[0..clear], 0..) |*entry, i| {
        entry.* = .{ .prefix = -1, .first = @truncate(i), .suffix = @truncate(i) };
    }

    var avail: u32 = clear + 2;
    var oldcode: i32 = -1;
    var len: u32 = 0;
    while (true) {
        if (valid_bits < codesize) {
            if (len == 0) {
                // A new sub-block; an empty one ends the raster.
                len = source.get8();
                if (len == 0) return;
            }
            len -= 1;
            bits |= @as(u32, source.get8()) << valid_bits;
            valid_bits += 8;
            continue;
        }
        const code = bits & codemask;
        bits >>= codesize;
        valid_bits -= codesize;
        if (code == clear) {
            codesize = @intCast(lzw_cs + 1);
            codemask = (@as(u32, 1) << codesize) - 1;
            avail = clear + 2;
            oldcode = -1;
            first = false;
        } else if (code == clear + 1) {
            // The end code: skip the rest of the data sub-blocks.
            source.skip(len);
            while (true) {
                const block = source.get8();
                if (block == 0) break;
                source.skip(block);
            }
            return;
        } else if (code <= avail) {
            if (first) return source.fail(error.NoGifClearCode);
            if (oldcode >= 0) {
                const new = avail;
                avail += 1;
                if (avail > code_limit) return source.fail(error.TooManyGifCodes);
                const entry = &g.codes[new];
                entry.prefix = @intCast(oldcode);
                entry.first = g.codes[@intCast(oldcode)].first;
                entry.suffix = if (code == avail) entry.first else g.codes[code].first;
            } else if (code == avail) {
                return source.fail(error.IllegalGifCode);
            }
            try outputCode(source, g, @intCast(code));
            if (avail & codemask == 0 and avail <= 0x0fff) {
                codesize += 1;
                codemask = (@as(u32, 1) << codesize) - 1;
            }
            oldcode = @intCast(code);
        } else {
            return source.fail(error.IllegalGifCode);
        }
    }
}

/// `stbi__gif_load_next`: the next frame onto the canvas `g.out`, or false
/// at the end of the stream. `two_back` says whether the original has the
/// frame before the last to restore from, which it has from the third frame
/// on.
fn loadNext(
    gpa: std.mem.Allocator,
    source: *Source,
    g: *Gif,
    two_back: bool,
    limits: common.Limits,
) Error!bool {
    var first_frame = false;
    if (!g.started) {
        const screen = try readScreen(source, limits);
        g.w = screen.width;
        g.h = screen.height;
        g.flags = screen.flags;
        g.background_index = screen.background_index;
        g.transparent = -1;
        if (g.flags & 0x80 != 0) {
            parseColorTable(source, &g.pal, @as(u32, 2) << @intCast(g.flags & 7), -1);
        }
        if (!common.sizesValid(limits, &.{ 4, g.w, g.h }, 0)) return source.fail(error.TooLargeGif);
        const pcount = @as(usize, g.w) * g.h;
        g.out = try gpa.alloc(u8, 4 * pcount);
        g.background = try gpa.alloc(u8, 4 * pcount);
        g.history = try gpa.alloc(u8, pcount);
        g.started = true;
        // Nothing drawn yet shows the background, transparent at first.
        @memset(g.out, 0);
        @memset(g.background, 0);
        first_frame = true;
    } else {
        // Dispose of the previous frame as its graphic control extension
        // says.
        var dispose = (g.eflags & 0x1c) >> 2;
        if (dispose == 3 and !two_back) dispose = 2;
        if (dispose == 3) {
            // Restore to the frame before: the original's pointer to it
            // lies two frames before the start of its buffer, and it reads
            // there for every pixel the last frame drew.
            if (std.mem.indexOfScalar(u8, g.history, 1) != null) {
                return source.fail(error.GifDisposeToPrevious);
            }
        } else if (dispose == 2) {
            // Restore what the last frame drew to the canvas before it.
            for (g.history, 0..) |drawn, i| {
                if (drawn != 0) g.out[i * 4 ..][0..4].* = g.background[i * 4 ..][0..4].*;
            }
        }
        @memcpy(g.background, g.out);
    }
    @memset(g.history, 0);

    while (true) {
        switch (source.get8()) {
            0x2c => {
                // The image descriptor.
                const x: u32 = source.get16le();
                const y: u32 = source.get16le();
                const w: u32 = source.get16le();
                const h: u32 = source.get16le();
                if (x + w > g.w or y + h > g.h) return source.fail(error.BadGifImageDescriptor);

                g.line_size = @as(i64, g.w) * 4;
                g.start_x = @as(i64, x) * 4;
                g.start_y = @as(i64, y) * g.line_size;
                g.max_x = g.start_x + @as(i64, w) * 4;
                g.max_y = g.start_y + @as(i64, h) * g.line_size;
                g.cur_x = g.start_x;
                g.cur_y = g.start_y;
                // A frame of no width draws no pixels.
                if (w == 0) g.cur_y = g.max_y;

                g.lflags = source.get8();
                if (g.lflags & 0x40 != 0) {
                    // Interlaced: every eighth row first.
                    g.step = 8 * g.line_size;
                    g.parse = 3;
                } else {
                    g.step = g.line_size;
                    g.parse = 0;
                }

                if (g.lflags & 0x80 != 0) {
                    const transparent = if (g.eflags & 0x01 != 0) g.transparent else -1;
                    parseColorTable(
                        source,
                        &g.lpal,
                        @as(u32, 2) << @intCast(g.lflags & 7),
                        transparent,
                    );
                    g.local_table = true;
                } else if (g.flags & 0x80 != 0) {
                    g.local_table = false;
                } else {
                    return source.fail(error.MissingGifColorTable);
                }

                try processRaster(source, g);

                if (first_frame and g.background_index > 0) {
                    // On the first frame, the pixels not drawn get the
                    // background colour, opaque, in the palette's order.
                    for (g.history, 0..) |drawn, i| {
                        if (drawn == 0) {
                            g.pal[g.background_index][3] = 255;
                            g.out[i * 4 ..][0..4].* = g.pal[g.background_index];
                        }
                    }
                }
                return true;
            },
            0x21 => {
                // An extension: only the graphic control extension matters.
                const ext = source.get8();
                if (ext == 0xf9) {
                    const len = source.get8();
                    if (len == 4) {
                        g.eflags = source.get8();
                        // In hundredths of a second, kept as thousandths.
                        g.delay = 10 * @as(i32, source.get16le());
                        if (g.transparent >= 0) g.pal[@intCast(g.transparent)][3] = 255;
                        if (g.eflags & 0x01 != 0) {
                            g.transparent = source.get8();
                            g.pal[@intCast(g.transparent)][3] = 0;
                        } else {
                            source.skip(1);
                            g.transparent = -1;
                        }
                    } else {
                        // The original skips the block and reads its
                        // sub-blocks as the next tags.
                        source.skip(len);
                        continue;
                    }
                }
                while (true) {
                    const len = source.get8();
                    if (len == 0) break;
                    source.skip(len);
                }
            },
            // The trailer.
            0x3b => return false,
            else => return source.fail(error.UnknownGifCode),
        }
    }
}

/// `stbi__gif_load`: the first frame, converted to `req_comp` components.
pub fn load(
    gpa: std.mem.Allocator,
    source: *Source,
    request: common.Request,
) Error!common.Decoded {
    const limits = request.options.limits;
    var g: Gif = .{};
    defer g.deinit(gpa);
    // A GIF of no frames fails without a reason of its own.
    if (!try loadNext(gpa, source, &g, false, limits)) return source.staleFailure();
    var pixels = g.out;
    g.out = &.{};
    if (request.req_comp != 0 and request.req_comp != 4) {
        pixels = try common.convertFormat(gpa, limits, pixels, 4, request.req_comp, g.w, g.h);
    }
    return .{
        .pixels = .{ .u8 = pixels },
        .width = g.w,
        .height = g.h,
        .channels_in_file = 4,
    };
}

/// `stbi__load_gif_main`: every frame, each the whole canvas, and each
/// frame's delay in milliseconds. A frame that fails after the first ends
/// the animation, as in the original, unless the original is unsafe there.
pub fn loadAnimation(
    gpa: std.mem.Allocator,
    source: *Source,
    options: *const common.Options,
) Error!common.Animation {
    if (!detect(source)) return source.fail(error.NotGifAnimation);
    const limits = options.limits;
    var g: Gif = .{};
    defer g.deinit(gpa);
    var frames: std.ArrayList(u8) = .empty;
    defer frames.deinit(gpa);
    var delays: std.ArrayList(i32) = .empty;
    defer delays.deinit(gpa);

    var layers: u32 = 0;
    while (true) {
        const more = loadNext(gpa, source, &g, layers >= 2, limits) catch |err| switch (err) {
            error.OutOfMemory, error.GifDisposeToPrevious, error.TooLargeGif => return err,
            else => if (layers == 0) return err else break,
        };
        if (!more) break;
        layers += 1;
        if (layers >= 2 and g.out.len == 0) {
            // The original reallocates its frames to no bytes, which frees
            // them, and then frees them again.
            return source.fail(error.GifZeroAreaFrames);
        }
        // The original sizes its buffer in `int`.
        if (!common.sizesValid(limits, &.{ layers, @intCast(g.out.len) }, 0)) {
            return error.OutOfMemory;
        }
        try frames.appendSlice(gpa, g.out);
        try delays.append(gpa, g.delay);
    }
    // No frames: the original fails without a reason of its own.
    if (layers == 0) return source.staleFailure();

    var pixels = try frames.toOwnedSlice(gpa);
    const req_comp = options.reqComp();
    if (req_comp != 0 and req_comp != 4) {
        pixels = try common.convertFormat(gpa, limits, pixels, 4, req_comp, layers * g.w, g.h);
    }
    errdefer gpa.free(pixels);
    return .{
        .pixels = pixels,
        .delays_ms = try delays.toOwnedSlice(gpa),
        .width = g.w,
        .height = g.h,
        .frames = layers,
        .channels = if (req_comp == 0) 4 else req_comp,
    };
}
