# Testing

The sections up to "In this repository" are the same in every Farhollow
Games port of a C or C++ library to Zig. The last section says how this
repository applies them.

## Oracle tests

The original is pinned to one upstream commit and kept in `reference/` (or
fetched as a lazy dependency), byte for byte as upstream has it. It is built
only for the tests and the benchmark, and is never part of the package.

An oracle test runs the original and the port on the same inputs and
compares the results. Where the original is exact, the test compares every
output byte and every returned value, not a summary such as a hash or one
field of the result. The inputs are:

- the original's own test data and demo assets, where it has them;
- hand-made edge cases: empty input, one element, the largest size, and
  degenerate cases;
- seeded random inputs (see Fuzzing).

`STATUS.md` lists every public function, option and mode of the original,
and names the tests that check each one. Code coverage is not the measure:
a feature counts as checked when a test compares it, not when a line is
reached.

## What "the same output" means

- Bytes and integers are equal.
- Floats are compared by their bit patterns, so `-0.0` differs from `0.0`,
  and a NaN matches only a NaN with the same bits.
- Where the original's output depends on how it is compiled (fused
  multiply-add, fast-math, signed overflow), the reference is built with
  flags that fix one result, and the port computes that result. The last
  section names the flags.
- Where a port deliberately computes differently from the original, a
  written design gives the units, scales, overflow bounds and tolerances.
  The port is then checked against an exact port within those tolerances,
  and against itself exactly.

## Fuzzing

Each fuzz test draws its inputs from a seeded generator and runs at least
1,000 cases. The seeds are recorded in the tests, so every run checks the
same inputs. A failure prints its seed, and the configuration where there is
one, so that it can be repeated. Where a repository has the option,
`zig build test -Dfuzz-seed=N` changes every fuzz test's seed, to explore
other inputs.

## Malformed input

Decoders and parsers are given truncated, corrupted and random bytes, and
must give the original's result: the same output, the same error, or the
same rejection. Where the port asserts a condition that the original
reports as an error code, or that the original does not check, `STATUS.md`
says so. Where a repository has contract tests, a program breaks one
contract per run, and the test expects the abort and its message in the safe
build modes.

## Determinism

The same inputs give the same output on every run. Where the library splits
work over threads, the tests compare the output on 1, 2 and more threads
with the output of one.

## Build modes

`zig build test` runs the tests in ReleaseSafe unless
`-Dtest-optimize=<mode>` says otherwise. ReleaseSafe keeps every assert and
integer overflow check on and runs the slow cases in reasonable time. The
last section says which modes have been run.

## Review

After a port passes its oracle tests, a separate AI agent profiles it
against the original and tunes the hot paths; each change is kept only if
the oracle tests still pass and the benchmark shows a gain. Another AI agent
then tries to break the claims: features left untested, comparisons that
check too little, fuzzing too narrow, benchmarks that favour the port,
undefined behaviour, integer overflow, and references that can outlive what
they point to. Each confirmed finding is fixed with a test that failed
before the fix. No person has yet reviewed the code or the tests.

## In this repository

### The original

`reference/stb_image.h` is stb_image 2.30 as stb commit
`a7d4c2175630e1ea5b6f8dd00ab96fed0b97b96d` has it. The tests build it twice
with the clang that Zig carries, at `-O3 -std=c99 -ffp-contract=off
-fno-fast-math -fno-sanitize=undefined`, through `test/shim/oracle.c`, a C
interface that sets the original's global and thread-local settings before
each call:

- once as upstream builds it for x86-64, with its SSE2 paths;
- once with `STBI_NO_SIMD` and `STBI_FAILURE_USERMSG`, which also gives each
  failure reason in its long form.

Every load is compared with both builds. Where the two builds give
different pixels (JPEG coefficients past 16 bits, where the SSE2 IDCT
saturates and the scalar one wraps), the port is compared with the build it
follows, the SSE2 one on x86-64 and the scalar one elsewhere unless
`-Djpeg-idct` says otherwise; the JPEG tests run in both modes. With fused multiply-adds off, float steps round as written, as
Zig's do. The original calls the C library's `pow`; the port carries
glibc 2.44's, which on this machine is the one the original calls
([`parity.md`](parity.md) has the detail).

