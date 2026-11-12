//! What a load does after the decoder: bit-depth changes, the vertical flip
//! and the conversions between 8-bit and linear float pixels.

const std = @import("std");
const common = @import("common.zig");
const pow = @import("pow.zig").pow;

const Error = common.Error;
const Options = common.Options;

/// `stbi__convert_16_to_8`: the top byte of each sample. Frees `wide`.
pub fn convert16To8(gpa: std.mem.Allocator, wide: []u16) Error![]u8 {
    defer gpa.free(wide);
    const narrow = try gpa.alloc(u8, wide.len);
    for (narrow, wide) |*n, w| n.* = @truncate(w >> 8);
    return narrow;
}

/// `stbi__convert_8_to_16`: each byte repeated, so 255 becomes 0xffff.
/// Frees `narrow`.
pub fn convert8To16(gpa: std.mem.Allocator, narrow: []u8) Error![]u16 {
    defer gpa.free(narrow);
    const wide = try gpa.alloc(u16, narrow.len);
    for (wide, narrow) |*w, n| w.* = @as(u16, n) * 0x101;
    return wide;
}

/// Swaps the rows of `pixels`, `height` rows of `width * comp` samples.
pub fn verticalFlip(comptime T: type, pixels: []T, width: u32, height: u32, comp: u32) void {
    const row_len = @as(usize, width) * comp;
    for (0..height / 2) |row| {
        const top = pixels[row * row_len ..][0..row_len];
        const bottom = pixels[(height - 1 - row) * row_len ..][0..row_len];
        for (top, bottom) |*a, *b| std.mem.swap(T, a, b);
    }
}

/// `stbi__ldr_to_hdr`: `(v / 255) ^ gamma * scale` for colour, `v / 255`
/// for alpha, with the C library's double `pow`. Frees `data`.
pub fn ldrToHdr(
    gpa: std.mem.Allocator,
    options: *const Options,
    data: []u8,
    x: u32,
    y: u32,
    comp: u3,
) Error![]f32 {
    defer gpa.free(data);
    // The original checks the size in bytes, four to a float.
    if (!common.sizesValid(options.limits, &.{ x, y, comp, 4 }, 0)) return error.OutOfMemory;
    const output = try gpa.alloc(f32, @as(usize, x) * y * comp);
    const colour: usize = if (comp & 1 != 0) comp else comp - 1;
    const gamma: f64 = options.ldr_to_hdr_gamma;
    const scale: f64 = options.ldr_to_hdr_scale;
    const pixels = @as(usize, x) * y;
    for (0..pixels) |i| {
        for (0..colour) |k| {
            const v: f32 = @as(f32, @floatFromInt(data[i * comp + k])) / 255.0;
            output[i * comp + k] = @floatCast(pow(v, gamma) * scale);
        }
    }
    if (colour < comp) {
        for (0..pixels) |i| {
            output[i * comp + colour] = @as(f32, @floatFromInt(data[i * comp + colour])) / 255.0;
        }
    }
    return output;
}

/// `stbi__hdr_to_ldr`: `(v * (1 / scale)) ^ (1 / gamma)` for colour and `v`
/// for alpha, scaled to 0..255, rounded and clamped. Frees `data`.
pub fn hdrToLdr(
    gpa: std.mem.Allocator,
    options: *const Options,
    data: []f32,
    x: u32,
    y: u32,
    comp: u3,
) Error![]u8 {
    defer gpa.free(data);
    const output = try common.allocChecked(u8, gpa, options.limits, &.{ x, y, comp }, 0);
    const colour: usize = if (comp & 1 != 0) comp else comp - 1;
    const gamma_inverse: f32 = 1.0 / options.hdr_to_ldr_gamma;
    const scale_inverse: f32 = 1.0 / options.hdr_to_ldr_scale;
    const pixels = @as(usize, x) * y;
    for (0..pixels) |i| {
        for (0..colour) |k| {
            const linear = data[i * comp + k] * scale_inverse;
            const powered: f32 = @floatCast(pow(linear, gamma_inverse));
            output[i * comp + k] = toByte(powered * 255 + 0.5);
        }
        if (colour < comp) output[i * comp + colour] = toByte(data[i * comp + colour] * 255 + 0.5);
    }
    return output;
}

/// The original clamps to 0..255 and truncates; a NaN passes both of its
/// comparisons, and its conversion to `int` is undefined there. The port
/// gives 0 for NaN.
fn toByte(z: f32) u8 {
    if (std.math.isNan(z)) return 0;
    const clamped = std.math.clamp(z, 0, 255);
    return @intFromFloat(clamped);
}
