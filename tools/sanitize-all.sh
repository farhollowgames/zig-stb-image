#!/bin/sh
# Runs `zig build sanitize` once per test file, so each run stays under a
# build time limit, then merges the runs (tools/sanitize-merge.sh). Give
# filters as arguments to run only those (a run is skipped when its
# zig-out/sanitize/<filter>/counts.txt exists, so an interrupted pass
# resumes); set ZIG_BUILD to the command that runs `zig build` (default
# "zig build"), and SANITIZE_ARGS to more build options (such as
# -Djpeg-idct=scalar).
set -u
cd "$(dirname "$0")/.."
build=${ZIG_BUILD:-zig build}
args=${SANITIZE_ARGS:-}
suffix=
case "$args" in *jpeg-idct=scalar*) suffix=+jpeg-idct-scalar ;; esac
if [ $# -eq 0 ]; then
  set -- core_test. zlib_test. png_test. settings_test. hdr_test. gif_test. pic_test. \
    bmp_test. tga_test. psd_test. pnm_test. jpeg_test.
fi
for filter in "$@"; do
  name=$(printf '%s' "$filter" | sed 's/[^A-Za-z0-9._+-]/-/g')$suffix
  if [ -e "zig-out/sanitize/$name/counts.txt" ]; then
    echo "sanitize-all: $filter done before"
    continue
  fi
  echo "sanitize-all: $filter"
  $build sanitize "-Dtest-filter=$filter" $args || echo "sanitize-all: $filter failed"
done
sh tools/sanitize-merge.sh zig-out/sanitize
