       >>SOURCE FORMAT FREE
*> ==================================================================
*>  LLAMA2.COB - Llama 2 inference in pure COBOL
*>
*>  A port of run.c (github.com/karpathy/llama2.c) to GnuCOBOL.
*>
*>  How to make COBOL fast:
*>  - GnuCOBOL runs COMPUTE (even between integers) with arbitrary-
*>    precision decimal arithmetic: correct but slow.
*>  - USAGE INDEX fields instead become C "int"s, and SET, ADD,
*>    SUBTRACT, MULTIPLY, DIVIDE into them become native C.
*>  - So the hot path uses block floating point: every vector is
*>    made of small integers plus a shared exponent
*>    (value = integer * 2^k), so rescaling is a shift.
*>  - Activations live in Q16 fixed point (65536 = 1.0), like a
*>    bank's cents. No floats in the main loop.
*>
*>  Usage: llama2 <checkpoint> [options]
*>    -t <float>  temperature (default 1.0, 0 = greedy)
*>    -p <float>  top-p (default 0.9)
*>    -s <int>    random seed (default: clock)
*>    -n <int>    number of steps (default 256, 0 = seq_len)
*>    -i <text>   prompt
*>    -z <file>   tokenizer (default tokenizer.bin)
*> ==================================================================
IDENTIFICATION DIVISION.
PROGRAM-ID. LLAMA2.

DATA DIVISION.
WORKING-STORAGE SECTION.
*> ---- maximum capacities (enough for stories15M) -----------------
78 MAX-W           VALUE 16000000.
78 MAX-ACT         VALUE 100000.
78 MAX-KV          VALUE 2000000.
78 MAX-KVROWS      VALUE 100000.
78 MAX-VOCAB       VALUE 32000.
78 MAX-SEQ         VALUE 1024.
78 MAX-ROPE        VALUE 65536.
78 MAX-ENC         VALUE 1100.
78 MAX-ROWS        VALUE 100000.
78 MAX-N           VALUE 1024.
78 CHUNK-FLOATS    VALUE 65536.

*> ---- command line ------------------------------------------------
01 ARG-COUNT       PIC 9(4) COMP-5.
01 ARG-IDX         PIC 9(4) COMP-5.
01 ARG-FLAG        PIC X(256).
01 ARG-VAL         PIC X(1024).
01 CKPT-PATH       PIC X(256) VALUE SPACES.
01 TOK-PATH        PIC X(256) VALUE "tokenizer.bin".
01 PROMPT-TXT      PIC X(1024) VALUE SPACES.
01 PROMPT-LEN      PIC S9(9) COMP-5 VALUE 0.
01 TEMPERATURE     COMP-2 VALUE 1.0.
01 TOPP            COMP-2 VALUE 0.9.
01 RNG-SEED        PIC S9(9) COMP-5 VALUE 0.
01 STEPS           PIC S9(9) COMP-5 VALUE 256.

*> ---- binary I/O (GnuCOBOL byte-stream routines) -----------------
01 F-HANDLE        PIC X(4).
01 F-ACCESS        PIC X COMP-X VALUE 1.
01 F-DENY          PIC X COMP-X VALUE 0.
01 F-DEVICE        PIC X COMP-X VALUE 0.
01 F-OFFSET        PIC X(8) COMP-X.
01 F-NBYTES        PIC X(4) COMP-X.
01 F-FLAGS         PIC X COMP-X VALUE 0.
01 F-DONE          PIC S9(9) COMP-5.
01 F-CHUNK         PIC S9(9) COMP-5.
*> the file's floats read as raw bits: FLOAT-TO-Q16 decodes them
01 F-BUF.
   05 F-BUF-I      PIC S9(9) COMP-5 OCCURS CHUNK-FLOATS TIMES.

*> ---- model configuration (checkpoint header) --------------------
01 CFG-HEADER.
   05 DIM          PIC S9(9) COMP-5.
   05 HID          PIC S9(9) COMP-5.
   05 N-LAYERS     PIC S9(9) COMP-5.
   05 N-HEADS      PIC S9(9) COMP-5.
   05 N-KVH        PIC S9(9) COMP-5.
   05 HDR-VOCAB    PIC S9(9) COMP-5.
   05 SEQ-LEN      PIC S9(9) COMP-5.
01 N-VOCAB         PIC S9(9) COMP-5 VALUE 1.
01 SHARED-W        PIC 9 VALUE 0.
01 HS              PIC S9(9) COMP-5.
01 HS2             PIC S9(9) COMP-5.
01 KVD             PIC S9(9) COMP-5.
01 KVMUL           PIC S9(9) COMP-5.

*> ---- 1-based offsets of the tensors inside WQ -------------------
01 O-EMB           PIC S9(9) COMP-5.
01 O-RMSATT        PIC S9(9) COMP-5.
01 O-WQ            PIC S9(9) COMP-5.
01 O-WK            PIC S9(9) COMP-5.
01 O-WV            PIC S9(9) COMP-5.
01 O-WO            PIC S9(9) COMP-5.
01 O-RMSFFN        PIC S9(9) COMP-5.
01 O-W1            PIC S9(9) COMP-5.
01 O-W2            PIC S9(9) COMP-5.
01 O-W3            PIC S9(9) COMP-5.
01 O-RMSFIN        PIC S9(9) COMP-5.
01 O-WCLS          PIC S9(9) COMP-5.
01 N-FLOATS        PIC S9(9) COMP-5.

*> ---- all the weights in Q16 -------------------------------------
01 WEIGHTS.
   05 WQ           PIC S9(9) COMP-5 OCCURS MAX-W TIMES.

*> ---- matrix weights: small integers (same offsets as WQ) --------
*>      plus one exponent per row: weight_Q16 = MQ * 2^ER
01 MQ-TAB.
   05 MQ           PIC S9(4) COMP-5 OCCURS MAX-W TIMES.
01 ER-TAB.
   05 ER           PIC S9(4) COMP-5 OCCURS MAX-ROWS TIMES.
01 RB-WQ           PIC S9(9) COMP-5.
01 RB-WK           PIC S9(9) COMP-5.
01 RB-WV           PIC S9(9) COMP-5.
01 RB-WO           PIC S9(9) COMP-5.
01 RB-W1           PIC S9(9) COMP-5.
01 RB-W2           PIC S9(9) COMP-5.
01 RB-W3           PIC S9(9) COMP-5.
01 RB-WCLS         PIC S9(9) COMP-5.
01 N-ROWS          PIC S9(9) COMP-5.
01 QT-OFF          PIC S9(9) COMP-5.
01 QT-ROWS         PIC S9(9) COMP-5.
01 QT-N            PIC S9(9) COMP-5.

*> ---- activations in Q16 (a single "RAM" with offsets) ----------
01 A-X             PIC S9(9) COMP-5.
01 A-XB            PIC S9(9) COMP-5.
01 A-XB2           PIC S9(9) COMP-5.
01 A-HB            PIC S9(9) COMP-5.
01 A-HB2           PIC S9(9) COMP-5.
01 A-Q             PIC S9(9) COMP-5.
01 A-QS            PIC S9(9) COMP-5.
01 A-K             PIC S9(9) COMP-5.
01 A-V             PIC S9(9) COMP-5.
01 A-LOG           PIC S9(9) COMP-5.
01 A-END           PIC S9(9) COMP-5.
01 ACTS.
   05 ACT          PIC S9(9) COMP-5 OCCURS MAX-ACT TIMES.

*> ---- quantized KV cache: one exponent per (layer, pos, head) -----
01 KQ-TAB.
   05 KQ           PIC S9(4) COMP-5 OCCURS MAX-KV TIMES.
01 VQ-TAB.
   05 VQ           PIC S9(4) COMP-5 OCCURS MAX-KV TIMES.
01 KE-TAB.
   05 KE           PIC S9(4) COMP-5 OCCURS MAX-KVROWS TIMES.
01 VE-TAB.
   05 VE           PIC S9(4) COMP-5 OCCURS MAX-KVROWS TIMES.
01 KV-ROW          PIC S9(9) COMP-5.
01 KV-BASE         PIC S9(9) COMP-5.
01 KE-BASE         PIC S9(9) COMP-5.

*> ---- quantized vector (output of QUANT-VEC) ---------------------
01 QB-TAB.
   05 QB           USAGE INDEX OCCURS MAX-N TIMES.
01 QV-IN           PIC S9(9) COMP-5.
01 QV-N            PIC S9(9) COMP-5.
01 QV-K            USAGE INDEX.
*> quantization limits: a sum of n products |w| * |x| must fit in
*> 32 bits, so (WLIM+1) * (XLIM+1) * n < 2^31. The available bits
*> are split in half between the two factors (see SPLIT-BITS).
01 WLIM-D          PIC S9(9) COMP-5.
01 WLIM-H          PIC S9(9) COMP-5.
01 XLIM-D          PIC S9(9) COMP-5.
01 XLIM-H          PIC S9(9) COMP-5.
01 KLIM            PIC S9(9) COMP-5.
01 QLIM            PIC S9(9) COMP-5.
*> v is weighted by coefficients that sum to 2^15: 15 bits are enough
01 VLIM            PIC S9(9) COMP-5 VALUE 32766.
01 SB-N            PIC S9(9) COMP-5.
01 SB-A            PIC S9(9) COMP-5.
01 SB-B            PIC S9(9) COMP-5.
01 SB-P            PIC S9(18) COMP-5.
01 QT-LIM          PIC S9(9) COMP-5.

