//! A Zig port of stb_image's image decoders: JPEG, PNG, TGA, BMP, PSD, GIF,
//! HDR, PIC and PNM, read from memory, a reader or a file, into 8-bit,
//! 16-bit or float pixels.

const std = @import("std");
const build_options = @import("stb_image_options");
const common = @import("common.zig");
const errors = @import("errors.zig");
const postprocess = @import("postprocess.zig");

pub const settings = @import("settings.zig");
pub const zlib = @import("zlib.zig");
/// The C library's double `pow`, as the float conversions compute it.
pub const pow = @import("pow.zig").pow;

pub const Error = errors.Error;
pub const failureReason = errors.failureReason;
pub const failureMessage = errors.failureMessage;
pub const Limits = common.Limits;
pub const Components = common.Components;
pub const Options = common.Options;
pub const Info = common.Info;
pub const Animation = common.Animation;

const Source = common.Source;
const Decoded = common.Decoded;
const Request = common.Request;

/// The formats a build decodes, from the `-D<format>` build options (all on
/// by default), as stb_image's `STBI_NO_*` and `STBI_ONLY_*`.
pub const formats = struct {
    pub const jpeg = build_options.jpeg;
    pub const png = build_options.png;
    pub const bmp = build_options.bmp;
    pub const tga = build_options.tga;
    pub const psd = build_options.psd;
    pub const gif = build_options.gif;
    pub const hdr = build_options.hdr;
    pub const pic = build_options.pic;
    pub const pnm = build_options.pnm;
};

const jpeg = if (formats.jpeg) @import("jpeg.zig") else Missing;
const png = if (formats.png) @import("png.zig") else Missing;
const bmp = if (formats.bmp) @import("bmp.zig") else Missing;
const tga = if (formats.tga) @import("tga.zig") else Missing;
const psd = if (formats.psd) @import("psd.zig") else Missing;
const gif = if (formats.gif) @import("gif.zig") else Missing;
const hdr = if (formats.hdr) @import("hdr.zig") else Missing;
const pic = if (formats.pic) @import("pic.zig") else Missing;
const pnm = if (formats.pnm) @import("pnm.zig") else Missing;

/// A format left out of the build: never detected.
const Missing = struct {
    fn detect(_: *Source) bool {
        return false;
    }
    fn load(_: std.mem.Allocator, _: *Source, _: Request) Error!Decoded {
        unreachable;
    }
    fn info(_: *Source) ?Info {
        return null;
    }
    fn is16(_: *Source) bool {
        return false;
    }
};

/// A decoded image: `width * height` pixels of `channels` interleaved
/// components each, top row first unless flipped. `channels_in_file` is the
/// count the file has, which differs from `channels` when the load asked for
/// other components.
pub fn Image(comptime T: type) type {
    return struct {
        pixels: []T,
        width: u32,
        height: u32,
        channels: u8,
        channels_in_file: u8,

        pub fn deinit(image: *@This(), gpa: std.mem.Allocator) void {
            gpa.free(image.pixels);
            image.* = undefined;
        }
    };
}

fn checkSample(comptime T: type) void {
    if (T != u8 and T != u16 and T != f32) {
        @compileError("stb_image loads u8, u16 or f32 samples, not " ++ @typeName(T));
    }
}

/// Decodes the image in `bytes` to samples of `T` (`u8`, `u16` or `f32`):
/// `stbi_load_from_memory`, `stbi_load_16_from_memory` and
/// `stbi_loadf_from_memory`.
pub fn loadFromMemory(
    comptime T: type,
    gpa: std.mem.Allocator,
    bytes: []const u8,
    options: Options,
) Error!Image(T) {
    comptime checkSample(T);
    var source: Source = .initMemory(bytes);
    return loadSource(T, gpa, &source, &options);
}

/// Decodes the image `reader` gives, as stb_image's callbacks do
/// (`stbi_load_from_callbacks` and its 16-bit and float forms). It reads
/// through a 128-byte buffer of its own, so it may take more of `reader`
/// than the image needs. A short read marks the end, as `feof` would.
pub fn loadFromReader(
    comptime T: type,
    gpa: std.mem.Allocator,
    reader: *std.Io.Reader,
    options: Options,
) Error!Image(T) {
    comptime checkSample(T);
    var source: Source = undefined;
    source.initReader(reader);
    return loadSource(T, gpa, &source, &options);
}

