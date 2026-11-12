//! `zig build bench`: zig-stb-image against the original, one feature per
//! row, on one thread.
//!
//! The inputs are made at start-up from one photograph (jpeg-decoder's
//! `mjpeg.png`, 960 x 720, RGB): written by stb_image_write where it has the
//! format (PNG, JPEG, BMP, TGA, HDR), and by small writers below where it
//! does not (16-bit, interlaced and paletted PNG, PSD, PNM, a zlib stream);
//! the progressive and YCCK JPEGs and the GIF are test-corpus files. The
//! original comes from `reference/`, built at -O3 for the same CPU as the
//! Zig, which is ReleaseFast, with its SIMD paths on; the JPEG rows also time
//! it with them off. Both sides allocate with the C allocator. Each sample
//! times enough decodes to last at least `sample_ns_min` of the benchmark
//! thread's CPU time, after warm-up samples, and the sides' samples
//! alternate so both see the same load. Every decode's output is kept
//! behind a compiler barrier, and the two sides' outputs are compared: a row
//! whose bytes differ says so.
//!
//!   zig build bench [-- --samples N --rounds N --filter TEXT]
//!
//! `--rounds` runs every row that many times, spread over the whole run,
//! and keeps each side's best median.

const std = @import("std");
const builtin = @import("builtin");
const stbi = @import("stb_image");
const bench_paths = @import("bench_paths");

const Settings = extern struct {
    via: c_int = 0,
    fd: c_int = -1,
    req_comp: c_int = 0,
    flip: c_int = 0,
    flip_thread: c_int = -1,
    unpremultiply: c_int = 0,
    unpremultiply_thread: c_int = -1,
    iphone: c_int = 0,
    iphone_thread: c_int = -1,
    l2h_gamma: f32 = 2.2,
    l2h_scale: f32 = 1.0,
    h2l_gamma: f32 = 2.2,
    h2l_scale: f32 = 1.0,
    path: ?[*:0]const u8 = null,
};

const Result = extern struct {
    pixels: ?*anyopaque,
    x: c_int,
    y: c_int,
    comp: c_int,
    z: c_int,
    delays: ?[*]c_int,
    reason: ?[*:0]const u8,
    pos_after: c_long,
};

const LoadFn = fn ([*]const u8, usize, c_int, *const Settings, *Result) callconv(.c) void;
const GifFn = fn ([*]const u8, usize, *const Settings, *Result) callconv(.c) void;
extern fn simd_load(bytes: [*]const u8, len: usize, bits: c_int, settings: *const Settings, out: *Result) void;
extern fn scalar_load(bytes: [*]const u8, len: usize, bits: c_int, settings: *const Settings, out: *Result) void;
extern fn simd_load_gif(bytes: [*]const u8, len: usize, settings: *const Settings, out: *Result) void;
extern fn simd_free(p: ?*anyopaque) void;
extern fn simd_zlib(
    which: c_int,
    buffer: [*]const u8,
    len: c_int,
    initial_size: c_int,
    parse_header: c_int,
    obuffer: ?[*]u8,
    olen: c_int,
    outlen: *c_int,
    reason: *?[*:0]const u8,
) ?[*]u8;
extern fn bench_write(
    format: c_int,
    w: c_int,
    h: c_int,
    comp: c_int,
    pixels: *const anyopaque,
    quality: c_int,
    len: *usize,
) ?[*]u8;
extern fn bench_free(p: ?*anyopaque) void;

const sample_ns_min = 50 * std.time.ns_per_ms;
const warm_up_samples = 2;
const gpa = std.heap.c_allocator;

const Sample = enum { u8, u16, f32 };

/// Where a load reads its input: memory; a reader over it, against the
/// original's callbacks; or an in-memory file, against the original's
/// `FILE` on the same descriptor.
const Via = enum(c_int) { memory = 0, reader = 1, file = 2 };

const Kind = union(enum) {
    load: struct { sample: Sample, components: stbi.Components = .file, via: Via = .memory },
    gif,
    zlib,
};

const Input = enum {
    png_rgb,
    png_rgba,
    png_grey,
    png_rgb16,
    png_adam7,
    png_palette,
    jpeg_444,
    jpeg_420,
    jpeg_grey,
    jpeg_progressive,
    jpeg_ycck,
    bmp_24,
    bmp_32,
    tga_raw,
    tga_rle,
    psd_raw,
    psd_rle,
    hdr,
    pnm_8,
    pnm_16,
    gif,
    zlib,
};