*> ---- native C integers (USAGE INDEX) for the whole hot path -----
01 P2-TAB.
   05 P2           USAGE INDEX OCCURS 31 TIMES.
01 IP              USAGE INDEX.
01 IACC            USAGE INDEX.
01 IWI             USAGE INDEX.
01 IXI             USAGE INDEX.
01 IR              USAGE INDEX.
01 IV              USAGE INDEX.
01 IA              USAGE INDEX.
01 IT              USAGE INDEX.
01 IT2             USAGE INDEX.
01 IK              USAGE INDEX.
01 IMAX            USAGE INDEX.
01 ILIM            USAGE INDEX.
01 ISH             USAGE INDEX.
01 ISR              USAGE INDEX.
01 IU              USAGE INDEX.
01 IH              USAGE INDEX.
01 IL              USAGE INDEX.
01 IE              USAGE INDEX.
01 ISUM            USAGE INDEX.
01 IKB             USAGE INDEX.
01 IEB             USAGE INDEX.
01 IVMAX           USAGE INDEX.
01 IMAXS           USAGE INDEX.
01 ITT             USAGE INDEX.
01 IB              USAGE INDEX.
01 IM              USAGE INDEX.
01 IEXP            USAGE INDEX.
01 INEG            USAGE INDEX.
*> operands and result of MUL-Q16
01 IX              USAGE INDEX.
01 IY              USAGE INDEX.
01 IZ              USAGE INDEX.
01 MX              USAGE INDEX.
01 MY              USAGE INDEX.
01 MXH             USAGE INDEX.
01 MXL             USAGE INDEX.
01 MYH             USAGE INDEX.
01 MYL             USAGE INDEX.
01 MT              USAGE INDEX.
01 MLO             USAGE INDEX.
01 MSG             USAGE INDEX.
01 RLIM            PIC S9(9) COMP-5.
01 R-K             PIC S9(9) COMP-5.
01 RPI             PIC S9(9) COMP-5.

*> ---- fixed-point exponential ------------------------------------
*> FUNCTION EXP costs ~100 microseconds: too much. Two Q15 tables:
*> exp(-u) = exp(-(u div 1024)/64) * exp(-(u mod 1024)/65536), u in Q16
01 EXH-TAB.
   05 EXH          USAGE INDEX OCCURS 1025 TIMES.
01 EXL-TAB.
   05 EXL          USAGE INDEX OCCURS 1024 TIMES.

*> ---- attention --------------------------------------------------
01 ATS-TAB.
   05 ATS          USAGE INDEX OCCURS MAX-SEQ TIMES.
01 ATE-TAB.
   05 ATE          USAGE INDEX OCCURS MAX-SEQ TIMES.
01 INV-SQRT-HS     PIC S9(9) COMP-5.

*> ---- precomputed RoPE tables (cos/sin in Q16) -------------------
01 ROPE-TAB.
   05 ROPE-ENTRY   OCCURS MAX-ROPE TIMES.
      10 ROPE-C    PIC S9(9) COMP-5.
      10 ROPE-S    PIC S9(9) COMP-5.
01 FREQ            COMP-2.
01 R-C             COMP-2.
01 R-S             COMP-2.
01 R-C1            COMP-2.
01 R-S1            COMP-2.
01 R-VAL           COMP-2.
01 R-STEP          COMP-2.

*> ---- registers for the "subroutines" (paragraphs) --------------
01 M-OUT           PIC S9(9) COMP-5.
01 M-W             PIC S9(9) COMP-5.
01 M-N             PIC S9(9) COMP-5.
01 M-D             PIC S9(9) COMP-5.
01 M-R             PIC S9(9) COMP-5.
01 R-OUT           PIC S9(9) COMP-5.
01 R-IN            PIC S9(9) COMP-5.
01 R-W             PIC S9(9) COMP-5.
01 R-N             PIC S9(9) COMP-5.
01 R-SS            COMP-2.
01 R-SCALE         PIC S9(18) COMP-5.
01 ACC             PIC S9(18) COMP-5.
01 TMP             PIC S9(18) COMP-5.
01 MI              PIC S9(9) COMP-5.
01 WI              PIC S9(9) COMP-5.
01 LI              PIC S9(9) COMP-5.
01 LJ              PIC S9(9) COMP-5.
01 LT              PIC S9(9) COMP-5.
01 N-T             PIC S9(9) COMP-5.
01 HD              PIC S9(9) COMP-5.
01 LYR             PIC S9(9) COMP-5.
01 KVH             PIC S9(9) COMP-5.
01 RP              PIC S9(9) COMP-5.
01 RA              PIC S9(9) COMP-5.
01 RC              PIC S9(9) COMP-5.
01 RS              PIC S9(9) COMP-5.
01 V0              PIC S9(9) COMP-5.
01 V1              PIC S9(9) COMP-5.

*> ---- generation state -------------------------------------------
01 G-POS           PIC S9(9) COMP-5.
01 G-TOKEN         PIC S9(9) COMP-5.
01 G-NEXT          PIC S9(9) COMP-5.

*> ---- tokenizer --------------------------------------------------
*> the file is read in one go (each CBL_READ_FILE is a system call,
*> very slow on some filesystems) and then split up in memory
78 MAX-TOKFILE     VALUE 2000000.
01 TOK-BUF         PIC X(MAX-TOKFILE).
01 TOK-SIZE        PIC X(8) COMP-X.
01 TOK-P           PIC S9(9) COMP-5.
01 B4              PIC X(4).
01 B4-F REDEFINES B4 COMP-1.
01 B4-I REDEFINES B4 PIC S9(9) COMP-5.
01 MAX-TOK-LEN     PIC S9(9) COMP-5.
01 VOCAB-TAB.
   05 VOC-ENTRY    OCCURS MAX-VOCAB TIMES.
      10 VOC-STR   PIC X(32).
      10 VOC-LEN   PIC S9(4) COMP-5.
      10 VOC-SCORE COMP-1.
*> sorted copy of the vocabulary for binary search (SEARCH ALL)
01 SORTED-TAB.
   05 SV-ENTRY     OCCURS 1 TO MAX-VOCAB TIMES DEPENDING ON N-VOCAB
                   ASCENDING KEY IS SV-STR
                   INDEXED BY SVX.
      10 SV-STR    PIC X(32).
      10 SV-ID     PIC S9(9) COMP-5.
01 LK-KEY          PIC X(32).
01 FOUND-ID        PIC S9(9) COMP-5.
01 N-ENC           PIC S9(9) COMP-5.
01 ENC-TAB.
   05 ENC-TOK      PIC S9(9) COMP-5 OCCURS MAX-ENC TIMES.
01 E-I             PIC S9(9) COMP-5.
01 E-BYTE          PIC S9(4) COMP-5.
01 E-NEXT-BYTE     PIC S9(4) COMP-5.
01 E-BUF           PIC X(8).
01 E-BUFLEN        PIC S9(4) COMP-5.
01 E-A             PIC S9(9) COMP-5.
01 E-B             PIC S9(9) COMP-5.
01 E-LA            PIC S9(4) COMP-5.
01 E-LB            PIC S9(4) COMP-5.
01 BEST-SCORE      COMP-2.
01 BEST-ID         PIC S9(9) COMP-5.
01 BEST-IDX        PIC S9(9) COMP-5.
01 D-START         PIC S9(4) COMP-5.
01 D-LEN           PIC S9(4) COMP-5.
01 D-PIECE         PIC X(32).
01 D-BYTE          PIC S9(4) COMP-5.
01 HEX-DIGITS      PIC X(16) VALUE "0123456789ABCDEF".
01 HEX-CH          PIC X.
01 HEX-VAL         PIC S9(4) COMP-5.
01 HEX-K           PIC S9(4) COMP-5.

*> ---- sampling ---------------------------------------------------
*> integer (unnormalized) probabilities from the exp table
01 PROB-TAB.
   05 PROB         PIC S9(9) COMP-5 OCCURS MAX-VOCAB TIMES.
01 PI-COUNT        PIC S9(9) COMP-5 VALUE 1.
01 PI-TAB.
   05 PI-ENTRY     OCCURS 1 TO MAX-VOCAB TIMES DEPENDING ON PI-COUNT.
      10 PI-PROB   PIC S9(9) COMP-5.
      10 PI-IDX    PIC S9(9) COMP-5.
01 L-MAX           PIC S9(9) COMP-5.
01 INV-TEMP        PIC S9(18) COMP-5.
01 P-SUM           PIC S9(18) COMP-5.
01 P-CDF           PIC S9(18) COMP-5.
01 P-CUTOFF        PIC S9(18) COMP-5.
01 P-TARGET        PIC S9(18) COMP-5.
01 P-COIN          COMP-2.
01 P-LAST          PIC S9(9) COMP-5.

