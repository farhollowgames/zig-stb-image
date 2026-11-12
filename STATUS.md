# Status

Every public function, build option and format of stb_image 2.30 (stb
commit `a7d4c2175630e1ea5b6f8dd00ab96fed0b97b96d`, `reference/stb_image.h`,
`STBI_VERSION 1`), and its state:

- **not started**;
- **ported**: translated;
- **oracle-tested**: tests run the original and the port on the same inputs
  and compare success, size, channel count, every output byte (floats by
  their bits) and the failure reason in both its short and long forms;
- **benchmarked**: timed against the original by `zig build bench`;
- **reviewed**: an agent that did not write the port has tried to break it.

## Work in progress

The port is being written. This section says where it stands, for whoever
picks it up; the git log has the detail.

- **Done:** the repository, the pinned original in `reference/`, the test
  images as lazy dependencies, the shared code (`src/common.zig`: the byte
  source, size checks, component conversion; `src/postprocess.zig`;
  `src/settings.zig`; `src/errors.zig`), the public API in
  `src/stb_image.zig`, and the oracle (`test/shim/oracle.c`,
  `test/oracle.zig`, `test/fuzz.zig`, `test/corpus.zig`).
- **Placeholders:** every format file in `src/` (detects nothing), `src/zlib.zig`
  (empty) and `src/pow.zig` (std's `pow`, not the C library's).
- **Next:** the decoders, each with its oracle tests:
  zlib and PNG; JPEG; the other seven formats and `pow`. Then the
  benchmark, the docs, and steps 5 to 7 of the methodology.
- **Builds:** one at a time, under the memory cap, as
  `timeout 3000 systemd-run --user --scope -q -p MemoryMax=6G zig build <step> -j3`.
- **Sanitizer run:** `zig build sanitize` runs every test's calls to the
  original through a build of it with AddressSanitizer and
  UndefinedBehaviorSanitizer (system clang) and lists the flagged calls in
  `zig-out/sanitize/report.txt`.
- **Branches:** the decoders are written on `port/png`, `port/jpeg`,
  `port/bmp-tga-psd-pnm` and `port/gif-hdr-pic` (worktrees under
  `~/Projects/zig-stb-image.wt/`), merged into `main` when their tests pass.

## Formats

| format | upstream | zig-stb-image | tests | state |
| --- | --- | --- | --- | --- |
| JPEG baseline | `stbi__jpeg_*` | `src/jpeg.zig` | | not started |
| JPEG progressive | as above | as above | | not started |
| JPEG restart markers, DNL, Adobe and JFIF colour transforms, CMYK and YCCK | as above | as above | | not started |
| PNG 1, 2, 4, 8, 16 bits, every colour type, palettes, tRNS | `stbi__png_*` | `src/png.zig` | | not started |
| PNG Adam7 interlace | as above | as above | | not started |
| PNG iPhone CgBI, BGR conversion and unpremultiply | `stbi__de_iphone` | as above | | not started |
| zlib (inflate) | `stbi__zbuf`, `stbi__parse_zlib` | `src/zlib.zig` | | not started |
| TGA | `stbi__tga_*` | `src/tga.zig` | | not started |
| BMP | `stbi__bmp_*` | `src/bmp.zig` | | not started |
| PSD (composited image, 8 and 16 bits, RLE and raw) | `stbi__psd_*` | `src/psd.zig` | | not started |
| GIF, first frame | `stbi__gif_load` | `src/gif.zig` | `test/gif_test.zig`: the corpus, every LZW code size and stream shape, full code tables, corrupt rasters, interlace, palettes and transparency, frames off the canvas, extensions, headers, truncation, limits, allocation failures, 2,000 fuzz cases | oracle-tested |
| GIF, every frame | `stbi_load_gif_from_memory` | `loadGifFromMemory` | as above, every test also as an animation: every disposal method, delays, frames kept after a failure; refusals in `doc/parity.md` | oracle-tested |
| HDR (Radiance RGBE, RLE and flat) | `stbi__hdr_*` | `src/hdr.zig` | `test/hdr_test.zig`: the corpus, RLE and flat sizes, the old RLE form, bad runs, every header form, long header lines, truncation, gammas and scales, limits, allocation failures, 2,000 fuzz cases | oracle-tested |
| PIC (Softimage) | `stbi__pic_*` | `src/pic.zig` | `test/pic_test.zig`: every packet type and channel layout, empty images, bad packets, overrunning and short scanlines, truncation, headers and info, limits, allocation failures, 3,000 fuzz cases | oracle-tested |
| PNM (binary PGM and PPM, 8 and 16 bits) | `stbi__pnm_*` | `src/pnm.zig` | | not started |

## Functions

