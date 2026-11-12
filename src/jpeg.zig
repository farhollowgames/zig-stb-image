//! The JPEG decoder: baseline and progressive Huffman-coded JPEG with 8-bit
//! samples and one, three or four components, every integer ratio of
//! sampling factors, restart intervals, and JFIF YCbCr, Adobe RGB, CMYK and
//! YCCK colour. Arithmetic coding, 12-bit samples and lossless JPEG are
//! refused, as the original refuses them.

const std = @import("std");
const common = @import("common.zig");

const Source = common.Source;
const Error = common.Error;

const idct_kind = @import("stb_image_options").jpeg_idct;

/// Huffman codes of at most this many bits decode with one table lookup.
const fast_bits = 9;
const fast_len = 1 << fast_bits;
const fast_mask = fast_len - 1;

/// The value `getMarker` gives when there is no marker; no marker has it.
const marker_none: u8 = 0xff;

/// One Huffman table. Zeroes, as a table never defined is: every symbol
/// then decodes as 0 from no bits at all, as in the original.
const Huffman = struct {
    /// By the next `fast_bits` bits of input, the position of the code
    /// that starts there if it is at most `fast_bits` long, or 255.
    fast: [fast_len]u8 = @splat(0),
    code: [256]u16 = @splat(0),
    values: [256]u8 = @splat(0),
    size: [257]u8 = @splat(0),
    /// One past the largest code of each length, shifted to 16 bits.
    maxcode: [18]u32 = @splat(0),
    /// Added to a code of each length to give its position.
    delta: [17]i32 = @splat(0),
};

/// How far `decodeHeader` reads: the start-of-image marker only, the
/// frame header, or the frame header and the buffers a decode needs.
const Scan = enum { load, signature, header };

/// A block's pixels were written by the IDCT.
const block_decoded: u8 = 1 << 0;
/// A progressive block's coefficients were zeroed by a first DC scan.
const block_cleared: u8 = 1 << 1;

const Component = struct {
    id: u8 = 0,
    h: u8 = 0,
    v: u8 = 0,
    tq: u8 = 0,
    hd: u8 = 0,
    ha: u8 = 0,
    dc_pred: i32 = 0,
    /// The samples the image needs of this component.
    x: u32 = 0,
    y: u32 = 0,
    /// The samples decoded: whole MCUs, past the image's edge.
    w2: u32 = 0,
    h2: u32 = 0,
    data: []u8 = &.{},
    /// Progressive only: 64 coefficients per block, blocks row by row.
    coeff: []i16 = &.{},
    /// Blocks across and down `data`.
    blocks_w: u32 = 0,
    blocks_h: u32 = 0,
    /// Per block, `block_decoded` and `block_cleared`. The original leaves
    /// its buffers as `malloc` gives them, so a block no scan decoded holds
    /// whatever was there; the port refuses an image whose pixels need one.
    blocks: []u8 = &.{},
    linebuf: []u8 = &.{},
};

