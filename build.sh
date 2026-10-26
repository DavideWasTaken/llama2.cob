#!/usr/bin/env bash
# Builds llama2.cob with GnuCOBOL.
# -fno-trunc: binary integers use their full width instead of being
# truncated to their PICTURE digits (needed by the 64-bit accumulators).
set -e
cd "$(dirname "$0")"
mkdir -p build
rm -f build/llama2
cobc -x -O2 -fno-trunc -o build/llama2 src/llama2.cob 2>&1 \
  | grep -v -e "_FORTIFY_SOURCE" -e "previous definition" || true
test -x build/llama2
