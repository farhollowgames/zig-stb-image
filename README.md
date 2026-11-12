# zig-stb-image

Ported from stb_image 2.30 (`a7d4c21`) · Zig 0.17.0 · [status](STATUS.md)

This port is not affiliated with or reviewed by the original authors. Its
code was written with AI assistance for Farhollow Games, and is only machine
verified. See [the tests](doc/TESTING.md) and [parity with the original](doc/parity.md).

## What it is

A Zig port of stb_image, Sean Barrett's single-file image loader from stb.
It decodes JPEG, PNG, TGA, BMP, PSD, GIF, HDR, PIC and PNM images to 8-bit,
16-bit or float samples, and gives the original's pixels and failure
reasons. It is pure Zig, with no dependencies beyond the standard library.
The original is listed under [References](#references).

## Features

- JPEG baseline and progressive, with restart markers, DNL, JFIF and Adobe
  colour transforms, CMYK and YCCK.
- PNG at 1, 2, 4, 8 and 16 bits, every colour type, palettes and `tRNS`,
  Adam7 interlace, and iPhone CgBI files.
- TGA, BMP, PSD (the composited image, 8 and 16 bits), GIF (the first frame,
  or every frame with its delay), HDR (Radiance RGBE), PIC (Softimage) and
  binary PNM.
- Loads from memory, from a `std.Io.Reader`, from a file or a path; the
  info, 16-bit and HDR queries; any requested component count.
- Vertical flip, iPhone unpremultiply and BGR conversion as global and
  thread-local settings, HDR and LDR gamma and scale as global settings, and
  all of them per call.
- `stbi.zlib`: the original's zlib inflate.
- Caller-set limits on image dimensions and image buffer sizes, defaulting
  to the original's. They do not bound all memory (a PNG's compressed data
  inflates as far as it goes, as in the original); an allocator can.
- Every function that allocates takes a `std.mem.Allocator`.

## Install

```sh
zig fetch --save git+https://github.com/farhollowgames/zig-stb-image#main
```

There is no release yet; this fetches `main`. The package needs Zig 0.17.0.

In `build.zig`:

```zig
const stb_image = b.dependency("stb_image", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("stb_image", stb_image.module("stb_image"));
```

### Build options

The original's compile-time switches are build options, passed where the
dependency is declared, such as `.png = false`:

| option | original | effect |
| --- | --- | --- |
| `jpeg`, `png`, `bmp`, `tga`, `psd`, `gif`, `hdr`, `pic`, `pnm` | `STBI_NO_*`, `STBI_ONLY_*` | `false` leaves the format out, and it is never detected; each is on by default |
| `jpeg-idct` | `STBI_NO_SIMD`, `STBI_SSE2` | `sse2` or `scalar`: which of the original's builds the JPEG decoder follows on damaged coefficients, where the two differ; `sse2` by default on x86-64, `scalar` elsewhere |

## Use

Load an image as RGBA, whatever its format:

```zig
const std = @import("std");
const stbi = @import("stb_image");

pub fn loadRgba(gpa: std.mem.Allocator, bytes: []const u8) !stbi.Image(u8) {
    const image = stbi.loadFromMemory(u8, gpa, bytes, .{ .components = .rgba }) catch |err| {
        std.log.err("not loaded: {s}", .{stbi.failureMessage(err)});
        return err;
    };
    // image.pixels holds width * height * 4 bytes, top row first.
    return image;
}
```

The caller frees the pixels with `image.deinit(gpa)`.

## Differences from the original

The reasons are in [`doc/parity.md`](doc/parity.md).

*Additions*:

- `Options` per call for every setting, beside the global and thread-local
  ones.
- `Limits` per call, in place of the `STBI_MAX_DIMENSIONS` compile switch.
- `-Djpeg-idct=sse2|scalar` picks which of the original's builds the JPEG
  decoder follows on damaged coefficients, where the two differ: `sse2` on
  x86-64, as the original builds there, and `scalar` elsewhere.

*Changes to expect*:

- Failures are a Zig error set; `failureReason` and `failureMessage` give
  the original's two strings.
- Where the original reads or writes out of bounds, reads memory it never
  wrote or is undefined, the port returns an error.
- BMP palette entries the original never reads, which it takes from
  uninitialized memory, read as black, so OS/2 BMPs whose palette the
  original reads short load.
- The component count is an enum, so the original's "bad req_comp" cannot
  happen.
