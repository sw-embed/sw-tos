; context-switch.s -- SWTOS cooperative context-switch smoke test
;
; Each saved context consists of r0, return PC (r1), r2, and fp on the
; task's own stack. The scheduler retains only the saved stack pointer.

_start:
        ; Allocate two 1 KiB stacks from the EBR stack arena.
        la      r2,_alloc_stack
        jal     r1,(r2)
        la      r2,_task_a_sp
        sw      r0,0(r2)
        la      r2,_alloc_stack
        jal     r1,(r2)
        la      r2,_task_b_sp
        sw      r0,0(r2)

        ; Build task A's initial context at its allocated stack top.
        la      r2,_task_a_sp
        lw      r0,0(r2)
        mov     sp,r0
        lc      r0,0
        push    r0              ; saved r0
        la      r0,_task_a
        push    r0              ; initial PC in saved r1 slot
        lc      r0,0
        push    r0              ; saved r2
        push    r0              ; saved fp
        mov     r0,sp
        la      r2,_task_a_sp
        sw      r0,0(r2)

        ; Build task B's initial context in its disjoint stack region.
        la      r2,_task_b_sp
        lw      r0,0(r2)
        mov     sp,r0
        lc      r0,0
        push    r0
        la      r0,_task_b
        push    r0
        lc      r0,0
        push    r0
        push    r0
        mov     r0,sp
        la      r2,_task_b_sp
        sw      r0,0(r2)

        ; Start task A by restoring its fabricated context.
        lc      r0,0
        la      r2,_current_task
        sb      r0,0(r2)
        la      r2,_task_a_sp
        lw      r0,0(r2)
        mov     sp,r0
        bra     _restore_context

; Allocate a fixed-size stack from the top of the EBR stack arena.
; Returns the new stack's exclusive high address in r0.
_alloc_stack:
        push    r1
        push    r2
        la      r2,_stack_heap_next
        lw      r0,0(r2)
        push    r0
        la      r1,0x000400
        sub     r0,r1
        sw      r0,0(r2)
        pop     r0
        pop     r2
        pop     r1
        jmp     (r1)

; Save the running task and restore the other runnable task.
_yield:
        push    r0
        push    r1
        push    r2
        push    fp

        la      r2,_current_task
        lbu     r0,0(r2)
        ceq     r0,z
        brt     _save_task_a

_save_task_b:
        mov     r0,sp
        la      r2,_task_b_sp
        sw      r0,0(r2)
        lc      r0,0
        la      r2,_current_task
        sb      r0,0(r2)
        la      r2,_task_a_sp
        lw      r0,0(r2)
        mov     sp,r0
        bra     _restore_context

_save_task_a:
        mov     r0,sp
        la      r2,_task_a_sp
        sw      r0,0(r2)
        lc      r0,1
        la      r2,_current_task
        sb      r0,0(r2)
        la      r2,_task_b_sp
        lw      r0,0(r2)
        mov     sp,r0

_restore_context:
        pop     fp
        pop     r2
        pop     r1
        pop     r0
        jmp     (r1)

_task_a:
        la      r2,_task_a_count
        lbu     r0,0(r2)
        add     r0,1
        sb      r0,0(r2)

        lc      r0,65           ; A
        la      r2,_putchar
        jal     r1,(r2)
        la      r2,_task_a_count
        lbu     r0,0(r2)
        add     r0,48
        la      r2,_putchar
        jal     r1,(r2)
        lc      r0,10
        la      r2,_putchar
        jal     r1,(r2)

        la      r0,0x654321
        push    r0
        mov     fp,sp
        la      r0,0x123456
        la      r2,_yield
        jal     r1,(r2)
        la      r2,0x123456
        ceq     r0,r2
        brf     _context_failure
        lw      r0,0(fp)
        la      r1,0x654321
        ceq     r0,r1
        brf     _context_failure
        pop     r2
        bra     _task_a

_task_b:
        la      r2,_task_b_count
        lbu     r0,0(r2)
        add     r0,1
        sb      r0,0(r2)

        lc      r0,66           ; B
        la      r2,_putchar
        jal     r1,(r2)
        la      r2,_task_b_count
        lbu     r0,0(r2)
        add     r0,48
        la      r2,_putchar
        jal     r1,(r2)
        lc      r0,10
        la      r2,_putchar
        jal     r1,(r2)

        la      r2,_task_b_count
        lbu     r0,0(r2)
        lc      r2,3
        ceq     r0,r2
        brt     _halt
        la      r0,0x765432
        push    r0
        mov     fp,sp
        la      r0,0x234567
        la      r2,_yield
        jal     r1,(r2)
        la      r2,0x234567
        ceq     r0,r2
        brf     _context_failure
        lw      r0,0(fp)
        la      r1,0x765432
        ceq     r0,r1
        brf     _context_failure
        pop     r2
        bra     _task_b

_context_failure:
        lc      r0,88           ; X
        la      r2,_putchar
        jal     r1,(r2)
        bra     _halt

; Polled UART output. r0 is the character; r1 is the return address.
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

_halt:
        bra     _halt

_task_a_sp:
        .zero   3
_task_b_sp:
        .zero   3
_current_task:
        .byte   0
_task_a_count:
        .byte   0
_task_b_count:
        .byte   0
_stack_heap_next:
        .word   0xFEEC00
