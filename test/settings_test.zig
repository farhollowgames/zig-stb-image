//! The process-wide and per-thread settings against the original's: the
//! same calls on the same threads give the same flags on each thread, and
//! a load with the flags a thread sees gives the original's pixels.

const std = @import("std");
const stbi = @import("stb_image");
const oracle = @import("oracle.zig");
const png_file = @import("png_file.zig");
const fuzz_options = @import("fuzz_options");

const settings = stbi.settings;
const gpa = std.testing.allocator;

const Flag = enum(c_int) { flip = 0, unpremultiply = 1, iphone = 2 };

const Flags = struct { flip: bool, unpremultiply: bool, iphone: bool };

/// Sets `flag` process-wide, or for the calling thread, in both builds of
/// the original and in the port.
fn set(flag: Flag, thread: bool, value: bool) void {
    oracle.upstream.simd_set_flag(@backingInt(flag), @intFromBool(thread), @intFromBool(value));
    oracle.upstream.scalar_set_flag(@backingInt(flag), @intFromBool(thread), @intFromBool(value));
    switch (flag) {
        .flip => if (thread) settings.setFlipVerticallyOnLoadThread(value) else settings.setFlipVerticallyOnLoad(value),
        .unpremultiply => if (thread)
            settings.setUnpremultiplyOnLoadThread(value)
        else
            settings.setUnpremultiplyOnLoad(value),
        .iphone => if (thread) settings.convertIphonePngToRgbThread(value) else settings.convertIphonePngToRgb(value),
    }
}

fn theirs(get: *const fn (*c_int, *c_int, *c_int) callconv(.c) void) Flags {
    var flip: c_int = 0;
    var unpremultiply: c_int = 0;
    var iphone: c_int = 0;
    get(&flip, &unpremultiply, &iphone);
    return .{ .flip = flip != 0, .unpremultiply = unpremultiply != 0, .iphone = iphone != 0 };
}

/// The calling thread's flags in the port and both builds of the original
/// are `expected`.
fn expectFlags(expected: Flags) !void {
    const options = settings.current();
    const ours: Flags = .{
        .flip = options.flip_vertically,
        .unpremultiply = options.unpremultiply,
        .iphone = options.convert_iphone_png,
    };
    try std.testing.expectEqual(expected, theirs(&oracle.upstream.simd_get_flags));
    try std.testing.expectEqual(expected, theirs(&oracle.upstream.scalar_get_flags));
    try std.testing.expectEqual(expected, ours);
}

/// The steps of the two threads, in turn: `step` is the next one to run.
const Script = struct {
    step: std.atomic.Value(u32) = .init(0),
    failed: std.atomic.Value(bool) = .init(false),

    fn waitFor(script: *Script, step: u32) void {
        while (script.step.load(.acquire) != step) std.Thread.yield() catch {};
    }

    fn done(script: *Script) void {
        _ = script.step.fetchAdd(1, .release);
    }

    fn check(script: *Script, result: anyerror!void) void {
        result catch script.failed.store(true, .release);
    }
};

fn threadA(script: *Script) void {
    script.waitFor(0);
    script.check(expectFlags(.{ .flip = true, .unpremultiply = false, .iphone = false }));
    set(.flip, true, false);
    script.check(expectFlags(.{ .flip = false, .unpremultiply = false, .iphone = false }));
    // A process-wide change does not reach a thread that set its own.
    set(.flip, false, false);
    set(.flip, false, true);
    set(.unpremultiply, false, true);
    script.check(expectFlags(.{ .flip = false, .unpremultiply = true, .iphone = false }));
    script.done();

    script.waitFor(2);
    // Thread B's own settings stay on thread B.
    script.check(expectFlags(.{ .flip = false, .unpremultiply = true, .iphone = false }));
    set(.iphone, false, true);
    set(.flip, true, true);
    script.check(expectFlags(.{ .flip = true, .unpremultiply = true, .iphone = true }));
    script.done();
}

fn threadB(script: *Script) void {
    script.waitFor(1);
    // Thread A's own setting stays on thread A.
    script.check(expectFlags(.{ .flip = true, .unpremultiply = true, .iphone = false }));
    set(.iphone, true, true);
    set(.unpremultiply, true, false);
    script.check(expectFlags(.{ .flip = true, .unpremultiply = false, .iphone = true }));
    script.done();
}

test "settings: a thread's own setting wins on that thread, and other threads see the process-wide one, as in the original" {
    if (fuzz_options.sanitize) return;
    defer {
        set(.flip, false, false);
        set(.unpremultiply, false, false);
        set(.iphone, false, false);
    }
    set(.flip, false, true);
    set(.unpremultiply, false, false);
    set(.iphone, false, false);
    var script: Script = .{};
    const a = try std.Thread.spawn(.{}, threadA, .{&script});
    const b = try std.Thread.spawn(.{}, threadB, .{&script});
    a.join();
    b.join();
    try std.testing.expect(!script.failed.load(.acquire));
    try std.testing.expectEqual(3, script.step.load(.acquire));
}

/// On its own thread: loads `bytes` with the port's per-thread settings,
/// and with the original's, set through the oracle's thread fields.
fn loadOnThread(bytes: []const u8, result: *anyerror!void) void {
    result.* = loadWithThreadSettings(bytes);
}

fn loadWithThreadSettings(bytes: []const u8) !void {
    settings.setFlipVerticallyOnLoadThread(true);
    settings.convertIphonePngToRgbThread(true);
    settings.setUnpremultiplyOnLoadThread(true);
    var image = try stbi.loadFromMemory(u8, gpa, bytes, settings.current());
    defer image.deinit(gpa);

    const request: oracle.Settings = .{ .flip_thread = 1, .iphone_thread = 1, .unpremultiply_thread = 1 };
    for ([_]*const fn ([*]const u8, usize, c_int, *const oracle.Settings, *oracle.Result) callconv(.c) void{
        &oracle.upstream.simd_load,
        &oracle.upstream.scalar_load,
    }) |load| {
        var out: oracle.Result = undefined;
        load(bytes.ptr, bytes.len, 8, &request, &out);
        defer oracle.upstream.simd_free(out.pixels);
        const pixels: [*]const u8 = @ptrCast(out.pixels orelse return error.TestUnexpectedResult);
        try std.testing.expectEqual(image.width, @as(u32, @intCast(out.x)));
        try std.testing.expectEqualSlices(u8, pixels[0..image.pixels.len], image.pixels);
    }
}

test "settings: a load with a thread's own settings flips and converts as the original's" {
    if (fuzz_options.sanitize) return;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var prng: std.Random.DefaultPrng = .init(0x7e);
    const bytes = try png_file.random(arena_state.allocator(), prng.random(), .{
        .width = 5,
        .height = 4,
        .color = 6,
    }, .{ .cgbi = true });
    var result: anyerror!void = {};
    const thread = try std.Thread.spawn(.{}, loadOnThread, .{ bytes, &result });
    thread.join();
    try result;
}
