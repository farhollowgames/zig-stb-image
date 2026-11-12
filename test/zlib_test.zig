//! The zlib decoder against the original's six `stbi_zlib_decode_*`
//! functions: the same bytes, length and failure reason, and for the
//! fixed-buffer forms the same buffer contents, also after a failure.

const std = @import("std");
const stbi = @import("stb_image");
const oracle = @import("oracle.zig");
const fuzz = @import("fuzz.zig");
const corpus = @import("corpus.zig");
const deflate = @import("deflate.zig");
const fuzz_options = @import("fuzz_options");

const zlib = stbi.zlib;
const gpa = std.testing.allocator;

/// The original's functions, in the order of `oracle.c`'s `which`.
const Function = enum(c_int) {
    malloc_guesssize = 0,
    malloc = 1,
    malloc_guesssize_headerflag = 2,
    buffer = 3,
    noheader_malloc = 4,
    noheader_buffer = 5,

    fn isBuffer(function: Function) bool {
        return function == .buffer or function == .noheader_buffer;
    }
};

const Call = struct {
    function: Function,
    /// For the guess-size forms.
    initial_size: u32 = 16384,
    /// For `malloc_guesssize_headerflag`.
    parse_header: bool = true,
    /// For the buffer forms.
    buffer_len: usize = 0,
};

const Outcome = union(enum) {
    bytes: []const u8,
    failure: ?[]const u8,
};

/// Runs `call` on `input` with the original and the port, and fails on any
/// difference.
fn expectSame(input: []const u8, call: Call, label: []const u8) !void {
    // Each buffer has bytes past the length it is given, which must stay
    // as they are, and never a zero-length allocation's address.
    const whole_theirs = try gpa.alloc(u8, call.buffer_len + 16);
    defer gpa.free(whole_theirs);
    const whole_ours = try gpa.alloc(u8, call.buffer_len + 16);
    defer gpa.free(whole_ours);
    @memset(whole_theirs, 0xa5);
    @memset(whole_ours, 0xa5);
    const buffer_theirs = whole_theirs[0..call.buffer_len];
    const buffer_ours = whole_ours[0..call.buffer_len];

    if (fuzz_options.sanitize) return sanitize(input, call, label, buffer_theirs, buffer_ours);
    var outlen: c_int = 0;
    var reason: ?[*:0]const u8 = null;
    const returned = originalDecode(input, call, buffer_theirs, &outlen, &reason);
    defer oracle.upstream.simd_free(returned);

    const theirs: Outcome = if (call.function.isBuffer())
        (if (outlen >= 0)
            .{ .bytes = buffer_theirs[0..@intCast(outlen)] }
        else
            .{ .failure = span(reason) })
    else if (returned) |p|
        .{ .bytes = p[0..@intCast(outlen)] }
    else
        .{ .failure = span(reason) };

    var owned: ?[]u8 = null;
    defer if (owned) |o| gpa.free(o);
    const result = portDecode(input, call, buffer_ours);
    const ours: Outcome = if (result) |bytes| blk: {
        if (!call.function.isBuffer()) owned = @constCast(bytes);
        break :blk .{ .bytes = bytes };
    } else |err| .{ .failure = if (err == error.NoReason) null else stbi.failureReason(err) };

    switch (theirs) {
        .bytes => |bytes| switch (ours) {
            .bytes => |port_bytes| if (std.mem.indexOfDiff(u8, bytes, port_bytes)) |at| {
                std.debug.print("\n[{s}] {t}: {d} bytes against the port's {d}, " ++
                    "first difference at {d}\n", .{
                    label, call.function, bytes.len, port_bytes.len, at,
                });
                return error.TestUnexpectedResult;
            },
            .failure => |port_reason| {
                std.debug.print("\n[{s}] {t}: the original decodes {d} bytes, " ++
                    "the port fails with \"{s}\"\n", .{
                    label, call.function, bytes.len, port_reason orelse "(null)",
                });
                return error.TestUnexpectedResult;
            },
        },
        .failure => |their_reason| switch (ours) {
            .bytes => |port_bytes| {
                std.debug.print("\n[{s}] {t}: the original fails with \"{s}\", " ++
                    "the port decodes {d} bytes\n", .{
                    label, call.function, their_reason orelse "(null)", port_bytes.len,
                });
                return error.TestUnexpectedResult;
            },
            .failure => |port_reason| {
                const same = if (their_reason) |r|
                    port_reason != null and std.mem.eql(u8, r, port_reason.?)
                else
                    port_reason == null;
                if (!same) {
                    std.debug.print("\n[{s}] {t}: the original fails with \"{s}\", " ++
                        "the port with \"{s}\"\n", .{
                        label,
                        call.function,
                        their_reason orelse "(null)",
                        port_reason orelse "(null)",
                    });
                    return error.TestUnexpectedResult;
                }
            },
        },
    }
    if (std.mem.indexOfDiff(u8, whole_theirs, whole_ours)) |at| {
        std.debug.print("\n[{s}] {t}: the buffers differ at {d}: {d} against the port's {d}\n", .{
            label, call.function, at, whole_theirs[at], whole_ours[at],
        });
        return error.TestUnexpectedResult;
    }
}

