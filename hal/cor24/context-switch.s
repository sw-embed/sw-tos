; context-switch.s -- SWTOS cooperative context-switch smoke test
;
; Each saved context consists of r0, return PC (r1), r2, and fp on the
; task's own stack. The scheduler retains only the saved stack pointer.

_start:
        ; Boot trampoline: establish the kernel stack and prove polled UART.
        la      r0,0xFEEC00
        mov     sp,r0
        la      r0,_boot_banner
        la      r2,_puts
        jal     r1,(r2)

        ; Allocate two 1 KiB stacks from the EBR stack arena.
        la      r2,_alloc_stack
        jal     r1,(r2)
        la      r2,_proc_a
        sw      r0,9(r2)        ; PD_SP
        la      r2,_alloc_stack
        jal     r1,(r2)
        la      r2,_proc_b
        sw      r0,9(r2)        ; PD_SP

        ; Populate the descriptor fields used by the scheduler.
        la      r2,_proc_a
        la      r0,_task_a
        sw      r0,12(r2)       ; PD_PC
        lc      r0,1
        sw      r0,18(r2)       ; PD_ENDPOINT
        sw      r0,24(r2)       ; PD_STATE = PROC_RUNNABLE
        la      r2,_proc_b
        la      r0,_task_b
        sw      r0,12(r2)
        lc      r0,2
        sw      r0,18(r2)
        lc      r0,1
        sw      r0,24(r2)

        ; Build task A's initial context at its allocated stack top.
        la      r2,_proc_a
        lw      r0,9(r2)
        mov     sp,r0
        lc      r0,0
        push    r0              ; saved r0
        lw      r0,12(r2)
        push    r0              ; initial PC in saved r1 slot
        lc      r0,0
        push    r0              ; saved r2
        push    r0              ; saved fp
        mov     r0,sp
        la      r2,_proc_a
        sw      r0,9(r2)

        ; Build task B's initial context in its disjoint stack region.
        la      r2,_proc_b
        lw      r0,9(r2)
        mov     sp,r0
        lc      r0,0
        push    r0
        lw      r0,12(r2)
        push    r0
        lc      r0,0
        push    r0
        push    r0
        mov     r0,sp
        la      r2,_proc_b
        sw      r0,9(r2)

        ; Start task B first so RECEIVE proves its blocking path before A sends.
        la      r0,_proc_b
        la      r2,_current_proc
        sw      r0,0(r2)
        mov     r2,r0
        lw      r0,9(r2)
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

        ; Save SP through the current PL/SW PROC_DESC, then choose the
        ; other descriptor by endpoint.
        la      r2,_current_proc
        lw      r2,0(r2)
        mov     r0,sp
        sw      r0,9(r2)
        lbu     r0,18(r2)
        lc      r1,1
        ceq     r0,r1
        brt     _switch_to_b

_switch_to_a:
        la      r2,_proc_a
        la      r1,_current_proc
        sw      r2,0(r1)
        lw      r0,9(r2)
        mov     sp,r0
        bra     _restore_context

_switch_to_b:
        la      r2,_proc_b
        la      r1,_current_proc
        sw      r2,0(r1)
        lw      r0,9(r2)
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

        ; Build a fixed seven-word TTY_WRITE message.
        la      r2,_ipc_message
        lc      r0,1
        sw      r0,0(r2)        ; MSG_SOURCE = endpoint A
        sw      r0,3(r2)        ; MSG_TYPE = MSG_TTY_WRITE
        la      r2,_task_a_count
        lbu     r0,0(r2)
        la      r2,_ipc_message
        sw      r0,6(r2)        ; MSG_FIELD1 = counter payload

        ; SEND blocks A until B copies and acknowledges the message.
        lc      r0,4            ; PROC_SEND_BLOCK
        la      r2,_proc_a
        sw      r0,24(r2)
        la      r0,_ipc_message
        sw      r0,33(r2)       ; PD_MSGPTR
        lc      r0,1            ; wake blocked receiver
        la      r2,_proc_b
        sw      r0,24(r2)

        la      r0,0x654321
        push    r0
        mov     fp,sp
        la      r0,0x123456
        la      r2,_yield
        jal     r1,(r2)
        la      r2,0x123456
        ceq     r0,r2
        brt     _task_a_r0_ok
        la      r2,_context_failure
        jmp     (r2)
_task_a_r0_ok:
        lw      r0,0(fp)
        la      r1,0x654321
        ceq     r0,r1
        brt     _task_a_fp_ok
        la      r2,_context_failure
        jmp     (r2)
_task_a_fp_ok:
        pop     r2
        bra     _task_a

_task_b:
_task_b_receive:
        ; RECEIVE blocks until endpoint A is waiting in SEND_BLOCK.
        la      r2,_proc_a
        lbu     r0,24(r2)
        lc      r1,4
        ceq     r0,r1
        brt     _task_b_message_ready
        lc      r0,3            ; PROC_RECV_BLOCK
        la      r2,_proc_b
        sw      r0,24(r2)
        la      r2,_yield
        jal     r1,(r2)
        bra     _task_b_receive

_task_b_message_ready:
        ; Kernel copy: sender and receiver do not share the receive buffer.
        la      r1,_ipc_message
        la      r2,_task_b_message
        lw      r0,0(r1)
        sw      r0,0(r2)
        lw      r0,3(r1)
        sw      r0,3(r2)
        lw      r0,6(r1)
        sw      r0,6(r2)
        lw      r0,9(r1)
        sw      r0,9(r2)
        lw      r0,12(r1)
        sw      r0,12(r2)
        lw      r0,15(r1)
        sw      r0,15(r2)
        lw      r0,18(r1)
        sw      r0,18(r2)
        lc      r0,1
        la      r2,_proc_a
        sw      r0,24(r2)       ; acknowledge and wake sender
        la      r2,_proc_b
        sw      r0,24(r2)

        ; TTY service consumes the private copy.
        lc      r0,65           ; A
        la      r2,_putchar
        jal     r1,(r2)
        la      r2,_task_b_message
        lw      r0,6(r2)
        add     r0,48
        la      r2,_putchar
        jal     r1,(r2)
        lc      r0,10
        la      r2,_putchar
        jal     r1,(r2)

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
        la      r2,_task_b
        jmp     (r2)

_context_failure:
        lc      r0,88           ; X
        la      r2,_putchar
        jal     r1,(r2)
        bra     _halt

_puts:
        push    r1
        push    r2
        mov     r2,r0
_puts_loop:
        lbu     r0,0(r2)
        ceq     r0,z
        brt     _puts_done
        push    r2
        la      r2,_putchar
        jal     r1,(r2)
        pop     r2
        add     r2,1
        bra     _puts_loop
_puts_done:
        pop     r2
        pop     r1
        jmp     (r1)

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

; PROC_DESC storage. Layout matches include/swtos.msw (36 bytes each).
_proc_a:
        .zero   36
_proc_b:
        .zero   36
_current_proc:
        .zero   3
_task_a_count:
        .byte   0
_task_b_count:
        .byte   0
_ipc_message:
        .zero   21
_task_b_message:
        .zero   21
_stack_heap_next:
        .word   0xFEEC00
_boot_banner:
        .byte   83,87,84,79,83,32,77,49,10,0
