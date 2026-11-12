# zig-stb-image

Tracks stb_image 2.30 · Zig 0.17 · [status](STATUS.md)

## What it is

A Zig port of stb_image, Sean Barrett's single-file image loader from
[stb](#licence-and-references). It decodes JPEG, PNG, TGA, BMP, PSD, GIF,
HDR, PIC and PNM images to 8-bit, 16-bit or float samples, and gives the
original's pixels and failure reasons. It is pure Zig, with no dependencies
beyond the standard library.

This port is not affiliated with or reviewed by the original authors. Its
code was written with AI assistance for Farhollow Games, and is only machine
verified. See [the tests](doc/TESTING.md) and [parity with the original](doc/parity.md).

## Features

- JPEG baseline and progressive, with restart markers, DNL, JFIF and Adobe
  colour transforms, CMYK and YCCK.
- PNG at 1, 2, 4, 8 and 16 bits, every colour type, palettes and `tRNS`,
  Adam7 interlace, and iPhone CgBI files.
- TGA, BMP, PSD (the composited image, 8 and 16 bits), GIF (the first frame,
  or every frame with its delay), HDR (Radiance RGBE), PIC (Softimage) and
  binary PNM.
- Loads from memory, from a `std.Io.Reader`, from a file or a path; the
  info, 16-bit and HDR queries; any requested component count; vertical
  flip, HDR and LDR gamma and scale, iPhone unpremultiply and BGR
  conversion, as global and thread-local settings or per call.
- `stbi.zlib`: the original's zlib inflate.
- Caller-set dimension and memory limits, defaulting to the original's.
- Every function that allocates takes a `std.mem.Allocator`.

## Install

```sh
zig fetch --save git+https://github.com/farhollowgames/zig-stb-image#main
```

There is no release yet; this fetches `main`.

In `build.zig`:

```zig
const stb_image = b.dependency("stb_image", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("stb_image", stb_image.module("stb_image"));
```

`-Djpeg=false`, `-Dpng=false` and so on leave a format out, as the
original's `STBI_NO_*` switches do.

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
- `-Djpeg-idct=scalar|sse2` picks which of the original's builds the JPEG
  decoder follows on damaged coefficients, where the two differ.

*Changes to expect*:

- Failures are a Zig error set; `failureReason` and `failureMessage` give
  the original's two strings.
- Where the original reads or writes out of bounds, reads memory it never
  wrote or is undefined, the port returns an error. Some real files are
  refused this way, such as OS/2 BMPs that use their last palette entries.
- The component count is an enum, so the original's "bad req_comp" cannot
  happen.
- The reader functions take a `std.Io.Reader` in place of
  `stbi_io_callbacks`.
- `pow` is glibc 2.44's (from Arm's optimized-routines), so float
  conversions match the original built against that glibc on x86-64.

## Not included

The parts of the original that are left out, each with its reason, are listed in
[`STATUS.md`](STATUS.md), under "Left out".

## Testing and benchmarks

`zig build test` runs 162 tests. 159 run the original beside the port on the
same inputs and compare their results: success, size, channels, every output
byte (floats by their bits), the failure reason in both forms, and where a
file is left. The inputs are the test images of other decoders (PngSuite,
bmpsuite, jpeg-decoder, image-rs, psd-tools, libjpeg-turbo), hand-made edge
cases and about 27,500 seeded fuzz cases. `zig build sanitize` runs every
test input through the original under AddressSanitizer and
UndefinedBehaviorSanitizer, to find the inputs the original is unsafe on.

Port time against original time, for a 960 x 720 photograph:

| feature | port vs original |
| --- | ---: |
| PNG, 8-bit RGB | 10% slower |
| JPEG 4:2:0 | 52% slower (1% slower than the original without SIMD) |
| BMP, 24-bit | 95% slower |
| GIF, first frame | 25% faster |
| zlib inflate | 9% slower |

AMD Ryzen 9 9950X3D, one thread, Linux 7.3.3, Zig 0.17.0 ReleaseFast
against clang 22.1.8 `-O3` with the original's SSE2 paths, at commit
`8e1f84e`, on a busy machine (load average about 15 on 32 hardware
threads). The port has no SIMD code yet; a performance pass is next.

- [`doc/TESTING.md`](doc/TESTING.md): how the tests compare the port with
  the original, and what this repository's tests cover.
- [`doc/BENCHMARKS.md`](doc/BENCHMARKS.md): ratios and full tables: every
  feature, the flags on both sides, the biases and the command.

## Licence and references

The original's licence: MIT or public domain (the Unlicense), your choice
([`LICENSE`](LICENSE)). zig-stb-image is an altered version of stb_image:
the code is rewritten in Zig, with its own interface. The original's licence
text and its notice, "Copyright (c) 2017 Sean Barrett", are kept in
`LICENSE` as they are. `src/pow.zig` is translated from Arm's
optimized-routines and is used under the MIT licence; its text and Arm's
copyright notices are in `LICENSE` too.

- [stb](https://github.com/nothings/stb), the original, by
  [Sean Barrett](https://github.com/nothings) and the stb_image
  contributors.
- [optimized-routines](https://github.com/ARM-software/optimized-routines),
  Arm's maths routines, which glibc's `pow` and the port's are built from.

Made by Farhollow Games for the Loomwork Engine.
