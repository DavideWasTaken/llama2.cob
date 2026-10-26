       >>SOURCE FORMAT FREE
*> ==================================================================
*>  ARITH - what does "acc = acc + w * x" cost in GnuCOBOL?
*>
*>  The same dot product (1000 elements, integer values between
*>  -1000 and 1000) written with different types and statements.
*>  Every variant walks the tables with the same USAGE INDEX
*>  subscript, so only the arithmetic changes. Each variant runs for
*>  at least one second; the result must be the same for all of them.
*>
*>  Part B: cost of single operations (EXP, SQRT, CBL_READ_FILE).
*>
*>  Usage: arith [file [B]]  the file is only used to time
*>                           CBL_READ_FILE (reads its first 4 bytes);
*>                           with B only part B runs
*> ==================================================================
IDENTIFICATION DIVISION.
PROGRAM-ID. ARITH.

DATA DIVISION.
WORKING-STORAGE SECTION.
78 N-ELEM          VALUE 1000.
78 N-OPS-B         VALUE 100.

*> the same data in four representations
01 T-C2.
   05 W2           COMP-2 OCCURS N-ELEM TIMES.
   05 X2           COMP-2 OCCURS N-ELEM TIMES.
01 T-C5.
   05 W5           PIC S9(9) COMP-5 OCCURS N-ELEM TIMES.
   05 X5           PIC S9(9) COMP-5 OCCURS N-ELEM TIMES.
01 T-BL.
   05 WB           BINARY-LONG SIGNED OCCURS N-ELEM TIMES.
   05 XB           BINARY-LONG SIGNED OCCURS N-ELEM TIMES.
01 T-IX.
   05 WX           USAGE INDEX OCCURS N-ELEM TIMES.
   05 XX           USAGE INDEX OCCURS N-ELEM TIMES.

01 ACC-C2          COMP-2.
01 ACC-C5          PIC S9(18) COMP-5.
01 P-C5            PIC S9(18) COMP-5.
01 ACC-BD          BINARY-DOUBLE SIGNED.
01 ACC-IX          USAGE INDEX.
01 P-IX            USAGE INDEX.
01 J               USAGE INDEX.
01 RESULT          PIC S9(18) COMP-5.
01 EXPECTED        PIC S9(18) COMP-5.

*> part B
01 F               COMP-2 VALUE 0.5.
01 G               COMP-2.
01 BIG             PIC S9(18) COMP-5 VALUE 123456789012.
01 R5              PIC S9(9) COMP-5.
01 RX              USAGE INDEX.
01 FILE-PATH       PIC X(256) VALUE SPACES.
01 RUN-MODE        PIC X(8) VALUE SPACES.
01 F-HANDLE        PIC X(4).
01 F-ACCESS        PIC X COMP-X VALUE 1.
01 F-DENY          PIC X COMP-X VALUE 0.
01 F-DEVICE        PIC X COMP-X VALUE 0.
01 F-OFFSET        PIC X(8) COMP-X VALUE 0.
01 F-NBYTES        PIC X(4) COMP-X VALUE 4.
01 F-FLAGS         PIC X COMP-X VALUE 0.
01 F-BUF           PIC X(4).

*> measurement
01 V               PIC 99.
01 V-NAME          PIC X(46).
01 PASS-OPS        PIC 9(9) COMP-5.
01 PASSES          PIC 9(18) COMP-5.
01 K               PIC 9(9) COMP-5.
01 CUR-DT.
   05 FILLER       PIC 9(8).
   05 C-HH         PIC 99.
   05 C-MI         PIC 99.
   05 C-SS         PIC 99.
   05 C-HS         PIC 99.
   05 FILLER       PIC X(5).
01 NOW-S           COMP-2.
01 T0              COMP-2.
01 ELAPSED         COMP-2.
01 NS-OP           COMP-2.
01 SHOW-NS         PIC Z(8)9.99.
01 SHOW-X          PIC Z(6)9.9.
01 SHOW-RES        PIC -(18)9.
01 BASE-NS         COMP-2.
01 STATUS-TXT      PIC X(12).

