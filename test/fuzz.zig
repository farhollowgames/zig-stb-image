//! Seeded fuzzing: each case mutates one input of a seed set and picks a
//! random request, from a generator seeded by the test's seed and the case
//! number alone, so `zig build sanitize` runs the very cases the tests run
//! through the sanitizer build of the original.

const std = @import("std");
const stbi = @import("stb_image");
const oracle = @import("oracle.zig");
const fuzz_options = @import("fuzz_options");

/// A call the sanitizer build of the original is unsafe on, for one case.
pub const Call = enum { load, info, is_16_bit, gif };

pub const Unsafe = struct {
    case: u32,
    call: Call,
};

pub const Config = struct {
    name: []const u8,
    seed: u64,
    cases: u32 = 1000,
    /// Also load each case as a GIF animation.
    gif: bool = false,
    /// Cases the original is unsafe on, found by `zig build sanitize` with
    /// the default `-Dfuzz-seed`; the port must refuse them.
    unsafe: []const Unsafe = &.{},
    /// Where the original's result depends on memory it never wrote, the
    /// port must refuse the case (`oracle.Expect.same_unless_unwritten`).
    refuse_unwritten: bool = false,
};

pub const Case = struct {
    bytes: []u8,
    request: oracle.Request,
};

/// The seed of one case: the test's seed moved by `-Dfuzz-seed`, and the
/// case number.
pub fn caseSeed(config: Config, case: u32) u64 {
    const base = config.seed +% fuzz_options.fuzz_seed;
    var hasher = std.hash.Wyhash.init(base);
    hasher.update(std.mem.asBytes(&case));
    return hasher.final();
}

/// Makes case `case` of `config` from `inputs`. The caller frees `bytes`.
pub fn makeCase(
    gpa: std.mem.Allocator,
    config: Config,
    case: u32,
    inputs: []const []const u8,
) !Case {
    var prng: std.Random.DefaultPrng = .init(caseSeed(config, case));
    const rng = prng.random();
    const original = inputs[rng.uintLessThan(usize, inputs.len)];
    return .{
        .bytes = try mutate(gpa, rng, original),
        .request = randomRequest(rng),
    };
}

const interesting_bytes = [_]u8{ 0, 1, 2, 3, 4, 7, 8, 15, 16, 0x7f, 0x80, 0xfe, 0xff };
const interesting_words = [_]u32{
    0,          1,       0xff,      0x100,      0x7fff,     0x8000,
    0xffff,     0x10000, 0x1000000, 0x7fffffff, 0x80000000, 0xfffffffe,
    0xffffffff,
};

/// One to four changes to `original`: bit flips, bytes and integers set to
/// edge values, truncation, and ranges deleted, repeated or inserted. Half
/// the positions fall in the first 64 bytes, where the headers are.
pub fn mutate(gpa: std.mem.Allocator, rng: std.Random, original: []const u8) ![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(gpa);
    try bytes.appendSlice(gpa, original);
    const changes = 1 + rng.uintLessThan(u32, 4);
    for (0..changes) |_| {
        const len = bytes.items.len;
        const at = position(rng, len);
        switch (rng.uintLessThan(u32, 9)) {
            0 => if (len > 0) {
                bytes.items[at] ^= @as(u8, 1) << rng.int(u3);
            },
            1 => if (len > 0) {
                bytes.items[at] = rng.int(u8);
            },
            2 => if (len > 0) {
                bytes.items[at] = interesting_bytes[rng.uintLessThan(usize, interesting_bytes.len)];
            },
            3 => {
                const word = interesting_words[rng.uintLessThan(usize, interesting_words.len)];
                const width: usize = if (rng.boolean()) 2 else 4;
                if (len >= width) {
                    const start = @min(at, len - width);
                    var raw: [4]u8 = undefined;
                    if (rng.boolean()) {
                        std.mem.writeInt(u32, &raw, word, .big);
                        @memcpy(bytes.items[start..][0..width], raw[4 - width ..]);
                    } else {
                        std.mem.writeInt(u32, &raw, word, .little);
                        @memcpy(bytes.items[start..][0..width], raw[0..width]);
                    }
                }
            },
            4 => bytes.shrinkRetainingCapacity(if (len > 0) rng.uintLessThan(usize, len) else 0),
            5 => if (len > 0) {
                const count = @min(1 + rng.uintLessThan(usize, 64), len - at);
                try bytes.replaceRange(gpa, at, count, &.{});
            },
            6 => if (len > 0) {
                const count = @min(1 + rng.uintLessThan(usize, 64), len - at);
                const copy = try gpa.dupe(u8, bytes.items[at..][0..count]);
                defer gpa.free(copy);
                try bytes.insertSlice(gpa, position(rng, len + 1), copy);
            },
            7 => {
                var random: [16]u8 = undefined;
                const count = 1 + rng.uintLessThan(usize, random.len);
                rng.bytes(random[0..count]);
                try bytes.insertSlice(gpa, @min(at, len), random[0..count]);
            },
            8 => if (len > 0) {
                // A run of one value, as corrupt images often have.
                const count = @min(1 + rng.uintLessThan(usize, 256), len - at);
                @memset(bytes.items[at..][0..count], rng.int(u8));
            },
            else => unreachable,
        }
    }
    return bytes.toOwnedSlice(gpa);
}

