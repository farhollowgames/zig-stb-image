# Where the port differs from the original

The port gives the original's result on every input the original handles
safely. Where the original reads out of bounds, reads uninitialized memory,
frees twice or is otherwise undefined, the port returns an error instead,
except for a BMP palette entry the original never read, which the port
reads as zero.
Each such case has a test, and the fuzz tests list the cases they generate
in their `.unsafe` lists (`test/<format>_unsafe.zig`). The author has
approved each case. `zig build sanitize` runs every test's calls to the
original under AddressSanitizer and UndefinedBehaviorSanitizer and checks
what the port does on each call they flag; the port refuses every one but
the two harmless cases below (the empty IDAT, and the scalar IDCT overflow
on the SSE2 port), see `TESTING.md`.

## zlib

- **An initial size of 0, with output to write.**
  `stbi_zlib_decode_malloc_guesssize` and
  `…_malloc_guesssize_headerflag` start their buffer at `initial_size`
  bytes and double it as output arrives. From 0 the doubling stays at 0,
  so the original loops for ever. The port fails with `OutOfMemory`
  ("outofmem"). With no output to write, both decode the empty result.
  Test: "zlib: initial sizes of 0 and 1 grow as in the original".

## PNG

- **A palette index past every PLTE entry.** The original keeps the
  palette in a 1024-byte stack array that only PLTE chunks write, and
  looks every index up in it, so an index past the entries any PLTE set
  reads uninitialized stack memory into the pixels. The port fails with
  the new `error.PngPaletteIndex` ("bad palette index", "Corrupt PNG").
  Entries set by an earlier, longer PLTE count as set, as they hold real
  values in the original too, and decode the same in both. The other
  possible choice is to read unset entries as zero (black, opaque or
  transparent by `tRNS`).
  Test: "png: palette indices past every PLTE are refused, where the
  original reads garbage".
- **An IDAT chunk of length 0 before any data.** The original grows its
  data buffer only for a non-zero length, then copies the chunk with
  `memcpy` from a null destination plus 0, for 0 bytes. That is undefined
  behavior in C, though no byte is read or written; UndefinedBehaviorSanitizer
  reports it. The port skips the chunk and gives the original's result:
  "no IDAT" when no data follows, and the image when a later IDAT holds it.
  Test: "png: damaged headers and chunks fail with the original's reasons"
  (damaged case 11, two empty IDATs, and the next case, an empty IDAT
  before the data), and "png: IDAT data in many chunks, among ancillary
  chunks, decodes as in the original".

## JPEG

- **Pixels from scans the file never had.** The original allocates each
  component's sample buffer (and, for progressive images, its coefficient
  buffer) without clearing it. When the file ends before every block of a
  component is decoded (a truncated file, missing scans, a DHT, DRI or other
  segment after the frame header that the original fails to parse and then
  treats as the end of the image, a restart interval whose markers are
  missing) it converts the blocks it never wrote, and the pixels come from
  whatever the allocator held. The port tracks which blocks each scan wrote,
  and refuses with `error.JpegMissingScanData` ("missing scan data") when
  the output needs a block no scan wrote; where the output does not use the
  component (grey output of a colour image) it decodes as the original.
  Tests: "jpeg: an image missing some components' scans loads only where they are
  not needed", "jpeg: a restart interval without its markers stops the scan, and
  the port refuses the rest", "jpeg: faults in the tables fail as in the
  original", "jpeg: a JPEG cut short anywhere in its segments or scans loads as in
  the original", the fuzz tests (every load there and in the corpus tests
  runs the original with fresh allocations filled with 0x00, 0xff and 0x5a,
  and wherever the results differ, the port must refuse). Where the
  original reads unwritten samples but its output happens not to change
  with them (a CMYK pixel whose K sample is 0 is black whatever C, M and Y
  hold), the port still refuses.
- **A refinement scan on blocks no first scan cleared.** A progressive AC
  refinement scan on a component whose first DC scan never ran reads the
  same unwritten coefficients; the port refuses with
  `error.JpegMissingScanData`. Tests: the progressive fuzz test.
- **Signed overflow in the scalar IDCT.** Coefficients of damaged files can
  overflow an `int` in `stbi__idct_block`, which is undefined behaviour in
  C. The scalar port computes the same sums, proves at compile time that a
  block whose coefficients are within ±23,911 (the row pass) and ±24,100
  (the column pass) cannot overflow, checks the rest in 64 bits, and refuses
  with `error.JpegIdctOverflow` ("IDCT overflow") where the original would
  overflow. Tests: "jpeg: coefficients that overflow the original's scalar IDCT
  are refused by the scalar port", and the corpus file
  `imagetestsuite/b0b8914cc5f7a6eff409f16d8cc236c5.jpg` in "jpeg: the jpeg-decoder
  test images decode as in the original".
