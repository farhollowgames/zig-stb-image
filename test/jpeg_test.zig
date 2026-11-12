//! The JPEG decoder against the original: the corpora, images made by a
//! small encoder below (every sampling factor, colour model, restart
//! interval, frame type, truncation and header fault the decoder branches
//! on), seeded fuzzing, and the port's own refusals where the original
//! reads memory it never wrote or overflows an `int`.

const std = @import("std");
const stbi = @import("stb_image");
const oracle = @import("oracle.zig");
const fuzz_options = @import("fuzz_options");
const corpus = @import("corpus.zig");
const fuzz = @import("fuzz.zig");

const gpa = std.testing.allocator;

/// Every load of `bytes` against the original; where the original's
/// result depends on memory it never wrote, the port must refuse.
fn expectAll(bytes: []const u8, name: []const u8) !void {
    try oracle.expectAll(gpa, bytes, .{ .name = name }, .same_unless_unwritten);
}

/// Corpus files whose coefficients overflow an `int` in the original's
/// scalar IDCT (the sanitizer run finds them): the scalar port refuses them,
/// the SSE2 port gives the SSE2 build's samples.
const idct_overflows = [_][]const u8{
    "imagetestsuite/b0b8914cc5f7a6eff409f16d8cc236c5.jpg",
};

fn expectCorpus(root: corpus.Root, sub_dir: []const u8) !usize {
    var set = try corpus.load(gpa, std.testing.io, root, sub_dir, &.{ ".jpg", ".jpeg" });
    defer set.deinit(gpa);
    for (set.entries) |entry| {
        const overflows = for (idct_overflows) |name| {
            if (std.mem.endsWith(u8, entry.name, name)) break true;
        } else false;
        if (overflows and stbi.jpeg_idct == .scalar) {
            try std.testing.expectError(
                error.JpegIdctOverflow,
                stbi.loadFromMemory(u8, gpa, entry.bytes, .{}),
            );
            try oracle.expectAll(gpa, entry.bytes, .{ .name = entry.name }, .port_refuses);
        } else try expectAll(entry.bytes, entry.name);
    }
    return set.entries.len;
}

test "jpeg: the jpeg-decoder test images decode as in the original" {
    // reftest (with mozilla/ and lossless/), crashtest (with
    // imagetestsuite/) and icc.
    const count = try expectCorpus(.jpeg_decoder, "tests");
    try std.testing.expect(count >= 150);
}

test "jpeg: the libjpeg-turbo test images decode as in the original" {
    const count = try expectCorpus(.libjpeg_turbo, "testimages");
    try std.testing.expect(count >= 4);
}

test "jpeg: the image-rs JPEG test images decode as in the original" {
    try std.testing.expect(try expectCorpus(.image_rs, "tests/images/jpg") >= 6);
    try std.testing.expect(try expectCorpus(.image_rs, "tests/regression/jpg") >= 1);
}

test "jpeg: arithmetic-coded and 12-bit JPEGs are refused for the original's reasons" {
    var set = try corpus.load(gpa, std.testing.io, .libjpeg_turbo, "testimages", &.{".jpg"});
    defer set.deinit(gpa);
    var checked: u32 = 0;
    for (set.entries) |entry| {
        const expected: ?stbi.Error = if (std.mem.endsWith(u8, entry.name, "testimgari.jpg"))
            error.UnknownJpegMarker // SOF9, arithmetic coding
        else if (std.mem.endsWith(u8, entry.name, "monkey12.jpg"))
            error.JpegOnly8Bit
        else
            null;
        const err = expected orelse continue;
        try std.testing.expectError(err, stbi.loadFromMemory(u8, gpa, entry.bytes, .{}));
        try oracle.expectLoadSame(gpa, entry.bytes, .{}, .{ .name = entry.name }, .same);
        checked += 1;
    }
    try std.testing.expectEqual(2, checked);
}

// ---- A small JPEG encoder -------------------------------------------------

const Component = struct {
    id: u8,
    h: u4 = 1,
    v: u4 = 1,
    tq: u8 = 0,
};

const grey = [_]Component{.{ .id = 1 }};
const ycbcr_420 = [_]Component{
    .{ .id = 1, .h = 2, .v = 2 },
    .{ .id = 2, .tq = 1 },
    .{ .id = 3, .tq = 1 },
};

const Frame = enum(u8) { baseline = 0xc0, extended = 0xc1, progressive = 0xc2 };

/// What `encode` makes: a frame of `components` with coefficients from
/// `seed`, as one interleaved scan or one scan per component (baseline),
/// or a progressive script with spectral selection and successive
/// approximation.
const Image = struct {
    width: u16 = 16,
    height: u16 = 16,
    components: []const Component = &grey,
    frame: Frame = .baseline,
    interleaved: bool = true,
    jfif: bool = true,
    adobe_transform: ?u8 = null,
    quant: enum { small, sixteen, one } = .small,
    restart_interval: u16 = 0,
    /// Write the restart markers the interval asks for.
    restart_markers: bool = true,
    /// Every block of every component gets these coefficients (zigzag
    /// order) instead of generated ones.
    fill: ?Block = null,
    /// A DNL segment with this height after the first scan.
    dnl: ?u16 = null,
    /// The standard Huffman tables of the JPEG spec's annex K, else
    /// tables with every symbol and codes up to 16 bits.
    standard_tables: bool = false,
    /// Write the Huffman tables before the frame header instead of after.
    dht_before_sof: bool = false,
    /// The largest DC magnitude; AC values are smaller.
    amplitude: i32 = 60,
    seed: u64 = 1,
};

const HuffmanSpec = struct {
    counts: [16]u8,
    values: []const u8,
};

const dc_standard: HuffmanSpec = .{
    .counts = .{ 0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0 },
    .values = &.{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 },
};

const ac_standard: HuffmanSpec = .{
    .counts = .{ 0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 0x7d },
    .values = &.{
        0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12, 0x21, 0x31, 0x41, 0x06, 0x13, 0x51,
        0x61, 0x07, 0x22, 0x71, 0x14, 0x32, 0x81, 0x91, 0xa1, 0x08, 0x23, 0x42, 0xb1, 0xc1,
        0x15, 0x52, 0xd1, 0xf0, 0x24, 0x33, 0x62, 0x72, 0x82, 0x09, 0x0a, 0x16, 0x17, 0x18,
        0x19, 0x1a, 0x25, 0x26, 0x27, 0x28, 0x29, 0x2a, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39,
        0x3a, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49, 0x4a, 0x53, 0x54, 0x55, 0x56, 0x57,
        0x58, 0x59, 0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x6a, 0x73, 0x74, 0x75,
        0x76, 0x77, 0x78, 0x79, 0x7a, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89, 0x8a, 0x92,
        0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9a, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7,
        0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3,
        0xc4, 0xc5, 0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8,
        0xd9, 0xda, 0xe1, 0xe2, 0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea, 0xf1, 0xf2,
        0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8, 0xf9, 0xfa,
    },
};

/// DC categories 0 to 15, two codes of each length from 2 to 9 bits.
const dc_full: HuffmanSpec = .{
    .counts = .{ 0, 2, 2, 2, 2, 2, 2, 2, 2, 0, 0, 0, 0, 0, 0, 0 },
    .values = &.{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 },
};

