//! Runs the original stb_image (both of its builds, see `shim/oracle.c`)
//! and the port on the same input and request, and fails on any difference:
//! success or failure, the size and channel count, every pixel byte (floats
//! by their bits), the failure reason in both its forms, and for files the
//! position left behind.

const std = @import("std");
const stbi = @import("stb_image");
const fuzz_options = @import("fuzz_options");

pub const Bits = enum { u8, u16, f32 };
pub const Via = enum(c_int) { memory = 0, callbacks = 1, file = 2 };
pub const Path = enum { simd, scalar };

pub const Settings = extern struct {
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
};

pub const Result = extern struct {
    pixels: ?*anyopaque,
    x: c_int,
    y: c_int,
    comp: c_int,
    z: c_int,
    delays: ?[*]c_int,
    reason: ?[*:0]const u8,
    pos_after: c_long,
};

pub const upstream = struct {
    pub extern fn simd_load(bytes: [*]const u8, len: usize, bits: c_int, settings: *const Settings, out: *Result) void;
    pub extern fn scalar_load(bytes: [*]const u8, len: usize, bits: c_int, settings: *const Settings, out: *Result) void;
    pub extern fn simd_load_gif(bytes: [*]const u8, len: usize, settings: *const Settings, out: *Result) void;
    pub extern fn scalar_load_gif(bytes: [*]const u8, len: usize, settings: *const Settings, out: *Result) void;
    pub extern fn simd_free(p: ?*anyopaque) void;
    pub extern fn simd_set_malloc_fill(fill: c_int) void;
    pub extern fn scalar_set_malloc_fill(fill: c_int) void;
    pub extern fn scalar_free(p: ?*anyopaque) void;
    pub extern fn simd_query(bytes: [*]const u8, len: usize, what: c_int, settings: *const Settings, out: *Result) c_int;
    pub extern fn scalar_query(bytes: [*]const u8, len: usize, what: c_int, settings: *const Settings, out: *Result) c_int;
    pub extern fn simd_zlib(
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
    pub extern fn simd_pow(x: f64, y: f64) f64;
    pub extern fn simd_set_flag(which: c_int, thread: c_int, value: c_int) void;
    pub extern fn scalar_set_flag(which: c_int, thread: c_int, value: c_int) void;
    pub extern fn simd_get_flags(flip: *c_int, unpremultiply: *c_int, iphone: *c_int) void;
    pub extern fn scalar_get_flags(flip: *c_int, unpremultiply: *c_int, iphone: *c_int) void;
};

pub fn loadFn(path: Path) *const fn ([*]const u8, usize, c_int, *const Settings, *Result) callconv(.c) void {
    return switch (path) {
        .simd => &upstream.simd_load,
        .scalar => &upstream.scalar_load,
    };
}

pub fn freeFn(path: Path) *const fn (?*anyopaque) callconv(.c) void {
    return switch (path) {
        .simd => &upstream.simd_free,
        .scalar => &upstream.scalar_free,
    };
}

fn queryFn(path: Path) *const fn ([*]const u8, usize, c_int, *const Settings, *Result) callconv(.c) c_int {
    return switch (path) {
        .simd => &upstream.simd_query,
        .scalar => &upstream.scalar_query,
    };
}

/// One load: the bit depth, how the input is read, and the options.
pub const Request = struct {
    bits: Bits = .u8,
    via: Via = .memory,
    /// For `.file`: junk bytes before the image, so the load starts at an
    /// offset into the file.
    file_offset: u32 = 0,
    options: stbi.Options = .{},

    pub fn settings(request: Request) Settings {
        const o = request.options;
        return .{
            .via = @backingInt(request.via),
            .req_comp = o.reqComp(),
            .flip = @intFromBool(o.flip_vertically),
            .unpremultiply = @intFromBool(o.unpremultiply),
            .iphone = @intFromBool(o.convert_iphone_png),
            .l2h_gamma = o.ldr_to_hdr_gamma,
            .l2h_scale = o.ldr_to_hdr_scale,
            .h2l_gamma = o.hdr_to_ldr_gamma,
            .h2l_scale = o.hdr_to_ldr_scale,
        };
    }
};

/// Names the input in a failure: a file, or a fuzz test's seed and case.
pub const Label = struct {
    name: []const u8,
    seed: ?u64 = null,
    case: ?usize = null,

    pub fn print(label: Label, request: Request, comptime fmt: []const u8, args: anytype) void {
        std.debug.print("\n[{s}", .{label.name});
        if (label.seed) |seed| std.debug.print(" seed {d}", .{seed});
        if (label.case) |case| std.debug.print(" case {d}", .{case});
        std.debug.print("] {t} via {t}, components {t}, flip {}: ", .{
            request.bits,
            request.via,
            request.options.components,
            request.options.flip_vertically,
        });
        std.debug.print(fmt ++ "\n", args);
    }
};

/// An input in a file the original and the port both read, from an
/// in-memory file descriptor.
const MemFile = struct {
    fd: std.posix.fd_t,

    fn init(bytes: []const u8, offset: u32) !MemFile {
        const fd = try std.posix.memfd_create("stb-image-oracle", 0);
        const handle: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
        errdefer handle.close(std.testing.io);
        var junk: [256]u8 = undefined;
        @memset(&junk, 0xA5);
        var written: u32 = 0;
        while (written < offset) {
            const n = @min(junk.len, offset - written);
            try handle.writePositionalAll(std.testing.io, junk[0..n], written);
            written += @intCast(n);
        }
        try handle.writePositionalAll(std.testing.io, bytes, offset);
        return .{ .fd = fd };
    }

    fn file(mem: MemFile) std.Io.File {
        return .{ .handle = mem.fd, .flags = .{ .nonblocking = false } };
    }

    /// Puts the descriptor's own offset at `offset`, where the original's
    /// `FILE` starts reading.
    fn seek(mem: MemFile, offset: u32) void {
        _ = std.os.linux.lseek(mem.fd, offset, std.os.linux.SEEK.SET);
    }

    fn deinit(mem: MemFile) void {
        mem.file().close(std.testing.io);
    }
};

fn sampleSize(bits: Bits) usize {
    return switch (bits) {
        .u8 => 1,
        .u16 => 2,
        .f32 => 4,
    };
}

fn bitsArg(bits: Bits) c_int {
    return switch (bits) {
        .u8 => 8,
        .u16 => 16,
        .f32 => 32,
    };
}

/// Checks that `err` is the failure the original reported, in its short
/// (`simd`) or long (`scalar`, built with `STBI_FAILURE_USERMSG`) form.
fn reasonMatches(err: anyerror, reason: ?[*:0]const u8, path: Path) bool {
    const port_err = toStbiError(err) orelse return false;
    const theirs = std.mem.span(reason orelse return port_err == error.NoReason);
    if (port_err == error.NoReason) return false;
    const ours = switch (path) {
        .simd => stbi.failureReason(port_err),
        .scalar => stbi.failureMessage(port_err),
    };
    if (port_err == error.UnknownPngChunk and path == .simd) {
        // The original names the chunk: "abcd PNG chunk not known", which
        // a zero byte in the name cuts short.
        if (theirs.len < 4) return true;
        return theirs.len == 4 + 1 + ours.len and std.mem.eql(u8, theirs[5..], ours);
    }
    return std.mem.eql(u8, theirs, ours);
}

fn toStbiError(err: anyerror) ?stbi.Error {
    inline for (@typeInfo(stbi.Error).error_set.error_names.?) |name| {
        if (err == @field(anyerror, name)) return @field(stbi.Error, name);
    }
    return null;
}

/// Loads `bytes` with the port as `request` says, as raw bytes for the
/// comparison. The caller frees `pixels`.
fn portLoad(
    gpa: std.mem.Allocator,
    bytes: []const u8,
    request: Request,
    mem_file: ?MemFile,
    pos_after: *u64,
) !union(enum) { image: struct { owned: []u8, x: u32, y: u32, comp: u32 }, failure: anyerror } {
    switch (request.bits) {
        inline else => |bits| {
            const T = switch (bits) {
                .u8 => u8,
                .u16 => u16,
                .f32 => f32,
            };
            const result = switch (request.via) {
                .memory => stbi.loadFromMemory(T, gpa, bytes, request.options),
                .callbacks => blk: {
                    var reader: std.Io.Reader = .fixed(bytes);
                    break :blk stbi.loadFromReader(T, gpa, &reader, request.options);
                },
                .file => blk: {
                    var buffer: [512]u8 = undefined;
                    var file_reader = mem_file.?.file().reader(std.testing.io, &buffer);
                    file_reader.seekTo(request.file_offset) catch unreachable;
                    const r = stbi.loadFromFile(T, gpa, &file_reader, request.options);
                    pos_after.* = file_reader.logicalPos();
                    break :blk r;
                },
            };
            const image = result catch |err| return .{ .failure = err };
            return .{ .image = .{
                .owned = std.mem.sliceAsBytes(image.pixels),
                .x = image.width,
                .y = image.height,
                .comp = image.channels_in_file,
            } };
        },
    }
}

pub const Expect = enum {
    /// The original and the port agree.
    same,
    /// The original reads out of bounds or is undefined on this input (the
    /// sanitizer run finds these): the port must refuse it.
    port_refuses,
    /// As `same`, unless the original's result depends on memory it
    /// allocated and never wrote (it changes with what fresh allocations
    /// hold, see `readsUnwritten`): then the port must refuse the input.
    same_unless_unwritten,
    /// The original reads some pixels from memory it never wrote: both must
    /// decode, to the same size and channels; the pixels are not compared.
    same_size,
};

fn setMallocFill(path: Path, fill: c_int) void {
    switch (path) {
        .simd => upstream.simd_set_malloc_fill(fill),
        .scalar => upstream.scalar_set_malloc_fill(fill),
    }
}

/// Whether the original's result for `request` depends on memory it
/// allocated and never wrote: whether either build gives another result,
/// failure reason or file position when every allocation is filled with
/// 0x00 than when it is filled with 0xff or 0x5a. (Two fills alone can
/// agree by chance: 0x00 and 0xff both make a CMYK pixel black.)
fn readsUnwritten(bytes: []const u8, request: Request, mem_file: ?MemFile) bool {
    for ([_]c_int{ 0xff, 0x5a }) |other| {
        if (fillsDiffer(bytes, request, mem_file, .{ 0x00, other })) return true;
    }
    return false;
}

fn fillsDiffer(bytes: []const u8, request: Request, mem_file: ?MemFile, fills: [2]c_int) bool {
    var settings = request.settings();
    for ([_]Path{ .simd, .scalar }) |path| {
        var results: [2]Result = undefined;
        for (&results, fills) |*result, fill| {
            if (mem_file) |m| {
                m.seek(request.file_offset);
                settings.fd = m.fd;
            }
            setMallocFill(path, fill);
            loadFn(path)(bytes.ptr, bytes.len, bitsArg(request.bits), &settings, result);
            setMallocFill(path, -1);
        }
        defer for (results) |result| freeFn(path)(result.pixels);
        const a = results[0];
        const b = results[1];
        if ((a.pixels == null) != (b.pixels == null)) return true;
        if (a.pos_after != b.pos_after) return true;
        if (a.pixels == null) {
            const reason_a = std.mem.span(a.reason orelse "");
            const reason_b = std.mem.span(b.reason orelse "");
            if (!std.mem.eql(u8, reason_a, reason_b)) return true;
            continue;
        }
        if (a.x != b.x or a.y != b.y or a.comp != b.comp) return true;
        const req: u32 = request.options.reqComp();
        const comp: u32 = if (req != 0) req else @intCast(a.comp);
        const len = @as(usize, @intCast(a.x)) * @as(usize, @intCast(a.y)) * comp *
            sampleSize(request.bits);
        const pixels_a: [*]const u8 = @ptrCast(a.pixels.?);
        const pixels_b: [*]const u8 = @ptrCast(b.pixels.?);
        if (!std.mem.eql(u8, pixels_a[0..len], pixels_b[0..len])) return true;
    }
    return false;
}

/// The build of the original the port follows where the two give different
/// results, which only the JPEG decoder's IDCT can make (see
/// `stbi.jpeg_idct`).
const followed_path: Path = switch (stbi.jpeg_idct) {
    .scalar => .scalar,
    .sse2 => .simd,
};

/// Whether the two builds of the original give different results for
/// `bytes` loaded from memory as `request` says.
pub fn originalBuildsDisagree(bytes: []const u8, request: Request) bool {
    std.debug.assert(request.via != .file);
    const paths = [_]Path{ .simd, .scalar };
    var results: [2]Result = undefined;
    const settings = request.settings();
    for (paths, &results) |path, *theirs| {
        loadFn(path)(bytes.ptr, bytes.len, bitsArg(request.bits), &settings, theirs);
    }
    defer for (paths, results) |path, theirs| freeFn(path)(theirs.pixels);
    return buildsDisagree(results, request);
}

/// Whether the two builds of the original give different results: one
/// decodes and the other fails, or they decode to other sizes or bytes.
fn buildsDisagree(results: [2]Result, request: Request) bool {
    const a = results[0];
    const b = results[1];
    if ((a.pixels == null) != (b.pixels == null)) return true;
    if (a.pixels == null) return false;
    if (a.x != b.x or a.y != b.y or a.comp != b.comp) return true;
    const req: u32 = request.options.reqComp();
    const comp: u32 = if (req != 0) req else @intCast(a.comp);
    const len = @as(usize, @intCast(a.x)) * @as(usize, @intCast(a.y)) * comp *
        sampleSize(request.bits);
    const pixels_a: [*]const u8 = @ptrCast(a.pixels.?);
    const pixels_b: [*]const u8 = @ptrCast(b.pixels.?);
    return !std.mem.eql(u8, pixels_a[0..len], pixels_b[0..len]);
}

/// Loads `bytes` with both builds of the original and the port, and fails
/// on any difference. Where the two builds differ from each other, the port
/// is held to the one it follows.
pub fn expectLoadSame(
    gpa: std.mem.Allocator,
    bytes: []const u8,
    request: Request,
    label: Label,
    expect: Expect,
) !void {
    if (fuzz_options.sanitize) return sanitizeCall(gpa, bytes, request, label, .{ .load = expect });
    const mem_file: ?MemFile = if (request.via == .file) try MemFile.init(bytes, request.file_offset) else null;
    defer if (mem_file) |m| m.deinit();

    var port_pos: u64 = 0;
    const port = try portLoad(gpa, bytes, request, mem_file, &port_pos);
    defer switch (port) {
        .image => |image| freePort(gpa, request.bits, image.owned),
        .failure => {},
    };

    const refuse = switch (expect) {
        .same, .same_size => false,
        .port_refuses => true,
        .same_unless_unwritten => readsUnwritten(bytes, request, mem_file),
    };
    if (refuse) {
        if (port == .image) {
            const what = if (expect == .port_refuses)
                "is unsafe on"
            else
                "reads unwritten memory on";
            label.print(request, "the port decoded an input the original {s}", .{what});
            return error.TestUnexpectedResult;
        }
        return;
    }

    const paths = [_]Path{ .simd, .scalar };
    var results: [2]Result = undefined;
    var settings = request.settings();
    for (paths, &results) |path, *theirs| {
        if (mem_file) |m| {
            m.seek(request.file_offset);
            settings.fd = m.fd;
        }
        loadFn(path)(bytes.ptr, bytes.len, bitsArg(request.bits), &settings, theirs);
    }
    defer for (paths, results) |path, theirs| freeFn(path)(theirs.pixels);
    const disagree = buildsDisagree(results, request);

    for (paths, results) |path, theirs| {
        if (disagree and path != followed_path) continue;
        switch (port) {
            .failure => |err| {
                if (expect == .same_size) {
                    label.print(request, "{t}: the port fails with {t} where it must decode", .{
                        path, err,
                    });
                    return error.TestUnexpectedResult;
                }
                if (theirs.pixels != null) {
                    label.print(request, "{t}: the original decodes {d}x{d}x{d}, the port fails with {t}", .{
                        path, theirs.x, theirs.y, theirs.comp, err,
                    });
                    return error.TestUnexpectedResult;
                }
                if (!reasonMatches(err, theirs.reason, path)) {
                    label.print(request, "{t}: the original fails with \"{s}\", the port with {t}", .{
                        path, theirs.reason orelse "(null)", err,
                    });
                    return error.TestUnexpectedResult;
                }
            },
            .image => |image| {
                if (theirs.pixels == null) {
                    label.print(request, "{t}: the original fails with \"{s}\", the port decodes {d}x{d}x{d}", .{
                        path, theirs.reason orelse "(null)", image.x, image.y, image.comp,
                    });
                    return error.TestUnexpectedResult;
                }
                if (theirs.x != image.x or theirs.y != image.y or theirs.comp != image.comp) {
                    label.print(request, "{t}: size {d}x{d}x{d} against the port's {d}x{d}x{d}", .{
                        path, theirs.x, theirs.y, theirs.comp, image.x, image.y, image.comp,
                    });
                    return error.TestUnexpectedResult;
                }
                const req: u32 = request.options.reqComp();
                const comp = if (req != 0) req else image.comp;
                const len = @as(usize, image.x) * image.y * comp * sampleSize(request.bits);
                const ours = image.owned;
                const original: [*]const u8 = @ptrCast(theirs.pixels.?);
                if (ours.len != len) {
                    label.print(request, "{t}: the port gives {d} bytes, not {d}", .{ path, ours.len, len });
                    return error.TestUnexpectedResult;
                }
                const compared = if (expect == .same_size) 0 else len;
                if (std.mem.indexOfDiff(u8, original[0..compared], ours[0..compared])) |at| {
                    label.print(request, "{t}: pixel bytes differ first at byte {d} of {d}: {d} against the port's {d}", .{
                        path, at, len, original[at], ours[at],
                    });
                    return error.TestUnexpectedResult;
                }
            },
        }
        if (mem_file != null and theirs.pos_after != port_pos) {
            label.print(request, "{t}: the file is left at {d}, by the port at {d}", .{
                path, theirs.pos_after, port_pos,
            });
            return error.TestUnexpectedResult;
        }
    }
}

fn freePort(gpa: std.mem.Allocator, bits: Bits, owned: []u8) void {
    switch (bits) {
        .u8 => gpa.free(owned),
        .u16 => gpa.free(@as([]u16, @alignCast(std.mem.bytesAsSlice(u16, owned)))),
        .f32 => gpa.free(@as([]f32, @alignCast(std.mem.bytesAsSlice(f32, owned)))),
    }
}

pub const Query = enum(c_int) { info = 0, is_16_bit = 1, is_hdr = 2 };

/// Compares `stbi_info`, `stbi_is_16_bit` or `stbi_is_hdr` with the port's.
pub fn expectQuerySame(
    bytes: []const u8,
    query: Query,
    via: Via,
    label: Label,
) !void {
    const request: Request = .{ .via = via };
    if (fuzz_options.sanitize) {
        return sanitizeCall(std.testing.allocator, bytes, request, label, .{ .query = query });
    }
    const mem_file: ?MemFile = if (via == .file) try MemFile.init(bytes, 0) else null;
    defer if (mem_file) |m| m.deinit();

    var settings = request.settings();
    if (mem_file) |m| {
        m.seek(0);
        settings.fd = m.fd;
    }
    var theirs: Result = undefined;
    const r = queryFn(.simd)(bytes.ptr, bytes.len, @backingInt(query), &settings, &theirs);

    var buffer: [512]u8 = undefined;
    var reader: std.Io.Reader = .fixed(bytes);
    var file_reader: std.Io.File.Reader = if (mem_file) |m| m.file().reader(std.testing.io, &buffer) else undefined;
    switch (query) {
        .info => {
            const found: anyerror!stbi.Info = switch (via) {
                .memory => stbi.infoFromMemory(bytes),
                .callbacks => stbi.infoFromReader(&reader),
                .file => stbi.infoFromFile(&file_reader),
            };
            if (found) |info| {
                // The original's sizes are `int`s, which BMP and PSD fill
                // with the stored 32 bits; the port reports the same bits.
                const x: u32 = @bitCast(theirs.x);
                const y: u32 = @bitCast(theirs.y);
                if (r == 0 or info.width != x or info.height != y or
                    info.channels_in_file != theirs.comp)
                {
                    label.print(request, "info: {d} {d}x{d}x{d} against the port's {d}x{d}x{d}", .{
                        r, theirs.x, theirs.y, theirs.comp, info.width, info.height, info.channels_in_file,
                    });
                    return error.TestUnexpectedResult;
                }
            } else |err| {
                if (r != 0 or !reasonMatches(err, theirs.reason, .simd)) {
                    label.print(request, "info: {d} {d}x{d}x{d} \"{s}\" against the port's {t}", .{
                        r, theirs.x, theirs.y, theirs.comp, theirs.reason orelse "(null)", err,
                    });
                    return error.TestUnexpectedResult;
                }
            }
        },
        .is_16_bit, .is_hdr => {
            const found: anyerror!bool = switch (via) {
                .memory => if (query == .is_hdr) stbi.isHdrFromMemory(bytes) else stbi.is16BitFromMemory(bytes),
                .callbacks => if (query == .is_hdr) stbi.isHdrFromReader(&reader) else stbi.is16BitFromReader(&reader),
                .file => if (query == .is_hdr) stbi.isHdrFromFile(&file_reader) else stbi.is16BitFromFile(&file_reader),
            };
            const ours = try found;
            if (ours != (r != 0)) {
                label.print(request, "{t}: {d} against the port's {}", .{ query, r, ours });
                return error.TestUnexpectedResult;
            }
        },
    }
    if (mem_file != null) {
        if (file_reader.logicalPos() != theirs.pos_after) {
            label.print(request, "{t}: the file is left at {d}, by the port at {d}", .{
                query, theirs.pos_after, file_reader.logicalPos(),
            });
            return error.TestUnexpectedResult;
        }
    }
}

/// Every load and query a corpus file goes through: each bit depth and
/// component count from memory, flipped and not, and a sample through the
/// reader and from a file.
pub fn expectAllSame(gpa: std.mem.Allocator, bytes: []const u8, label: Label) !void {
    return expectAll(gpa, bytes, label, .same);
}

/// As `expectAllSame`, with every load expected as `expect` says; the
/// queries are always compared.
pub fn expectAll(gpa: std.mem.Allocator, bytes: []const u8, label: Label, expect: Expect) !void {
    for ([_]Bits{ .u8, .u16, .f32 }) |bits| {
        for (0..5) |comp| {
            try expectLoadSame(gpa, bytes, .{
                .bits = bits,
                .options = .{ .components = @fromBackingInt(@as(u3, @intCast(comp))) },
            }, label, expect);
        }
        try expectLoadSame(gpa, bytes, .{
            .bits = bits,
            .options = .{ .flip_vertically = true },
        }, label, expect);
        try expectLoadSame(gpa, bytes, .{ .bits = bits, .via = .callbacks }, label, expect);
        const from_file: Request = .{ .bits = bits, .via = .file, .file_offset = 3 };
        try expectLoadSame(gpa, bytes, from_file, label, expect);
    }
    for ([_]Query{ .info, .is_16_bit, .is_hdr }) |query| {
        for ([_]Via{ .memory, .callbacks, .file }) |via| try expectQuerySame(bytes, query, via, label);
    }
}

fn loadGifFn(path: Path) *const fn ([*]const u8, usize, *const Settings, *Result) callconv(.c) void {
    return switch (path) {
        .simd => &upstream.simd_load_gif,
        .scalar => &upstream.scalar_load_gif,
    };
}

/// Compares `stbi_load_gif_from_memory` with `loadGifFromMemory`: the frame
/// count, size, channels, delays and every byte of every frame.
pub fn expectGifSame(
    gpa: std.mem.Allocator,
    bytes: []const u8,
    options: stbi.Options,
    label: Label,
) !void {
    const request: Request = .{ .options = options };
    if (fuzz_options.sanitize) return sanitizeCall(gpa, bytes, request, label, .gif);
    const settings = request.settings();
    const port = stbi.loadGifFromMemory(gpa, bytes, options);
    defer if (port) |animation| {
        var copy = animation;
        copy.deinit(gpa);
    } else |_| {};
    const req: u32 = options.reqComp();
    if (options.flip_vertically and req != 0 and req != 4) {
        // The original flips every frame as 4 components, whatever it
        // converted them to: past the end of its buffer when it decoded rows
        // to swap. Find out, without the flip, whether it would.
        var unflipped = request;
        unflipped.options.flip_vertically = false;
        const probe_settings = unflipped.settings();
        var probe: Result = undefined;
        upstream.simd_load_gif(bytes.ptr, bytes.len, &probe_settings, &probe);
        upstream.simd_free(probe.pixels);
        upstream.simd_free(@ptrCast(probe.delays));
        if (probe.pixels != null and probe.z > 0 and probe.x > 0 and probe.y >= 2) {
            if (port) |_| {
                label.print(request, "gif: the port flipped what the original flips past its buffer", .{});
                return error.TestUnexpectedResult;
            } else |_| return;
        }
    }
    for ([_]Path{ .simd, .scalar }) |path| {
        var theirs: Result = undefined;
        loadGifFn(path)(bytes.ptr, bytes.len, &settings, &theirs);
        defer freeFn(path)(theirs.pixels);
        defer freeFn(path)(@ptrCast(theirs.delays));
        // When the first frame fails and other components than 4 are asked
        // for, the original converts its null result, an image of no
        // columns, into an empty buffer with no frames: a failure.
        const theirs_failed = theirs.pixels == null or theirs.z == 0;
        if (port) |animation| {
            if (theirs_failed) {
                label.print(request, "gif {t}: the original fails with \"{s}\", the port decodes {d} frames", .{
                    path, theirs.reason orelse "(null)", animation.frames,
                });
                return error.TestUnexpectedResult;
            }
            if (theirs.x != animation.width or theirs.y != animation.height or theirs.z != animation.frames) {
                label.print(request, "gif {t}: {d}x{d}, {d} frames against the port's {d}x{d}, {d}", .{
                    path, theirs.x, theirs.y, theirs.z, animation.width, animation.height, animation.frames,
                });
                return error.TestUnexpectedResult;
            }
            const channels: u32 = if (req != 0) req else 4;
            const len = @as(usize, animation.width) * animation.height * animation.frames * channels;
            const original: [*]const u8 = @ptrCast(theirs.pixels.?);
            if (animation.channels != channels or animation.pixels.len != len or
                !std.mem.eql(u8, original[0..len], animation.pixels))
            {
                label.print(request, "gif {t}: the frames differ", .{path});
                return error.TestUnexpectedResult;
            }
            for (animation.delays_ms, 0..) |delay, i| {
                if (theirs.delays.?[i] != delay) {
                    label.print(request, "gif {t}: delay {d} is {d}, the port's {d}", .{
                        path, i, theirs.delays.?[i], delay,
                    });
                    return error.TestUnexpectedResult;
                }
            }
        } else |err| {
            if (!theirs_failed) {
                label.print(request, "gif {t}: the original decodes {d} frames, the port fails with {t}", .{
                    path, theirs.z, err,
                });
                return error.TestUnexpectedResult;
            }
            if (!reasonMatches(err, theirs.reason, path)) {
                label.print(request, "gif {t}: the original fails with \"{s}\", the port with {t}", .{
                    path, theirs.reason orelse "(null)", err,
                });
                return error.TestUnexpectedResult;
            }
        }
    }
}


// ---- The sanitizer run ----------------------------------------------------

const SanitizeCall = union(enum) { load: Expect, query: Query, gif };

/// Under `zig build sanitize`: runs `call` through both builds of the
/// original, built with AddressSanitizer and UndefinedBehaviorSanitizer, in
/// child processes (see `runOriginal`). For each build a sanitizer flags,
/// it prints a `stbi-flagged:` line with what the port does on the same
/// input and request, so `tools/sanitize.sh` can list the flagged calls the
/// port accepts. Every call first prints a `stbi-call:` line, to be counted.
fn sanitizeCall(
    gpa: std.mem.Allocator,
    bytes: []const u8,
    request: Request,
    label: Label,
    call: SanitizeCall,
) !void {
    var label_buffer: [256]u8 = undefined;
    const text = try sanitizeLabel(&label_buffer, label, request, call);
    const number = sanitizeStart(text);
    const original: OriginalCall = .{ .bytes = bytes, .request = request, .call = call };
    const flags = try runOriginal(OriginalCall, &original, OriginalCall.run, &.{ .simd, .scalar });
    if (!flags.any()) return;
    var outcome_buffer: [64]u8 = undefined;
    const outcome = try portOutcome(gpa, &outcome_buffer, bytes, request, call);
    flags.print(number, text, outcome);
}

/// The call's name in the sanitizer's report: the input, the call and the
/// request, and for loads what the test expects of the port.
fn sanitizeLabel(buffer: []u8, label: Label, request: Request, call: SanitizeCall) ![]const u8 {
    const o = request.options;
    var writer: std.Io.Writer = .fixed(buffer);
    try writer.print("{s}", .{label.name});
    if (label.seed) |seed| try writer.print(" seed {d}", .{seed});
    if (label.case) |case| try writer.print(" case {d}", .{case});
    switch (call) {
        .load => |expect| try writer.print(
            ": load {t} via {t}, components {t}, flip {}, expect {t}",
            .{ request.bits, request.via, o.components, o.flip_vertically, expect },
        ),
        .query => |query| try writer.print(": {t} via {t}", .{ query, request.via }),
        .gif => try writer.print(": gif, components {t}, flip {}", .{
            o.components, o.flip_vertically,
        }),
    }
    return writer.buffered();
}

/// The calls of the sanitizer run so far. The labels of hand-made inputs
/// repeat, so each call is told apart by its number.
var sanitize_calls: u64 = 0;

/// Prints the `stbi-call:` line that counts a call of the sanitizer run,
/// and returns the call's number.
pub fn sanitizeStart(label: []const u8) u64 {
    sanitize_calls += 1;
    std.debug.print("stbi-call: #{d} {s}\n", .{ sanitize_calls, label });
    return sanitize_calls;
}

/// One call to the original, as a child process of the sanitizer run makes
/// it. Files are read as callbacks: the original reads both the same way,
/// and the child needs no descriptors.
const OriginalCall = struct {
    bytes: []const u8,
    request: Request,
    call: SanitizeCall,

    fn run(original: *const OriginalCall, path: Path) void {
        const bytes = original.bytes;
        var settings = original.request.settings();
        if (original.request.via == .file) settings.via = @backingInt(Via.callbacks);
        var theirs: Result = undefined;
        switch (original.call) {
            .load => {
                const bits = bitsArg(original.request.bits);
                loadFn(path)(bytes.ptr, bytes.len, bits, &settings, &theirs);
                freeFn(path)(theirs.pixels);
            },
            .query => |query| {
                _ = queryFn(path)(bytes.ptr, bytes.len, @backingInt(query), &settings, &theirs);
            },
            .gif => {
                loadGifFn(path)(bytes.ptr, bytes.len, &settings, &theirs);
                freeFn(path)(theirs.pixels);
                freeFn(path)(@ptrCast(theirs.delays));
            },
        }
    }
};

/// What the port does on a flagged call: "refuses error.X", "accepts" and
/// the size, or for the yes-or-no queries "answers" and the answer.
fn portOutcome(
    gpa: std.mem.Allocator,
    buffer: []u8,
    bytes: []const u8,
    request: Request,
    call: SanitizeCall,
) ![]const u8 {
    const mem_file: ?MemFile = if (request.via == .file)
        try MemFile.init(bytes, request.file_offset)
    else
        null;
    defer if (mem_file) |m| m.deinit();
    var file_buffer: [512]u8 = undefined;
    var file_reader: std.Io.File.Reader = undefined;
    if (mem_file) |m| {
        file_reader = m.file().reader(std.testing.io, &file_buffer);
        try file_reader.seekTo(request.file_offset);
    }
    var reader: std.Io.Reader = .fixed(bytes);
    switch (call) {
        .load => {
            var pos_after: u64 = 0;
            switch (try portLoad(gpa, bytes, request, mem_file, &pos_after)) {
                .image => |image| {
                    defer freePort(gpa, request.bits, image.owned);
                    const size = .{ image.x, image.y, image.comp };
                    return std.fmt.bufPrint(buffer, "accepts {d}x{d}x{d}", size);
                },
                .failure => |err| return refusal(buffer, err),
            }
        },
        .query => |query| switch (query) {
            .info => {
                const found: anyerror!stbi.Info = switch (request.via) {
                    .memory => stbi.infoFromMemory(bytes),
                    .callbacks => stbi.infoFromReader(&reader),
                    .file => stbi.infoFromFile(&file_reader),
                };
                const info = found catch |err| return refusal(buffer, err);
                const size = .{ info.width, info.height, info.channels_in_file };
                return std.fmt.bufPrint(buffer, "accepts {d}x{d}x{d}", size);
            },
            .is_16_bit, .is_hdr => {
                const found: anyerror!bool = if (query == .is_hdr) switch (request.via) {
                    .memory => stbi.isHdrFromMemory(bytes),
                    .callbacks => stbi.isHdrFromReader(&reader),
                    .file => stbi.isHdrFromFile(&file_reader),
                } else switch (request.via) {
                    .memory => stbi.is16BitFromMemory(bytes),
                    .callbacks => stbi.is16BitFromReader(&reader),
                    .file => stbi.is16BitFromFile(&file_reader),
                };
                const answer = found catch |err| return refusal(buffer, err);
                return std.fmt.bufPrint(buffer, "answers {}", .{answer});
            },
        },
        .gif => {
            var animation = stbi.loadGifFromMemory(gpa, bytes, request.options) catch |err|
                return refusal(buffer, err);
            defer animation.deinit(gpa);
            return std.fmt.bufPrint(buffer, "accepts {d} frames", .{animation.frames});
        },
    }
}

/// "refuses" and the error's name, in `buffer`.
pub fn refusal(buffer: []u8, err: anyerror) ![]const u8 {
    return std.fmt.bufPrint(buffer, "refuses {t}", .{err});
}

/// What a sanitizer reported on one build of the original: the kind of
/// error, the access for a memory error, and the first frame in the
/// original, as the library and offset `tools/sanitize.sh` symbolizes; or
/// how the child ended when it printed no report.
pub const Report = struct {
    buffer: [320]u8 = undefined,
    len: usize = 0,

    pub fn text(report: *const Report) []const u8 {
        return report.buffer[0..report.len];
    }
};

/// The reports of the builds a sanitizer flagged on one call.
pub const Flags = struct {
    reports: std.EnumArray(Path, ?Report) = .initFill(null),

    pub fn any(flags: *const Flags) bool {
        for (flags.reports.values) |report| if (report != null) return true;
        return false;
    }

    /// One `stbi-flagged:` line per flagged build: the call's number and
    /// label, the build, the report and what the port does (`outcome`).
    pub fn print(flags: *const Flags, number: u64, label: []const u8, outcome: []const u8) void {
        for (std.enums.values(Path)) |path| {
            const report = flags.reports.getPtrConst(path).* orelse continue;
            std.debug.print("stbi-flagged: #{d} {s} | {t} | {s} | port {s}\n", .{
                number, label, path, report.text(), outcome,
            });
        }
    }
};

/// The seconds a child may run before it is stopped and counted as
/// flagged: the original loops for ever on some inputs (a zlib initial
/// size of 0); every other call takes a small part of that.
const child_seconds = 20;

/// Runs `call(context, path)` for each of `builds` in a child process with
/// the sanitizers set to stop at the first report, so a flag ends the child
/// with a non-zero status, and an overrun cannot corrupt the calls after
/// it. One child runs every build in turn; after a flag, a new child runs
/// the builds after the flagged one. Each child's error output comes back
/// through a pipe, so a report is never paired with another call.
pub fn runOriginal(
    comptime Context: type,
    context: *const Context,
    comptime call: fn (*const Context, Path) void,
    builds: []const Path,
) !Flags {
    var flags: Flags = .{};
    var next: usize = 0;
    while (next < builds.len) {
        const flag = try runChild(Context, context, call, builds[next..]) orelse break;
        flags.reports.set(builds[next + flag.index], flag.report);
        next += flag.index + 1;
    }
    return flags;
}

const ChildFlag = struct {
    /// Which of the child's builds was flagged.
    index: usize,
    report: Report,
};

/// Written by the child before each build's call, so the parent can tell
/// which build a report belongs to.
const build_marker = "stbi-build\n";

fn runChild(
    comptime Context: type,
    context: *const Context,
    comptime call: fn (*const Context, Path) void,
    builds: []const Path,
) !?ChildFlag {
    var fds: [2]std.c.fd_t = undefined;
    if (std.c.pipe(&fds) != 0) return error.PipeFailed;
    const pid = std.c.fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) {
        _ = std.c.close(fds[0]);
        _ = std.c.dup2(fds[1], std.posix.STDERR_FILENO);
        _ = std.c.close(fds[1]);
        _ = std.c.alarm(child_seconds);
        for (builds) |build| {
            _ = std.c.write(std.posix.STDERR_FILENO, build_marker, build_marker.len);
            call(context, build);
        }
        std.c._exit(0);
    }
    _ = std.c.close(fds[1]);
    // The report comes first; a long stack trace past the buffer is dropped.
    var output: [16384]u8 = undefined;
    var len: usize = 0;
    var drain: [4096]u8 = undefined;
    while (true) {
        const into = if (len < output.len) output[len..] else &drain;
        const n = std.c.read(fds[0], into.ptr, into.len);
        if (n <= 0) break;
        if (len < output.len) len += @intCast(n);
    }
    _ = std.c.close(fds[0]);
    var status: c_int = 0;
    if (std.c.waitpid(pid, &status, 0) != pid) return error.WaitFailed;
    const bits: u32 = @bitCast(status);
    const text = output[0..len];
    const exited_clean = std.os.linux.W.IFEXITED(bits) and std.os.linux.W.EXITSTATUS(bits) == 0;
    if (exited_clean and firstLine(text, &report_starts) == null) return null;
    const markers = std.mem.count(u8, text, build_marker);
    const index = @min(builds.len, @max(markers, 1)) - 1;
    const last_marker = std.mem.lastIndexOf(u8, text, build_marker);
    const after = if (last_marker) |at| text[at + build_marker.len ..] else text;
    return .{ .index = index, .report = parseReport(after, bits) };
}