/// The original's `call` on `input`. The caller frees the result.
fn originalDecode(
    input: []const u8,
    call: Call,
    buffer: []u8,
    outlen: *c_int,
    reason: *?[*:0]const u8,
) ?[*]u8 {
    return oracle.upstream.simd_zlib(
        @backingInt(call.function),
        input.ptr,
        @intCast(input.len),
        @intCast(call.initial_size),
        @intFromBool(call.parse_header),
        buffer.ptr,
        @intCast(call.buffer_len),
        outlen,
        reason,
    );
}

/// The port's `call` on `input`. The caller frees the result unless the
/// call writes into `buffer`.
fn portDecode(input: []const u8, call: Call, buffer: []u8) zlib.Error![]const u8 {
    return switch (call.function) {
        .malloc_guesssize => zlib.decodeAlloc(gpa, input, .{ .initial_size = call.initial_size }),
        .malloc => zlib.decodeAlloc(gpa, input, .{}),
        .malloc_guesssize_headerflag => zlib.decodeAlloc(gpa, input, .{
            .initial_size = call.initial_size,
            .parse_header = call.parse_header,
        }),
        .noheader_malloc => zlib.decodeAlloc(gpa, input, .{ .parse_header = false }),
        .buffer, .noheader_buffer => blk: {
            const header = call.function == .buffer;
            const n = zlib.decodeBuffer(buffer, input, .{ .parse_header = header }) catch |err|
                break :blk err;
            break :blk buffer[0..n];
        },
    };
}

/// Under `zig build sanitize`: the original's `call` in a child process,
/// and where a sanitizer flags it, what the port does (see
/// `oracle.sanitizeCall`). The zlib code is the same in both builds of the
/// original, so only one runs.
fn sanitize(
    input: []const u8,
    call: Call,
    label: []const u8,
    buffer_theirs: []u8,
    buffer_ours: []u8,
) !void {
    var label_buffer: [256]u8 = undefined;
    const text = try std.fmt.bufPrint(
        &label_buffer,
        "{s}: zlib {t}, initial {d}, header {}, buffer {d}",
        .{ label, call.function, call.initial_size, call.parse_header, call.buffer_len },
    );
    oracle.sanitizeStart(text);
    const Original = struct {
        input: []const u8,
        call: Call,
        buffer: []u8,

        fn run(context: *const @This(), _: oracle.Path) void {
            var outlen: c_int = 0;
            var reason: ?[*:0]const u8 = null;
            const c = context;
            oracle.upstream.simd_free(originalDecode(c.input, c.call, c.buffer, &outlen, &reason));
        }
    };
    const context: Original = .{ .input = input, .call = call, .buffer = buffer_theirs };
    const flags = try oracle.runOriginal(Original, &context, Original.run, &.{.simd});
    if (!flags.any()) return;
    var outcome_buffer: [64]u8 = undefined;
    const outcome = if (portDecode(input, call, buffer_ours)) |bytes| blk: {
        if (!call.function.isBuffer()) gpa.free(bytes);
        break :blk try std.fmt.bufPrint(&outcome_buffer, "accepts {d} bytes", .{bytes.len});
    } else |err| try oracle.refusal(&outcome_buffer, err);
    flags.print(text, outcome);
}