const Row = struct {
    name: []const u8,
    input: Input,
    kind: Kind,
    /// Also time the original with its SIMD paths off.
    scalar: bool = false,
};

const rows = [_]Row{
    .{ .name = "png rgb", .input = .png_rgb, .kind = .{ .load = .{ .sample = .u8 } } },
    .{ .name = "png rgba", .input = .png_rgba, .kind = .{ .load = .{ .sample = .u8 } } },
    .{ .name = "png grey", .input = .png_grey, .kind = .{ .load = .{ .sample = .u8 } } },
    .{ .name = "png rgb 16-bit", .input = .png_rgb16, .kind = .{ .load = .{ .sample = .u16 } } },
    .{ .name = "png rgb adam7", .input = .png_adam7, .kind = .{ .load = .{ .sample = .u8 } } },
    .{ .name = "png palette", .input = .png_palette, .kind = .{ .load = .{ .sample = .u8 } } },
    .{ .name = "png rgb to rgba", .input = .png_rgb, .kind = .{ .load = .{ .sample = .u8, .components = .rgba } } },
    .{ .name = "png rgb to float", .input = .png_rgb, .kind = .{ .load = .{ .sample = .f32 } } },
    .{ .name = "jpeg 4:4:4", .input = .jpeg_444, .kind = .{ .load = .{ .sample = .u8 } }, .scalar = true },
    .{ .name = "jpeg 4:2:0", .input = .jpeg_420, .kind = .{ .load = .{ .sample = .u8 } }, .scalar = true },
    .{ .name = "jpeg 4:2:0 to rgba", .input = .jpeg_420, .kind = .{ .load = .{ .sample = .u8, .components = .rgba } }, .scalar = true },
    .{ .name = "jpeg grey", .input = .jpeg_grey, .kind = .{ .load = .{ .sample = .u8 } }, .scalar = true },
    .{ .name = "jpeg progressive", .input = .jpeg_progressive, .kind = .{ .load = .{ .sample = .u8 } }, .scalar = true },
    .{ .name = "jpeg ycck", .input = .jpeg_ycck, .kind = .{ .load = .{ .sample = .u8 } }, .scalar = true },
    .{ .name = "bmp 24-bit", .input = .bmp_24, .kind = .{ .load = .{ .sample = .u8 } } },
    .{ .name = "bmp 32-bit", .input = .bmp_32, .kind = .{ .load = .{ .sample = .u8 } } },
    .{ .name = "bmp 24-bit to rgba", .input = .bmp_24, .kind = .{ .load = .{ .sample = .u8, .components = .rgba } } },
    .{ .name = "tga raw", .input = .tga_raw, .kind = .{ .load = .{ .sample = .u8 } } },
    .{ .name = "tga rle", .input = .tga_rle, .kind = .{ .load = .{ .sample = .u8 } } },
    .{ .name = "tga raw to rgba", .input = .tga_raw, .kind = .{ .load = .{ .sample = .u8, .components = .rgba } } },
    .{ .name = "tga raw to grey", .input = .tga_raw, .kind = .{ .load = .{ .sample = .u8, .components = .grey } } },
    .{ .name = "psd raw", .input = .psd_raw, .kind = .{ .load = .{ .sample = .u8 } } },
    .{ .name = "psd rle", .input = .psd_rle, .kind = .{ .load = .{ .sample = .u8 } } },
    .{ .name = "psd raw to rgb", .input = .psd_raw, .kind = .{ .load = .{ .sample = .u8, .components = .rgb } } },
    .{ .name = "hdr float", .input = .hdr, .kind = .{ .load = .{ .sample = .f32 } } },
    .{ .name = "hdr to 8-bit", .input = .hdr, .kind = .{ .load = .{ .sample = .u8 } } },
    .{ .name = "pnm 8-bit", .input = .pnm_8, .kind = .{ .load = .{ .sample = .u8 } } },
    .{ .name = "pnm 16-bit", .input = .pnm_16, .kind = .{ .load = .{ .sample = .u16 } } },
    .{ .name = "gif first frame", .input = .gif, .kind = .{ .load = .{ .sample = .u8 } } },
    .{ .name = "gif every frame", .input = .gif, .kind = .gif },
    .{ .name = "zlib inflate", .input = .zlib, .kind = .zlib },
    .{ .name = "png rgb via reader", .input = .png_rgb, .kind = .{ .load = .{ .sample = .u8, .via = .reader } } },
    .{ .name = "png rgb via file", .input = .png_rgb, .kind = .{ .load = .{ .sample = .u8, .via = .file } } },
    .{ .name = "jpeg 4:2:0 via reader", .input = .jpeg_420, .kind = .{ .load = .{ .sample = .u8, .via = .reader } } },
    .{ .name = "jpeg 4:2:0 via file", .input = .jpeg_420, .kind = .{ .load = .{ .sample = .u8, .via = .file } } },
    .{ .name = "bmp 24-bit via reader", .input = .bmp_24, .kind = .{ .load = .{ .sample = .u8, .via = .reader } } },
    .{ .name = "bmp 24-bit via file", .input = .bmp_24, .kind = .{ .load = .{ .sample = .u8, .via = .file } } },
    .{ .name = "psd raw via reader", .input = .psd_raw, .kind = .{ .load = .{ .sample = .u8, .via = .reader } } },
    .{ .name = "psd raw via file", .input = .psd_raw, .kind = .{ .load = .{ .sample = .u8, .via = .file } } },
    .{ .name = "psd rle via reader", .input = .psd_rle, .kind = .{ .load = .{ .sample = .u8, .via = .reader } } },
    .{ .name = "psd rle via file", .input = .psd_rle, .kind = .{ .load = .{ .sample = .u8, .via = .file } } },
};