/// The decoder's state, as stb_image's `stbi__jpeg`, zeroed at the start
/// as there.
const Decoder = struct {
    source: *Source,
    limits: common.Limits,
    /// Set for a load; the header scans allocate nothing.
    gpa: ?std.mem.Allocator = null,

    huff_dc: [4]Huffman = @splat(.{}),
    huff_ac: [4]Huffman = @splat(.{}),
    dequant: [4][64]u16 = @splat(@splat(0)),
    /// Per AC table, by the next `fast_bits` bits: the value, run and
    /// combined length of a small coefficient, or 0.
    fast_ac: [4][fast_len]i16 = @splat(@splat(0)),

    img_h_max: u32 = 0,
    img_v_max: u32 = 0,
    img_mcu_x: u32 = 0,
    img_mcu_y: u32 = 0,
    img_mcu_w: u32 = 0,
    img_mcu_h: u32 = 0,

    components: [4]Component = @splat(.{}),

    code_buffer: u32 = 0,
    code_bits: i32 = 0,
    /// A marker met while filling `code_buffer`.
    marker: u8 = 0,
    /// A marker was met: the entropy-coded data gives only zero bits now.
    nomore: bool = false,

    progressive: bool = false,
    spec_start: u8 = 0,
    spec_end: u8 = 0,
    succ_high: u8 = 0,
    succ_low: u8 = 0,
    eob_run: i32 = 0,
    jfif: bool = false,
    app14_color_transform: i16 = 0,
    rgb: u8 = 0,

    scan_n: u8 = 0,
    order: [4]u8 = @splat(0),
    restart_interval: u32 = 0,
    todo: i32 = 0,

    fn freeComponents(z: *Decoder, gpa: std.mem.Allocator) void {
        for (&z.components) |*c| {
            gpa.free(c.data);
            gpa.free(c.coeff);
            gpa.free(c.blocks);
            gpa.free(c.linebuf);
            c.data = &.{};
            c.coeff = &.{};
            c.blocks = &.{};
            c.linebuf = &.{};
        }
    }

    /// `len` items, after the original's size check of `factors` and
    /// `add`; a failed check is out of memory, as there.
    fn allocChecked(
        z: *Decoder,
        comptime T: type,
        factors: []const i64,
        add: i64,
        len: usize,
    ) Error![]T {
        if (!common.sizesValid(z.limits, factors, add)) return z.source.fail(error.OutOfMemory);
        return z.gpa.?.alloc(T, len) catch z.source.fail(error.OutOfMemory);
    }

    fn allocZeroed(
        z: *Decoder,
        comptime T: type,
        factors: []const i64,
        add: i64,
        len: usize,
    ) Error![]T {
        const buffer = try z.allocChecked(T, factors, add, len);
        @memset(buffer, 0);
        return buffer;
    }

    // ---- Huffman tables -------------------------------------------------

    /// `stbi__build_huffman`: the canonical codes from the count of codes
    /// of each length, and the fast table.
    fn buildHuffman(z: *Decoder, h: *Huffman, count: *const [16]u32) Error!void {
        var k: usize = 0;
        for (0..16) |i| {
            for (0..count[i]) |_| {
                h.size[k] = @intCast(i + 1);
                k += 1;
                if (k >= 257) return z.source.fail(error.BadJpegSizeList);
            }
        }
        h.size[k] = 0;

        var code: u32 = 0;
        k = 0;
        var j: u32 = 1;
        while (j <= 16) : (j += 1) {
            h.delta[j] = @as(i32, @intCast(k)) - @as(i32, @intCast(code));
            if (h.size[k] == j) {
                while (h.size[k] == j) {
                    h.code[k] = @intCast(code);
                    k += 1;
                    code += 1;
                }
                if (code - 1 >= @as(u32, 1) << @intCast(j)) {
                    return z.source.fail(error.JpegBadCodeLengths);
                }
            }
            h.maxcode[j] = code << @intCast(16 - j);
            code <<= 1;
        }
        h.maxcode[17] = 0xffffffff;

        @memset(&h.fast, 255);
        for (0..k) |i| {
            const s = h.size[i];
            if (s <= fast_bits) {
                const c = @as(usize, h.code[i]) << @intCast(fast_bits - s);
                const m = @as(usize, 1) << @intCast(fast_bits - s);
                @memset(h.fast[c..][0..m], @intCast(i));
            }
        }
    }

    /// `stbi__build_fast_ac`: decodes both the length and the value of
    /// small AC coefficients in one lookup.
    fn buildFastAc(fast_ac: *[fast_len]i16, h: *const Huffman) void {
        for (fast_ac, 0..) |*entry, i| {
            const fast = h.fast[i];
            entry.* = 0;
            if (fast < 255) {
                const rs: i32 = h.values[fast];
                const run = (rs >> 4) & 15;
                const magbits = rs & 15;
                const len: i32 = h.size[fast];
                if (magbits != 0 and len + magbits <= fast_bits) {
                    // The value's bits follow the code.
                    const shifted = (@as(i32, @intCast(i)) << @intCast(len)) & fast_mask;
                    var k = shifted >> @intCast(fast_bits - magbits);
                    const m = @as(i32, 1) << @intCast(magbits - 1);
                    if (k < m) k += 1 - (@as(i32, 1) << @intCast(magbits));
                    if (k >= -128 and k <= 127) {
                        entry.* = @intCast(k * 256 + run * 16 + len + magbits);
                    }
                }
            }
        }
    }

    // ---- The bit reader -------------------------------------------------

    /// `stbi__grow_buffer_unsafe`: more than 24 bits in `code_buffer`, or
    /// fewer where a marker ends the data.
    fn growBuffer(z: *Decoder) void {
        while (true) {
            const b: u32 = if (z.nomore) 0 else z.source.get8();
            if (b == 0xff) {
                var c = z.source.get8();
                while (c == 0xff) c = z.source.get8();
                if (c != 0) {
                    z.marker = c;
                    z.nomore = true;
                    return;
                }
            }
            z.code_buffer |= b << @intCast(24 - z.code_bits);
            z.code_bits += 8;
            if (z.code_bits > 24) return;
        }
    }

    /// `stbi__jpeg_huff_decode`: the next symbol, or null for a code the
    /// table does not have.
    fn huffDecode(z: *Decoder, h: *const Huffman) ?u8 {
        if (z.code_bits < 16) z.growBuffer();

        const c = (z.code_buffer >> (32 - fast_bits)) & fast_mask;
        const fast = h.fast[c];
        if (fast < 255) {
            const s = h.size[fast];
            if (s > z.code_bits) return null;
            z.code_buffer <<= @intCast(s);
            z.code_bits -= s;
            return h.values[fast];
        }

        // Codes longer than `fast_bits`: maxcode is shifted to 16 bits, so
        // the top 16 bits compare against every length alike.
        const temp = z.code_buffer >> 16;
        var k: u32 = fast_bits + 1;
        while (k < 17 and temp >= h.maxcode[k]) k += 1;
        if (k == 17) {
            z.code_bits -= 16;
            return null;
        }
        if (k > z.code_bits) return null;

        const bits: i32 = @intCast((z.code_buffer >> @intCast(32 - k)) & bmask[k]);
        const position = bits + h.delta[k];
        if (position < 0 or position >= 256) return null;
        z.code_bits -= @intCast(k);
        z.code_buffer <<= @intCast(k);
        return h.values[@intCast(position)];
    }

    /// `stbi__extend_receive`: `n` bits as a signed coefficient, or 0 when
    /// the data has run out.
    fn extendReceive(z: *Decoder, n: u5) i32 {
        if (z.code_bits < n) z.growBuffer();
        if (z.code_bits < n) return 0;
        // The top bit clear means a negative value.
        const negative = (z.code_buffer >> 31) == 0;
        const rotated = std.math.rotl(u32, z.code_buffer, n);
        z.code_buffer = rotated & ~bmask[n];
        z.code_bits -= n;
        const k: i32 = @intCast(rotated & bmask[n]);
        return if (negative) k + jbias[n] else k;
    }

    /// `stbi__jpeg_get_bits`: `n` bits, or 0 when the data has run out.
    fn getBits(z: *Decoder, n: u5) i32 {
        if (z.code_bits < n) z.growBuffer();
        if (z.code_bits < n) return 0;
        const rotated = std.math.rotl(u32, z.code_buffer, n);
        z.code_buffer = rotated & ~bmask[n];
        z.code_bits -= n;
        return @intCast(rotated & bmask[n]);
    }

    /// `stbi__jpeg_get_bit`: one bit, or 0 when the data has run out.
    fn getBit(z: *Decoder) bool {
        if (z.code_bits < 1) z.growBuffer();
        if (z.code_bits < 1) return false;
        const bit = z.code_buffer & 0x80000000 != 0;
        z.code_buffer <<= 1;
        z.code_bits -= 1;
        return bit;
    }

    // ---- Blocks ---------------------------------------------------------

    /// `stbi__jpeg_decode_block`: one baseline block, dequantized.
    fn decodeBlock(
        z: *Decoder,
        data: *[64]i16,
        hdc: *const Huffman,
        hac: *const Huffman,
        fac: *const [fast_len]i16,
        b: usize,
        dequant: *const [64]u16,
    ) Error!void {
        if (z.code_bits < 16) z.growBuffer();
        const t = z.huffDecode(hdc) orelse return z.source.fail(error.JpegBadHuffmanCode);
        if (t > 15) return z.source.fail(error.JpegBadHuffmanCode);

        data.* = @splat(0);

        const diff = if (t != 0) z.extendReceive(@intCast(t)) else 0;
        const dc_pred = z.components[b].dc_pred;
        if (!addIntsValid(dc_pred, diff)) return z.source.fail(error.BadJpegDelta);
        const dc = dc_pred + diff;
        z.components[b].dc_pred = dc;
        if (!mul2ShortsValid(dc, dequant[0])) return z.source.fail(error.CannotMergeDcAndAc);
        data[0] = @intCast(dc * dequant[0]);

        var k: u32 = 1;
        while (true) {
            if (z.code_bits < 16) z.growBuffer();
            const c = (z.code_buffer >> (32 - fast_bits)) & fast_mask;
            const r: i32 = fac[c];
            if (r != 0) {
                k += @intCast((r >> 4) & 15);
                const s = r & 15;
                if (s > z.code_bits) return z.source.fail(error.JpegBadHuffmanLength);
                z.code_buffer <<= @intCast(s);
                z.code_bits -= s;
                const zig = dezigzag[k];
                k += 1;
                data[zig] = @truncate((r >> 8) * dequant[zig]);
            } else {
                const rs = z.huffDecode(hac) orelse return z.source.fail(error.JpegBadHuffmanCode);
                const s: u5 = @intCast(rs & 15);
                const run = rs >> 4;
                if (s == 0) {
                    if (rs != 0xf0) break; // end of block
                    k += 16;
                } else {
                    k += run;
                    const zig = dezigzag[k];
                    k += 1;
                    data[zig] = @truncate(z.extendReceive(s) * dequant[zig]);
                }
            }
            if (k >= 64) break;
        }
    }

    /// `stbi__jpeg_decode_block_prog_dc`: the DC coefficient of a block in
    /// a progressive scan, first or refined.
    fn decodeBlockProgDc(
        z: *Decoder,
        data: *[64]i16,
        flags: *u8,
        hdc: *const Huffman,
        b: usize,
    ) Error!void {
        if (z.spec_end != 0) return z.source.fail(error.CannotMergeDcAndAc);
        if (z.code_bits < 16) z.growBuffer();

        if (z.succ_high == 0) {
            data.* = @splat(0);
            flags.* |= block_cleared;
            const t = z.huffDecode(hdc) orelse return z.source.fail(error.CannotMergeDcAndAc);
            if (t > 15) return z.source.fail(error.CannotMergeDcAndAc);
            const diff = if (t != 0) z.extendReceive(@intCast(t)) else 0;

            const dc_pred = z.components[b].dc_pred;
            if (!addIntsValid(dc_pred, diff)) return z.source.fail(error.BadJpegDelta);
            const dc = dc_pred + diff;
            z.components[b].dc_pred = dc;
            const scale = @as(i32, 1) << @intCast(z.succ_low);
            if (!mul2ShortsValid(dc, scale)) return z.source.fail(error.CannotMergeDcAndAc);
            data[0] = @intCast(dc * scale);
        } else {
            if (z.getBit()) data[0] +%= @as(i16, 1) << @intCast(z.succ_low);
        }
    }

    /// `stbi__jpeg_decode_block_prog_ac`: the AC coefficients of a block in
    /// a progressive scan, first or refined, with end-of-band runs.
    fn decodeBlockProgAc(
        z: *Decoder,
        data: *[64]i16,
        flags: u8,
        hac: *const Huffman,
        fac: *const [fast_len]i16,
    ) Error!void {
        if (z.spec_start == 0) return z.source.fail(error.CannotMergeDcAndAc);

        if (z.succ_high == 0) {
            const shift: u5 = @intCast(z.succ_low);
            if (z.eob_run != 0) {
                z.eob_run -= 1;
                return;
            }
            var k: u32 = z.spec_start;
            while (true) {
                if (z.code_bits < 16) z.growBuffer();
                const c = (z.code_buffer >> (32 - fast_bits)) & fast_mask;
                const r: i32 = fac[c];
                if (r != 0) {
                    k += @intCast((r >> 4) & 15);
                    const s = r & 15;
                    if (s > z.code_bits) return z.source.fail(error.JpegBadHuffmanLength);
                    z.code_buffer <<= @intCast(s);
                    z.code_bits -= s;
                    const zig = dezigzag[k];
                    k += 1;
                    data[zig] = @truncate((r >> 8) * (@as(i32, 1) << shift));
                } else {
                    const rs = z.huffDecode(hac) orelse
                        return z.source.fail(error.JpegBadHuffmanCode);
                    const s: u5 = @intCast(rs & 15);
                    const run: u5 = @intCast(rs >> 4);
                    if (s == 0) {
                        if (run < 15) {
                            z.eob_run = @as(i32, 1) << run;
                            if (run != 0) z.eob_run += z.getBits(run);
                            z.eob_run -= 1;
                            break;
                        }
                        k += 16;
                    } else {
                        k += run;
                        const zig = dezigzag[k];
                        k += 1;
                        data[zig] = @truncate(z.extendReceive(s) * (@as(i32, 1) << shift));
                    }
                }
                if (k > z.spec_end) break;
            }
            return;
        }

        // A refinement reads the coefficients it refines: in a block no
        // first DC scan cleared, the original reads `malloc`'s leftovers and
        // decodes the rest of the scan from them.
        if (flags & block_cleared == 0) return z.source.fail(error.JpegMissingScanData);

        const bit = @as(i16, 1) << @intCast(z.succ_low);
        if (z.eob_run != 0) {
            z.eob_run -= 1;
            var k: u32 = z.spec_start;
            while (k <= z.spec_end) : (k += 1) z.refine(&data[dezigzag[k]], bit);
            return;
        }
        var k: u32 = z.spec_start;
        while (true) {
            const rs = z.huffDecode(hac) orelse return z.source.fail(error.JpegBadHuffmanCode);
            var s: i16 = 0;
            var run: u32 = rs >> 4;
            if (rs & 15 == 0) {
                if (run < 15) {
                    z.eob_run = (@as(i32, 1) << @intCast(run)) - 1;
                    if (run != 0) z.eob_run += z.getBits(@intCast(run));
                    // Only refinements for the rest of the band.
                    run = 64;
                }
                // Else a run of 16 zeros: 15 skipped, and a zero written.
            } else {
                if (rs & 15 != 1) return z.source.fail(error.JpegBadHuffmanCode);
                s = if (z.getBit()) bit else -bit;
            }

            while (k <= z.spec_end) {
                const p = &data[dezigzag[k]];
                k += 1;
                if (p.* != 0) {
                    z.refine(p, bit);
                } else {
                    if (run == 0) {
                        p.* = s;
                        break;
                    }
                    run -= 1;
                }
            }
            if (k > z.spec_end) break;
        }
    }

    /// The next correction bit of a coefficient already nonzero.
    fn refine(z: *Decoder, p: *i16, bit: i16) void {
        if (p.* == 0) return;
        if (z.getBit() and p.* & bit == 0) {
            if (p.* > 0) p.* +%= bit else p.* -%= bit;
        }
    }

    // ---- Entropy-coded data ---------------------------------------------

    /// `stbi__get_marker`: the marker the bit reader met, else the next one
    /// in the input, else `marker_none`.
    fn getMarker(z: *Decoder) u8 {
        if (z.marker != marker_none) {
            const x = z.marker;
            z.marker = marker_none;
            return x;
        }
        var x = z.source.get8();
        if (x != 0xff) return marker_none;
        while (x == 0xff) x = z.source.get8(); // fill bytes
        return x;
    }

    /// `stbi__jpeg_reset`: after a restart marker, the bit reader and the
    /// DC predictions start over.
    fn reset(z: *Decoder) void {
        z.code_bits = 0;
        z.code_buffer = 0;
        z.nomore = false;
        for (&z.components) |*c| c.dc_pred = 0;
        z.marker = marker_none;
        z.todo = if (z.restart_interval != 0) @intCast(z.restart_interval) else 0x7fffffff;
        z.eob_run = 0;
    }

    /// Counts down the restart interval after an MCU. False when the scan
    /// stops there: the interval is over and no restart marker follows, so
    /// the rest of the image keeps what it had.
    fn nextMcu(z: *Decoder) bool {
        z.todo -= 1;
        if (z.todo > 0) return true;
        if (z.code_bits < 24) z.growBuffer();
        if (!isRestart(z.marker)) return false;
        z.reset();
        return true;
    }

    /// One baseline block, decoded and transformed into the component's
    /// samples at block column `bx` and row `by`.
    fn decodeBaselineBlock(z: *Decoder, n: usize, bx: usize, by: usize) Error!void {
        const c = &z.components[n];
        var data: [64]i16 = undefined;
        try z.decodeBlock(
            &data,
            &z.huff_dc[c.hd],
            &z.huff_ac[c.ha],
            &z.fast_ac[c.ha],
            n,
            &z.dequant[c.tq],
        );
        const offset = by * 8 * @as(usize, c.w2) + bx * 8;
        try z.inverseTransform(c.data[offset..], c.w2, &data);
        c.blocks[by * c.blocks_w + bx] |= block_decoded;
    }

    /// The samples of a block, by the IDCT the build names.
    fn inverseTransform(
        z: *Decoder,
        out: []u8,
        out_stride: usize,
        data: *const [64]i16,
    ) Error!void {
        switch (idct_kind) {
            .scalar => idctBlock(out, out_stride, data) catch
                return z.source.fail(error.JpegIdctOverflow),
            .sse2 => idctBlockSse2(out, out_stride, data),
        }
    }

    fn progressiveBlock(z: *Decoder, n: usize, bx: usize, by: usize) struct { *[64]i16, *u8 } {
        const c = &z.components[n];
        const block = by * c.blocks_w + bx;
        return .{ c.coeff[block * 64 ..][0..64], &c.blocks[block] };
    }

    /// `stbi__parse_entropy_coded_data`: one scan.
    fn parseEntropyCodedData(z: *Decoder) Error!void {
        z.reset();
        if (z.scan_n == 1) {
            // One component: its blocks in row order, each one an MCU.
            const n = z.order[0];
            const c = &z.components[n];
            const w = (c.x + 7) >> 3;
            const h = (c.y + 7) >> 3;
            for (0..h) |j| {
                for (0..w) |i| {
                    if (!z.progressive) {
                        try z.decodeBaselineBlock(n, i, j);
                    } else {
                        const data, const flags = z.progressiveBlock(n, i, j);
                        if (z.spec_start == 0) {
                            try z.decodeBlockProgDc(data, flags, &z.huff_dc[c.hd], n);
                        } else {
                            const hac = &z.huff_ac[c.ha];
                            try z.decodeBlockProgAc(data, flags.*, hac, &z.fast_ac[c.ha]);
                        }
                    }
                    if (!z.nextMcu()) return;
                }
            }
            return;
        }
        // Interleaved: each MCU holds h by v blocks of each component in
        // the scan.
        for (0..z.img_mcu_y) |j| {
            for (0..z.img_mcu_x) |i| {
                for (z.order[0..z.scan_n]) |n| {
                    const c = &z.components[n];
                    for (0..c.v) |y| {
                        for (0..c.h) |x| {
                            const bx = i * c.h + x;
                            const by = j * c.v + y;
                            if (!z.progressive) {
                                try z.decodeBaselineBlock(n, bx, by);
                            } else {
                                const data, const flags = z.progressiveBlock(n, bx, by);
                                try z.decodeBlockProgDc(data, flags, &z.huff_dc[c.hd], n);
                            }
                        }
                    }
                }
                if (!z.nextMcu()) return;
            }
        }
    }

    /// `stbi__jpeg_finish`: a progressive image's coefficients, dequantized
    /// and transformed. A block no first DC scan cleared holds `malloc`'s
    /// leftovers in the original; the port leaves it undecoded.
    fn finish(z: *Decoder) Error!void {
        if (!z.progressive) return;
        const img_n: usize = @intCast(z.source.img_n);
        for (z.components[0..img_n]) |*c| {
            const w = (c.x + 7) >> 3;
            const h = (c.y + 7) >> 3;
            for (0..h) |j| {
                for (0..w) |i| {
                    const block = j * c.blocks_w + i;
                    if (c.blocks[block] & block_cleared == 0) continue;
                    const data = c.coeff[block * 64 ..][0..64];
                    for (data, &z.dequant[c.tq]) |*d, q| d.* = @truncate(@as(i32, d.*) * q);
                    const offset = j * 8 * @as(usize, c.w2) + i * 8;
                    try z.inverseTransform(c.data[offset..], c.w2, data);
                    c.blocks[block] |= block_decoded;
                }
            }
        }
    }

    // ---- Markers --------------------------------------------------------

    /// `stbi__process_marker`: a table, the restart interval, or an APP or
    /// COM segment.
    fn processMarker(z: *Decoder, m: u8) Error!void {
        const s = z.source;
        switch (m) {
            marker_none => return s.fail(error.ExpectedMarker),
            0xdd => {
                // DRI
                if (s.get16be() != 4) return s.fail(error.BadDriLength);
                z.restart_interval = s.get16be();
                return;
            },
            0xdb => {
                // DQT
                var left: i32 = @as(i32, s.get16be()) - 2;
                while (left > 0) {
                    const q = s.get8();
                    const p = q >> 4;
                    const sixteen = p != 0;
                    const t = q & 15;
                    if (p != 0 and p != 1) return s.fail(error.BadDqtType);
                    if (t > 3) return s.fail(error.BadDqtTable);
                    for (dezigzag[0..64]) |zig| {
                        z.dequant[t][zig] = if (sixteen) s.get16be() else s.get8();
                    }
                    left -= if (sixteen) 129 else 65;
                }
                if (left != 0) return s.staleFailure();
                return;
            },
            0xc4 => {
                // DHT
                var left: i32 = @as(i32, s.get16be()) - 2;
                while (left > 0) {
                    const q = s.get8();
                    const tc = q >> 4;
                    const th = q & 15;
                    if (tc > 1 or th > 3) return s.fail(error.BadDhtHeader);
                    var sizes: [16]u32 = undefined;
                    var n: u32 = 0;
                    for (&sizes) |*size| {
                        size.* = s.get8();
                        n += size.*;
                    }
                    if (n > 256) return s.fail(error.BadDhtHeader);
                    left -= 17;
                    const table = if (tc == 0) &z.huff_dc[th] else &z.huff_ac[th];
                    try z.buildHuffman(table, &sizes);
                    for (table.values[0..n]) |*value| value.* = s.get8();
                    if (tc != 0) buildFastAc(&z.fast_ac[th], table);
                    left -= @intCast(n);
                }
                if (left != 0) return s.staleFailure();
                return;
            },
            else => {},
        }

        if ((m >= 0xe0 and m <= 0xef) or m == 0xfe) {
            var left: i32 = s.get16be();
            if (left < 2) {
                return s.fail(if (m == 0xfe) error.BadComLength else error.BadAppLength);
            }
            left -= 2;
            if (m == 0xe0 and left >= 5) {
                var ok = true;
                for ("JFIF\x00") |tag| {
                    if (s.get8() != tag) ok = false;
                }
                left -= 5;
                if (ok) z.jfif = true;
            } else if (m == 0xee and left >= 12) {
                var ok = true;
                for ("Adobe\x00") |tag| {
                    if (s.get8() != tag) ok = false;
                }
                left -= 6;
                if (ok) {
                    _ = s.get8(); // version
                    _ = s.get16be(); // flags0
                    _ = s.get16be(); // flags1
                    z.app14_color_transform = s.get8();
                    left -= 6;
                }
            }
            s.skip(left);
            return;
        }
        return s.fail(error.UnknownJpegMarker);
    }

    /// `stbi__process_scan_header`: the start of a scan.
    fn processScanHeader(z: *Decoder) Error!void {
        const s = z.source;
        const ls = s.get16be();
        z.scan_n = s.get8();
        if (z.scan_n < 1 or z.scan_n > 4 or z.scan_n > s.img_n) {
            return s.fail(error.BadSosComponentCount);
        }
        if (ls != 6 + 2 * @as(u32, z.scan_n)) return s.fail(error.BadSosLength);
        const img_n: usize = @intCast(s.img_n);
        for (z.order[0..z.scan_n]) |*order| {
            const id = s.get8();
            const q = s.get8();
            const which = for (z.components[0..img_n], 0..) |c, i| {
                if (c.id == id) break i;
            } else return s.staleFailure();
            const c = &z.components[which];
            c.hd = q >> 4;
            if (c.hd > 3) return s.fail(error.BadDcHuffman);
            c.ha = q & 15;
            if (c.ha > 3) return s.fail(error.BadAcHuffman);
            order.* = @intCast(which);
        }

        z.spec_start = s.get8();
        z.spec_end = s.get8(); // 63, or 0 in a progressive DC scan
        const aa = s.get8();
        z.succ_high = aa >> 4;
        z.succ_low = aa & 15;
        if (z.progressive) {
            if (z.spec_start > 63 or z.spec_end > 63 or z.spec_start > z.spec_end or
                z.succ_high > 13 or z.succ_low > 13)
            {
                return s.fail(error.BadSos);
            }
        } else {
            if (z.spec_start != 0) return s.fail(error.BadSos);
            if (z.succ_high != 0 or z.succ_low != 0) return s.fail(error.BadSos);
            z.spec_end = 63;
        }
    }

    /// `stbi__process_frame_header`: the image's size and components, and
    /// for a load the buffers they decode into.
    fn processFrameHeader(z: *Decoder, scan: Scan) Error!void {
        const s = z.source;
        const lf = s.get16be();
        if (lf < 11) return s.fail(error.BadSofLength);
        const p = s.get8();
        if (p != 8) return s.fail(error.JpegOnly8Bit);
        s.img_y = s.get16be();
        if (s.img_y == 0) return s.fail(error.JpegDelayedHeight);
        s.img_x = s.get16be();
        if (s.img_x == 0) return s.fail(error.ZeroWidthJpeg);
        if (s.img_y > z.limits.dimension_max) return s.fail(error.DimensionTooLarge);
        if (s.img_x > z.limits.dimension_max) return s.fail(error.DimensionTooLarge);
        const c = s.get8();
        if (c != 3 and c != 1 and c != 4) return s.fail(error.BadJpegComponentCount);
        s.img_n = c;
        if (lf != 8 + 3 * @as(u32, c)) return s.fail(error.BadSofLength);

        z.rgb = 0;
        for (z.components[0..c], 0..) |*comp, i| {
            comp.id = s.get8();
            if (c == 3 and comp.id == "RGB"[i]) z.rgb += 1;
            const q = s.get8();
            comp.h = q >> 4;
            if (comp.h == 0 or comp.h > 4) return s.fail(error.BadHorizontalSampling);
            comp.v = q & 15;
            if (comp.v == 0 or comp.v > 4) return s.fail(error.BadVerticalSampling);
            comp.tq = s.get8();
            if (comp.tq > 3) return s.fail(error.BadQuantizationTable);
        }

        if (scan != .load) return;

        if (!common.sizesValid(z.limits, &.{ s.img_x, s.img_y, c }, 0)) {
            return s.fail(error.ImageTooLarge);
        }

        var h_max: u32 = 1;
        var v_max: u32 = 1;
        for (z.components[0..c]) |comp| {
            h_max = @max(h_max, comp.h);
            v_max = @max(v_max, comp.v);
        }
        // The resamplers handle integer ratios only.
        for (z.components[0..c]) |comp| {
            if (h_max % comp.h != 0) return s.fail(error.BadHorizontalSampling);
            if (v_max % comp.v != 0) return s.fail(error.BadVerticalSampling);
        }

        z.img_h_max = h_max;
        z.img_v_max = v_max;
        z.img_mcu_w = h_max * 8;
        z.img_mcu_h = v_max * 8;
        z.img_mcu_x = (s.img_x + z.img_mcu_w - 1) / z.img_mcu_w;
        z.img_mcu_y = (s.img_y + z.img_mcu_h - 1) / z.img_mcu_h;

        for (z.components[0..c]) |*comp| {
            comp.x = (s.img_x * comp.h + h_max - 1) / h_max;
            comp.y = (s.img_y * comp.v + v_max - 1) / v_max;
            // Whole MCUs decode, also past the image's edge; colour
            // conversion drops the extra samples.
            comp.w2 = z.img_mcu_x * comp.h * 8;
            comp.h2 = z.img_mcu_y * comp.v * 8;
            comp.blocks_w = comp.w2 / 8;
            comp.blocks_h = comp.h2 / 8;
            const samples = @as(usize, comp.w2) * comp.h2;
            comp.data = try z.allocZeroed(u8, &.{ comp.w2, comp.h2 }, 15, samples);
            if (z.progressive) {
                comp.coeff = try z.allocZeroed(i16, &.{ comp.w2, comp.h2, 2 }, 15, samples);
            }
            const blocks = @as(usize, comp.blocks_w) * comp.blocks_h;
            comp.blocks = z.gpa.?.alloc(u8, blocks) catch return s.fail(error.OutOfMemory);
            @memset(comp.blocks, 0);
        }
    }

    /// `stbi__decode_jpeg_header`: the segments before the frame header,
    /// and the frame header, as far as `scan` asks.
    fn decodeHeader(z: *Decoder, scan: Scan) Error!void {
        z.jfif = false;
        z.app14_color_transform = -1; // the valid ones are 0, 1 and 2
        z.marker = marker_none;
        var m = z.getMarker();
        if (m != 0xd8) return z.source.fail(error.NoSoi);
        if (scan == .signature) return;
        m = z.getMarker();
        while (!isSof(m)) {
            try z.processMarker(m);
            m = z.getMarker();
            while (m == marker_none) {
                // Some files pad between segments.
                if (z.source.atEof()) return z.source.fail(error.NoSof);
                m = z.getMarker();
            }
        }
        z.progressive = m == 0xc2;
        try z.processFrameHeader(scan);
    }

    /// `stbi__skip_jpeg_junk_at_end`: past the bytes after a scan to what
    /// looks like a marker.
    fn skipJunkAtEnd(z: *Decoder) u8 {
        const s = z.source;
        while (!s.atEof()) {
            var x = s.get8();
            while (x == 0xff) {
                if (s.atEof()) return marker_none;
                x = s.get8();
                // Neither a stuffed zero nor more fill: a marker.
                if (x != 0x00 and x != 0xff) return x;
            }
        }
        return marker_none;
    }

    /// `stbi__decode_jpeg_image`: every segment up to the end of the image.
    /// A segment that fails after the frame header ends the decode with
    /// what it has, as in the original.
    fn decodeImage(z: *Decoder) Error!void {
        z.restart_interval = 0;
        try z.decodeHeader(.load);
        var m = z.getMarker();
        while (m != 0xd9) {
            if (m == 0xda) {
                try z.processScanHeader();
                try z.parseEntropyCodedData();
                if (z.marker == marker_none) z.marker = z.skipJunkAtEnd();
                m = z.getMarker();
                if (isRestart(m)) m = z.getMarker();
            } else if (m == 0xdc) {
                const ld = z.source.get16be();
                const nl = z.source.get16be();
                if (ld != 4) return z.source.fail(error.BadDnlLength);
                if (nl != z.source.img_y) return z.source.fail(error.BadDnlHeight);
                m = z.getMarker();
            } else {
                z.processMarker(m) catch return;
                m = z.getMarker();
            }
        }
        try z.finish();
    }

    /// Fails unless every block whose samples reach the output was
    /// decoded: the original reads `malloc`'s leftovers there.
    fn checkDecoded(z: *Decoder, used: u4) Error!void {
        for (z.components, 0..) |c, k| {
            if (used & (@as(u4, 1) << @intCast(k)) == 0) continue;
            const w = (c.x + 7) >> 3;
            const h = (c.y + 7) >> 3;
            for (0..h) |j| {
                for (c.blocks[j * c.blocks_w ..][0..w]) |flags| {
                    if (flags & block_decoded == 0) return z.source.fail(error.JpegMissingScanData);
                }
            }
        }
    }

    /// `load_jpeg_image`: the decode, upsampled and colour-converted to `n`
    /// components.
    fn loadImage(z: *Decoder, gpa: std.mem.Allocator, req_comp: u3) Error!common.Decoded {
        const s = z.source;
        s.img_n = 0;
        try z.decodeImage();

        const img_n: u32 = @intCast(s.img_n);
        const n: u32 = if (req_comp != 0) req_comp else if (img_n >= 3) 3 else 1;
        const transform = z.app14_color_transform;
        const is_rgb = img_n == 3 and (z.rgb == 3 or (transform == 0 and !z.jfif));
        const decode_n: u32 = if (img_n == 3 and n < 3 and !is_rgb) 1 else img_n;

        var resamplers: [4]Resampler = undefined;
        for (resamplers[0..decode_n], z.components[0..decode_n]) |*r, *c| {
            // Room for upsampling past the edge by up to 4.
            c.linebuf = gpa.alloc(u8, @as(usize, s.img_x) + 3) catch
                return s.fail(error.OutOfMemory);
            const hs = z.img_h_max / c.h;
            const vs = z.img_v_max / c.v;
            r.* = .{
                .hs = hs,
                .vs = vs,
                .ystep = vs >> 1,
                .w_lores = (s.img_x + hs - 1) / hs,
                .ypos = 0,
                .line0 = 0,
                .line1 = 0,
                .kind = if (hs == 1 and vs == 1)
                    .row_1
                else if (hs == 1 and vs == 2)
                    .v_2
                else if (hs == 2 and vs == 1)
                    .h_2
                else if (hs == 2 and vs == 2)
                    .hv_2
                else
                    .generic,
            };
        }

        const row_len = @as(usize, n) * s.img_x;
        const output = try z.allocChecked(u8, &.{ n, s.img_x, s.img_y }, 1, row_len * s.img_y);
        errdefer gpa.free(output);

        try z.checkDecoded(usedComponents(img_n, n, is_rgb, transform));

        var coutput: [4][]const u8 = undefined;
        const x: usize = s.img_x;
        for (0..s.img_y) |j| {
            const out = output[row_len * j ..][0..row_len];
            for (resamplers[0..decode_n], z.components[0..decode_n], 0..) |*r, *c, k| {
                const y_bot = r.ystep >= (r.vs >> 1);
                const near = if (y_bot) r.line1 else r.line0;
                const far = if (y_bot) r.line0 else r.line1;
                coutput[k] = r.resample(c, near, far)[0..x];
                r.ystep += 1;
                if (r.ystep >= r.vs) {
                    r.ystep = 0;
                    r.line0 = r.line1;
                    r.ypos += 1;
                    if (r.ypos < c.y) r.line1 += c.w2;
                }
            }
            convertRow(out, &coutput, img_n, n, is_rgb, transform);
        }
        return .{
            .pixels = .{ .u8 = output },
            .width = s.img_x,
            .height = s.img_y,
            .channels_in_file = if (img_n >= 3) 3 else 1,
        };
    }
};

