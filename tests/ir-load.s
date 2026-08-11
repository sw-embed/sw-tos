_start:
        la      r2,_saved_ir
        lw      ir,0(r2)
_saved_ir:
        .zero   3
