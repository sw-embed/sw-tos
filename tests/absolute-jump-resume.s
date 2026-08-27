; Prove that a dynamically patched absolute jump can resume a task after every
; software-visible register and the condition flag have already been restored.

_start:
        la      r0,0xFEEC00
        mov     sp,r0

        ; Patch the three little-endian immediate bytes following opcode C7.
        la      r0,_resume_target
        la      r2,_resume_jump
        sb      r0,1(r2)
        lc      r1,8
        srl     r0,r1
        sb      r0,2(r2)
        srl     r0,r1
        sb      r0,3(r2)

        ; Establish sentinel task state.  The final CEQ sets C without changing
        ; any register, then execution falls through the patched jump.
        la      r0,0xFEE100
        mov     sp,r0
        mov     fp,sp
        la      r0,0xFEEC00
        mov     sp,r0
        la      r0,0x102030
        la      r1,0x405060
        la      r2,0x708090
        clu     z,r0            ; C = true without changing task registers

_resume_jump:
        .byte   199             ; C7: la ir,imm24 == jmp imm24
        .zero   3

_resume_target:
        ; Snapshot the arrived state before using any task register as scratch.
        push    r0
        push    r1
        push    r2
        push    fp
        mov     r0,c
        push    r0
        mov     fp,sp

        lw      r0,0(fp)
        lc      r1,1
        ceq     r0,r1
        brf     _fail
        lw      r0,3(fp)
        la      r1,0xFEE100
        ceq     r0,r1
        brf     _fail
        lw      r0,6(fp)
        la      r1,0x708090
        ceq     r0,r1
        brf     _fail
        lw      r0,9(fp)
        la      r1,0x405060
        ceq     r0,r1
        brf     _fail
        lw      r0,12(fp)
        la      r1,0x102030
        ceq     r0,r1
        brf     _fail
        mov     r0,sp
        la      r1,0xFEEBF1
        ceq     r0,r1
        brf     _fail

        lc      r0,74           ; J
        la      r2,_putchar
        jal     r1,(r2)
        lc      r0,49           ; 1
        la      r2,_putchar
        jal     r1,(r2)
        lc      r0,10
        la      r2,_putchar
        jal     r1,(r2)
_halt:
        bra     _halt

_fail:
        lc      r0,70           ; F
        la      r2,_putchar
        jal     r1,(r2)
        lc      r0,10
        la      r2,_putchar
        jal     r1,(r2)
        bra     _halt

_putchar:
        push    r1
        push    r2
_putchar_wait:
        la      r2,0xFF0101
        lbu     r1,0(r2)
        lcu     r2,128
        and     r1,r2
        ceq     r1,z
        brf     _putchar_wait
        la      r2,0xFF0100
        sb      r0,0(r2)
        pop     r2
        pop     r1
        jmp     (r1)
