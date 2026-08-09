; catalog-spawn.s -- descriptor-sized stack/state spawn proof
;
; Two processes share one resident entry point. Spawn allocates each process a
; descriptor-sized EBR stack and zeroed private state block, then fabricates
; the initial cooperative context expected by the SWTOS scheduler.

_start:
        ; Keep the kernel call stack above the process allocation arena.
        la      r0,0xFEEC00
        mov     sp,r0
        la      r0,_banner
        la      r2,_puts
        jal     r1,(r2)

        la      r0,_launcher_descriptor
        la      r2,_proc_a
        la      r1,_spawn_process
        sw      r2,0(r1)
        la      r2,_spawn_resident
        jal     r1,(r2)
        la      r2,_proc_a
        lc      r0,1
        sw      r0,18(r2)
        lw      r2,36(r2)
        la      r0,_counter_descriptor
        sw      r0,3(r2)        ; process-local descriptor selection
        la      r0,_hello_descriptor
        sw      r0,6(r2)
        la      r0,_clock_descriptor
        sw      r0,9(r2)

        la      r0,_proc_a
        la      r2,_current_proc
        sw      r0,0(r2)
        mov     r2,r0
        lw      r0,9(r2)
        mov     sp,r0
        la      r2,_restore_context
        jmp     (r2)

; Spawn descriptor in r0 into the process selected in _spawn_process.
_spawn_resident:
        push    r1
        la      r1,_spawn_descriptor
        sw      r0,0(r1)

        ; Allocate and zero descriptor-sized process-local state.
        lw      r0,18(r0)       ; PROGRAM_DESC state_words
        la      r2,_alloc_state_words
        jal     r1,(r2)
        la      r2,_spawn_process
        lw      r2,0(r2)
        sw      r0,36(r2)       ; PROC_DESC state pointer

        ; Allocate stack_words and fabricate r0/r1/r2/fp saved context.
        la      r2,_spawn_descriptor
        lw      r2,0(r2)
        lw      r0,15(r2)       ; PROGRAM_DESC stack_words
        la      r2,_alloc_stack_words
        jal     r1,(r2)
        la      r2,_spawn_process
        lw      r2,0(r2)
        lw      r1,36(r2)
        sw      r1,-3(r0)       ; initial r0 = state pointer
        la      r1,_spawn_descriptor
        lw      r1,0(r1)
        lw      r1,6(r1)        ; direct resident entry
        sw      r1,-6(r0)       ; initial r1/PC
        lc      r1,0
        sw      r1,-9(r0)       ; initial r2
        sw      r1,-12(r0)      ; initial fp
        add     r0,-12
        sw      r0,9(r2)        ; saved SP
        la      r1,_spawn_descriptor
        lw      r1,0(r1)
        lw      r0,6(r1)
        sw      r0,12(r2)       ; descriptor PC
        lc      r0,1
        sw      r0,24(r2)       ; PROC_RUNNABLE
        pop     r1
        jmp     (r1)

; TASK_SPAWN(descriptor): callable from PL/SW while task A's frames remain
; live. The first caller materializes process B; later calls are harmless.
        .globl  _TASK_SPAWN
_TASK_SPAWN:
        push    fp
        push    r2
        push    r1
        mov     fp,sp
        la      r2,_second_spawned
        lbu     r0,0(r2)
        ceq     r0,z
        brf     _spawn_second_done
        lc      r0,1
        sb      r0,0(r2)
        la      r2,_proc_b
        la      r1,_spawn_process
        sw      r2,0(r1)
        lw      r0,9(fp)        ; selected PROGRAM_DESC pointer
        la      r2,_spawn_resident
        jal     r1,(r2)
        la      r2,_proc_b
        lc      r0,2
        sw      r0,18(r2)
_spawn_second_done:
        mov     sp,fp
        pop     r1
        pop     r2
        pop     fp
        jmp     (r1)

