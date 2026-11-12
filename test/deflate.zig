//! A small DEFLATE and zlib encoder for the tests: stored, fixed and
//! dynamic Huffman blocks, from a greedy LZ77 search, and the bit writer
//! and canonical codes for streams built by hand. Test-only code.

const std = @import("std");

/// Writes bits from the least significant end, as DEFLATE packs them.
pub const BitWriter = struct {
    gpa: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,
    bit_buffer: u64 = 0,
    bit_count: u6 = 0,

    pub fn init(gpa: std.mem.Allocator) BitWriter {
        return .{ .gpa = gpa };
    }

    pub fn deinit(w: *BitWriter) void {
        w.bytes.deinit(w.gpa);
    }

    /// The low `count` bits of `value`.
    pub fn bits(w: *BitWriter, value: u32, count: u6) !void {
        std.debug.assert(count <= 32);
        w.bit_buffer |= @as(u64, value & mask(count)) << w.bit_count;
        w.bit_count += count;
        while (w.bit_count >= 8) {
            try w.bytes.append(w.gpa, @truncate(w.bit_buffer));
            w.bit_buffer >>= 8;
            w.bit_count -= 8;
        }
    }

    /// A Huffman code of `len` bits, sent from its most significant bit.
    pub fn code(w: *BitWriter, value: u16, len: u4) !void {
        const reversed = @as(u32, @bitReverse(value)) >> (16 - @as(u5, len));
        try w.bits(reversed, len);
    }

    /// Pads with zeros to a byte boundary.
    pub fn alignByte(w: *BitWriter) !void {
        if (w.bit_count % 8 != 0) try w.bits(0, 8 - w.bit_count % 8);
    }

    pub fn byte(w: *BitWriter, value: u8) !void {
        std.debug.assert(w.bit_count == 0);
        try w.bytes.append(w.gpa, value);
    }

    /// The stream so far, padded to whole bytes; the caller frees it.
    pub fn finish(w: *BitWriter) ![]u8 {
        try w.alignByte();
        return w.bytes.toOwnedSlice(w.gpa);
    }

    fn mask(count: u6) u32 {
        return if (count >= 32) 0xffff_ffff else (@as(u32, 1) << @intCast(count)) - 1;
    }
};

/// The canonical codes of `lengths`, as DEFLATE assigns them.
pub fn canonical(lengths: []const u8, codes: []u16) void {
    var count: [16]u16 = @splat(0);
    for (lengths) |len| count[len] += 1;
    count[0] = 0;
    var next: [16]u16 = @splat(0);
    var c: u16 = 0;
    for (1..16) |bits| {
        c = (c + count[bits - 1]) << 1;
        next[bits] = c;
    }
    for (lengths, codes) |len, *out| {
        if (len == 0) continue;
        out.* = next[len];
        next[len] += 1;
    }
}

pub const Token = union(enum) {
    literal: u8,
    match: struct { len: u16, dist: u16 },
};

/// A greedy LZ77 parse: at each position the longest match within the
/// window found along a short hash chain, if at least 3 bytes.
pub fn tokenize(gpa: std.mem.Allocator, data: []const u8, window: usize) ![]Token {
    var tokens: std.ArrayList(Token) = .empty;
    errdefer tokens.deinit(gpa);
    const hash_size = 1 << 12;
    var head: [hash_size]i32 = @splat(-1);
    const prev = try gpa.alloc(i32, data.len);
    defer gpa.free(prev);
    var pos: usize = 0;
    while (pos < data.len) {
        var best_len: usize = 0;
        var best_dist: usize = 0;
        if (pos + 3 <= data.len) {
            const h = hash3(data[pos..][0..3]);
            var candidate = head[h];
            var chain: u32 = 0;
            while (candidate >= 0 and chain < 64) : (chain += 1) {
                const at: usize = @intCast(candidate);
                if (pos - at > window) break;
                var len: usize = 0;
                while (len < 258 and pos + len < data.len and data[at + len] == data[pos + len]) {
                    len += 1;
                }
                if (len > best_len) {
                    best_len = len;
                    best_dist = pos - at;
                }
                candidate = prev[at];
            }
        }
        const step = if (best_len >= 3) best_len else 1;
        if (best_len >= 3) {
            try tokens.append(gpa, .{ .match = .{
                .len = @intCast(best_len),
                .dist = @intCast(best_dist),
            } });
        } else {
            try tokens.append(gpa, .{ .literal = data[pos] });
        }
        for (pos..pos + step) |p| {
            if (p + 3 > data.len) break;
            const h = hash3(data[p..][0..3]);
            prev[p] = head[h];
            head[h] = @intCast(p);
        }
        pos += step;
    }
    return tokens.toOwnedSlice(gpa);
}

fn hash3(bytes: *const [3]u8) usize {
    const v = @as(u32, bytes[0]) << 16 | @as(u32, bytes[1]) << 8 | bytes[2];
    return (v *% 2654435761) >> 20;
}

