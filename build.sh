#!/usr/bin/env bash
# Compila llama2.cob con GnuCOBOL.
# -fno-trunc: gli interi binari usano tutta la loro larghezza (necessario
# per gli accumulatori a 64 bit e per la velocita' dell'aritmetica intera).
set -e
cd "$(dirname "$0")"
mkdir -p build
rm -f build/llama2
cobc -x -O2 -fno-trunc -o build/llama2 src/llama2.cob 2>&1 \
  | grep -v -e "_FORTIFY_SOURCE" -e "previous definition" || true
test -x build/llama2
