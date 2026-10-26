       >>SOURCE FORMAT FREE
*> ==================================================================
*>  OVERFLOW - il prezzo della velocita' di USAGE INDEX.
*>
*>  Un campo USAGE INDEX e' un int C a 32 bit: se sfora, il valore
*>  "gira" in silenzio. Un campo COMP-5 con ON SIZE ERROR invece
*>  segnala l'errore e lascia il valore intatto.
*> ==================================================================
IDENTIFICATION DIVISION.
PROGRAM-ID. OVERFLOW.

DATA DIVISION.
WORKING-STORAGE SECTION.
01 IX              USAGE INDEX.
01 C5              PIC S9(9) COMP-5.
01 C5-BIG          PIC S9(18) COMP-5.
01 SHOW            PIC -(11)9.

PROCEDURE DIVISION.
MAIN.
    DISPLAY "1. USAGE INDEX: 2147483647 + 1"
    SET IX TO 2147483647
    ADD 1 TO IX
        ON SIZE ERROR DISPLAY "   SIZE ERROR segnalato"
        NOT ON SIZE ERROR DISPLAY "   nessun errore segnalato"
    END-ADD
    SET C5-BIG TO IX
    MOVE C5-BIG TO SHOW
    DISPLAY "   risultato: " SHOW

    DISPLAY "2. USAGE INDEX: 50000 * 50000"
    SET IX TO 50000
    MULTIPLY 50000 BY IX
        ON SIZE ERROR DISPLAY "   SIZE ERROR segnalato"
        NOT ON SIZE ERROR DISPLAY "   nessun errore segnalato"
    END-MULTIPLY
    SET C5-BIG TO IX
    MOVE C5-BIG TO SHOW
    DISPLAY "   risultato: " SHOW " (giusto: 2500000000)"

    DISPLAY "3. COMP-5 PIC S9(9): 50000 * 50000"
    MOVE 50000 TO C5
    MULTIPLY 50000 BY C5
        ON SIZE ERROR DISPLAY "   SIZE ERROR segnalato"
        NOT ON SIZE ERROR DISPLAY "   nessun errore segnalato"
    END-MULTIPLY
    MOVE C5 TO SHOW
    DISPLAY "   risultato: " SHOW " (valore precedente conservato)"

    DISPLAY "4. COMP-5: 1 / 0"
    MOVE 1 TO C5
    DIVIDE 0 INTO C5
        ON SIZE ERROR DISPLAY "   SIZE ERROR segnalato"
        NOT ON SIZE ERROR DISPLAY "   nessun errore segnalato"
    END-DIVIDE

    DISPLAY "5. USAGE INDEX: 1 / 0"
    SET IX TO 1
    SET C5 TO 0
    DIVIDE C5 INTO IX
        ON SIZE ERROR DISPLAY "   SIZE ERROR segnalato"
        NOT ON SIZE ERROR DISPLAY "   nessun errore segnalato"
    END-DIVIDE
    DISPLAY "   il programma e' ancora vivo"
    STOP RUN.