fn span(reason: ?[*:0]const u8) ?[]const u8 {
    return if (reason) |r| std.mem.span(r) else null;
}

/// Every function on `input`, with growing buffers that start at several
/// sizes, and fixed ones of the exact length, one short, half and empty.
/// `expected_len` is the stream's output length, when it decodes.
fn expectAllSame(input: []const u8, expected_len: usize, header: bool, label: []const u8) !void {
    const growing = [_]Function{
        .malloc,
        .malloc_guesssize,
        .malloc_guesssize_headerflag,
        .noheader_malloc,
    };
    const exact: u32 = @intCast(expected_len);
    for (growing) |function| {
        for ([_]u32{ 1, 2, 7, 100, 16384, exact }) |initial_size| {
            if (initial_size == 0) continue;
            try expectSame(input, .{
                .function = function,
                .initial_size = initial_size,
                .parse_header = header,
            }, label);
        }
    }
    for ([_]Function{ .buffer, .noheader_buffer }) |function| {
        const lengths = [_]usize{
            expected_len,
            expected_len -| 1,
            expected_len / 2,
            0,
            expected_len + 100,
        };
        for (lengths) |buffer_len| {
            try expectSame(input, .{ .function = function, .buffer_len = buffer_len }, label);
        }
    }
}

/// The length `input` decodes to, or a small one if it fails.
fn decodedLength(input: []const u8, header: bool) usize {
    const bytes = zlib.decodeAlloc(gpa, input, .{ .parse_header = header }) catch return 40;
    defer gpa.free(bytes);
    return bytes.len;
}

/// The checks for one truncation of a stream: a growing buffer from a
/// small start, and a fixed one.
fn expectTruncationSame(input: []const u8, header: bool, label: []const u8) !void {
    const growing: Function = if (header) .malloc_guesssize else .noheader_malloc;
    const fixed_buffer: Function = if (header) .buffer else .noheader_buffer;
    try expectSame(input, .{ .function = growing, .initial_size = 8 }, label);
    try expectSame(input, .{ .function = fixed_buffer, .buffer_len = 64 }, label);
}

/// Test data: text, runs, periods, random bytes, matches at the longest
/// distances, and skewed bytes whose rare values get codes past 9 bits.
fn samples(arena: std.mem.Allocator) ![]const []const u8 {
    var prng: std.Random.DefaultPrng = .init(0x2a71b);
    const rng = prng.random();
    var list: std.ArrayList([]const u8) = .empty;
    try list.appendSlice(arena, &.{ "", "a", "abc", "hello hello hello hello, said the stream" });

    const random = try arena.alloc(u8, 1000);
    rng.bytes(random);
    try list.append(arena, random);

    const zeros = try arena.alloc(u8, 70000);
    @memset(zeros, 0);
    try list.append(arena, zeros);

    const periodic = try arena.alloc(u8, 35000);
    for (periodic, 0..) |*b, i| b.* = "abcdefg"[i % 7];
    try list.append(arena, periodic);

    const far = try arena.alloc(u8, 40000);
    rng.bytes(far[0..20000]);
    @memcpy(far[20000..], far[0..20000]);
    try list.append(arena, far);

    const every = try arena.alloc(u8, 256 * 3);
    for (every, 0..) |*b, i| b.* = @truncate(i);
    try list.append(arena, every);

    const skewed = try arena.alloc(u8, 6000);
    for (skewed) |*b| b.* = if (rng.uintLessThan(u32, 100) < 93) 'a' else rng.int(u8);
    try list.append(arena, skewed);

    return list.toOwnedSlice(arena);
}

/// `data` compressed every way the tests use: stored, fixed and dynamic
/// blocks in several block sizes, and std's compressor.
fn encodings(arena: std.mem.Allocator, data: []const u8, zlib_container: bool) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    const configs = [_]deflate.Options{
        .{ .kind = .stored },
        .{ .kind = .stored, .block_size = 1000 },
        .{ .kind = .fixed },
        .{ .kind = .fixed, .block_size = 4096 },
        .{ .kind = .dynamic },
        .{ .kind = .dynamic, .block_size = 100 },
        .{ .kind = .dynamic, .window = 300 },
    };
    for (configs) |config| {
        var options = config;
        options.zlib = zlib_container;
        try list.append(arena, try deflate.compress(arena, data, options));
    }
    for ([_]std.compress.flate.Compress.Options{ .fastest, .default, .best }) |level| {
        try list.append(arena, try stdCompress(arena, data, zlib_container, level));
    }
    return list.toOwnedSlice(arena);
}

