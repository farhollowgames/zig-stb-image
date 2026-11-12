# Status

## Report at the end of step 4 (11 November 2026)

- **Done:** every format, function and switch of stb_image 2.30 is ported
  to Zig 0.17 and compared with the original, on `main`. 162 tests pass in
  ReleaseSafe (159 against both builds of the original, SSE2 and scalar);
  the JPEG tests also pass with `-Djpeg-idct=sse2`. About 27,500 seeded fuzz
  cases; every corpus file through every load and query path.
- **Benchmark** (port time / original time, 960 x 720 photo, busy machine;
  `doc/BENCHMARKS.md`): PNG 1.00 to 1.20 (palette slowest); JPEG 1.37 to
  1.52 against SSE2, 2.78 to RGBA, 0.91 to 1.01 against the scalar build;
  BMP 1.95 to 2.06; PSD 1.44 to 1.52; TGA 0.94 to 1.03; HDR 0.89 to 0.99;
  PNM 0.99 to 1.00; GIF 0.75 to 0.83; zlib 1.09.
- **Awaiting the author's approval** ("Left out" below has each):
  - build switches with no option: failure strings, stdio, linear, zlib,
    SIMD (with `-Djpeg-idct` for the one place SIMD and scalar differ),
    thread locals, Windows UTF-8, static/STBIDEF;
  - refusals where the original is unsafe: zlib initial size 0 (loops for
    ever); PNG palette index past every PLTE; BMP palette index past the
    palette (this refuses real OS/2 BMPs, `Core_1/4/8_Bit.bmp`,
    `pal8os2sp.bmp`, because the original reads 4 entries too few); BMP
    height -2^31; TGA raw cut short; PSD colour below the white matte; JPEG
    blocks no scan wrote; JPEG scalar IDCT `int` overflow; GIF disposal 3
    once two frames are out; GIF zero-area animation; flipped GIF animation
    of 1 to 3 components; GIF rows past `int`; HDR flat pixels cut short;
    PIC scanline failure converted from NULL.
  - choices: the PNG and BMP palette cases could read unset entries as
    zero instead of refusing; `-Djpeg-idct` defaults to scalar, where
    upstream's x86-64 default is SSE2.
- **Open:** the sanitizer run is now one process per call (an overrun of
  the original corrupted the heap and ended the earlier whole run in the
  GIF tests), and the whole run takes longer than the 50-minute build
  limit. Run per test file, it has finished for GIF (23,277 calls, 339
  flagged, all GIF animations: flipped with fewer than 4 components, and
  disposal cases) and for PIC and HDR (1,838 flagged: PIC loads that
  convert the NULL a failed scanline gives, as `doc/parity.md` says; four
  flagged `is_hdr` queries on PIC tests look misattributed). The flagged
  calls are not yet matched one by one against the refusals the tests
  expect, and the other test files are not yet run. AddressSanitizer does
  not see reads of memory never written (the palette, TGA, HDR and JPEG
  refusals); those cases rest on reading the C and, for JPEG, on the
  three-fill check.
- **Next:** steps 5 to 7 (see "Work in progress").

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