### What a test compares

Each load compares, with both builds of the original: success or failure,
width, height, channels in the file and returned, every output byte (16-bit
samples by value, floats by their bits), the failure reason in its short and
long forms, and, for loads from a file, where the file is left afterwards.
`oracle.expectAllSame` runs a file through every combination the API has:
8-bit, 16-bit and float, each requested component count, flipped and not,
from memory, from a reader, from a file at an offset and by path (against
`stbi_load`, `stbi_load_16` and `stbi_loadf` on the same file), and through
a file reader that cannot seek, against the original's `FILE` (results
compared, not where the file is left), and the info, 16-bit and HDR queries through each of those five sources. A
query runs on both builds of the original and compares both reason forms.
Where the two builds disagree on an input that is not a JPEG, the test
fails instead of following one of them. GIFs are also loaded as
animations, comparing every frame and every delay.

### The inputs

- The test images of other decoders, fetched as lazy dependencies at
  pinned commits: stb's own tests (PngSuite and the iPhone PNGs),
  jpeg-decoder's test images (with an image test suite of damaged JPEGs),
  stb's and libjpeg-turbo's PGM and PPM files,
  image-rs's PNG, JPEG, BMP (bmpsuite), GIF, TGA, HDR and PNM tests,
  psd-tools' PSD and PSB files and libjpeg-turbo's test images.
- Hand-made files from small encoders in each test file: every PNG colour
  type, depth, filter and interlace; every BMP header size, depth and mask;
  every TGA type and RLE packet; PSD channel counts and PackBits runs; PNM
  maximum values and comment placements; every JPEG sampling combination,
  restart interval, DNL and frame type; GIF code sizes, disposals and
  interlace; HDR run forms; every PIC packet type. Each format also has
  1×1 images, the largest dimensions the limits allow, damaged headers, and
  every truncation.
- Seeded fuzzing (below).

### Fuzzing

| fuzz test | cases |
| --- | ---: |
| short random inputs, against every format | 1,000 |
| PNG | 3,000 |
| zlib and raw DEFLATE streams | 1,500 |
| baseline JPEG; progressive JPEG | 1,500 each |
| BMP; TGA; PSD; PNM; PIC | 3,000 each |
| GIF, first frame and every frame; HDR | 2,000 each |

Each case mutates one seed input (bit flips, bytes and integers set to edge
values, truncation, ranges deleted, repeated or inserted, runs of one
value), picks a random request (bit depth, components, flip, unpremultiply,
iPhone conversion, gamma and scale, source and file offset) and compares the
load and the queries with the original. Case `i` of a test takes its seed
from Wyhash of `i`, keyed by the test's recorded seed plus `N` from
`-Dfuzz-seed=N` (0 by default, which runs the recorded cases).
`-Dfuzz-replay=i` runs only case `i` of each fuzz test.

### Malformed input and the original's unsafe cases

`zig build sanitize` runs every test's calls to the original through a
build of it with AddressSanitizer and UndefinedBehaviorSanitizer (the
system clang), and for each call a sanitizer flags, runs the port on the
same input and request. Each call runs in a child process whose
sanitizers stop at the first report, so a report ends the child with a
non-zero status, an overrun cannot corrupt the calls after it, and a report
is never paired with another call (the child's error output comes back
through a pipe). One child runs the call through both builds of the
original; after a flag on the SIMD build, a new child runs the scalar one.
`zig-out/sanitize/<filters>/` gets `report.txt`, a line per flagged call
and build (the call, the build, the report's kind, access and first frame
in the original, and whether the port refuses or accepts), `accepted.txt`,
the flagged calls the port accepts, `counts.txt` and the full log.
`tools/sanitize-all.sh` runs it once per test file (`-Dtest-filter`), so
each build stays short and a stopped pass resumes where it was, and
`tools/sanitize-merge.sh` merges the runs into `zig-out/sanitize/`. The
port follows the SSE2 build's JPEG IDCT by default, so the scalar build's
IDCT overflows are flagged calls the port accepts; the JPEG file runs again
with `-Djpeg-idct=scalar` (`SANITIZE_ARGS=-Djpeg-idct=scalar`) to check the
scalar port's refusals. A child stops after 20 seconds (the original loops
for ever on a zlib initial size of 0), and a segmentation fault is
reported by Zig's handler, which the test runner installs over the
sanitizer's, as "died, signal 6: Segmentation fault at address …".