fn stdCompress(
    arena: std.mem.Allocator,
    data: []const u8,
    zlib_container: bool,
    level: std.compress.flate.Compress.Options,
) ![]u8 {
    var out: std.Io.Writer.Allocating = try .initCapacity(arena, 1024);
    const window = try arena.alloc(u8, std.compress.flate.max_window_len);
    var compressor: std.compress.flate.Compress = try .init(
        &out.writer,
        window,
        if (zlib_container) .zlib else .raw,
        level,
    );
    try compressor.writer.writeAll(data);
    try compressor.finish();
    return out.toOwnedSlice();
}

test "zlib: every block type and block size decodes as in the original, through all six functions" {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for (try samples(arena), 0..) |data, i| {
        for ([_]bool{ true, false }) |header| {
            for (try encodings(arena, data, header), 0..) |encoded, k| {
                const label = try std.fmt.allocPrint(arena, "sample {d} encoding {d} header {}", .{
                    i, k, header,
                });
                try expectAllSame(encoded, data.len, header, label);
            }
        }
    }
}

/// A stream from `bits`: header, then hand-written blocks.
fn handMade(
    arena: std.mem.Allocator,
    header: bool,
    comptime write: fn (*deflate.BitWriter) anyerror!void,
) ![]u8 {
    var w: deflate.BitWriter = .init(arena);
    if (header) {
        try w.byte(0x78);
        try w.byte(0x01);
    }
    try write(&w);
    return w.finish();
}

/// Fixed-code helpers for hand-made blocks.
const fixed = struct {
    const lengths = deflate.fixedLengths();
    const codes = blk: {
        var c: [288]u16 = undefined;
        deflate.canonical(&lengths, &c);
        break :blk c;
    };

    fn symbol(w: *deflate.BitWriter, s: u16) !void {
        try w.code(codes[s], @intCast(lengths[s]));
    }

    fn distance(w: *deflate.BitWriter, s: u16) !void {
        try w.code(s, 5);
    }

    fn literals(w: *deflate.BitWriter, bytes: []const u8) !void {
        for (bytes) |b| try symbol(w, b);
    }
};

