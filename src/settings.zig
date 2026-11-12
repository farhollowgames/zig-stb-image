//! stb_image's process-wide and per-thread settings, for callers that set
//! them once rather than pass `Options` to each load. `current` gives the
//! `Options` they amount to on the calling thread. A per-thread setting,
//! once made, wins over the process-wide one on its thread, as in the
//! original.

const std = @import("std");
const Options = @import("common.zig").Options;

const Flag = struct {
    global: std.atomic.Value(bool) = .init(false),

    fn get(flag: *const Flag, local: *const ?bool) bool {
        return local.* orelse flag.global.load(.monotonic);
    }
};

var flip: Flag = .{};
var unpremultiply: Flag = .{};
var convert_iphone: Flag = .{};
threadlocal var flip_local: ?bool = null;
threadlocal var unpremultiply_local: ?bool = null;
threadlocal var convert_iphone_local: ?bool = null;

var ldr_to_hdr_gamma: f32 = 2.2;
var ldr_to_hdr_scale: f32 = 1.0;
var hdr_to_ldr_gamma: f32 = 2.2;
var hdr_to_ldr_scale: f32 = 1.0;

/// `stbi_set_flip_vertically_on_load`.
pub fn setFlipVerticallyOnLoad(should_flip: bool) void {
    flip.global.store(should_flip, .monotonic);
}

/// `stbi_set_flip_vertically_on_load_thread`.
pub fn setFlipVerticallyOnLoadThread(should_flip: bool) void {
    flip_local = should_flip;
}

/// `stbi_set_unpremultiply_on_load`.
pub fn setUnpremultiplyOnLoad(should_unpremultiply: bool) void {
    unpremultiply.global.store(should_unpremultiply, .monotonic);
}

/// `stbi_set_unpremultiply_on_load_thread`.
pub fn setUnpremultiplyOnLoadThread(should_unpremultiply: bool) void {
    unpremultiply_local = should_unpremultiply;
}

/// `stbi_convert_iphone_png_to_rgb`.
pub fn convertIphonePngToRgb(should_convert: bool) void {
    convert_iphone.global.store(should_convert, .monotonic);
}

/// `stbi_convert_iphone_png_to_rgb_thread`.
pub fn convertIphonePngToRgbThread(should_convert: bool) void {
    convert_iphone_local = should_convert;
}

/// `stbi_ldr_to_hdr_gamma`. Process-wide, like the three below, and not
/// synchronized: set them before loads start.
pub fn setLdrToHdrGamma(gamma: f32) void {
    ldr_to_hdr_gamma = gamma;
}

/// `stbi_ldr_to_hdr_scale`.
pub fn setLdrToHdrScale(scale: f32) void {
    ldr_to_hdr_scale = scale;
}

/// `stbi_hdr_to_ldr_gamma`.
pub fn setHdrToLdrGamma(gamma: f32) void {
    hdr_to_ldr_gamma = gamma;
}

/// `stbi_hdr_to_ldr_scale`.
pub fn setHdrToLdrScale(scale: f32) void {
    hdr_to_ldr_scale = scale;
}

/// The options the settings amount to on this thread, with `components`
/// and `limits` at their defaults.
pub fn current() Options {
    return .{
        .flip_vertically = flip.get(&flip_local),
        .unpremultiply = unpremultiply.get(&unpremultiply_local),
        .convert_iphone_png = convert_iphone.get(&convert_iphone_local),
        .ldr_to_hdr_gamma = ldr_to_hdr_gamma,
        .ldr_to_hdr_scale = ldr_to_hdr_scale,
        .hdr_to_ldr_gamma = hdr_to_ldr_gamma,
        .hdr_to_ldr_scale = hdr_to_ldr_scale,
    };
}
