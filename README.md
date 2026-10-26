# llama2.cob

**English** | [Italiano](README.it.md)

**What we learned about GnuCOBOL arithmetic by running an LLM in COBOL.**

This project started as an experiment: port Andrej Karpathy's [llama2.c](https://github.com/karpathy/llama2.c) to COBOL. The first version worked, but ran at 1.2 tokens per second. To find out why, we read the C code that GnuCOBOL generates, and found something that applies to any GnuCOBOL program, not just this one:

> **In GnuCOBOL 3.2 every `COMPUTE`, `MULTIPLY` and `DIVIDE` goes through arbitrary-precision decimal arithmetic (GMP), even between binary `COMP-5` fields, which is the form the documentation recommends for speed. Only `ADD` and `SUBTRACT` on binary fields are compiled to native C. With a `USAGE INDEX` field as the receiving item, `MULTIPLY` and `DIVIDE` become native C arithmetic too, and a dot product gets about 100 times faster.**

The price is steep, and it is described below: 32 bits, no overflow detection (`ON SIZE ERROR` is ignored), and a division by zero kills the program. Used where it is safe, it took the transformer from 1.2 to over 1300 tokens per second, faster than `run.c` built with `gcc -O3` on the 15M model.

We could not find this behavior documented anywhere: the [FAQ](https://gnucobol.sourceforge.io/faq/index.html) and the [Programmer's Guide](https://gnucobol.sourceforge.io/HTML/gnucobpg.html) recommend `COMP-5` for performance and do not mention `USAGE INDEX`. If this is already known, pointers are welcome.

## The finding in numbers

The same dot product, `acc = acc + w * x` over 1000 integers, written eight ways (`bench/arith.cob`). Every variant walks the tables with the same index, so only the arithmetic changes. All variants produce the same result.

GnuCOBOL 3.2, gcc 15.2, Intel i7-10700K, `cobc -x -O2`:

| Field type | Statements | ns per multiply-add | vs `COMP-5` |
|---|---|---|---|
| `COMP-2` (float) | `COMPUTE` | 945 | 24× slower |
| **`COMP-5`** (the official advice) | **`COMPUTE`** | **39** | **1×** |
| `COMP-5` | `MULTIPLY ... GIVING` + `ADD` | 63 | 1.6× slower |
| `BINARY-LONG` / `BINARY-DOUBLE` | `COMPUTE` | 40 | same |
| `USAGE INDEX` | `COMPUTE` | 39 | same |
| **`USAGE INDEX`** | **`SET` / `MULTIPLY` / `ADD`** | **0.36** | **~100× faster** |
| `COMP-5` data, `USAGE INDEX` result | `SET` / `MULTIPLY` / `ADD` | 0.36 | ~100× faster |
| `COMP-5` data and sum, `USAGE INDEX` product | `SET` / `MULTIPLY` / `ADD` | 0.47 | ~80× faster |

The numbers do not change with `-fno-trunc` (`bench/run.sh` measures both builds). The things to remember:
- **It is the statement that matters, not the type alone.** `COMPUTE` on an `INDEX` field is still decimal (39 ns). Only the format-1 verbs can be native: `ADD x TO y`, `SUBTRACT x FROM y`, `MULTIPLY x BY y`, `DIVIDE x INTO y`, `SET idx TO x`, `SET idx UP BY x`.
- **`ADD` and `SUBTRACT` are already native on `COMP-5` and `BINARY-*` fields**, if the value added fits in 32 bits. They are not native with `GIVING`, with `ON SIZE ERROR`, or on plain `COMP` unless you build with `-fno-trunc`.
- **`MULTIPLY` and `DIVIDE` are native only when the receiving field is `USAGE INDEX`.** On `COMP-5` they call `cob_mul` / `cob_div` in libcob, which work in decimal. This is the real bottleneck.
- **Only the product needs an `INDEX` field.** The data and the running sum can stay `COMP-5` (last row; the 64-bit sum costs a little more). The weight tables in `llama2.cob` are `PIC S9(4) COMP-5`, that is 16-bit integers.

### Why: the generated C

`cobc -C` shows what the line inside the loop turns into. `COMP-5` with `COMPUTE`:

```c
cob_decimal_set_llint (d_0, (*(cob_s64_ptr)(b_32)));
cob_decimal_set_llint (d_1, (*(int *)(b_22 + 4LL * ((cob_s64_t)((*(int *) (b_37))) - 1))));
cob_decimal_set_llint (d_2, (*(int *)(b_22 + 4000 + 4LL * ((cob_s64_t)((*(int *) (b_37))) - 1))));
cob_decimal_mul (d_1, d_2);
cob_decimal_add (d_0, d_1);
cob_decimal_get_field (d_0, &f_32, 0);
```

`USAGE INDEX` with `SET` / `MULTIPLY` / `ADD`:

```c
(*(int *) (b_36)) = (*(int *) (b_28 + 4LL * ((cob_s64_t)((*(int *) (b_37))) - 1)));
(*(int *) (b_36)) = ((*(int *) (b_36)) * (*(int *) (b_28 + 4000 + 4LL * ((cob_s64_t)((*(int *) (b_37))) - 1))));
(*(int *) (b_35)) = ((*(int *) (b_35)) + (*(int *) (b_36)));
```

The first is six library calls that turn every operand into a GMP number. The second is plain C that gcc is free to optimize: 0.36 ns is about 1.5 clock cycles per operation.

The `ADD` into a `COMP-5` sum (last row of the table) becomes `cob_add_s64 (b_32, ...)`: a static inline helper in the generated header that does a plain `n += val`. With `COMP-5` as the receiving field, `MULTIPLY` becomes `cob_mul (...)` instead, a libcob call that converts both operands to decimal.

## When NOT to use it

`USAGE INDEX` is meant for indexing tables, and GnuCOBOL treats it as a C `int` with no checks at all. `bench/overflow.cob` shows what happens:

| Case, always with `ON SIZE ERROR` | `COMP-5` (4 bytes) | `USAGE INDEX` |
|---|---|---|
| 50000 × 50000 | error raised, previous value kept | **-1794967296**, no error |
| 1 / 0 | error raised | **the program dies** (SIGFPE, `fatal arithmetic error`) |

2147483647 + 1 on an `INDEX` field also gives -2147483648 without any error.

So:

- **Never for amounts, balances, rates or any business data.** Those need decimal precision and `ON SIZE ERROR`, which is exactly why COBOL uses decimal arithmetic.
- **Never if a divisor can be zero.**
- **Only if you can prove that every intermediate result fits in ±2,147,483,647.** In `llama2.cob` this is guaranteed by `SPLIT-BITS`: for a sum of n products, the factors are scaled down so that (|a|+1)·(|b|+1)·n < 2³¹.
- **Fine for** counters, indexes, loops, checksums, hashes, and integer number crunching with known bounds: the "engine" of an algorithm rather than its accounting data.

## Other measured costs

`bench/arith.cob`, part B:

| Operation | ns |
|---|---|
| `FUNCTION EXP` on `COMP-2` | ~97,000 |
| `FUNCTION SQRT` on `COMP-2` | ~2,200 |
| `COMPUTE R ROUNDED = BIG / 65536` (`COMP-5`) | 107 |
| `DIVIDE 65536 INTO RX` (`USAGE INDEX`) | 0.46 |
| 4-byte `CBL_READ_FILE`, on tmpfs | 320 |
| 4-byte `CBL_READ_FILE`, on a Windows folder mounted in WSL (9p) | 126,000 |

Two practical warnings:
- **`FUNCTION EXP` costs almost 0.1 ms.** Inside a loop, use a precomputed table.
- **`CBL_READ_FILE` is not slow in itself; the cost depends on the filesystem.** On `/mnt/c` under WSL every call goes through the 9p protocol: reading a file with 96,000 small reads took 15 seconds. The fix is to read everything in one call and split it in memory.

## The proof: an LLM in COBOL

`src/llama2.cob` is a complete Llama 2 transformer in about 1650 lines of COBOL: RMSNorm, RoPE, grouped-query attention, SwiGLU, KV cache, BPE tokenizer and top-p sampling. It loads Karpathy's *TinyStories* models and writes little stories:

```
$ ./build/llama2 model/stories15M.bin -z model/tokenizer.bin -t 0 -i "Once upon a time"
Once upon a time, there was a little girl named Lily. She loved to play outside in the
sunshine. One day, she saw a big, red ball in the sky. It was the sun! She thought it
was so pretty. ...
achieved tok/s: 83.71
```

In greedy mode (`-t 0`) the text is **byte-for-byte identical** to `run.c`'s output, on both models.

### Speed

256 tokens, best of 3 runs (`verify.sh`):

| Model | Output vs `run.c` | C `gcc -O3` | C `gcc -Ofast -march=native` | **COBOL** |
|---|---|---|---|---|
| stories260K | identical | ~3800 tok/s | ~12750 tok/s | **~1300 tok/s** |
| stories15M | identical | 61 tok/s | 174 tok/s | **84 tok/s** |

Absolute numbers vary by up to 20% between runs (CPU frequency); the ratios stay similar. On the 15M model the COBOL version beats C built with `-O3`. The most likely explanation, not checked in the assembly, is that 32-bit integer sums can be vectorized, while a float sum cannot be reordered without `-ffast-math`. With every optimization enabled, C is still about 2× faster. On the 260K model a generation lasts a few hundredths of a second and the measurements are noisy.

### The path, measured at every step

| Step | tok/s (260K) | What changed |
|---|---|---|
| 1 | 1.2 | straight translation of `run.c`: `COMP-2`, `COMPUTE`, `FUNCTION EXP` |
| 2 | 42 | exponential tables instead of `FUNCTION EXP` |
| 3 | 93 | matrix-vector product with `USAGE INDEX` |
| 4 | 654 | the whole hot path in native integers, attention included |
| 5 | 1342 | Q16 × Q16 multiplications made native too |

To stay within the 32 bits of `USAGE INDEX` the program uses **block floating point**, as DSPs do; the idea is similar to the quantization in `runq.c`. Each vector is made of small integers plus a shared exponent (value ≈ integer × 2^k), so rescaling is a shift, that is a native division by a power of 2. In detail:
- Weights are 11-13 bit integers with one exponent per row.
- The KV cache is stored quantized, with one exponent per head.
- Activations between blocks are Q16 fixed point (65536 = 1.0), like a bank's cents.
- `MUL-Q16` multiplies two Q16 values by splitting them into 15-bit halves: x·y/2¹⁶ = xh·yh·2¹⁴ + (xh·yl + xl·yh)/2 + xl·yl/2¹⁶. Each piece fits in 32 bits and the result is rounded exactly.
- `FLOAT-TO-Q16` decodes the checkpoint's IEEE-754 floats by hand (sign, exponent, mantissa) with integer divisions.
- `exp` comes from two Q15 tables: exp(−u) = exp(−high part) × exp(−low part).
- The `cos` and `sin` tables for RoPE are built by successive rotations, with a single call to `FUNCTION COS`/`SIN` per frequency.
- The tokenizer searches the vocabulary with `SEARCH ALL` on a table ordered with `SORT`.

None of this is new from an AI point of view: it is the same approach as integer-only inference ([I-LLM](https://arxiv.org/abs/2405.17849)), power-of-two quantization scales, and verifiable inference systems (zkML), which use fixed point and lookup tables for the same reason. The only new thing here is the language.

### The near-tie at step 185

At one point the text diverged from C after 185 tokens: "Lily said…" instead of "Lily didn't…". Making `run.c` print the gap between the two best logits showed that at that point **C itself is undecided**: the difference between `" d"` and `" said"` is 0.004. A quantized implementation and a float one agree until the model is within a hair of a tie; at those points a single rounding is enough to take the other path. The final version agrees again, but "byte-for-byte identical" should be read with this caveat.

## Reproduce

You need GnuCOBOL 3.x (tested with 3.2 on Ubuntu):

```bash
sudo apt install gnucobol
```

The arithmetic benchmark, with the generated C and the overflow demo:

```bash
bash bench/run.sh
```

The LLM: download a model and its tokenizer, then build and run.

```bash
mkdir -p model
curl -L -o model/stories15M.bin https://huggingface.co/karpathy/tinyllamas/resolve/main/stories15M.bin
curl -L -o model/tokenizer.bin https://raw.githubusercontent.com/karpathy/llama2.c/master/tokenizer.bin
bash build.sh
./build/llama2 model/stories15M.bin -z model/tokenizer.bin -i "The dragon"
```

| Option | Meaning | Default |
|---|---|---|
| `-t <float>` | temperature (0 = greedy) | 1.0 |
| `-p <float>` | top-p (nucleus sampling) | 0.9 |
| `-s <int>` | random seed | clock |
| `-n <int>` | tokens to generate (0 = max) | 256 |
| `-i <text>` | prompt | empty |
| `-z <file>` | tokenizer | `tokenizer.bin` |

The tiny `stories260K` model has its own tokenizer:

```bash
curl -L -o model/stories260K.bin https://huggingface.co/karpathy/tinyllamas/resolve/main/stories260K/stories260K.bin
curl -L -o model/tok512.bin https://huggingface.co/karpathy/tinyllamas/resolve/main/stories260K/tok512.bin
```

`verify.sh` also builds `ref/run.c`, checks that both programs generate the same text, and measures their speed.

## Files

| File | Contents |
|---|---|
| `bench/arith.cob` | the arithmetic benchmark (part A) and single-operation costs (part B) |
| `bench/overflow.cob` | what happens when a `USAGE INDEX` field overflows or divides by zero |
| `bench/run.sh` | runs the benchmarks, shows the generated C and the environment |
| `src/llama2.cob` | the transformer in COBOL |
| `build.sh` | builds `llama2.cob` with `cobc -x -O2 -fno-trunc` |
| `verify.sh` | comparison with `run.c`: identical output and speed |
| `ref/run.c` | Karpathy's C reference (MIT license in `ref/LICENSE`) |

## Limits of what we verified

- **Only GnuCOBOL 3.2** on x86-64 Linux (WSL2, Ubuntu). Other versions, especially the 4.0 development branch, may generate different code: `bash bench/run.sh` will tell you in a minute.
- **The behavior of `USAGE INDEX` is implementation-specific.** Other COBOL compilers, IBM Enterprise COBOL included, were not tested.
- **`llama2.cob` only runs on little-endian machines**, its tables are sized up to stories15M, and with a temperature it uses `FUNCTION RANDOM`: with the same seed the story differs from `run.c`'s.

## Credits

- [llama2.c](https://github.com/karpathy/llama2.c) by Andrej Karpathy: architecture, file format, models and tokenizer.
- [TinyStories](https://arxiv.org/abs/2305.07759) by Ronen Eldan and Yuanzhi Li: the dataset the models were trained on.

## License

MIT, see `LICENSE`. `src/llama2.cob` is a port of `run.c` from llama2.c, also MIT (Copyright (c) 2023 Andrej Karpathy).