pub const FileError = Error || std.Io.File.Reader.SeekError;

/// Decodes the image at `file_reader`'s position (`stbi_load_from_file` and
/// its 16-bit and float forms). After an 8 or 16-bit load the reader is
/// left at the first byte after what the decoder read; after a float load,
/// as with stb_image, wherever its buffer reached.
pub fn loadFromFile(
    comptime T: type,
    gpa: std.mem.Allocator,
    file_reader: *std.Io.File.Reader,
    options: Options,
) FileError!Image(T) {
    comptime checkSample(T);
    var source: Source = undefined;
    source.initReader(&file_reader.interface);
    var image = try loadSource(T, gpa, &source, &options);
    if (T != f32) {
        errdefer image.deinit(gpa);
        // Give back what the source buffered but did not use.
        try file_reader.seekBy(-@as(i64, @intCast(source.end - source.pos)));
    }
    return image;
}

pub const PathError = FileError || std.Io.File.OpenError;

/// Decodes the image in the file at `sub_path` (`stbi_load` and its 16-bit
/// and float forms).
pub fn loadFromPath(
    comptime T: type,
    gpa: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    sub_path: []const u8,
    options: Options,
) PathError!Image(T) {
    const file = try dir.openFile(io, sub_path, .{});
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var file_reader = file.readerStreaming(io, &buffer);
    return loadFromFile(T, gpa, &file_reader, options);
}

fn loadSource(
    comptime T: type,
    gpa: std.mem.Allocator,
    source: *Source,
    options: *const Options,
) Error!Image(T) {
    const req_comp = options.reqComp();
    const result = switch (T) {
        u8 => loadAndPostprocess8(gpa, source, options),
        u16 => loadAndPostprocess16(gpa, source, options),
        f32 => loadfMain(gpa, source, options),
        else => comptime unreachable,
    };
    var decoded = result catch |err| {
        if (source.read_failed) return error.ReadFailed;
        return err;
    };
    if (source.read_failed) {
        decoded.pixels.free(gpa);
        return error.ReadFailed;
    }
    return .{
        .pixels = @field(decoded.pixels, @typeName(T)),
        .width = decoded.width,
        .height = decoded.height,
        .channels = if (req_comp != 0) req_comp else decoded.channels_in_file,
        .channels_in_file = decoded.channels_in_file,
    };
}

/// `stbi__load_main`: the first format whose test passes decodes. The
/// formats with a distinctive signature are tried first, TGA last.
fn loadMain(gpa: std.mem.Allocator, source: *Source, request: Request) Error!Decoded {
    if (png.detect(source)) return png.load(gpa, source, request);
    if (bmp.detect(source)) return bmp.load(gpa, source, request);
    if (gif.detect(source)) return gif.load(gpa, source, request);
    if (psd.detect(source)) return psd.load(gpa, source, request);
    if (pic.detect(source)) return pic.load(gpa, source, request);
    if (jpeg.detect(source)) return jpeg.load(gpa, source, request);
    if (pnm.detect(source)) return pnm.load(gpa, source, request);
    if (hdr.detect(source)) {
        const decoded = try hdr.load(gpa, source, request);
        const comp = if (request.req_comp != 0) request.req_comp else decoded.channels_in_file;
        return .{
            .pixels = .{ .u8 = try postprocess.hdrToLdr(
                gpa,
                request.options,
                decoded.pixels.f32,
                decoded.width,
                decoded.height,
                @intCast(comp),
            ) },
            .width = decoded.width,
            .height = decoded.height,
            .channels_in_file = decoded.channels_in_file,
        };
    }
    if (tga.detect(source)) return tga.load(gpa, source, request);
    return source.fail(error.UnknownImageType);
}

fn outputComponents(decoded: Decoded, req_comp: u3) u32 {
    return if (req_comp != 0) req_comp else decoded.channels_in_file;
}

fn loadAndPostprocess8(
    gpa: std.mem.Allocator,
    source: *Source,
    options: *const Options,
) Error!Decoded {
    const req_comp = options.reqComp();
    var decoded = try loadMain(gpa, source, .{
        .req_comp = req_comp,
        .bits_per_channel = 8,
        .options = options,
    });
    const comp = outputComponents(decoded, req_comp);
    switch (decoded.pixels) {
        .u8 => {},
        .u16 => |wide| decoded.pixels = .{ .u8 = try postprocess.convert16To8(gpa, wide) },
        .f32 => unreachable,
    }
    if (options.flip_vertically) {
        postprocess.verticalFlip(u8, decoded.pixels.u8, decoded.width, decoded.height, comp);
    }
    return decoded;
}