/// For the rows that load from a file: each input in an in-memory file,
/// and the `Io` the port's file reader needs.
var input_files: std.EnumArray(Input, std.posix.fd_t) = .initFill(-1);
var bench_io: std.Io = undefined;

// --- The two sides ------------------------------------------------------------

/// One decode's output: a pointer kept behind a barrier, and the bytes and
/// work done, for the comparison and the throughput.
const Output = struct {
    bytes: []const u8,
    /// Pixels, or bytes for the zlib row.
    units: usize,
};

fn bitsOf(sample: Sample) c_int {
    return switch (sample) {
        .u8 => 8,
        .u16 => 16,
        .f32 => 32,
    };
}

fn sampleSize(sample: Sample) usize {
    return switch (sample) {
        .u8 => 1,
        .u16 => 2,
        .f32 => 4,
    };
}

const Side = enum { port, original, original_scalar };

/// Decodes `input` once with `side`. Returns the output, which the caller
/// frees with `release`.
fn decode(side: Side, row: *const Row, input: []const u8) Output {
    switch (row.kind) {
        .load => |load| {
            if (side == .port) {
                switch (load.sample) {
                    inline else => |sample| {
                        const T = switch (sample) {
                            .u8 => u8,
                            .u16 => u16,
                            .f32 => f32,
                        };
                        const options: stbi.Options = .{ .components = load.components };
                        const result = switch (load.via) {
                            .memory => stbi.loadFromMemory(T, gpa, input, options),
                            .reader => blk: {
                                var reader: std.Io.Reader = .fixed(input);
                                break :blk stbi.loadFromReader(T, gpa, &reader, options);
                            },
                            .file => blk: {
                                const file: std.Io.File = .{
                                    .handle = input_files.get(row.input),
                                    .flags = .{ .nonblocking = false },
                                };
                                var buffer: [4096]u8 = undefined;
                                var file_reader = file.reader(bench_io, &buffer);
                                break :blk stbi.loadFromFile(T, gpa, &file_reader, options);
                            },
                        };
                        const image = result catch |err|
                            std.debug.panic("{s}: the port fails: {t}", .{ row.name, err });
                        return .{
                            .bytes = std.mem.sliceAsBytes(image.pixels),
                            .units = @as(usize, image.width) * image.height,
                        };
                    },
                }
            }
            var settings: Settings = .{
                .req_comp = @backingInt(load.components),
                .via = @backingInt(load.via),
            };
            if (load.via == .file) {
                // The original reads from the descriptor's own offset.
                settings.fd = input_files.get(row.input);
                _ = std.os.linux.lseek(settings.fd, 0, std.os.linux.SEEK.SET);
            }
            var result: Result = undefined;
            const f: *const LoadFn = if (side == .original) &simd_load else &scalar_load;
            f(input.ptr, input.len, bitsOf(load.sample), &settings, &result);
            const pixels: [*]const u8 = @ptrCast(result.pixels orelse
                std.debug.panic("{s}: the original fails: {s}", .{ row.name, result.reason orelse "" }));
            const comp: usize = if (load.components != .file) @backingInt(load.components) else @intCast(result.comp);
            const units = @as(usize, @intCast(result.x)) * @as(usize, @intCast(result.y));
            return .{ .bytes = pixels[0 .. units * comp * sampleSize(load.sample)], .units = units };
        },
        .gif => {
            if (side == .port) {
                const animation = stbi.loadGifFromMemory(gpa, input, .{}) catch |err|
                    std.debug.panic("{s}: the port fails: {t}", .{ row.name, err });
                gpa.free(animation.delays_ms);
                return .{
                    .bytes = animation.pixels,
                    .units = @as(usize, animation.width) * animation.height * animation.frames,
                };
            }
            var result: Result = undefined;
            simd_load_gif(input.ptr, input.len, &.{}, &result);
            simd_free(@ptrCast(result.delays));
            const pixels: [*]const u8 = @ptrCast(result.pixels orelse
                std.debug.panic("{s}: the original fails", .{row.name}));
            const units = @as(usize, @intCast(result.x)) * @as(usize, @intCast(result.y)) *
                @as(usize, @intCast(result.z));
            return .{ .bytes = pixels[0 .. units * 4], .units = units };
        },
        .zlib => {
            if (side == .port) {
                const out = stbi.zlib.decodeAlloc(gpa, input, .{}) catch |err|
                    std.debug.panic("{s}: the port fails: {t}", .{ row.name, err });
                return .{ .bytes = out, .units = out.len };
            }
            var len: c_int = 0;
            var reason: ?[*:0]const u8 = null;
            const out = simd_zlib(1, input.ptr, @intCast(input.len), 0, 1, null, 0, &len, &reason) orelse
                std.debug.panic("{s}: the original fails", .{row.name});
            return .{ .bytes = out[0..@intCast(len)], .units = @intCast(len) };
        },
    }
}