*> ---- timer ------------------------------------------------------
01 CUR-DT.
   05 CD-DATE      PIC 9(8).
   05 CD-HH        PIC 99.
   05 CD-MI        PIC 99.
   05 CD-SS        PIC 99.
   05 CD-HS        PIC 99.
   05 FILLER       PIC X(5).
01 NOW-S           COMP-2.
01 T-START         COMP-2 VALUE 0.
01 T-STARTED       PIC 9 VALUE 0.
01 TOK-S           PIC Z(6)9.99.

PROCEDURE DIVISION.
MAIN.
    PERFORM PARSE-ARGS
    PERFORM INIT-POW2
    PERFORM LOAD-CHECKPOINT
    PERFORM LOAD-TOKENIZER
    PERFORM INIT-STATE
    PERFORM RUN-GENERATION
    STOP RUN.

*> ==================================================================
*>  COMMAND LINE
*> ==================================================================
PARSE-ARGS.
    ACCEPT ARG-COUNT FROM ARGUMENT-NUMBER
    IF ARG-COUNT < 1
        PERFORM SHOW-USAGE
    END-IF
    ACCEPT CKPT-PATH FROM ARGUMENT-VALUE
    MOVE 2 TO ARG-IDX
    PERFORM UNTIL ARG-IDX > ARG-COUNT
        ACCEPT ARG-FLAG FROM ARGUMENT-VALUE
        ADD 1 TO ARG-IDX
        IF ARG-IDX > ARG-COUNT
            PERFORM SHOW-USAGE
        END-IF
        MOVE SPACES TO ARG-VAL
        ACCEPT ARG-VAL FROM ARGUMENT-VALUE
        ADD 1 TO ARG-IDX
        EVALUATE ARG-FLAG
            WHEN "-t" COMPUTE TEMPERATURE = FUNCTION NUMVAL(ARG-VAL)
            WHEN "-p" COMPUTE TOPP = FUNCTION NUMVAL(ARG-VAL)
            WHEN "-s" COMPUTE RNG-SEED = FUNCTION NUMVAL(ARG-VAL)
            WHEN "-n" COMPUTE STEPS = FUNCTION NUMVAL(ARG-VAL)
            WHEN "-i" MOVE ARG-VAL TO PROMPT-TXT
            WHEN "-z" MOVE ARG-VAL TO TOK-PATH
            WHEN OTHER PERFORM SHOW-USAGE
        END-EVALUATE
    END-PERFORM
    IF TEMPERATURE < 0
        MOVE 0 TO TEMPERATURE
    END-IF
    IF TOPP < 0 OR TOPP > 1
        MOVE 0.9 TO TOPP
    END-IF
    IF STEPS < 0
        MOVE 0 TO STEPS
    END-IF
    *> prompt length without the trailing padding spaces
    MOVE 1024 TO PROMPT-LEN
    PERFORM UNTIL PROMPT-LEN = 0
               OR PROMPT-TXT(PROMPT-LEN:1) NOT = SPACE
        SUBTRACT 1 FROM PROMPT-LEN
    END-PERFORM.

SHOW-USAGE.
    DISPLAY "Usage:   llama2 <checkpoint> [options]" UPON SYSERR
    DISPLAY "Example: llama2 model.bin -n 256 -i ""Once upon a time"""
        UPON SYSERR
    DISPLAY "Options:" UPON SYSERR
    DISPLAY "  -t <float>  temperature in [0,inf], default 1.0" UPON SYSERR
    DISPLAY "  -p <float>  top-p in [0,1], default 0.9" UPON SYSERR
    DISPLAY "  -s <int>    random seed, default clock" UPON SYSERR
    DISPLAY "  -n <int>    steps to generate, default 256" UPON SYSERR
    DISPLAY "  -i <text>   prompt" UPON SYSERR
    DISPLAY "  -z <file>   tokenizer, default tokenizer.bin" UPON SYSERR
    STOP RUN RETURNING 1.

*> P2(k + 1) = 2^k, for native shifts
INIT-POW2.
    SET P2(1) TO 1
    PERFORM VARYING LI FROM 2 BY 1 UNTIL LI > 31
        SET P2(LI) TO P2(LI - 1)
        MULTIPLY 2 BY P2(LI)
    END-PERFORM.

*> ==================================================================
*>  CHECKPOINT LOADING: header + float weights -> Q16
*> ==================================================================
LOAD-CHECKPOINT.
    CALL "CBL_OPEN_FILE" USING CKPT-PATH F-ACCESS F-DENY F-DEVICE F-HANDLE
    IF RETURN-CODE NOT = 0
        DISPLAY "Cannot open " FUNCTION TRIM(CKPT-PATH) UPON SYSERR
        STOP RUN RETURNING 1
    END-IF
    MOVE 0 TO F-OFFSET
    MOVE 28 TO F-NBYTES
    CALL "CBL_READ_FILE" USING F-HANDLE F-OFFSET F-NBYTES F-FLAGS CFG-HEADER

    *> negative vocab_size = classifier separate from the embeddings
    IF HDR-VOCAB > 0
        MOVE 1 TO SHARED-W
        MOVE HDR-VOCAB TO N-VOCAB
    ELSE
        MOVE 0 TO SHARED-W
        COMPUTE N-VOCAB = 0 - HDR-VOCAB
    END-IF
    COMPUTE HS = DIM / N-HEADS
    COMPUTE HS2 = HS / 2
    COMPUTE KVD = DIM * N-KVH / N-HEADS
    COMPUTE KVMUL = N-HEADS / N-KVH

    IF N-VOCAB > MAX-VOCAB OR SEQ-LEN > MAX-SEQ
       OR SEQ-LEN * HS2 > MAX-ROPE
       OR DIM > MAX-N OR HID > MAX-N
       OR N-LAYERS * SEQ-LEN * KVD > MAX-KV
       OR N-LAYERS * SEQ-LEN * N-KVH > MAX-KVROWS
        DISPLAY "Model too large for the LLAMA2 tables"
            UPON SYSERR
        STOP RUN RETURNING 1
    END-IF

    *> tensor offsets, in the same order as memory_map_weights()
    MOVE 1 TO O-EMB
    COMPUTE O-RMSATT = O-EMB    + N-VOCAB * DIM
    COMPUTE O-WQ     = O-RMSATT + N-LAYERS * DIM
    COMPUTE O-WK     = O-WQ     + N-LAYERS * DIM * DIM
    COMPUTE O-WV     = O-WK     + N-LAYERS * DIM * KVD
    COMPUTE O-WO     = O-WV     + N-LAYERS * DIM * KVD
    COMPUTE O-RMSFFN = O-WO     + N-LAYERS * DIM * DIM
    COMPUTE O-W1     = O-RMSFFN + N-LAYERS * DIM
    COMPUTE O-W2     = O-W1     + N-LAYERS * DIM * HID
    COMPUTE O-W3     = O-W2     + N-LAYERS * HID * DIM
    COMPUTE O-RMSFIN = O-W3     + N-LAYERS * DIM * HID
    *> after rms_final come the old freq_cis tables (unused)
    COMPUTE N-FLOATS = O-RMSFIN - 1 + DIM + SEQ-LEN * HS
    IF SHARED-W = 1
        MOVE O-EMB TO O-WCLS
    ELSE
        COMPUTE O-WCLS = N-FLOATS + 1
        COMPUTE N-FLOATS = N-FLOATS + N-VOCAB * DIM
    END-IF
    IF N-FLOATS > MAX-W
        DISPLAY "Too many weights: " N-FLOATS UPON SYSERR
        STOP RUN RETURNING 1
    END-IF

    *> reads the floats in chunks and converts them to Q16 by decoding
    *> the IEEE-754 bits by hand: no floating-point arithmetic
    MOVE 28 TO F-OFFSET
    MOVE 0 TO F-DONE
    PERFORM UNTIL F-DONE >= N-FLOATS
        COMPUTE F-CHUNK = FUNCTION MIN(CHUNK-FLOATS, N-FLOATS - F-DONE)
        COMPUTE F-NBYTES = F-CHUNK * 4
        CALL "CBL_READ_FILE" USING F-HANDLE F-OFFSET F-NBYTES F-FLAGS F-BUF
        IF RETURN-CODE NOT = 0
            DISPLAY "Truncated checkpoint" UPON SYSERR
            STOP RUN RETURNING 1
        END-IF
        SET IWI TO F-DONE
        SET IWI UP BY 1
        PERFORM VARYING LI FROM 1 BY 1 UNTIL LI > F-CHUNK
            SET IB TO F-BUF-I(LI)
            PERFORM FLOAT-TO-Q16
            SET WQ(IWI) TO IV
            SET IWI UP BY 1
        END-PERFORM
        ADD F-CHUNK TO F-DONE
        ADD F-NBYTES TO F-OFFSET
    END-PERFORM
    CALL "CBL_CLOSE_FILE" USING F-HANDLE
    PERFORM COMPUTE-LIMITS
    PERFORM QUANTIZE-WEIGHTS.