fn loadAndPostprocess16(
    gpa: std.mem.Allocator,
    source: *Source,
    options: *const Options,
) Error!Decoded {
    const req_comp = options.reqComp();
    var decoded = try loadMain(gpa, source, .{
        .req_comp = req_comp,
        .bits_per_channel = 16,
        .options = options,
    });
    const comp = outputComponents(decoded, req_comp);
    switch (decoded.pixels) {
        .u8 => |narrow| decoded.pixels = .{ .u16 = try postprocess.convert8To16(gpa, narrow) },
        .u16 => {},
        .f32 => unreachable,
    }
    if (options.flip_vertically) {
        postprocess.verticalFlip(u16, decoded.pixels.u16, decoded.width, decoded.height, comp);
    }
    return decoded;
}

/// `stbi__loadf_main`: HDR files decode to floats directly, the others at 8
/// bits and are then made linear. A failed 8-bit load reports an unknown
/// image type, as the original does.
fn loadfMain(gpa: std.mem.Allocator, source: *Source, options: *const Options) Error!Decoded {
    const req_comp = options.reqComp();
    if (hdr.detect(source)) {
        const decoded = try hdr.load(gpa, source, .{
            .req_comp = req_comp,
            .bits_per_channel = 32,
            .options = options,
        });
        if (options.flip_vertically) {
            const comp = outputComponents(decoded, req_comp);
            postprocess.verticalFlip(f32, decoded.pixels.f32, decoded.width, decoded.height, comp);
        }
        return decoded;
    }
    const decoded = loadAndPostprocess8(gpa, source, options) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return source.fail(error.UnknownImageType),
    };
    return .{
        .pixels = .{ .f32 = try postprocess.ldrToHdr(
            gpa,
            options,
            decoded.pixels.u8,
            decoded.width,
            decoded.height,
            @intCast(outputComponents(decoded, req_comp)),
        ) },
        .width = decoded.width,
        .height = decoded.height,
        .channels_in_file = decoded.channels_in_file,
    };
}

/// Decodes every frame of the GIF in `bytes` (`stbi_load_gif_from_memory`).
/// Every frame is the whole canvas with the frames before it composited in.
/// The channel count is 4 unless `options.components` asks for another.
pub fn loadGifFromMemory(
    gpa: std.mem.Allocator,
    bytes: []const u8,
    options: Options,
) Error!Animation {
    if (!formats.gif) @compileError("GIF is left out of this build");
    var source: Source = .initMemory(bytes);
    var animation = try gif.loadAnimation(gpa, &source, &options);
    if (options.flip_vertically) {
        const slice = @as(usize, animation.width) * animation.height * animation.channels;
        for (0..animation.frames) |frame| {
            const pixels = animation.pixels[frame * slice ..][0..slice];
            postprocess.verticalFlip(u8, pixels, animation.width, animation.height, animation.channels);
        }
    }
    return animation;
}

/// `stbi__info_main`: the size and channel count of the image, without
/// decoding it. Each format's test is tried in the original's order.
fn infoMain(source: *Source) error{UnknownImageType}!Info {
    if (jpeg.info(source)) |found| return found;
    if (png.info(source)) |found| return found;
    if (gif.info(source)) |found| return found;
    if (bmp.info(source)) |found| return found;
    if (psd.info(source)) |found| return found;
    if (pic.info(source)) |found| return found;
    if (pnm.info(source)) |found| return found;
    if (hdr.info(source)) |found| return found;
    if (tga.info(source)) |found| return found;
    return error.UnknownImageType;
}

fn is16Main(source: *Source) bool {
    if (png.is16(source)) return true;
    if (psd.is16(source)) return true;
    if (pnm.is16(source)) return true;
    return false;
}

fn isHdrMain(source: *Source) bool {
    return hdr.detect(source);
}

pub const InfoError = error{ UnknownImageType, ReadFailed };

/// `stbi_info_from_memory`.
pub fn infoFromMemory(bytes: []const u8) error{UnknownImageType}!Info {
    var source: Source = .initMemory(bytes);
    return infoMain(&source);
}