const cases = struct {
    fn typeThree(w: *deflate.BitWriter) !void {
        try w.bits(1, 1);
        try w.bits(3, 2);
    }
    fn storedBadNlen(w: *deflate.BitWriter) !void {
        try w.bits(1, 1);
        try w.bits(0, 2);
        try w.alignByte();
        try w.bits(5, 16);
        try w.bits(5, 16);
    }
    fn storedPastEnd(w: *deflate.BitWriter) !void {
        try w.bits(1, 1);
        try w.bits(0, 2);
        try w.alignByte();
        try w.bits(10, 16);
        try w.bits(~@as(u16, 10), 16);
        for ("abc") |b| try w.byte(b);
    }
    /// A fixed block with bits left in the buffer, then a stored block
    /// whose header comes partly from the bit buffer.
    fn fixedThenStored(w: *deflate.BitWriter) !void {
        try w.bits(0, 1);
        try w.bits(1, 2);
        try fixed.literals(w, "xyz");
        try fixed.symbol(w, 256);
        try w.bits(1, 1);
        try w.bits(0, 2);
        try w.alignByte();
        try w.bits(4, 16);
        try w.bits(~@as(u16, 4), 16);
        for ("abcd") |b| try w.byte(b);
    }
    fn emptyStored(w: *deflate.BitWriter) !void {
        try w.bits(0, 1);
        try w.bits(0, 2);
        try w.alignByte();
        try w.bits(0, 16);
        try w.bits(0xffff, 16);
        try w.bits(1, 1);
        try w.bits(1, 2);
        try fixed.literals(w, "q");
        try fixed.symbol(w, 256);
    }
    fn distanceTooFar(w: *deflate.BitWriter) !void {
        try w.bits(1, 1);
        try w.bits(1, 2);
        try fixed.literals(w, "ab");
        try fixed.symbol(w, 257);
        try fixed.distance(w, 2); // distance 3, two bytes out
        try fixed.symbol(w, 256);
    }
    fn lengthCode286(w: *deflate.BitWriter) !void {
        try w.bits(1, 1);
        try w.bits(1, 2);
        try fixed.literals(w, "ab");
        try fixed.symbol(w, 286);
    }
    fn lengthCode287(w: *deflate.BitWriter) !void {
        try w.bits(1, 1);
        try w.bits(1, 2);
        try fixed.literals(w, "ab");
        try fixed.symbol(w, 287);
    }
    fn distanceCode30(w: *deflate.BitWriter) !void {
        try w.bits(1, 1);
        try w.bits(1, 2);
        try fixed.literals(w, "ab");
        try fixed.symbol(w, 257);
        try fixed.distance(w, 30);
    }
    fn distanceCode31(w: *deflate.BitWriter) !void {
        try w.bits(1, 1);
        try w.bits(1, 2);
        try fixed.literals(w, "ab");
        try fixed.symbol(w, 257);
        try fixed.distance(w, 31);
    }
    /// A match of every length symbol with every extra value at the
    /// longest distance code, after enough output.
    fn everyLength(w: *deflate.BitWriter) !void {
        try w.bits(0, 1);
        try w.bits(0, 2);
        try w.alignByte();
        try w.bits(30000, 16);
        try w.bits(~@as(u16, 30000), 16);
        for (0..30000) |i| try w.byte(@truncate(i *% 7));
        try w.bits(1, 1);
        try w.bits(1, 2);
        var len: u16 = 3;
        while (len <= 258) : (len += 1) {
            const l = deflate.lengthSymbol(len);
            try fixed.symbol(w, l.symbol);
            try w.bits(l.extra, l.extra_bits);
            const d = deflate.distanceSymbol(@intCast(24577 + len));
            try fixed.distance(w, d.symbol);
            try w.bits(d.extra, d.extra_bits);
        }
        try fixed.symbol(w, 256);
    }
    /// No end of block: the input ends and the decoder reads zero bits.
    fn noEndOfBlock(w: *deflate.BitWriter) !void {
        try w.bits(1, 1);
        try w.bits(1, 2);
        try fixed.literals(w, "abcdefgh");
    }
    /// An end of block whose last bits are past the input's end.
    fn endPastInput(w: *deflate.BitWriter) !void {
        try w.bits(1, 1);
        try w.bits(1, 2);
        // Symbol 256 is seven zero bits; a 0 byte would hold them.
        try fixed.literals(w, "a");
    }
    /// A code-length code with three codes of one bit.
    fn badSizes(w: *deflate.BitWriter) !void {
        try w.bits(1, 1);
        try w.bits(2, 2);
        try w.bits(0, 5);
        try w.bits(0, 5);
        try w.bits(0, 4); // four code-length codes: 16, 17, 18, 0
        for (0..3) |_| try w.bits(1, 3);
        try w.bits(0, 3);
    }
    /// Two codes of one bit and one of two: over-subscribed.
    fn badCodeLengths(w: *deflate.BitWriter) !void {
        try w.bits(1, 1);
        try w.bits(2, 2);
        try w.bits(0, 5);
        try w.bits(0, 5);
        try w.bits(0, 4);
        try w.bits(1, 3);
        try w.bits(1, 3);
        try w.bits(2, 3);
        try w.bits(0, 3);
    }
    /// A repeat of the previous length before any length.
    fn repeatFirst(w: *deflate.BitWriter) !void {
        try w.bits(1, 1);
        try w.bits(2, 2);
        try w.bits(0, 5);
        try w.bits(0, 5);
        try w.bits(0, 4);
        // Codes: 16 -> 0 (1 bit), 17 -> 10, 18 -> 11 (2 bits).
        try w.bits(1, 3);
        try w.bits(2, 3);
        try w.bits(2, 3);
        try w.bits(0, 3);
        try w.code(0, 1);
        try w.bits(0, 2);
    }
    /// 138 zeros, then 138 more, past the 258 lengths.
    fn repeatPastEnd(w: *deflate.BitWriter) !void {
        try w.bits(1, 1);
        try w.bits(2, 2);
        try w.bits(0, 5);
        try w.bits(0, 5);
        try w.bits(0, 4);
        try w.bits(1, 3);
        try w.bits(2, 3);
        try w.bits(2, 3);
        try w.bits(0, 3);
        try w.code(0b11, 2);
        try w.bits(127, 7);
        try w.code(0b11, 2);
        try w.bits(127, 7);
    }
    /// A code-length code that leaves code 0b11 unused, then that code.
    fn invalidCodeLengthCode(w: *deflate.BitWriter) !void {
        try w.bits(1, 1);
        try w.bits(2, 2);
        try w.bits(0, 5);
        try w.bits(0, 5);
        try w.bits(0, 4);
        try w.bits(1, 3); // 16: 0
        try w.bits(2, 3); // 17: 10
        try w.bits(0, 3);
        try w.bits(0, 3);
        try w.code(0b11, 2);
    }
    /// A literal/length code with codes of 1 to 15 bits, the long ones
    /// read through the slow path, and an unused 15-bit code.
    fn longCodes(w: *deflate.BitWriter) !void {
        try w.bits(1, 1);
        try w.bits(2, 2);
        var lit: [257]u8 = @splat(0);
        // 'a' to 'n' of 1 to 14 bits and 256 of 15 leave code 0x7fff unused.
        for (0..14) |i| lit['a' + i] = @intCast(i + 1);
        lit[256] = 15;
        const dist = [_]u8{1};
        try deflate.writeDynamicHeader(w, &lit, &dist);
        var codes: [257]u16 = undefined;
        deflate.canonical(&lit, &codes);
        for (0..14) |i| try w.code(codes['n' - i], @intCast(14 - i));
        try w.code(0x7fff, 15);
        try w.code(0x7fff, 15);
    }
    fn longCodesValid(w: *deflate.BitWriter) !void {
        try w.bits(1, 1);
        try w.bits(2, 2);
        var lit: [257]u8 = @splat(0);
        for (0..15) |i| lit['a' + i] = @intCast(i + 1);
        lit[256] = 15;
        const dist = [_]u8{1};
        try deflate.writeDynamicHeader(w, &lit, &dist);
        var codes: [257]u16 = undefined;
        deflate.canonical(&lit, &codes);
        for (0..3) |_| {
            for (0..15) |i| try w.code(codes['o' - i], @intCast(15 - i));
        }
        try w.code(codes[256], 15);
    }
};

