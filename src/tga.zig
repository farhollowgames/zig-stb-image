//! Placeholder for the tga decoder.

const std = @import("std");
const common = @import("common.zig");

const Source = common.Source;

pub fn detect(source: *Source) bool {
    _ = source;
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