Where the port stands, for whoever picks it up; the git log has the detail.
Steps 1 to 4 of the port methodology are done on `main`; steps 5 to 7 (the
performance pass, the skeptic's review, the fixes) are not started.

- **Done:** every format, function and switch of the tables below is ported
  and compared with the original (162 tests, all passing in ReleaseSafe;
  the JPEG tests also with `-Djpeg-idct=sse2`). `zig build bench` times
  each format against the original. `doc/parity.md` lists every input the
  port refuses where the original is unsafe; `doc/TESTING.md` and
  `doc/BENCHMARKS.md` describe the tests and the benchmark.
- **The author's decisions (12 November 2026):** the build switches are
  left out as listed; every refusal in `doc/parity.md` is approved, except
  that a BMP palette index past the entries the original reads now reads as
  zero (black), so the OS/2 BMPs whose palette the original reads short
  load; `-Djpeg-idct` becomes `sse2` by default on x86-64 once a `@Vector`
  IDCT gives the SSE2 mode's samples bit for bit. The performance target is
  no row slower than the original's SSE2 build.
- **In progress on `review/perf-and-skeptic`** (step 5): three performance
  agents, each on its own branch and worktree under
  `~/Projects/zig-stb-image.wt/`, merged into `review/perf-and-skeptic`
  when done: `perf/jpeg` (IDCT, YCbCr conversion, upsampling, the
  `-Djpeg-idct` default), `perf/png` (unfiltering, palette expansion,
  zlib), `perf/pixels` (the BMP zero-palette change first, then BMP, PSD,
  TGA and the shared component conversion). Each kept change is one commit
  whose message gives its benchmark gain; the oracle tests are not edited
  for speed.
- **Performance: JPEG** (`perf/jpeg`). Time port / original SSE2, best
  of 3, `zig build bench -- --filter jpeg --rounds 3`: 4:4:4 0.70, 4:2:0
  0.52, 4:2:0 to rgba 0.95, grey 0.52, progressive 0.93, ycck 0.74. Done:
  the SSE2-mode IDCT on `@Vector` lanes; `-Djpeg-idct` defaults to `sse2`
  on x86-64; `@Vector` YCbCr to RGB/RGBA with the YCCK blend; `@Vector`
  2x2 (hv_2) upsampling; the bit reader's refill takes up to four bytes at
  once; the baseline AC loop keeps the bit buffer in locals; the DC
  overflow test multiplies instead of dividing; the scalar IDCT
  (`-Djpeg-idct=scalar`) on eight lanes where no step can overflow (that
  mode: 4:4:4 0.73, 4:2:0 0.55, rgba 1.02, grey 0.55, progressive 0.94,
  ycck 0.79 against the SSE2 build; 0.36 to 0.66 against the scalar
  build). Tried and
  dropped (no gain): the grey row as a `@memcpy`; the refill's fast path
  inlined; a DC-only block filled without the IDCT; the component buffers
  left unzeroed. Next
  (rgba is the one row near 1: the port's RGBA costs what its RGB does, so
  the decode itself must get faster): Huffman and per-block overhead, the
  scalar IDCT on vectors where no step can overflow. Resume: measure a
  change with the filtered bench in the same session before and after;
  run `test -Dtest-filter=jpeg` in both `-Djpeg-idct` modes; at the end
  update `doc/BENCHMARKS.md`'s JPEG bias and README's `-Djpeg-idct` line
  (the lead's).
- **Left to do:**
  1. Step 5, the performance pass, by an agent that did not write the port,
     on branch `review/perf-and-skeptic`. Zig 0.17 never vectorizes loops,
     so the original's SSE2 paths (JPEG IDCT, YCbCr conversion, 2x2
     upsampling) and the loops clang vectorizes at -O3 (PNG unfiltering,
     component conversion, PNG palette expansion) need explicit `@Vector`
     code to keep up. Each change is kept only if the tests pass and the
     benchmark gains.
  2. Step 6, a skeptic agent that did not write the port, on the same
     branch: untested features, weak comparisons, narrow fuzzing, a
     benchmark that favours the port, undefined behaviour, overflow and
     stale references.
  3. Step 7, each confirmed finding fixed with a test that failed first;
     then the tests, `zig build sanitize` and the benchmark again, and the
     README's numbers updated.
- **Builds:** one at a time, under the memory cap, as
  `timeout 3000 systemd-run --user --scope -q -p MemoryMax=6G zig build <step> -j3`.
  The full test run peaks near 6 GB and takes about 6 minutes.
- **Resume the sanitizer run:** run it per test file
  (`zig build sanitize -Dtest-filter=<file prefix>`) so each stays under
  the 50-minute limit, or fork only for the calls the tests expect to be
  unsafe; then check every flagged call against `doc/parity.md`.
- **Sanitizer run:** `zig build sanitize` runs every test's calls to the
  original, each in a process of its own, through a build of it with
  AddressSanitizer and UndefinedBehaviorSanitizer (system clang), and lists
  the flagged calls in `zig-out/sanitize/report.txt`.
- **Branches:** the decoders were written on `port/png`, `port/jpeg`,
  `port/bmp-tga-psd-pnm` and `port/gif-hdr-pic` (local only, worktrees under
  `~/Projects/zig-stb-image.wt/`), all merged into `main`.

## Formats

| format | upstream | zig-stb-image | tests | state |
| --- | --- | --- | --- | --- |
| JPEG baseline | `stbi__jpeg_*` | `src/jpeg.zig` | `test/jpeg_test.zig`: the jpeg-decoder, libjpeg-turbo and image-rs corpora; "jpeg: every sampling factor combination the original accepts …", "jpeg: sizes that are not whole blocks or MCUs …", "jpeg: the frame types and table variants …", "jpeg: faults in the frame header … / tables … / scan headers fail as in the original", "jpeg: a JPEG cut short anywhere …", "jpeg: fuzzed baseline JPEGs load as in the original" | oracle-tested |
| JPEG progressive | as above | as above | as above, and "jpeg: fuzzed progressive JPEGs load as in the original" | oracle-tested |
| JPEG restart markers, DNL, Adobe and JFIF colour transforms, CMYK and YCCK | as above | as above | "jpeg: restart intervals and every restart marker …", "jpeg: a DNL segment …", "jpeg: every colour model decodes as in the original" | oracle-tested |
| JPEG IDCT of the SSE2 build | `stbi__idct_simd` | `-Djpeg-idct=sse2`, the default on x86-64 | the JPEG suite run with `-Djpeg-idct=sse2`; "jpeg: coefficients past 16 bits give the samples of the original build the port follows"; "the vector SSE2 IDCT gives the samples of the SSE2 IDCT computed lane by lane" (`src/jpeg.zig`) | oracle-tested |
| PNG 1, 2, 4, 8, 16 bits, every colour type, palettes, tRNS | `stbi__png_*` | `src/png.zig` | "png: the PngSuite's …" (primary, check, 16-bit, corrupt, unused), "png: image-rs's PNG images …", "png: libjpeg-turbo's PNG images …", "png: every colour type, bit depth, filter, interlacing and size …", "png: a tRNS colour key …", "png: damaged headers and chunks …", "png: every truncation …", "png: IDAT data in many chunks …", "png: more pixel data …", "png: the largest dimensions …", "png: a smaller dimension limit …", "png: palette indices past every PLTE …", "fuzz: mutated PNGs …", "png: each allocation failure …" | oracle-tested |
| PNG Adam7 interlace | as above | as above | as above | oracle-tested |
| PNG iPhone CgBI, BGR conversion and unpremultiply | `stbi__de_iphone` | as above | "png: the iPhone images …", "png: iPhone PNGs convert to RGB and unpremultiply …", "fuzz: mutated PNGs …" | oracle-tested |
| zlib (inflate) | `stbi__zbuf`, `stbi__parse_zlib` | `src/zlib.zig` | "zlib: every block type and block size …", "zlib: corrupt, truncated and odd streams …", "zlib: zero bits past the end …", "zlib: initial sizes of 0 and 1 …", "zlib: the IDAT streams of the PNG corpus …", "fuzz: mutated zlib and raw DEFLATE streams …", "zlib: each allocation failure …" | oracle-tested |
| TGA | `stbi__tga_*` | `src/tga.zig` | `test/tga_test.zig`: the TGA test suite, every image type, depth and origin, packets of every length, colour maps, headers, largest sizes, every cut, 3,000 fuzz cases, allocation failures | oracle-tested |
| BMP | `stbi__bmp_*` | `src/bmp.zig` | `test/bmp_test.zig`: bmpsuite and libjpeg-turbo files, every header size and depth, bit-field masks of every width, zero alpha, palette sizes, bad headers, largest sizes, every cut, 3,000 fuzz cases, allocation failures | oracle-tested |
| PSD (composited image, 8 and 16 bits, RLE and raw) | `stbi__psd_*` | `src/psd.zig` | `test/psd_test.zig`: the psd-tools PSD and PSB files, channel counts 0 to 56 at both depths and compressions, PackBits of every length byte, header fields, largest sizes, the 16-bit request and query, every cut, 3,000 fuzz cases, allocation failures | oracle-tested |
| GIF, first frame | `stbi__gif_load` | `src/gif.zig` | `test/gif_test.zig`: the corpus, every LZW code size and stream shape, full code tables, corrupt rasters, interlace, palettes and transparency, frames off the canvas, extensions, headers, truncation, limits, allocation failures, 2,000 fuzz cases | oracle-tested |
| GIF, every frame | `stbi_load_gif_from_memory` | `loadGifFromMemory` | as above, every test also as an animation: every disposal method, delays, frames kept after a failure; refusals in `doc/parity.md` | oracle-tested |
| HDR (Radiance RGBE, RLE and flat) | `stbi__hdr_*` | `src/hdr.zig` | `test/hdr_test.zig`: the corpus, RLE and flat sizes, the old RLE form, bad runs, every header form, long header lines, truncation, gammas and scales, limits, allocation failures, 2,000 fuzz cases | oracle-tested |
| PIC (Softimage) | `stbi__pic_*` | `src/pic.zig` | `test/pic_test.zig`: every packet type and channel layout, empty images, bad packets, overrunning and short scanlines, truncation, headers and info, limits, allocation failures, 3,000 fuzz cases | oracle-tested |
| PNM (binary PGM and PPM, 8 and 16 bits) | `stbi__pnm_*` | `src/pnm.zig` | `test/pnm_test.zig`: stb, libjpeg-turbo and image-rs files, every maximum value, whitespace and comments, numbers at the edge of an int, largest sizes, every cut, 3,000 fuzz cases, allocation failures | oracle-tested |

## Functions

| upstream | zig-stb-image | tests | state |
| --- | --- | --- | --- |
| `stbi_load_from_memory`, `stbi_load_16_from_memory`, `stbi_loadf_from_memory` | `loadFromMemory(u8 / u16 / f32, …)` | every corpus file and fuzz case | oracle-tested |
| `stbi_load_from_callbacks`, `stbi_load_16_from_callbacks`, `stbi_loadf_from_callbacks`, `stbi_io_callbacks` | `loadFromReader` on a `*std.Io.Reader` | corpus files; fuzz cases | oracle-tested |
| `stbi_load_from_file`, `stbi_load_from_file_16`, `stbi_loadf_from_file` | `loadFromFile` on a `*std.Io.File.Reader`, leaving it where the original leaves the `FILE` | corpus files; fuzz cases | oracle-tested |
| `stbi_load`, `stbi_load_16`, `stbi_loadf` | `loadFromPath` | | ported |
| `stbi_load_gif_from_memory` | `loadGifFromMemory` | `test/gif_test.zig` | oracle-tested |
| `stbi_info_from_memory`, `stbi_info_from_callbacks`, `stbi_info_from_file`, `stbi_info` | `infoFromMemory`, `infoFromReader`, `infoFromFile`, `infoFromPath` | corpus files; fuzz cases | oracle-tested |
| `stbi_is_16_bit_from_memory`, `…_from_callbacks`, `…_from_file`, `stbi_is_16_bit` | `is16BitFromMemory`, `…FromReader`, `…FromFile`, `…FromPath` | as above | oracle-tested |
| `stbi_is_hdr_from_memory`, `…_from_callbacks`, `…_from_file`, `stbi_is_hdr` | `isHdrFromMemory`, `…FromReader`, `…FromFile`, `…FromPath` | as above | oracle-tested |
| `desired_channels`, `*channels_in_file` | `Options.components`, `Image.channels` and `Image.channels_in_file` | every load compares all five | oracle-tested |
| `stbi_set_flip_vertically_on_load`, `…_thread` | `Options.flip_vertically`; `settings.setFlipVerticallyOnLoad`, `…Thread` | "settings: a thread's own flag wins there …", "settings: a load with a thread's own settings …" | oracle-tested |
| `stbi_set_unpremultiply_on_load`, `…_thread` | `Options.unpremultiply`; `settings.setUnpremultiplyOnLoad`, `…Thread` | "settings: a thread's own flag wins there …", "settings: a load with a thread's own settings …" | oracle-tested |
| `stbi_convert_iphone_png_to_rgb`, `…_thread` | `Options.convert_iphone_png`; `settings.convertIphonePngToRgb`, `…Thread` | "settings: a thread's own flag wins there …", "settings: a load with a thread's own settings …" | oracle-tested |
| `stbi_hdr_to_ldr_gamma`, `stbi_hdr_to_ldr_scale` | `Options.hdr_to_ldr_gamma`, `…_scale`; `settings.setHdrToLdrGamma`, `…Scale` | fuzz cases at random gammas and scales; "hdr: …" gamma and scale tests | oracle-tested |
| `stbi_ldr_to_hdr_gamma`, `stbi_ldr_to_hdr_scale` | `Options.ldr_to_hdr_gamma`, `…_scale`; `settings.setLdrToHdrGamma`, `…Scale` | as above | oracle-tested |
| `stbi_failure_reason` | the returned `Error`; `failureReason(err)` | every failing load compares it | oracle-tested |
| `stbi_image_free` | `Image.deinit`, `Animation.deinit` | every test runs on `std.testing.allocator` | oracle-tested |
| `stbi_zlib_decode_malloc_guesssize`, `…_malloc`, `…_malloc_guesssize_headerflag`, `…_buffer`, `…_noheader_malloc`, `…_noheader_buffer` | `zlib.decodeAlloc` (`initial_size`, `parse_header`), `zlib.decodeBuffer` (`parse_header`) | "zlib: every block type and block size … through all six functions" and the other zlib tests | oracle-tested |

## Build options

| upstream | zig-stb-image | state |
| --- | --- | --- |
| `STBI_NO_JPEG` … `STBI_NO_PNM`, `STBI_ONLY_JPEG` … `STBI_ONLY_PNM` | `-Djpeg=false` and so on: a format left out is never detected | ported |
| `STBI_MAX_DIMENSIONS` | `Options.limits.dimension_max` | ported |
| `STBI_FAILURE_USERMSG` | `failureMessage(err)` | ported |
| `STBI_NO_FAILURE_STRINGS` | none: the strings are compiled only where `failureReason` or `failureMessage` is called | left out (approved) |
| `STBI_NO_STDIO` | none: the file functions are compiled only where called | left out (approved) |
| `STBI_NO_LINEAR`, `STBI_NO_HDR`'s float half | none: the float functions are compiled only where called | left out (approved) |
| `STBI_SUPPORT_ZLIB`, `STBI_NO_ZLIB` | none: `zlib` is compiled only where used | left out (approved) |
| `STBI_MALLOC`, `STBI_REALLOC`, `STBI_REALLOC_SIZED`, `STBI_FREE` | the `std.mem.Allocator` each call takes | ported |
| `STBI_ASSERT` | Zig's safety checks | ported |
| `STBI_NO_SIMD`, `STBI_SSE2`, `STBI_NEON` | `-Djpeg-idct=sse2` (default on x86-64) or `scalar` (default elsewhere): the JPEG IDCT whose samples to give where the two differ (see "Left out") | left out (approved) |
| `STBI_NO_THREAD_LOCALS` | none: Zig has `threadlocal` on every target the port builds for | left out (approved) |
| `STBI_WINDOWS_UTF8`, `stbi_convert_wchar_to_utf8` | none: Zig paths are UTF-8 on Windows already | left out (approved) |
| `STB_IMAGE_STATIC`, `STBIDEF`, `STB_IMAGE_IMPLEMENTATION` | none: C linkage only | left out (approved) |

## Left out (approved)

Where the port departs from the original. `doc/parity.md` has the detail and
the tests of each case where the original is unsafe or never returns.

### Build switches

- `STBI_NO_FAILURE_STRINGS`, `STBI_NO_STDIO`, `STBI_NO_LINEAR`,
  `STBI_SUPPORT_ZLIB` and `STBI_NO_ZLIB`: no option. Zig compiles only the
  functions a program calls, so the failure strings, the file functions,
  the float conversions and `zlib` cost nothing when unused.
- `STBI_NO_SIMD`, `STBI_SSE2`, `STBI_NEON`: no option. The original's SSE2
  and scalar paths give the same pixels on every valid file, and the tests
  compare the port with both. They differ on JPEG coefficients past 16
  bits; `-Djpeg-idct=scalar|sse2` picks which the port follows (SSE2 by
  default on x86-64, as upstream builds there, scalar elsewhere). The NEON
  build is not followed.
- `STBI_NO_THREAD_LOCALS`: no option; Zig has `threadlocal` on every target
  the port builds for.
- `STBI_WINDOWS_UTF8` and `stbi_convert_wchar_to_utf8`: left out; Zig paths
  are UTF-8 on Windows already.
- `STB_IMAGE_STATIC`, `STBIDEF`, `STB_IMAGE_IMPLEMENTATION`: left out; they
  are C linkage only.

### zlib and PNG

- **Initial size 0:** the original's zlib decode loops for ever when
  `initial_size` is 0 and there is output; the port fails with `OutOfMemory`.
- **Palette indices past every PLTE entry:** the original reads
  uninitialized stack memory into the pixels; the port fails with the new
  `error.PngPaletteIndex` ("bad palette index", "Corrupt PNG"). The other
  choice would be to read unset entries as zero.
- **An empty IDAT before any data:** the original calls `memcpy` on a null
  pointer for 0 bytes (undefined in C, harmless in practice); the port gives
  the original's result, so nothing is refused.
- **Allocation:** the port allocates as data arrives rather than up front
  (the zlib output starts at the guessed size but no more than the input
  could fill, IDAT data is read in 1 MiB pieces, the final interlaced image
  only once every pass has decoded). On every input the result and reason
  are the original's; only where the original's large allocation would fail
  and the port's smaller ones succeed, or the reverse, can the two differ.
- **Dead checks:** the original's "bad bits_per_channel" and bad
  `req_comp` paths cannot be reached through the public API; the port has
  no such checks.
- **Not reached by tests:** a PNG whose IDAT data passes 2^31 bytes and a
  zlib output past 2^31 bytes need gigabytes of input; the port fails both
  as the original does (the first sets no new reason, the second sets "outofmem"),
  checked by reading only.

### JPEG

- Where the original reads sample or coefficient memory it never wrote
  (missing or truncated scans, segments after the frame header it fails to
  parse, restart intervals without their markers), the port refuses with
  `error.JpegMissingScanData`.
- Where the original's scalar IDCT overflows an `int` (undefined in C), the
  scalar port refuses with `error.JpegIdctOverflow`. The corpus file
  `imagetestsuite/b0b8914cc5f7a6eff409f16d8cc236c5.jpg` is one.
- The original's SSE2 and scalar builds give other samples on coefficients
  past 16 bits; `-Djpeg-idct` picks the one the port follows (SSE2 by
  default on x86-64, scalar elsewhere). The NEON build is not followed.
- The SSE2 build's IDCT is `@Vector` code computing what its intrinsics
  compute; its YCbCr conversion and 2x2 upsampling give the scalar ones'
  bytes, which the port's vector code also gives.
- Arithmetic-coded (SOF9 to SOF15), lossless (SOF3) and 12-bit JPEGs are
  refused as the original refuses them.

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

### BMP, TGA, PSD and PNM

Inputs the original is unsafe or undefined on, which the port refuses
(`doc/parity.md` has each, with its test):

- BMP: a pixel naming a palette entry past the palette, read by the
  original from uninitialized stack memory (`error.BmpPaletteIndex`). Every
  OS/2 BMP using one of its last four palette entries is such a file, as the
  original reads four entries fewer than an OS/2 palette holds: bmpsuite's
  `Core_1_Bit.bmp`, `Core_4_Bit.bmp`, `Core_8_Bit.bmp` and `pal8os2sp.bmp`,
  and `pal8badindex.bmp`.
- BMP: a stored height of -2^31, whose `abs()` is undefined
  (`error.DimensionTooLarge`, as the original reports in practice).
- TGA: a raw true-colour or grey image cut short, whose missing rows the
  original leaves uninitialized (`error.TgaTruncated`).
- PSD: a colour below its white matte, whose conversion to an integer is
  undefined (`error.PsdMatteOutOfRange`).

Not refusals: the PSD 16-bit query follows the original's GCC and Clang
builds, where `STBI_NOTUSED` skips the reads it wraps; BMP and PSD `info`
sizes are the original's `int` bits in a `u32`.