; Allocate r0 words downward and return the exclusive stack high address.
_alloc_stack_words:
        push    r1
        push    r2
        mov     r1,r0
        add     r0,r1
        add     r0,r1           ; bytes = words * 3
        la      r2,_ebr_next
        lw      r1,0(r2)
        push    r1              ; return old high address
        sub     r1,r0
        sw      r1,0(r2)
        pop     r0
        pop     r2
        pop     r1
        jmp     (r1)

; Allocate r0 words downward, zero them, and return the low base address.
_alloc_state_words:
        push    r1
        push    r2
        la      r2,_zero_remaining
        sw      r0,0(r2)
        mov     r1,r0
        add     r0,r1
        add     r0,r1
        la      r2,_ebr_next
        lw      r1,0(r2)
        sub     r1,r0
        sw      r1,0(r2)
        mov     r0,r1           ; allocated base
        la      r2,_allocated_base
        sw      r0,0(r2)
        mov     r2,r1
_zero_state:
        la      r1,_zero_remaining
        lw      r0,0(r1)
        ceq     r0,z
        brt     _state_done
        lc      r1,0
        sw      r1,0(r2)
        add     r2,3
        add     r0,-1
        la      r1,_zero_remaining
        sw      r0,0(r1)
        bra     _zero_state
_state_done:
        la      r2,_allocated_base
        lw      r0,0(r2)
        pop     r2
        pop     r1
        jmp     (r1)

_yield:
        push    r0
        push    r1
        push    r2
        push    fp
        la      r2,_current_proc
        lw      r2,0(r2)
        mov     r0,sp
        sw      r0,9(r2)
        lbu     r0,18(r2)
        lc      r1,1
        ceq     r0,r1
        brt     _switch_b
        la      r2,_proc_a
        bra     _select_context
_switch_b:
        la      r2,_proc_b
_select_context:
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

; Convert scheduler entry ABI (r0 = state pointer) to a PL/SW argument.
_plsw_launcher_trampoline:
        push    r0
        la      r2,_PLSW_LAUNCHER
        jal     r1,(r2)
        add     sp,3
        la      r2,_halt
        jmp     (r2)

_plsw_counter_trampoline:
        push    r0
        la      r2,_PLSW_COUNTER
        jal     r1,(r2)
        add     sp,3
        la      r2,_halt
        jmp     (r2)

_plsw_hello_trampoline:
        push    r0
        la      r2,_PLSW_HELLO
        jal     r1,(r2)
        add     sp,3
        la      r2,_halt
        jmp     (r2)

_plsw_clock_trampoline:
        push    r0
        la      r2,_PLSW_CLOCK
        jal     r1,(r2)
        add     sp,3
        la      r2,_halt
        jmp     (r2)

; PL/SW-callable cooperative yield.
        .globl  _TASK_YIELD
_TASK_YIELD:
        push    fp
        push    r2
        push    r1
        mov     fp,sp
        la      r2,_yield
        jal     r1,(r2)
        mov     sp,fp
        pop     r1
        pop     r2
        pop     fp
        jmp     (r1)

; TASK_GETCHAR(destination): polled UART input for the scheduled shell.
        .globl  _TASK_GETCHAR
_TASK_GETCHAR:
        push    fp
        push    r2
        push    r1
        mov     fp,sp
_task_getchar_wait:
        la      r2,0xFF0101
        lbu     r0,0(r2)
        lcu     r1,1
        and     r0,r1
        ceq     r0,z
        brt     _task_getchar_wait
        la      r2,0xFF0100
        lbu     r0,0(r2)
        lw      r2,9(fp)
        sb      r0,0(r2)
        mov     sp,fp
        pop     r1
        pop     r2
        pop     fp
        jmp     (r1)

; PL/SW runtime-compatible UART output entry.
        .globl  _UART_PUTCHAR