*> ------------------------------------------------------------------
*>  COMPUTE-LIMITS: the quantization limits for each length n
*> ------------------------------------------------------------------
COMPUTE-LIMITS.
    MOVE DIM TO SB-N
    PERFORM SPLIT-BITS
    MOVE SB-A TO WLIM-D
    MOVE SB-B TO XLIM-D
    *> for RMSNORM's sum of squares: (RLIM+1)^2 * dim < 2^31
    COMPUTE RLIM = SB-A / 2
    MOVE HID TO SB-N
    PERFORM SPLIT-BITS
    MOVE SB-A TO WLIM-H
    MOVE SB-B TO XLIM-H
    MOVE HS TO SB-N
    PERFORM SPLIT-BITS
    MOVE SB-A TO KLIM
    MOVE SB-B TO QLIM
    *> k ends up in 16-bit fields
    IF KLIM > 32766
        MOVE 32766 TO KLIM
    END-IF.

*> SB-A = 2^k - 1 for the largest k such that 4^k * n < 2^31,
*> SB-B = what is left for the other factor, with a margin of 1
*> for FIND-SHIFT's rounding
SPLIT-BITS.
    MOVE 1 TO SB-P
    PERFORM UNTIL SB-P * SB-P * 4 * SB-N > 2147483647
        COMPUTE SB-P = SB-P * 2
    END-PERFORM
    COMPUTE SB-A = SB-P - 1
    COMPUTE SB-B = 2147483647 / (SB-P * SB-N) - 2.

*> ------------------------------------------------------------------
*>  FLOAT-TO-Q16: 32-bit IEEE-754 bits in IB -> Q16 value in IV.
*>  sign (1 bit) | exponent (8 bits) | mantissa (23 bits)
*> ------------------------------------------------------------------
FLOAT-TO-Q16.
    SET INEG TO 0
    IF IB < 0
        *> drop the sign bit: IB + 2^31, without overflowing
        SET INEG TO 1
        ADD 2147483647 TO IB
        ADD 1 TO IB
    END-IF
    SET IEXP TO IB
    DIVIDE 8388608 INTO IEXP
    SET IV TO IEXP
    MULTIPLY 8388608 BY IV
    SET IM TO IB
    SUBTRACT IV FROM IM
    IF IEXP = 0
        *> zero (or denormal, negligible in Q16 anyway)
        SET IV TO 0
    ELSE
        *> value = (2^23 + mantissa) * 2^(exponent - 127 - 23 + 16)
        ADD 8388608 TO IM
        SET IV TO IM
        SET ISH TO IEXP
        SUBTRACT 134 FROM ISH
        IF ISH < -30
            SET IV TO 0
        ELSE
            PERFORM APPLY-SHIFT
        END-IF
        IF INEG = 1
            SET IT TO 0
            SUBTRACT IV FROM IT
            SET IV TO IT
        END-IF
    END-IF.

*> ------------------------------------------------------------------
*>  QUANTIZE-WEIGHTS: every row of every matrix becomes small integers
*>  (|MQ| <= WLIM+1) with one exponent per row: weight_Q16 = MQ * 2^ER
*> ------------------------------------------------------------------
QUANTIZE-WEIGHTS.
    MOVE 1 TO N-ROWS
    MOVE WLIM-D TO QT-LIM
    MOVE N-ROWS TO RB-WQ
    MOVE O-WQ TO QT-OFF
    COMPUTE QT-ROWS = N-LAYERS * DIM
    MOVE DIM TO QT-N
    PERFORM QUANT-TENSOR

    MOVE N-ROWS TO RB-WK
    MOVE O-WK TO QT-OFF
    COMPUTE QT-ROWS = N-LAYERS * KVD
    PERFORM QUANT-TENSOR

    MOVE N-ROWS TO RB-WV
    MOVE O-WV TO QT-OFF
    PERFORM QUANT-TENSOR

    MOVE N-ROWS TO RB-WO
    MOVE O-WO TO QT-OFF
    COMPUTE QT-ROWS = N-LAYERS * DIM
    PERFORM QUANT-TENSOR

    MOVE N-ROWS TO RB-W1
    MOVE O-W1 TO QT-OFF
    COMPUTE QT-ROWS = N-LAYERS * HID
    PERFORM QUANT-TENSOR

    MOVE N-ROWS TO RB-W2
    MOVE O-W2 TO QT-OFF
    COMPUTE QT-ROWS = N-LAYERS * DIM
    MOVE HID TO QT-N
    MOVE WLIM-H TO QT-LIM
    PERFORM QUANT-TENSOR

    MOVE N-ROWS TO RB-W3
    MOVE O-W3 TO QT-OFF
    COMPUTE QT-ROWS = N-LAYERS * HID
    MOVE DIM TO QT-N
    MOVE WLIM-D TO QT-LIM
    PERFORM QUANT-TENSOR

    MOVE N-ROWS TO RB-WCLS
    MOVE O-WCLS TO QT-OFF
    MOVE N-VOCAB TO QT-ROWS
    PERFORM QUANT-TENSOR.

QUANT-TENSOR.
    IF N-ROWS + QT-ROWS > MAX-ROWS
        DISPLAY "Too many rows to quantize" UPON SYSERR
        STOP RUN RETURNING 1
    END-IF
    SET IWI TO QT-OFF
    PERFORM QT-ROWS TIMES
        SET IMAX TO 1
        SET IXI TO IWI
        PERFORM QT-N TIMES
            SET IV TO WQ(IXI)
            PERFORM ABS-MAX
            SET IXI UP BY 1
        END-PERFORM
        SET ILIM TO QT-LIM
        PERFORM FIND-SHIFT
        SET ER(N-ROWS) TO IK
        SET ISH TO 0
        SUBTRACT IK FROM ISH
        PERFORM QT-N TIMES
            SET IV TO WQ(IWI)
            PERFORM APPLY-SHIFT
            SET MQ(IWI) TO IV
            SET IWI UP BY 1
        END-PERFORM
        ADD 1 TO N-ROWS
    END-PERFORM.

*> ==================================================================
*>  NATIVE ARITHMETIC: shifts, absolute values, exponentials
*> ==================================================================
*> IV = IV * 2^ISH (negative ISH = rounded division)
APPLY-SHIFT.
    IF ISH > 0
        MULTIPLY P2(ISH + 1) BY IV
    ELSE
        IF ISH < 0
            SET ISR TO 0
            SUBTRACT ISH FROM ISR
            PERFORM RSHIFT
        END-IF
    END-IF.

*> IV = round(IV / 2^ISR), ISR >= 1, rounding half away from zero
RSHIFT.
    IF ISR > 30
        SET IV TO 0
    ELSE
        IF IV >= 0
            ADD P2(ISR) TO IV
        ELSE
            SUBTRACT P2(ISR) FROM IV
        END-IF
        DIVIDE P2(ISR + 1) INTO IV
    END-IF.

*> IMAX = max(IMAX, |IV|)
ABS-MAX.
    IF IV < 0
        SET IA TO 0
        SUBTRACT IV FROM IA
    ELSE
        SET IA TO IV
    END-IF
    IF IA > IMAX
        SET IMAX TO IA
    END-IF.

*> IK = the smallest k (>= -16) such that IMAX / 2^k <= ILIM
FIND-SHIFT.
    SET IK TO 0
    SET IT TO IMAX
    PERFORM UNTIL IT <= ILIM
        DIVIDE 2 INTO IT
        SET IK UP BY 1
    END-PERFORM
    IF IK = 0
        PERFORM UNTIL IK <= -16
            SET IT2 TO IT
            MULTIPLY 2 BY IT2
            IF IT2 > ILIM
                EXIT PERFORM
            END-IF
            SET IT TO IT2
            SET IK DOWN BY 1
        END-PERFORM
    END-IF.

*> IZ = round(IX * IY / 65536), all in 32 bits. The full product
*> would overflow, so each factor is split into high*2^15 + low:
*> x*y/2^16 = xh*yh*2^14 + (xh*yl + xl*yh)/2 + xl*yl/2^16
MUL-Q16.
    SET MSG TO 1
    IF IX < 0
        SET MX TO 0
        SUBTRACT IX FROM MX
        MULTIPLY -1 BY MSG
    ELSE
        SET MX TO IX
    END-IF
    IF IY < 0
        SET MY TO 0
        SUBTRACT IY FROM MY
        MULTIPLY -1 BY MSG
    ELSE
        SET MY TO IY
    END-IF
    SET MXH TO MX
    DIVIDE 32768 INTO MXH
    SET MXL TO MXH
    MULTIPLY 32768 BY MXL
    SUBTRACT MXL FROM MX
    SET MXL TO MX
    SET MYH TO MY
    DIVIDE 32768 INTO MYH
    SET MYL TO MYH
    MULTIPLY 32768 BY MYL
    SUBTRACT MYL FROM MY
    SET MYL TO MY
    *> high term
    SET IZ TO MXH
    MULTIPLY MYH BY IZ
    MULTIPLY 16384 BY IZ
    *> mixed terms: the whole half now, the remainder goes to the low term
    SET MT TO MXH
    MULTIPLY MYL BY MT
    SET MLO TO MXL
    MULTIPLY MYH BY MLO
    ADD MLO TO MT
    SET MLO TO MT
    DIVIDE 2 INTO MT
    ADD MT TO IZ
    MULTIPLY 2 BY MT
    SUBTRACT MT FROM MLO
    MULTIPLY 32768 BY MLO
    *> low term, rounded
    SET MT TO MXL
    MULTIPLY MYL BY MT
    ADD MT TO MLO
    ADD 32768 TO MLO
    DIVIDE 65536 INTO MLO
    ADD MLO TO IZ
    MULTIPLY MSG BY IZ.

