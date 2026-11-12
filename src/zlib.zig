//! stb_image's zlib decoder: inflate of a zlib stream, or of raw DEFLATE
//! data, held whole in memory, into a buffer that grows as stb_image's
//! does or into one of fixed size. `decodeAlloc` and `decodeBuffer` are the
//! six `stbi_zlib_decode_*` functions.

const std = @import("std");

/// The ways a decode fails, each one of stb_image's failure reasons.
/// `NoReason` is a block of the reserved type 3, where the original fails
/// without setting a reason.
pub const Error = error{
    BadZlibHeader,
    ZlibPresetDictionary,
    ZlibBadCompression,
    ZlibCorrupt,
    ZlibReadPastBuffer,
    ZlibBadHuffmanCode,
    ZlibBadCodeLengths,
    BadPngSizes,
    BadDistance,
    UnexpectedPngEnd,
    ZlibOutputLimit,
    OutOfMemory,
    NoReason,
};

pub const AllocOptions = struct {
    /// The size of the first output buffer, doubled whenever the output
    /// outgrows it; `stbi_zlib_decode_malloc` uses 16384.
    initial_size: usize = 16384,
    /// Read the two-byte zlib header first; false for raw DEFLATE data.
    parse_header: bool = true,
};

pub const BufferOptions = struct {
    /// Read the two-byte zlib header first; false for raw DEFLATE data.
    parse_header: bool = true,
};

/// Inflates `input` into memory from `gpa`, which the caller frees:
/// `stbi_zlib_decode_malloc_guesssize_headerflag`, and with the default
/// options `stbi_zlib_decode_malloc`. The slice holds what the stream
/// produced, nothing past it.
pub fn decodeAlloc(gpa: std.mem.Allocator, input: []const u8, options: AllocOptions) Error![]u8 {
    const output = try decodeGrowing(gpa, input, options);
    errdefer gpa.free(output.buffer);
    return gpa.realloc(output.buffer, output.len);
}

/// Inflates `input` into `output` and returns the length produced:
/// `stbi_zlib_decode_buffer`, and `stbi_zlib_decode_noheader_buffer` with
/// `parse_header` false. A stream longer than `output` fails with
/// `error.ZlibOutputLimit`. On failure `output` holds what was decoded
/// before it, as in the original.
pub fn decodeBuffer(output: []u8, input: []const u8, options: BufferOptions) Error!usize {
    var decoder: Decoder = .{
        .input = input,
        .gpa = null,
        .out = output,
        .limit = output.len,
    };
    try decoder.parseZlib(options.parse_header);
    return decoder.len;
}

/// A growing decode's result: `buffer` is the allocation, of which the
/// first `len` bytes were produced.
pub const Output = struct {
    buffer: []u8,
    len: usize,
};

/// Inflates `input` into a buffer that grows as the original's does,
/// without trimming it to the length produced. The caller frees `buffer`.
pub fn decodeGrowing(
    gpa: std.mem.Allocator,
    input: []const u8,
    options: AllocOptions,
) Error!Output {
    // The original allocates `initial_size` at once. DEFLATE gives at most
    // 1032 bytes per input byte, short of one corrupt case (see
    // `receive`), so the port starts with no more than that and grows like
    // the original past it: a header's lie costs no memory. When and how
    // the decode fails stays the original's, decided by `limit`.
    const likely = (input.len +| 8) *| 1032;
    var decoder: Decoder = .{
        .input = input,
        .gpa = gpa,
        .out = try gpa.alloc(u8, @min(options.initial_size, likely)),
        .limit = options.initial_size,
    };
    errdefer gpa.free(decoder.out);
    try decoder.parseZlib(options.parse_header);
    return .{ .buffer = decoder.out, .len = decoder.len };
}

const fast_bits = 9;
const fast_mask = (1 << fast_bits) - 1;
/// The symbols of the literal/length alphabet.
const symbol_count = 288;