fn release(side: Side, output: Output) void {
    if (side == .port) {
        gpa.free(output.bytes);
    } else {
        simd_free(@constCast(output.bytes.ptr));
    }
}

// --- Measurement ----------------------------------------------------------------

fn timeDecodes(io: std.Io, side: Side, row: *const Row, input: []const u8, reps: u32) u64 {
    const start = std.Io.Clock.cpu_thread.now(io);
    for (0..reps) |_| {
        std.mem.doNotOptimizeAway(input.ptr);
        const output = decode(side, row, input);
        std.mem.doNotOptimizeAway(output.bytes.ptr);
        release(side, output);
    }
    const end = std.Io.Clock.cpu_thread.now(io);
    return @intCast(start.durationTo(end).nanoseconds);
}

const Timing = struct {
    /// Median nanoseconds per decode.
    median_ns: f64,
    /// (slowest - fastest) / median, over the samples.
    range: f64,

    fn of(ns: []f64) Timing {
        std.mem.sort(f64, ns, {}, std.sort.asc(f64));
        const mid = ns.len / 2;
        const median = if (ns.len % 2 == 1) ns[mid] else (ns[mid - 1] + ns[mid]) / 2;
        return .{ .median_ns = median, .range = (ns[ns.len - 1] - ns[0]) / median };
    }

    fn better(a: ?Timing, b: Timing) Timing {
        const old = a orelse return b;
        return if (b.median_ns < old.median_ns) b else old;
    }
};

const sides = [_]Side{ .port, .original, .original_scalar };

const RowResult = struct {
    timings: [sides.len]?Timing = @splat(null),
    units: usize = 0,
    same_bytes: bool = true,
};

fn measure(io: std.Io, row: *const Row, input: []const u8, samples: u32, scratch: []f64, result: *RowResult) void {
    const active: []const Side = if (row.scalar) &sides else sides[0..2];
    var reps: [sides.len]u32 = undefined;
    for (active, 0..) |side, i| {
        const once = @max(timeDecodes(io, side, row, input, 1), 1);
        reps[i] = @intCast(@max(1, std.math.divCeil(u64, sample_ns_min, once) catch unreachable));
    }
    for (0..warm_up_samples + samples) |k| {
        // Rotating which side goes first evens out any advantage of
        // running after the other.
        for (0..active.len) |turn| {
            const i = (turn + k) % active.len;
            const ns = timeDecodes(io, active[i], row, input, reps[i]);
            if (k >= warm_up_samples) {
                scratch[i * samples + k - warm_up_samples] =
                    @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(reps[i]));
            }
        }
    }
    for (active, 0..) |_, i| {
        result.timings[i] = Timing.better(result.timings[i], Timing.of(scratch[i * samples ..][0..samples]));
    }
    const port = decode(.port, row, input);
    defer release(.port, port);
    result.units = port.units;
    for (active[1..]) |side| {
        const original = decode(side, row, input);
        defer release(side, original);
        if (!std.mem.eql(u8, port.bytes, original.bytes)) result.same_bytes = false;
    }
}