PROCEDURE DIVISION.
MAIN.
    ACCEPT FILE-PATH FROM ARGUMENT-VALUE
    ACCEPT RUN-MODE FROM ARGUMENT-VALUE
    PERFORM INIT-DATA

    IF RUN-MODE NOT = "B"
        DISPLAY "A. acc = acc + w * x, ns per multiply-add"
        DISPLAY "   (speed relative to COMP-5 + COMPUTE, the recommended form)"
        MOVE N-ELEM TO PASS-OPS
        MOVE 2 TO V
        PERFORM MEASURE
        MOVE NS-OP TO BASE-NS
        PERFORM VARYING V FROM 1 BY 1 UNTIL V > 7
            PERFORM MEASURE
            PERFORM SHOW-A
        END-PERFORM
        DISPLAY " "
    END-IF

    DISPLAY "B. single operations, ns per operation"
    MOVE N-OPS-B TO PASS-OPS
    PERFORM VARYING V FROM 11 BY 1 UNTIL V > 15
        IF V = 15 AND FILE-PATH = SPACES
            DISPLAY "   CBL_READ_FILE: skipped (no file given)"
        ELSE
            PERFORM MEASURE
            MOVE NS-OP TO SHOW-NS
            DISPLAY "   " V-NAME SHOW-NS
        END-IF
    END-PERFORM
    STOP RUN.

*> w = (7j mod 2001) - 1000, x = (13j mod 1999) - 999
INIT-DATA.
    MOVE 0 TO EXPECTED
    PERFORM VARYING K FROM 1 BY 1 UNTIL K > N-ELEM
        COMPUTE W5(K) = FUNCTION MOD(K * 7, 2001) - 1000
        COMPUTE X5(K) = FUNCTION MOD(K * 13, 1999) - 999
        MOVE W5(K) TO W2(K)
        MOVE X5(K) TO X2(K)
        MOVE W5(K) TO WB(K)
        MOVE X5(K) TO XB(K)
        SET WX(K) TO W5(K)
        SET XX(K) TO X5(K)
        COMPUTE EXPECTED = EXPECTED + W5(K) * X5(K)
    END-PERFORM.

*> repeats variant V until at least one second has passed
MEASURE.
    MOVE 0 TO PASSES
    PERFORM GET-TIME
    MOVE NOW-S TO T0
    MOVE 0 TO ELAPSED
    PERFORM UNTIL ELAPSED >= 1
        PERFORM 100 TIMES
            EVALUATE V
                WHEN 1  PERFORM PASS-1
                WHEN 2  PERFORM PASS-2
                WHEN 3  PERFORM PASS-3
                WHEN 4  PERFORM PASS-4
                WHEN 5  PERFORM PASS-5
                WHEN 6  PERFORM PASS-6
                WHEN 7  PERFORM PASS-7
                WHEN 11 PERFORM PASS-11
                WHEN 12 PERFORM PASS-12
                WHEN 13 PERFORM PASS-13
                WHEN 14 PERFORM PASS-14
                WHEN 15 PERFORM PASS-15
            END-EVALUATE
        END-PERFORM
        ADD 100 TO PASSES
        PERFORM GET-TIME
        COMPUTE ELAPSED = NOW-S - T0
    END-PERFORM
    COMPUTE NS-OP = ELAPSED * 1000000000 / (PASSES * PASS-OPS).

SHOW-A.
    MOVE NS-OP TO SHOW-NS
    COMPUTE SHOW-X = BASE-NS / NS-OP
    MOVE RESULT TO SHOW-RES
    IF RESULT = EXPECTED
        MOVE "ok" TO STATUS-TXT
    ELSE
        MOVE "WRONG" TO STATUS-TXT
    END-IF
    DISPLAY "   " V ". " V-NAME SHOW-NS " ns  " SHOW-X "x  "
            FUNCTION TRIM(STATUS-TXT).

GET-TIME.
    MOVE FUNCTION CURRENT-DATE TO CUR-DT
    COMPUTE NOW-S = C-HH * 3600 + C-MI * 60 + C-SS + C-HS / 100.

*> ---- part A: one pass = one 1000-term dot product ---------------
PASS-1.
    MOVE "COMP-2 (float)        + COMPUTE" TO V-NAME
    MOVE 0 TO ACC-C2
    SET J TO 1
    PERFORM N-ELEM TIMES
        COMPUTE ACC-C2 = ACC-C2 + W2(J) * X2(J)
        SET J UP BY 1
    END-PERFORM
    MOVE ACC-C2 TO RESULT.

