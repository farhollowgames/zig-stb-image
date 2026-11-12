#!/bin/sh
# Runs the sanitize test binary ($1) with the ASan runtime preloaded, and
# writes into $2 the full log and report.txt: each call a sanitizer flagged,
# as the "stbi-case:" line the harness printed before it, then the
# sanitizer's first line about it.
set -u
test_binary="$1"
out="$2"
mkdir -p "$out"
runtime=$(clang -print-file-name=libclang_rt.asan-x86_64.so)
ASAN_OPTIONS=halt_on_error=0:detect_leaks=0:abort_on_error=0:print_summary=1:allocator_may_return_null=1:suppress_equal_pcs=0 \
UBSAN_OPTIONS=halt_on_error=0:print_stacktrace=1 \
LD_PRELOAD="$runtime" "$test_binary" >"$out/log.txt" 2>&1
status=$?
awk '
  /^stbi-case: / { label = $0; reported = 0; next }
  /ERROR: AddressSanitizer|AddressSanitizer: CHECK failed|runtime error:|^stbi-crash: / {
    if (!reported) { print label; reported = 1 }
    print "    " $0
  }
' "$out/log.txt" > "$out/report.txt"
echo "sanitize: test binary exit $status; $(grep -c '^stbi-case' "$out/report.txt") flagged calls in $out/report.txt"