/// All 256 AC symbols (every run with every size, end-of-band runs
/// included), shorter codes for the smaller ones, 80 codes of 16 bits.
const ac_full: HuffmanSpec = .{
    .counts = .{ 0, 1, 1, 2, 4, 8, 8, 16, 32, 32, 32, 40, 0, 0, 0, 80 },
    .values = &ac_full_values,
};

const ac_full_values = blk: {
    @setEvalBranchQuota(20000);
    var values: [256]u8 = undefined;
    var n: usize = 0;
    for (0..31) |sum| {
        for (0..16) |run| {
            for (0..16) |size| {
                if (run + size == sum) {
                    values[n] = run << 4 | size;
                    n += 1;
                }
            }
        }
    }
    break :blk values;
};

test "jpeg: the encoder's Huffman tables are complete prefix codes" {
    for ([_]HuffmanSpec{ dc_standard, ac_standard, dc_full, ac_full }) |spec| {
        var total: usize = 0;
        var kraft: f64 = 0;
        for (spec.counts, 1..) |count, len| {
            total += count;
            const codes: u32 = @as(u32, 1) << @intCast(len);
            kraft += @as(f64, @floatFromInt(count)) / @as(f64, @floatFromInt(codes));
        }
        try std.testing.expectEqual(spec.values.len, total);
        try std.testing.expect(kraft < 1);
        var seen: [256]bool = @splat(false);
        for (spec.values) |value| {
            try std.testing.expect(!seen[value]);
            seen[value] = true;
        }
    }
    // The annex K AC table: end of block, 16 zeros, and every run with
    // sizes 1 to 10.
    for (0..16) |run| {
        for (1..11) |size| {
            const symbol: u8 = @intCast(run << 4 | size);
            try std.testing.expect(std.mem.indexOfScalar(u8, ac_standard.values, symbol) != null);
        }
    }
}

const Codes = struct {
    code: [256]u16 = @splat(0),
    size: [256]u8 = @splat(0),

    fn init(spec: HuffmanSpec) Codes {
        var codes: Codes = .{};
        var code: u32 = 0;
        var k: usize = 0;
        for (spec.counts, 1..) |count, len| {
            for (0..count) |_| {
                codes.code[spec.values[k]] = @intCast(code);
                codes.size[spec.values[k]] = @intCast(len);
                code += 1;
                k += 1;
            }
            code <<= 1;
        }
        return codes;
    }
};

const BitWriter = struct {
    out: *std.ArrayList(u8),
    byte: u8 = 0,
    count: u4 = 0,

    fn bits(w: *BitWriter, value: u32, n: u32) !void {
        var i = n;
        while (i > 0) {
            i -= 1;
            w.byte = (w.byte << 1) | @as(u8, @intCast((value >> @intCast(i)) & 1));
            w.count += 1;
            if (w.count == 8) {
                try w.out.append(gpa, w.byte);
                if (w.byte == 0xff) try w.out.append(gpa, 0x00);
                w.byte = 0;
                w.count = 0;
            }
        }
    }

    fn symbol(w: *BitWriter, codes: *const Codes, value: u8) !void {
        std.debug.assert(codes.size[value] != 0);
        try w.bits(codes.code[value], codes.size[value]);
    }

    /// Pads the last byte with ones, as before a marker.
    fn flush(w: *BitWriter) !void {
        while (w.count != 0) try w.bits(1, 1);
    }
};

fn bitLength(magnitude: u32) u32 {
    return 32 - @clz(magnitude);
}

/// A value in a category's bits: negative values as `value - 1` in them.
fn putValue(w: *BitWriter, value: i32, size: u32) !void {
    if (size == 0) return;
    const raw: i32 = if (value < 0) value + (@as(i32, 1) << @intCast(size)) - 1 else value;
    try w.bits(@intCast(raw), size);
}

const Layout = struct {
    h_max: u32,
    v_max: u32,
    mcu_x: u32,
    mcu_y: u32,

    fn init(image: Image) Layout {
        var h_max: u32 = 1;
        var v_max: u32 = 1;
        for (image.components) |c| {
            h_max = @max(h_max, c.h);
            v_max = @max(v_max, c.v);
        }
        return .{
            .h_max = h_max,
            .v_max = v_max,
            .mcu_x = (@as(u32, image.width) + 8 * h_max - 1) / (8 * h_max),
            .mcu_y = (@as(u32, image.height) + 8 * v_max - 1) / (8 * v_max),
        };
    }

    fn blocksAcross(l: Layout, c: Component) u32 {
        return l.mcu_x * c.h;
    }

    /// The blocks of a scan of `c` alone: the component's own samples.
    fn ownBlocks(l: Layout, image: Image, c: Component) [2]u32 {
        const x = (@as(u32, image.width) * c.h + l.h_max - 1) / l.h_max;
        const y = (@as(u32, image.height) * c.v + l.v_max - 1) / l.v_max;
        return .{ (x + 7) / 8, (y + 7) / 8 };
    }
};

const Block = [64]i32;