PASS-2.
    MOVE "COMP-5                + COMPUTE" TO V-NAME
    MOVE 0 TO ACC-C5
    SET J TO 1
    PERFORM N-ELEM TIMES
        COMPUTE ACC-C5 = ACC-C5 + W5(J) * X5(J)
        SET J UP BY 1
    END-PERFORM
    MOVE ACC-C5 TO RESULT.

PASS-3.
    MOVE "COMP-5                + MULTIPLY/ADD" TO V-NAME
    MOVE 0 TO ACC-C5
    SET J TO 1
    PERFORM N-ELEM TIMES
        MULTIPLY W5(J) BY X5(J) GIVING P-C5
        ADD P-C5 TO ACC-C5
        SET J UP BY 1
    END-PERFORM
    MOVE ACC-C5 TO RESULT.

PASS-4.
    MOVE "BINARY-LONG/DOUBLE    + COMPUTE" TO V-NAME
    MOVE 0 TO ACC-BD
    SET J TO 1
    PERFORM N-ELEM TIMES
        COMPUTE ACC-BD = ACC-BD + WB(J) * XB(J)
        SET J UP BY 1
    END-PERFORM
    MOVE ACC-BD TO RESULT.

PASS-5.
    MOVE "USAGE INDEX           + COMPUTE" TO V-NAME
    SET ACC-IX TO 0
    SET J TO 1
    PERFORM N-ELEM TIMES
        COMPUTE ACC-IX = ACC-IX + WX(J) * XX(J)
        SET J UP BY 1
    END-PERFORM
    SET RESULT TO ACC-IX.

PASS-6.
    MOVE "USAGE INDEX           + SET/MULTIPLY/ADD" TO V-NAME
    SET ACC-IX TO 0
    SET J TO 1
    PERFORM N-ELEM TIMES
        SET P-IX TO WX(J)
        MULTIPLY XX(J) BY P-IX
        ADD P-IX TO ACC-IX
        SET J UP BY 1
    END-PERFORM
    SET RESULT TO ACC-IX.

*> the data stays COMP-5: only the fields receiving the result
*> are USAGE INDEX (this is the form llama2.cob uses)
PASS-7.
    MOVE "COMP-5 data, INDEX result + SET/MULT/ADD" TO V-NAME
    SET ACC-IX TO 0
    SET J TO 1
    PERFORM N-ELEM TIMES
        SET P-IX TO W5(J)
        MULTIPLY X5(J) BY P-IX
        ADD P-IX TO ACC-IX
        SET J UP BY 1
    END-PERFORM
    SET RESULT TO ACC-IX.

*> ---- part B: one pass = N-OPS-B operations ----------------------
PASS-11.
    MOVE "FUNCTION EXP (COMP-2)" TO V-NAME
    PERFORM N-OPS-B TIMES
        COMPUTE G = FUNCTION EXP(F)
    END-PERFORM.

PASS-12.
    MOVE "FUNCTION SQRT (COMP-2)" TO V-NAME
    PERFORM N-OPS-B TIMES
        COMPUTE G = FUNCTION SQRT(F)
    END-PERFORM.

PASS-13.
    MOVE "COMPUTE R ROUNDED = BIG / 65536 (COMP-5)" TO V-NAME
    PERFORM N-OPS-B TIMES
        COMPUTE R5 ROUNDED = BIG / 65536
    END-PERFORM.

PASS-14.
    MOVE "DIVIDE 65536 INTO RX (USAGE INDEX)" TO V-NAME
    PERFORM N-OPS-B TIMES
        SET RX TO 123456789
        DIVIDE 65536 INTO RX
    END-PERFORM.

PASS-15.
    MOVE "4-byte CBL_READ_FILE" TO V-NAME
    CALL "CBL_OPEN_FILE" USING FILE-PATH F-ACCESS F-DENY F-DEVICE F-HANDLE
    IF RETURN-CODE NOT = 0
        DISPLAY "cannot open " FUNCTION TRIM(FILE-PATH)
        STOP RUN RETURNING 1
    END-IF
    PERFORM N-OPS-B TIMES
        CALL "CBL_READ_FILE" USING F-HANDLE F-OFFSET F-NBYTES F-FLAGS F-BUF
    END-PERFORM
    CALL "CBL_CLOSE_FILE" USING F-HANDLE.