_UART_PUTCHAR:
        push    fp
        push    r2
        push    r1
        mov     fp,sp
        lw      r0,9(fp)
        la      r2,_putchar
        jal     r1,(r2)
        mov     sp,fp
        pop     r1
        pop     r2
        pop     fp
        jmp     (r1)

; PL/SW compiler runtime helper for positive 24-bit integer division.
        .globl  __plsw_div
__plsw_div:
        push    fp
        push    r2
        push    r1
        mov     fp,sp
        lw      r0,9(fp)
        lw      r1,12(fp)
        lc      r2,0
_plsw_div_loop:
        cls     r0,r1
        brt     _plsw_div_done
        sub     r0,r1
        add     r2,1
        bra     _plsw_div_loop
_plsw_div_done:
        mov     r0,r2
        mov     sp,fp
        pop     r1
        pop     r2
        pop     fp
        jmp     (r1)

        .globl  _TASK_HALT
_TASK_HALT:
        la      r2,_halt
        jmp     (r2)

; TASK_EXIT(): terminate spawned process B, release its slot, and resume shell.
        .globl  _TASK_EXIT
_TASK_EXIT:
        la      r2,_current_proc
        lw      r2,0(r2)
        lbu     r0,18(r2)
        lc      r1,2
        ceq     r0,r1
        brf     _TASK_HALT
        lc      r0,0
        sw      r0,24(r2)       ; PROC_FREE
        la      r2,_second_spawned
        sb      r0,0(r2)
        la      r2,_proc_a
        la      r1,_current_proc
        sw      r2,0(r1)
        lw      r0,9(r2)
        mov     sp,r0
        la      r2,_restore_context
        jmp     (r2)

; TASK_STEP(value): PL/SW callback that reports one step and cooperatively
; yields. Its call frame remains on the process stack across the switch.
        .globl  _TASK_STEP
_TASK_STEP:
        push    fp
        push    r2
        push    r1
        mov     fp,sp
        lw      r0,9(fp)
        push    r0
        la      r2,_current_proc
        lw      r2,0(r2)
        lbu     r0,18(r2)
        add     r0,64
        la      r2,_putchar
        jal     r1,(r2)
        pop     r0
        add     r0,48
        la      r2,_putchar
        jal     r1,(r2)
        lc      r0,10
        la      r2,_putchar
        jal     r1,(r2)

_counter_yield:
        la      r2,_yield
        jal     r1,(r2)
        mov     sp,fp
        pop     r1
        pop     r2
        pop     fp
        jmp     (r1)

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

; PROGRAM_DESC: name, kind, entry, words, entry_off, stack_words,
; state_words, flags.
_launcher_descriptor:
        .word   _launcher_name
        .word   0
        .word   _plsw_launcher_trampoline
        .word   0
        .word   0
        .word   64
        .word   4
        .word   1
_launcher_name:
        .byte   115,104,101,108,108,0
_counter_descriptor:
        .word   _counter_name
        .word   0
        .word   _plsw_counter_trampoline
        .word   0
        .word   0
        .word   64
        .word   2
        .word   1
_counter_name:
        .byte   99,111,117,110,116,101,114,0
_hello_descriptor:
        .word   _hello_name
        .word   0
        .word   _plsw_hello_trampoline
        .word   0
        .word   0
        .word   64
        .word   1
        .word   1
_hello_name:
        .byte   104,101,108,108,111,0
_clock_descriptor:
        .word   _clock_name
        .word   0
        .word   _plsw_clock_trampoline
        .word   0
        .word   0
        .word   96
        .word   1
        .word   3
_clock_name:
        .byte   99,108,111,99,107,0
_proc_a:
        .zero   39
_proc_b:
        .zero   39
_current_proc:
        .zero   3
_spawn_descriptor:
        .zero   3
_spawn_process:
        .zero   3
_zero_remaining:
        .zero   3
_allocated_base:
        .zero   3
_ebr_next:
        .word   0xFEE800
_second_spawned:
        .byte   0
_banner:
        .byte   83,80,65,87,78,10,0