const Encoder = struct {
    image: Image,
    layout: Layout,
    out: std.ArrayList(u8) = .empty,
    /// Per component, every block of whole MCUs, coefficients in zigzag
    /// order.
    coefficients: [4][]Block = @splat(&.{}),
    dc: Codes,
    ac: Codes,

    fn dnlSegment(e: *Encoder) !void {
        const height = e.image.dnl orelse return;
        try e.segment(0xdc, &.{ @intCast(height >> 8), @truncate(height) });
    }

    fn deinit(e: *Encoder) void {
        e.out.deinit(gpa);
        for (e.coefficients) |blocks| gpa.free(blocks);
    }

    fn segment(e: *Encoder, marker: u8, payload: []const u8) !void {
        try e.out.appendSlice(gpa, &.{ 0xff, marker });
        const length = payload.len + 2;
        try e.out.appendSlice(gpa, &.{ @intCast(length >> 8), @truncate(length) });
        try e.out.appendSlice(gpa, payload);
    }

    fn generate(e: *Encoder) !void {
        var prng: std.Random.DefaultPrng = .init(e.image.seed);
        const rng = prng.random();
        const amplitude = e.image.amplitude;
        for (e.image.components, 0..) |c, n| {
            const count = e.layout.blocksAcross(c) * e.layout.mcu_y * c.v;
            const blocks = try gpa.alloc(Block, count);
            e.coefficients[n] = blocks;
            for (blocks, 0..) |*block, i| {
                if (e.image.fill) |fill| {
                    block.* = fill;
                    continue;
                }
                block.* = @splat(0);
                // A slow ramp across the image and some noise.
                const ramp: i32 = @intCast(i % 23);
                const dc = ramp * 6 - 66 + rng.intRangeAtMost(i32, -9, 9);
                block[0] = std.math.clamp(dc, -amplitude, amplitude);
                const ac_max: i32 = @max(1, @divTrunc(amplitude, 3));
                for (1..64) |k| {
                    if (rng.uintLessThan(u32, 3 + @as(u32, @intCast(k)) / 4) != 0) continue;
                    const limit: i32 = @max(1, @divTrunc(ac_max, 1 + @as(i32, @intCast(k / 8))));
                    var value = rng.intRangeAtMost(i32, -limit, limit);
                    if (value == 0) value = 1;
                    block[k] = value;
                }
            }
        }
    }

    fn header(e: *Encoder) !void {
        const image = e.image;
        try e.out.appendSlice(gpa, &.{ 0xff, 0xd8 });
        if (image.jfif) try e.segment(0xe0, "JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00");
        if (image.adobe_transform) |transform| {
            try e.segment(0xee, &.{ 'A', 'd', 'o', 'b', 'e', 0, 100, 0, 0, 0, 0, transform });
        }
        var used: [4]bool = @splat(false);
        for (image.components) |c| used[c.tq & 3] = true;
        for (used, 0..) |is_used, t| {
            if (!is_used) continue;
            var payload: std.ArrayList(u8) = .empty;
            defer payload.deinit(gpa);
            const sixteen = image.quant == .sixteen;
            try payload.append(gpa, @as(u8, @intFromBool(sixteen)) << 4 | @as(u8, @intCast(t)));
            for (0..64) |k| {
                switch (image.quant) {
                    .sixteen => {
                        const q: u16 = @intCast(200 + k * 5 + t);
                        try payload.appendSlice(gpa, &.{ @intCast(q >> 8), @truncate(q) });
                    },
                    .small => try payload.append(gpa, @intCast(1 + (k + t) % 7)),
                    .one => try payload.append(gpa, 1),
                }
            }
            try e.segment(0xdb, payload.items);
        }
        if (image.dht_before_sof) try e.huffmanTables();
        var sof: std.ArrayList(u8) = .empty;
        defer sof.deinit(gpa);
        try sof.appendSlice(gpa, &.{
            8,
            @intCast(image.height >> 8),
            @truncate(image.height),
            @intCast(image.width >> 8),
            @truncate(image.width),
            @intCast(image.components.len),
        });
        for (image.components) |c| {
            try sof.appendSlice(gpa, &.{ c.id, @as(u8, c.h) << 4 | c.v, c.tq });
        }
        try e.segment(@backingInt(image.frame), sof.items);
        if (!image.dht_before_sof) try e.huffmanTables();
        if (image.restart_interval != 0) {
            const ri = image.restart_interval;
            try e.segment(0xdd, &.{ @intCast(ri >> 8), @truncate(ri) });
        }
    }

    /// One DHT segment per table: DC 0, AC 0, DC 1, AC 1.
    fn huffmanTables(e: *Encoder) !void {
        const dc_spec = if (e.image.standard_tables) dc_standard else dc_full;
        const ac_spec = if (e.image.standard_tables) ac_standard else ac_full;
        for ([_]u8{ 0x00, 0x10, 0x01, 0x11 }) |class_and_id| {
            const spec = if (class_and_id >> 4 == 0) dc_spec else ac_spec;
            var payload: std.ArrayList(u8) = .empty;
            defer payload.deinit(gpa);
            try payload.append(gpa, class_and_id);
            try payload.appendSlice(gpa, &spec.counts);
            try payload.appendSlice(gpa, spec.values);
            try e.segment(0xc4, payload.items);
        }
    }

    const Pass = struct {
        components: []const u8,
        ss: u8 = 0,
        se: u8 = 63,
        ah: u4 = 0,
        al: u4 = 0,
    };

    const ScanState = struct {
        w: BitWriter,
        pred: [4]i32 = @splat(0),
        eobrun: u32 = 0,
        /// Correction bits of the blocks in the end-of-band run.
        pending: std.ArrayList(u1) = .empty,
    };

    fn scan(e: *Encoder, pass: Pass) !void {
        var sos: std.ArrayList(u8) = .empty;
        defer sos.deinit(gpa);
        try sos.append(gpa, @intCast(pass.components.len));
        for (pass.components) |n| {
            const table: u8 = if (n == 0) 0 else 1;
            try sos.appendSlice(gpa, &.{ e.image.components[n].id, table << 4 | table });
        }
        try sos.appendSlice(gpa, &.{ pass.ss, pass.se, @as(u8, pass.ah) << 4 | pass.al });
        try e.segment(0xda, sos.items);

        var state: ScanState = .{ .w = .{ .out = &e.out } };
        defer state.pending.deinit(gpa);
        const layout = e.layout;
        const single = pass.components.len == 1;
        const own = if (single)
            layout.ownBlocks(e.image, e.image.components[pass.components[0]])
        else
            .{ 0, 0 };
        const mcus = if (single) own[0] * own[1] else layout.mcu_x * layout.mcu_y;
        const interval = e.image.restart_interval;
        for (0..mcus) |mcu| {
            if (interval != 0 and mcu != 0 and mcu % interval == 0) {
                try e.endOfBandRun(&state);
                if (e.image.restart_markers) {
                    try state.w.flush();
                    const rst: u8 = @intCast((mcu / interval - 1) % 8);
                    try e.out.appendSlice(gpa, &.{ 0xff, 0xd0 + rst });
                    state.pred = @splat(0);
                }
            }
            if (single) {
                const n = pass.components[0];
                const c = e.image.components[n];
                const bx = mcu % own[0];
                const by = mcu / own[0];
                try e.encodeBlock(&state, pass, n, by * layout.blocksAcross(c) + bx);
            } else {
                const i = mcu % layout.mcu_x;
                const j = mcu / layout.mcu_x;
                for (pass.components) |n| {
                    const c = e.image.components[n];
                    for (0..c.v) |y| {
                        for (0..c.h) |x| {
                            const bx = i * c.h + x;
                            const by = j * c.v + y;
                            try e.encodeBlock(&state, pass, n, by * layout.blocksAcross(c) + bx);
                        }
                    }
                }
            }
        }
        try e.endOfBandRun(&state);
        try state.w.flush();
    }

    fn encodeBlock(e: *Encoder, state: *ScanState, pass: Pass, n: usize, index: usize) !void {
        const coef = &e.coefficients[n][index];
        const w = &state.w;
        if (pass.ss == 0) {
            if (pass.ah == 0) {
                const value = coef[0] >> pass.al;
                const diff = value - state.pred[n];
                state.pred[n] = value;
                const size = bitLength(@abs(diff));
                try w.symbol(&e.dc, @intCast(size));
                try putValue(w, diff, size);
            } else {
                try w.bits(@intCast((coef[0] >> pass.al) & 1), 1);
            }
            if (e.image.frame != .progressive) try e.acBaseline(w, coef);
            return;
        }
        if (pass.ah == 0) return e.acFirst(state, pass, coef);
        return e.acRefine(state, pass, coef);
    }

    fn acBaseline(e: *Encoder, w: *BitWriter, coef: *const Block) !void {
        var run: u32 = 0;
        for (coef[1..]) |value| {
            if (value == 0) {
                run += 1;
                continue;
            }
            while (run > 15) : (run -= 16) try w.symbol(&e.ac, 0xf0);
            const size = bitLength(@abs(value));
            try w.symbol(&e.ac, @intCast(run << 4 | size));
            try putValue(w, value, size);
            run = 0;
        }
        if (run > 0) try w.symbol(&e.ac, 0x00);
    }

    fn endOfBandRun(e: *Encoder, state: *ScanState) !void {
        if (state.eobrun == 0) return;
        const size = bitLength(state.eobrun) - 1;
        try state.w.symbol(&e.ac, @intCast(size << 4));
        try state.w.bits(state.eobrun, size);
        state.eobrun = 0;
        for (state.pending.items) |bit| try state.w.bits(bit, 1);
        state.pending.clearRetainingCapacity();
    }

    fn acFirst(e: *Encoder, state: *ScanState, pass: Pass, coef: *const Block) !void {
        const w = &state.w;
        var run: u32 = 0;
        for (coef[pass.ss .. @as(usize, pass.se) + 1]) |value| {
            const magnitude = @abs(value) >> pass.al;
            if (magnitude == 0) {
                run += 1;
                continue;
            }
            try e.endOfBandRun(state);
            while (run > 15) : (run -= 16) try w.symbol(&e.ac, 0xf0);
            const size = bitLength(magnitude);
            try w.symbol(&e.ac, @intCast(run << 4 | size));
            const unsigned: i32 = @intCast(magnitude);
            const signed = if (value < 0) -unsigned else unsigned;
            try putValue(w, signed, size);
            run = 0;
        }
        if (run > 0) {
            state.eobrun += 1;
            if (state.eobrun == 0x7fff) try e.endOfBandRun(state);
        }
    }

    /// Successive approximation of AC coefficients, as libjpeg's
    /// `encode_mcu_AC_refine`.
    fn acRefine(e: *Encoder, state: *ScanState, pass: Pass, coef: *const Block) !void {
        const w = &state.w;
        const band = coef[pass.ss .. @as(usize, pass.se) + 1];
        var last_new: usize = 0;
        for (band, 0..) |value, k| {
            if (@abs(value) >> pass.al == 1) last_new = k;
        }
        var corrections: std.ArrayList(u1) = .empty;
        defer corrections.deinit(gpa);
        var run: u32 = 0;
        for (band, 0..) |value, k| {
            const magnitude = @abs(value) >> pass.al;
            if (magnitude == 0) {
                run += 1;
                continue;
            }
            while (run > 15 and k <= last_new) {
                try e.endOfBandRun(state);
                try w.symbol(&e.ac, 0xf0);
                run -= 16;
                for (corrections.items) |bit| try w.bits(bit, 1);
                corrections.clearRetainingCapacity();
            }
            if (magnitude > 1) {
                try corrections.append(gpa, @intCast(magnitude & 1));
                continue;
            }
            try e.endOfBandRun(state);
            try w.symbol(&e.ac, @intCast(run << 4 | 1));
            try w.bits(@intFromBool(value > 0), 1);
            for (corrections.items) |bit| try w.bits(bit, 1);
            corrections.clearRetainingCapacity();
            run = 0;
        }
        if (run > 0 or corrections.items.len > 0) {
            state.eobrun += 1;
            try state.pending.appendSlice(gpa, corrections.items);
            if (state.eobrun == 0x7fff) try e.endOfBandRun(state);
        }
    }
};