/// `stbi_info_from_callbacks`.
pub fn infoFromReader(reader: *std.Io.Reader) InfoError!Info {
    var source: Source = undefined;
    source.initReader(reader);
    const found = infoMain(&source);
    if (source.read_failed) return error.ReadFailed;
    return found;
}

/// `stbi_info_from_file`: the file reader is put back where it was.
pub fn infoFromFile(
    file_reader: *std.Io.File.Reader,
) (InfoError || std.Io.File.Reader.SeekError)!Info {
    const start = file_reader.logicalPos();
    var source: Source = undefined;
    source.initReader(&file_reader.interface);
    const found = infoMain(&source);
    try file_reader.seekTo(start);
    if (source.read_failed) return error.ReadFailed;
    return found;
}

/// `stbi_info`.
pub fn infoFromPath(
    io: std.Io,
    dir: std.Io.Dir,
    sub_path: []const u8,
) (InfoError || std.Io.File.Reader.SeekError || std.Io.File.OpenError)!Info {
    const file = try dir.openFile(io, sub_path, .{});
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var file_reader = file.readerStreaming(io, &buffer);
    return infoFromFile(&file_reader);
}

/// `stbi_is_16_bit_from_memory`: whether the image has 16-bit samples
/// (PNG, PSD and PNM only).
pub fn is16BitFromMemory(bytes: []const u8) bool {
    var source: Source = .initMemory(bytes);
    return is16Main(&source);
}

/// `stbi_is_16_bit_from_callbacks`.
pub fn is16BitFromReader(reader: *std.Io.Reader) error{ReadFailed}!bool {
    var source: Source = undefined;
    source.initReader(reader);
    const found = is16Main(&source);
    if (source.read_failed) return error.ReadFailed;
    return found;
}

/// `stbi_is_16_bit_from_file`: the file reader is put back where it was.
pub fn is16BitFromFile(
    file_reader: *std.Io.File.Reader,
) (error{ReadFailed} || std.Io.File.Reader.SeekError)!bool {
    const start = file_reader.logicalPos();
    var source: Source = undefined;
    source.initReader(&file_reader.interface);
    const found = is16Main(&source);
    try file_reader.seekTo(start);
    if (source.read_failed) return error.ReadFailed;
    return found;
}

/// `stbi_is_16_bit`.
pub fn is16BitFromPath(
    io: std.Io,
    dir: std.Io.Dir,
    sub_path: []const u8,
) (error{ReadFailed} || std.Io.File.Reader.SeekError || std.Io.File.OpenError)!bool {
    const file = try dir.openFile(io, sub_path, .{});
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var file_reader = file.readerStreaming(io, &buffer);
    return is16BitFromFile(&file_reader);
}

/// `stbi_is_hdr_from_memory`: whether the image is HDR, the one format that
/// decodes to floats directly.
pub fn isHdrFromMemory(bytes: []const u8) bool {
    var source: Source = .initMemory(bytes);
    return isHdrMain(&source);
}

/// `stbi_is_hdr_from_callbacks`.
pub fn isHdrFromReader(reader: *std.Io.Reader) error{ReadFailed}!bool {
    var source: Source = undefined;
    source.initReader(reader);
    const found = isHdrMain(&source);
    if (source.read_failed) return error.ReadFailed;
    return found;
}

/// `stbi_is_hdr_from_file`: the file reader is put back where it was.
pub fn isHdrFromFile(
    file_reader: *std.Io.File.Reader,
) (error{ReadFailed} || std.Io.File.Reader.SeekError)!bool {
    const start = file_reader.logicalPos();
    var source: Source = undefined;
    source.initReader(&file_reader.interface);
    const found = isHdrMain(&source);
    try file_reader.seekTo(start);
    if (source.read_failed) return error.ReadFailed;
    return found;
}

/// `stbi_is_hdr`. A file that cannot be opened is not HDR, as there.
pub fn isHdrFromPath(io: std.Io, dir: std.Io.Dir, sub_path: []const u8) bool {
    const file = dir.openFile(io, sub_path, .{}) catch return false;
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var file_reader = file.readerStreaming(io, &buffer);
    return isHdrFromFile(&file_reader) catch false;
}

test {
    std.testing.refAllDecls(@This());
    _ = common;
    _ = postprocess;
}