*> IE = exp(-IU / 65536) in Q15, with IU >= 0 in Q16
EXP15.
    IF IU >= 1048576
        SET IE TO 0
    ELSE
        SET IH TO IU
        DIVIDE 1024 INTO IH
        SET IL TO IH
        MULTIPLY 1024 BY IL
        SET IE TO IU
        SUBTRACT IL FROM IE
        SET IL TO IE
        SET IE TO EXH(IH + 1)
        MULTIPLY EXL(IL + 1) BY IE
        ADD 16384 TO IE
        DIVIDE 32768 INTO IE
    END-IF.

*> ------------------------------------------------------------------
*>  QUANT-VEC: ACT(QV-IN), QV-N values -> QB(1..QV-N) integers with
*>  |QB| <= ILIM+1 and a shared exponent: value_Q16 = QB * 2^QV-K
*> ------------------------------------------------------------------
QUANT-VEC.
    SET IMAX TO 1
    SET IXI TO QV-IN
    PERFORM QV-N TIMES
        SET IV TO ACT(IXI)
        PERFORM ABS-MAX
        SET IXI UP BY 1
    END-PERFORM
    PERFORM FIND-SHIFT
    SET QV-K TO IK
    SET ISH TO 0
    SUBTRACT IK FROM ISH
    SET IXI TO QV-IN
    SET IWI TO 1
    PERFORM QV-N TIMES
        SET IV TO ACT(IXI)
        PERFORM APPLY-SHIFT
        SET QB(IWI) TO IV
        SET IXI UP BY 1
        SET IWI UP BY 1
    END-PERFORM.

*> ==================================================================
*>  TOKENIZER LOADING
*> ==================================================================
LOAD-TOKENIZER.
    CALL "CBL_OPEN_FILE" USING TOK-PATH F-ACCESS F-DENY F-DEVICE F-HANDLE
    IF RETURN-CODE NOT = 0
        DISPLAY "Cannot open " FUNCTION TRIM(TOK-PATH) UPON SYSERR
        STOP RUN RETURNING 1
    END-IF
    *> flag 128: CBL_READ_FILE returns the file size
    MOVE 0 TO TOK-SIZE
    MOVE 0 TO F-NBYTES
    MOVE 128 TO F-FLAGS
    CALL "CBL_READ_FILE" USING F-HANDLE TOK-SIZE F-NBYTES F-FLAGS TOK-BUF
    MOVE 0 TO F-FLAGS
    IF TOK-SIZE > MAX-TOKFILE
        DISPLAY "Tokenizer too large" UPON SYSERR
        STOP RUN RETURNING 1
    END-IF
    MOVE 0 TO F-OFFSET
    MOVE TOK-SIZE TO F-NBYTES
    CALL "CBL_READ_FILE" USING F-HANDLE F-OFFSET F-NBYTES F-FLAGS TOK-BUF
    CALL "CBL_CLOSE_FILE" USING F-HANDLE

    *> format: max_token_length, then for each token
    *> score (float), length (int), the string's bytes
    MOVE TOK-BUF(1:4) TO B4
    MOVE B4-I TO MAX-TOK-LEN
    MOVE 5 TO TOK-P
    PERFORM VARYING LI FROM 1 BY 1 UNTIL LI > N-VOCAB
        MOVE TOK-BUF(TOK-P:4) TO B4
        MOVE B4-F TO VOC-SCORE(LI)
        MOVE TOK-BUF(TOK-P + 4:4) TO B4
        ADD 8 TO TOK-P
        IF B4-I > 32 OR TOK-P + B4-I - 1 > TOK-SIZE
            DISPLAY "Invalid tokenizer" UPON SYSERR
            STOP RUN RETURNING 1
        END-IF
        *> strings are padded with LOW-VALUES, not spaces,
        *> so " " and "  " stay different tokens
        MOVE LOW-VALUES TO VOC-STR(LI)
        MOVE B4-I TO VOC-LEN(LI)
        IF B4-I > 0
            MOVE TOK-BUF(TOK-P:B4-I) TO VOC-STR(LI)(1:B4-I)
            ADD B4-I TO TOK-P
        END-IF
        MOVE VOC-STR(LI) TO SV-STR(LI)
        COMPUTE SV-ID(LI) = LI - 1
    END-PERFORM
    SORT SV-ENTRY ON ASCENDING KEY SV-STR.

*> ==================================================================
*>  STATE: activation layout, tables, random generator
*> ==================================================================
INIT-STATE.
    MOVE 1 TO A-X
    COMPUTE A-XB  = A-X   + DIM
    COMPUTE A-XB2 = A-XB  + DIM
    COMPUTE A-HB  = A-XB2 + DIM
    COMPUTE A-HB2 = A-HB  + HID
    COMPUTE A-Q   = A-HB2 + HID
    COMPUTE A-QS  = A-Q   + DIM
    COMPUTE A-K   = A-QS  + DIM
    COMPUTE A-V   = A-K   + KVD
    COMPUTE A-LOG = A-V   + KVD
    COMPUTE A-END = A-LOG + N-VOCAB
    IF A-END > MAX-ACT
        DISPLAY "Too many activations" UPON SYSERR
        STOP RUN RETURNING 1
    END-IF

    *> exp tables in Q15. FUNCTION EXP is slow, so only two calls
    *> and then exp(-(k+1)d) = exp(-kd) * exp(-d)
    COMPUTE R-STEP = FUNCTION EXP(-1 / 64)
    MOVE 1 TO R-VAL
    PERFORM VARYING LI FROM 1 BY 1 UNTIL LI > 1025
        COMPUTE TMP ROUNDED = R-VAL * 32768
        SET EXH(LI) TO TMP
        COMPUTE R-VAL = R-VAL * R-STEP
    END-PERFORM
    COMPUTE R-STEP = FUNCTION EXP(-1 / 65536)
    MOVE 1 TO R-VAL
    PERFORM VARYING LI FROM 1 BY 1 UNTIL LI > 1024
        COMPUTE TMP ROUNDED = R-VAL * 32768
        SET EXL(LI) TO TMP
        COMPUTE R-VAL = R-VAL * R-STEP
    END-PERFORM
    COMPUTE INV-SQRT-HS ROUNDED = 65536 / FUNCTION SQRT(HS)
    IF TEMPERATURE > 0
        COMPUTE INV-TEMP ROUNDED = 65536 / TEMPERATURE
    END-IF

    *> RoPE: angle = pos * freq, freq = 1 / 10000^(2i/head_size).
    *> cos and sin of pos*freq by successive rotations by freq:
    *> a single call to COS and SIN per frequency
    PERFORM VARYING LI FROM 0 BY 1 UNTIL LI >= HS2
        COMPUTE FREQ = 1 / (10000 ** (2 * LI / HS))
        COMPUTE R-C1 = FUNCTION COS(FREQ)
        COMPUTE R-S1 = FUNCTION SIN(FREQ)
        MOVE 1 TO R-C
        MOVE 0 TO R-S
        PERFORM VARYING LT FROM 0 BY 1 UNTIL LT >= SEQ-LEN
            COMPUTE RP = LT * HS2 + LI + 1
            COMPUTE ROPE-C(RP) ROUNDED = R-C * 65536
            COMPUTE ROPE-S(RP) ROUNDED = R-S * 65536
            COMPUTE R-VAL = R-C * R-C1 - R-S * R-S1
            COMPUTE R-S = R-S * R-C1 + R-C * R-S1
            MOVE R-VAL TO R-C
        END-PERFORM
    END-PERFORM

    IF STEPS = 0 OR STEPS > SEQ-LEN
        MOVE SEQ-LEN TO STEPS
    END-IF
    IF RNG-SEED = 0
        PERFORM GET-TIME
        COMPUTE RNG-SEED = NOW-S * 100
    END-IF
    COMPUTE P-COIN = FUNCTION RANDOM(RNG-SEED).

*> ==================================================================
*>  GENERATION LOOP
*> ==================================================================
RUN-GENERATION.
    PERFORM ENCODE-PROMPT
    MOVE ENC-TOK(1) TO G-TOKEN
    MOVE 0 TO G-POS
    PERFORM UNTIL G-POS >= STEPS
        PERFORM FORWARD
        IF G-POS < N-ENC - 1
            MOVE ENC-TOK(G-POS + 2) TO G-NEXT
        ELSE
            PERFORM SAMPLE
        END-IF
        ADD 1 TO G-POS
        *> the BOS token (1) delimits sequences
        IF G-NEXT = 1
            EXIT PERFORM
        END-IF
        PERFORM DECODE-PRINT
        MOVE G-NEXT TO G-TOKEN
        IF T-STARTED = 0
            PERFORM GET-TIME
            MOVE NOW-S TO T-START
            MOVE 1 TO T-STARTED
        END-IF
    END-PERFORM
    DISPLAY X"0A" WITH NO ADVANCING
    IF G-POS > 1
        PERFORM GET-TIME
        IF NOW-S > T-START
            COMPUTE TOK-S = (G-POS - 1) / (NOW-S - T-START)
            DISPLAY "achieved tok/s: " FUNCTION TRIM(TOK-S) UPON SYSERR
        END-IF
    END-IF.