fn position(rng: std.Random, len: usize) usize {
    if (len == 0) return 0;
    if (rng.boolean()) return rng.uintLessThan(usize, @min(len, 64));
    return rng.uintLessThan(usize, len);
}

/// A random bit depth, component count, flip and reader, mostly loads
/// from memory.
pub fn randomRequest(rng: std.Random) oracle.Request {
    const pick = rng.uintLessThan(u32, 10);
    const bits: oracle.Bits = if (pick < 6) .u8 else if (pick < 8) .u16 else .f32;
    const via_pick = rng.uintLessThan(u32, 20);
    const via: oracle.Via = if (via_pick < 15) .memory else if (via_pick < 19) .callbacks else .file;
    var options: stbi.Options = .{
        .components = @fromBackingInt(rng.uintLessThan(u3, 5)),
        .flip_vertically = rng.uintLessThan(u32, 4) == 0,
        .unpremultiply = rng.uintLessThan(u32, 4) == 0,
        .convert_iphone_png = rng.uintLessThan(u32, 4) == 0,
    };
    if (rng.uintLessThan(u32, 10) == 0) {
        options.ldr_to_hdr_gamma = 0.5 + rng.float(f32) * 2.5;
        options.ldr_to_hdr_scale = 0.25 + rng.float(f32) * 4;
        options.hdr_to_ldr_gamma = 0.5 + rng.float(f32) * 2.5;
        options.hdr_to_ldr_scale = 0.25 + rng.float(f32) * 4;
    }
    return .{
        .bits = bits,
        .via = via,
        .file_offset = if (via == .file) rng.uintLessThan(u32, 6) else 0,
        .options = options,
    };
}

fn unsafeCall(config: Config, case: u32, call: Call) bool {
    if (fuzz_options.fuzz_seed != 0 or fuzz_options.sanitize) return false;
    for (config.unsafe) |entry| {
        if (entry.case == case and entry.call == call) return true;
    }
    return false;
}

/// Runs every case of `config` on `inputs`: the case's load, and the info
/// and 16-bit queries from memory, against the original.
pub fn run(gpa: std.mem.Allocator, config: Config, inputs: []const []const u8) !void {
    std.debug.assert(inputs.len > 0);
    const first: u32 = if (fuzz_options.fuzz_replay) |replay| @intCast(replay) else 0;
    const last: u32 = if (fuzz_options.fuzz_replay) |replay| @intCast(replay + 1) else config.cases;
    for (first..last) |index| {
        const case_number: u32 = @intCast(index);
        const case = try makeCase(gpa, config, case_number, inputs);
        defer gpa.free(case.bytes);
        const label: oracle.Label = .{
            .name = config.name,
            .seed = config.seed +% fuzz_options.fuzz_seed,
            .case = case_number,
        };
        const load_expect: oracle.Expect = if (unsafeCall(config, case_number, .load))
            .port_refuses
        else if (config.refuse_unwritten)
            .same_unless_unwritten
        else
            .same;
        try oracle.expectLoadSame(gpa, case.bytes, case.request, label, load_expect);
        if (!unsafeCall(config, case_number, .info)) {
            try oracle.expectQuerySame(case.bytes, .info, .memory, label);
        }
        if (!unsafeCall(config, case_number, .is_16_bit)) {
            try oracle.expectQuerySame(case.bytes, .is_16_bit, .memory, label);
        }
        if (config.gif and !unsafeCall(config, case_number, .gif)) {
            try oracle.expectGifSame(gpa, case.bytes, case.request.options, label);
        }
    }
}

/// Checks that the port refuses every load in `config.unsafe` with one of
/// `refusals`, the errors it gives where the original is unsafe.
pub fn expectUnsafeRefused(
    gpa: std.mem.Allocator,
    config: Config,
    inputs: []const []const u8,
    refusals: []const anyerror,
) !void {
    if (fuzz_options.fuzz_seed != 0 or fuzz_options.sanitize) return;
    for (config.unsafe) |entry| {
        if (entry.call != .load) continue;
        const case = try makeCase(gpa, config, entry.case, inputs);
        defer gpa.free(case.bytes);
        // From memory and at 8 bits: a float load reports any failure as
        // an unknown image type.
        if (stbi.loadFromMemory(u8, gpa, case.bytes, case.request.options)) |image| {
            var copy = image;
            copy.deinit(gpa);
        } else |err| {
            for (refusals) |refusal| {
                if (err == refusal) break;
            } else {
                const name = config.name;
                std.debug.print("\n[{s} case {d}] refused with {t}\n", .{ name, entry.case, err });
                return error.TestUnexpectedResult;
            }
            continue;
        }
        const name = config.name;
        std.debug.print("\n[{s} case {d}] listed as unsafe, but decodes\n", .{ name, entry.case });
        return error.TestUnexpectedResult;
    }
}

/// The `Unsafe` entries of loads, from their case numbers.
pub fn unsafeLoads(comptime cases: []const u32) [cases.len]Unsafe {
    var list: [cases.len]Unsafe = undefined;
    for (cases, &list) |case, *entry| entry.* = .{ .case = case, .call = .load };
    return list;
}