/// A canonical Huffman code, read from the least significant bit: a table
/// for codes of up to `fast_bits` bits, and the first code and symbol of
/// each length for the longer ones.
const Huffman = struct {
    /// For each `fast_bits`-bit window: the length of the code it starts
    /// with, shifted left 9, or'd with its symbol; 0 where no code that
    /// short matches.
    fast: [1 << fast_bits]u16,
    firstcode: [16]u16,
    /// One past the last code of each length, shifted to 16 bits.
    maxcode: [17]i32,
    firstsymbol: [16]u16,
    size: [symbol_count]u8,
    value: [symbol_count]u16,

    /// Builds the code of the lengths in `sizelist` (`stbi__zbuild_huffman`).
    /// Incomplete codes are accepted, as in the original.
    fn build(z: *Huffman, sizelist: []const u8) Error!void {
        var sizes: [17]i32 = @splat(0);
        var next_code: [16]i32 = @splat(0);
        z.fast = @splat(0);
        for (sizelist) |s| sizes[s] += 1;
        sizes[0] = 0;
        for (1..16) |i| {
            if (sizes[i] > (@as(i32, 1) << @intCast(i))) return error.BadPngSizes;
        }
        var code: i32 = 0;
        var k: i32 = 0;
        for (1..16) |i| {
            next_code[i] = code;
            z.firstcode[i] = @intCast(code);
            z.firstsymbol[i] = @intCast(k);
            code += sizes[i];
            if (sizes[i] != 0 and code - 1 >= (@as(i32, 1) << @intCast(i))) {
                return error.ZlibBadCodeLengths;
            }
            z.maxcode[i] = code << @intCast(16 - i);
            code <<= 1;
            k += sizes[i];
        }
        z.maxcode[16] = 0x10000;
        for (sizelist, 0..) |s, i| {
            if (s == 0) continue;
            // The symbol's place among the codes in code order, below
            // `firstsymbol[s] + sizes[s]`.
            const c: usize = @intCast(next_code[s] - z.firstcode[s] + z.firstsymbol[s]);
            z.size[c] = s;
            z.value[c] = @intCast(i);
            if (s <= fast_bits) {
                const fastv: u16 = @intCast((@as(u32, s) << 9) | i);
                var j: usize = bitReverse(@intCast(next_code[s]), s);
                while (j < (1 << fast_bits)) : (j += @as(usize, 1) << @intCast(s)) {
                    z.fast[j] = fastv;
                }
            }
            next_code[s] += 1;
        }
    }
};

/// The low `bits` bits of `v`, reversed.
fn bitReverse(v: u32, bits: u8) u32 {
    const reversed: u32 = @bitReverse(@as(u16, @truncate(v)));
    return reversed >> @intCast(16 - bits);
}

/// The fixed codes of block type 1, which the original builds anew for
/// each such block.
const fixed = struct {
    const length_sizes: [symbol_count]u8 = blk: {
        var sizes: [symbol_count]u8 = undefined;
        for (&sizes, 0..) |*size, i| {
            size.* = if (i <= 143) 8 else if (i <= 255) 9 else if (i <= 279) 7 else 8;
        }
        break :blk sizes;
    };
    const distance_sizes: [32]u8 = @splat(5);

    const length: Huffman = build(&length_sizes);
    const distance: Huffman = build(&distance_sizes);

    fn build(comptime sizes: []const u8) Huffman {
        @setEvalBranchQuota(100_000);
        var z: Huffman = std.mem.zeroes(Huffman);
        z.build(sizes) catch unreachable;
        return z;
    }
};

const length_base = [31]u16{
    3,  4,  5,  6,  7,  8,  9,  10,  11,  13,  15,  17,  19,  23, 27, 31,
    35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258, 0,  0,
};
const length_extra = [31]u5{
    0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
    3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0, 0, 0,
};
const distance_base = [32]u16{
    1,   2,   3,   4,   5,    7,    9,    13,   17,   25,   33,   49,    65,    97,    129, 193,
    257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577, 0,   0,
};
const distance_extra = [32]u5{
    0, 0, 0, 0, 1, 1, 2,  2,  3,  3,  4,  4,  5,  5,  6, 6,
    7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13, 0, 0,
};

