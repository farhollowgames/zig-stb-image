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