/// A JPEG file of `image`. The caller frees it.
fn encode(image: Image) ![]u8 {
    var e: Encoder = .{
        .image = image,
        .layout = .init(image),
        .dc = .init(if (image.standard_tables) dc_standard else dc_full),
        .ac = .init(if (image.standard_tables) ac_standard else ac_full),
    };
    defer e.deinit();
    try e.generate();
    try e.header();
    const all = [_]u8{ 0, 1, 2, 3 };
    const components = all[0..image.components.len];
    if (image.frame != .progressive) {
        if (image.interleaved) {
            try e.scan(.{ .components = components });
            try e.dnlSegment();
        } else for (components, 0..) |*n, i| {
            try e.scan(.{ .components = n[0..1] });
            if (i == 0) try e.dnlSegment();
        }
    } else {
        // DC first at reduced precision, AC bands at reduced precision,
        // then the refinements of both.
        try e.scan(.{ .components = components, .se = 0, .al = 1 });
        try e.dnlSegment();
        for (components) |*n| {
            try e.scan(.{ .components = n[0..1], .ss = 1, .se = 5, .al = 1 });
            try e.scan(.{ .components = n[0..1], .ss = 6, .se = 63, .al = 1 });
        }
        try e.scan(.{ .components = components, .se = 0, .ah = 1, .al = 0 });
        for (components) |*n| try e.scan(.{ .components = n[0..1], .ss = 1, .se = 63, .ah = 1 });
    }
    try e.out.appendSlice(gpa, &.{ 0xff, 0xd9 });
    return e.out.toOwnedSlice(gpa);
}

// ---- Images made by the encoder -------------------------------------------

/// Every load of `image` against the original, which decodes it.
fn expectImage(image: Image, name: []const u8) !void {
    const bytes = try encode(image);
    defer gpa.free(bytes);
    var decoded = try stbi.loadFromMemory(u8, gpa, bytes, .{});
    decoded.deinit(gpa);
    try oracle.expectAll(gpa, bytes, .{ .name = name }, .same);
}

/// Every load of `bytes` against the original, which fails or reads
/// memory it never wrote: the port fails with `expected`.
fn expectRefused(bytes: []const u8, expected: stbi.Error, name: []const u8) !void {
    try std.testing.expectError(expected, stbi.loadFromMemory(u8, gpa, bytes, .{}));
    try expectAll(bytes, name);
}

fn findMarker(bytes: []const u8, marker: u8) usize {
    return findMarkerFrom(bytes, 0, marker);
}

/// The offset of the first `marker` at or after `start`.
fn findMarkerFrom(bytes: []const u8, start: usize, marker: u8) usize {
    var i: usize = start;
    while (i + 1 < bytes.len) : (i += 1) {
        if (bytes[i] == 0xff and bytes[i + 1] == marker) return i;
    }
    unreachable;
}

test "jpeg: 1x1 images decode as in the original" {
    try expectImage(.{ .width = 1, .height = 1 }, "1x1 grey");
    try expectImage(.{ .width = 1, .height = 1, .components = &ycbcr_420 }, "1x1 4:2:0");
    try expectImage(.{ .width = 1, .height = 1, .frame = .progressive }, "1x1 progressive");
    try expectImage(.{
        .width = 1,
        .height = 1,
        .components = &ycbcr_420,
        .frame = .progressive,
    }, "1x1 progressive 4:2:0");
}

fn ratioValid(a: u4, b: u4) bool {
    const max = @max(a, b);
    return max % a == 0 and max % b == 0;
}

