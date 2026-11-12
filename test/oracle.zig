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
};

fn loadFn(path: Path) *const fn ([*]const u8, usize, c_int, *const Settings, *Result) callconv(.c) void {
    return switch (path) {
        .simd => &upstream.simd_load,
        .scalar => &upstream.scalar_load,
    };
}

fn freeFn(path: Path) *const fn (?*anyopaque) callconv(.c) void {
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
        // The original names the chunk: "abcd PNG chunk not known".
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
};

/// Loads `bytes` with both builds of the original and the port, and fails
/// on any difference.
pub fn expectLoadSame(
    gpa: std.mem.Allocator,
    bytes: []const u8,
    request: Request,
    label: Label,
    expect: Expect,
) !void {
    if (fuzz_options.sanitize) return sanitizeCall(bytes, request, label, "load", .load);
    const mem_file: ?MemFile = if (request.via == .file) try MemFile.init(bytes, request.file_offset) else null;
    defer if (mem_file) |m| m.deinit();

    var port_pos: u64 = 0;
    const port = try portLoad(gpa, bytes, request, mem_file, &port_pos);
    defer switch (port) {
        .image => |image| freePort(gpa, request.bits, image.owned),
        .failure => {},
    };

    if (expect == .port_refuses) {
        if (port == .image) {
            label.print(request, "the port decoded an input the original is unsafe on", .{});
            return error.TestUnexpectedResult;
        }
        return;
    }

    var settings = request.settings();
    for ([_]Path{ .simd, .scalar }) |path| {
        if (mem_file) |m| {
            m.seek(request.file_offset);
            settings.fd = m.fd;
        }
        var theirs: Result = undefined;
        loadFn(path)(bytes.ptr, bytes.len, bitsArg(request.bits), &settings, &theirs);
        defer freeFn(path)(theirs.pixels);

        switch (port) {
            .failure => |err| {
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
                if (std.mem.indexOfDiff(u8, original[0..len], ours)) |at| {
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
    if (fuzz_options.sanitize) return sanitizeCall(bytes, request, label, @tagName(query), .{ .query = query });
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
        try expectLoadSame(gpa, bytes, .{ .bits = bits, .via = .file, .file_offset = 3 }, label, expect);
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
    if (fuzz_options.sanitize) return sanitizeCall(bytes, request, label, "gif", .gif);
    const settings = request.settings();
    const port = stbi.loadGifFromMemory(gpa, bytes, options);
    defer if (port) |animation| {
        var copy = animation;
        copy.deinit(gpa);
    } else |_| {};
    for ([_]Path{ .simd, .scalar }) |path| {
        var theirs: Result = undefined;
        loadGifFn(path)(bytes.ptr, bytes.len, &settings, &theirs);
        defer freeFn(path)(theirs.pixels);
        defer freeFn(path)(@ptrCast(theirs.delays));
        if (port) |animation| {
            if (theirs.pixels == null) {
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
            const req: u32 = options.reqComp();
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
            if (theirs.pixels != null) {
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

const SanitizeCall = union(enum) { load, query: Query, gif };

/// Under `zig build sanitize`: names the call on stderr, then runs only the
/// original, built with AddressSanitizer and UndefinedBehaviorSanitizer,
/// whose reports follow the name. `tools/sanitize.sh` pairs them up.
fn sanitizeCall(
    bytes: []const u8,
    request: Request,
    label: Label,
    call_name: []const u8,
    call: SanitizeCall,
) !void {
    std.debug.print("stbi-case: {s} seed {?d} case {?d} call {s} | {t} via {t} components {t} flip {}\n", .{
        label.name,
        label.seed,
        label.case,
        call_name,
        request.bits,
        request.via,
        request.options.components,
        request.options.flip_vertically,
    });
    // Files go through memory here: the original reads them as it reads
    // callbacks, and the sanitizer run needs no descriptors.
    var settings = request.settings();
    if (request.via == .file) settings.via = @backingInt(Via.callbacks);
    for ([_]Path{ .simd, .scalar }) |path| {
        var theirs: Result = undefined;
        switch (call) {
            .load => {
                loadFn(path)(bytes.ptr, bytes.len, bitsArg(request.bits), &settings, &theirs);
                freeFn(path)(theirs.pixels);
            },
            .query => |query| _ = queryFn(path)(bytes.ptr, bytes.len, @backingInt(query), &settings, &theirs),
            .gif => {
                loadGifFn(path)(bytes.ptr, bytes.len, &settings, &theirs);
                freeFn(path)(theirs.pixels);
                freeFn(path)(@ptrCast(theirs.delays));
            },
        }
    }
}
