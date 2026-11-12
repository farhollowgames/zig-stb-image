//! The C library's double `pow`, which stb_image calls in `stbi__ldr_to_hdr`
//! and `stbi__hdr_to_ldr`: glibc 2.44's `pow` as built for x86-64 with fused
//! multiply-adds, bit for bit.
//!
//! The algorithm and its tables are Arm's optimized-routines `pow` (MIT
//! licence), which glibc carries unchanged: log(x) in double-double from a
//! 128-entry table and a polynomial, multiplied by y, then exp of the product
//! from a 128-entry table of 2^(k/128) and a polynomial. glibc's build lets
//! the compiler fuse multiply-adds, and it fuses most of them; each `@mulAdd`
//! here stands where that build has a fused multiply-add, and every other
//! step rounds as written. A fused multiply-add rounds once on every target,
//! so the result does not depend on the machine.

const std = @import("std");
const tables = @import("pow_tables.zig");

/// x^y, as glibc's `pow`. NaN results have the bits x86-64 gives them.
pub fn pow(x: f64, y: f64) f64 {
    var bias: u64 = 0;
    var ix = bitsOf(x);
    const iy = bitsOf(y);
    var topx = top12(x);
    const topy = top12(y);
    // x subnormal, zero, negative, infinite or NaN; or |y| below 2^-65,
    // at least 2^63, or NaN.
    if (topx -% 0x001 >= 0x7ff - 0x001 or (topy & 0x7ff) -% 0x3be >= 0x43e - 0x3be) {
        if (zeroInfNan(iy)) {
            if (iy << 1 == 0) return if (isSignaling(ix)) x + y else 1.0;
            if (ix == bitsOf(1.0)) return if (isSignaling(iy)) x + y else 1.0;
            if (ix << 1 > bitsOf(std.math.inf(f64)) << 1 or
                iy << 1 > bitsOf(std.math.inf(f64)) << 1) return x + y;
            if (ix << 1 == bitsOf(1.0) << 1) return 1.0;
            // |x| < 1 and y = inf, or |x| > 1 and y = -inf.
            if ((ix << 1 < bitsOf(1.0) << 1) == (iy >> 63 == 0)) return 0.0;
            return y * y;
        }
        if (zeroInfNan(ix)) {
            var x2 = x * x;
            if (ix >> 63 != 0 and checkInt(iy) == .odd) {
                x2 = -x2;
                bias = 1;
            }
            if (ix << 1 == 0 and iy >> 63 != 0) return divideByZero(bias);
            return if (iy >> 63 != 0) 1 / x2 else x2;
        }
        // x and y are finite and not zero.
        if (ix >> 63 != 0) {
            switch (checkInt(iy)) {
                .not_integer => return invalid(x),
                .odd => bias = sign_bias,
                .even => {},
            }
            ix &= 0x7fff_ffff_ffff_ffff;
            topx &= 0x7ff;
        }
        if ((topy & 0x7ff) -% 0x3be >= 0x43e - 0x3be) {
            // y is not odd here, so the bias is 0.
            if (ix == bitsOf(1.0)) return 1.0;
            if ((topy & 0x7ff) < 0x3be) {
                // |y| < 2^-65: x^y is 1 + y log(x), rounded.
                return if (ix > bitsOf(1.0)) 1.0 + y else 1.0 - y;
            }
            return if ((ix > bitsOf(1.0)) == (topy < 0x800)) overflow(0) else underflow(0);
        }
        if (topx == 0) {
            // A subnormal x, normalized so that its exponent goes negative.
            ix = bitsOf(x * 0x1p52);
            ix &= 0x7fff_ffff_ffff_ffff;
            ix -%= 52 << 52;
        }
    }
    var log_tail: f64 = undefined;
    const log_head = logInline(ix, &log_tail);
    const ehi = y * log_head;
    const elo = @mulAdd(f64, y, log_tail, @mulAdd(f64, y, log_head, -ehi));
    return expInline(ehi, elo, bias);
}

const log_bits = 7;
const ln2hi: f64 = 0x1.62e42fefa3800p-1;
const ln2lo: f64 = 0x1.ef35793c76730p-45;
/// The coefficients of log1p(r) after the first, scaled as the evaluation
/// uses them; A[0] is -1/2.
const A = [7]f64{
    -0x1p-1,
    -0x1.5555555555560p-1,
    0x1.0000000000006p-1,
    0x1.999999959554ep-1,
    -0x1.555555529a47ap-1,
    -0x1.2495b9b4845e9p+0,
    0x1.0002b8b263fc3p+0,
};
/// The start of the mantissa range the log table covers: z in [OFF, 2 OFF).
const off: u64 = 0x3fe6955500000000;