/// The components whose samples reach the output, as a mask.
fn usedComponents(img_n: u32, n: u32, is_rgb: bool, transform: i16) u4 {
    if (n >= 3) {
        return switch (img_n) {
            3 => 0b0111,
            4 => if (transform == 0 or transform == 2) 0b1111 else 0b0111,
            else => 0b0001,
        };
    }
    if (is_rgb) return 0b0111;
    if (img_n == 4 and transform == 0) return 0b1111;
    if (img_n == 4 and transform == 2) return 0b1001;
    return 0b0001;
}

/// One output row of `n` components from each component's resampled row.
fn convertRow(
    out: []u8,
    coutput: *const [4][]const u8,
    img_n: u32,
    n: u32,
    is_rgb: bool,
    transform: i16,
) void {
    const x = coutput[0].len;
    const y = coutput[0];
    if (n >= 3) {
        if (img_n == 3) {
            if (is_rgb) {
                for (0..x) |i| {
                    const o = out[i * n ..][0..n];
                    o[0] = y[i];
                    o[1] = coutput[1][i];
                    o[2] = coutput[2][i];
                    if (n == 4) o[3] = 255;
                }
            } else {
                ycbcrToRgbRow(out, y, coutput[1], coutput[2], n);
            }
        } else if (img_n == 4) {
            if (transform == 0) {
                // CMYK
                for (0..x) |i| {
                    const m = coutput[3][i];
                    const o = out[i * n ..][0..n];
                    o[0] = blinn8x8(coutput[0][i], m);
                    o[1] = blinn8x8(coutput[1][i], m);
                    o[2] = blinn8x8(coutput[2][i], m);
                    if (n == 4) o[3] = 255;
                }
            } else if (transform == 2) {
                // YCCK
                ycbcrToRgbRow(out, y, coutput[1], coutput[2], n);
                for (0..x) |i| {
                    const m = coutput[3][i];
                    const o = out[i * n ..][0..3];
                    o[0] = blinn8x8(255 - o[0], m);
                    o[1] = blinn8x8(255 - o[1], m);
                    o[2] = blinn8x8(255 - o[2], m);
                }
            } else {
                // YCbCr, the fourth component left out.
                ycbcrToRgbRow(out, y, coutput[1], coutput[2], n);
            }
        } else {
            for (0..x) |i| {
                const o = out[i * n ..][0..n];
                o[0] = y[i];
                o[1] = y[i];
                o[2] = y[i];
                if (n == 4) o[3] = 255;
            }
        }
        return;
    }
    for (0..x) |i| {
        out[i * n] = if (is_rgb)
            common.computeY(y[i], coutput[1][i], coutput[2][i])
        else if (img_n == 4 and transform == 0) blk: {
            const m = coutput[3][i];
            const r = blinn8x8(coutput[0][i], m);
            const g = blinn8x8(coutput[1][i], m);
            const b = blinn8x8(coutput[2][i], m);
            break :blk common.computeY(r, g, b);
        } else if (img_n == 4 and transform == 2)
            blinn8x8(255 - y[i], coutput[3][i])
        else
            y[i];
        if (n == 2) out[i * n + 1] = 255;
    }
}