test "zlib: corrupt, truncated and odd streams fail or decode as in the original" {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Headers: too short, a bad check, a preset dictionary, not DEFLATE.
    const headers = [_][]const u8{
        "",                 "\x78",             "\x78\x9c",         "\x78\x9d\x03\x00",
        "\x78\xbb\x03\x00", "\x79\x18\x03\x00", "\x77\x9c\x03\x00", "\x08\x1d\x03\x00",
        "\x78\x01\x03\x00",
    };
    for (headers, 0..) |input, i| {
        const label = try std.fmt.allocPrint(arena, "header {d}", .{i});
        try expectAllSame(input, 0, true, label);
    }

    const writers = .{
        cases.typeThree,       cases.storedBadNlen,  cases.storedPastEnd,
        cases.fixedThenStored, cases.emptyStored,    cases.distanceTooFar,
        cases.lengthCode286,   cases.lengthCode287,  cases.distanceCode30,
        cases.distanceCode31,  cases.everyLength,    cases.noEndOfBlock,
        cases.endPastInput,    cases.badSizes,       cases.badCodeLengths,
        cases.repeatFirst,     cases.repeatPastEnd,  cases.invalidCodeLengthCode,
        cases.longCodes,       cases.longCodesValid,
    };
    inline for (writers, 0..) |write, i| {
        for ([_]bool{ true, false }) |header| {
            const input = try handMade(arena, header, write);
            const label = try std.fmt.allocPrint(arena, "hand-made {d} header {}", .{ i, header });
            try expectAllSame(input, decodedLength(input, header), header, label);
            // Every truncation of the short ones.
            if (input.len < 200) {
                for (0..input.len) |n| try expectTruncationSame(input[0..n], header, label);
            }
        }
    }

    // Every truncation of real streams of each block type.
    const data = "the quick brown fox jumps over the lazy dog; the quick brown fox again";
    for (try encodings(arena, data, true), 0..) |encoded, k| {
        for (0..encoded.len) |n| {
            const label = try std.fmt.allocPrint(arena, "truncated encoding {d} at {d}", .{ k, n });
            try expectTruncationSame(encoded[0..n], true, label);
        }
    }
}