const exp_bits = 7;
const inv_ln2_n: f64 = 0x1.71547652b82fep0 * (1 << exp_bits);
const neg_ln2_hi_n: f64 = -0x1.62e42fefa0000p-8;
const neg_ln2_lo_n: f64 = -0x1.cf79abc9e3b3ap-47;
const shift: f64 = 0x1.8p52;
const C2: f64 = 0x1.ffffffffffdbdp-2;
const C3: f64 = 0x1.555555555543cp-3;
const C4: f64 = 0x1.55555cf172b91p-5;
const C5: f64 = 0x1.1111167a4d017p-7;
/// Added to the exponent index to make the result negative.
const sign_bias: u64 = 0x800 << exp_bits;

fn bitsOf(x: f64) u64 {
    return @bitCast(x);
}

fn fromBits(bits: u64) f64 {
    return @bitCast(bits);
}

/// The sign and exponent bits.
fn top12(x: f64) u32 {
    return @intCast(bitsOf(x) >> 52);
}

/// log(x) as head + tail, the head rounded and the tail about 15 bits more.
/// `ix` is the bits of x, a subnormal x normalized with its exponent going
/// into the sign bit.
fn logInline(ix: u64, tail: *f64) f64 {
    // x = 2^k z, z in [OFF, 2 OFF) and exact; the table entry of z's
    // subinterval holds 1/c for a c near its centre.
    const tmp = ix -% off;
    const i: usize = @intCast((tmp >> (52 - log_bits)) % (1 << log_bits));
    const k: i32 = @intCast(@as(i64, @bitCast(tmp)) >> 52);
    const iz = ix -% (tmp & (@as(u64, 0xfff) << 52));
    const z = fromBits(iz);
    const kd: f64 = @floatFromInt(k);
    const invc, const logc, const logctail = tables.log_table[i];

    // log(x) = k ln2 + log(c) + log1p(z/c - 1); z/c - 1 is exact.
    const r = @mulAdd(f64, z, invc, -1.0);
    const t1 = @mulAdd(f64, kd, ln2hi, logc);
    const t2 = t1 + r;
    const lo1 = @mulAdd(f64, kd, ln2lo, logctail);
    const lo2 = t1 - t2 + r;

    const ar = A[0] * r;
    const ar2 = r * ar;
    const ar3 = r * ar2;
    const hi = t2 + ar2;
    const lo3 = @mulAdd(f64, ar, r, -ar2);
    const lo4 = t2 - hi + ar2;
    // log1p(r) - r - A[0] r^2.
    const q12 = @mulAdd(f64, r, A[2], A[1]);
    const q34 = @mulAdd(f64, r, A[4], A[3]);
    const q56 = @mulAdd(f64, r, A[6], A[5]);
    const poly = @mulAdd(f64, ar2, @mulAdd(f64, q56, ar2, q34), q12);
    const lo = @mulAdd(f64, poly, ar3, lo1 + lo2 + lo3 + lo4);
    const y = hi + lo;
    tail.* = hi - y + lo;
    return y;
}

/// sign * exp(x + xtail), |xtail| < 2^-8 / 128 and |xtail| <= |x|. `bias`
/// is `sign_bias` for a negative result, 0 otherwise.
fn expInline(x: f64, xtail: f64, bias: u64) f64 {
    var abstop = top12(x) & 0x7ff;
    if (abstop -% top12(0x1p-54) >= top12(512.0) - top12(0x1p-54)) {
        if (abstop -% top12(0x1p-54) >= 0x8000_0000) {
            // A tiny x: exp(x) rounds to 1 + x.
            const one = 1.0 + x;
            return if (bias != 0) -one else one;
        }
        if (abstop >= top12(1024.0)) {
            return if (bitsOf(x) >> 63 != 0) underflow(bias) else overflow(bias);
        }
        // Large x: handled by `specialCase` below.
        abstop = 0;
    }

    // exp(x) = 2^(k/128) exp(r), x = k ln2/128 + r, |r| <= ln2/256.
    const shifted = @mulAdd(f64, inv_ln2_n, x, shift);
    const ki = bitsOf(shifted);
    const kd = shifted - shift;
    var r = @mulAdd(f64, kd, neg_ln2_lo_n, @mulAdd(f64, kd, neg_ln2_hi_n, x));
    r = xtail + r;
    // 2^(k/128) ~= scale * (1 + tail).
    const index: usize = @intCast(2 * (ki % (1 << exp_bits)));
    const top = (ki +% bias) << (52 - exp_bits);
    const tail = fromBits(tables.exp_table[index]);
    // A valid scale only for -1023 * 128 < k < 1024 * 128.
    const sbits = tables.exp_table[index + 1] +% top;
    // exp(x) ~= scale + scale * (tail + exp(r) - 1).
    const r2 = r * r;
    const low_terms = @mulAdd(f64, r2, @mulAdd(f64, r, C3, C2), tail + r);
    const tmp = @mulAdd(f64, @mulAdd(f64, r, C5, C4), r2 * r2, low_terms);
    if (abstop == 0) return specialCase(tmp, sbits, ki);
    const scale = fromBits(sbits);
    return @mulAdd(f64, scale, tmp, scale);
}