const length_base = [29]u16{
    3,  4,  5,  6,  7,  8,  9,  10, 11,  13,  15,  17,  19,  23,  27,
    31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258,
};
const length_extra = [29]u4{
    0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
    3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0,
};
const distance_base = [30]u16{
    1,   2,   3,   4,   5,   7,    9,    13,   17,   25,   33,   49,   65,    97,    129,
    193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577,
};
const distance_extra = [30]u4{
    0, 0, 0, 0, 1, 1, 2, 2,  3,  3,  4,  4,  5,  5,  6,
    6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13,
};

/// The length symbol (257..285) and its extra bits for a match length.
pub fn lengthSymbol(len: u16) struct { symbol: u16, extra: u16, extra_bits: u4 } {
    var i: usize = 28;
    while (length_base[i] > len) i -= 1;
    return .{
        .symbol = @intCast(257 + i),
        .extra = len - length_base[i],
        .extra_bits = length_extra[i],
    };
}

pub fn distanceSymbol(dist: u16) struct { symbol: u16, extra: u16, extra_bits: u4 } {
    var i: usize = 29;
    while (distance_base[i] > dist) i -= 1;
    return .{
        .symbol = @intCast(i),
        .extra = dist - distance_base[i],
        .extra_bits = distance_extra[i],
    };
}

pub fn fixedLengths() [288]u8 {
    var lengths: [288]u8 = undefined;
    for (&lengths, 0..) |*len, i| {
        len.* = if (i <= 143) 8 else if (i <= 255) 9 else if (i <= 279) 7 else 8;
    }
    return lengths;
}

pub const BlockKind = enum { stored, fixed, dynamic };

pub const Options = struct {
    /// The two-byte zlib header and the Adler-32 trailer.
    zlib: bool = true,
    kind: BlockKind = .dynamic,
    /// Input bytes per block; stored blocks hold at most 65535.
    block_size: usize = 65535,
    window: usize = 32768,
};

/// Compresses `data` into blocks of one kind; the caller frees the result.
pub fn compress(gpa: std.mem.Allocator, data: []const u8, options: Options) ![]u8 {
    var w: BitWriter = .init(gpa);
    errdefer w.deinit();
    if (options.zlib) {
        try w.byte(0x78);
        try w.byte(0x9c);
    }
    var start: usize = 0;
    while (true) {
        const end = @min(data.len, start + options.block_size);
        const final = end == data.len;
        try writeBlock(&w, data[start..end], final, options.kind, options.window);
        if (final) break;
        start = end;
    }
    if (options.zlib) {
        try w.alignByte();
        const adler = std.hash.Adler32.hash(data);
        for (0..4) |i| try w.byte(@truncate(adler >> @intCast(24 - 8 * i)));
    }
    return w.finish();
}

/// One block of `data`, of `kind`.
pub fn writeBlock(
    w: *BitWriter,
    data: []const u8,
    final: bool,
    kind: BlockKind,
    window: usize,
) !void {
    try w.bits(@intFromBool(final), 1);
    switch (kind) {
        .stored => {
            std.debug.assert(data.len <= 65535);
            try w.bits(0, 2);
            try w.alignByte();
            const len: u16 = @intCast(data.len);
            try w.bits(len, 16);
            try w.bits(~len, 16);
            for (data) |b| try w.byte(b);
        },
        .fixed => {
            try w.bits(1, 2);
            const tokens = try tokenize(w.gpa, data, window);
            defer w.gpa.free(tokens);
            const lengths = fixedLengths();
            var codes: [288]u16 = undefined;
            canonical(&lengths, &codes);
            const distance_lengths: [30]u8 = @splat(5);
            var distance_codes: [30]u16 = undefined;
            canonical(&distance_lengths, &distance_codes);
            try writeTokens(w, tokens, &lengths, &codes, &distance_lengths, &distance_codes);
        },
        .dynamic => {
            try w.bits(2, 2);
            const tokens = try tokenize(w.gpa, data, window);
            defer w.gpa.free(tokens);
            var lit_freq: [286]u32 = @splat(0);
            var dist_freq: [30]u32 = @splat(0);
            for (tokens) |token| switch (token) {
                .literal => |b| lit_freq[b] += 1,
                .match => |m| {
                    lit_freq[lengthSymbol(m.len).symbol] += 1;
                    dist_freq[distanceSymbol(m.dist).symbol] += 1;
                },
            };
            lit_freq[256] += 1;
            var lit_lengths: [286]u8 = undefined;
            var dist_lengths: [30]u8 = undefined;
            shannonLengths(&lit_freq, &lit_lengths, 15);
            shannonLengths(&dist_freq, &dist_lengths, 15);
            if (std.mem.allEqual(u8, &dist_lengths, 0)) dist_lengths[0] = 1;
            var hlit: usize = 286;
            while (lit_lengths[hlit - 1] == 0) hlit -= 1;
            var hdist: usize = 30;
            while (hdist > 1 and dist_lengths[hdist - 1] == 0) hdist -= 1;
            try writeDynamicHeader(w, lit_lengths[0..hlit], dist_lengths[0..hdist]);
            var codes: [286]u16 = undefined;
            canonical(lit_lengths[0..hlit], codes[0..hlit]);
            var distance_codes: [30]u16 = undefined;
            canonical(dist_lengths[0..hdist], distance_codes[0..hdist]);
            try writeTokens(
                w,
                tokens,
                lit_lengths[0..hlit],
                codes[0..hlit],
                dist_lengths[0..hdist],
                distance_codes[0..hdist],
            );
        },
    }
}