/// `stbi__resample`: one component's place in its upsampling.
const Resampler = struct {
    kind: enum { row_1, v_2, h_2, hv_2, generic },
    /// The input rows above and below the output row, as offsets into the
    /// component's samples.
    line0: usize,
    line1: usize,
    hs: u32,
    vs: u32,
    /// Samples in an input row.
    w_lores: u32,
    /// Output rows into the current pair of input rows.
    ystep: u32,
    /// The input row at `line1`.
    ypos: u32,

    fn resample(r: *const Resampler, c: *Component, near: usize, far: usize) []const u8 {
        const in_near = c.data[near..][0..r.w_lores];
        const in_far = c.data[far..][0..r.w_lores];
        const out = c.linebuf;
        switch (r.kind) {
            .row_1 => return c.data[near..],
            .v_2 => resampleRowV2(out, in_near, in_far),
            .h_2 => resampleRowH2(out, in_near),
            .hv_2 => resampleRowHv2(out, in_near, in_far),
            .generic => resampleRowGeneric(out, in_near, r.hs),
        }
        return out;
    }
};

fn div4(x: u32) u8 {
    return @intCast(x >> 2);
}

fn div16(x: u32) u8 {
    return @intCast(x >> 4);
}

/// `stbi__resample_row_v_2`: two output rows per input row, each three
/// parts the nearer input row and one part the farther.
fn resampleRowV2(out: []u8, in_near: []const u8, in_far: []const u8) void {
    for (out[0..in_near.len], in_near, in_far) |*o, near, far| {
        o.* = div4(3 * @as(u32, near) + far + 2);
    }
}

