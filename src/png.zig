//! Placeholder for the png decoder.

const std = @import("std");
const common = @import("common.zig");

const Source = common.Source;

/// Until PNG is ported: only `stbi__check_png_header`'s failure reason,
/// which later failures of other formats report.
pub fn detect(source: *Source) bool {
    for ([_]u8{ 137, 80, 78, 71, 13, 10, 26, 10 }) |byte| {
        if (source.get8() != byte) {
            source.reason = error.BadPngSignature;
            break;
        }
    }
    source.rewind();
    return false;
}

pub fn load(gpa: std.mem.Allocator, source: *Source, request: common.Request) common.Error!common.Decoded {
    _ = gpa;
    _ = request;
    return source.fail(error.UnknownImageType);
}

pub fn info(source: *Source) ?common.Info {
    _ = source;
    return null;
}

pub fn is16(source: *Source) bool {
    _ = source;
    return false;
}
