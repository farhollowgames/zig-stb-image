#!/bin/sh
# Runs the sanitize test binary ($1), whose sanitizer build of the original
# is $2, with the ASan runtime preloaded, and writes into $3:
#   log.txt       everything the run printed;
#   report.txt    each flagged call and build: the call, the build, the
#                 sanitizer's report (frames symbolized) and what the port
#                 does;
#   accepted.txt  the lines of report.txt where the port does not refuse;
#   parent.txt    sanitizer reports from outside the child processes (none
#                 is expected: the parent never calls the original);
#   counts.txt    the counts.
set -u
test_binary="$1"
library="$2"
out="$3"
mkdir -p "$out"
runtime=$(clang -print-file-name=libclang_rt.asan-x86_64.so)
# Each child makes one call and stops at its first report, which then ends
# it with status 1. Frames stay unsymbolized (symbolizing in every child is
# slow); the offsets in the original's library are symbolized below.
ASAN_OPTIONS=halt_on_error=1:abort_on_error=0:exitcode=1:detect_leaks=0:symbolize=0:print_summary=0:allocator_may_return_null=1 \
UBSAN_OPTIONS=halt_on_error=1:abort_on_error=0:exitcode=1:print_stacktrace=1:symbolize=0:print_summary=0 \
LD_PRELOAD="$runtime" "$test_binary" >"$out/log.txt" 2>&1
status=$?

grep '^stbi-flagged: ' "$out/log.txt" | sed 's/^stbi-flagged: //' > "$out/flagged.raw"
# "libstb_image_sanitize.so+0x1234" becomes the function and source line.
grep -o 'libstb_image_sanitize\.so+0x[0-9a-f]*' "$out/flagged.raw" | sort -u > "$out/frames.raw"
: > "$out/frames.map"
if [ -s "$out/frames.raw" ]; then
  sed 's/.*+//' "$out/frames.raw" |
    llvm-symbolizer --obj="$library" --output-style=GNU --no-inlines --basenames |
    paste -d '\t' - - | paste -d '\t' "$out/frames.raw" - > "$out/frames.map"
fi
awk -F '\t' '
  FILENAME == ARGV[1] { name[$1] = $2 " " $3; next }
  {
    if (match($0, /libstb_image_sanitize\.so\+0x[0-9a-f]+/)) {
      key = substr($0, RSTART, RLENGTH)
      if (key in name) $0 = substr($0, 1, RSTART - 1) name[key] substr($0, RSTART + RLENGTH)
    }
    print
  }
' "$out/frames.map" "$out/flagged.raw" > "$out/report.txt"
rm -f "$out/flagged.raw" "$out/frames.raw" "$out/frames.map"
grep -v '| port refuses ' "$out/report.txt" > "$out/accepted.txt"
grep -v '^stbi-\|^    #' "$out/log.txt" |
  grep 'ERROR: AddressSanitizer\|runtime error:\|AddressSanitizer: CHECK' > "$out/parent.txt"

calls=$(grep -c '^stbi-call: ' "$out/log.txt")
# A call flagged on both builds has a line for each; it is counted once.
calls_of() { sed 's/ | .*//' "$1" | sort -u | wc -l; }
flagged=$(calls_of "$out/report.txt")
refused=$(grep '| port refuses ' "$out/report.txt" > "$out/refused.tmp"; calls_of "$out/refused.tmp")
rm -f "$out/refused.tmp"
accepted=$(calls_of "$out/accepted.txt")
parent=$(wc -l < "$out/parent.txt")
cat > "$out/counts.txt" <<COUNTS
test binary exit $status
calls $calls
flagged $flagged
port refuses $refused
port accepts $accepted
parent reports $parent
COUNTS
echo "sanitize: $(tr '\n' ';' < "$out/counts.txt") in $out"
