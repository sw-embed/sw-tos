; Test harness for the reusable COR24 protocol decoder.

_start:
        la      r0,0xFEEC00
        mov     sp,r0
_main:
        la      r2,0xFF0101
        lbu     r0,0(r2)
        lc      r1,1
        and     r0,r1
        ceq     r0,z
        brt     _main
        la      r2,0xFF0100
        lbu     r0,0(r2)
        la      r2,_PROTOCOL_CONSUME
        jal     r1,(r2)
        la      r2,_valid_count
        lbu     r0,0(r2)
        lc      r1,3
        ceq     r0,r1
        brf     _main
_halt:
        bra     _halt

_PROTOCOL_FRAME:
        push    r1
        push    r2
        la      r2,_PROTOCOL_RX_TYPE
        lbu     r0,0(r2)
        add     r0,64
        la      r2,_harness_putchar
        jal     r1,(r2)
        la      r2,_PROTOCOL_RX_LENGTH
        lw      r0,0(r2)
        add     r0,48
        la      r2,_harness_putchar
        jal     r1,(r2)
        la      r2,_valid_count
        lbu     r0,0(r2)
        add     r0,1
        sb      r0,0(r2)
        pop     r2
        pop     r1
        jmp     (r1)

_PROTOCOL_ERROR:
        push    r1
        push    r2
        lc      r0,69
        la      r2,_harness_putchar
        jal     r1,(r2)
        pop     r2
        pop     r1
        jmp     (r1)

_harness_putchar:
        push    r1
        push    r2
_harness_putchar_wait:
        la      r2,0xFF0101
        lbu     r1,0(r2)
        lcu     r2,128
        and     r1,r2
        ceq     r1,z
        brf     _harness_putchar_wait
        la      r2,0xFF0100
        sb      r0,0(r2)
        pop     r2
        pop     r1
        jmp     (r1)

_valid_count:
        .byte 0
