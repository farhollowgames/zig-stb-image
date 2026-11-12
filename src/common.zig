//! What every decoder shares: the byte source it reads, the options of a
//! load, the size checks and the generic component conversion.

const std = @import("std");
const errors = @import("errors.zig");

pub const Error = errors.Error;

/// The limits a load works within. The defaults are stb_image's own: no
/// side longer than `STBI_MAX_DIMENSIONS`, and no buffer whose size, counted
/// as stb_image counts it, passes the largest `int`.
pub const Limits = struct {
    /// The longest side, in pixels, a decoder accepts.
    dimension_max: u32 = 1 << 24,
    /// The largest buffer, in bytes, wherever stb_image checks a size against
    /// `INT_MAX` before it allocates.
    bytes_max: u64 = std.math.maxInt(i32),
};

/// The components of a decoded pixel. `file` keeps the count the file has.
pub const Components = enum(u3) {
    file = 0,
    grey = 1,
    grey_alpha = 2,
    rgb = 3,
    rgba = 4,
};

/// How one load runs. The defaults are stb_image's defaults; `Options.current`
/// reads the settings made through `settings` instead, as stb_image does.
pub const Options = struct {
    /// The components in the result.
    components: Components = .file,
    /// Put the last row first, for APIs that start at the bottom.
    flip_vertically: bool = false,
    /// Undo premultiplied alpha in iPhone PNGs, when they are also converted.
    unpremultiply: bool = false,
    /// Turn the BGR(A) of iPhone PNGs (CgBI) back into RGB(A).
    convert_iphone_png: bool = false,
    /// HDR images loaded as 8 or 16 bits: `(value * (1 / scale)) ^ (1 / gamma)`.
    hdr_to_ldr_gamma: f32 = 2.2,
    hdr_to_ldr_scale: f32 = 1.0,
    /// 8-bit images loaded as floats: `(value / 255) ^ gamma * scale`.
    ldr_to_hdr_gamma: f32 = 2.2,
    ldr_to_hdr_scale: f32 = 1.0,
    limits: Limits = .{},

    /// The number of components asked for, 0 for the file's.
    pub fn reqComp(options: *const Options) u3 {
        return @backingInt(options.components);
    }
};

/// The pixels a decoder hands back, at the bit depth it decoded.
pub const Pixels = union(enum) {
    u8: []u8,
    u16: []u16,
    f32: []f32,

    pub fn free(pixels: Pixels, gpa: std.mem.Allocator) void {
        switch (pixels) {
            inline else => |slice| gpa.free(slice),
        }
    }
};

/// A decoder's result: `pixels` holds `width * height` pixels of the
/// requested components, or of `channels_in_file` when none were requested.
pub const Decoded = struct {
    pixels: Pixels,
    width: u32,
    height: u32,
    channels_in_file: u8,
};

/// The frames of a GIF, as `stbi_load_gif_from_memory` gives them:
/// `frames` images of `width * height * channels` bytes, one after another,
/// and each frame's delay in milliseconds.
pub const Animation = struct {
    pixels: []u8,
    delays_ms: []i32,
    width: u32,
    height: u32,
    frames: u32,
    channels: u8,

    pub fn deinit(animation: *Animation, gpa: std.mem.Allocator) void {
        gpa.free(animation.pixels);
        gpa.free(animation.delays_ms);
        animation.* = undefined;
    }
};

/// What the info functions report.
pub const Info = struct {
    width: u32,
    height: u32,
    channels_in_file: u8,
};

/// A decoder's call: the requested components, the bit depth the caller
/// wants (only PSD reads it), and the load's options.
pub const Request = struct {
    req_comp: u3,
    bits_per_channel: u8,
    options: *const Options,
};

