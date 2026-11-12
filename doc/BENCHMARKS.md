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

Measured on 11 November 2026, at commit `8e1f84e` plus the PSD input
fix of the next commit, on an AMD Ryzen 9 9950X3D (16 cores, 32 threads)
under Linux 7.3.3 (CachyOS). Other builds were running: the one-minute load
average was about 15 during the run. Thread CPU time leaves out time spent
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
| png rgb | 72.8 | 7.3% | 80.0 | 8.2% | 1.10 | | |
| png rgba | 64.9 | 8.9% | 66.6 | 7.6% | 1.03 | | |
| png grey | 158.4 | 3.6% | 165.1 | 2.3% | 1.04 | | |
| png rgb 16-bit | 41.1 | 6.8% | 46.5 | 3.6% | 1.13 | | |
| png rgb adam7 | 70.4 | 7.0% | 75.7 | 9.3% | 1.08 | | |
| png palette | 253.1 | 5.3% | 302.9 | 1.8% | 1.20 | | |
| png rgb to rgba | 76.2 | 5.3% | 82.8 | 5.5% | 1.09 | | |
| png rgb to float | 30.6 | 2.4% | 30.6 | 3.3% | 1.00 | | |
| jpeg 4:4:4 | 124.6 | 3.1% | 189.1 | 3.0% | 1.52 | 113.5 | 0.91 |
| jpeg 4:2:0 | 189.6 | 1.9% | 288.5 | 2.1% | 1.52 | 191.1 | 1.01 |
| jpeg 4:2:0 to rgba | 186.3 | 2.4% | 517.8 | 2.5% | 2.78 | 188.3 | 1.01 |
| jpeg grey | 198.0 | 1.5% | 298.3 | 0.9% | 1.51 | 195.4 | 0.99 |
| jpeg progressive | 73.9 | 6.2% | 100.9 | 2.5% | 1.37 | 71.2 | 0.96 |
| jpeg ycck | 63.7 | 3.0% | 94.2 | 3.5% | 1.48 | 61.8 | 0.97 |
| bmp 24-bit | 510.5 | 1.2% | 994.6 | 12.7% | 1.95 | | |
| bmp 32-bit | 397.5 | 7.7% | 818.2 | 4.7% | 2.06 | | |
| tga raw | 4062.1 | 4.7% | 4189.3 | 3.5% | 1.03 | | |
| tga rle | 317.0 | 3.7% | 296.8 | 8.4% | 0.94 | | |
| psd raw | 260.0 | 8.0% | 374.1 | 4.8% | 1.44 | | |
| psd rle | 249.3 | 6.7% | 379.1 | 5.8% | 1.52 | | |
| hdr float | 193.4 | 5.4% | 171.7 | 6.5% | 0.89 | | |
| hdr to 8-bit | 39.4 | 4.5% | 39.2 | 6.1% | 0.99 | | |
| pnm 8-bit | 22517.9 | 7.7% | 22367.9 | 12.5% | 0.99 | | |
| pnm 16-bit | 11174.3 | 26.6% | 11157.3 | 11.7% | 1.00 | | |
| gif first frame | 390.5 | 19.5% | 294.1 | 25.7% | 0.75 | | |
| gif every frame | 432.7 | 40.6% | 360.7 | 17.3% | 0.83 | | |
| zlib inflate | 264.8 | 9.5% | 288.2 | 6.1% | 1.09 | | |

## Known biases and slower rows

- **JPEG.** The port does not have the original's SSE2 code yet: its IDCT,
  YCbCr conversion and 2x2 upsampling are scalar, and Zig 0.17 does not
  vectorize loops by itself. Against the original without SIMD the port is
  within a few percent; against the SSE2 build it is about 1.5 times slower,
  and 2.8 times on RGBA output, where the original converts YCbCr straight
  to four channels with SSE2.
- **BMP and PSD.** The original's per-pixel loops compile to vector code at
  -O3; the port's do not yet.
- **PNG palette.** The palette expansion is scalar in the port.
- **Allocation.** The port's zlib output is shrunk to its length at the
  end (`realloc`), and PNG reads IDAT data in 1 MiB pieces; the original
  does neither.
- **One machine, one input size.** Other images, sizes and CPUs give other
  ratios; small images weigh the fixed costs more.
- **Load.** The machine was busy with other work during this run.
