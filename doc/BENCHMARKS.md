# Benchmarks

These are measurements on one machine, under the conditions below. They
are not a verdict on either side.

`zig build bench` decodes the same inputs with the port and the original,
one feature per row, on one thread, and prints the table below:

```sh
zig build bench [-- --samples 11 --rounds 1 --filter <text>]
```

Each sample times enough decodes to last at least 50 ms of the benchmark
thread's CPU time; two warm-up samples come first, and a row reports the
median of 11 samples, with the range (slowest minus fastest, over the
median). The sides take turns sample by sample, the first side rotating, so
both see the same load. `--rounds N` runs the whole table N times and keeps
each side's best median. Every decode's output is kept behind a compiler
barrier, and the two sides' outputs are compared: a row whose bytes differ
says so. None did.

## Inputs

One photograph, jpeg-decoder's `tests/reftest/images/mjpeg.png` (960 x
720, RGB), decoded once and written at start-up:

- by stb_image_write (stb at the pinned commit): PNG RGB, RGBA and grey,
  JPEG at quality 95 (4:4:4) and 85 (4:2:0) and grey at 90, BMP 24 and 32
  bits, TGA raw and RLE, and HDR of the photo's squared values;
- by small writers in `bench/bench.zig`: 16-bit, Adam7 and 8-bit paletted
  PNGs (std's deflate, filters 0 to 4 in turn), PSD raw and PackBits with
  alpha blended over white as Photoshop stores it, PNM 8 and 16 bits, and a
  zlib stream of the RGB pixels;
- from the test corpora: jpeg-decoder's `progressive3.jpg` and
  `ycck.jpg`, and image-rs's `large-gif-anim-combine.gif`.

RGBA and 16-bit inputs carry made-up alpha and low bits, so no channel is
constant.

## Machine and flags

Measured on 12 November 2026, at commit `ac97ea4`, with `--rounds 3`, on
an AMD Ryzen 9 9950X3D (16 cores, 32 threads) under Linux 7.3.3 (CachyOS).
Other builds were running: the one-minute load average was between 6 and
20 during the run. Thread CPU time leaves out time spent
waiting, but other threads on the same core still slow a sample; the
ranges show how much.

- **The port:** Zig 0.17.0, ReleaseFast, for the machine's own CPU
  (`znver5`), allocating with the C allocator.
- **The original:** stb_image 2.30 (`a7d4c21`), built by the clang that
  Zig 0.17.0 carries (22.1.8), for the same CPU, at `-O3 -std=c99
  -ffp-contract=off -fno-fast-math -fno-sanitize=undefined`, linked
  statically. "original" is the build with its SSE2 paths, as upstream
  builds for x86-64; "original, no SIMD" adds `STBI_NO_SIMD` and is timed
  for the JPEG rows only, where the SIMD code is.
- **Both:** no fused multiply-adds, which the tests need for equal float
  outputs; `malloc` and `free` from glibc 2.44.

## Results

Mpix/s of output (MB/s for zlib); "time, port / original" is the port's
median time over the original's, so below 1 is faster.

| feature | port | range | original | range | time, port / original | original, no SIMD | time, port / no SIMD |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| png rgb | 115.0 | 0.4% | 89.6 | 0.2% | 0.78 | | |
| png rgba | 99.9 | 0.6% | 80.0 | 2.9% | 0.80 | | |
| png grey | 261.7 | 0.5% | 184.5 | 0.4% | 0.71 | | |
| png rgb 16-bit | 64.7 | 2.8% | 54.6 | 1.0% | 0.84 | | |
| png rgb adam7 | 104.7 | 0.2% | 83.6 | 1.5% | 0.80 | | |
| png palette | 533.4 | 0.4% | 329.3 | 0.6% | 0.62 | | |
| png rgb to rgba | 109.7 | 0.5% | 89.5 | 1.2% | 0.82 | | |
| png rgb to float | 36.9 | 0.1% | 33.5 | 0.2% | 0.91 | | |
| jpeg 4:4:4 | 299.7 | 0.6% | 208.8 | 0.4% | 0.70 | 125.2 | 0.42 |
| jpeg 4:2:0 | 598.4 | 0.4% | 310.4 | 0.3% | 0.52 | 206.7 | 0.35 |
| jpeg 4:2:0 to rgba | 586.3 | 0.3% | 563.6 | 0.6% | 0.96 | 206.7 | 0.35 |
| jpeg grey | 621.0 | 0.5% | 321.1 | 0.4% | 0.52 | 210.9 | 0.34 |
| jpeg progressive | 114.1 | 1.7% | 110.3 | 1.1% | 0.97 | 76.0 | 0.67 |
| jpeg ycck | 137.2 | 1.4% | 101.0 | 1.7% | 0.74 | 66.6 | 0.49 |
| bmp 24-bit | 23205.9 | 2.8% | 1008.8 | 9.1% | 0.04 | | |
| bmp 32-bit | 18590.6 | 2.4% | 856.8 | 4.1% | 0.05 | | |
| bmp 24-bit to rgba | 7107.1 | 0.2% | 922.2 | 3.1% | 0.13 | | |
| tga raw | 15792.3 | 0.7% | 4489.9 | 0.6% | 0.28 | | |
| tga rle | 400.1 | 4.6% | 301.8 | 7.4% | 0.75 | | |
| tga raw to rgba | 5746.3 | 0.3% | 3598.8 | 0.3% | 0.63 | | |
| tga raw to grey | 6961.2 | 2.3% | 3616.1 | 0.7% | 0.52 | | |
| psd raw | 611.6 | 1.0% | 391.8 | 3.0% | 0.64 | | |
| psd rle | 454.0 | 0.5% | 396.3 | 17.2% | 0.87 | | |
| psd raw to rgb | 593.8 | 0.7% | 387.0 | 2.2% | 0.65 | | |
| hdr float | 226.2 | 7.8% | 178.5 | 6.5% | 0.79 | | |
| hdr to 8-bit | 43.1 | 1.0% | 41.2 | 1.1% | 0.95 | | |
| pnm 8-bit | 23728.8 | 1.5% | 23575.6 | 2.0% | 0.99 | | |
| pnm 16-bit | 13259.5 | 5.6% | 13181.7 | 4.6% | 0.99 | | |
| gif first frame | 416.0 | 4.6% | 331.9 | 13.1% | 0.80 | | |
| gif every frame | 510.2 | 15.0% | 399.8 | 11.0% | 0.78 | | |
| zlib inflate | 370.7 | 2.9% | 304.0 | 3.1% | 0.82 | | |
| png rgb via reader | 110.5 | 3.0% | 85.7 | 3.6% | 0.78 | | |
| png rgb via file | 112.3 | 0.7% | 87.7 | 0.2% | 0.78 | | |
| jpeg 4:2:0 via reader | 581.7 | 4.4% | 307.6 | 5.6% | 0.53 | | |
| jpeg 4:2:0 via file | 582.2 | 0.4% | 308.2 | 0.2% | 0.53 | | |
| bmp 24-bit via reader | 4869.9 | 0.3% | 762.3 | 0.6% | 0.16 | | |
| bmp 24-bit via file | 2668.0 | 2.8% | 688.5 | 1.0% | 0.26 | | |
| psd raw via reader | 438.2 | 0.7% | 370.8 | 2.5% | 0.85 | | |
| psd raw via file | 395.6 | 0.5% | 350.3 | 2.1% | 0.89 | | |
| psd rle via reader | 394.6 | 0.4% | 338.4 | 4.2% | 0.86 | | |
| psd rle via file | 367.0 | 0.9% | 309.9 | 2.0% | 0.84 | | |

## Known biases and slower rows

- **JPEG.** Much of the port's lead on RGB output is the original's
  scalar conversion to three channels, which its SSE2 code leaves out; to
  RGBA, which the SSE2 code converts, the two are close (0.96).
  Progressive JPEG (0.97) is the closest row: its decoding is the port's
  scalar Huffman code against the original's.
- **Memory, reader and file loads.** The rows above, and every row whose
  name does not say otherwise, load from memory. The rows named "via
  reader" load through a `std.Io.Reader` over the bytes, against the
  original's callbacks over the same bytes; those named "via file" load
  from an in-memory file, against the original's `FILE` on the same
  descriptor (the original also opens and closes a `FILE` for each
  decode, a few microseconds). Both sides then read through a 128-byte
  buffer, so the port's fast paths that take a whole row from memory do
  not apply; it copies rows and planes from that buffer in pieces, as
  the original reads them byte by byte.
- **Allocation.** The port's zlib output is shrunk to its length at the
  end (`realloc`), and PNG reads IDAT data in 1 MiB pieces; the original
  does neither.
- **One machine, one input size.** Other images, sizes and CPUs give other
  ratios; small images weigh the fixed costs more.
- **Load.** The machine was busy with other work during this run.