test "jpeg: every sampling factor combination the original accepts decodes as in the original" {
    var count: u32 = 0;
    for (1..5) |yh| for (1..5) |yv| for (1..5) |ch| for (1..5) |cv| {
        const y: Component = .{ .id = 1, .h = @intCast(yh), .v = @intCast(yv) };
        const c: Component = .{ .id = 2, .h = @intCast(ch), .v = @intCast(cv), .tq = 1 };
        if (!ratioValid(y.h, c.h) or !ratioValid(y.v, c.v)) continue;
        const components = [_]Component{ y, c, .{ .id = 3, .h = c.h, .v = c.v, .tq = 1 } };
        for ([_]bool{ true, false }) |interleaved| {
            try expectImage(.{
                .width = 37,
                .height = 29,
                .components = &components,
                .interleaved = interleaved,
                .seed = count,
            }, "sampling factors");
        }
        count += 1;
    };
    try std.testing.expectEqual(144, count);
    // The chroma components with factors of their own.
    for ([_][3][2]u4{
        .{ .{ 4, 4 }, .{ 2, 2 }, .{ 1, 1 } },
        .{ .{ 2, 1 }, .{ 1, 1 }, .{ 2, 1 } },
        .{ .{ 1, 2 }, .{ 1, 1 }, .{ 1, 2 } },
        .{ .{ 3, 1 }, .{ 1, 1 }, .{ 3, 1 } },
        .{ .{ 1, 1 }, .{ 2, 2 }, .{ 4, 4 } },
        .{ .{ 4, 2 }, .{ 2, 1 }, .{ 1, 2 } },
    }) |factors| {
        var components: [3]Component = undefined;
        for (&components, factors, 0..) |*c, f, i| {
            c.* = .{ .id = @intCast(i + 1), .h = f[0], .v = f[1], .tq = @intFromBool(i != 0) };
        }
        try expectImage(.{ .width = 45, .height = 21, .components = &components }, "own factors");
    }
    // One component: the MCU is one block whatever its factors.
    for (1..5) |h| for (1..5) |v| {
        const components = [_]Component{.{ .id = 1, .h = @intCast(h), .v = @intCast(v) }};
        try expectImage(.{ .width = 19, .height = 23, .components = &components }, "grey factors");
    };
}

test "jpeg: sampling factors with a fractional ratio are refused as in the original" {
    var count: u32 = 0;
    for (1..5) |yh| for (1..5) |yv| for (1..5) |ch| for (1..5) |cv| {
        const y: Component = .{ .id = 1, .h = @intCast(yh), .v = @intCast(yv) };
        const c: Component = .{ .id = 2, .h = @intCast(ch), .v = @intCast(cv) };
        if (ratioValid(y.h, c.h) and ratioValid(y.v, c.v)) continue;
        const components = [_]Component{ y, c, .{ .id = 3, .h = c.h, .v = c.v } };
        const bytes = try encode(.{ .width = 24, .height = 24, .components = &components });
        defer gpa.free(bytes);
        // Each component in turn, horizontal before vertical.
        const h_max = @max(y.h, c.h);
        const v_max = @max(y.v, c.v);
        const expected: stbi.Error = if (h_max % y.h != 0)
            error.BadHorizontalSampling
        else if (v_max % y.v != 0)
            error.BadVerticalSampling
        else if (h_max % c.h != 0)
            error.BadHorizontalSampling
        else
            error.BadVerticalSampling;
        try expectRefused(bytes, expected, "fractional factors");
        count += 1;
    };
    try std.testing.expectEqual(256 - 144, count);
}

test "jpeg: sizes that are not whole blocks or MCUs decode as in the original" {
    for ([_]u16{ 1, 2, 7, 8, 9, 15, 16, 17, 31, 33 }) |width| {
        for ([_]u16{ 1, 7, 9, 16, 17 }) |height| {
            try expectImage(.{
                .width = width,
                .height = height,
                .components = &ycbcr_420,
            }, "4:2:0 size");
            const ycbcr_422 = [_]Component{
                .{ .id = 1, .h = 2 },
                .{ .id = 2, .tq = 1 },
                .{ .id = 3, .tq = 1 },
            };
            try expectImage(.{
                .width = width,
                .height = height,
                .components = &ycbcr_422,
            }, "4:2:2 size");
            try expectImage(.{
                .width = width,
                .height = height,
                .frame = .progressive,
            }, "progressive size");
        }
    }
}

const rgb_ids = [_]Component{ .{ .id = 'R' }, .{ .id = 'G' }, .{ .id = 'B' } };
const three = [_]Component{ .{ .id = 1 }, .{ .id = 2 }, .{ .id = 3 } };
const four = [_]Component{ .{ .id = 1 }, .{ .id = 2 }, .{ .id = 3 }, .{ .id = 4 } };
const four_subsampled = [_]Component{
    .{ .id = 1, .h = 2, .v = 2 },
    .{ .id = 2 },
    .{ .id = 3 },
    .{ .id = 4, .h = 2, .v = 2 },
};

test "jpeg: every colour model decodes as in the original" {
    // JFIF YCbCr, and YCbCr with neither JFIF nor Adobe segments.
    try expectImage(.{ .width = 21, .height = 13, .components = &three }, "JFIF YCbCr");
    try expectImage(.{
        .width = 21,
        .height = 13,
        .components = &three,
        .jfif = false,
    }, "plain YCbCr");
    // Adobe: transform 0 is RGB unless JFIF says otherwise, 1 is YCbCr.
    for ([_]bool{ false, true }) |jfif| {
        for ([_]u8{ 0, 1, 2, 7 }) |transform| {
            try expectImage(.{
                .width = 21,
                .height = 13,
                .components = &three,
                .jfif = jfif,
                .adobe_transform = transform,
            }, "Adobe three components");
            for ([_][]const Component{ &four, &four_subsampled }) |components| {
                try expectImage(.{
                    .width = 21,
                    .height = 13,
                    .components = components,
                    .jfif = jfif,
                    .adobe_transform = transform,
                }, "Adobe four components");
            }
        }
    }
    // Components named R, G and B are RGB whatever the segments say.
    try expectImage(.{ .width = 21, .height = 13, .components = &rgb_ids }, "RGB ids");
    try expectImage(.{
        .width = 21,
        .height = 13,
        .components = &rgb_ids,
        .adobe_transform = 1,
    }, "RGB ids, Adobe 1");
    // Four components with no Adobe segment: YCbCr, the fourth left out.
    try expectImage(.{ .width = 21, .height = 13, .components = &four }, "four components");
    try expectImage(.{
        .width = 21,
        .height = 13,
        .components = &four,
        .frame = .progressive,
        .adobe_transform = 2,
    }, "progressive YCCK");
    try expectImage(.{
        .width = 21,
        .height = 13,
        .components = &four,
        .frame = .progressive,
        .adobe_transform = 0,
    }, "progressive CMYK");
}

test "jpeg: the frame types and table variants decode as in the original" {
    for ([_]Frame{ .baseline, .extended, .progressive }) |frame| {
        for ([_]bool{ false, true }) |standard_tables| {
            if (frame == .progressive and standard_tables) continue; // no end-of-band runs
            try expectImage(.{
                .width = 40,
                .height = 24,
                .components = &ycbcr_420,
                .frame = frame,
                .standard_tables = standard_tables,
            }, "frame");
            try expectImage(.{
                .width = 40,
                .height = 24,
                .components = &ycbcr_420,
                .frame = frame,
                .quant = .sixteen,
                .amplitude = 4,
            }, "16-bit quantization");
        }
    }
    try expectImage(.{
        .width = 40,
        .height = 24,
        .components = &three,
        .frame = .progressive,
    }, "progressive 4:4:4");
}

test "jpeg: restart intervals and every restart marker decode as in the original" {
    for ([_]u16{ 1, 2, 7, 9 }) |interval| {
        for ([_]bool{ true, false }) |interleaved| {
            try expectImage(.{
                .width = 80,
                .height = 48,
                .components = &ycbcr_420,
                .interleaved = interleaved,
                .restart_interval = interval,
            }, "restart");
        }
        try expectImage(.{
            .width = 80,
            .height = 48,
            .components = &ycbcr_420,
            .frame = .progressive,
            .restart_interval = interval,
        }, "progressive restart");
    }
}