/// `stbi__resample_row_h_2`: two output samples per input sample.
fn resampleRowH2(out: []u8, input: []const u8) void {
    const w = input.len;
    if (w == 1) {
        // One sample: nothing to interpolate.
        out[0] = input[0];
        out[1] = input[0];
        return;
    }
    out[0] = input[0];
    out[1] = div4(@as(u32, input[0]) * 3 + input[1] + 2);
    for (1..w - 1) |i| {
        const n = 3 * @as(u32, input[i]) + 2;
        out[i * 2 + 0] = div4(n + input[i - 1]);
        out[i * 2 + 1] = div4(n + input[i + 1]);
    }
    const i = w - 1;
    out[i * 2 + 0] = div4(@as(u32, input[w - 2]) * 3 + input[w - 1] + 2);
    out[i * 2 + 1] = input[w - 1];
}

/// `stbi__resample_row_hv_2`: 2 by 2 output samples per input sample.
fn resampleRowHv2(out: []u8, in_near: []const u8, in_far: []const u8) void {
    const w = in_near.len;
    if (w == 1) {
        const value = div4(3 * @as(u32, in_near[0]) + in_far[0] + 2);
        out[0] = value;
        out[1] = value;
        return;
    }
    var t1 = 3 * @as(u32, in_near[0]) + in_far[0];
    out[0] = div4(t1 + 2);
    for (1..w) |i| {
        const t0 = t1;
        t1 = 3 * @as(u32, in_near[i]) + in_far[i];
        out[i * 2 - 1] = div16(3 * t0 + t1 + 8);
        out[i * 2] = div16(3 * t1 + t0 + 8);
    }
    out[w * 2 - 1] = div4(t1 + 2);
}

/// `stbi__resample_row_generic`: each input sample repeated `hs` times;
/// the rows repeat too.
fn resampleRowGeneric(out: []u8, in_near: []const u8, hs: u32) void {
    for (in_near, 0..) |sample, i| @memset(out[i * hs ..][0..hs], sample);
}

/// A `@shuffle` mask of `groups` groups of lanes, each `from_a` lanes of
/// the first vector and then `from_b` of the second, starting at group
/// `first` of each.
fn zip(
    comptime groups: usize,
    comptime from_a: usize,
    comptime from_b: usize,
    comptime first: usize,
) @Vector(groups * (from_a + from_b), i32) {
    var mask: [groups * (from_a + from_b)]i32 = undefined;
    for (0..groups) |j| {
        const group = mask[j * (from_a + from_b) ..][0 .. from_a + from_b];
        for (group[0..from_a], 0..) |*lane, t| lane.* = @intCast((first + j) * from_a + t);
        for (group[from_a..], 0..) |*lane, t| {
            lane.* = ~@as(i32, @intCast((first + j) * from_b + t));
        }
    }
    return mask;
}