| upstream | zig-stb-image | tests | state |
| --- | --- | --- | --- |
| `stbi_load_from_memory`, `stbi_load_16_from_memory`, `stbi_loadf_from_memory` | `loadFromMemory(u8 / u16 / f32, …)` | every corpus file and fuzz case | ported |
| `stbi_load_from_callbacks`, `stbi_load_16_from_callbacks`, `stbi_loadf_from_callbacks`, `stbi_io_callbacks` | `loadFromReader` on a `*std.Io.Reader` | corpus files; fuzz cases | ported |
| `stbi_load_from_file`, `stbi_load_from_file_16`, `stbi_loadf_from_file` | `loadFromFile` on a `*std.Io.File.Reader`, leaving it where the original leaves the `FILE` | corpus files; fuzz cases | ported |
| `stbi_load`, `stbi_load_16`, `stbi_loadf` | `loadFromPath` | | ported |
| `stbi_load_gif_from_memory` | `loadGifFromMemory` | `test/gif_test.zig` | oracle-tested |
| `stbi_info_from_memory`, `stbi_info_from_callbacks`, `stbi_info_from_file`, `stbi_info` | `infoFromMemory`, `infoFromReader`, `infoFromFile`, `infoFromPath` | corpus files; fuzz cases | ported |
| `stbi_is_16_bit_from_memory`, `…_from_callbacks`, `…_from_file`, `stbi_is_16_bit` | `is16BitFromMemory`, `…FromReader`, `…FromFile`, `…FromPath` | as above | ported |
| `stbi_is_hdr_from_memory`, `…_from_callbacks`, `…_from_file`, `stbi_is_hdr` | `isHdrFromMemory`, `…FromReader`, `…FromFile`, `…FromPath` | as above | ported |
| `desired_channels`, `*channels_in_file` | `Options.components`, `Image.channels` and `Image.channels_in_file` | every load compares all five | ported |
| `stbi_set_flip_vertically_on_load`, `…_thread` | `Options.flip_vertically`; `settings.setFlipVerticallyOnLoad`, `…Thread` | | ported |
| `stbi_set_unpremultiply_on_load`, `…_thread` | `Options.unpremultiply`; `settings.setUnpremultiplyOnLoad`, `…Thread` | | ported |
| `stbi_convert_iphone_png_to_rgb`, `…_thread` | `Options.convert_iphone_png`; `settings.convertIphonePngToRgb`, `…Thread` | | ported |
| `stbi_hdr_to_ldr_gamma`, `stbi_hdr_to_ldr_scale` | `Options.hdr_to_ldr_gamma`, `…_scale`; `settings.setHdrToLdrGamma`, `…Scale` | | ported |
| `stbi_ldr_to_hdr_gamma`, `stbi_ldr_to_hdr_scale` | `Options.ldr_to_hdr_gamma`, `…_scale`; `settings.setLdrToHdrGamma`, `…Scale` | | ported |
| `stbi_failure_reason` | the returned `Error`; `failureReason(err)` | every failing load compares it | ported |
| `stbi_image_free` | `Image.deinit`, `Animation.deinit` | every test runs on `std.testing.allocator` | ported |
| `stbi_zlib_decode_malloc_guesssize`, `…_malloc`, `…_malloc_guesssize_headerflag`, `…_buffer`, `…_noheader_malloc`, `…_noheader_buffer` | `zlib` | | not started |

## Build options

| upstream | zig-stb-image | state |
| --- | --- | --- |
| `STBI_NO_JPEG` … `STBI_NO_PNM`, `STBI_ONLY_JPEG` … `STBI_ONLY_PNM` | `-Djpeg=false` and so on: a format left out is never detected | ported |
| `STBI_MAX_DIMENSIONS` | `Options.limits.dimension_max` | ported |
| `STBI_FAILURE_USERMSG` | `failureMessage(err)` | ported |
| `STBI_NO_FAILURE_STRINGS` | none: the strings are compiled only where `failureReason` or `failureMessage` is called | awaiting the author's approval |
| `STBI_NO_STDIO` | none: the file functions are compiled only where called | awaiting the author's approval |
| `STBI_NO_LINEAR`, `STBI_NO_HDR`'s float half | none: the float functions are compiled only where called | awaiting the author's approval |
| `STBI_SUPPORT_ZLIB`, `STBI_NO_ZLIB` | none: `zlib` is compiled only where used | awaiting the author's approval |
| `STBI_MALLOC`, `STBI_REALLOC`, `STBI_REALLOC_SIZED`, `STBI_FREE` | the `std.mem.Allocator` each call takes | ported |
| `STBI_ASSERT` | Zig's safety checks | ported |
| `STBI_NO_SIMD`, `STBI_SSE2`, `STBI_NEON` | see "Left out" | awaiting the author's approval |
| `STBI_NO_THREAD_LOCALS` | none: Zig has `threadlocal` on every target the port builds for | awaiting the author's approval |
| `STBI_WINDOWS_UTF8`, `stbi_convert_wchar_to_utf8` | none: Zig paths are UTF-8 on Windows already | awaiting the author's approval |
| `STB_IMAGE_STATIC`, `STBIDEF`, `STB_IMAGE_IMPLEMENTATION` | none: C linkage only | awaiting the author's approval |

## Left out (awaiting the author's approval)

To be completed with the decoders.

### GIF, HDR and PIC

Inputs on which the original is unsafe or undefined, which the port refuses
with an error (`doc/parity.md` has each one and its test):

- GIF: restoring to the previous frame once two frames are out
  (`GifDisposeToPrevious`); an animation of no pixels with several frames
  (`GifZeroAreaFrames`); a flipped animation of fewer than 4 components
  (`GifFlipComponents`); rows past the 32-bit range (`TooLargeGif`).
- HDR: flat pixels that end early (`HdrTruncated`); info on a negative
  size.
- PIC: a packet or scanline failure loaded to other than 4 components.
