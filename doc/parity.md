# Parity with stb_image

Where the port gives other results than stb_image 2.30, and why. On every
other input it gives the same result: success or failure, size, channel
count, every output byte and the failure reason, as the oracle tests check.
The port differs only where the original reads memory it never wrote, reads
or writes out of bounds, or is undefined; there the port returns an error.
Each case below is awaiting the author's approval.

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
  Tests: "an image missing some components' scans loads only where they are
  not needed", "a restart interval without its markers stops the scan, and
  the port refuses the rest", "faults in the tables fail as in the
  original", "a JPEG cut short anywhere in its segments or scans loads as in
  the original", the fuzz tests (every load there and in the corpus tests
  runs the original with fresh allocations filled with 0x00 and with 0xff,
  and wherever the results differ, the port must refuse).
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
  overflow. Tests: "coefficients that overflow the original's scalar IDCT
  are refused by the scalar port", and the corpus file
  `imagetestsuite/b0b8914cc5f7a6eff409f16d8cc236c5.jpg` in "the jpeg-decoder
  test images decode as in the original".
- **The two builds of the original disagree.** The SSE2 IDCT
  (`stbi__idct_simd`) wraps sums of two coefficients to 16 bits and
  saturates between the passes, where the scalar one keeps them whole; on
  coefficients that need more than 16 bits the two builds give other
  samples. The port follows one of them, chosen at build time with
  `-Djpeg-idct=scalar` (the default) or `-Djpeg-idct=sse2`
  (`stbi.jpeg_idct`). The SSE2 port is defined on every input and never
  refuses. Where the builds disagree, the oracle holds the port to the
  build it follows. Tests: "coefficients past 16 bits give the samples of
  the original build the port follows"; the whole JPEG suite runs in both
  modes. The YCbCr conversion and the 2x2 upsampler of the SSE2 build give
  the same bytes as the scalar ones on every input, so they need no option.
  The NEON IDCT is not followed.
- **A byte written past each pixel.** For three-component output the
  original's colour conversion writes a fourth byte (255) after each pixel.
  The next pixel overwrites it, and after the image's last pixel it lands in
  one spare byte the original allocates for it. The port writes only the
  pixel's bytes and allocates no spare byte; the output is the same.
