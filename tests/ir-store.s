_start:
        la      r2,_saved_ir
        sw      ir,0(r2)
_saved_ir:
        .zero   3