test "jpeg: a restart interval without its markers stops the scan, and the port refuses the rest" {
    const bytes = try encode(.{
        .width = 80,
        .height = 48,
        .components = &ycbcr_420,
        .restart_interval = 3,
        .restart_markers = false,
    });
    defer gpa.free(bytes);
    try expectRefused(bytes, error.JpegMissingScanData, "restart markers missing");
}

test "jpeg: a DNL segment decodes as in the original, and a wrong one fails as there" {
    try expectImage(.{ .width = 30, .height = 20, .components = &ycbcr_420, .dnl = 20 }, "DNL");
    try expectImage(.{
        .width = 30,
        .height = 20,
        .components = &ycbcr_420,
        .interleaved = false,
        .dnl = 20,
    }, "DNL after the first scan");
    try expectImage(.{
        .width = 30,
        .height = 20,
        .frame = .progressive,
        .dnl = 20,
    }, "progressive DNL");
    const wrong = try encode(.{ .width = 30, .height = 20, .components = &ycbcr_420, .dnl = 19 });
    defer gpa.free(wrong);
    try expectRefused(wrong, error.BadDnlHeight, "DNL height");
    const at = findMarker(wrong, 0xdc);
    wrong[at + 3] = 5;
    try expectRefused(wrong, error.BadDnlLength, "DNL length");
}

test "jpeg: the largest dimensions decode as in the original" {
    try expectImage(.{ .width = 65535, .height = 1 }, "65535 wide");
    try expectImage(.{ .width = 1, .height = 65535 }, "65535 high");
    try expectImage(.{ .width = 65535, .height = 3, .components = &ycbcr_420 }, "65535 wide 4:2:0");
}

test "jpeg: the limits options refuse what is past them" {
    const bytes = try encode(.{ .width = 101, .height = 50 });
    defer gpa.free(bytes);
    try std.testing.expectError(error.DimensionTooLarge, stbi.loadFromMemory(u8, gpa, bytes, .{
        .limits = .{ .dimension_max = 100 },
    }));
    var image = try stbi.loadFromMemory(u8, gpa, bytes, .{ .limits = .{ .dimension_max = 101 } });
    image.deinit(gpa);
    try std.testing.expectError(error.ImageTooLarge, stbi.loadFromMemory(u8, gpa, bytes, .{
        .limits = .{ .bytes_max = 101 * 50 - 1 },
    }));
}

test "jpeg: a flat image decodes to its colour" {
    var fill: Block = @splat(0);
    fill[0] = 80; // (80 * 1) / 8 + 128 = 138
    const bytes = try encode(.{ .width = 9, .height = 9, .quant = .one, .fill = fill });
    defer gpa.free(bytes);
    var image = try stbi.loadFromMemory(u8, gpa, bytes, .{});
    defer image.deinit(gpa);
    for (image.pixels) |pixel| try std.testing.expectEqual(138, pixel);
}

// ---- The IDCT -------------------------------------------------------------

test "jpeg: coefficients past 16 bits give the samples of the original build the port follows" {
    // The SSE2 IDCT wraps sums of two coefficients to 16 bits where the
    // scalar one keeps them whole.
    var fill: Block = @splat(0);
    fill[0] = 10000;
    fill[14] = -9250;
    const bytes = try encode(.{ .width = 8, .height = 8, .quant = .one, .fill = fill });
    defer gpa.free(bytes);
    // The sanitizer run calls the original only in child processes.
    if (!fuzz_options.sanitize) try std.testing.expect(oracle.originalBuildsDisagree(bytes, .{}));
    try expectImage(.{ .width = 8, .height = 8, .quant = .one, .fill = fill }, "builds disagree");
}

test "jpeg: coefficients that overflow the original's scalar IDCT are refused by the scalar port" {
    const image: Image = .{ .width = 8, .height = 8, .quant = .one, .fill = @splat(32767) };
    switch (stbi.jpeg_idct) {
        .scalar => {
            const bytes = try encode(image);
            defer gpa.free(bytes);
            try std.testing.expectError(
                error.JpegIdctOverflow,
                stbi.loadFromMemory(u8, gpa, bytes, .{}),
            );
            try oracle.expectAll(gpa, bytes, .{ .name = "IDCT overflow" }, .port_refuses);
        },
        .sse2 => try expectImage(image, "IDCT overflow"),
    }
}

// ---- Header faults --------------------------------------------------------

/// `bytes` with `patch` at offsets from the first `marker`.
const Patch = struct { offset: usize, value: u8 };

/// Every load of `image`, patched, against the original; the port fails,
/// with `expected` where it is given.
fn expectFault(
    image: Image,
    marker: u8,
    patches: []const Patch,
    expected: ?stbi.Error,
    name: []const u8,
) !void {
    const bytes = try encode(image);
    defer gpa.free(bytes);
    const at = findMarker(bytes, marker);
    for (patches) |patch| bytes[at + patch.offset] = patch.value;
    try expectFails(bytes, expected, name);
}

fn expectFails(bytes: []const u8, expected: ?stbi.Error, name: []const u8) !void {
    if (stbi.loadFromMemory(u8, gpa, bytes, .{})) |decoded| {
        var image = decoded;
        image.deinit(gpa);
        std.debug.print("[{s}] the port decodes it\n", .{name});
        return error.TestUnexpectedResult;
    } else |err| if (expected) |e| try std.testing.expectEqual(e, err);
    try expectAll(bytes, name);
}

/// `bytes` with `extra` inserted at `at`. The caller frees it.
fn inserted(bytes: []const u8, at: usize, extra: []const u8) ![]u8 {
    const out = try gpa.alloc(u8, bytes.len + extra.len);
    @memcpy(out[0..at], bytes[0..at]);
    @memcpy(out[at..][0..extra.len], extra);
    @memcpy(out[at + extra.len ..], bytes[at..]);
    return out;
}

test "jpeg: faults in the frame header fail as in the original" {
    const grey_16: Image = .{};
    const p = struct {
        fn at(offset: usize, value: u8) [1]Patch {
            return .{.{ .offset = offset, .value = value }};
        }
    }.at;
    // The payload starts 4 bytes after the marker: precision, height,
    // width, component count, then id, sampling factors and table.
    try expectFault(grey_16, 0xc0, &p(3, 5), error.BadSofLength, "SOF length");
    try expectFault(grey_16, 0xc0, &p(4, 12), error.JpegOnly8Bit, "12-bit");
    try expectFault(grey_16, 0xc0, &p(4, 16), error.JpegOnly8Bit, "16-bit");
    try expectFault(grey_16, 0xc0, &p(6, 0), error.JpegDelayedHeight, "zero height");
    try expectFault(grey_16, 0xc0, &p(8, 0), error.ZeroWidthJpeg, "zero width");
    try expectFault(grey_16, 0xc0, &p(9, 2), error.BadJpegComponentCount, "two components");
    try expectFault(grey_16, 0xc0, &p(9, 3), error.BadSofLength, "three components");
    try expectFault(grey_16, 0xc0, &p(11, 0x01), error.BadHorizontalSampling, "H 0");
    try expectFault(grey_16, 0xc0, &p(11, 0x51), error.BadHorizontalSampling, "H 5");
    try expectFault(grey_16, 0xc0, &p(11, 0x10), error.BadVerticalSampling, "V 0");
    try expectFault(grey_16, 0xc0, &p(11, 0x15), error.BadVerticalSampling, "V 5");
    try expectFault(grey_16, 0xc0, &p(12, 4), error.BadQuantizationTable, "TQ 4");
    try expectFault(grey_16, 0xc0, &p(1, 0xc3), error.UnknownJpegMarker, "lossless");
    try expectFault(grey_16, 0xc0, &p(1, 0xc9), error.UnknownJpegMarker, "arithmetic");
    try expectFault(grey_16, 0xc0, &p(1, 0xcd), error.UnknownJpegMarker, "arithmetic progressive");
}

