# Where the port differs from the original

The port gives the original's result on every input, except where the
original reads or writes out of bounds, reads memory it never wrote, or
does something C leaves undefined. There the port refuses the input with
an error, and a test shows it. Each case is awaiting the author's approval.

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