On 12 November 2026 the run made 418,326 calls (and the JPEG file's 48,941
again with the scalar IDCT) in about 20 minutes. 2,465 were flagged; the
port refuses all but 85 of them, and those 85 are the two cases
`parity.md` names: an empty IDAT chunk before the data (24 calls, a
`memcpy` of 0 bytes from a null pointer), and the scalar build's IDCT
overflows on the SSE2 port (61 calls; the scalar port refuses every one).
The sanitizers do not see reads of memory never written, on the stack or
the heap, so the PNG palette, BMP palette, TGA, HDR and JPEG-block cases
are not among the flagged calls; they rest on reading the C and, for
JPEG, on the three-fill check below.

Where the original reads out of bounds, reads memory it never wrote,
overflows an `int` or is otherwise undefined, the port returns an error of
its own, the same in every build mode; the one exception is a BMP palette
entry the original never read, which the port reads as zero.
[`parity.md`](parity.md) lists each case with its test. The tests check
each refusal on hand-made inputs, and the fuzz tests list the generated
cases the original is unsafe on (`test/*_unsafe.zig` and the lists in the
test files), where they expect the refusal and do not compare. Where the original's result depends on
memory it allocated but never wrote (a JPEG whose scans leave blocks
unwritten), the tests run it with fresh allocations filled with three
different bytes; if the results differ, the port must refuse. The BMP
inputs naming unset palette entries are compared by size and channels
(`oracle.Expect.same_size`, and the fuzz test's `unset_pixels` cases), and
their pixels against the files' own palettes. For the fuzz cases, a copy
of the input with every palette entry the original reads made white is
also loaded by both builds: each pixel from a read entry is compared with
them, and each from an unset entry must be zero.

### Settings and threads

stb_image has global settings and thread-local overrides (flip,
unpremultiply, iPhone conversion). The port has the same in
`stbi.settings`, and per call in `Options`. "settings: …" runs a scripted
sequence of global and thread-local changes on two threads at once, on the
port and the original, and compares the flags each thread sees; another
test sets the HDR gamma and scale, which are global only, and checks that
loads on other threads use them as the original's do. The decoders keep
no state between calls.

### Limits and format switches

`test/limits_test.zig` checks `Limits.bytes_max` on BMP, TGA, PSD and PNM:
an image at the limit loads, one byte past fails as the original fails
past `INT_MAX`, a conversion to more components is checked too, and a
PNG's inflated data grows past the limit as the original's grows past
`INT_MAX` (the limit bounds image buffers, not all memory).
`test/formats_test.zig` runs on two more builds of the port, one without
JPEG, BMP, GIF, PIC and PNM and one with only those: a file of a format
left out fails as an unknown image type, and the others load.

### Failed allocations

Each format has a test that fails each allocation of a decode in turn, with
`std.testing.checkAllAllocationFailures`, and checks that the decode returns
`error.OutOfMemory` and frees everything. Every test runs on
`std.testing.allocator`, which fails on leaks and double frees.

### pow

`test/pow_test.zig` compares the port's `pow` with the C library's on every
8-bit input at the default gamma and at 10,000 random gammas, on every
finite non-negative float at 1/2.2, on 10^7 random floats and 10^7 random
doubles, and on the special values. All match bit for bit.

### Build modes

The tests run in ReleaseSafe by default; `-Dtest-optimize` selects another
mode. The original is always built at `-O3`. On 12 November 2026 every test
passed on x86-64 Linux (glibc 2.44) in ReleaseSafe and in ReleaseFast:
182 tests in each (9 unit tests, 171 against the original, and one on each
of the two format-switch builds). The JPEG tests also passed with
`-Djpeg-idct=scalar`.