test "jpeg: faults in the tables fail as in the original" {
    const p = struct {
        fn at(offset: usize, value: u8) [1]Patch {
            return .{.{ .offset = offset, .value = value }};
        }
    }.at;
    // DQT: precision and table, then 64 values.
    try expectFault(.{}, 0xdb, &p(4, 0x20), error.BadDqtType, "DQT type");
    try expectFault(.{}, 0xdb, &p(4, 0x04), error.BadDqtTable, "DQT table");
    try expectFault(.{}, 0xdb, &p(3, 0x42), null, "DQT length short");
    try expectFault(.{}, 0xdb, &p(3, 0x44), null, "DQT length long");
    try expectFault(.{ .quant = .sixteen }, 0xdb, &p(3, 0x82), null, "16-bit DQT length");
    // DHT, read before the frame so that its faults fail the load: class
    // and table, 16 counts, then the values.
    const early: Image = .{ .dht_before_sof = true };
    try expectFault(early, 0xc4, &p(4, 0x20), error.BadDhtHeader, "DHT class");
    try expectFault(early, 0xc4, &p(4, 0x04), error.BadDhtHeader, "DHT table");
    try expectFault(early, 0xc4, &p(20, 255), error.BadDhtHeader, "DHT over 256 codes");
    try expectFault(early, 0xc4, &.{
        .{ .offset = 5, .value = 2 },
        .{ .offset = 6, .value = 0 },
    }, error.JpegBadCodeLengths, "DHT code lengths");
    try expectFault(early, 0xc4, &p(3, 0x22), null, "DHT length short");
    try expectFault(early, 0xc4, &p(3, 0x24), null, "DHT length long");
    // After the frame header a bad table ends the image without its scans,
    // which the original then reads unwritten.
    try expectFault(.{}, 0xc4, &p(4, 0x20), error.JpegMissingScanData, "late DHT class");
    try expectFault(
        .{ .restart_interval = 1 },
        0xdd,
        &p(3, 5),
        error.JpegMissingScanData,
        "DRI length",
    );
    // APP0 length below 2.
    try expectFault(.{}, 0xe0, &p(3, 1), error.BadAppLength, "APP length");
    try expectFault(.{}, 0xe0, &p(2, 0x7f), null, "APP length past the end");
}

test "jpeg: markers, fill bytes and junk between segments load as in the original" {
    const bytes = try encode(.{ .components = &ycbcr_420 });
    defer gpa.free(bytes);
    const sof = findMarker(bytes, 0xc0);
    const cases = [_]struct { at: usize, extra: []const u8, fails: ?stbi.Error, name: []const u8 }{
        .{ .at = 2, .extra = "\xff\xfe\x00\x05abc", .fails = null, .name = "comment" },
        .{
            .at = 2,
            .extra = "\xff\xfe\x00\x01",
            .fails = error.BadComLength,
            .name = "COM length",
        },
        .{
            .at = 2,
            .extra = "\xff\xc8\x00\x02",
            .fails = error.UnknownJpegMarker,
            .name = "JPG marker",
        },
        .{ .at = 2, .extra = "\xff\xef\x00\x02", .fails = null, .name = "APP15" },
        .{ .at = 2, .extra = "\x00", .fails = error.ExpectedMarker, .name = "junk after SOI" },
        .{ .at = sof, .extra = "\xff\xff\xff", .fails = null, .name = "fill bytes" },
        .{ .at = sof, .extra = "\x00\x12\x34", .fails = null, .name = "junk before SOF" },
        .{
            .at = sof + 19,
            .extra = "\x00",
            .fails = error.JpegMissingScanData,
            .name = "junk after SOF",
        },
        .{
            .at = bytes.len - 2,
            .extra = "\x00\xff\xff\x12",
            .fails = null,
            .name = "junk before EOI",
        },
    };
    for (cases) |case| {
        const changed = try inserted(bytes, case.at, case.extra);
        defer gpa.free(changed);
        if (case.fails) |err| {
            try expectFails(changed, err, case.name);
        } else {
            var image = try stbi.loadFromMemory(u8, gpa, changed, .{});
            image.deinit(gpa);
            try expectAll(changed, case.name);
        }
    }
    // No EOI at all.
    try expectAll(bytes[0 .. bytes.len - 2], "no EOI");
}

test "jpeg: faults in the scan headers fail as in the original" {
    const p = struct {
        fn at(offset: usize, value: u8) [1]Patch {
            return .{.{ .offset = offset, .value = value }};
        }
    }.at;
    // Baseline 4:2:0, one interleaved scan: count, three ids with tables,
    // Ss, Se, Ah and Al.
    const colour: Image = .{ .components = &ycbcr_420 };
    try expectFault(colour, 0xda, &p(4, 0), error.BadSosComponentCount, "no components");
    try expectFault(colour, 0xda, &p(4, 4), error.BadSosComponentCount, "four of three");
    try expectFault(colour, 0xda, &p(3, 11), error.BadSosLength, "SOS length");
    try expectFault(colour, 0xda, &p(5, 9), null, "unknown component");
    try expectFault(colour, 0xda, &p(6, 0x40), error.BadDcHuffman, "DC table 4");
    try expectFault(colour, 0xda, &p(6, 0x04), error.BadAcHuffman, "AC table 4");
    try expectFault(colour, 0xda, &p(11, 1), error.BadSos, "baseline Ss");
    try expectFault(colour, 0xda, &p(13, 0x10), error.BadSos, "baseline Ah");
    try expectFault(colour, 0xda, &p(13, 0x01), error.BadSos, "baseline Al");
    // A baseline Se other than 63 counts as 63.
    {
        const bytes = try encode(colour);
        defer gpa.free(bytes);
        bytes[findMarker(bytes, 0xda) + 12] = 0;
        try expectAll(bytes, "baseline Se 0");
    }
    // Progressive grey: the first scan is DC, Ss = Se = 0, Al = 1.
    const progressive: Image = .{ .frame = .progressive };
    try expectFault(progressive, 0xda, &p(8, 5), error.CannotMergeDcAndAc, "DC with AC");
    try expectFault(progressive, 0xda, &p(7, 64), error.BadSos, "Ss 64");
    try expectFault(progressive, 0xda, &p(8, 64), error.BadSos, "Se 64");
    try expectFault(progressive, 0xda, &p(7, 1), error.BadSos, "Ss past Se");
    try expectFault(progressive, 0xda, &p(9, 0xe1), error.BadSos, "Ah 14");
    try expectFault(progressive, 0xda, &p(9, 0x0e), error.BadSos, "Al 14");
    try expectFault(
        .{ .frame = .progressive, .components = &ycbcr_420 },
        0xda,
        &p(12, 5),
        error.CannotMergeDcAndAc,
        "interleaved DC with AC",
    );
}