- The reader functions take a `std.Io.Reader` in place of
  `stbi_io_callbacks`.
- `pow` is glibc 2.44's (from Arm's optimized-routines), so float
  conversions match the original built against that glibc on x86-64.

## Left out

The parts of the original that are left out, each with its reason, are
listed in [`STATUS.md`](STATUS.md#left-out-approved). In short:

- Build switches Zig has no need for: `STBI_NO_FAILURE_STRINGS`,
  `STBI_NO_STDIO`, `STBI_NO_LINEAR`, `STBI_SUPPORT_ZLIB` and `STBI_NO_ZLIB`
  (Zig compiles only the functions a program calls), `STBI_NO_THREAD_LOCALS`,
  `STBI_WINDOWS_UTF8` (Zig paths are UTF-8 on Windows already) and the C
  linkage macros.
- The NEON build of the JPEG IDCT, which the port does not follow.
- Inputs on which the original reads or writes out of bounds, reads memory
  it never wrote, never returns or is undefined: the port refuses them with
  an error, each listed in `doc/parity.md` with its test.

## Tests

`zig build test` runs 182 tests. 171 run the original beside the port on
the same inputs and compare their results: success, size, channels, every
output byte (floats by their bits), the failure reason in both forms, and
where a file is left. The inputs are the test images of other decoders
(PngSuite, bmpsuite, jpeg-decoder, image-rs, psd-tools, libjpeg-turbo),
hand-made edge cases and about 27,500 seeded fuzz cases, loaded from
memory, readers, files and paths. They pass in ReleaseSafe and ReleaseFast.
`zig build sanitize` runs every test input through the original under
AddressSanitizer and UndefinedBehaviorSanitizer: of 419,867 calls it
flagged 3,119. The port refuses each of those inputs except 85, which
[`doc/parity.md`](doc/parity.md) explains: an empty PNG IDAT chunk, where
the original passes a null pointer to `memcpy` for 0 bytes, and overflows
in the scalar JPEG IDCT, whose build the port follows only with
`-Djpeg-idct=scalar` (and then refuses them).

- [`doc/TESTING.md`](doc/TESTING.md): how the tests compare the port with
  the original, and what this repository's tests cover.
- [`doc/parity.md`](doc/parity.md): where the port differs from the
  original, and the test of each difference.

## Speed

Port time against original time, one thread, for a 960 x 720 photograph
loaded from memory:

| feature | time, port / original | port vs original |
| --- | ---: | ---: |
| PNG, 8-bit RGB | 0.78 | 22% faster |
| JPEG 4:2:0 | 0.52 | 48% faster |
| JPEG progressive | 0.97 | 3% faster |
| BMP, 24-bit | 0.04 | 96% faster |
| zlib inflate | 0.82 | 18% faster |

No row of the full table is slower than the original; the closest are
progressive JPEG (3% faster) and PNM (1% faster).

AMD Ryzen 9 9950X3D, one thread, Linux 7.3.3, Zig 0.17.0 ReleaseFast against
clang 22.1.8 `-O3` with the original's SSE2 paths, at commit `ac97ea4`;
each side's best median of three rounds; a load average of 6 to 20 on 32
hardware threads, from other builds.

- [`doc/BENCHMARKS.md`](doc/BENCHMARKS.md): every feature, the flags on both
  sides, the biases and the command.

## Licence

MIT or public domain (the Unlicense), your choice, as the original
([`LICENSE`](LICENSE)). zig-stb-image is an altered version of stb_image:
the code is rewritten in Zig, with its own interface. The original's licence
text and its notice, "Copyright (c) 2017 Sean Barrett", are kept in
`LICENSE` as they are, beside "Copyright (c) 2026 Farhollow Games".
`src/pow.zig` is translated from Arm's optimized-routines and is used under
the MIT licence; its text and Arm's copyright notices are in `LICENSE` too.

## References

- [stb](https://github.com/nothings/stb), the original, by
  [Sean Barrett](https://github.com/nothings) and the stb_image
  contributors, commit `a7d4c21`, copied into `reference/` for the tests and
  the benchmark only.
- [optimized-routines](https://github.com/ARM-software/optimized-routines),
  Arm's maths routines, which glibc's `pow` and the port's are built from.
- The test images, from the repositories of stb, jpeg-decoder, image-rs,
  psd-tools and libjpeg-turbo, fetched as lazy dependencies for the tests
  and the benchmark only.

Made by Farhollow Games for the Loomwork Engine.