/// The bytes a decoder reads, from memory or through a reader, as
/// stb_image's `stbi__context`. Reads past the end give zeros. A source made
/// with `initReader` reads through its own 128-byte buffer, as stb_image's
/// callbacks do, and must stay where `initReader` put it: `base` points into
/// it.
pub const Source = struct {
    img_x: u32 = 0,
    img_y: u32 = 0,
    img_n: i32 = 0,
    img_out_n: i32 = 0,

    reader: ?*std.Io.Reader = null,
    /// Whether more bytes may come from the reader; cleared at its end.
    read_from_callbacks: bool = false,
    /// The reader's end-of-file flag, as `feof` sets it: by a read that came
    /// up short, and anew after each skip.
    reader_eof: bool = false,
    /// A read failed; the load reports `error.ReadFailed`.
    read_failed: bool = false,
    buffer_start: [128]u8 = undefined,
    /// Bytes taken from the reader before the current buffer.
    callback_already_read: usize = 0,
    /// Bytes skips asked for past the reader's end. A `FILE` seeks past
    /// its end there, so `loadFromFile` does too.
    skipped_past_end: u64 = 0,

    base: [*]const u8 = undefined,
    pos: usize = 0,
    end: usize = 0,
    original_end: usize = 0,

    /// The failure stb_image would report now, kept as it keeps
    /// `stbi__g_failure_reason`: set by every failure, also by the format
    /// tests, so a decoder that fails without a reason of its own reports
    /// the one before it.
    reason: ?Error = null,

    pub fn initMemory(bytes: []const u8) Source {
        return .{
            .base = bytes.ptr,
            .end = bytes.len,
            .original_end = bytes.len,
        };
    }

    /// Starts `source` on `reader`, reading its first buffer. `source` must
    /// not move afterwards.
    pub fn initReader(source: *Source, reader: *std.Io.Reader) void {
        source.* = .{ .reader = reader, .read_from_callbacks = true };
        source.base = &source.buffer_start;
        source.refill();
        source.original_end = source.end;
    }

    /// Records `err` as the reason of the failure and returns it.
    pub fn fail(source: *Source, err: Error) Error {
        source.reason = err;
        return err;
    }

    /// The failure to report where stb_image fails without setting a reason
    /// of its own: the last reason set, if any.
    pub fn staleFailure(source: *const Source) Error {
        return source.reason orelse error.NoReason;
    }

    /// Back to the start of the first buffer, which is all the format tests
    /// ever read.
    pub fn rewind(source: *Source) void {
        source.pos = 0;
        source.end = source.original_end;
    }

    /// The bytes read so far: from memory, the offset; from a reader, also
    /// the buffers before this one.
    pub fn bytesRead(source: *const Source) usize {
        return source.callback_already_read + source.pos;
    }

    fn readerRead(source: *Source, buffer: []u8) usize {
        const count = source.reader.?.readSliceShort(buffer) catch blk: {
            source.read_failed = true;
            break :blk 0;
        };
        if (count < buffer.len) source.reader_eof = true;
        return count;
    }

    fn refill(source: *Source) void {
        const n = source.readerRead(&source.buffer_start);
        source.callback_already_read += source.pos;
        if (n == 0) {
            // At the end, read as from memory: one zero byte, so the buffer
            // stays valid for a zero-length input.
            source.read_from_callbacks = false;
            source.pos = 0;
            source.end = 1;
            source.buffer_start[0] = 0;
        } else {
            source.pos = 0;
            source.end = n;
        }
    }

    pub inline fn get8(source: *Source) u8 {
        if (source.pos < source.end) {
            const byte = source.base[source.pos];
            source.pos += 1;
            return byte;
        }
        if (source.read_from_callbacks) {
            source.refill();
            const byte = source.base[source.pos];
            source.pos += 1;
            return byte;
        }
        return 0;
    }

    pub fn atEof(source: *const Source) bool {
        if (source.reader != null) {
            if (!source.reader_eof) return false;
            // The reader is at its end; only the zero byte of the last
            // refill may be left.
            if (!source.read_from_callbacks) return true;
        }
        return source.pos >= source.end;
    }

    pub fn skip(source: *Source, n: i64) void {
        if (n == 0) return;
        if (n < 0) {
            source.pos = source.end;
            return;
        }
        const count: u64 = @intCast(n);
        if (source.reader) |reader| {
            const buffered = source.end - source.pos;
            if (buffered < count) {
                source.pos = source.end;
                const rest = count - buffered;
                const wanted = std.math.cast(usize, rest) orelse std.math.maxInt(usize);
                const discarded = reader.discardShort(wanted) catch blk: {
                    source.read_failed = true;
                    break :blk 0;
                };
                source.skipped_past_end +|= rest - discarded;
                source.reader_eof = if (reader.peekByte()) |_| false else |_| true;
                return;
            }
        }
        // From memory a skip may pass the end; reads there give zeros.
        source.pos +|= std.math.cast(usize, count) orelse std.math.maxInt(usize);
    }

    /// Fills `buffer`, or reports false when the input ends first.
    pub fn getn(source: *Source, buffer: []u8) bool {
        if (source.reader != null) {
            const buffered = source.end - source.pos;
            if (buffered < buffer.len) {
                @memcpy(buffer[0..buffered], source.base[source.pos..source.end]);
                const count = source.readerRead(buffer[buffered..]);
                source.pos = source.end;
                return count == buffer.len - buffered;
            }
        }
        if (source.pos <= source.end and buffer.len <= source.end - source.pos) {
            @memcpy(buffer, source.base[source.pos..][0..buffer.len]);
            source.pos += buffer.len;
            return true;
        }
        return false;
    }

    /// The next `len` bytes, when all of them are in the buffer, read as
    /// `len` calls of `get8` would read them; null otherwise, reading
    /// nothing. Lets a decoder work on whole rows where the input allows.
    pub inline fn takeBuffered(source: *Source, len: usize) ?[]const u8 {
        // After a skip from memory, `pos` may be past `end`.
        if (source.pos > source.end or source.end - source.pos < len) return null;
        const bytes = source.base[source.pos..][0..len];
        source.pos += len;
        return bytes;
    }

    pub fn get16be(source: *Source) u16 {
        const high: u16 = source.get8();
        return (high << 8) | source.get8();
    }

    pub fn get32be(source: *Source) u32 {
        const high: u32 = source.get16be();
        return (high << 16) | source.get16be();
    }

    pub fn get16le(source: *Source) u16 {
        const low: u16 = source.get8();
        return low | (@as(u16, source.get8()) << 8);
    }

    pub fn get32le(source: *Source) u32 {
        const low: u32 = source.get16le();
        return low | (@as(u32, source.get16le()) << 16);
    }
};

