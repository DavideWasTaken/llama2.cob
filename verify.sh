#!/usr/bin/env bash
# Verifica che llama2.cob generi esattamente lo stesso testo di run.c
# (karpathy/llama2.c) in modalita' greedy, e confronta le velocita'.
set -e
cd "$(dirname "$0")"
mkdir -p build out
bash build.sh
gcc -O3 -o build/run ref/run.c -lm 2>/dev/null
gcc -Ofast -march=native -o build/runfast ref/run.c -lm 2>/dev/null

speed() {  # migliore di 3 esecuzioni, in token/s
  local best=0 r
  for _ in 1 2 3; do
    r=$("$@" 2>&1 >/dev/null | grep -o '[0-9.]*$')
    best=$(awk -v a="$best" -v b="$r" 'BEGIN { print (b > a) ? b : a }')
  done
  echo "$best"
}

check() {  # $1 = checkpoint, $2 = tokenizer
  [ -f "model/$1" ] || { echo "manca model/$1, salto"; return; }
  local args=(model/$1 -z model/$2 -t 0 -n 256 -i "Once upon a time")
  echo "== $1"
  ./build/run "${args[@]}" > out/ref.txt 2>/dev/null
  ./build/llama2 "${args[@]}" > out/cob.txt 2>/dev/null
  if cmp -s out/ref.txt out/cob.txt; then
    echo "   output: IDENTICO a run.c"
  else
    echo "   output: DIVERSO da run.c"
  fi
  printf "   %-28s %10s tok/s\n" "C (gcc -O3)"                 "$(speed ./build/run "${args[@]}")"
  printf "   %-28s %10s tok/s\n" "C (gcc -Ofast -march=native)" "$(speed ./build/runfast "${args[@]}")"
  printf "   %-28s %10s tok/s\n" "COBOL (GnuCOBOL -O2)"         "$(speed ./build/llama2 "${args[@]}")"
}

check stories260K.bin tok512.bin
check stories15M.bin tokenizer.bin