/// The first line of every report kind the sanitizers print.
const report_starts = [_][]const u8{
    "ERROR: AddressSanitizer",
    "runtime error:",
    "AddressSanitizer: CHECK",
};

/// The first line of `text` that holds one of `needles`.
fn firstLine(text: []const u8, needles: []const []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        for (needles) |needle| if (std.mem.indexOf(u8, line, needle) != null) return line;
    }
    return null;
}

/// Shortens a child's output to a `Report`: the report's kind without its
/// addresses (for UndefinedBehaviorSanitizer, the source position and the
/// message), the access, and the first frame in the original's library.
fn parseReport(text: []const u8, status: u32) Report {
    var report: Report = .{};
    var writer: std.Io.Writer = .fixed(&report.buffer);
    // A full buffer only cuts the text short.
    describeReport(&writer, text, status) catch {};
    report.len = writer.end;
    return report;
}

fn describeReport(writer: *std.Io.Writer, text: []const u8, status: u32) !void {
    const W = std.os.linux.W;
    const line = firstLine(text, &report_starts) orelse {
        if (W.IFSIGNALED(status)) {
            const signal = W.TERMSIG(status);
            const what = if (signal == .ALRM) "timed out" else "died";
            try writer.print("{s}, signal {d}", .{ what, @backingInt(signal) });
        } else {
            try writer.print("exited with {d}", .{W.EXITSTATUS(status)});
        }
        // Whatever else the child printed, such as a failed assert.
        var lines = std.mem.tokenizeScalar(u8, text, '\n');
        const first = lines.next() orelse return writer.print(", no output", .{});
        return writer.print(": {s}", .{first});
    };
    if (std.mem.indexOf(u8, line, "runtime error:")) |at| {
        // "<dir>/stb_image.h:1234:5: runtime error: ...": the file's own name.
        const position = line[0..at];
        const slash = std.mem.lastIndexOfScalar(u8, position, '/');
        const name = if (slash) |i| position[i + 1 ..] else position;
        try writer.print("{s}{s}", .{ name, line[at..] });
    } else {
        const start = std.mem.indexOf(u8, line, "AddressSanitizer").?;
        var kind = line[start..];
        for ([_][]const u8{ " on ", " at ", " (", " \"" }) |cut| {
            if (std.mem.indexOf(u8, kind, cut)) |at| kind = kind[0..at];
        }
        try writer.print("{s}", .{kind});
        if (firstLine(text, &.{ "READ of size", "WRITE of size" })) |access| {
            const from = std.mem.indexOf(u8, access, "READ") orelse
                std.mem.indexOf(u8, access, "WRITE").?;
            var what = access[from..];
            if (std.mem.indexOf(u8, what, " at ")) |at| what = what[0..at];
            try writer.print(", {s}", .{what});
        }
    }
    if (firstLine(text, &.{original_library ++ "+0x"})) |frame| {
        const at = std.mem.indexOf(u8, frame, original_library).?;
        const end = std.mem.indexOfScalarPos(u8, frame, at, ')') orelse frame.len;
        try writer.print(", in {s}", .{frame[at..end]});
    }
}

/// The sanitizer build of the original, as `build.zig` names it.
const original_library = "libstb_image_sanitize.so";