// --- Inputs ---------------------------------------------------------------------

const Photo = struct {
    width: u32,
    height: u32,
    rgb: []u8,
};

fn readFile(io: std.Io, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 << 20));
}

fn loadPhoto(io: std.Io) !Photo {
    const png = try readFile(io, bench_paths.photo);
    var result: Result = undefined;
    simd_load(png.ptr, png.len, 8, &.{ .req_comp = 3 }, &result);
    const pixels: [*]u8 = @ptrCast(result.pixels orelse return error.PhotoUnreadable);
    const width: u32 = @intCast(result.x);
    const height: u32 = @intCast(result.y);
    return .{ .width = width, .height = height, .rgb = pixels[0 .. @as(usize, width) * height * 3] };
}

fn write(format: c_int, photo: Photo, comp: u32, pixels: []const u8, quality: c_int) ![]const u8 {
    var len: usize = 0;
    const data = bench_write(
        format,
        @intCast(photo.width),
        @intCast(photo.height),
        @intCast(comp),
        pixels.ptr,
        quality,
        &len,
    ) orelse return error.WriteFailed;
    return data[0..len];
}

fn withComponents(photo: Photo, comp: u32) ![]u8 {
    const pixels = @as(usize, photo.width) * photo.height;
    const out = try gpa.alloc(u8, pixels * comp);
    for (0..pixels) |i| {
        const r = photo.rgb[i * 3];
        const g = photo.rgb[i * 3 + 1];
        const b = photo.rgb[i * 3 + 2];
        switch (comp) {
            1 => out[i] = @intCast((@as(u32, r) * 77 + @as(u32, g) * 150 + @as(u32, b) * 29) >> 8),
            4 => out[i * 4 ..][0..4].* = .{ r, g, b, @truncate(i *% 7 +% (i / photo.width)) },
            else => unreachable,
        }
    }
    return out;
}

/// A PNG with `filtered` rows (each row's filter byte already in place)
/// compressed by std's deflate at its default level.
fn pngFile(
    width: u32,
    height: u32,
    depth: u8,
    color_type: u8,
    interlace: bool,
    palette: ?[]const u8,
    filtered: []const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = try .initCapacity(gpa, 1 << 16);
    const w = &out.writer;
    try w.writeAll("\x89PNG\r\n\x1a\n");
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], width, .big);
    std.mem.writeInt(u32, ihdr[4..8], height, .big);
    ihdr[8..13].* = .{ depth, color_type, 0, 0, @intFromBool(interlace) };
    try chunk(w, "IHDR", &ihdr);
    if (palette) |plte| try chunk(w, "PLTE", plte);

    var compressed: std.Io.Writer.Allocating = try .initCapacity(gpa, 1 << 20);
    const window = try gpa.alloc(u8, std.compress.flate.max_window_len);
    var compress: std.compress.flate.Compress = try .init(&compressed.writer, window, .zlib, .default);
    try compress.writer.writeAll(filtered);
    try compress.finish();
    try chunk(w, "IDAT", compressed.written());
    try chunk(w, "IEND", "");
    return out.toOwnedSlice();
}

fn chunk(w: *std.Io.Writer, kind: *const [4]u8, data: []const u8) !void {
    try w.writeInt(u32, @intCast(data.len), .big);
    try w.writeAll(kind);
    try w.writeAll(data);
    var crc: std.hash.Crc32 = .init();
    crc.update(kind);
    crc.update(data);
    try w.writeInt(u32, crc.final(), .big);
}

/// Rows of `bpp`-byte pixels with filters 0 to 4 in turn (computed for
/// real), as the PNG writers of image editors mix them.
fn filterRows(rows_data: []const u8, width: usize, height: usize, bpp: usize, out: *std.ArrayList(u8)) !void {
    const stride = width * bpp;
    for (0..height) |y| {
        const filter: u8 = @intCast(y % 5);
        try out.append(gpa, filter);
        const row = rows_data[y * stride ..][0..stride];
        const prior: ?[]const u8 = if (y > 0) rows_data[(y - 1) * stride ..][0..stride] else null;
        for (row, 0..) |x, i| {
            const a: i32 = if (i >= bpp) row[i - bpp] else 0;
            const b: i32 = if (prior) |p| p[i] else 0;
            const c: i32 = if (prior != null and i >= bpp) prior.?[i - bpp] else 0;
            const predicted: i32 = switch (filter) {
                0 => 0,
                1 => a,
                2 => b,
                3 => @divFloor(a + b, 2),
                4 => paeth(a, b, c),
                else => unreachable,
            };
            try out.append(gpa, @truncate(@as(u32, @bitCast(@as(i32, x) - predicted))));
        }
    }
}

