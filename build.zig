const std = @import("std");

const Format = enum { jpeg, png, bmp, tga, psd, gif, hdr, pic, pnm };

/// The JPEG IDCT to compute: the original's scalar one, or its SSE2 one.
const JpegIdct = enum { scalar, sse2 };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The formats to decode, as stb_image's STBI_NO_* and STBI_ONLY_*.
    const format_options = b.addOptions();
    inline for (@typeInfo(Format).@"enum".field_names) |name| {
        const enabled = b.option(bool, name, "Decode " ++ name ++ " (default true)") orelse true;
        format_options.addOption(bool, name, enabled);
    }
    // The original builds its SSE2 IDCT for x86-64 and its scalar one for
    // targets without SSE2.
    const jpeg_idct = b.option(
        JpegIdct,
        "jpeg-idct",
        "The JPEG IDCT whose samples to give where the original's builds differ " ++
            "(default sse2 on x86-64, else scalar)",
    ) orelse if (target.result.cpu.arch == .x86_64) JpegIdct.sse2 else .scalar;
    format_options.addOption(JpegIdct, "jpeg_idct", jpeg_idct);
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

    const corpus_module = corpus_paths.createModule();
    const differential = differentialTest(b, target, test_optimize, test_module, corpus_module, .{
        .filters = test_filters,
        .fuzz_seed = fuzz_seed,
        .fuzz_replay = fuzz_replay,
        .sanitize = false,
        .jpeg_idct = jpeg_idct,
    });
    differential.root_module.linkLibrary(oracleLibrary(b, target, .simd));
    differential.root_module.linkLibrary(oracleLibrary(b, target, .scalar));
    test_step.dependOn(&b.addRunArtifact(differential).step);

    addSanitize(b, target, test_optimize, test_module, corpus_module, .{
        .filters = test_filters,
        .fuzz_seed = fuzz_seed,
        .fuzz_replay = fuzz_replay,
        .sanitize = true,
        .jpeg_idct = jpeg_idct,
    });

    addBench(b, target, format_module);
}

/// `zig build bench`: the port at ReleaseFast against the original at -O3,
/// for the same CPU. Arguments after `--` go to the benchmark.
fn addBench(b: *std.Build, target: std.Build.ResolvedTarget, format_module: *std.Build.Module) void {
    const stb = b.lazyDependency("stb", .{}) orelse return;
    const jpeg_decoder = b.lazyDependency("jpeg_decoder", .{}) orelse return;
    const image_rs = b.lazyDependency("image_rs", .{}) orelse return;

    const paths = b.addOptions();
    paths.addOptionPath("photo", jpeg_decoder.path("tests/reftest/images/mjpeg.png"));
    paths.addOptionPath("progressive", jpeg_decoder.path("tests/reftest/images/progressive3.jpg"));
    paths.addOptionPath("ycck", jpeg_decoder.path("tests/reftest/images/ycck.jpg"));
    paths.addOptionPath("gif", image_rs.path("tests/images/gif/anim/large-gif-anim-combine.gif"));

    const port = b.createModule(.{
        .root_source_file = b.path("src/stb_image.zig"),
        .target = target,
        .optimize = .fast,
        .imports = &.{.{ .name = "stb_image_options", .module = format_module }},
    });
    const bench = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/bench.zig"),
            .target = target,
            .optimize = .fast,
            .link_libc = true,
            .imports = &.{
                .{ .name = "stb_image", .module = port },
                .{ .name = "bench_paths", .module = paths.createModule() },
            },
        }),
    });
    bench.root_module.linkLibrary(oracleLibrary(b, target, .simd));
    bench.root_module.linkLibrary(oracleLibrary(b, target, .scalar));
    bench.root_module.addIncludePath(stb.path(""));
    bench.root_module.addCSourceFile(.{
        .file = b.path("bench/writers.c"),
        .flags = &.{ "-O3", "-std=c99" },
    });

    const run = b.addRunArtifact(bench);
    run.addPassthruArgs();
    run.stdio = .inherit;
    const step = b.step("bench", "Time the port against the original");
    step.dependOn(&run.step);
    step.dependOn(&b.addInstallArtifact(bench, .{}).step);
}

const TestConfig = struct {
    filters: []const []const u8,
    fuzz_seed: u64,
    fuzz_replay: ?u64,
    sanitize: bool,
    /// The IDCT the port follows, which names the sanitizer run's output.
    jpeg_idct: JpegIdct,
};

