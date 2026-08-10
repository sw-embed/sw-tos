; catalog-spawn.s -- descriptor-sized stack/state spawn proof
;
; A persistent shell and two child slots share resident entry points. Spawn
; allocates descriptor-sized EBR stacks and zeroed private state blocks, then
; fabricates the initial cooperative contexts expected by the SWTOS scheduler.

_start:
        ; Keep the kernel call stack above the process allocation arena.
        la      r0,0xFEEC00
        mov     sp,r0
        la      r0,_banner
        la      r2,_puts
        jal     r1,(r2)

        la      r0,_scheduled_shell_descriptor
        la      r2,_proc_a
        la      r1,_spawn_process
        sw      r2,0(r1)
        la      r2,_spawn_resident
        jal     r1,(r2)
        la      r2,_proc_a
        lc      r0,1
        sw      r0,18(r2)
        lw      r2,36(r2)
        la      r0,_scheduled_counter_descriptor
        sw      r0,3(r2)        ; process-local descriptor selection
        la      r0,_scheduled_hello_descriptor
        sw      r0,6(r2)
        la      r0,_scheduled_clock_descriptor
        sw      r0,9(r2)

        ; Endpoint identities belong to process-table slots, including FREE
        ; slots, so process inspection remains stable before first spawn.
        la      r2,_proc_b
        lc      r0,2
        sw      r0,18(r2)
        la      r2,_proc_c
        lc      r0,3
        sw      r0,18(r2)

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
        la      r1,_spawn_descriptor
        lw      r1,0(r1)
        sw      r1,33(r2)       ; selected PROGRAM_DESC
        lc      r0,1
        sw      r0,24(r2)       ; PROC_RUNNABLE
        pop     r1
        jmp     (r1)

; TASK_SPAWN(descriptor): allocate the first free child process-table slot.
        .globl  _TASK_SPAWN
_TASK_SPAWN:
        push    fp
        push    r2
        push    r1
        mov     fp,sp
        la      r2,_child_count
        lbu     r0,0(r2)
        ceq     r0,z
        brf     _spawn_have_arena_mark
        la      r2,_ebr_next
        lw      r0,0(r2)
        la      r2,_spawn_arena_mark
        sw      r0,0(r2)       ; app allocations are reclaimed at TASK_EXIT
_spawn_have_arena_mark:
        la      r2,_proc_b
_spawn_find_slot:
        lw      r0,24(r2)
        ceq     r0,z
        brt     _spawn_slot_found
        add     r2,39
        la      r1,_proc_table_end
        mov     r0,r2
        ceq     r0,r1
        brt     _spawn_child_done
        bra     _spawn_find_slot
_spawn_slot_found:
        la      r1,_spawn_process
        sw      r2,0(r1)
        lw      r0,9(fp)        ; selected PROGRAM_DESC pointer
        la      r2,_spawn_resident
        jal     r1,(r2)
        la      r2,_spawn_process
        lw      r2,0(r2)
        la      r1,_proc_b
        mov     r0,r2
        ceq     r0,r1
        brf     _spawn_endpoint_three
        lc      r0,2
        bra     _spawn_set_endpoint
_spawn_endpoint_three:
        lc      r0,3
_spawn_set_endpoint:
        sw      r0,18(r2)
        la      r2,_child_count
        lbu     r0,0(r2)
        add     r0,1
        sb      r0,0(r2)
_spawn_child_done:
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
_scan_runnable:
        add     r2,39
        la      r1,_proc_table_end
        mov     r0,r2
        ceq     r0,r1
        brf     _scan_check_state
        la      r2,_proc_table
_scan_check_state:
        lw      r0,24(r2)
        lc      r1,1
        ceq     r0,r1
        brf     _scan_runnable
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

; Load and call a version 1 embedded entry, then terminate its child process.
; Provider validation has already checked the header and checksum. This first
; catalog bridge supports the fixture's compact (<256-word) text/data lengths.
_embedded_loader_trampoline:
        la      r2,_current_proc
        lw      r2,0(r2)
        lw      r2,33(r2)
        lw      r2,9(r2)        ; descriptor image base
        lbu     r0,11(r2)       ; text_words low byte
        lbu     r1,14(r2)       ; data_words low byte
        add     r0,r1
        mov     r1,r0
        add     r0,r1
        add     r0,r1           ; packed payload bytes
        push    r0
        add     r2,27
        la      r0,_embedded_load_region
_embedded_copy_loop:
        lbu     r1,0(r2)
        sb      r1,0(r0)
        add     r2,1
        add     r0,1
        pop     r1
        add     r1,-1
        push    r1
        push    r0
        mov     r0,r1
        ceq     r0,z
        pop     r0
        brf     _embedded_copy_loop
        pop     r1
        la      r2,_embedded_load_region
        jal     r1,(r2)
        la      r2,_TASK_EXIT
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

; TASK_CATALOG_LIST(): enumerate the generated, zero-terminated descriptor
; table. Each descriptor begins with its NUL-terminated name pointer.
        .globl  _TASK_CATALOG_LIST
_TASK_CATALOG_LIST:
        push    fp
        push    r2
        push    r1
        mov     fp,sp
        la      r2,_scheduled_catalog_table
_task_catalog_list_next:
        lw      r0,0(r2)
        ceq     r0,z
        brt     _task_catalog_list_done
        push    r2
        lw      r0,0(r0)
        la      r2,_puts
        jal     r1,(r2)
        lc      r0,10
        la      r2,_putchar
        jal     r1,(r2)
        pop     r2
        add     r2,3
        bra     _task_catalog_list_next