fn paeth(a: i32, b: i32, c: i32) i32 {
    const p = a + b - c;
    const pa = @abs(p - a);
    const pb = @abs(p - b);
    const pc = @abs(p - c);
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

fn pngRgb16(photo: Photo) ![]u8 {
    const pixels = @as(usize, photo.width) * photo.height;
    const wide = try gpa.alloc(u8, pixels * 6);
    for (0..pixels * 3) |i| {
        const v: u16 = @as(u16, photo.rgb[i]) * 257 +% @as(u16, @truncate(i *% 2654435761 >> 24));
        std.mem.writeInt(u16, wide[i * 2 ..][0..2], v, .big);
    }
    var filtered: std.ArrayList(u8) = .empty;
    try filterRows(wide, photo.width, photo.height, 6, &filtered);
    return pngFile(photo.width, photo.height, 16, 2, false, null, filtered.items);
}

/// Adam7's seven passes of the RGB photo, each filtered.
fn pngAdam7(photo: Photo) ![]u8 {
    const xorig = [_]usize{ 0, 4, 0, 2, 0, 1, 0 };
    const yorig = [_]usize{ 0, 0, 4, 0, 2, 0, 1 };
    const xspc = [_]usize{ 8, 8, 4, 4, 2, 2, 1 };
    const yspc = [_]usize{ 8, 8, 8, 4, 4, 2, 2 };
    var filtered: std.ArrayList(u8) = .empty;
    for (0..7) |p| {
        const w = (photo.width - xorig[p] + xspc[p] - 1) / xspc[p];
        const h = (photo.height - yorig[p] + yspc[p] - 1) / yspc[p];
        if (w == 0 or h == 0) continue;
        const pass = try gpa.alloc(u8, w * h * 3);
        for (0..h) |j| {
            for (0..w) |i| {
                const sx = xorig[p] + i * xspc[p];
                const sy = yorig[p] + j * yspc[p];
                @memcpy(pass[(j * w + i) * 3 ..][0..3], photo.rgb[(sy * photo.width + sx) * 3 ..][0..3]);
            }
        }
        try filterRows(pass, w, h, 3, &filtered);
    }
    return pngFile(photo.width, photo.height, 8, 2, true, null, filtered.items);
}

/// The photo in 3-3-2 bits of colour, as an 8-bit paletted PNG.
fn pngPalette(photo: Photo) ![]u8 {
    var palette: [256 * 3]u8 = undefined;
    for (0..256) |i| {
        palette[i * 3 ..][0..3].* = .{
            @intCast((i >> 5) * 255 / 7),
            @intCast(((i >> 2) & 7) * 255 / 7),
            @intCast((i & 3) * 255 / 3),
        };
    }
    const pixels = @as(usize, photo.width) * photo.height;
    const indices = try gpa.alloc(u8, pixels);
    for (indices, 0..) |*index, i| {
        const rgb = photo.rgb[i * 3 ..][0..3];
        index.* = (rgb[0] & 0xe0) | ((rgb[1] >> 3) & 0x1c) | (rgb[2] >> 6);
    }
    var filtered: std.ArrayList(u8) = .empty;
    try filterRows(indices, photo.width, photo.height, 1, &filtered);
    return pngFile(photo.width, photo.height, 8, 3, false, &palette, filtered.items);
}

/// A PSD of the photo with an alpha channel, planar, raw or PackBits.
fn psdFile(photo: Photo, rle: bool) ![]u8 {
    var out: std.Io.Writer.Allocating = try .initCapacity(gpa, 1 << 20);
    const w = &out.writer;
    const channels = 4;
    try w.writeAll("8BPS");
    try w.writeInt(u16, 1, .big);
    try w.writeAll(&@as([6]u8, @splat(0)));
    try w.writeInt(u16, channels, .big);
    try w.writeInt(u32, photo.height, .big);
    try w.writeInt(u32, photo.width, .big);
    try w.writeInt(u16, 8, .big);
    try w.writeInt(u16, 3, .big);
    for (0..3) |_| try w.writeInt(u32, 0, .big);
    try w.writeInt(u16, @intFromBool(rle), .big);
    // Photoshop stores colour with alpha blended over white, which the
    // original takes out again; colour below that matte is not valid.
    const rgba = try withComponents(photo, 4);
    for (0..rgba.len / 4) |i| {
        const a: u32 = rgba[i * 4 + 3];
        for (rgba[i * 4 ..][0..3]) |*c| c.* = @intCast((@as(u32, c.*) * a + 255 * (255 - a)) / 255);
    }
    const width: usize = photo.width;
    const plane_row = try gpa.alloc(u8, width);
    if (!rle) {
        for (0..channels) |c| {
            for (0..photo.height) |y| {
                for (plane_row, 0..) |*v, x| v.* = rgba[(y * width + x) * 4 + c];
                try w.writeAll(plane_row);
            }
        }
        return out.toOwnedSlice();
    }
    var packed_rows: std.ArrayList(u8) = .empty;
    var counts: std.ArrayList(u16) = .empty;
    for (0..channels) |c| {
        for (0..photo.height) |y| {
            for (plane_row, 0..) |*v, x| v.* = rgba[(y * width + x) * 4 + c];
            const before = packed_rows.items.len;
            try packBits(plane_row, &packed_rows);
            try counts.append(gpa, @intCast(packed_rows.items.len - before));
        }
    }
    for (counts.items) |count| try w.writeInt(u16, count, .big);
    try w.writeAll(packed_rows.items);
    return out.toOwnedSlice();
}

fn packBits(row: []const u8, out: *std.ArrayList(u8)) !void {
    var i: usize = 0;
    while (i < row.len) {
        var run: usize = 1;
        while (i + run < row.len and run < 128 and row[i + run] == row[i]) run += 1;
        if (run >= 3) {
            try out.append(gpa, @intCast(257 - run));
            try out.append(gpa, row[i]);
            i += run;
            continue;
        }
        var literal: usize = 1;
        while (i + literal < row.len and literal < 128) {
            const at = i + literal;
            if (at + 2 < row.len and row[at] == row[at + 1] and row[at] == row[at + 2]) break;
            literal += 1;
        }
        try out.append(gpa, @intCast(literal - 1));
        try out.appendSlice(gpa, row[i..][0..literal]);
        i += literal;
    }
}

fn pnmFile(photo: Photo, sixteen: bool) ![]u8 {
    var out: std.Io.Writer.Allocating = try .initCapacity(gpa, 1 << 20);
    const w = &out.writer;
    try w.print("P6\n{d} {d}\n{d}\n", .{ photo.width, photo.height, @as(u32, if (sixteen) 65535 else 255) });
    if (!sixteen) {
        try w.writeAll(photo.rgb);
    } else {
        for (photo.rgb, 0..) |v, i| {
            try w.writeInt(u16, @as(u16, v) * 257 +% @as(u16, @truncate(i *% 2654435761 >> 24)), .big);
        }
    }
    return out.toOwnedSlice();
}

fn hdrPixels(photo: Photo) ![]f32 {
    const out = try gpa.alloc(f32, photo.rgb.len);
    for (out, photo.rgb) |*f, v| {
        const x = @as(f32, @floatFromInt(v)) / 255.0;
        f.* = x * x * 4.0;
    }
    return out;
}

fn zlibStream(photo: Photo) ![]u8 {
    var compressed: std.Io.Writer.Allocating = try .initCapacity(gpa, 1 << 20);
    const window = try gpa.alloc(u8, std.compress.flate.max_window_len);
    var compress: std.compress.flate.Compress = try .init(&compressed.writer, window, .zlib, .default);
    try compress.writer.writeAll(photo.rgb);
    try compress.finish();
    return compressed.toOwnedSlice();
}

/// `bytes` in an in-memory file.
fn memFile(io: std.Io, bytes: []const u8) !std.posix.fd_t {
    const fd = try std.posix.memfd_create("stb-image-bench", 0);
    const file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
    try file.writePositionalAll(io, bytes, 0);
    return fd;
}

fn prepare(io: std.Io) !std.EnumArray(Input, []const u8) {
    const photo = try loadPhoto(io);
    const grey = try withComponents(photo, 1);
    const rgba = try withComponents(photo, 4);
    var inputs: std.EnumArray(Input, []const u8) = .initUndefined();
    inputs.set(.png_rgb, try write(0, photo, 3, photo.rgb, 0));
    inputs.set(.png_rgba, try write(0, photo, 4, rgba, 0));
    inputs.set(.png_grey, try write(0, photo, 1, grey, 0));
    inputs.set(.png_rgb16, try pngRgb16(photo));
    inputs.set(.png_adam7, try pngAdam7(photo));
    inputs.set(.png_palette, try pngPalette(photo));
    // stb_image_write subsamples the chroma at quality 90 and below.
    inputs.set(.jpeg_444, try write(1, photo, 3, photo.rgb, 95));
    inputs.set(.jpeg_420, try write(1, photo, 3, photo.rgb, 85));
    inputs.set(.jpeg_grey, try write(1, photo, 1, grey, 90));
    inputs.set(.jpeg_progressive, try readFile(io, bench_paths.progressive));
    inputs.set(.jpeg_ycck, try readFile(io, bench_paths.ycck));
    inputs.set(.bmp_24, try write(2, photo, 3, photo.rgb, 0));
    inputs.set(.bmp_32, try write(2, photo, 4, rgba, 0));
    inputs.set(.tga_raw, try write(3, photo, 3, photo.rgb, 0));
    inputs.set(.tga_rle, try write(4, photo, 3, photo.rgb, 0));
    inputs.set(.psd_raw, try psdFile(photo, false));
    inputs.set(.psd_rle, try psdFile(photo, true));
    inputs.set(.hdr, try write(5, photo, 3, std.mem.sliceAsBytes(try hdrPixels(photo)), 0));
    inputs.set(.pnm_8, try pnmFile(photo, false));
    inputs.set(.pnm_16, try pnmFile(photo, true));
    inputs.set(.gif, try readFile(io, bench_paths.gif));
    inputs.set(.zlib, try zlibStream(photo));
    for (rows) |row| {
        if (row.kind != .load or row.kind.load.via != .file) continue;
        if (input_files.get(row.input) < 0) input_files.set(row.input, try memFile(io, inputs.get(row.input)));
    }
    return inputs;
}

// --- Main -----------------------------------------------------------------------

const Options = struct {
    samples: u32 = 11,
    rounds: u32 = 1,
    filter: ?[]const u8 = null,
};

fn parseOptions(args: []const [:0]const u8) !Options {
    var options: Options = .{};
    var i: usize = 1;
    while (i < args.len) : (i += 2) {
        if (i + 1 >= args.len) return error.MissingValue;
        const value = args[i + 1];
        if (std.mem.eql(u8, args[i], "--samples")) {
            options.samples = try std.fmt.parseInt(u32, value, 10);
        } else if (std.mem.eql(u8, args[i], "--rounds")) {
            options.rounds = try std.fmt.parseInt(u32, value, 10);
        } else if (std.mem.eql(u8, args[i], "--filter")) {
            options.filter = value;
        } else return error.UnknownOption;
    }
    if (options.samples == 0 or options.rounds == 0) return error.ZeroCount;
    return options;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    bench_io = io;
    const options = try parseOptions(try init.minimal.args.toSlice(init.arena.allocator()));
    const inputs = try prepare(io);
    const scratch = try gpa.alloc(f64, sides.len * options.samples);

    var results: [rows.len]RowResult = @splat(.{});
    for (0..options.rounds) |_| {
        for (&rows, &results) |*row, *result| {
            if (options.filter) |f| if (std.mem.find(u8, row.name, f) == null) continue;
            measure(io, row, inputs.get(row.input), options.samples, scratch, result);
        }
    }

    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buffer);
    const w = &stdout.interface;
    try w.print(
        \\zig-stb-image benchmark: {t} {s}, {t}, Zig {s}, one thread
        \\median of {d} samples of at least {d} ms after {d} warm-ups, best of {d} round(s);
        \\thread CPU time; Mpix/s (MB/s of output for zlib)
        \\
        \\| feature | port | range | original | range | time, port / original | original, no SIMD | time, port / no SIMD |
        \\| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
        \\
    , .{
        builtin.cpu.arch,
        builtin.cpu.model.name,
        builtin.os.tag,
        builtin.zig_version_string,
        options.samples,
        sample_ns_min / std.time.ns_per_ms,
        warm_up_samples,
        options.rounds,
    });
    for (&rows, results) |*row, result| {
        const port = result.timings[0] orelse continue;
        const units: f64 = @floatFromInt(result.units);
        try w.print("| {s} | {d:.1} | {d:.1}% |", .{ row.name, units / port.median_ns * 1e3, port.range * 100 });
        for (result.timings[1..], 0..) |timing, i| {
            if (timing) |t| {
                try w.print(" {d:.1} |", .{units / t.median_ns * 1e3});
                if (i == 0) try w.print(" {d:.1}% |", .{t.range * 100});
                try w.print(" {d:.2} |", .{port.median_ns / t.median_ns});
            } else if (i == 1) try w.print(" | |", .{});
        }
        if (!result.same_bytes) try w.print(" OUTPUT DIFFERS", .{});
        try w.print("\n", .{});
    }
    try w.flush();
}
