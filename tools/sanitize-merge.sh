#!/bin/sh
# Merges the sanitizer runs under $1 (zig-out/sanitize/<filter>/) into $1:
# report.txt and accepted.txt, and counts.txt with a line of counts per run
# and their sums.
set -u
dir="$1"
: > "$dir/report.txt"
: > "$dir/accepted.txt"
printf '%-32s %8s %8s %8s %8s %8s\n' run calls flagged refuses accepts parent > "$dir/counts.txt"
for run in "$dir"/*/; do
  [ -e "$run/counts.txt" ] || continue
  cat "$run/report.txt" >> "$dir/report.txt"
  cat "$run/accepted.txt" >> "$dir/accepted.txt"
  awk -v run="$(basename "$run")" '
    /^calls / { c = $2 } /^flagged / { f = $2 } /^port refuses / { r = $3 }
    /^port accepts / { a = $3 } /^parent reports / { p = $3 }
    END { printf "%-32s %8d %8d %8d %8d %8d\n", run, c, f, r, a, p }
  ' "$run/counts.txt" >> "$dir/counts.txt"
done
awk 'NR > 1 { for (i = 2; i <= 6; i++) sum[i] += $i }
  END { printf "%-32s %8d %8d %8d %8d %8d\n", "total", sum[2], sum[3], sum[4], sum[5], sum[6] }
' "$dir/counts.txt" >> "$dir/counts.txt"
cat "$dir/counts.txt"
