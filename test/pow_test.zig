//! The port's `pow` against the C library's, which the original calls: on
//! every input stb_image gives it at the default gamma, on random gammas,
//! and on random and special doubles.

const std = @import("std");
const stbi = @import("stb_image");
const oracle = @import("oracle.zig");

const theirs = oracle.upstream.simd_pow;

fn bits(x: f64) u64 {
    return @bitCast(x);
}

fn expectSamePow(x: f64, y: f64) !void {
    const expected = theirs(x, y);
    const actual = stbi.pow(x, y);
    if (bits(expected) != bits(actual)) {
        std.debug.print("\npow({x}, {x}): the C library gives {x} (0x{x}), the port {x} (0x{x})\n", .{
            x, y, expected, bits(expected), actual, bits(actual),
        });
        return error.TestUnexpectedResult;
    }
}

/// The 8-bit to float conversion: `pow(k / 255.0f, gamma)` with float
/// operands made double.
fn expectLdrSame(gamma: f32) !void {
    for (0..256) |k| {
        const v: f32 = @as(f32, @floatFromInt(k)) / 255.0;
        try expectSamePow(v, gamma);
    }
}

test "pow matches the C library on every 8-bit input at the default gamma" {
    try expectLdrSame(2.2);
}

test "pow matches the C library on every 8-bit input at 10,000 random gammas" {
    var prng: std.Random.DefaultPrng = .init(0x9a33a_0001);
    const rng = prng.random();
    for (0..10_000) |_| try expectLdrSame(0.05 + rng.float(f32) * 10);
}

const Sweep = struct {
    first: u32,
    last: u32,
    gamma_inverse: f64,
    mismatches: u64 = 0,
    first_mismatch: ?u32 = null,

    fn run(sweep: *Sweep) void {
        var v = sweep.first;
        while (v < sweep.last) : (v += 1) {
            const x: f64 = @as(f32, @bitCast(v));
            if (bits(theirs(x, sweep.gamma_inverse)) != bits(stbi.pow(x, sweep.gamma_inverse))) {
                sweep.mismatches += 1;
                if (sweep.first_mismatch == null) sweep.first_mismatch = v;
            }
        }
    }
};

/// Every finite non-negative float to the power `gamma_inverse`, on as many
/// threads as there are cores.
fn expectEveryFloatSame(gamma_inverse: f32) !void {
    const end: u32 = 0x7f80_0000;
    var sweeps: [64]Sweep = undefined;
    var threads: [64]std.Thread = undefined;
    const count = @min(sweeps.len, std.Thread.getCpuCount() catch 1);
    const step = end / count + 1;
    for (0..count) |t| {
        const first: u32 = @intCast(@min(end, t * step));
        sweeps[t] = .{
            .first = first,
            .last = @intCast(@min(end, first + step)),
            .gamma_inverse = gamma_inverse,
        };
        threads[t] = try std.Thread.spawn(.{}, Sweep.run, .{&sweeps[t]});
    }
    var mismatches: u64 = 0;
    for (threads[0..count], sweeps[0..count]) |thread, *sweep| {
        thread.join();
        mismatches += sweep.mismatches;
        if (sweep.first_mismatch) |v| {
            const x: f64 = @as(f32, @bitCast(v));
            std.debug.print("\nfirst mismatch in a sweep: pow({x}, {x})\n", .{ x, gamma_inverse });
        }
    }
    if (mismatches != 0) {
        std.debug.print("{d} mismatches of {d}\n", .{ mismatches, end });
        return error.TestUnexpectedResult;
    }
}

test "pow matches the C library on every finite non-negative float at 1 / 2.2" {
    const gamma: f32 = 2.2;
    try expectEveryFloatSame(1.0 / gamma);
}

test "pow matches the C library on 10^7 random floats at random gammas" {
    var prng: std.Random.DefaultPrng = .init(0x9a33a_0002);
    const rng = prng.random();
    for (0..1000) |_| {
        const gamma: f32 = 0.05 + rng.float(f32) * 10;
        const gamma_inverse: f32 = 1.0 / gamma;
        for (0..10_000) |_| {
            const v: f32 = @bitCast(rng.uintLessThan(u32, 0x7f80_0000));
            try expectSamePow(v, gamma_inverse);
        }
    }
}

test "pow matches the C library on 10^7 random doubles" {
    var prng: std.Random.DefaultPrng = .init(0x9a33a_0003);
    const rng = prng.random();
    for (0..10_000_000) |i| {
        const x: f64 = @bitCast(rng.int(u64));
        const y: f64 = switch (i % 4) {
            0 => @bitCast(rng.int(u64)),
            1 => @floatFromInt(rng.intRangeAtMost(i32, -1100, 1100)),
            2 => (rng.float(f64) - 0.5) * 20,
            else => rng.float(f64) * 4,
        };
        if (std.math.isNan(x) or std.math.isNan(y)) continue;
        try expectSamePow(x, y);
    }
}

test "pow matches the C library on special values" {
    const inf = std.math.inf(f64);
    const specials = [_]f64{
        0,                      -0.0,                    1,                       -1,
        2,                      -2,                      0.5,                     -0.5,
        3,                      -3,                      inf,                     -inf,
        std.math.floatMin(f64), -std.math.floatMin(f64), std.math.floatMax(f64),  -std.math.floatMax(f64),
        0x1p-1074,              -0x1p-1074,              0x1.fffffffffffffp-1023, 1 + 0x1p-52,
        1 - 0x1p-53,            0x1p63,                  -0x1p63,                 0x1p-65,
        -0x1p-65,               0x1p-66,                 1100,                    -1100,
        1075,                   -1075,                   2.2,                     1.0 / 2.2,
        0x1.749p62,             0x1.e7b6p-65,            1e308,                   1e-308,
        9007199254740992,       -9007199254740994,       4503599627370497,        -4503599627370497,
    };
    for (specials) |x| {
        for (specials) |y| try expectSamePow(x, y);
    }
    const nan = std.math.nan(f64);
    for (specials) |v| {
        for ([2][2]f64{ .{ nan, v }, .{ v, nan } }) |pair| {
            const expected = theirs(pair[0], pair[1]);
            const actual = stbi.pow(pair[0], pair[1]);
            try std.testing.expectEqual(std.math.isNan(expected), std.math.isNan(actual));
            if (!std.math.isNan(expected)) try std.testing.expectEqual(bits(expected), bits(actual));
        }
    }
}