/// `a * b * ... + add` as stb_image's `stbi__mad*sizes_valid` checks it: no
/// term negative, and every partial product and the sum at most
/// `limits.bytes_max`. The terms are the C code's `int`s; a value past
/// `INT_MAX` there was negative, so here it is past the default limit.
pub fn sizesValid(limits: Limits, factors: []const i64, add: i64) bool {
    if (add < 0) return false;
    var product: u64 = 1;
    for (factors) |factor| {
        if (factor < 0) return false;
        const f: u64 = @intCast(factor);
        if (f > limits.bytes_max) return false;
        if (f != 0 and product > limits.bytes_max / f) return false;
        product *= f;
    }
    const extra: u64 = @intCast(add);
    return extra <= limits.bytes_max and product <= limits.bytes_max - extra;
}

/// Allocates `a * b * ... + add` items of `T` after the size check of
/// `stbi__malloc_mad*`; a failed check is an out-of-memory error, as there.
pub fn allocChecked(
    comptime T: type,
    gpa: std.mem.Allocator,
    limits: Limits,
    factors: []const i64,
    add: i64,
) Error![]T {
    if (!sizesValid(limits, factors, add)) return error.OutOfMemory;
    var len: usize = @intCast(add);
    var product: usize = 1;
    for (factors) |factor| product *= @intCast(factor);
    len += product;
    return gpa.alloc(T, len);
}

