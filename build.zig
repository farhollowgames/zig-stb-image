const std = @import("std");

const Format = enum { jpeg, png, bmp, tga, psd, gif, hdr, pic, pnm };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The formats to decode, as stb_image's STBI_NO_* and STBI_ONLY_*.
    const format_options = b.addOptions();
    inline for (@typeInfo(Format).@"enum".field_names) |name| {
        const enabled = b.option(bool, name, "Decode " ++ name ++ " (default true)") orelse true;
        format_options.addOption(bool, name, enabled);
    }
    const format_module = format_options.createModule();

    const stb_image = b.addModule("stb_image", .{
        .root_source_file = b.path("src/stb_image.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "stb_image_options", .module = format_module }},
    });
    _ = stb_image;

    // Tests default to ReleaseSafe: the fuzz tests run many thousands of
    // decodes, and ReleaseSafe keeps every assert and overflow check on.
    const test_optimize = b.option(
        std.lang.Optimize,
        "test-optimize",
        "Optimize mode for the tests (default ReleaseSafe)",
    ) orelse .safe;
    const test_filters = b.option(
        []const []const u8,
        "test-filter",
        "Skip tests that do not match any filter",
    ) orelse &.{};
    const fuzz_seed = b.option(
        u64,
        "fuzz-seed",
        "Offset every fuzz test's seed, to run other cases (default 0)",
    ) orelse 0;
    const fuzz_replay = b.option(u64, "fuzz-replay", "Run only this case in each fuzz test");

    const test_module = b.createModule(.{
        .root_source_file = b.path("src/stb_image.zig"),
        .target = target,
        .optimize = test_optimize,
        .imports = &.{.{ .name = "stb_image_options", .module = format_module }},
    });

    const test_step = b.step("test", "Run unit and differential tests");
    const unit_tests = b.addTest(.{ .root_module = test_module, .filters = test_filters });
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);

    // The test images are fetched only for this repository's own tests, and
    // never for a package that depends on this one.
    if (!b.isRoot()) return;
    const corpus_paths = b.addOptions();
    var have_corpora = true;
    for (corpora) |name| {
        if (b.lazyDependency(name, .{})) |dependency| {
            corpus_paths.addOptionPathDirectory(name, dependency.path(""));
        } else have_corpora = false;
    }
    if (!have_corpora) return;

    const fuzz_options = b.addOptions();
    fuzz_options.addOption(u64, "fuzz_seed", fuzz_seed);
    fuzz_options.addOption(?u64, "fuzz_replay", fuzz_replay);

    const differential = b.addTest(.{
        .name = "differential",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/all.zig"),
            .target = target,
            .optimize = test_optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "stb_image", .module = test_module },
                .{ .name = "corpus_paths", .module = corpus_paths.createModule() },
                .{ .name = "fuzz_options", .module = fuzz_options.createModule() },
            },
        }),
        .filters = test_filters,
    });
    differential.root_module.linkLibrary(oracleLibrary(b, target, .simd));
    differential.root_module.linkLibrary(oracleLibrary(b, target, .scalar));
    test_step.dependOn(&b.addRunArtifact(differential).step);
}

const corpora = [_][]const u8{ "stb", "jpeg_decoder", "image_rs", "psd_tools", "libjpeg_turbo" };

const OraclePath = enum { simd, scalar };

/// The original from `reference/`, with the tests' C interface, at -O3
/// (Zig's ReleaseFast gives C -O2). Fused multiply-adds are off, so float
/// steps round as written, as Zig's do. `scalar` turns the SIMD paths off,
/// and makes the failure reasons the long ones.
fn oracleLibrary(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    path: OraclePath,
) *std.Build.Step.Compile {
    const library = b.addLibrary(.{
        .name = b.fmt("stb_image_{t}", .{path}),
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = .fast,
            .link_libc = true,
        }),
    });
    library.root_module.addIncludePath(b.path("reference"));
    const common_flags = [_][]const u8{
        "-O3",
        "-std=c99",
        "-D_GNU_SOURCE",
        "-ffp-contract=off",
        "-fno-fast-math",
        "-fno-sanitize=undefined",
    };
    const path_flags: []const []const u8 = switch (path) {
        .simd => &.{"-DORACLE_PREFIX=simd"},
        .scalar => &.{ "-DORACLE_PREFIX=scalar", "-DSTBI_NO_SIMD", "-DSTBI_FAILURE_USERMSG" },
    };
    library.root_module.addCSourceFile(.{
        .file = b.path("test/shim/oracle.c"),
        .flags = std.mem.concat(b.allocator, []const u8, &.{ &common_flags, path_flags }) catch
            @panic("OOM"),
    });
    return library;
}