/// A stream where zero bits decode as a length code with 2 extra bits and
/// a distance code with 13: past the end of the input, where `receive`
/// gives zero bits without end, the match can repeat until the output is
/// full. `literals` 2-bit literals and `zero_bytes` zero bytes after the
/// header move where the input ends against the repeating match.
fn endlessMatch(arena: std.mem.Allocator, literals: usize, zero_bytes: usize) ![]u8 {
    var w: deflate.BitWriter = .init(arena);
    try w.byte(0x78);
    try w.byte(0x01);
    try w.bits(0, 1);
    try w.bits(0, 2);
    try w.alignByte();
    try w.bits(20000, 16);
    try w.bits(~@as(u16, 20000), 16);
    for (0..20000) |i| try w.byte(@truncate(i));
    try w.bits(1, 1);
    try w.bits(2, 2);
    var lit: [271]u8 = @splat(0);
    lit[270] = 1; // the all-zero code: length 23, 2 extra bits
    lit[0] = 2;
    lit[256] = 2;
    var dist: [29]u8 = @splat(0);
    dist[28] = 8; // the all-zero code: distance 16385, 13 extra bits
    try deflate.writeDynamicHeader(&w, &lit, &dist);
    for (0..literals) |_| try w.code(0b10, 2);
    try w.alignByte();
    for (0..zero_bytes) |_| try w.byte(0);
    return w.finish();
}

test "zlib: zero bits past the end repeat a match until the buffer is full, as in the original" {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var filled: usize = 0;
    for (0..12) |literals| {
        for (0..4) |zero_bytes| {
            const input = try endlessMatch(arena, literals, zero_bytes);
            for ([_]usize{ 20000, 20023, 100_000, 1 << 20 }) |buffer_len| {
                const call: Call = .{ .function = .buffer, .buffer_len = buffer_len };
                try expectSame(input, call, "endless match");
            }
            const buffer = try arena.alloc(u8, 1 << 20);
            if (zlib.decodeBuffer(buffer, input, .{})) |_| {} else |err| {
                if (err == error.ZlibOutputLimit) filled += 1;
            }
        }
    }
    try std.testing.expect(filled > 0);
}

test "zlib: initial sizes of 0 and 1 grow as in the original" {
    // A zero size never grows in the original, whose doubling never ends;
    // with nothing to write it decodes, as here.
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for (try encodings(arena, "", true)) |encoded| {
        for ([_]u32{ 0, 1 }) |initial_size| {
            const call: Call = .{ .function = .malloc_guesssize, .initial_size = initial_size };
            try expectSame(encoded, call, "empty");
        }
    }
    const xs = try arena.alloc(u8, 5000);
    @memset(xs, 'x');
    for (try encodings(arena, xs, true)) |encoded| {
        const call: Call = .{ .function = .malloc_guesssize, .initial_size = 1 };
        try expectSame(encoded, call, "5000 bytes, size 1");
        // The original would loop for ever here; the port fails.
        const result = zlib.decodeAlloc(gpa, encoded, .{ .initial_size = 0 });
        try std.testing.expectError(error.OutOfMemory, result);
    }
}