pub fn computeY(r: u32, g: u32, b: u32) u8 {
    return @truncate((r * 77 + g * 150 + 29 * b) >> 8);
}

pub fn computeY16(r: u32, g: u32, b: u32) u16 {
    return @truncate((r * 77 + g * 150 + 29 * b) >> 8);
}

/// `stbi__convert_format`: `data`, `x * y` pixels of `img_n` components,
/// converted to `req_comp` components. Takes `data`, and frees it.
pub fn convertFormat(
    gpa: std.mem.Allocator,
    limits: Limits,
    data: []u8,
    img_n: u3,
    req_comp: u3,
    x: u32,
    y: u32,
) Error![]u8 {
    if (req_comp == img_n) return data;
    defer gpa.free(data);
    const good = try allocChecked(u8, gpa, limits, &.{ req_comp, x, y }, 0);
    convertRows(u8, 255, computeY, data, good, img_n, req_comp, x, y);
    return good;
}

/// `stbi__convert_format16`, as `convertFormat` for 16-bit samples. The
/// original allocates without a size check.
pub fn convertFormat16(
    gpa: std.mem.Allocator,
    data: []u16,
    img_n: u3,
    req_comp: u3,
    x: u32,
    y: u32,
) Error![]u16 {
    if (req_comp == img_n) return data;
    defer gpa.free(data);
    const good = try gpa.alloc(u16, @as(usize, req_comp) * x * y);
    convertRows(u16, 0xffff, computeY16, data, good, img_n, req_comp, x, y);
    return good;
}

fn convertRows(
    comptime T: type,
    comptime opaque_alpha: T,
    comptime luma: fn (u32, u32, u32) T,
    data: []const T,
    good: []T,
    img_n: u3,
    req_comp: u3,
    x: u32,
    y: u32,
) void {
    const pixels = @as(usize, x) * y;
    switch (@as(u8, img_n) * 8 + req_comp) {
        inline 1 * 8 + 2,
        1 * 8 + 3,
        1 * 8 + 4,
        2 * 8 + 1,
        2 * 8 + 3,
        2 * 8 + 4,
        3 * 8 + 4,
        3 * 8 + 1,
        3 * 8 + 2,
        4 * 8 + 1,
        4 * 8 + 2,
        4 * 8 + 3,
        => |combo| {
            const a = combo / 8;
            const b = combo % 8;
            for (0..pixels) |i| {
                const src = data[i * a ..][0..a];
                const dest = good[i * b ..][0..b];
                switch (combo) {
                    1 * 8 + 2 => {
                        dest[0] = src[0];
                        dest[1] = opaque_alpha;
                    },
                    1 * 8 + 3 => dest.* = .{ src[0], src[0], src[0] },
                    1 * 8 + 4 => dest.* = .{ src[0], src[0], src[0], opaque_alpha },
                    2 * 8 + 1 => dest[0] = src[0],
                    2 * 8 + 3 => dest.* = .{ src[0], src[0], src[0] },
                    2 * 8 + 4 => dest.* = .{ src[0], src[0], src[0], src[1] },
                    3 * 8 + 4 => dest.* = .{ src[0], src[1], src[2], opaque_alpha },
                    3 * 8 + 1 => dest[0] = luma(src[0], src[1], src[2]),
                    3 * 8 + 2 => dest.* = .{ luma(src[0], src[1], src[2]), opaque_alpha },
                    4 * 8 + 1 => dest[0] = luma(src[0], src[1], src[2]),
                    4 * 8 + 2 => dest.* = .{ luma(src[0], src[1], src[2]), src[3] },
                    4 * 8 + 3 => dest.* = .{ src[0], src[1], src[2] },
                    else => comptime unreachable,
                }
            }
        },
        // The decoders only ask for conversions between 1 to 4 components.
        else => unreachable,
    }
}