// ---- Truncation and missing scans -----------------------------------------

test "jpeg: a JPEG cut short anywhere in its segments or scans loads as in the original" {
    const images = [_]Image{
        .{ .width = 20, .height = 18, .components = &ycbcr_420, .restart_interval = 1 },
        .{ .width = 20, .height = 18, .components = &ycbcr_420, .frame = .progressive },
        .{ .width = 12, .height = 10, .components = &four, .adobe_transform = 2 },
    };
    var name_buffer: [64]u8 = undefined;
    for (images, 0..) |image, n| {
        const bytes = try encode(image);
        defer gpa.free(bytes);
        var cuts: std.ArrayList(usize) = .empty;
        defer cuts.deinit(gpa);
        for (0..bytes.len - 1) |i| {
            const marker = bytes[i + 1];
            if (bytes[i] != 0xff or marker == 0 or marker == 0xff) continue;
            const has_length = marker < 0xd0 or marker > 0xd9;
            const length: usize = if (has_length)
                @as(usize, bytes[i + 2]) << 8 | bytes[i + 3]
            else
                0;
            for ([_]usize{ 0, 1, 2, 3, 4, 2 + length / 2, 2 + length }) |cut| {
                if (i + cut < bytes.len) try cuts.append(gpa, i + cut);
            }
        }
        for (1..8) |eighth| try cuts.append(gpa, bytes.len * eighth / 8);
        for (cuts.items) |cut| {
            const name = try std.fmt.bufPrint(&name_buffer, "image {d} cut at {d}", .{ n, cut });
            try expectAll(bytes[0..cut], name);
        }
    }
}

test "jpeg: an image missing some components' scans loads only where they are not needed" {
    const bytes = try encode(.{
        .width = 16,
        .height = 16,
        .components = &three,
        .interleaved = false,
    });
    defer gpa.free(bytes);
    const first = findMarker(bytes, 0xda);
    const second = findMarkerFrom(bytes, first + 2, 0xda);
    // The Y scan alone: grey output needs nothing else.
    const y_only = try inserted(bytes[0..second], second, "\xff\xd9");
    defer gpa.free(y_only);
    var grey_image = try stbi.loadFromMemory(u8, gpa, y_only, .{ .components = .grey });
    grey_image.deinit(gpa);
    try std.testing.expectError(
        error.JpegMissingScanData,
        stbi.loadFromMemory(u8, gpa, y_only, .{ .components = .rgb }),
    );
    try expectAll(y_only, "Y scan only");
    // No scan at all.
    const none = try inserted(bytes[0..first], first, "\xff\xd9");
    defer gpa.free(none);
    try expectRefused(none, error.JpegMissingScanData, "no scans");
}

// ---- Allocation failure ---------------------------------------------------

fn loadAll(allocator: std.mem.Allocator, bytes: []const u8) !void {
    var image = try stbi.loadFromMemory(u8, allocator, bytes, .{ .components = .rgba });
    image.deinit(allocator);
    var wide = try stbi.loadFromMemory(u16, allocator, bytes, .{});
    wide.deinit(allocator);
    var float = try stbi.loadFromMemory(f32, allocator, bytes, .{ .flip_vertically = true });
    float.deinit(allocator);
}

test "jpeg: every allocation of a decode can fail without a leak" {
    const images = [_]Image{
        .{ .width = 20, .height = 18, .components = &ycbcr_420, .restart_interval = 2 },
        .{ .width = 20, .height = 18, .components = &ycbcr_420, .frame = .progressive },
        .{ .width = 12, .height = 10, .components = &four, .adobe_transform = 2 },
    };
    for (images) |image| {
        const bytes = try encode(image);
        defer gpa.free(bytes);
        try std.testing.checkAllAllocationFailures(gpa, loadAll, .{bytes});
    }
}

// ---- Fuzzing --------------------------------------------------------------

fn encodeAll(images: []const Image, out: [][]const u8) !void {
    for (images, out, 0..) |image, *bytes, done| {
        errdefer for (out[0..done]) |b| gpa.free(b);
        bytes.* = try encode(image);
    }
}

test "jpeg: fuzzed baseline JPEGs load as in the original" {
    const images = [_]Image{
        .{ .width = 13, .height = 11 },
        .{ .width = 20, .height = 18, .components = &ycbcr_420, .restart_interval = 2 },
        .{ .width = 17, .height = 9, .components = &four, .adobe_transform = 2 },
        .{
            .width = 24,
            .height = 8,
            .components = &three,
            .interleaved = false,
            .standard_tables = true,
        },
        .{ .width = 9, .height = 9, .components = &ycbcr_420, .dnl = 9, .quant = .sixteen },
    };
    var inputs: [images.len][]const u8 = undefined;
    try encodeAll(&images, &inputs);
    defer for (inputs) |bytes| gpa.free(bytes);
    try fuzz.run(gpa, .{
        .name = "baseline JPEG",
        .seed = 0x4a504547_0001,
        .cases = 1500,
        .unsafe = if (stbi.jpeg_idct == .scalar) &baseline_idct_overflows else &.{},
        .refuse_unwritten = true,
    }, &inputs);
}

test "jpeg: fuzzed progressive JPEGs load as in the original" {
    const images = [_]Image{
        .{ .width = 13, .height = 11, .frame = .progressive },
        .{ .width = 20, .height = 18, .components = &ycbcr_420, .frame = .progressive },
        .{
            .width = 17,
            .height = 9,
            .components = &four,
            .frame = .progressive,
            .restart_interval = 1,
        },
    };
    var inputs: [images.len][]const u8 = undefined;
    try encodeAll(&images, &inputs);
    defer for (inputs) |bytes| gpa.free(bytes);
    try fuzz.run(gpa, .{
        .name = "progressive JPEG",
        .seed = 0x4a504547_0002,
        .cases = 1500,
        .unsafe = if (stbi.jpeg_idct == .scalar) &progressive_idct_overflows else &.{},
        .refuse_unwritten = true,
    }, &inputs);
}

/// Fuzz cases whose coefficients overflow an `int` in the original's
/// scalar IDCT. The sanitizer reports each overflow check only once per
/// run, so each case was confirmed alone with
/// `zig build sanitize -Dfuzz-replay=<case>`.
const baseline_idct_overflows = [_]fuzz.Unsafe{
    .{ .case = 12, .call = .load },
    .{ .case = 17, .call = .load },
    .{ .case = 248, .call = .load },
    .{ .case = 310, .call = .load },
    .{ .case = 316, .call = .load },
    .{ .case = 543, .call = .load },
    .{ .case = 591, .call = .load },
    .{ .case = 657, .call = .load },
    .{ .case = 665, .call = .load },
    .{ .case = 754, .call = .load },
    .{ .case = 1018, .call = .load },
    .{ .case = 1080, .call = .load },
    .{ .case = 1312, .call = .load },
    .{ .case = 1334, .call = .load },
    .{ .case = 1345, .call = .load },
};
const progressive_idct_overflows = [_]fuzz.Unsafe{};
