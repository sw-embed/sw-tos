; Position-independent loaded entry: print E and return to loader trampoline.
_start:
        lc      r0,69
        la      r2,0xFF0100
        sb      r0,0(r2)
        jmp     (r1)
