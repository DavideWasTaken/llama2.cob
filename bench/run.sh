#!/usr/bin/env bash
# Benchmark dell'aritmetica di GnuCOBOL: compila, esegue, mostra il C
# generato per le varianti principali e la prova di overflow.
set -e
cd "$(dirname "$0")/.."
mkdir -p build/bench

echo "== ambiente"
cobc --version | head -1
gcc --version | head -1
grep -m1 "model name" /proc/cpuinfo | sed 's/.*: //'
echo

for flags in "" "-fno-trunc"; do
  echo "== cobc -x -O2 $flags"
  cobc -x -O2 $flags -o build/bench/arith bench/arith.cob 2>&1 | grep -v -e FORTIFY -e "previous def" || true
  ./build/bench/arith
  echo
done

echo "== CBL_READ_FILE secondo il filesystem"
head -c 4096 /dev/urandom > /tmp/arith_bench.bin
cp /tmp/arith_bench.bin build/bench/arith_bench.bin
echo "-- /tmp ($(df -T /tmp | awk 'NR==2 {print $2}'))"
./build/bench/arith /tmp/arith_bench.bin B | grep CBL_READ_FILE
echo "-- cartella del progetto ($(df -T . | awk 'NR==2 {print $2}'))"
./build/bench/arith build/bench/arith_bench.bin B | grep CBL_READ_FILE
rm -f /tmp/arith_bench.bin build/bench/arith_bench.bin
echo

echo "== C generato da cobc -C -O2 (istruzioni del ciclo interno)"
cobc -C -O2 -o build/bench/arith.c bench/arith.cob
for p in PASS-2 PASS-5 PASS-6; do
  echo "-- $p: $(grep -A1 "^$p\." bench/arith.cob | tail -1 | sed 's/.*"\(.*\)".*/\1/' | tr -s ' ')"
  awk "/Paragraph $p /{f=1;next} /Paragraph /{f=0} f" build/bench/arith.c \
    | awk '/for \(/{f=1;next} f && /^    }/{exit} f' \
    | grep -v -e "Line:" -e "^\s*$" -e "^\s*[{}]\s*$" | sed 's/^ *//'
done
echo

echo "== overflow"
cobc -x -O2 -o build/bench/overflow bench/overflow.cob 2>&1 | grep -v -e FORTIFY -e "previous def" || true
./build/bench/overflow || echo "   il programma e' terminato con codice $? (divisione per zero in C)"