fn float2fixed(comptime x: f32) i32 {
    return @as(i32, @intFromFloat(x * 4096.0 + 0.5)) << 8;
}

/// Samples converted at once by the vector colour conversion and
/// upsampling.
const lanes = 16;
const U8xN = @Vector(lanes, u8);
const U16xN = @Vector(lanes, u16);
const I32xN = @Vector(lanes, i32);

/// `stbi__YCbCr_to_RGB_row`: a reduced-precision conversion, the one the
/// original's SIMD paths also compute, into `step` (3 or 4) bytes a pixel.
fn ycbcrToRgbRow(out: []u8, y: []const u8, pcb: []const u8, pcr: []const u8, step: u32) void {
    switch (step) {
        3 => ycbcrToRgb(3, out, y, pcb, pcr),
        4 => ycbcrToRgb(4, out, y, pcb, pcr),
        else => unreachable,
    }
}

fn ycbcrToRgb(
    comptime step: usize,
    out: []u8,
    y: []const u8,
    pcb: []const u8,
    pcr: []const u8,
) void {
    var i: usize = 0;
    while (i + lanes <= y.len) : (i += lanes) {
        const luma = y[i..][0..lanes].*;
        const pixels = ycbcrPixels(step, luma, pcb[i..][0..lanes].*, pcr[i..][0..lanes].*);
        out[i * step ..][0 .. lanes * step].* = pixels;
    }
    // The last few pixels, through zero-filled copies.
    const rest = y.len - i;
    if (rest == 0) return;
    var parts: [3][lanes]u8 = @splat(@splat(0));
    for (&parts, [_][]const u8{ y, pcb, pcr }) |*part, samples| {
        @memcpy(part[0..rest], samples[i..]);
    }
    const pixels = ycbcrPixels(step, parts[0], parts[1], parts[2]);
    @memcpy(out[i * step ..][0 .. rest * step], pixels[0 .. rest * step]);
}

/// `lanes` pixels' colour, interleaved; the alpha of RGBA is 255.
fn ycbcrPixels(comptime step: usize, luma: U8xN, blue: U8xN, red: U8xN) [lanes * step]u8 {
    const splat = struct {
        fn f(x: i32) I32xN {
            return @splat(x);
        }
    }.f;
    const y_fixed = (@as(I32xN, luma) << @splat(20)) + splat(1 << 19); // rounding
    const cr = @as(I32xN, red) - splat(128);
    const cb = @as(I32xN, blue) - splat(128);
    const high_half: i32 = @bitCast(@as(u32, 0xffff0000));
    const cb_green = (cb * splat(-float2fixed(0.34414))) & splat(high_half);
    const r = (y_fixed + cr * splat(float2fixed(1.40200))) >> @splat(20);
    const g = (y_fixed + cr * splat(-float2fixed(0.71414)) + cb_green) >> @splat(20);
    const b = (y_fixed + cb * splat(float2fixed(1.77200))) >> @splat(20);
    const clamp = struct {
        fn f(x: I32xN) U8xN {
            return @intCast(@min(@max(x, splat(0)), splat(255)));
        }
    }.f;
    const rg = @shuffle(u8, clamp(r), clamp(g), zip(lanes, 1, 1, 0));
    if (step == 3) return @shuffle(u8, rg, clamp(b), zip(lanes, 2, 1, 0));
    const alpha: U8xN = @splat(255);
    const ba = @shuffle(u8, clamp(b), alpha, zip(lanes, 1, 1, 0));
    return @shuffle(u8, rg, ba, zip(lanes, 2, 2, 0));
}

/// `stbi__blinn_8x8`: `x * y / 255`, rounded.
fn blinn8x8(x: u8, y: u8) u8 {
    const t = @as(u32, x) * y + 128;
    return @intCast((t + (t >> 8)) >> 8);
}

fn isRestart(m: u8) bool {
    return m >= 0xd0 and m <= 0xd7;
}

/// Baseline, extended and progressive frames; every other frame type is
/// an unknown marker.
fn isSof(m: u8) bool {
    return m == 0xc0 or m == 0xc1 or m == 0xc2;
}

/// `stbi__addints_valid`: whether `a + b` fits an `int`.
fn addIntsValid(a: i32, b: i32) bool {
    if ((a >= 0) != (b >= 0)) return true;
    if (a < 0 and b < 0) return a >= std.math.minInt(i32) - b;
    return a <= std.math.maxInt(i32) - b;
}

/// `stbi__mul2shorts_valid`: whether `a * b` fits a `short`, with C's
/// division.
fn mul2ShortsValid(a: i32, b: i32) bool {
    const short_max = std.math.maxInt(i16);
    const short_min = std.math.minInt(i16);
    if (b == 0 or b == -1) return true;
    if ((a >= 0) == (b >= 0)) return a <= @divTrunc(short_max, b);
    if (b < 0) return a <= @divTrunc(short_min, b);
    return a >= @divTrunc(short_min, b);
}

/// `(1 << n) - 1`.
const bmask = blk: {
    var masks: [17]u32 = undefined;
    for (&masks, 0..) |*m, n| m.* = (1 << n) - 1;
    break :blk masks;
};

/// `(-1 << n) + 1`.
const jbias = blk: {
    var biases: [16]i32 = undefined;
    for (&biases, 0..) |*b, n| b.* = 1 - (1 << n);
    break :blk biases;
};

/// The row-major position of each coefficient in zigzag order, and 15
/// more entries, so corrupt input that runs past the end lands on 63.
const dezigzag = [64 + 15]u8{
    0,  1,  8,  16, 9,  2,  3,  10,
    17, 24, 32, 25, 18, 11, 4,  5,
    12, 19, 26, 33, 40, 48, 41, 34,
    27, 20, 13, 6,  7,  14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36,
    29, 22, 15, 23, 30, 37, 44, 51,
    58, 59, 52, 45, 38, 31, 39, 46,
    53, 60, 61, 54, 47, 55, 62, 63,
    63, 63, 63, 63, 63, 63, 63, 63,
    63, 63, 63, 63, 63, 63, 63,
};

// ---- The inverse DCT ------------------------------------------------------

/// `stbi__f2f`: a constant in 12-bit fixed point. The product is a `float`
/// and the rounding term a `double`, as in the C macro.
fn f2f(comptime x: f32) i32 {
    return @intFromFloat(@as(f64, x * 4096) + 0.5);
}

/// The original's 1-D IDCT, derived from the IJG's `jidctint`, over three
/// kinds of arithmetic: `Plain`, the C code's `int`; `Checked`, 64 bits
/// that note any step an `int` cannot hold, where C is undefined; and
/// `Bounds`, the range of every step, at compile time.
fn idct1d(
    comptime A: type,
    a: *A,
    s: [8]A.Num,
    comptime bias: i32,
    comptime shift: u5,
) [8]A.Num {
    var p2 = s[2];
    var p3 = s[6];
    var p1 = a.mul(a.add(p2, p3), f2f(0.5411961));
    var t2 = a.add(p1, a.mul(p3, f2f(-1.847759065)));
    var t3 = a.add(p1, a.mul(p2, f2f(0.765366865)));
    p2 = s[0];
    p3 = s[4];
    var t0 = a.mul(a.add(p2, p3), 4096);
    var t1 = a.mul(a.sub(p2, p3), 4096);
    const x0 = a.add(a.add(t0, t3), a.constant(bias));
    const x3 = a.add(a.sub(t0, t3), a.constant(bias));
    const x1 = a.add(a.add(t1, t2), a.constant(bias));
    const x2 = a.add(a.sub(t1, t2), a.constant(bias));
    t0 = s[7];
    t1 = s[5];
    t2 = s[3];
    t3 = s[1];
    p3 = a.add(t0, t2);
    var p4 = a.add(t1, t3);
    p1 = a.add(t0, t3);
    p2 = a.add(t1, t2);
    const p5 = a.mul(a.add(p3, p4), f2f(1.175875602));
    t0 = a.mul(t0, f2f(0.298631336));
    t1 = a.mul(t1, f2f(2.053119869));
    t2 = a.mul(t2, f2f(3.072711026));
    t3 = a.mul(t3, f2f(1.501321110));
    p1 = a.add(p5, a.mul(p1, f2f(-0.899976223)));
    p2 = a.add(p5, a.mul(p2, f2f(-2.562915447)));
    p3 = a.mul(p3, f2f(-1.961570560));
    p4 = a.mul(p4, f2f(-0.390180644));
    t3 = a.add(t3, a.add(p1, p4));
    t2 = a.add(t2, a.add(p2, p3));
    t1 = a.add(t1, a.add(p2, p4));
    t0 = a.add(t0, a.add(p1, p3));
    return .{
        a.shr(a.add(x0, t3), shift),
        a.shr(a.add(x1, t2), shift),
        a.shr(a.add(x2, t1), shift),
        a.shr(a.add(x3, t0), shift),
        a.shr(a.sub(x3, t0), shift),
        a.shr(a.sub(x2, t1), shift),
        a.shr(a.sub(x1, t2), shift),
        a.shr(a.sub(x0, t3), shift),
    };
}