_task_catalog_list_done:
        mov     sp,fp
        pop     r1
        pop     r2
        pop     fp
        jmp     (r1)

; TASK_PROCESS_LIST(): print every process-table slot as "endpoint state".
        .globl  _TASK_PROCESS_LIST
_TASK_PROCESS_LIST:
        push    fp
        push    r2
        push    r1
        mov     fp,sp
        la      r2,_proc_table
_task_process_list_next:
        lw      r0,18(r2)
        add     r0,48
        push    r2
        la      r2,_putchar
        jal     r1,(r2)
        lc      r0,32
        la      r2,_putchar
        jal     r1,(r2)
        pop     r2
        lw      r0,24(r2)
        ceq     r0,z
        brt     _task_process_list_free
        lc      r1,1
        ceq     r0,r1
        brt     _task_process_list_runnable
        la      r0,_state_unknown
        bra     _task_process_list_state
_task_process_list_free:
        la      r0,_state_free
        bra     _task_process_list_state
_task_process_list_runnable:
        la      r0,_state_runnable
_task_process_list_state:
        push    r2
        la      r2,_puts
        jal     r1,(r2)
        lc      r0,10
        la      r2,_putchar
        jal     r1,(r2)
        pop     r2
        add     r2,39
        la      r1,_proc_table_end
        mov     r0,r2
        ceq     r0,r1
        brf     _task_process_list_next
        mov     sp,fp
        pop     r1
        pop     r2
        pop     fp
        jmp     (r1)

; TASK_CATALOG_FIND(name, result): search generated program descriptors by
; name and write either the matching descriptor pointer or zero to result.
        .globl  _TASK_CATALOG_FIND
_TASK_CATALOG_FIND:
        push    fp
        push    r2
        push    r1
        mov     fp,sp
        lw      r2,12(fp)
        lc      r0,0
        sw      r0,0(r2)
        la      r2,_scheduled_catalog_table
_task_catalog_find_next:
        lw      r0,0(r2)
        ceq     r0,z
        brt     _task_catalog_find_done
        lw      r1,3(r0)       ; IMAGE_PROGRAM kind is zero
        ceq     r1,z
        brt     _task_catalog_find_program
        lc      r0,1           ; embedded executable kind
        ceq     r0,r1
        brf     _task_catalog_find_advance
        lw      r0,0(r2)
_task_catalog_find_program:
        push    r2
        lw      r1,0(r0)       ; descriptor name
        lw      r2,9(fp)       ; requested name
_task_catalog_find_compare:
        push    r1
        lbu     r0,0(r1)
        push    r0
        lbu     r0,0(r2)
        pop     r1
        ceq     r0,r1
        pop     r1
        brf     _task_catalog_find_mismatch
        ceq     r0,z
        brt     _task_catalog_find_match
        add     r1,1
        add     r2,1
        bra     _task_catalog_find_compare
_task_catalog_find_mismatch:
        pop     r2
        bra     _task_catalog_find_advance
_task_catalog_find_match:
        pop     r2
        lw      r0,0(r2)
        lw      r1,12(fp)
        sw      r0,0(r1)
        bra     _task_catalog_find_done
_task_catalog_find_advance:
        add     r2,3
        bra     _task_catalog_find_next
_task_catalog_find_done:
        mov     sp,fp
        pop     r1
        pop     r2
        pop     fp
        jmp     (r1)

; TASK_JOIN(): cooperate until the spawned process exits. TASK_EXIT restores
; the shell inside _yield, after which this loop observes the released slot.
        .globl  _TASK_JOIN
_TASK_JOIN:
        push    fp
        push    r2
        push    r1
        mov     fp,sp
_task_join_wait:
        la      r2,_child_count
        lbu     r0,0(r2)
        ceq     r0,z
        brt     _task_join_done
        la      r2,_yield
        jal     r1,(r2)
        bra     _task_join_wait
_task_join_done:
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

; TASK_EXIT(): terminate a child slot and resume the persistent shell.
        .globl  _TASK_EXIT
_TASK_EXIT:
        la      r2,_current_proc
        lw      r2,0(r2)
        lbu     r0,18(r2)
        lc      r1,1
        ceq     r0,r1
        brt     _TASK_HALT
        lc      r0,0
        sw      r0,24(r2)       ; PROC_FREE
        la      r2,_child_count
        lbu     r0,0(r2)
        add     r0,-1
        sb      r0,0(r2)
        ceq     r0,z
        brf     _task_exit_keep_arena
        ; The last child releases the allocation generation.
        la      r2,_spawn_arena_mark
        lw      r0,0(r2)
        la      r2,_ebr_next
        sw      r0,0(r2)
_task_exit_keep_arena:
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

_proc_table:
_proc_a:
        .zero   39
_proc_b:
        .zero   39
_proc_c:
        .zero   39
_proc_table_end:
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
_spawn_arena_mark:
        .zero   3
_ebr_next:
        .word   0xFEEB00
_child_count:
        .byte   0
_banner:
        .byte   83,80,65,87,78,10,0
_embedded_load_region:
        .zero   64
_state_free:
        .byte   70,82,69,69,0
_state_runnable:
        .byte   82,85,78,78,65,66,76,69,0
_state_unknown:
        .byte   85,78,75,78,79,87,78,0