/// scale * (1 + tmp) where it may overflow or underflow, without rounding
/// in between. `sbits` is the bits of scale with an exponent that may have
/// run into the sign bit; `ki` holds k in its low 32 bits, positive where the
/// result may overflow and negative where it may underflow.
fn specialCase(tmp: f64, sbits_in: u64, ki: u64) f64 {
    if (ki & 0x8000_0000 == 0) {
        // k > 0: the exponent of scale may have overflowed by up to 460.
        const scale = fromBits(sbits_in -% (1009 << 52));
        const y = @mulAdd(f64, scale, tmp, scale);
        return y * 0x1p1009;
    }
    // k < 0: the subnormal range needs care.
    const sbits = sbits_in +% (1022 << 52);
    const scale = fromBits(sbits);
    const scaled_tmp = scale * tmp;
    var y = scale + scaled_tmp;
    if (@abs(y) < 1.0) {
        // Round y to its final precision before scaling it into the
        // subnormal range, so it is not rounded twice.
        const one: f64 = if (y < 0.0) -1.0 else 1.0;
        var lo = scale - y + scaled_tmp;
        const hi = one + y;
        lo = one - hi + y + lo;
        y = (lo + hi) - one;
        // The sign of a zero result.
        if (y == 0.0) y = fromBits(sbits & 0x8000_0000_0000_0000);
    }
    return 0x1p-1022 * y;
}

const IntKind = enum { not_integer, odd, even };

/// Whether the non-zero finite value with bits `iy` is an integer, and odd.
fn checkInt(iy: u64) IntKind {
    const e: u32 = @intCast(iy >> 52 & 0x7ff);
    if (e < 0x3ff) return .not_integer;
    if (e > 0x3ff + 52) return .even;
    const unit = @as(u64, 1) << @intCast(0x3ff + 52 - e);
    if (iy & (unit - 1) != 0) return .not_integer;
    if (iy & unit != 0) return .odd;
    return .even;
}

/// Whether `bits` are those of a zero, an infinity or a NaN.
fn zeroInfNan(bits: u64) bool {
    return (bits << 1) -% 1 >= (bitsOf(std.math.inf(f64)) << 1) - 1;
}

fn isSignaling(bits: u64) bool {
    return (bits ^ 0x0008_0000_0000_0000) << 1 > @as(u64, 0x7ff8_0000_0000_0000) << 1;
}

fn overflow(bias: u64) f64 {
    const inf = std.math.inf(f64);
    return if (bias != 0) -inf else inf;
}

fn underflow(bias: u64) f64 {
    return if (bias != 0) -0.0 else 0.0;
}

fn divideByZero(bias: u64) f64 {
    const inf = std.math.inf(f64);
    return if (bias != 0) -inf else inf;
}

/// The NaN of an invalid operation, `(x - x) / (x - x)` for a finite x.
fn invalid(x: f64) f64 {
    const zero = x - x;
    return zero / zero;
}

test "pow of exact cases" {
    try std.testing.expectEqual(@as(f64, 8.0), pow(2.0, 3.0));
    try std.testing.expectEqual(@as(f64, 1.0), pow(0.0, 0.0));
    try std.testing.expectEqual(@as(f64, 0.5), pow(4.0, -0.5));
    try std.testing.expectEqual(@as(f64, -8.0), pow(-2.0, 3.0));
    try std.testing.expect(std.math.isNan(pow(-2.0, 0.5)));
    try std.testing.expectEqual(std.math.inf(f64), pow(0.0, -2.2));
}