const Plain = struct {
    const Num = i32;

    inline fn add(_: *Plain, x: i32, y: i32) i32 {
        return x + y;
    }
    inline fn sub(_: *Plain, x: i32, y: i32) i32 {
        return x - y;
    }
    inline fn mul(_: *Plain, x: i32, comptime c: i32) i32 {
        return x * c;
    }
    inline fn shr(_: *Plain, x: i32, comptime shift: u5) i32 {
        return x >> shift;
    }
    inline fn constant(_: *Plain, comptime c: i32) i32 {
        return c;
    }
};

const Checked = struct {
    const Num = i64;
    overflow: bool = false,

    fn note(a: *Checked, x: i64) i64 {
        if (x < std.math.minInt(i32) or x > std.math.maxInt(i32)) a.overflow = true;
        return x;
    }
    fn add(a: *Checked, x: i64, y: i64) i64 {
        return a.note(x + y);
    }
    fn sub(a: *Checked, x: i64, y: i64) i64 {
        return a.note(x - y);
    }
    fn mul(a: *Checked, x: i64, comptime c: i32) i64 {
        return a.note(x * c);
    }
    fn shr(_: *Checked, x: i64, comptime shift: u5) i64 {
        return x >> shift;
    }
    fn constant(_: *Checked, comptime c: i32) i64 {
        return c;
    }
};

const Bounds = struct {
    const Num = struct { lo: i64, hi: i64 };
    /// The largest magnitude of any step.
    peak: i64 = 0,

    fn note(a: *Bounds, x: Num) Num {
        a.peak = @max(a.peak, -x.lo, x.hi);
        return x;
    }
    fn add(a: *Bounds, x: Num, y: Num) Num {
        return a.note(.{ .lo = x.lo + y.lo, .hi = x.hi + y.hi });
    }
    fn sub(a: *Bounds, x: Num, y: Num) Num {
        return a.note(.{ .lo = x.lo - y.hi, .hi = x.hi - y.lo });
    }
    fn mul(a: *Bounds, x: Num, comptime c: i32) Num {
        const p = x.lo * c;
        const q = x.hi * c;
        return a.note(.{ .lo = @min(p, q), .hi = @max(p, q) });
    }
    fn shr(_: *Bounds, x: Num, comptime shift: u5) Num {
        return .{ .lo = x.lo >> shift, .hi = x.hi >> shift };
    }
    fn constant(_: *Bounds, comptime c: i32) Num {
        return .{ .lo = c, .hi = c };
    }
};

/// The rounding of the column pass, which keeps 2 extra bits.
const column_bias = 512;
const column_shift = 10;
/// The rounding of the row pass, which also adds 128 to centre the samples
/// on 0 to 255. Its 17 bits are the constants' 12, the column pass's 2,
/// and the 3 of the two passes' factor of 8.
const row_bias = 65536 + (128 << 17);
const row_shift = 17;
/// The largest input magnitudes for which no step of a pass can overflow
/// an `int`, as the compile-time check below proves. Larger inputs take
/// the checked arithmetic.
const column_input_max = 24100;
const row_input_max = 23911;

comptime {
    for ([_]struct { i64, i32, u5 }{
        .{ column_input_max, column_bias, column_shift },
        .{ row_input_max, row_bias, row_shift },
    }) |pass| {
        var a: Bounds = .{};
        const input: Bounds.Num = .{ .lo = -pass[0], .hi = pass[0] };
        _ = idct1d(Bounds, &a, @splat(input), pass[1], pass[2]);
        if (a.peak > std.math.maxInt(i32)) @compileError("an IDCT input limit is too large");
    }
}

/// One pass over eight values: plain `int` arithmetic where no step can
/// overflow, checked arithmetic otherwise.
fn idctPass(
    s: [8]i32,
    comptime bias: i32,
    comptime shift: u5,
    comptime input_max: u32,
) error{Overflow}![8]i32 {
    var peak: u32 = 0;
    for (s) |value| peak = @max(peak, @abs(value));
    if (peak <= input_max) {
        var a: Plain = .{};
        return idct1d(Plain, &a, s, bias, shift);
    }
    var a: Checked = .{};
    var wide: [8]i64 = undefined;
    for (&wide, s) |*w, value| w.* = value;
    const result = idct1d(Checked, &a, wide, bias, shift);
    if (a.overflow) return error.Overflow;
    var narrow: [8]i32 = undefined;
    for (&narrow, result) |*n, value| n.* = @intCast(value);
    return narrow;
}

/// `stbi__idct_block`: the 8 by 8 samples of a block from its
/// coefficients, into `out` with rows `out_stride` apart. Fails where the
/// original's `int` arithmetic overflows.
fn idctBlock(out: []u8, out_stride: usize, data: *const [64]i16) error{Overflow}!void {
    var val: [64]i32 = undefined;
    for (0..8) |i| {
        var column: [8]i32 = undefined;
        for (&column, 0..) |*value, row| value.* = data[row * 8 + i];
        // A column with only its DC term gives eight equal values.
        const result = if (std.mem.allEqual(i32, column[1..], 0))
            @as([8]i32, @splat(column[0] * 4))
        else
            try idctPass(column, column_bias, column_shift, column_input_max);
        for (result, 0..) |value, row| val[row * 8 + i] = value;
    }
    for (0..8) |row| {
        const result = try idctPass(val[row * 8 ..][0..8].*, row_bias, row_shift, row_input_max);
        const o = out[row * out_stride ..][0..8];
        for (o, result) |*sample, value| sample.* = @intCast(std.math.clamp(value, 0, 255));
    }
}

/// Eight 16-bit values, one per column (or row) of a block.
const I16x8 = @Vector(8, i16);
const I32x8 = @Vector(8, i32);

/// One pass of `stbi__idct_simd`, the original's SSE2 IDCT, over eight
/// columns at once (lane `i` is column `i`): the scalar pass's arithmetic
/// regrouped, with sums of inputs in 16 bits, products and sums in 32 bits,
/// all wrapping, and the results saturated to 16 bits.
fn idctPassSse2(s: [8]I16x8, comptime bias: i32, comptime shift: u5) [8]I16x8 {
    const a = comptime f2f(0.5411961);
    const d = comptime f2f(1.175875602);
    const k = comptime f2f(-1.961570560);
    const l = comptime f2f(-0.390180644);
    const ops = struct {
        fn widen(x: I16x8) I32x8 {
            return x;
        }
        // `_mm_madd_epi16`: two 16-bit products summed. No product of a
        // 16-bit value and these constants (below 2^13) overflows.
        fn rot(x: I16x8, y: I16x8, comptime cx: i32, comptime cy: i32) I32x8 {
            const vx: I32x8 = @splat(cx);
            const vy: I32x8 = @splat(cy);
            return widen(x) * vx +% widen(y) * vy;
        }
        // `_mm_packs_epi32` saturates.
        fn pack(x: I32x8) I16x8 {
            const low: I32x8 = @splat(std.math.minInt(i16));
            const high: I32x8 = @splat(std.math.maxInt(i16));
            return @truncate(@min(@max(x >> @splat(shift), low), high));
        }
    };
    const rot = ops.rot;
    const pack = ops.pack;
    const scale: I32x8 = @splat(4096);
    // Even part.
    const t2e = rot(s[2], s[6], a, a + f2f(-1.847759065));
    const t3e = rot(s[2], s[6], a + f2f(0.765366865), a);
    const t0e = ops.widen(s[0] +% s[4]) * scale;
    const t1e = ops.widen(s[0] -% s[4]) * scale;
    const x0 = t0e +% t3e;
    const x3 = t0e -% t3e;
    const x1 = t1e +% t2e;
    const x2 = t1e -% t2e;
    // Odd part.
    const y0o = rot(s[7], s[3], k + f2f(0.298631336), k);
    const y2o = rot(s[7], s[3], k, k + f2f(3.072711026));
    const y1o = rot(s[5], s[1], l + f2f(2.053119869), l);
    const y3o = rot(s[5], s[1], l, l + f2f(1.501321110));
    const sum17 = s[1] +% s[7];
    const sum35 = s[3] +% s[5];
    const y4o = rot(sum17, sum35, d + f2f(-0.899976223), d);
    const y5o = rot(sum17, sum35, d, d + f2f(-2.562915447));
    const x4 = y0o +% y4o;
    const x5 = y1o +% y5o;
    const x6 = y2o +% y5o;
    const x7 = y3o +% y4o;
    const b: I32x8 = @splat(bias);
    return .{
        pack(x0 +% b +% x7),
        pack(x1 +% b +% x6),
        pack(x2 +% b +% x5),
        pack(x3 +% b +% x4),
        pack(x3 +% b -% x4),
        pack(x2 +% b -% x5),
        pack(x1 +% b -% x6),
        pack(x0 +% b -% x7),
    };
}