fn differentialTest(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    test_optimize: std.lang.Optimize,
    test_module: *std.Build.Module,
    corpus_module: *std.Build.Module,
    config: TestConfig,
) *std.Build.Step.Compile {
    const fuzz_options = b.addOptions();
    fuzz_options.addOption(u64, "fuzz_seed", config.fuzz_seed);
    fuzz_options.addOption(?u64, "fuzz_replay", config.fuzz_replay);
    fuzz_options.addOption(bool, "sanitize", config.sanitize);
    return b.addTest(.{
        .name = if (config.sanitize) "differential-sanitize" else "differential",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/all.zig"),
            .target = target,
            .optimize = test_optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "stb_image", .module = test_module },
                .{ .name = "corpus_paths", .module = corpus_module },
                .{ .name = "fuzz_options", .module = fuzz_options.createModule() },
            },
        }),
        .filters = config.filters,
    });
}

/// `zig build sanitize`: every test's calls to the original, through the
/// original built by the system clang with AddressSanitizer and
/// UndefinedBehaviorSanitizer, each call in child processes that stop at
/// the first report. For every flagged call the port runs on the same
/// input and request; zig-out/sanitize/<filters>/ gets the flagged calls
/// (report.txt), those the port accepts (accepted.txt), the counts and the
/// full log. Needs clang with its sanitizer runtimes on the PATH.
fn addSanitize(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    test_optimize: std.lang.Optimize,
    test_module: *std.Build.Module,
    corpus_module: *std.Build.Module,
    config: TestConfig,
) void {
    const step = b.step("sanitize", "Run every test's inputs through the original under ASan and UBSan");
    const sanitize_flags = [_][]const u8{
        "-O1",
        "-g",
        "-fPIC",
        "-fno-omit-frame-pointer",
        "-fsanitize=address,undefined",
        // Every report ends the child process making the call.
        "-fno-sanitize-recover=all",
        "-std=c99",
        "-D_GNU_SOURCE",
        "-ffp-contract=off",
    };
    const link = b.addSystemCommand(&.{
        "clang",
        "-shared",
        "-shared-libasan",
        "-fsanitize=address,undefined",
        "-o",
    });
    const shared = link.addOutputFileArg("libstb_image_sanitize.so");
    for ([_][]const []const u8{
        &.{"-DORACLE_PREFIX=simd"},
        &.{ "-DORACLE_PREFIX=scalar", "-DSTBI_NO_SIMD", "-DSTBI_FAILURE_USERMSG" },
    }, [_][]const u8{ "simd", "scalar" }) |path_flags, name| {
        const cc = b.addSystemCommand(&.{ "clang", "-c" });
        cc.addArgs(&sanitize_flags);
        cc.addArgs(path_flags);
        cc.addPrefixedDirectoryArg("-I", b.path("reference"));
        cc.addFileArg(b.path("test/shim/oracle.c"));
        cc.addArg("-o");
        link.addFileArg(cc.addOutputFileArg(b.fmt("oracle_{s}.o", .{name})));
    }

    const differential = differentialTest(b, target, test_optimize, test_module, corpus_module, config);
    differential.root_module.addObjectFile(shared);
    differential.root_module.addRPath(shared.dirname());

    const run = b.addSystemCommand(&.{"sh"});
    run.addFileArg(b.path("tools/sanitize.sh"));
    run.addArtifactArg(differential);
    run.addFileArg(shared);
    const out = run.addOutputDirectoryArg("sanitize");
    run.has_side_effects = true;
    run.stdio = .inherit;
    const install = b.addInstallDirectory(.{
        .source_dir = out,
        .install_dir = .prefix,
        .install_subdir = b.fmt("sanitize/{s}{s}", .{
            runName(b, config.filters),
            if (config.jpeg_idct == .scalar) "+jpeg-idct-scalar" else "",
        }),
    });
    step.dependOn(&install.step);
}

/// A directory name for a run with `filters`: "all" without any, else the
/// filters joined by "+", with every character other than letters, digits,
/// '.', '_', '-' and '+' made a '-'.
fn runName(b: *std.Build, filters: []const []const u8) []const u8 {
    if (filters.len == 0) return "all";
    const name = std.mem.join(b.allocator, "+", filters) catch @panic("OOM");
    for (name) |*c| {
        const kept = std.ascii.isAlphanumeric(c.*) or c.* == '.' or c.* == '_' or
            c.* == '-' or c.* == '+';
        if (!kept) c.* = '-';
    }
    return name;
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