/// The joined IDAT data of a PNG file, or null when it has none.
fn idatStream(arena: std.mem.Allocator, png: []const u8) !?[]u8 {
    if (png.len < 8 or !std.mem.eql(u8, png[0..8], "\x89PNG\r\n\x1a\n")) return null;
    var data: std.ArrayList(u8) = .empty;
    var pos: usize = 8;
    while (pos + 8 <= png.len) {
        const len = std.mem.readInt(u32, png[pos..][0..4], .big);
        const kind = png[pos + 4 ..][0..4];
        if (len > png.len - pos - 8) break;
        if (std.mem.eql(u8, kind, "IDAT")) try data.appendSlice(arena, png[pos + 8 ..][0..len]);
        pos += 12 + @as(usize, len);
    }
    if (data.items.len == 0) return null;
    return data.items;
}

fn corpusStreams(arena: std.mem.Allocator) ![]const []const u8 {
    var streams: std.ArrayList([]const u8) = .empty;
    const sources = [_]struct { root: corpus.Root, dir: []const u8 }{
        .{ .root = .stb, .dir = "tests/pngsuite" },
        .{ .root = .image_rs, .dir = "tests/images/png" },
        .{ .root = .libjpeg_turbo, .dir = "testimages" },
    };
    for (sources) |source| {
        var set = try corpus.load(gpa, std.testing.io, source.root, source.dir, &.{".png"});
        defer set.deinit(gpa);
        for (set.entries) |entry| {
            if (try idatStream(arena, entry.bytes)) |stream| try streams.append(arena, stream);
        }
    }
    return streams.toOwnedSlice(arena);
}

test "zlib: the IDAT streams of the PNG corpus inflate as in the original" {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for (try corpusStreams(arena), 0..) |stream, i| {
        const label = try std.fmt.allocPrint(arena, "corpus stream {d}", .{i});
        var length: usize = 0;
        if (zlib.decodeAlloc(gpa, stream, .{})) |bytes| {
            length = bytes.len;
            gpa.free(bytes);
        } else |_| {}
        try expectSame(stream, .{ .function = .malloc }, label);
        try expectSame(stream, .{ .function = .malloc_guesssize, .initial_size = 3 }, label);
        try expectSame(stream, .{ .function = .buffer, .buffer_len = length }, label);
        try expectSame(stream, .{ .function = .buffer, .buffer_len = length -| 1 }, label);
    }
}

test "fuzz: mutated zlib and raw DEFLATE streams decode as in the original" {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var seeds: std.ArrayList([]const u8) = .empty;
    for ((try samples(arena))[0..6]) |data| {
        try seeds.appendSlice(arena, try encodings(arena, data[0..@min(data.len, 3000)], true));
    }
    const corpus_streams = try corpusStreams(arena);
    for (corpus_streams[0..@min(corpus_streams.len, 40)]) |stream| try seeds.append(arena, stream);

    const config: fuzz.Config = .{ .name = "zlib streams", .seed = 0x5eed_2001, .cases = 1500 };
    for (0..config.cases) |case| {
        var prng: std.Random.DefaultPrng = .init(fuzz.caseSeed(config, @intCast(case)));
        const rng = prng.random();
        const original = seeds.items[rng.uintLessThan(usize, seeds.items.len)];
        const bytes = try fuzz.mutate(gpa, rng, original);
        defer gpa.free(bytes);
        const function: Function = @fromBackingInt(@as(c_int, rng.uintLessThan(u8, 6)));
        // Never an initial size of 0, where the original can loop for ever.
        const sizes = [_]u32{ 1, 5, 64, 4096, 16384 };
        const call: Call = .{
            .function = function,
            .initial_size = sizes[rng.uintLessThan(usize, sizes.len)],
            .parse_header = rng.boolean(),
            .buffer_len = rng.uintLessThan(usize, 70000),
        };
        const label = try std.fmt.allocPrint(arena, "zlib fuzz case {d}", .{case});
        try expectSame(bytes, call, label);
    }
}

fn decodeForFailures(allocator: std.mem.Allocator, input: []const u8) !void {
    const bytes = try zlib.decodeAlloc(allocator, input, .{ .initial_size = 4 });
    allocator.free(bytes);
}

test "zlib: each allocation failure of a growing decode is reported and leaks nothing" {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const data = try arena.alloc(u8, 5000);
    for (data, 0..) |*b, i| b.* = @truncate(i * i);
    const input = try deflate.compress(arena, data, .{});
    try std.testing.checkAllAllocationFailures(gpa, decodeForFailures, .{input});
}