GET-TIME.
    MOVE FUNCTION CURRENT-DATE TO CUR-DT
    COMPUTE NOW-S = CD-HH * 3600 + CD-MI * 60 + CD-SS + CD-HS / 100.

*> ==================================================================
*>  FORWARD: one transformer step for token G-TOKEN at G-POS
*> ==================================================================
FORWARD.
    *> token embedding
    COMPUTE WI = O-EMB + G-TOKEN * DIM
    PERFORM VARYING LJ FROM 0 BY 1 UNTIL LJ >= DIM
        MOVE WQ(WI + LJ) TO ACT(A-X + LJ)
    END-PERFORM

    PERFORM VARYING LYR FROM 0 BY 1 UNTIL LYR >= N-LAYERS
        *> --- attention block ---
        MOVE A-XB TO R-OUT
        MOVE A-X TO R-IN
        COMPUTE R-W = O-RMSATT + LYR * DIM
        MOVE DIM TO R-N
        PERFORM RMSNORM

        *> q, k and v all read the same xb: quantize it once
        MOVE A-XB TO QV-IN
        MOVE DIM TO QV-N
        SET ILIM TO XLIM-D
        PERFORM QUANT-VEC

        MOVE A-Q TO M-OUT
        COMPUTE M-W = O-WQ + LYR * DIM * DIM
        COMPUTE M-R = RB-WQ + LYR * DIM
        MOVE DIM TO M-N
        MOVE DIM TO M-D
        PERFORM MATMUL

        MOVE A-K TO M-OUT
        COMPUTE M-W = O-WK + LYR * DIM * KVD
        COMPUTE M-R = RB-WK + LYR * KVD
        MOVE KVD TO M-D
        PERFORM MATMUL

        MOVE A-V TO M-OUT
        COMPUTE M-W = O-WV + LYR * DIM * KVD
        COMPUTE M-R = RB-WV + LYR * KVD
        PERFORM MATMUL

        PERFORM ROPE
        PERFORM STORE-KV
        PERFORM ATTENTION

        MOVE A-XB TO QV-IN
        MOVE DIM TO QV-N
        SET ILIM TO XLIM-D
        PERFORM QUANT-VEC
        MOVE A-XB2 TO M-OUT
        COMPUTE M-W = O-WO + LYR * DIM * DIM
        COMPUTE M-R = RB-WO + LYR * DIM
        MOVE DIM TO M-N
        MOVE DIM TO M-D
        PERFORM MATMUL

        *> residual connection: x += xb2
        PERFORM VARYING LJ FROM 0 BY 1 UNTIL LJ >= DIM
            SET IV TO ACT(A-X + LJ)
            ADD ACT(A-XB2 + LJ) TO IV
            SET ACT(A-X + LJ) TO IV
        END-PERFORM

        *> --- feed-forward block (SwiGLU) ---
        MOVE A-XB TO R-OUT
        MOVE A-X TO R-IN
        COMPUTE R-W = O-RMSFFN + LYR * DIM
        MOVE DIM TO R-N
        PERFORM RMSNORM

        MOVE A-XB TO QV-IN
        MOVE DIM TO QV-N
        SET ILIM TO XLIM-D
        PERFORM QUANT-VEC

        MOVE A-HB TO M-OUT
        COMPUTE M-W = O-W1 + LYR * DIM * HID
        COMPUTE M-R = RB-W1 + LYR * HID
        MOVE DIM TO M-N
        MOVE HID TO M-D
        PERFORM MATMUL

        MOVE A-HB2 TO M-OUT
        COMPUTE M-W = O-W3 + LYR * DIM * HID
        COMPUTE M-R = RB-W3 + LYR * HID
        PERFORM MATMUL

        *> SwiGLU: hb = silu(hb) * hb2, with sigmoid from the table
        PERFORM VARYING LJ FROM 0 BY 1 UNTIL LJ >= HID
            SET IX TO ACT(A-HB + LJ)
            IF IX >= 0
                SET IU TO IX
            ELSE
                SET IU TO 0
                SUBTRACT IX FROM IU
            END-IF
            *> e = exp(-|v|) in Q15; sigmoid in Q15, then Q16
            PERFORM EXP15
            SET IT TO 32768
            ADD IE TO IT
            IF IX >= 0
                SET IY TO 1073741824
            ELSE
                SET IY TO IE
                MULTIPLY 32768 BY IY
            END-IF
            ADD IT TO IY
            SET IT2 TO IT
            DIVIDE 2 INTO IT2
            SUBTRACT IT2 FROM IY
            DIVIDE IT INTO IY
            MULTIPLY 2 BY IY
            PERFORM MUL-Q16
            SET IX TO IZ
            SET IY TO ACT(A-HB2 + LJ)
            PERFORM MUL-Q16
            SET ACT(A-HB + LJ) TO IZ
        END-PERFORM

        MOVE A-HB TO QV-IN
        MOVE HID TO QV-N
        SET ILIM TO XLIM-H
        PERFORM QUANT-VEC
        MOVE A-XB TO M-OUT
        COMPUTE M-W = O-W2 + LYR * DIM * HID
        COMPUTE M-R = RB-W2 + LYR * DIM
        MOVE HID TO M-N
        MOVE DIM TO M-D
        PERFORM MATMUL

        *> residual connection: x += xb
        PERFORM VARYING LJ FROM 0 BY 1 UNTIL LJ >= DIM
            SET IV TO ACT(A-X + LJ)
            ADD ACT(A-XB + LJ) TO IV
            SET ACT(A-X + LJ) TO IV
        END-PERFORM
    END-PERFORM

    *> final rmsnorm and classifier
    MOVE A-X TO R-OUT
    MOVE A-X TO R-IN
    MOVE O-RMSFIN TO R-W
    MOVE DIM TO R-N
    PERFORM RMSNORM

    MOVE A-X TO QV-IN
    MOVE DIM TO QV-N
    SET ILIM TO XLIM-D
    PERFORM QUANT-VEC
    MOVE A-LOG TO M-OUT
    MOVE O-WCLS TO M-W
    MOVE RB-WCLS TO M-R
    MOVE DIM TO M-N
    MOVE N-VOCAB TO M-D
    PERFORM MATMUL.

*> ------------------------------------------------------------------
*>  MATMUL: ACT(M-OUT..) = W(M-D x M-N) * x, with x already in QB.
*>  The inner loop is all USAGE INDEX: GnuCOBOL compiles it to
*>  native C. Weights within WLIM times x within XLIM: the sum fits in 32 bits.
*> ------------------------------------------------------------------
MATMUL.
    SET IWI TO M-W
    SET IR TO M-R
    PERFORM VARYING MI FROM 0 BY 1 UNTIL MI >= M-D
        SET IACC TO 0
        SET IXI TO 1
        PERFORM M-N TIMES
            SET IP TO MQ(IWI)
            MULTIPLY QB(IXI) BY IP
            ADD IP TO IACC
            SET IWI UP BY 1
            SET IXI UP BY 1
        END-PERFORM
        *> back to Q16: IACC * 2^(row_exp + x_exp - 16)
        SET ISH TO ER(IR)
        ADD QV-K TO ISH
        SUBTRACT 16 FROM ISH
        SET IV TO IACC
        PERFORM APPLY-SHIFT
        SET ACT(M-OUT + MI) TO IV
        SET IR UP BY 1
    END-PERFORM.

*> ------------------------------------------------------------------
*>  RMSNORM: ACT(R-OUT..) = W * x / sqrt(mean(x^2) + 1e-5)
*> ------------------------------------------------------------------
RMSNORM.
    *> sum of squares on the quantized integers: x = QB * 2^QV-K
    MOVE R-IN TO QV-IN
    MOVE R-N TO QV-N
    SET ILIM TO RLIM
    PERFORM QUANT-VEC
    SET IACC TO 0
    SET IXI TO 1
    PERFORM R-N TIMES
        SET IP TO QB(IXI)
        MULTIPLY QB(IXI) BY IP
        ADD IP TO IACC
        SET IXI UP BY 1
    END-PERFORM
    *> a single (decimal) square root per vector
    SET ACC TO IACC
    SET R-K TO QV-K
    COMPUTE R-SS = ACC * (2 ** (2 * R-K - 32)) / R-N + 0.00001
    COMPUTE R-SCALE ROUNDED = 65536 / FUNCTION SQRT(R-SS)
    PERFORM VARYING LJ FROM 0 BY 1 UNTIL LJ >= R-N
        SET IX TO ACT(R-IN + LJ)
        SET IY TO R-SCALE
        PERFORM MUL-Q16
        SET IX TO IZ
        SET IY TO WQ(R-W + LJ)
        PERFORM MUL-Q16
        SET ACT(R-OUT + LJ) TO IZ
    END-PERFORM.