- **The two builds of the original disagree.** The SSE2 IDCT
  (`stbi__idct_simd`) wraps sums of two coefficients to 16 bits and
  saturates between the passes, where the scalar one keeps them whole; on
  coefficients that need more than 16 bits the two builds give other
  samples. The port follows one of them, chosen at build time with
  `-Djpeg-idct=sse2` (the default on x86-64, as upstream builds there) or
  `-Djpeg-idct=scalar` (the default elsewhere) (`stbi.jpeg_idct`). The SSE2 port is defined on every input and never
  refuses. Where the builds disagree, the oracle holds the port to the
  build it follows. Tests: "jpeg: coefficients past 16 bits give the samples of
  the original build the port follows"; the whole JPEG suite runs in both
  modes. The YCbCr conversion and the 2x2 upsampler of the SSE2 build give
  the same bytes as the scalar ones on every input, so they need no option.
  The NEON IDCT is not followed.
- **A byte written past each pixel.** For three-component output the
  original's colour conversion writes a fourth byte (255) after each pixel.
  The next pixel overwrites it, and after the image's last pixel it lands in
  one spare byte the original allocates for it. The port writes only the
  pixel's bytes and allocates no spare byte; the output is the same.

## pow

What the original does: the HDR to 8-bit conversion and the 8-bit to float
conversion call the C library's `pow`, whose last bit differs between C
libraries and builds of them.

What the port does: `src/pow.zig` is glibc 2.44's x86-64 `pow`, with a fused
multiply-add wherever the system's build (for x86-64-v3) uses one, so it
gives that `pow`'s result bit for bit. The oracle keeps calling the system's
`pow`; on another C library, or a glibc built without FMA, the original's
float results can differ from the port's in the last bit.

Tests: `pow matches the C library on every 8-bit input at the default
gamma`, `… at 10,000 random gammas`, `… on every finite non-negative float at
1 / 2.2`, `… on 10^7 random floats at random gammas`, `… on 10^7 random
doubles`, `… on special values` (`test/pow_test.zig`).

## GIF

- **Restoring to the previous frame once two frames are out.** The original
  keeps the frame before last behind its output buffer, at
  `out - 2 * stride`, which points before the buffer; a frame with disposal
  method 3 copies from there at the start of the next frame. The port
  returns `error.GifDisposeToPrevious` for an animation where that copy would
  happen: disposal 3 on the second frame or a later one that drew pixels.
  The copy comes when the next frame is read, so the end of the file right
  after such a frame is refused too. Disposal 3 on the first frame, or on a
  frame that drew nothing, decodes as in the original. Tests: `a GIF that restores to the previous frame once two
  frames are out is refused`, `a GIF restoring to the previous frame after
  an empty frame decodes as in the original`; fuzz cases in
  `test/gif_unsafe.zig`.
- **An animation of no pixels with several frames.** The original grows its
  frame buffer with `realloc(p, 0)`, which frees it on glibc, and then frees
  it again. The port returns `error.GifZeroAreaFrames`. Test: `a GIF
  animation of no pixels and more than one frame is refused`.
- **Flipping an animation of fewer than 4 components.** The original flips
  each frame as 4 components wide whatever was asked for, past the end of
  its buffer. The port returns `error.GifFlipComponents` for a flipped
  animation of 1 to 3 components, at least 1 wide and 2 high. Test: `a
  flipped GIF animation of fewer than 4 components is refused`.
- **A first frame that fails, with 1 to 3 components asked for.** The
  original returns an empty, non-null buffer of 0 frames; the port returns
  the failure. The oracle reads both as a failure.
- **Rows past the 32-bit range.** The original's row position is an `int`
  that would overflow on a frame of about 2^31 rows; the port returns
  `error.TooLargeGif` there. There is no test: such a file needs gigabytes.
- **A failed flipped load.** The original flips with frame counts it never
  set; with the caller's values zeroed this flips nothing, and the port
  flips nothing on a failure.

## HDR