/// The tokens, then the end of the block.
pub fn writeTokens(
    w: *BitWriter,
    tokens: []const Token,
    lengths: []const u8,
    codes: []const u16,
    distance_lengths: []const u8,
    distance_codes: []const u16,
) !void {
    for (tokens) |token| switch (token) {
        .literal => |b| try w.code(codes[b], @intCast(lengths[b])),
        .match => |m| {
            const l = lengthSymbol(m.len);
            try w.code(codes[l.symbol], @intCast(lengths[l.symbol]));
            try w.bits(l.extra, l.extra_bits);
            const d = distanceSymbol(m.dist);
            try w.code(distance_codes[d.symbol], @intCast(distance_lengths[d.symbol]));
            try w.bits(d.extra, d.extra_bits);
        },
    };
    try w.code(codes[256], @intCast(lengths[256]));
}

/// Lengths of about `-log2(p)`, which always fit Kraft's inequality;
/// frequencies are halved until no length passes `limit`. Unused symbols
/// get 0.
pub fn shannonLengths(freq: []const u32, lengths: []u8, limit: u8) void {
    var scaled: [288]u64 = undefined;
    for (freq, scaled[0..freq.len]) |f, *s| s.* = f;
    while (true) {
        var total: u64 = 0;
        for (scaled[0..freq.len]) |f| total += f;
        var fits = true;
        for (scaled[0..freq.len], lengths) |f, *len| {
            if (f == 0) {
                len.* = 0;
                continue;
            }
            var bits: u8 = 1;
            while ((f << @intCast(bits)) < total) bits += 1;
            len.* = bits;
            if (bits > limit) fits = false;
        }
        if (fits) return;
        for (scaled[0..freq.len]) |*f| {
            if (f.* != 0) f.* = @max(1, f.* >> 1);
        }
    }
}

/// HLIT, HDIST, HCLEN, the code-length code and the run-length coded
/// lengths of a dynamic block.
pub fn writeDynamicHeader(w: *BitWriter, lit_lengths: []const u8, dist_lengths: []const u8) !void {
    const order = [19]u8{ 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 };
    var all: [316]u8 = undefined;
    @memcpy(all[0..lit_lengths.len], lit_lengths);
    @memcpy(all[lit_lengths.len..][0..dist_lengths.len], dist_lengths);
    const lengths = all[0 .. lit_lengths.len + dist_lengths.len];

    // Run-length code: 16 repeats the last length 3-6 times, 17 and 18
    // give 3-10 and 11-138 zeros.
    const Op = struct { symbol: u8, extra: u8 };
    var ops: [316]Op = undefined;
    var op_count: usize = 0;
    var i: usize = 0;
    while (i < lengths.len) {
        const len = lengths[i];
        var run: usize = 1;
        while (i + run < lengths.len and lengths[i + run] == len) run += 1;
        if (len == 0 and run >= 11) {
            const n = @min(run, 138);
            ops[op_count] = .{ .symbol = 18, .extra = @intCast(n - 11) };
            op_count += 1;
            i += n;
        } else if (len == 0 and run >= 3) {
            const n = @min(run, 10);
            ops[op_count] = .{ .symbol = 17, .extra = @intCast(n - 3) };
            op_count += 1;
            i += n;
        } else if (len != 0 and run >= 4) {
            ops[op_count] = .{ .symbol = len, .extra = 0 };
            op_count += 1;
            const n = @min(run - 1, 6);
            ops[op_count] = .{ .symbol = 16, .extra = @intCast(n - 3) };
            op_count += 1;
            i += 1 + n;
        } else {
            ops[op_count] = .{ .symbol = len, .extra = 0 };
            op_count += 1;
            i += 1;
        }
    }
    var cl_freq: [19]u32 = @splat(0);
    for (ops[0..op_count]) |op| cl_freq[op.symbol] += 1;
    var cl_lengths: [19]u8 = undefined;
    shannonLengths(&cl_freq, &cl_lengths, 7);
    var hclen: usize = 19;
    while (hclen > 4 and cl_lengths[order[hclen - 1]] == 0) hclen -= 1;
    try w.bits(@intCast(lit_lengths.len - 257), 5);
    try w.bits(@intCast(dist_lengths.len - 1), 5);
    try w.bits(@intCast(hclen - 4), 4);
    for (order[0..hclen]) |symbol| try w.bits(cl_lengths[symbol], 3);
    var cl_codes: [19]u16 = undefined;
    canonical(&cl_lengths, &cl_codes);
    for (ops[0..op_count]) |op| {
        try w.code(cl_codes[op.symbol], @intCast(cl_lengths[op.symbol]));
        switch (op.symbol) {
            16 => try w.bits(op.extra, 2),
            17 => try w.bits(op.extra, 3),
            18 => try w.bits(op.extra, 7),
            else => {},
        }
    }
}