/// `stbi__zbuf`: the input, the bit buffer and the output.
const Decoder = struct {
    input: []const u8,
    pos: usize = 0,
    /// The bits in `code_buffer`, from 0 to 32; `code_buffer` is always
    /// below `1 << num_bits`.
    num_bits: i32 = 0,
    /// The decoder ran out of input once and went on with 16 zero bits.
    hit_zeof_once: bool = false,
    code_buffer: u32 = 0,

    /// Grows the output; null for a fixed buffer.
    gpa: ?std.mem.Allocator,
    /// The allocation, never longer than `limit`.
    out: []u8,
    /// The bytes produced.
    len: usize = 0,
    /// The size of the original's buffer: past it, the original grows it.
    limit: u64,

    length: *const Huffman = undefined,
    distance: *const Huffman = undefined,
    dynamic_length: Huffman = undefined,
    dynamic_distance: Huffman = undefined,

    fn atEof(d: *const Decoder) bool {
        return d.pos >= d.input.len;
    }

    fn get8(d: *Decoder) u8 {
        if (d.atEof()) return 0;
        const byte = d.input[d.pos];
        d.pos += 1;
        return byte;
    }

    fn fillBits(d: *Decoder) void {
        while (true) {
            // Bits above `num_bits` would mean a corrupt buffer: end the
            // input, so the decode fails.
            if (d.code_buffer >= (@as(u32, 1) << @intCast(d.num_bits))) {
                d.pos = d.input.len;
                return;
            }
            d.code_buffer |= @as(u32, d.get8()) << @intCast(d.num_bits);
            d.num_bits += 8;
            if (d.num_bits > 24) return;
        }
    }

    /// The next `n` bits. Past the end of the input they are zeros, without
    /// end, unlike `decode`'s, which stop after 16; a corrupt stream can
    /// so repeat a match until the output limit, as in the original.
    fn receive(d: *Decoder, n: u5) u32 {
        if (d.num_bits < n) d.fillBits();
        const k = d.code_buffer & ((@as(u32, 1) << n) - 1);
        d.code_buffer >>= n;
        d.num_bits -= n;
        return k;
    }

    /// The next symbol of `z`, or -1 for an invalid code or an input that
    /// ended. At the end of the input it goes on once with 16 zero bits;
    /// the end of the block checks that none of them were used.
    fn decode(d: *Decoder, z: *const Huffman) i32 {
        if (d.num_bits < 16) {
            if (d.atEof()) {
                if (d.hit_zeof_once) return -1;
                d.hit_zeof_once = true;
                d.num_bits += 16;
            } else {
                d.fillBits();
            }
        }
        const b = z.fast[d.code_buffer & fast_mask];
        if (b != 0) {
            const s: u5 = @intCast(b >> 9);
            d.code_buffer >>= s;
            d.num_bits -= s;
            return b & 511;
        }
        return d.decodeSlow(z);
    }

    /// A code longer than `fast_bits`, found from its length's first code.
    fn decodeSlow(d: *Decoder, z: *const Huffman) i32 {
        const k: i32 = @intCast(bitReverse(d.code_buffer, 16));
        var s: usize = fast_bits + 1;
        while (k >= z.maxcode[s]) s += 1;
        if (s >= 16) return -1;
        const b = (k >> @intCast(16 - s)) - z.firstcode[s] + z.firstsymbol[s];
        if (b < 0 or b >= symbol_count) return -1;
        const at: usize = @intCast(b);
        if (z.size[at] != s) return -1;
        d.code_buffer >>= @intCast(s);
        d.num_bits -= @intCast(s);
        return z.value[at];
    }

    /// Makes room for `n` bytes after the first `cur` (`stbi__zexpand`).
    fn expand(d: *Decoder, cur: usize, n: usize) Error!void {
        d.len = cur;
        const gpa = d.gpa orelse return error.ZlibOutputLimit;
        if (cur + n > d.limit) {
            if (cur + n > std.math.maxInt(u32)) return error.OutOfMemory;
            var limit = d.limit;
            // The original doubles a zero size forever; the port fails as
            // that loop would if it ended.
            if (limit == 0) return error.OutOfMemory;
            while (cur + n > limit) {
                if (limit > std.math.maxInt(u32) / 2) return error.OutOfMemory;
                limit *= 2;
            }
            d.limit = limit;
        }
        const wanted = @max(cur + n, d.out.len *| 2);
        d.out = try gpa.realloc(d.out, @intCast(@min(d.limit, wanted)));
    }

    /// `stbi__parse_huffman_block`: symbols up to the end of the block.
    fn parseHuffmanBlock(d: *Decoder) Error!void {
        var zout = d.len;
        while (true) {
            var z = d.decode(d.length);
            if (z < 256) {
                if (z < 0) return error.ZlibBadHuffmanCode;
                if (zout >= d.out.len) {
                    try d.expand(zout, 1);
                    zout = d.len;
                }
                d.out[zout] = @intCast(z);
                zout += 1;
                continue;
            }
            if (z == 256) {
                d.len = zout;
                // Using any of the 16 zero bits added at the end of the
                // input means the stream ended early.
                if (d.hit_zeof_once and d.num_bits < 16) return error.UnexpectedPngEnd;
                return;
            }
            // Length codes 286 and 287 never appear in valid data.
            if (z >= 286) return error.ZlibBadHuffmanCode;
            const length_code: usize = @intCast(z - 257);
            var len: usize = length_base[length_code];
            if (length_extra[length_code] != 0) len += d.receive(length_extra[length_code]);
            z = d.decode(d.distance);
            // Distance codes 30 and 31 never appear in valid data.
            if (z < 0 or z >= 30) return error.ZlibBadHuffmanCode;
            const distance_code: usize = @intCast(z);
            var dist: usize = distance_base[distance_code];
            if (distance_extra[distance_code] != 0) {
                dist += d.receive(distance_extra[distance_code]);
            }
            if (zout < dist) return error.BadDistance;
            if (len > d.out.len - zout) {
                try d.expand(zout, len);
                zout = d.len;
            }
            const out = d.out;
            if (dist == 1) {
                @memset(out[zout..][0..len], out[zout - 1]);
            } else {
                // Forwards, byte by byte: the copy may overlap what it
                // writes, repeating it.
                for (out[zout..][0..len], out[zout - dist ..][0..len]) |*to, from| to.* = from;
            }
            zout += len;
        }
    }

    /// `stbi__compute_huffman_codes`: the code lengths of a dynamic block.
    fn computeHuffmanCodes(d: *Decoder) Error!void {
        const length_dezigzag = [19]u8{
            16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15,
        };
        var z_codelength: Huffman = undefined;
        var lencodes: [286 + 32 + 137]u8 = undefined;
        var codelength_sizes: [19]u8 = @splat(0);

        const hlit: usize = d.receive(5) + 257;
        const hdist: usize = d.receive(5) + 1;
        const hclen: usize = d.receive(4) + 4;
        const ntot = hlit + hdist;

        for (length_dezigzag[0..hclen]) |symbol| {
            codelength_sizes[symbol] = @intCast(d.receive(3));
        }
        try z_codelength.build(&codelength_sizes);

        var n: usize = 0;
        while (n < ntot) {
            const c = d.decode(&z_codelength);
            if (c < 0 or c >= 19) return error.ZlibBadCodeLengths;
            if (c < 16) {
                lencodes[n] = @intCast(c);
                n += 1;
                continue;
            }
            var fill: u8 = 0;
            var count: usize = undefined;
            if (c == 16) {
                count = d.receive(2) + 3;
                if (n == 0) return error.ZlibBadCodeLengths;
                fill = lencodes[n - 1];
            } else if (c == 17) {
                count = d.receive(3) + 3;
            } else {
                count = d.receive(7) + 11;
            }
            if (ntot - n < count) return error.ZlibBadCodeLengths;
            @memset(lencodes[n..][0..count], fill);
            n += count;
        }
        try d.dynamic_length.build(lencodes[0..hlit]);
        try d.dynamic_distance.build(lencodes[hlit..ntot]);
        d.length = &d.dynamic_length;
        d.distance = &d.dynamic_distance;
    }

    /// `stbi__parse_uncompressed_block`: a stored block.
    fn parseUncompressedBlock(d: *Decoder) Error!void {
        var header: [4]u8 = undefined;
        if (d.num_bits & 7 != 0) _ = d.receive(@intCast(d.num_bits & 7));
        // The whole bytes still in the bit buffer come first, then bytes
        // from the input.
        var k: usize = 0;
        while (d.num_bits > 0) {
            header[k] = @truncate(d.code_buffer);
            k += 1;
            d.code_buffer >>= 8;
            d.num_bits -= 8;
        }
        if (d.num_bits < 0) return error.ZlibCorrupt;
        while (k < 4) : (k += 1) header[k] = d.get8();
        const len = @as(usize, header[1]) * 256 + header[0];
        const nlen = @as(usize, header[3]) * 256 + header[2];
        if (nlen != len ^ 0xffff) return error.ZlibCorrupt;
        if (len > d.input.len - d.pos) return error.ZlibReadPastBuffer;
        if (len > d.out.len - d.len) try d.expand(d.len, len);
        @memcpy(d.out[d.len..][0..len], d.input[d.pos..][0..len]);
        d.pos += len;
        d.len += len;
    }

    /// `stbi__parse_zlib_header`.
    fn parseZlibHeader(d: *Decoder) Error!void {
        const cmf: u32 = d.get8();
        const cm = cmf & 15;
        const flg: u32 = d.get8();
        if (d.atEof()) return error.BadZlibHeader;
        if ((cmf * 256 + flg) % 31 != 0) return error.BadZlibHeader;
        if (flg & 32 != 0) return error.ZlibPresetDictionary;
        if (cm != 8) return error.ZlibBadCompression;
    }

    /// `stbi__parse_zlib`: the header, then blocks up to the final one.
    fn parseZlib(d: *Decoder, parse_header: bool) Error!void {
        if (parse_header) try d.parseZlibHeader();
        d.num_bits = 0;
        d.code_buffer = 0;
        d.hit_zeof_once = false;
        while (true) {
            const final = d.receive(1);
            switch (d.receive(2)) {
                0 => try d.parseUncompressedBlock(),
                1 => {
                    d.length = &fixed.length;
                    d.distance = &fixed.distance;
                    try d.parseHuffmanBlock();
                },
                2 => {
                    try d.computeHuffmanCodes();
                    try d.parseHuffmanBlock();
                },
                else => return error.NoReason,
            }
            if (final != 0) return;
        }
    }
};