/// The 8 by 8 transpose of `rows`, by three rounds of interleaving pairs.
fn transpose(rows: [8]I16x8) [8]I16x8 {
    // `_mm_unpacklo_epi16` and `_mm_unpackhi_epi16`: lanes taken in turn
    // from the low or high halves of `x` and `y` (`~i` is `y`'s lane `i`).
    const low = comptime zip(4, 1, 1, 0);
    const high = comptime zip(4, 1, 1, 4);
    var r = rows;
    inline for ([_][4][2]usize{
        .{ .{ 0, 4 }, .{ 1, 5 }, .{ 2, 6 }, .{ 3, 7 } },
        .{ .{ 0, 2 }, .{ 1, 3 }, .{ 4, 6 }, .{ 5, 7 } },
        .{ .{ 0, 1 }, .{ 2, 3 }, .{ 4, 5 }, .{ 6, 7 } },
    }) |round| {
        inline for (round) |pair| {
            const x = r[pair[0]];
            const y = r[pair[1]];
            r[pair[0]] = @shuffle(i16, x, y, low);
            r[pair[1]] = @shuffle(i16, x, y, high);
        }
    }
    return r;
}

/// `stbi__idct_simd`: the block's samples as the original's SSE2 build
/// computes them. Defined for every input.
fn idctBlockSse2(out: []u8, out_stride: usize, data: *const [64]i16) void {
    var rows: [8]I16x8 = undefined;
    for (&rows, 0..) |*row, i| row.* = data[i * 8 ..][0..8].*;
    const columns = idctPassSse2(rows, column_bias, column_shift);
    const samples = transpose(idctPassSse2(transpose(columns), row_bias, row_shift));
    const zero: I16x8 = @splat(0);
    const max: I16x8 = @splat(255);
    for (samples, 0..) |row, i| {
        const bytes: @Vector(8, u8) = @intCast(@min(@max(row, zero), max));
        out[i * out_stride ..][0..8].* = bytes;
    }
}

// ---- The entry points -----------------------------------------------------

/// `stbi__jpeg_test`: whether the input starts with a JPEG's start-of-image
/// marker. Rewinds.
pub fn detect(source: *Source) bool {
    var z: Decoder = .{ .source = source, .limits = .{} };
    const found = if (z.decodeHeader(.signature)) true else |_| false;
    source.rewind();
    return found;
}

/// `stbi__jpeg_load`.
pub fn load(
    gpa: std.mem.Allocator,
    source: *Source,
    request: common.Request,
) common.Error!common.Decoded {
    const z = gpa.create(Decoder) catch return source.fail(error.OutOfMemory);
    defer gpa.destroy(z);
    z.* = .{ .source = source, .limits = request.options.limits, .gpa = gpa };
    defer z.freeComponents(gpa);
    return z.loadImage(gpa, request.req_comp);
}

/// `stbi__jpeg_info`: the size and channel count from the frame header.
/// Rewinds only on failure, as the original.
pub fn info(source: *Source) ?common.Info {
    var z: Decoder = .{ .source = source, .limits = .{} };
    z.decodeHeader(.header) catch {
        source.rewind();
        return null;
    };
    return .{
        .width = source.img_x,
        .height = source.img_y,
        .channels_in_file = if (source.img_n >= 3) 3 else 1,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// The SSE2 IDCT one lane at a time, as the C intrinsics define each lane:
/// the reference for `idctBlockSse2`'s vector code.
fn idctBlockSse2Lanes(out: []u8, out_stride: usize, data: *const [64]i16) void {
    const pass = struct {
        fn rot(x: i16, y: i16, comptime cx: i32, comptime cy: i32) i32 {
            return @as(i32, x) * cx +% @as(i32, y) * cy;
        }
        fn pack(x: i32, comptime shift: u5) i16 {
            return @intCast(std.math.clamp(x >> shift, std.math.minInt(i16), std.math.maxInt(i16)));
        }
        fn f(s: [8]i16, comptime bias: i32, comptime shift: u5) [8]i16 {
            const a = comptime f2f(0.5411961);
            const d = comptime f2f(1.175875602);
            const k = comptime f2f(-1.961570560);
            const l = comptime f2f(-0.390180644);
            const t2e = rot(s[2], s[6], a, a + f2f(-1.847759065));
            const t3e = rot(s[2], s[6], a + f2f(0.765366865), a);
            const t0e = @as(i32, s[0] +% s[4]) * 4096;
            const t1e = @as(i32, s[0] -% s[4]) * 4096;
            const x0 = t0e +% t3e;
            const x3 = t0e -% t3e;
            const x1 = t1e +% t2e;
            const x2 = t1e -% t2e;
            const y0o = rot(s[7], s[3], k + f2f(0.298631336), k);
            const y2o = rot(s[7], s[3], k, k + f2f(3.072711026));
            const y1o = rot(s[5], s[1], l + f2f(2.053119869), l);
            const y3o = rot(s[5], s[1], l, l + f2f(1.501321110));
            const sum17 = s[1] +% s[7];
            const sum35 = s[3] +% s[5];
            const y4o = rot(sum17, sum35, d + f2f(-0.899976223), d);
            const y5o = rot(sum17, sum35, d, d + f2f(-2.562915447));
            const x4 = y0o +% y4o;
            const x5 = y1o +% y5o;
            const x6 = y2o +% y5o;
            const x7 = y3o +% y4o;
            return .{
                pack(x0 +% bias +% x7, shift),
                pack(x1 +% bias +% x6, shift),
                pack(x2 +% bias +% x5, shift),
                pack(x3 +% bias +% x4, shift),
                pack(x3 +% bias -% x4, shift),
                pack(x2 +% bias -% x5, shift),
                pack(x1 +% bias -% x6, shift),
                pack(x0 +% bias -% x7, shift),
            };
        }
    }.f;
    var val: [64]i16 = undefined;
    for (0..8) |i| {
        var column: [8]i16 = undefined;
        for (&column, 0..) |*value, row| value.* = data[row * 8 + i];
        const result = pass(column, column_bias, column_shift);
        for (result, 0..) |value, row| val[row * 8 + i] = value;
    }
    for (0..8) |row| {
        const result = pass(val[row * 8 ..][0..8].*, row_bias, row_shift);
        const o = out[row * out_stride ..][0..8];
        for (o, result) |*sample, value| sample.* = @intCast(std.math.clamp(value, 0, 255));
    }
}

test "the vector SSE2 IDCT gives the samples of the SSE2 IDCT computed lane by lane" {
    var prng: std.Random.DefaultPrng = .init(0x1dc7);
    const random = prng.random();
    for (0..200_000) |case| {
        var data: [64]i16 = undefined;
        // Full-range values, values of real images' size, and sparse blocks.
        const magnitude: i16 = switch (case % 4) {
            0 => std.math.maxInt(i16),
            1 => 2048,
            else => 300,
        };
        for (&data) |*d| {
            d.* = random.intRangeAtMost(i16, -magnitude, magnitude);
            if (case % 4 == 3 and random.uintLessThan(u8, 8) != 0) d.* = 0;
        }
        if (case < 64) data = @splat(if (case % 2 == 0) std.math.minInt(i16) else 0);
        if (case < 64) data[case] = std.math.maxInt(i16);
        var expected: [8 * 11]u8 = @splat(0xaa);
        var actual: [8 * 11]u8 = @splat(0xaa);
        idctBlockSse2Lanes(&expected, 11, &data);
        idctBlockSse2(&actual, 11, &data);
        try std.testing.expectEqualSlices(u8, &expected, &actual);
    }
}

/// `stbi__YCbCr_to_RGB_row` one pixel at a time: the reference for
/// `ycbcrToRgbRow`'s vector code.
fn ycbcrToRgbPixel(out: []u8, luma: u8, blue: u8, red: u8) void {
    const high_half: i32 = @bitCast(@as(u32, 0xffff0000));
    const y_fixed = (@as(i32, luma) << 20) + (1 << 19);
    const cr = @as(i32, red) - 128;
    const cb = @as(i32, blue) - 128;
    const cb_green = (cb * -float2fixed(0.34414)) & high_half;
    const r = (y_fixed + cr * float2fixed(1.40200)) >> 20;
    const g = (y_fixed + cr * -float2fixed(0.71414) + cb_green) >> 20;
    const b = (y_fixed + cb * float2fixed(1.77200)) >> 20;
    out[0] = @intCast(std.math.clamp(r, 0, 255));
    out[1] = @intCast(std.math.clamp(g, 0, 255));
    out[2] = @intCast(std.math.clamp(b, 0, 255));
    if (out.len == 4) out[3] = 255;
}

test "the vector YCbCr conversion gives the bytes of the scalar one for every colour" {
    var luma: [256 + 9]u8 = undefined;
    for (&luma, 0..) |*y, i| y.* = @truncate(i * 7);
    var blue: [luma.len]u8 = undefined;
    var red: [luma.len]u8 = undefined;
    var expected: [luma.len * 4]u8 = undefined;
    var actual: [luma.len * 4 + 1]u8 = undefined;
    for (0..256) |cb| {
        for (0..256) |cr| {
            // Each row has every luma; its length leaves a part vector.
            const len = 256 + (cb + cr) % 10;
            @memset(blue[0..len], @intCast(cb));
            @memset(red[0..len], @intCast(cr));
            for ([_]u32{ 3, 4 }) |step| {
                const size = len * step;
                for (0..len) |i| {
                    ycbcrToRgbPixel(expected[i * step ..][0..step], luma[i], blue[i], red[i]);
                }
                actual[size] = 0xaa;
                ycbcrToRgbRow(actual[0..size], luma[0..len], blue[0..len], red[0..len], step);
                try std.testing.expectEqualSlices(u8, expected[0..size], actual[0..size]);
                try std.testing.expectEqual(0xaa, actual[size]);
            }
        }
    }
}
