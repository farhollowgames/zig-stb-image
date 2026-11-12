# Where the port differs from the original

The port gives the original's result on every input the original handles
safely. Where the original reads out of bounds, reads uninitialized memory,
frees twice or is otherwise undefined, the port returns an error instead.
Each such case has a test, and the fuzz tests list the cases they generate
in their `.unsafe` lists (`test/<format>_unsafe.zig`). Each case is awaiting
the author's approval.

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
  so the pixel gets whatever was on the stack. The port fails with
  `error.BmpPaletteIndex`. Tests: "a pixel naming an entry past the palette
  is refused, where the original reads stack memory", "the BMP test files the
  port refuses name entries past their palette".
- **OS/2 (12-byte header) palettes.** A special case of the above that real
  files hit: the original counts the OS/2 header as 24 bytes when it works
  out the palette size, so it reads four entries fewer than the file holds,
  and none at all from a 1-bit file. Any pixel using one of the last four
  entries is refused. In bmpsuite and image-rs this refuses `Core_1_Bit.bmp`,
  `Core_4_Bit.bmp`, `Core_8_Bit.bmp` and `pal8os2sp.bmp`; `pal8badindex.bmp`
  is refused for an index past an ordinary palette. Same tests.
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
