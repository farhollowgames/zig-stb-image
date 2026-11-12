# Parity

The inputs on which the original reads or writes out of bounds, is
undefined, or never returns, and what the port does with them instead.
Everywhere else the port gives the original's result byte for byte. Each
case is awaiting the author's approval.

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
  `-Djpeg-idct=scalar` (the default) or `-Djpeg-idct=sse2`
  (`stbi.jpeg_idct`). The SSE2 port is defined on every input and never
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