- **Flat pixels that end early.** The original converts a pixel it could not
  read from uninitialized stack memory. The port returns
  `error.HdrTruncated`. Tests: `an HDR file whose flat pixels end early is
  refused`; fuzz cases in `test/hdr_unsafe.zig`.
- **Info on a negative size.** The original's info reports the width and
  height the header gives, negative ones too. `Info` holds them unsigned, so
  the port's info refuses those files. Test: `every HDR header form is read
  as in the original`.

## PIC

- **A failure in the packets or the scanlines.** The original then converts
  its null image to the components asked for. That returns the failure only
  when the conversion keeps 4 components; otherwise it reads the null
  image, or, when no components were asked for and the packets were not
  read, uses the caller's `*comp` (an assert in a debug build). The port
  returns the failure for every request. Tests: `PIC loads refuse a
  scanline failure the original converts from a null image`, and every PIC
  test, which compares the loads of 4 components and expects the port to
  refuse the others; fuzz cases in `test/pic_unsafe.zig`.

## BMP

- **A pixel naming a palette entry past the palette.** The original keeps
  the palette in a 256-entry stack array and reads an entry it never filled,
  so the pixel gets whatever was on the stack. The port reads such an entry
  as zero: black, and opaque when four components are asked for, as every
  palette pixel is. Tests: "a pixel naming an entry past the palette reads
  as zero" and "bad compressions, planes, offsets and depths fail as in the
  original" check the port's zeros and compare its size and channels with
  the original's; the fuzz test's `bmp_unset_pixels` cases must decode to
  the original's size and channels, their pixels not compared.
- **OS/2 (12-byte header) palettes.** A special case of the above that real
  files hit: the original counts the OS/2 header as 24 bytes when it works
  out the palette size, so it reads four entries fewer than the file holds,
  and none at all from a 1-bit file. A pixel using one of the last four
  entries reads as zero in the port. In bmpsuite and image-rs these are
  `Core_1_Bit.bmp`, `Core_4_Bit.bmp`, `Core_8_Bit.bmp` and `pal8os2sp.bmp`;
  `pal8badindex.bmp` names an entry past an ordinary palette. Test: "the BMP
  test files naming unset palette entries read them as zero" reads each
  file's palette and indices itself and expects the original's entry for
  each index the original reads and zero for the others, and compares with
  both builds of the original every pixel whose entry the original reads;
  "every BMP test file decodes as in the original" compares their sizes and
  channels.
- **A height of -2^31.** The original takes `abs()` of the stored height,
  which is undefined for the most negative `int`. The port fails with
  `error.DimensionTooLarge`, which is what the original reports in practice.
  Test: "a height of -2^31 is refused, where the original's abs() is
  undefined".
- **`info` of a top-down BMP.** The original reports the stored height, a
  negative `int`. The port's `Info.height` is a `u32` holding the same 32
  bits. Not a refusal; the oracle compares the bits.

## TGA

- **A raw image cut short.** For uncompressed true-colour and grey images
  the original reads each row with one `getn`; when the input ends, the row,
  and every row after it, stays as `malloc` left it, uninitialized. The port
  fails with `error.TgaTruncated`. Run-length and colour-mapped images read
  zeros past the end, as the original does, and decode. Tests: "a TGA cut
  short anywhere decodes or fails as in the original, or is refused when raw
  rows are missing", "the largest sizes decode or fail as in the original".

## PSD

- **A colour below its white matte.** For a partly transparent pixel the
  original computes `colour / alpha + max * (1 - 1 / alpha)` in floats and
  converts it to an 8 or 16-bit integer. A colour darker than the matte gives
  a value outside the integer's range, and that conversion is undefined in C.
  The port fails with `error.PsdMatteOutOfRange`. None of the psd-tools files
  has such a pixel. Test: "a colour below its white matte is refused, where the
  original's conversion is undefined".
- **The 16-bit query.** `stbi__psd_is16` means to skip the height and width
  with `STBI_NOTUSED(stbi__get32be(s))`, but outside MSVC that macro is
  `(void)sizeof(v)`, which does not evaluate the reads; the depth it checks
  is the top half of the height. The port follows the GCC and Clang builds,
  which the oracle is: a 16-bit PSD whose height is below 2^20 is not
  16-bit to `is16BitFromMemory`, as there. Not a refusal. Test: "the 16-bit
  query reads the depth where the original's GCC and Clang builds read it".
- **`info` sizes past 2^31.** The original reports them as negative `int`s;
  the port's `u32` fields hold the same 32 bits. Not a refusal.

## PNM

No differences.
