; preemption-runway.s -- software-only recovery of COR24's indirect-only IR
;
; A real UART interrupt preempts a non-yielding foreground loop.  The ISR
; saves the complete task state, masks UART interrupts, replaces the task text
; with one-byte `add r0,r1` instructions, and returns through IR with
; r0=TEXT_END and r1=-1.  On reaching TEXT_END, r0 is the exact interrupted
; PC.  The landing handler restores the text and resumes through a dynamically
; patched C7 absolute jump after restoring all task registers and C.

_start:
        la      r0,0xFEEC00
        mov     sp,r0
        la      r0,_uart_isr
        mov     iv,r0

        ; Keep a pristine RAM copy for restoring the temporary runway.
        la      r1,_foreground
        la      r2,_foreground_shadow
_copy_text:
        lbu     r0,0(r1)
        sb      r0,0(r2)
        add     r1,1
        add     r2,1
        la      r0,_foreground_end
        ceq     r0,r1
        brf     _copy_text
        la      r2,_foreground
        jmp     (r2)

_foreground:
        ; Enabling with host input pending guarantees IR points inside this
        ; writable region, at the first not-yet-executed hog instruction.
        la      r2,0xFF0010
        lc      r0,1
        sb      r0,0(r2)
_hog_loop:
        la      r2,_hog_count
        lw      r0,0(r2)
        add     r0,1
        sw      r0,0(r2)
        la      r2,_resumed
        lbu     r1,0(r2)
        ceq     r1,z
        brt     _hog_loop
        la      r2,_report
        jmp     (r2)
_foreground_end:

; The runway falls directly into this landing handler with r0 == original IR.
_runway_landing:
        la      r2,_recovered_pc
        sw      r0,0(r2)

        ; Restore the original task text before any task can execute it.
        la      r1,_foreground_shadow
        la      r2,_foreground
_restore_text:
        lbu     r0,0(r1)
        sb      r0,0(r2)
        add     r1,1
        add     r2,1
        la      r0,_foreground_end
        ceq     r0,r2
        brf     _restore_text

        lc      r0,1
        la      r2,_resumed
        sb      r0,0(r2)

        ; Patch C7's little-endian immediate before restoring task state.
        la      r2,_recovered_pc
        lw      r0,0(r2)
        la      r2,_resume_jump
        sb      r0,1(r2)
        lc      r1,8
        srl     r0,r1
        sb      r0,2(r2)
        srl     r0,r1
        sb      r0,3(r2)

        ; Restore C first; POP does not alter it.  Fall through only after all
        ; visible task state has been restored.
        pop     r0
        clu     z,r0
        pop     fp
        pop     r2
        pop     r1
        pop     r0
_resume_jump:
        .byte   199             ; C7: absolute immediate jump
        .zero   3

_uart_isr:
        push    r0
        push    r1
        push    r2
        push    fp
        mov     r2,c
        push    r2

        ; Acknowledge RX and mask further IRQs before jmp(ir) clears INTIS.
        la      r2,0xFF0100
        lbu     r0,0(r2)
        la      r2,0xFF0010
        lc      r0,0
        sb      r0,0(r2)

        ; Every byte in the task's text becomes add r0,r1 (opcode 01).
        la      r2,_foreground
        la      r1,_foreground_end
        lc      r0,1
_fill_runway:
        sb      r0,0(r2)
        add     r2,1
        ceq     r1,r2
        brf     _fill_runway

        la      r0,_foreground_end
        la      r1,0xFFFFFF
        jmp     (ir)

_report:
        ; The recovered address must be within the replaced text and the hog
        ; must have executed again after its transparent resume.
        la      r2,_recovered_pc
        lw      r0,0(r2)
        la      r1,_foreground
        clu     r0,r1
        brt     _fail
        la      r1,_foreground_end
        clu     r0,r1
        brf     _fail
        la      r2,_hog_count
        lw      r0,0(r2)
        ceq     r0,z
        brt     _fail

        lc      r0,80           ; P
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

_recovered_pc:
        .zero   3
_hog_count:
        .zero   3
_resumed:
        .byte   0
_foreground_shadow:
        .zero   64