*> ------------------------------------------------------------------
*>  ROPE: rotates pairs of q and k by an angle that depends on G-POS
*> ------------------------------------------------------------------
ROPE.
    *> RPI = (i mod head_size) / 2, the frequency index
    MOVE 0 TO RPI
    PERFORM VARYING LI FROM 0 BY 2 UNTIL LI >= DIM
        COMPUTE RP = G-POS * HS2 + RPI + 1
        MOVE ROPE-C(RP) TO RC
        MOVE ROPE-S(RP) TO RS
        COMPUTE RA = A-Q + LI
        PERFORM ROTATE-PAIR
        IF LI < KVD
            COMPUTE RA = A-K + LI
            PERFORM ROTATE-PAIR
        END-IF
        ADD 1 TO RPI
        IF RPI = HS2
            MOVE 0 TO RPI
        END-IF
    END-PERFORM.

*> (v0, v1) -> (v0*cos - v1*sin, v0*sin + v1*cos)
ROTATE-PAIR.
    MOVE ACT(RA) TO V0
    MOVE ACT(RA + 1) TO V1
    SET IX TO V0
    SET IY TO RC
    PERFORM MUL-Q16
    SET IV TO IZ
    SET IX TO V1
    SET IY TO RS
    PERFORM MUL-Q16
    SUBTRACT IZ FROM IV
    SET ACT(RA) TO IV
    SET IX TO V0
    SET IY TO RS
    PERFORM MUL-Q16
    SET IV TO IZ
    SET IX TO V1
    SET IY TO RC
    PERFORM MUL-Q16
    ADD IZ TO IV
    SET ACT(RA + 1) TO IV.

*> ------------------------------------------------------------------
*>  STORE-KV: stores this position's k and v in the cache, quantized
*>  head by head (small integers + exponent)
*> ------------------------------------------------------------------
STORE-KV.
    PERFORM VARYING KVH FROM 0 BY 1 UNTIL KVH >= N-KVH
        COMPUTE KV-ROW = (LYR * SEQ-LEN + G-POS) * N-KVH + KVH
        COMPUTE KV-BASE = KV-ROW * HS
        MOVE HS TO QV-N

        COMPUTE QV-IN = A-K + KVH * HS
        SET ILIM TO KLIM
        PERFORM QUANT-VEC
        SET KE(KV-ROW + 1) TO QV-K
        SET IWI TO KV-BASE
        SET IXI TO 1
        PERFORM HS TIMES
            SET IWI UP BY 1
            SET KQ(IWI) TO QB(IXI)
            SET IXI UP BY 1
        END-PERFORM

        COMPUTE QV-IN = A-V + KVH * HS
        SET ILIM TO VLIM
        PERFORM QUANT-VEC
        SET VE(KV-ROW + 1) TO QV-K
        SET IWI TO KV-BASE
        SET IXI TO 1
        PERFORM HS TIMES
            SET IWI UP BY 1
            SET VQ(IWI) TO QB(IXI)
            SET IXI UP BY 1
        END-PERFORM
    END-PERFORM.

*> ------------------------------------------------------------------
*>  ATTENTION: for each head, softmax(q.k / sqrt(hs)) weights the values.
*>  All the per-position work is in native integers.
*> ------------------------------------------------------------------
ATTENTION.
    *> q / sqrt(head_size), once for all heads
    SET IY TO INV-SQRT-HS
    PERFORM VARYING LJ FROM 0 BY 1 UNTIL LJ >= DIM
        SET IX TO ACT(A-Q + LJ)
        PERFORM MUL-Q16
        SET ACT(A-QS + LJ) TO IZ
    END-PERFORM
    COMPUTE N-T = G-POS + 1

    PERFORM VARYING HD FROM 0 BY 1 UNTIL HD >= N-HEADS
        COMPUTE QV-IN = A-QS + HD * HS
        MOVE HS TO QV-N
        SET ILIM TO QLIM
        PERFORM QUANT-VEC
        *> grouped-query attention: several q heads share one kv head
        COMPUTE KVH = HD / KVMUL
        COMPUTE KV-BASE = LYR * SEQ-LEN * KVD + KVH * HS
        COMPUTE KE-BASE = LYR * SEQ-LEN * N-KVH + KVH + 1

        *> scores: S(t) = q.k(t) in Q16
        SET IKB TO KV-BASE
        SET IEB TO KE-BASE
        SET ITT TO 1
        PERFORM N-T TIMES
            SET IACC TO 0
            SET IWI TO IKB
            SET IXI TO 1
            PERFORM HS TIMES
                SET IWI UP BY 1
                SET IP TO KQ(IWI)
                MULTIPLY QB(IXI) BY IP
                ADD IP TO IACC
                SET IXI UP BY 1
            END-PERFORM
            SET ISH TO KE(IEB)
            ADD QV-K TO ISH
            SUBTRACT 16 FROM ISH
            SET IV TO IACC
            PERFORM APPLY-SHIFT
            SET ATS(ITT) TO IV
            IF ITT = 1 OR IV > IMAXS
                SET IMAXS TO IV
            END-IF
            SET IKB UP BY KVD
            SET IEB UP BY N-KVH
            SET ITT UP BY 1
        END-PERFORM

        *> softmax: e(t) = exp(S(t) - max) in Q15 from the table
        SET ISUM TO 0
        SET ITT TO 1
        PERFORM N-T TIMES
            SET IU TO IMAXS
            SUBTRACT ATS(ITT) FROM IU
            PERFORM EXP15
            SET ATE(ITT) TO IE
            ADD IE TO ISUM
            SET ITT UP BY 1
        END-PERFORM

        *> weights a(t) = e(t) / sum in Q15, and the largest v exponent
        SET IEB TO KE-BASE
        SET ITT TO 1
        SET IVMAX TO -100
        PERFORM N-T TIMES
            SET IV TO ATE(ITT)
            MULTIPLY 32768 BY IV
            DIVIDE ISUM INTO IV
            SET ATE(ITT) TO IV
            IF VE(IEB) > IVMAX
                SET IVMAX TO VE(IEB)
            END-IF
            SET IEB UP BY N-KVH
            SET ITT UP BY 1
        END-PERFORM

        *> align the weights to the shared v exponent: c(t) = a(t) / 2^(max - e_t)
        SET IEB TO KE-BASE
        SET ITT TO 1
        PERFORM N-T TIMES
            SET ISR TO IVMAX
            SUBTRACT VE(IEB) FROM ISR
            IF ISR > 0
                SET IV TO ATE(ITT)
                PERFORM RSHIFT
                SET ATE(ITT) TO IV
            END-IF
            SET IEB UP BY N-KVH
            SET ITT UP BY 1
        END-PERFORM

        *> output: weighted sum of v, brought back to Q16
        SET ISH TO IVMAX
        SUBTRACT 15 FROM ISH
        PERFORM VARYING LI FROM 1 BY 1 UNTIL LI > HS
            SET IACC TO 0
            SET IWI TO KV-BASE
            SET IWI UP BY LI
            SET ITT TO 1
            PERFORM N-T TIMES
                SET IP TO VQ(IWI)
                MULTIPLY ATE(ITT) BY IP
                ADD IP TO IACC
                SET IWI UP BY KVD
                SET ITT UP BY 1
            END-PERFORM
            SET IV TO IACC
            PERFORM APPLY-SHIFT
            SET ACT(A-XB + HD * HS + LI - 1) TO IV
        END-PERFORM
    END-PERFORM.

