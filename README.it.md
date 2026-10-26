# llama2.cob

[English](README.md) | **Italiano**

**Cosa abbiamo scoperto sull'aritmetica di GnuCOBOL facendo girare un LLM in COBOL.**

Il progetto è nato come esperimento: portare [llama2.c](https://github.com/karpathy/llama2.c) di Andrej Karpathy in COBOL. La prima versione funzionava, ma andava a 1,2 token al secondo. Per capire perché abbiamo guardato il C che GnuCOBOL genera, e abbiamo trovato una cosa che riguarda qualunque programma GnuCOBOL, non solo questo:

> **In GnuCOBOL 3.2 ogni `COMPUTE`, `MULTIPLY` e `DIVIDE` passa per l'aritmetica decimale a precisione arbitraria (GMP), anche tra campi binari `COMP-5`, la forma che la documentazione consiglia per la velocità. Solo `ADD` e `SUBTRACT` su campi binari vengono tradotti in C nativo. Con un campo `USAGE INDEX` come destinazione diventano aritmetica C nativa anche `MULTIPLY` e `DIVIDE`, e un prodotto scalare diventa circa 100 volte più veloce.**

Il prezzo è alto, ed è descritto sotto: 32 bit, nessun controllo di overflow (`ON SIZE ERROR` viene ignorato) e una divisione per zero fa terminare il programma. Usato dove è sicuro, ha portato il transformer da 1,2 a oltre 1300 token al secondo, più veloce di `run.c` compilato con `gcc -O3` sul modello da 15M.

Non abbiamo trovato questo comportamento documentato: la [FAQ](https://gnucobol.sourceforge.io/faq/index.html) e la [Programmer's Guide](https://gnucobol.sourceforge.io/HTML/gnucobpg.html) consigliano `COMP-5` per le prestazioni e non citano `USAGE INDEX`. Se qualcuno lo conosceva già, le segnalazioni sono benvenute.

## La scoperta in numeri

Lo stesso prodotto scalare `acc = acc + w * x` su 1000 interi, scritto in otto modi (`bench/arith.cob`). Tutte le varianti scorrono le tabelle con lo stesso indice, quindi cambia solo l'aritmetica. Tutte danno lo stesso risultato.

GnuCOBOL 3.2, gcc 15.2, Intel i7-10700K, `cobc -x -O2`:

| Tipo dei campi | Istruzioni | ns per moltiplicazione-somma | rispetto a `COMP-5` |
|---|---|---|---|
| `COMP-2` (float) | `COMPUTE` | 945 | 24 volte più lento |
| **`COMP-5`** (il consiglio ufficiale) | **`COMPUTE`** | **39** | **1×** |
| `COMP-5` | `MULTIPLY ... GIVING` + `ADD` | 63 | 1,6 volte più lento |
| `BINARY-LONG` / `BINARY-DOUBLE` | `COMPUTE` | 40 | uguale |
| `USAGE INDEX` | `COMPUTE` | 39 | uguale |
| **`USAGE INDEX`** | **`SET` / `MULTIPLY` / `ADD`** | **0,36** | **~100 volte più veloce** |
| dati `COMP-5`, risultato `USAGE INDEX` | `SET` / `MULTIPLY` / `ADD` | 0,36 | ~100 volte più veloce |
| dati e somma `COMP-5`, prodotto `USAGE INDEX` | `SET` / `MULTIPLY` / `ADD` | 0,47 | ~80 volte più veloce |

Con `-fno-trunc` i numeri non cambiano (`bench/run.sh` misura entrambe le compilazioni). Le cose da tenere a mente:
- **Conta l'istruzione, non il tipo da solo.** `COMPUTE` su un campo `INDEX` resta decimale (39 ns). Possono diventare nativi solo i verbi di formato 1: `ADD x TO y`, `SUBTRACT x FROM y`, `MULTIPLY x BY y`, `DIVIDE x INTO y`, `SET idx TO x`, `SET idx UP BY x`.
- **`ADD` e `SUBTRACT` sono già nativi su campi `COMP-5` e `BINARY-*`**, se il valore sommato sta in 32 bit. Non lo sono con `GIVING`, con `ON SIZE ERROR`, né su `COMP` semplice se non si compila con `-fno-trunc`.
- **`MULTIPLY` e `DIVIDE` sono nativi solo se il campo che riceve il risultato è `USAGE INDEX`.** Su `COMP-5` chiamano `cob_mul` / `cob_div` di libcob, che lavorano in decimale. Il vero collo di bottiglia è questo.
- **Solo il prodotto ha bisogno di un campo `INDEX`.** I dati e la somma possono restare `COMP-5` (ultima riga; la somma a 64 bit costa un po' di più). Le tabelle dei pesi di `llama2.cob` sono `PIC S9(4) COMP-5`, cioè interi a 16 bit.

### Perché: il C generato

Con `cobc -C` si vede cosa diventa la riga dentro il ciclo. `COMP-5` con `COMPUTE`:

```c
cob_decimal_set_llint (d_0, (*(cob_s64_ptr)(b_32)));
cob_decimal_set_llint (d_1, (*(int *)(b_22 + 4LL * ((cob_s64_t)((*(int *) (b_37))) - 1))));
cob_decimal_set_llint (d_2, (*(int *)(b_22 + 4000 + 4LL * ((cob_s64_t)((*(int *) (b_37))) - 1))));
cob_decimal_mul (d_1, d_2);
cob_decimal_add (d_0, d_1);
cob_decimal_get_field (d_0, &f_32, 0);
```

`USAGE INDEX` con `SET` / `MULTIPLY` / `ADD`:

```c
(*(int *) (b_36)) = (*(int *) (b_28 + 4LL * ((cob_s64_t)((*(int *) (b_37))) - 1)));
(*(int *) (b_36)) = ((*(int *) (b_36)) * (*(int *) (b_28 + 4000 + 4LL * ((cob_s64_t)((*(int *) (b_37))) - 1))));
(*(int *) (b_35)) = ((*(int *) (b_35)) + (*(int *) (b_36)));
```

Il primo sono sei chiamate di libreria che convertono ogni operando in un numero GMP. Il secondo è C puro, che gcc può ottimizzare liberamente: 0,36 ns sono circa 1,5 cicli di clock per operazione.

L'`ADD` in una somma `COMP-5` (ultima riga della tabella) diventa `cob_add_s64 (b_32, ...)`: una funzione inline nell'header generato che fa un semplice `n += val`. Con `COMP-5` come destinazione, invece, `MULTIPLY` diventa `cob_mul (...)`, una chiamata a libcob che converte entrambi gli operandi in decimale.

## Quando NON usarlo

`USAGE INDEX` è pensato per indicizzare le tabelle, e GnuCOBOL lo tratta come un `int` C senza alcun controllo. `bench/overflow.cob` mostra cosa succede:

| Caso, sempre con `ON SIZE ERROR` | `COMP-5` (4 byte) | `USAGE INDEX` |
|---|---|---|
| 50000 × 50000 | errore segnalato, valore precedente conservato | **-1794967296**, nessun errore |
| 1 / 0 | errore segnalato | **il programma termina** (SIGFPE, `fatal arithmetic error`) |

Anche 2147483647 + 1 su un campo `INDEX` dà -2147483648 senza nessun errore.

Quindi:

- **Mai per importi, saldi, tassi o qualunque dato di business.** Lì servono la precisione decimale e `ON SIZE ERROR`, ed è proprio per questo che il COBOL usa l'aritmetica decimale.
- **Mai se un divisore può essere zero.**
- **Solo se si può dimostrare che ogni risultato intermedio sta in ±2.147.483.647.** In `llama2.cob` lo garantisce `SPLIT-BITS`: per una somma di n prodotti i fattori vengono ridotti in modo che (|a|+1)·(|b|+1)·n < 2³¹.
- **Va bene per** contatori, indici, cicli, checksum, hash, e calcoli numerici su interi con limiti noti, cioè il "motore" di un algoritmo più che i suoi dati contabili.

## Altri costi misurati

`bench/arith.cob`, parte B:

| Operazione | ns |
|---|---|
| `FUNCTION EXP` su `COMP-2` | ~97.000 |
| `FUNCTION SQRT` su `COMP-2` | ~2.200 |
| `COMPUTE R ROUNDED = BIG / 65536` (`COMP-5`) | 107 |
| `DIVIDE 65536 INTO RX` (`USAGE INDEX`) | 0,46 |
| `CBL_READ_FILE` di 4 byte, su tmpfs | 320 |
| `CBL_READ_FILE` di 4 byte, su una cartella Windows montata in WSL (9p) | 126.000 |

Due avvertenze pratiche:
- **`FUNCTION EXP` costa quasi 0,1 ms.** In un ciclo conviene una tabella precalcolata.
- **`CBL_READ_FILE` non è lento di per sé, il costo dipende dal filesystem.** Su `/mnt/c` in WSL ogni chiamata attraversa il protocollo 9p: leggere un file con 96.000 letture da pochi byte richiedeva 15 secondi. La soluzione è leggere tutto in un'unica chiamata e scomporre in memoria.

## La prova: un LLM in COBOL

`src/llama2.cob` è un transformer Llama 2 completo in circa 1650 righe di COBOL: RMSNorm, RoPE, grouped-query attention, SwiGLU, KV cache, tokenizer BPE e campionamento top-p. Carica i modelli *TinyStories* di Karpathy e scrive favolette in inglese:

```
$ ./build/llama2 model/stories15M.bin -z model/tokenizer.bin -t 0 -i "Once upon a time"
Once upon a time, there was a little girl named Lily. She loved to play outside in the
sunshine. One day, she saw a big, red ball in the sky. It was the sun! She thought it
was so pretty. ...
achieved tok/s: 83.71
```

In modalità greedy (`-t 0`) il testo è **identico byte per byte** a quello di `run.c`, su entrambi i modelli.

### Velocità

256 token, migliore di 3 esecuzioni (`verify.sh`):

| Modello | Output vs `run.c` | C `gcc -O3` | C `gcc -Ofast -march=native` | **COBOL** |
|---|---|---|---|---|
| stories260K | identico | ~3800 tok/s | ~12750 tok/s | **~1300 tok/s** |
| stories15M | identico | 61 tok/s | 174 tok/s | **84 tok/s** |

I valori assoluti cambiano anche del 20% da un'esecuzione all'altra (frequenza della CPU), i rapporti restano simili. Sul modello da 15M il COBOL batte il C compilato con `-O3`. La spiegazione più probabile, non verificata sull'assembly, è che le somme di interi a 32 bit si possono vettorizzare, mentre una somma di float non si può riordinare senza `-ffast-math`. Con tutte le ottimizzazioni attive il C resta circa 2 volte più veloce. Sul modello da 260K le generazioni durano pochi centesimi di secondo e le misure sono rumorose.

### Il percorso, misurato a ogni passo

| Passo | tok/s (260K) | Cosa è cambiato |
|---|---|---|
| 1 | 1,2 | traduzione diretta di `run.c`: `COMP-2`, `COMPUTE`, `FUNCTION EXP` |
| 2 | 42 | tabelle di esponenziali al posto di `FUNCTION EXP` |
| 3 | 93 | prodotto matrice-vettore con `USAGE INDEX` |
| 4 | 654 | tutto il percorso caldo in interi nativi, attenzione compresa |
| 5 | 1342 | anche le moltiplicazioni Q16 × Q16 native |

Per stare dentro i 32 bit di `USAGE INDEX` il programma usa il **floating point a blocchi**, come i DSP; l'idea è simile alla quantizzazione di `runq.c`. Ogni vettore è fatto di interi piccoli più un esponente comune (valore ≈ intero × 2^k), così i riscalamenti sono shift, cioè divisioni native per potenze di 2. In dettaglio:
- I pesi sono interi a 11-13 bit con un esponente per riga.
- La KV cache è salvata quantizzata, con un esponente per testa.
- Le attivazioni tra un blocco e l'altro sono in virgola fissa Q16 (65536 = 1,0), come i centesimi di una banca.
- `MUL-Q16` moltiplica due valori Q16 spezzandoli in parti da 15 bit: x·y/2¹⁶ = xh·yh·2¹⁴ + (xh·yl + xl·yh)/2 + xl·yl/2¹⁶. Ogni pezzo sta in 32 bit e il risultato è arrotondato esattamente.
- `FLOAT-TO-Q16` decodifica a mano i float IEEE-754 del checkpoint (segno, esponente, mantissa) con divisioni intere.
- `exp` viene da due tabelle Q15: exp(−u) = exp(−parte alta) × exp(−parte bassa).
- Le tabelle di `cos` e `sin` per RoPE si costruiscono per rotazioni successive, con una sola chiamata a `FUNCTION COS`/`SIN` per frequenza.
- Il tokenizer cerca nel vocabolario con `SEARCH ALL` su una tabella ordinata con `SORT`.

Niente di tutto questo è nuovo dal punto di vista dell'AI: è lo stesso approccio dell'inferenza solo a interi ([I-LLM](https://arxiv.org/abs/2405.17849)), della quantizzazione con scale a potenze di 2, e dei sistemi di inferenza verificabile (zkML), che per lo stesso motivo usano virgola fissa e tabelle. La novità qui è soltanto il linguaggio.

### Il quasi pareggio del passo 185

A un certo punto il testo divergeva dal C dopo 185 token: "Lily said…" invece di "Lily didn't…". Facendo stampare a `run.c` la distanza tra i due logit migliori, è venuto fuori che lì **anche il C è indeciso**: tra `" d"` e `" said"` la differenza è 0,004. Un'implementazione quantizzata e una in float coincidono finché il modello non arriva a un soffio dal pareggio; in quei punti basta un arrotondamento per cambiare strada. La versione finale torna a coincidere, ma "identico byte per byte" va letto con questa avvertenza.

## Riprodurre

Serve GnuCOBOL 3.x (testato con 3.2 su Ubuntu):

```bash
sudo apt install gnucobol
```

Il benchmark dell'aritmetica, con il C generato e la prova di overflow:

```bash
bash bench/run.sh
```

L'LLM: scarica un modello e il suo tokenizer, poi compila ed esegui.

```bash
mkdir -p model
curl -L -o model/stories15M.bin https://huggingface.co/karpathy/tinyllamas/resolve/main/stories15M.bin
curl -L -o model/tokenizer.bin https://raw.githubusercontent.com/karpathy/llama2.c/master/tokenizer.bin
bash build.sh
./build/llama2 model/stories15M.bin -z model/tokenizer.bin -i "The dragon"
```

| Opzione | Significato | Default |
|---|---|---|
| `-t <float>` | temperatura (0 = greedy) | 1.0 |
| `-p <float>` | top-p (nucleus sampling) | 0.9 |
| `-s <int>` | seed casuale | orologio |
| `-n <int>` | token da generare (0 = massimo) | 256 |
| `-i <testo>` | prompt | vuoto |
| `-z <file>` | tokenizer | `tokenizer.bin` |

Il modello minuscolo `stories260K` usa un tokenizer suo:

```bash
curl -L -o model/stories260K.bin https://huggingface.co/karpathy/tinyllamas/resolve/main/stories260K/stories260K.bin
curl -L -o model/tok512.bin https://huggingface.co/karpathy/tinyllamas/resolve/main/stories260K/tok512.bin
```

`verify.sh` compila anche `ref/run.c`, controlla che i due programmi generino lo stesso testo e misura le velocità.

## File

| File | Contenuto |
|---|---|
| `bench/arith.cob` | il benchmark dell'aritmetica (parte A) e dei costi singoli (parte B) |
| `bench/overflow.cob` | cosa succede quando un campo `USAGE INDEX` sfora o divide per zero |
| `bench/run.sh` | esegue i benchmark, mostra il C generato e l'ambiente |
| `src/llama2.cob` | il transformer in COBOL |
| `build.sh` | compila `llama2.cob` con `cobc -x -O2 -fno-trunc` |
| `verify.sh` | confronto con `run.c`: output identico e velocità |
| `ref/run.c` | il riferimento C di Karpathy (licenza MIT in `ref/LICENSE`) |

## Limiti di quello che abbiamo verificato

- **Solo GnuCOBOL 3.2** su x86-64 Linux (WSL2, Ubuntu). Altre versioni, in particolare la 4.0 in sviluppo, potrebbero generare codice diverso: `bash bench/run.sh` lo dice in un minuto.
- **Il comportamento di `USAGE INDEX` dipende dall'implementazione.** Altri compilatori COBOL, IBM Enterprise COBOL compreso, non sono stati provati.
- **`llama2.cob` funziona solo su macchine little-endian**, ha tabelle dimensionate fino a stories15M, e con la temperatura usa `FUNCTION RANDOM`: a parità di seed la storia è diversa da quella di `run.c`.

## Crediti

- [llama2.c](https://github.com/karpathy/llama2.c) di Andrej Karpathy: architettura, formato dei file, modelli e tokenizer.
- [TinyStories](https://arxiv.org/abs/2305.07759) di Ronen Eldan e Yuanzhi Li: il dataset su cui sono addestrati i modelli.

## Licenza

MIT, vedi `LICENSE`. `src/llama2.cob` è un porting di `run.c` di llama2.c, anch'esso MIT (Copyright (c) 2023 Andrej Karpathy).
