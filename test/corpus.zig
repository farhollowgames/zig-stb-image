//! The test images: the files of the pinned lazy dependencies, read by
//! directory and extension.

const std = @import("std");
const paths = @import("corpus_paths");

pub const Root = enum { stb, jpeg_decoder, image_rs, psd_tools, libjpeg_turbo };

pub const Entry = struct {
    /// The path below the dependency's root, for failure messages.
    name: []const u8,
    bytes: []u8,
};

pub const Set = struct {
    entries: []Entry,

    pub fn deinit(set: *Set, gpa: std.mem.Allocator) void {
        for (set.entries) |entry| {
            gpa.free(entry.name);
            gpa.free(entry.bytes);
        }
        gpa.free(set.entries);
        set.* = undefined;
    }

    /// The bytes of every entry, for fuzzing.
    pub fn inputs(set: Set, gpa: std.mem.Allocator) ![]const []const u8 {
        const list = try gpa.alloc([]const u8, set.entries.len);
        for (list, set.entries) |*input, entry| input.* = entry.bytes;
        return list;
    }
};

fn rootPath(root: Root) []const u8 {
    return switch (root) {
        inline else => |r| @field(paths, @tagName(r)),
    };
}

/// Every file under `sub_dir` of `root`, at any depth, whose name ends in
/// one of `extensions` (compared without case), sorted by path so every run
/// sees the same order.
pub fn load(
    gpa: std.mem.Allocator,
    io: std.Io,
    root: Root,
    sub_dir: []const u8,
    extensions: []const []const u8,
) !Set {
    const base = try std.fs.path.join(gpa, &.{ rootPath(root), sub_dir });
    defer gpa.free(base);
    // The dependency paths may be relative to the build root, where the
    // tests run.
    var dir = try std.Io.Dir.cwd().openDir(io, base, .{ .iterate = true });
    defer dir.close(io);

    var entries: std.ArrayList(Entry) = .empty;
    errdefer {
        for (entries.items) |entry| {
            gpa.free(entry.name);
            gpa.free(entry.bytes);
        }
        entries.deinit(gpa);
    }
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |item| {
        if (item.kind != .file) continue;
        if (!hasExtension(item.basename, extensions)) continue;
        const bytes = try dir.readFileAlloc(io, item.path, gpa, .limited(64 << 20));
        errdefer gpa.free(bytes);
        const name = try std.fs.path.join(gpa, &.{ sub_dir, item.path });
        try entries.append(gpa, .{ .name = name, .bytes = bytes });
    }
    std.mem.sort(Entry, entries.items, {}, struct {
        fn lessThan(_: void, a: Entry, b: Entry) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lessThan);
    return .{ .entries = try entries.toOwnedSlice(gpa) };
}

fn hasExtension(name: []const u8, extensions: []const []const u8) bool {
    for (extensions) |extension| {
        if (name.len >= extension.len and
            std.ascii.eqlIgnoreCase(name[name.len - extension.len ..], extension)) return true;
    }
    return false;
}