*> ==================================================================
*>  SAMPLING of the next token from the logits
*> ==================================================================
SAMPLE.
    IF TEMPERATURE = 0
        *> greedy: the token with the highest logit (the integer is enough)
        MOVE 0 TO G-NEXT
        MOVE ACT(A-LOG) TO L-MAX
        PERFORM VARYING LI FROM 1 BY 1 UNTIL LI >= N-VOCAB
            IF ACT(A-LOG + LI) > L-MAX
                MOVE ACT(A-LOG + LI) TO L-MAX
                MOVE LI TO G-NEXT
            END-IF
        END-PERFORM
        EXIT PARAGRAPH
    END-IF

    *> softmax(logit / temperature), all integer: the probabilities
    *> stay unnormalized and are compared against P-SUM
    MOVE ACT(A-LOG) TO L-MAX
    PERFORM VARYING LI FROM 1 BY 1 UNTIL LI >= N-VOCAB
        IF ACT(A-LOG + LI) > L-MAX
            MOVE ACT(A-LOG + LI) TO L-MAX
        END-IF
    END-PERFORM
    *> exp((logit - max) / T) in Q15, native: the sum over 32000
    *> tokens stays below 2^31
    *> (max - logit) / T: Q16 / 64 = Q10, times 1/T in Q10 = Q20, / 16 = Q16
    SET ISUM TO 0
    SET IY TO INV-TEMP
    DIVIDE 64 INTO IY
    PERFORM VARYING LI FROM 0 BY 1 UNTIL LI >= N-VOCAB
        SET IU TO L-MAX
        SUBTRACT ACT(A-LOG + LI) FROM IU
        DIVIDE 64 INTO IU
        MULTIPLY IY BY IU
        DIVIDE 16 INTO IU
        PERFORM EXP15
        SET PROB(LI + 1) TO IE
        ADD IE TO ISUM
    END-PERFORM
    SET P-SUM TO ISUM

    COMPUTE P-COIN = FUNCTION RANDOM
    IF TOPP <= 0 OR TOPP >= 1
        *> sample from the whole distribution
        COMPUTE P-TARGET = P-COIN * P-SUM
        COMPUTE G-NEXT = N-VOCAB - 1
        MOVE 0 TO P-CDF
        PERFORM VARYING LI FROM 1 BY 1 UNTIL LI > N-VOCAB
            ADD PROB(LI) TO P-CDF
            IF P-TARGET < P-CDF
                COMPUTE G-NEXT = LI - 1
                EXIT PERFORM
            END-IF
        END-PERFORM
    ELSE
        *> top-p (nucleus): only the most likely tokens up to a total of TOPP
        COMPUTE P-CUTOFF = (1 - TOPP) / (N-VOCAB - 1) * P-SUM
        SET IT TO P-CUTOFF
        COMPUTE P-TARGET = TOPP * P-SUM
        MOVE N-VOCAB TO PI-COUNT
        MOVE 0 TO LJ
        PERFORM VARYING LI FROM 1 BY 1 UNTIL LI > N-VOCAB
            IF PROB(LI) >= IT
                ADD 1 TO LJ
                MOVE PROB(LI) TO PI-PROB(LJ)
                COMPUTE PI-IDX(LJ) = LI - 1
            END-IF
        END-PERFORM
        MOVE LJ TO PI-COUNT
        SORT PI-ENTRY ON DESCENDING KEY PI-PROB
        MOVE PI-COUNT TO P-LAST
        MOVE 0 TO P-CDF
        PERFORM VARYING LI FROM 1 BY 1 UNTIL LI > PI-COUNT
            ADD PI-PROB(LI) TO P-CDF
            IF P-CDF > P-TARGET
                MOVE LI TO P-LAST
                EXIT PERFORM
            END-IF
        END-PERFORM
        COMPUTE P-TARGET = P-COIN * P-CDF
        MOVE PI-IDX(P-LAST) TO G-NEXT
        MOVE 0 TO P-CDF
        PERFORM VARYING LI FROM 1 BY 1 UNTIL LI > P-LAST
            ADD PI-PROB(LI) TO P-CDF
            IF P-TARGET < P-CDF
                MOVE PI-IDX(LI) TO G-NEXT
                EXIT PERFORM
            END-IF
        END-PERFORM
    END-IF.

*> ==================================================================
*>  TOKENIZER: text -> tokens (BPE with the vocabulary scores)
*> ==================================================================
ENCODE-PROMPT.
    MOVE 1 TO N-ENC
    MOVE 1 TO ENC-TOK(1)
    *> dummy " " prefix, as sentencepiece does
    IF PROMPT-LEN > 0
        MOVE LOW-VALUES TO LK-KEY
        MOVE SPACE TO LK-KEY(1:1)
        PERFORM LOOKUP
        ADD 1 TO N-ENC
        MOVE FOUND-ID TO ENC-TOK(N-ENC)
    END-IF

    *> one token per UTF-8 character (or one token per byte)
    MOVE 0 TO E-BUFLEN
    PERFORM VARYING E-I FROM 1 BY 1 UNTIL E-I > PROMPT-LEN
        COMPUTE E-BYTE = FUNCTION ORD(PROMPT-TXT(E-I:1)) - 1
        IF E-BYTE < 128 OR E-BYTE >= 192
            MOVE 0 TO E-BUFLEN
        END-IF
        ADD 1 TO E-BUFLEN
        MOVE PROMPT-TXT(E-I:1) TO E-BUF(E-BUFLEN:1)
        MOVE 0 TO E-NEXT-BYTE
        IF E-I < PROMPT-LEN
            COMPUTE E-NEXT-BYTE = FUNCTION ORD(PROMPT-TXT(E-I + 1:1)) - 1
        END-IF
        IF NOT (E-NEXT-BYTE >= 128 AND E-NEXT-BYTE < 192
                AND E-BUFLEN < 4)
            PERFORM EMIT-CODEPOINT
        END-IF
    END-PERFORM

    *> repeatedly merge the adjacent pair with the best score
    PERFORM UNTIL EXIT
        COMPUTE BEST-SCORE = -10000000000
        MOVE -1 TO BEST-ID
        MOVE -1 TO BEST-IDX
        PERFORM VARYING E-I FROM 1 BY 1 UNTIL E-I >= N-ENC
            COMPUTE E-A = ENC-TOK(E-I) + 1
            COMPUTE E-B = ENC-TOK(E-I + 1) + 1
            MOVE VOC-LEN(E-A) TO E-LA
            MOVE VOC-LEN(E-B) TO E-LB
            IF E-LA > 0 AND E-LB > 0 AND E-LA + E-LB <= 32
                MOVE LOW-VALUES TO LK-KEY
                MOVE VOC-STR(E-A)(1:E-LA) TO LK-KEY(1:E-LA)
                MOVE VOC-STR(E-B)(1:E-LB) TO LK-KEY(E-LA + 1:E-LB)
                PERFORM LOOKUP
                IF FOUND-ID >= 0
                    IF VOC-SCORE(FOUND-ID + 1) > BEST-SCORE
                        MOVE VOC-SCORE(FOUND-ID + 1) TO BEST-SCORE
                        MOVE FOUND-ID TO BEST-ID
                        MOVE E-I TO BEST-IDX
                    END-IF
                END-IF
            END-IF
        END-PERFORM
        IF BEST-IDX = -1
            EXIT PERFORM
        END-IF
        MOVE BEST-ID TO ENC-TOK(BEST-IDX)
        COMPUTE E-A = BEST-IDX + 1
        PERFORM VARYING E-I FROM E-A BY 1 UNTIL E-I >= N-ENC
            MOVE ENC-TOK(E-I + 1) TO ENC-TOK(E-I)
        END-PERFORM
        SUBTRACT 1 FROM N-ENC
    END-PERFORM.

EMIT-CODEPOINT.
    MOVE LOW-VALUES TO LK-KEY
    MOVE E-BUF(1:E-BUFLEN) TO LK-KEY(1:E-BUFLEN)
    PERFORM LOOKUP
    IF FOUND-ID >= 0
        ADD 1 TO N-ENC
        MOVE FOUND-ID TO ENC-TOK(N-ENC)
    ELSE
        *> byte fallback: tokens 3..258 are the single bytes
        PERFORM VARYING E-A FROM 1 BY 1 UNTIL E-A > E-BUFLEN
            ADD 1 TO N-ENC
            COMPUTE ENC-TOK(N-ENC) = FUNCTION ORD(E-BUF(E-A:1)) - 1 + 3
        END-PERFORM
    END-IF
    MOVE 0 TO E-BUFLEN.

*> binary search in the sorted vocabulary
LOOKUP.
    MOVE -1 TO FOUND-ID
    SEARCH ALL SV-ENTRY
        AT END CONTINUE
        WHEN SV-STR(SVX) = LK-KEY
            MOVE SV-ID(SVX) TO FOUND-ID
    END-SEARCH.

*> ==================================================================
*>  DECODE: token -> printable text
*> ==================================================================
DECODE-PRINT.
    MOVE 1 TO D-START
    MOVE VOC-LEN(G-NEXT + 1) TO D-LEN
    *> after BOS, sentencepiece strips the leading space
    IF G-TOKEN = 1 AND D-LEN > 0
        IF VOC-STR(G-NEXT + 1)(1:1) = SPACE
            MOVE 2 TO D-START
            SUBTRACT 1 FROM D-LEN
        END-IF
    END-IF
    IF D-LEN <= 0
        EXIT PARAGRAPH
    END-IF
    MOVE VOC-STR(G-NEXT + 1)(D-START:D-LEN) TO D-PIECE
    *> tokens like "<0x0A>" stand for a raw byte
    IF D-LEN = 6 AND D-PIECE(1:3) = "<0x" AND D-PIECE(6:1) = ">"
        MOVE D-PIECE(4:1) TO HEX-CH
        PERFORM HEX-DIGIT
        COMPUTE D-BYTE = HEX-VAL * 16
        MOVE D-PIECE(5:1) TO HEX-CH
        PERFORM HEX-DIGIT
        ADD HEX-VAL TO D-BYTE
        MOVE FUNCTION CHAR(D-BYTE + 1) TO D-PIECE(1:1)
        MOVE 1 TO D-LEN
    END-IF
    *> a single byte is printed only if it is printable or whitespace
    IF D-LEN = 1
        COMPUTE D-BYTE = FUNCTION ORD(D-PIECE(1:1)) - 1
        IF NOT ((D-BYTE >= 32 AND D-BYTE <= 126)
                OR (D-BYTE >= 9 AND D-BYTE <= 13))
            EXIT PARAGRAPH
        END-IF
    END-IF
    DISPLAY D-PIECE(1:D-LEN) WITH NO ADVANCING.

HEX-DIGIT.
    MOVE 0 TO HEX-VAL
    PERFORM VARYING HEX-K FROM 1 BY 1 UNTIL HEX-K > 16
        IF HEX-DIGITS(HEX-K:1) = HEX-CH
            COMPUTE HEX-VAL = HEX-K - 1
            EXIT PERFORM
        END-IF
    END-PERFORM.
