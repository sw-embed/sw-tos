; catalog-spawn.s -- descriptor-sized stack/state spawn proof
;
; A persistent shell and two child slots share resident entry points. Spawn
; allocates descriptor-sized EBR stacks and zeroed private state blocks, then
; fabricates the initial cooperative contexts expected by the SWTOS scheduler.

_start:
        ; Keep the kernel call stack above the process allocation arena.
        la      r0,0xFEEC00
        mov     sp,r0
        ; Paint the fixed boot/kernel stack reserve before its first use. The
        ; final boot path scans this area to record an observed high-water mark.
        la      r0,0xFEEB01
        la      r1,0x5A5A5A
        la      r2,0xFEEC00
_kernel_stack_fill:
        sw      r1,0(r0)
        add     r0,3
        ceq     r0,r2
        brf     _kernel_stack_fill
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
        la      r0,_scheduled_embedded_hello_descriptor
        sw      r0,12(r2)
        la      r0,_scheduled_uptime_descriptor
        sw      r0,15(r2)

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
        ; Stack grows down from FEEC00. Find the first word changed by boot and
        ; retain the used byte count; later reporting converts it to words.
        la      r0,0xFEEB01
        la      r1,_kernel_stack_scan_cursor
        sw      r0,0(r1)
_kernel_stack_scan:
        la      r1,_kernel_stack_scan_cursor
        lw      r1,0(r1)
        lw      r0,0(r1)
        la      r2,0x5A5A5A
        ceq     r0,r2
        brf     _kernel_stack_found
        add     r1,3
        la      r2,_kernel_stack_scan_cursor
        sw      r1,0(r2)
        la      r2,0xFEEC00
        mov     r0,r1
        ceq     r0,r2
        brf     _kernel_stack_scan
_kernel_stack_found:
        la      r0,_kernel_stack_scan_cursor
        lw      r0,0(r0)
        la      r1,0xFEEC00
        sub     r1,r0
        la      r2,_kernel_stack_peak_bytes
        sw      r1,0(r2)
        la      r0,_proc_a
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

        ; SPI lookup uses one transient descriptor. Snapshot an embedded
        ; descriptor into storage owned by the selected child before any
        ; subsequent lookup can overwrite that transient result.
        lw      r1,3(r0)
        lc      r2,1
        ceq     r1,r2
        brf     _spawn_descriptor_ready
        mov     r1,r0
        la      r2,_spawn_process
        lw      r2,0(r2)
        push    r1
        mov     r0,r2
        la      r1,_proc_b
        ceq     r0,r1
        pop     r1
        brf     _spawn_snapshot_c
        la      r2,_proc_b_image_descriptor
        bra     _spawn_snapshot_copy_start
_spawn_snapshot_c:
        la      r2,_proc_c_image_descriptor
_spawn_snapshot_copy_start:
        lc      r0,24
_spawn_snapshot_copy:
        push    r0
        lbu     r0,0(r1)
        sb      r0,0(r2)
        pop     r0
        add     r1,1
        add     r2,1
        add     r0,-1
        ceq     r0,z
        brf     _spawn_snapshot_copy
        add     r2,-24
        la      r1,_spawn_descriptor
        sw      r2,0(r1)
_spawn_descriptor_ready:

        ; Allocate and zero descriptor-sized process-local state.
        la      r1,_spawn_descriptor
        lw      r0,0(r1)
        lw      r0,18(r0)       ; PROGRAM_DESC state_words
        la      r2,_alloc_state_words
        jal     r1,(r2)
        ceq     r0,z
        brf     _spawn_state_allocated
        la      r2,_spawn_allocation_failed
        jmp     (r2)
_spawn_state_allocated:
        la      r2,_spawn_process
        lw      r2,0(r2)
        sw      r0,36(r2)       ; PROC_DESC state pointer

        ; Embedded descriptors allocate and load private executable memory
        ; inside the same child allocation generation as state and stack.
        la      r1,_spawn_descriptor
        lw      r0,0(r1)
        lw      r1,3(r0)
        lc      r0,1
        ceq     r0,r1
        brf     _spawn_stack
        ; Bind the concrete reader outside PROC_DESC. The load is synchronous,
        ; but each child retains its source for inspection and future dispatch.
        la      r2,_active_image_provider
        lw      r2,0(r2)
        la      r0,_composite_image_provider
        mov     r1,r2
        ceq     r0,r1
        brf     _spawn_provider_direct
        la      r2,_composite_lookup_read
        lw      r0,0(r2)
        bra     _spawn_provider_selected
_spawn_provider_direct:
        lw      r0,3(r2)
_spawn_provider_selected:
        push    r0
        la      r2,_spawn_process
        lw      r1,0(r2)
        la      r2,_proc_b
        mov     r0,r1
        ceq     r0,r2
        pop     r0
        brf     _spawn_provider_slot_c
        la      r2,_proc_b_image_provider
        bra     _spawn_provider_store
_spawn_provider_slot_c:
        la      r2,_proc_c_image_provider
_spawn_provider_store:
        sw      r0,0(r2)
        la      r2,_embedded_bound_read
        sw      r0,0(r2)
        la      r1,_spawn_descriptor
        lw      r0,0(r1)
        la      r2,_load_embedded_process
        jal     r1,(r2)
        ceq     r0,z
        brt     _spawn_stack
        ; No runnable context exists yet, so a failed load can roll the whole
        ; tentative child allocation back to its generation mark.
        la      r2,_spawn_arena_mark
        lw      r0,0(r2)
        la      r2,_ebr_next
        sw      r0,0(r2)
        lc      r0,1
        la      r2,_spawn_status
        sw      r0,0(r2)
        lc      r0,1
        pop     r1
        jmp     (r1)

        ; Allocate stack_words and fabricate r0/r1/r2/fp saved context.
_spawn_stack:
        la      r2,_spawn_descriptor
        lw      r2,0(r2)
        lw      r0,15(r2)       ; PROGRAM_DESC stack_words
        la      r2,_alloc_stack_words
        jal     r1,(r2)
        ceq     r0,z
        brf     _spawn_stack_allocated
        la      r2,_spawn_allocation_failed
        jmp     (r2)
_spawn_stack_allocated:
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
        lc      r0,0            ; spawn resident success
        pop     r1
        jmp     (r1)

_spawn_allocation_failed:
        la      r2,_spawn_process
        lw      r2,0(r2)
        lbu     r0,18(r2)
        lc      r1,1
        ceq     r0,r1
        brf     _spawn_child_allocation_failed
        la      r2,_halt
        jmp     (r2)
_spawn_child_allocation_failed:
        la      r2,_spawn_arena_mark
        lw      r0,0(r2)
        la      r2,_ebr_next
        sw      r0,0(r2)
        lc      r0,3
        la      r2,_spawn_status
        sw      r0,0(r2)
        lc      r0,1
        pop     r1
        jmp     (r1)

; TASK_SPAWN(descriptor): allocate the first free child process-table slot.
        .globl  _TASK_SPAWN
_TASK_SPAWN:
        push    fp
        push    r2
        push    r1
        mov     fp,sp
        lc      r0,0
        la      r2,_spawn_status
        sw      r0,0(r2)
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
        brf     _spawn_find_slot
        lc      r0,2
        la      r2,_spawn_status
        sw      r0,0(r2)
        bra     _spawn_child_done
_spawn_slot_found:
        la      r1,_spawn_process
        sw      r2,0(r1)
        lw      r0,9(fp)        ; selected PROGRAM_DESC pointer
        la      r2,_spawn_resident
        jal     r1,(r2)
        ceq     r0,z
        brf     _spawn_child_done
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

; TASK_SPAWN_RESULT(destination): copy the last spawn status (0 success,
; 1 provider/load failure, 2 no free slot) to PL/SW storage.
        .globl  _TASK_SPAWN_RESULT
_TASK_SPAWN_RESULT:
        push    fp
        push    r2
        push    r1
        mov     fp,sp
        la      r2,_spawn_status
        lw      r0,0(r2)
        lw      r2,9(fp)
        sw      r0,0(r2)
        mov     sp,fp
        pop     r1
        pop     r2
        pop     fp
        jmp     (r1)

; Test assertion for the two-child SPI proof: each live process must retain its
; own descriptor snapshot, and those snapshots must describe distinct extents.
        .globl  _TASK_DESCRIPTOR_SNAPSHOT_VERIFY
_TASK_DESCRIPTOR_SNAPSHOT_VERIFY:
        push    r1
        la      r2,_proc_b
        lw      r0,33(r2)
        la      r1,_proc_b_image_descriptor
        ceq     r0,r1
        brf     _descriptor_snapshot_fail
        la      r2,_proc_c
        lw      r0,33(r2)
        la      r1,_proc_c_image_descriptor
        ceq     r0,r1
        brf     _descriptor_snapshot_fail
        la      r2,_proc_b_image_descriptor
        lw      r0,9(r2)
        la      r2,_proc_c_image_descriptor
        lw      r1,9(r2)
        ceq     r0,r1
        brt     _descriptor_snapshot_fail
        la      r0,_descriptor_snapshot_message
        la      r2,_puts
        jal     r1,(r2)
        pop     r1
        jmp     (r1)
_descriptor_snapshot_fail:
        la      r2,_TASK_HALT
        jmp     (r2)

; Mixed composite proof: slot B must retain the resident Counter descriptor,
; while slot C owns a snapshot of the SD-backed image descriptor.
        .globl  _TASK_MIXED_DESCRIPTOR_VERIFY
_TASK_MIXED_DESCRIPTOR_VERIFY:
        push    r1
        la      r2,_proc_b
        lw      r0,33(r2)
        la      r1,_scheduled_counter_descriptor
        ceq     r0,r1
        brf     _mixed_descriptor_fail
        la      r2,_proc_c
        lw      r0,33(r2)
        la      r1,_proc_c_image_descriptor
        ceq     r0,r1
        brf     _mixed_descriptor_fail
        la      r2,_proc_c_image_descriptor
        lw      r0,3(r2)
        lc      r1,1
        ceq     r0,r1
        brf     _mixed_descriptor_fail
        la      r2,_proc_c_image_provider
        lw      r0,0(r2)
        la      r2,_composite_external_read
        lw      r1,0(r2)
        ceq     r0,r1
        brf     _mixed_descriptor_fail
        la      r0,_mixed_descriptor_message
        la      r2,_puts
        jal     r1,(r2)
        pop     r1
        jmp     (r1)
_mixed_descriptor_fail:
        la      r2,_TASK_HALT
        jmp     (r2)

; Reverse mixed proof: slot B owns the SD snapshot loaded before a later
; resident lookup, and slot C must retain the direct Counter descriptor.
        .globl  _TASK_MIXED_REVERSE_DESCRIPTOR_VERIFY
_TASK_MIXED_REVERSE_DESCRIPTOR_VERIFY:
        push    r1
        la      r2,_proc_b
        lw      r0,33(r2)
        la      r1,_proc_b_image_descriptor
        ceq     r0,r1
        brf     _mixed_reverse_descriptor_fail
        la      r2,_proc_b_image_descriptor
        lw      r0,3(r2)
        lc      r1,1
        ceq     r0,r1
        brf     _mixed_reverse_descriptor_fail
        la      r2,_proc_b_image_provider
        lw      r0,0(r2)
        la      r2,_composite_external_read
        lw      r1,0(r2)
        ceq     r0,r1
        brf     _mixed_reverse_descriptor_fail
        la      r2,_proc_c
        lw      r0,33(r2)
        la      r1,_scheduled_counter_descriptor
        ceq     r0,r1
        brf     _mixed_reverse_descriptor_fail
        la      r0,_mixed_reverse_descriptor_message
        la      r2,_puts
        jal     r1,(r2)
        pop     r1
        jmp     (r1)
_mixed_reverse_descriptor_fail:
        la      r2,_TASK_HALT
        jmp     (r2)

; Test-only fault injection consumed by the next memory-provider read.
        .globl  _TASK_PROVIDER_FAIL_NEXT
_TASK_PROVIDER_FAIL_NEXT:
        la      r2,_provider_fail_next
        lc      r0,1
        sb      r0,0(r2)
        jmp     (r1)

        .globl  _TASK_USE_BLOCK_PROVIDER
_TASK_USE_BLOCK_PROVIDER:
        la      r2,_spi_provider_active
        lc      r0,0
        sb      r0,0(r2)
        la      r2,_active_image_provider
        la      r0,_block_image_provider
        sw      r0,0(r2)
        la      r2,_block_fetch_count
        lc      r0,0
        sw      r0,0(r2)
        jmp     (r1)

        .globl  _TASK_USE_SPI_PROVIDER
_TASK_USE_SPI_PROVIDER:
        push    r1
        la      r2,_SPI_INIT
        jal     r1,(r2)
        la      r2,_spi_provider_active
        lc      r0,1
        sb      r0,0(r2)
        la      r2,_active_image_provider
        la      r0,_spi_image_provider
        sw      r0,0(r2)
        la      r2,_spi_fetch_count
        lc      r0,0
        sw      r0,0(r2)
        la      r2,_spi_cache_hit_count
        sw      r0,0(r2)
        la      r2,_spi_cache_valid
        sb      r0,0(r2)
        pop     r1
        jmp     (r1)

        .globl  _TASK_USE_SD_PROVIDER
_TASK_USE_SD_PROVIDER:
        la      r2,_spi_provider_active
        lc      r0,1
        sb      r0,0(r2)
        la      r2,_active_image_provider
        la      r0,_sd_image_provider
        sw      r0,0(r2)
        la      r2,_sd_cache_valid
        lc      r0,0
        sb      r0,0(r2)
        la      r2,_sd_fetch_count
        sw      r0,0(r2)
        jmp     (r1)

; Resident lookup first, then a link-configured external provider.
_composite_provider_find:
        push    r1
        la      r2,_composite_resident_only
        lc      r0,1
        sb      r0,0(r2)
        la      r2,_memory_provider_find
        jal     r1,(r2)
        la      r2,_composite_resident_only
        lc      r0,0
        sb      r0,0(r2)
        lw      r2,12(fp)
        lw      r0,0(r2)
        ceq     r0,z
        brf     _composite_found_resident
        la      r2,_composite_external_prepare
        lw      r2,0(r2)
        jal     r1,(r2)
        la      r2,_spi_provider_active
        lc      r0,1
        sb      r0,0(r2)
        la      r2,_composite_external_read
        lw      r0,0(r2)
        la      r2,_composite_lookup_read
        sw      r0,0(r2)
        la      r2,_block_provider_find
        jal     r1,(r2)
        bra     _composite_find_done
_composite_found_resident:
        la      r2,_spi_provider_active
        lc      r0,0
        sb      r0,0(r2)
        la      r0,_memory_provider_read
        la      r2,_composite_lookup_read
        sw      r0,0(r2)
_composite_find_done:
        pop     r1
        jmp     (r1)

_composite_provider_read:
        la      r2,_composite_lookup_read
        lw      r2,0(r2)
        jmp     (r2)

_composite_prepare_spi:
        push    r1
        la      r2,_SPI_INIT
        jal     r1,(r2)
        la      r2,_spi_cache_valid
        lc      r0,0
        sb      r0,0(r2)
        pop     r1
        jmp     (r1)

_composite_prepare_sd:
        la      r2,_sd_cache_valid
        lc      r0,0
        sb      r0,0(r2)
        jmp     (r1)

_composite_external_spi_read:
        la      r2,_spi_provider_read
        jmp     (r2)

_composite_external_sd_read:
        la      r2,_sd_provider_read
        jmp     (r2)

        .globl  _TASK_SPI_PROVIDER_VERIFY
_TASK_SPI_PROVIDER_VERIFY:
        push    r1
        la      r2,_spi_fetch_count
        lw      r0,0(r2)
        ceq     r0,z
        brf     _spi_provider_verified
        la      r2,_TASK_HALT
        jmp     (r2)
_spi_provider_verified:
        la      r2,_spi_cache_hit_count
        lw      r0,0(r2)
        ceq     r0,z
        brf     _spi_cache_verified
        la      r2,_TASK_HALT
        jmp     (r2)
_spi_cache_verified:
        la      r2,_active_image_provider
        la      r0,_memory_image_provider
        sw      r0,0(r2)
        la      r2,_spi_provider_active
        lc      r0,0
        sb      r0,0(r2)
        la      r0,_spi_provider_message
        la      r2,_puts
        jal     r1,(r2)
        pop     r1
        jmp     (r1)

; Require at least one host-backed block fetch, report it, and restore the
; default memory provider for subsequent tests and interactive commands.
        .globl  _TASK_BLOCK_PROVIDER_VERIFY
_TASK_BLOCK_PROVIDER_VERIFY:
        push    fp
        push    r2
        push    r1
        mov     fp,sp
        la      r2,_block_fetch_count
        lw      r0,0(r2)
        ceq     r0,z
        brf     _block_provider_verified
        la      r2,_halt
        jmp     (r2)
_block_provider_verified:
        la      r2,_active_image_provider
        la      r0,_memory_image_provider
        sw      r0,0(r2)
        la      r0,_block_provider_message
        la      r2,_puts
        jal     r1,(r2)
        mov     sp,fp
        pop     r1
        pop     r2
        pop     fp
        jmp     (r1)

; Reserve r0 words from the installed EBR arena. Return the low address or
; zero on exhaustion and retain the old high address for stack allocation.
_reserve_words:
        push    r1
        push    r2
        la      r2,_allocation_failed
        lc      r1,0
        sb      r1,0(r2)
        la      r2,_allocation_word_count
        sw      r0,0(r2)
        mov     r1,r0
        add     r0,r1
        add     r0,r1           ; requested bytes = words * 3
        la      r2,_allocation_bytes
        sw      r0,0(r2)
        la      r2,_ebr_next
        lw      r1,0(r2)
        la      r2,_allocation_old_high
        sw      r1,0(r2)
        la      r2,0xFEEB00
        sub     r2,r1           ; current arena bytes
        add     r0,r2           ; proposed arena bytes
        la      r2,2814         ; 938 aligned words within the EBR window
        cls     r2,r0
        brt     _reserve_words_failed
        la      r2,_allocation_peak_bytes
        lw      r1,0(r2)
        cls     r1,r0
        brf     _reserve_words_keep_peak
        sw      r0,0(r2)
_reserve_words_keep_peak:
        la      r2,_allocation_old_high
        lw      r1,0(r2)
        la      r2,_allocation_bytes
        lw      r0,0(r2)
        sub     r1,r0
        la      r2,_ebr_next
        sw      r1,0(r2)
        mov     r0,r1
        bra     _reserve_words_done
_reserve_words_failed:
        la      r2,_allocation_failed
        lc      r1,1
        sb      r1,0(r2)
        la      r2,_allocation_failures
        lw      r0,0(r2)
        add     r0,1
        sw      r0,0(r2)
        lc      r0,0
_reserve_words_done:
        pop     r2
        pop     r1
        jmp     (r1)

; Allocate r0 words downward and return the exclusive stack high address.
_alloc_stack_words:
        push    r1
        push    r2
        la      r2,_reserve_words
        jal     r1,(r2)
        ceq     r0,z
        brt     _alloc_stack_words_done
        la      r2,_allocation_old_high
        lw      r0,0(r2)
_alloc_stack_words_done:
        pop     r2
        pop     r1
        jmp     (r1)

; Allocate r0 words downward, zero them, and return the low base address.
_alloc_state_words:
        push    r1
        push    r2
        la      r2,_zero_remaining
        sw      r0,0(r2)
        la      r2,_reserve_words
        jal     r1,(r2)
        ceq     r0,z
        brt     _state_done
        la      r2,_allocated_base
        sw      r0,0(r2)
        mov     r2,r0
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
        la      r2,_allocation_failed
        lbu     r0,0(r2)
        ceq     r0,z
        brt     _state_return
        lc      r0,0
        bra     _state_return_done
_state_return:
        la      r2,_allocated_base
        lw      r0,0(r2)
_state_return_done:
        pop     r2
        pop     r1
        jmp     (r1)

; Provider read request is staged in kernel scratch so the same two-word
; provider record can later point at a block/SPI implementation.
_image_provider_read:
        push    r1
        push    r2
        la      r2,_embedded_bound_read
        lw      r2,0(r2)
        mov     r0,r2
        ceq     r0,z
        brt     _image_provider_read_active
        jal     r1,(r2)
        bra     _image_provider_read_done
_image_provider_read_active:
        la      r2,_active_image_provider
        lw      r2,0(r2)
        lw      r2,3(r2)       ; IMAGE_PROVIDER read
        jal     r1,(r2)
_image_provider_read_done:
        pop     r2
        pop     r1
        jmp     (r1)

_memory_provider_read:
        push    r1
        push    r2
        lc      r0,0
        la      r2,_provider_status
        sw      r0,0(r2)
        la      r2,_provider_fail_next
        lbu     r0,0(r2)
        ceq     r0,z
        brt     _memory_provider_check_bounds
        lc      r0,0
        sb      r0,0(r2)
        lc      r0,1
        la      r2,_provider_status
        sw      r0,0(r2)
        bra     _memory_provider_read_done
_memory_provider_check_bounds:
        la      r2,_provider_offset
        lw      r0,0(r2)
        la      r2,_provider_count
        lw      r1,0(r2)
        add     r0,r1
        la      r2,_provider_limit
        lw      r1,0(r2)
        ceq     r0,r1
        brt     _memory_provider_read_in_bounds
        cls     r0,r1
        brt     _memory_provider_read_in_bounds
        lc      r0,1
        la      r2,_provider_status
        sw      r0,0(r2)
        bra     _memory_provider_read_done
_memory_provider_read_in_bounds:
        la      r2,_provider_image
        lw      r0,0(r2)
        la      r2,_provider_offset
        lw      r1,0(r2)
        add     r0,r1
        la      r2,_provider_destination
        lw      r2,0(r2)
        la      r1,_provider_count
        lw      r1,0(r1)
_memory_provider_read_loop:
        push    r0
        lbu     r0,0(r0)
        sb      r0,0(r2)
        pop     r0
        add     r0,1
        add     r2,1
        add     r1,-1
        push    r0
        mov     r0,r1
        ceq     r0,z
        pop     r0
        brf     _memory_provider_read_loop
_memory_provider_read_done:
        pop     r2
        pop     r1
        jmp     (r1)

; Eight-byte block adapter backed by the generated, block-padded image bytes.
; It deliberately refills a block for each requested byte in this first proof;
; a physical SPI provider can retain the same contract and add caching later.
_block_provider_read:
        push    r1
        push    r2
        lc      r0,0
        la      r2,_provider_status
        sw      r0,0(r2)
        la      r2,_provider_offset
        lw      r0,0(r2)
        la      r2,_provider_count
        lw      r1,0(r2)
        add     r0,r1
        la      r2,_provider_limit
        lw      r1,0(r2)
        ceq     r0,r1
        brt     _block_provider_in_bounds
        cls     r0,r1
        brt     _block_provider_in_bounds
        lc      r0,1
        la      r2,_provider_status
        sw      r0,0(r2)
        la      r2,_block_provider_done
        jmp     (r2)
_block_provider_in_bounds:
        la      r2,_provider_offset
        lw      r0,0(r2)
        la      r2,_block_cursor
        sw      r0,0(r2)
        la      r2,_provider_count
        lw      r0,0(r2)
        la      r2,_block_remaining
        sw      r0,0(r2)
_block_provider_next_byte:
        ; Divide cursor into an eight-byte block base and within-block offset.
        la      r2,_block_cursor
        lw      r0,0(r2)
        lc      r1,0
_block_provider_divide:
        lc      r2,8
        cls     r0,r2
        brt     _block_provider_fetch
        sub     r0,r2
        add     r1,8
        bra     _block_provider_divide
_block_provider_fetch:
        la      r2,_block_within
        sw      r0,0(r2)
        la      r2,_provider_image
        lw      r0,0(r2)
        add     r0,r1
        la      r2,_block_buffer
        lc      r1,8
_block_provider_fill:
        push    r0
        lbu     r0,0(r0)
        sb      r0,0(r2)
        pop     r0
        add     r0,1
        add     r2,1
        add     r1,-1
        push    r0
        mov     r0,r1
        ceq     r0,z
        pop     r0
        brf     _block_provider_fill
        la      r2,_block_fetch_count
        lw      r0,0(r2)
        add     r0,1
        sw      r0,0(r2)

        la      r2,_block_within
        lw      r1,0(r2)
        la      r0,_block_buffer
        add     r0,r1
        lbu     r0,0(r0)
        la      r2,_provider_destination
        lw      r2,0(r2)
        sb      r0,0(r2)
        add     r2,1
        la      r1,_provider_destination
        sw      r2,0(r1)
        la      r2,_block_cursor
        lw      r0,0(r2)
        add     r0,1
        sw      r0,0(r2)
        la      r2,_block_remaining
        lw      r0,0(r2)
        add     r0,-1
        sw      r0,0(r2)
        ceq     r0,z
        brf     _block_provider_next_byte
_block_provider_done:
        pop     r2
        pop     r1
        jmp     (r1)

; Arbitrary byte reads adapted to the W25Q32 eight-byte block HAL.
_spi_provider_read:
        push    r1
        push    r2
        lc      r0,0
        la      r2,_provider_status
        sw      r0,0(r2)
        la      r2,_provider_offset
        lw      r0,0(r2)
        la      r2,_provider_count
        lw      r1,0(r2)
        add     r0,r1
        la      r2,_provider_limit
        lw      r1,0(r2)
        ceq     r0,r1
        brt     _spi_provider_in_bounds
        cls     r0,r1
        brt     _spi_provider_in_bounds
        lc      r0,1
        la      r2,_provider_status
        sw      r0,0(r2)
        la      r2,_spi_provider_done
        jmp     (r2)
_spi_provider_in_bounds:
        la      r2,_provider_image
        lw      r0,0(r2)
        la      r2,_provider_offset
        lw      r1,0(r2)
        add     r0,r1
        la      r2,_block_cursor
        sw      r0,0(r2)
        la      r2,_provider_count
        lw      r0,0(r2)
        la      r2,_block_remaining
        sw      r0,0(r2)
_spi_provider_next_byte:
        la      r2,_block_cursor
        lw      r0,0(r2)
        lc      r1,0
_spi_provider_divide:
        lc      r2,8
        cls     r0,r2
        brt     _spi_provider_fetch
        sub     r0,r2
        add     r1,1
        bra     _spi_provider_divide
_spi_provider_fetch:
        la      r2,_block_within
        sw      r0,0(r2)
        mov     r0,r1
        la      r2,_spi_requested_block
        sw      r0,0(r2)
        la      r2,_spi_cache_valid
        lbu     r1,0(r2)
        ceq     r1,z
        brt     _spi_provider_cache_miss
        la      r2,_spi_cached_block
        lw      r1,0(r2)
        ceq     r0,r1
        brf     _spi_provider_cache_miss
        la      r2,_spi_cache_hit_count
        lw      r1,0(r2)
        add     r1,1
        sw      r1,0(r2)
        la      r0,_SPI_FLASH_BLOCK_BUFFER
        bra     _spi_provider_have_block
_spi_provider_cache_miss:
        la      r2,_spi_requested_block
        lw      r0,0(r2)
        la      r2,_SPI_FLASH_READ_BLOCK
        jal     r1,(r2)
        la      r2,_spi_requested_block
        lw      r1,0(r2)
        la      r2,_spi_cached_block
        sw      r1,0(r2)
        la      r2,_spi_cache_valid
        lc      r1,1
        sb      r1,0(r2)
        la      r2,_spi_fetch_count
        lw      r1,0(r2)
        add     r1,1
        sw      r1,0(r2)
_spi_provider_have_block:
        la      r2,_block_within
        lw      r1,0(r2)
        add     r0,r1
        lbu     r0,0(r0)
        la      r2,_provider_destination
        lw      r2,0(r2)
        sb      r0,0(r2)
        add     r2,1
        la      r1,_provider_destination
        sw      r2,0(r1)
        la      r2,_block_cursor
        lw      r0,0(r2)
        add     r0,1
        sw      r0,0(r2)
        la      r2,_block_remaining
        lw      r0,0(r2)
        add     r0,-1
        sw      r0,0(r2)
        ceq     r0,z
        brt     _spi_provider_done
        la      r2,_spi_provider_next_byte
        jmp     (r2)
_spi_provider_done:
        pop     r2
        pop     r1
        jmp     (r1)

; Arbitrary bounded byte reads adapted to cached 512-byte SD-card sectors.
; The image base is a media byte offset, matching the W25Q32 provider ABI.
_sd_provider_read:
        push    r1
        push    r2
        lc      r0,0
        la      r2,_provider_status
        sw      r0,0(r2)
        la      r2,_provider_offset
        lw      r0,0(r2)
        la      r2,_provider_count
        lw      r1,0(r2)
        add     r0,r1
        la      r2,_provider_limit
        lw      r1,0(r2)
        ceq     r0,r1
        brt     _sd_provider_in_bounds
        cls     r0,r1
        brt     _sd_provider_in_bounds
        la      r2,_sd_provider_fail
        jmp     (r2)
_sd_provider_in_bounds:
        la      r2,_provider_image
        lw      r0,0(r2)
        la      r2,_provider_offset
        lw      r1,0(r2)
        add     r0,r1
        la      r2,_sd_cursor
        sw      r0,0(r2)
        la      r2,_provider_count
        lw      r0,0(r2)
        la      r2,_sd_remaining
        sw      r0,0(r2)
_sd_provider_next:
        la      r2,_sd_cursor
        lw      r0,0(r2)
        lc      r1,0
_sd_provider_divide:
        la      r2,512
        cls     r0,r2
        brt     _sd_provider_sector_ready
        sub     r0,r2
        add     r1,1
        bra     _sd_provider_divide
_sd_provider_sector_ready:
        la      r2,_sd_within
        sw      r0,0(r2)
        la      r2,_sd_requested_sector
        sw      r1,0(r2)
        la      r2,_sd_cache_valid
        lbu     r0,0(r2)
        ceq     r0,z
        brt     _sd_provider_cache_miss
        la      r2,_sd_cached_sector
        lw      r0,0(r2)
        ceq     r0,r1
        brt     _sd_provider_have_sector
_sd_provider_cache_miss:
        la      r0,_sd_read_status
        push    r0
        la      r0,_sd_sector_buffer
        push    r0
        mov     r0,r1
        push    r0
        la      r2,_SPI_SD_READ_SECTOR
        jal     r1,(r2)
        add     sp,9
        la      r2,_sd_read_status
        lw      r0,0(r2)
        ceq     r0,z
        brt     _sd_provider_read_ok
        la      r2,_sd_provider_fail
        jmp     (r2)
_sd_provider_read_ok:
        la      r2,_sd_requested_sector
        lw      r0,0(r2)
        la      r2,_sd_cached_sector
        sw      r0,0(r2)
        la      r2,_sd_cache_valid
        lc      r0,1
        sb      r0,0(r2)
        la      r2,_sd_fetch_count
        lw      r0,0(r2)
        add     r0,1
        sw      r0,0(r2)
_sd_provider_have_sector:
        la      r2,_sd_within
        lw      r1,0(r2)
        la      r0,_sd_sector_buffer
        add     r0,r1
        lbu     r0,0(r0)
        la      r2,_provider_destination
        lw      r2,0(r2)
        sb      r0,0(r2)
        add     r2,1
        la      r1,_provider_destination
        sw      r2,0(r1)
        la      r2,_sd_cursor
        lw      r0,0(r2)
        add     r0,1
        sw      r0,0(r2)
        la      r2,_sd_remaining
        lw      r0,0(r2)
        add     r0,-1
        sw      r0,0(r2)
        ceq     r0,z
        brt     _sd_provider_done
        la      r2,_sd_provider_next
        jmp     (r2)
_sd_provider_fail:
        lc      r0,1
        la      r2,_provider_status
        sw      r0,0(r2)
_sd_provider_done:
        pop     r2
        pop     r1
        jmp     (r1)

        .globl  _TASK_SD_PROVIDER_VERIFY
_TASK_SD_PROVIDER_VERIFY:
        push    r1
        la      r2,_sd_fetch_count
        lw      r0,0(r2)
        lc      r1,1
        bra     _sd_provider_verify_count

        .globl  _TASK_SD_PROVIDER_VERIFY_TWO_SECTORS
_TASK_SD_PROVIDER_VERIFY_TWO_SECTORS:
        push    r1
        la      r2,_sd_fetch_count
        lw      r0,0(r2)
        lc      r1,2
        bra     _sd_provider_verify_count

        .globl  _TASK_SD_PROVIDER_VERIFY_THREE_SECTORS
_TASK_SD_PROVIDER_VERIFY_THREE_SECTORS:
        push    r1
        la      r2,_sd_fetch_count
        lw      r0,0(r2)
        lc      r1,3
_sd_provider_verify_count:
        ceq     r0,r1
        brt     _sd_provider_verified
        la      r2,_TASK_HALT
        jmp     (r2)
_sd_provider_verified:
        la      r0,_sd_provider_message
        la      r2,_puts
        jal     r1,(r2)
        pop     r1
        jmp     (r1)

; After serial failure/success stress, no child may remain and the allocation
; cursor must have returned to the generation mark established by the spawn.
        .globl  _TASK_RECOVERY_RECLAIM_VERIFY
_TASK_RECOVERY_RECLAIM_VERIFY:
        push    r1
        la      r2,_child_count
        lbu     r0,0(r2)
        ceq     r0,z
        brf     _recovery_reclaim_fail
        la      r2,_ebr_next
        lw      r0,0(r2)
        la      r2,_spawn_arena_mark
        lw      r1,0(r2)
        ceq     r0,r1
        brf     _recovery_reclaim_fail
        la      r0,_recovery_reclaim_message
        la      r2,_puts
        jal     r1,(r2)
        pop     r1
        jmp     (r1)
_recovery_reclaim_fail:
        la      r2,_TASK_HALT
        jmp     (r2)

; Find a generated fixed-record catalog entry through block reads. Layout:
; eight-byte header (count in byte zero), then 24-byte records containing a
; 16-byte NUL-terminated name, one-byte descriptor ordinal, and seven padding.
_block_provider_find:
        push    r1
        lw      r2,12(fp)
        lc      r0,0
        sw      r0,0(r2)
        la      r2,_spi_provider_active
        lbu     r0,0(r2)
        ceq     r0,z
        brt     _block_find_memory_catalog
        lc      r0,0
        la      r2,_provider_image
        sw      r0,0(r2)
        la      r0,_block_catalog_index_end
        la      r1,_block_catalog_index
        sub     r0,r1
        bra     _block_find_catalog_limit
_block_find_memory_catalog:
        la      r0,_block_catalog_index
        la      r2,_provider_image
        sw      r0,0(r2)
        la      r0,_block_catalog_index_end
        la      r1,_block_catalog_index
        sub     r0,r1
_block_find_catalog_limit:
        la      r2,_provider_limit
        sw      r0,0(r2)
        lc      r0,0
        la      r2,_provider_offset
        sw      r0,0(r2)
        lc      r0,8
        la      r2,_provider_count
        sw      r0,0(r2)
        la      r0,_block_header_buffer
        la      r2,_provider_destination
        sw      r0,0(r2)
        la      r2,_image_provider_read
        jal     r1,(r2)
        la      r2,_provider_status
        lw      r0,0(r2)
        ceq     r0,z
        brt     _block_find_header_read_ok
        la      r2,_block_provider_find_done
        jmp     (r2)
_block_find_header_read_ok:
        ; Header: count, version 1, ASCII SWT, record CRC-32 low 24 bits.
        la      r2,_block_header_buffer
        lbu     r0,0(r2)
        ceq     r0,z
        brf     _block_find_count_nonzero
        la      r2,_block_provider_find_done
        jmp     (r2)
_block_find_count_nonzero:
        lbu     r0,1(r2)
        lc      r1,1
        ceq     r0,r1
        brt     _block_find_version_ok
        la      r2,_block_provider_find_done
        jmp     (r2)
_block_find_version_ok:
        la      r2,_block_header_buffer
        lbu     r0,2(r2)
        lc      r1,83
        ceq     r0,r1
        brf     _block_find_header_invalid
        lbu     r0,3(r2)
        lc      r1,87
        ceq     r0,r1
        brf     _block_find_header_invalid
        lbu     r0,4(r2)
        lc      r1,84
        ceq     r0,r1
        brt     _block_find_magic_ok
_block_find_header_invalid:
        la      r2,_block_provider_find_done
        jmp     (r2)
_block_find_magic_ok:
        la      r2,_block_header_buffer
        lbu     r0,0(r2)
        ; Header plus count fixed records must exactly fill the bounded index.
        mov     r1,r0
        add     r0,r1
        add     r0,r1
        lc      r1,3
        shl     r0,r1
        add     r0,8
        la      r2,_provider_limit
        lw      r1,0(r2)
        ceq     r0,r1
        brt     _block_find_count_valid
        la      r2,_block_provider_find_done
        jmp     (r2)
_block_find_count_valid:
        ; Read and authenticate the complete record region before traversal.
        lc      r0,8
        la      r2,_provider_offset
        sw      r0,0(r2)
        la      r2,_provider_limit
        lw      r0,0(r2)
        add     r0,-8
        la      r2,_provider_count
        sw      r0,0(r2)
        la      r0,_block_catalog_buffer
        la      r2,_provider_destination
        sw      r0,0(r2)
        la      r2,_image_provider_read
        jal     r1,(r2)
        la      r2,_provider_status
        lw      r0,0(r2)
        ceq     r0,z
        brt     _block_find_records_read_ok
        la      r2,_block_provider_find_done
        jmp     (r2)
_block_find_records_read_ok:
        la      r0,_block_catalog_buffer
        la      r2,_crc_cursor
        sw      r0,0(r2)
        la      r2,_provider_limit
        lw      r0,0(r2)
        add     r0,-8
        la      r2,_crc_remaining
        sw      r0,0(r2)
        la      r2,_crc32_low24
        jal     r1,(r2)
        la      r2,_block_catalog_crc
        sw      r0,0(r2)
        la      r0,_block_header_buffer
        add     r0,5
        la      r2,_read_image_word
        jal     r1,(r2)
        la      r2,_block_catalog_crc
        lw      r1,0(r2)
        ceq     r0,r1
        brt     _block_find_crc_ok
        la      r2,_block_provider_find_done
        jmp     (r2)
_block_find_crc_ok:
        la      r2,_block_header_buffer
        lbu     r0,0(r2)
        la      r2,_block_find_remaining
        sw      r0,0(r2)
        lc      r0,8
        la      r2,_block_find_offset
        sw      r0,0(r2)
        lc      r0,0
        la      r2,_block_find_ordinal
        sb      r0,0(r2)
        la      r0,_scheduled_catalog_table
        la      r2,_block_find_table
        sw      r0,0(r2)
_block_provider_find_next:
        la      r2,_block_find_offset
        lw      r0,0(r2)
        la      r2,_provider_offset
        sw      r0,0(r2)
        lc      r0,16
        la      r2,_provider_count
        sw      r0,0(r2)
        la      r0,_block_name_buffer
        la      r2,_provider_destination
        sw      r0,0(r2)
        la      r2,_image_provider_read
        jal     r1,(r2)
        la      r2,_provider_status
        lw      r0,0(r2)
        ceq     r0,z
        brt     _block_find_name_read_ok
        la      r2,_block_provider_find_done
        jmp     (r2)
_block_find_name_read_ok:
        la      r0,_block_name_buffer
        la      r2,_validate_block_name
        jal     r1,(r2)
        ceq     r0,z
        brt     _block_find_name_valid
        la      r2,_block_provider_find_done
        jmp     (r2)
_block_find_name_valid:
        lw      r2,9(fp)
        la      r1,_block_name_buffer
_block_provider_find_compare:
        push    r1
        lbu     r0,0(r1)
        push    r0
        lbu     r0,0(r2)
        pop     r1
        ceq     r0,r1
        pop     r1
        brf     _block_provider_find_mismatch
        ceq     r0,z
        brt     _block_provider_find_match
        add     r1,1
        add     r2,1
        bra     _block_provider_find_compare
_block_provider_find_mismatch:
        la      r2,_block_find_offset
        lw      r0,0(r2)
        add     r0,24
        sw      r0,0(r2)
        la      r2,_block_find_table
        lw      r0,0(r2)
        add     r0,3
        sw      r0,0(r2)
        la      r2,_block_find_ordinal
        lbu     r0,0(r2)
        add     r0,1
        sb      r0,0(r2)
        la      r2,_block_find_remaining
        lw      r0,0(r2)
        add     r0,-1
        sw      r0,0(r2)
        ceq     r0,z
        brt     _block_find_exhausted
        la      r2,_block_provider_find_next
        jmp     (r2)
_block_find_exhausted:
        la      r2,_block_provider_find_done
        jmp     (r2)
_block_provider_find_match:
        la      r2,_block_find_table
        lw      r2,0(r2)
        lw      r0,0(r2)
        lw      r1,3(r0)
        push    r0
        mov     r0,r1
        lc      r2,2
        ceq     r0,r2
        pop     r0
        brf     _block_find_not_service
        la      r2,_block_provider_find_done
        jmp     (r2)
_block_find_not_service:
        la      r2,_spi_provider_active
        lbu     r1,0(r2)
        ceq     r1,z
        brf     _block_find_spi_extent
        la      r2,_block_provider_find_store
        jmp     (r2)
_block_find_spi_extent:
        la      r2,_spi_source_descriptor
        sw      r0,0(r2)
        ; Read ordinal, offset, length, and flags as one complete record tail.
        la      r2,_block_find_offset
        lw      r0,0(r2)
        add     r0,16
        la      r2,_provider_offset
        sw      r0,0(r2)
        lc      r0,8
        la      r2,_provider_count
        sw      r0,0(r2)
        la      r0,_spi_extent_buffer
        la      r2,_provider_destination
        sw      r0,0(r2)
        la      r2,_image_provider_read
        jal     r1,(r2)
        la      r2,_provider_status
        lw      r0,0(r2)
        ceq     r0,z
        brt     _spi_extent_status_ok
        la      r2,_block_provider_find_done
        jmp     (r2)
_spi_extent_status_ok:
        ; Ordinal must agree with the runtime descriptor-table position.
        la      r2,_spi_extent_buffer
        lbu     r0,0(r2)
        la      r2,_block_find_ordinal
        lbu     r1,0(r2)
        ceq     r0,r1
        brt     _spi_extent_ordinal_ok
        la      r2,_block_provider_find_done
        jmp     (r2)
_spi_extent_ordinal_ok:
        ; Only records explicitly marked as carrying an image are loadable.
        la      r2,_spi_extent_buffer
        lbu     r0,7(r2)
        lc      r1,1
        ceq     r0,r1
        brt     _spi_extent_flags_ok
        la      r2,_block_provider_find_done
        jmp     (r2)
_spi_extent_flags_ok:
        la      r0,_spi_extent_buffer
        add     r0,1
        la      r2,_read_image_word
        jal     r1,(r2)
        la      r2,_spi_extent_offset
        sw      r0,0(r2)
        ; Image offset is block aligned and follows the 128-byte catalog.
        mov     r1,r0
        lc      r2,7
        and     r0,r2
        ceq     r0,z
        brt     _spi_extent_alignment_ok
        la      r2,_block_provider_find_done
        jmp     (r2)
_spi_extent_alignment_ok:
        la      r2,_provider_limit
        lw      r2,0(r2)
        clu     r1,r2
        brf     _spi_extent_minimum_ok
        la      r2,_block_provider_find_done
        jmp     (r2)
_spi_extent_minimum_ok:
        la      r0,_spi_extent_buffer
        add     r0,4
        la      r2,_read_image_word
        jal     r1,(r2)
        la      r2,_spi_extent_length
        sw      r0,0(r2)
        ; Logical byte length must equal descriptor image_words * 3.
        la      r2,_spi_source_descriptor
        lw      r2,0(r2)
        lw      r1,12(r2)
        mov     r2,r1
        add     r1,r2
        add     r1,r2
        ceq     r0,r1
        brt     _spi_extent_length_ok
        la      r2,_block_provider_find_done
        jmp     (r2)
_spi_extent_length_ok:
        ; Extent end must not wrap and must fit the 4 MiB W25Q32 address space.
        la      r2,_spi_extent_offset
        lw      r1,0(r2)
        add     r0,r1
        clu     r0,r1
        brf     _spi_extent_no_wrap
        la      r2,_block_provider_find_done
        jmp     (r2)
_spi_extent_no_wrap:
        la      r2,0x400000
        ceq     r0,r2
        brt     _spi_extent_valid
        clu     r0,r2
        brt     _spi_extent_valid
        la      r2,_block_provider_find_done
        jmp     (r2)
_spi_extent_valid:
        ; Copy the generated descriptor, then replace its in-memory image
        ; pointer with the validated media offset.
        la      r2,_spi_source_descriptor
        lw      r1,0(r2)
        la      r2,_spi_descriptor
        lc      r0,24
_spi_descriptor_copy:
        push    r0
        lbu     r0,0(r1)
        sb      r0,0(r2)
        pop     r0
        add     r1,1
        add     r2,1
        add     r0,-1
        ceq     r0,z
        brf     _spi_descriptor_copy
        la      r2,_spi_extent_offset
        lw      r0,0(r2)
        la      r2,_spi_descriptor
        sw      r0,9(r2)
        mov     r0,r2
_block_provider_find_store:
        lw      r2,12(fp)
        sw      r0,0(r2)
_block_provider_find_done:
        pop     r1
        jmp     (r1)

; Return zero only when r0 contains a NUL within its fixed 16-byte name field.
_validate_block_name:
        push    r1
        push    r2
        mov     r2,r0
        lc      r1,16
_validate_block_name_next:
        lbu     r0,0(r2)
        ceq     r0,z
        brt     _validate_block_name_ok
        add     r2,1
        add     r1,-1
        push    r0
        mov     r0,r1
        ceq     r0,z
        pop     r0
        brf     _validate_block_name_next
        lc      r0,1
        bra     _validate_block_name_done
_validate_block_name_ok:
        lc      r0,0
_validate_block_name_done:
        pop     r2
        pop     r1
        jmp     (r1)

; Read the big-endian header word at byte offset r0 through the active provider.
_read_embedded_field:
        push    r1
        push    r2
        la      r2,_provider_offset
        sw      r0,0(r2)
        la      r2,_embedded_image_base
        lw      r0,0(r2)
        la      r2,_provider_image
        sw      r0,0(r2)
        la      r0,_provider_word_buffer
        la      r2,_provider_destination
        sw      r0,0(r2)
        lc      r0,3
        la      r2,_provider_count
        sw      r0,0(r2)
        la      r2,_image_provider_read
        jal     r1,(r2)
        la      r2,_provider_status
        lw      r0,0(r2)
        ceq     r0,z
        brt     _read_embedded_field_ok
        lc      r0,1
        la      r2,_embedded_load_status
        sw      r0,0(r2)
        lc      r0,0
        bra     _read_embedded_field_done
_read_embedded_field_ok:
        la      r0,_provider_word_buffer
        la      r2,_read_image_word
        jal     r1,(r2)
_read_embedded_field_done:
        pop     r2
        pop     r1
        jmp     (r1)

; Load the embedded descriptor in r0 into private arena memory for the process
; selected by _spawn_process. Validate metadata and payload CRC before execute.
_load_embedded_process:
        push    r1
        lc      r1,0
        la      r2,_embedded_load_status
        sw      r1,0(r2)
        la      r1,_embedded_descriptor
        sw      r0,0(r1)
        lw      r1,12(r0)
        mov     r2,r1
        add     r1,r2
        add     r1,r2
        la      r2,_provider_limit
        sw      r1,0(r2)
        lw      r0,9(r0)
        la      r1,_embedded_image_base
        sw      r0,0(r1)

        la      r2,_validate_embedded_magic
        jal     r1,(r2)
        ceq     r0,z
        brt     _embedded_magic_ok
        la      r2,_embedded_load_fail
        jmp     (r2)
_embedded_magic_ok:

        ; Enforce version 1 and its zero-relocation policy on target.
        lc      r0,6
        la      r2,_read_embedded_field
        jal     r1,(r2)
        lc      r1,1
        ceq     r0,r1
        brt     _embedded_version_ok
        la      r2,_embedded_load_fail
        jmp     (r2)
_embedded_version_ok:
        lc      r0,21
        la      r2,_read_embedded_field
        jal     r1,(r2)
        ceq     r0,z
        brt     _embedded_relocations_ok
        la      r2,_embedded_load_fail
        jmp     (r2)
_embedded_relocations_ok:

        lc      r0,9
        la      r2,_read_embedded_field
        jal     r1,(r2)
        la      r2,_embedded_text_words
        sw      r0,0(r2)
        lc      r0,12
        la      r2,_read_embedded_field
        jal     r1,(r2)
        la      r2,_embedded_data_words
        sw      r0,0(r2)
        lc      r0,15
        la      r2,_read_embedded_field
        jal     r1,(r2)
        la      r2,_embedded_bss_words
        sw      r0,0(r2)
        lc      r0,18
        la      r2,_read_embedded_field
        jal     r1,(r2)
        la      r2,_embedded_entry_words
        sw      r0,0(r2)
        lc      r0,24
        la      r2,_read_embedded_field
        jal     r1,(r2)
        la      r2,_embedded_checksum
        sw      r0,0(r2)
        la      r2,_embedded_load_status
        lw      r0,0(r2)
        ceq     r0,z
        brt     _embedded_metadata_ok
        la      r2,_embedded_load_fail
        jmp     (r2)
_embedded_metadata_ok:
        la      r2,_validate_embedded_layout
        jal     r1,(r2)
        ceq     r0,z
        brt     _embedded_layout_ok
        la      r2,_embedded_load_fail
        jmp     (r2)
_embedded_layout_ok:

        ; The zeroing allocator reserves text + data + BSS in this process's
        ; reclaimable child generation.
        la      r2,_embedded_text_words
        lw      r0,0(r2)
        la      r2,_embedded_data_words
        lw      r1,0(r2)
        add     r0,r1
        la      r2,_embedded_bss_words
        lw      r1,0(r2)
        add     r0,r1
        la      r2,_alloc_state_words
        jal     r1,(r2)
        ceq     r0,z
        brf     _embedded_allocation_ok
        la      r2,_embedded_load_fail
        jmp     (r2)
_embedded_allocation_ok:
        la      r2,_spawn_process
        lw      r2,0(r2)
        sw      r0,27(r2)       ; private executable allocation base

        ; Copy text + initialized data; the remaining allocation stays zero.
        la      r2,_embedded_text_words
        lw      r1,0(r2)
        la      r2,_embedded_data_words
        lw      r2,0(r2)
        add     r1,r2
        mov     r2,r1
        add     r1,r2
        add     r1,r2
        la      r2,_provider_count
        sw      r1,0(r2)
        la      r2,_embedded_image_base
        lw      r1,0(r2)
        la      r2,_provider_image
        sw      r1,0(r2)
        lc      r1,27
        la      r2,_provider_offset
        sw      r1,0(r2)
        la      r2,_provider_destination
        sw      r0,0(r2)
        la      r2,_image_provider_read
        jal     r1,(r2)
        la      r2,_provider_status
        lw      r0,0(r2)
        ceq     r0,z
        brt     _embedded_payload_read_ok
        la      r2,_embedded_load_fail
        jmp     (r2)
_embedded_payload_read_ok:

        ; Validate the stored CRC-32 low 24 bits over copied text/data before
        ; any untrusted instruction can become runnable.
        la      r2,_spawn_process
        lw      r2,0(r2)
        lw      r0,27(r2)
        la      r2,_crc_cursor
        sw      r0,0(r2)
        la      r2,_provider_count
        lw      r0,0(r2)
        la      r2,_crc_remaining
        sw      r0,0(r2)
        la      r2,_crc32_low24
        jal     r1,(r2)
        la      r2,_embedded_checksum
        lw      r1,0(r2)
        ceq     r0,r1
        brt     _embedded_checksum_ok
        la      r2,_embedded_load_fail
        jmp     (r2)
_embedded_checksum_ok:

        ; Store allocation base + full 24-bit entry word offset.
        la      r2,_embedded_entry_words
        lw      r0,0(r2)
        mov     r1,r0
        add     r0,r1
        add     r0,r1
        la      r2,_spawn_process
        lw      r2,0(r2)
        lw      r1,27(r2)
        add     r0,r1
        sw      r0,30(r2)
        la      r2,_embedded_bound_read
        lc      r0,0
        sw      r0,0(r2)
        lc      r0,0
        pop     r1
        jmp     (r1)

; Validate C24IMG magic through the active provider before parsing metadata.
_validate_embedded_magic:
        push    r1
        push    r2
        lc      r0,0
        la      r2,_provider_offset
        sw      r0,0(r2)
        la      r2,_embedded_image_base
        lw      r0,0(r2)
        la      r2,_provider_image
        sw      r0,0(r2)
        la      r0,_embedded_magic_buffer
        la      r2,_provider_destination
        sw      r0,0(r2)
        lc      r0,6
        la      r2,_provider_count
        sw      r0,0(r2)
        la      r2,_image_provider_read
        jal     r1,(r2)
        la      r2,_provider_status
        lw      r0,0(r2)
        ceq     r0,z
        brf     _embedded_magic_fail
        la      r0,_embedded_magic_buffer
        la      r2,_embedded_magic_expected
        lc      r1,6
_embedded_magic_compare:
        push    r1
        lbu     r1,0(r0)
        push    r0
        lbu     r0,0(r2)
        ceq     r0,r1
        pop     r0
        pop     r1
        brf     _embedded_magic_fail
        add     r0,1
        add     r2,1
        add     r1,-1
        push    r0
        mov     r0,r1
        ceq     r0,z
        pop     r0
        brf     _embedded_magic_compare
        lc      r0,0
        bra     _embedded_magic_done
_embedded_magic_fail:
        lc      r0,1
_embedded_magic_done:
        pop     r2
        pop     r1
        jmp     (r1)

; Check entry bounds and all size arithmetic before allocating executable RAM.
; The descriptor's stored byte extent must exactly equal 27 + 3*(text+data).
_validate_embedded_layout:
        push    r1
        push    r2
        la      r2,_embedded_text_words
        lw      r1,0(r2)
        mov     r0,r1
        ceq     r0,z
        brt     _embedded_layout_fail
        la      r2,_embedded_entry_words
        lw      r0,0(r2)
        clu     r0,r1
        brf     _embedded_layout_fail
        la      r2,_embedded_data_words
        lw      r0,0(r2)
        add     r0,r1
        clu     r0,r1
        brt     _embedded_layout_fail
        mov     r1,r0
        add     r0,r1
        clu     r0,r1
        brt     _embedded_layout_fail
        add     r0,r1
        clu     r0,r1
        brt     _embedded_layout_fail
        mov     r1,r0
        add     r0,27
        clu     r0,r1
        brt     _embedded_layout_fail
        la      r2,_provider_limit
        lw      r1,0(r2)
        ceq     r0,r1
        brf     _embedded_layout_fail
        ; Allocation word total must not wrap when BSS is included.
        la      r2,_embedded_text_words
        lw      r0,0(r2)
        la      r2,_embedded_data_words
        lw      r1,0(r2)
        add     r0,r1
        la      r2,_embedded_bss_words
        lw      r1,0(r2)
        mov     r2,r0
        add     r0,r1
        clu     r0,r2
        brt     _embedded_layout_fail
        lc      r0,0
        bra     _embedded_layout_done
_embedded_layout_fail:
        lc      r0,1
_embedded_layout_done:
        pop     r2
        pop     r1
        jmp     (r1)

; Return the low 24 bits of standard CRC-32 for the range recorded in
; _crc_cursor/_crc_remaining. The 32-bit
; accumulator is split into a 24-bit low word and an eight-bit high part.
_crc32_low24:
        push    r1
        push    r2
        la      r0,0xFFFFFF
        la      r2,_crc_low
        sw      r0,0(r2)
        lcu     r0,255
        la      r2,_crc_high
        sb      r0,0(r2)
_crc_next_byte:
        la      r2,_crc_cursor
        lw      r2,0(r2)
        lbu     r0,0(r2)
        la      r2,_crc_low
        lw      r1,0(r2)
        xor     r1,r0
        sw      r1,0(r2)
        lc      r0,8
        la      r2,_crc_bits
        sb      r0,0(r2)
_crc_next_bit:
        la      r2,_crc_low
        lw      r0,0(r2)
        lc      r1,1
        and     r1,r0
        la      r2,_crc_lsb
        sb      r1,0(r2)
        lc      r1,1
        srl     r0,r1
        la      r2,_crc_high
        lbu     r1,0(r2)
        push    r1
        lc      r2,1
        and     r1,r2
        ceq     r1,z
        brt     _crc_no_high_carry
        la      r2,0x800000
        or      r0,r2
_crc_no_high_carry:
        la      r2,_crc_low
        sw      r0,0(r2)
        pop     r0
        lc      r1,1
        srl     r0,r1
        la      r2,_crc_high
        sb      r0,0(r2)
        la      r2,_crc_lsb
        lbu     r0,0(r2)
        ceq     r0,z
        brt     _crc_polynomial_done
        la      r2,_crc_low
        lw      r0,0(r2)
        la      r1,0xB88320
        xor     r0,r1
        sw      r0,0(r2)
        la      r2,_crc_high
        lbu     r0,0(r2)
        lcu     r1,237
        xor     r0,r1
        sb      r0,0(r2)
_crc_polynomial_done:
        la      r2,_crc_bits
        lbu     r0,0(r2)
        add     r0,-1
        sb      r0,0(r2)
        ceq     r0,z
        brf     _crc_next_bit
        la      r2,_crc_cursor
        lw      r0,0(r2)
        add     r0,1
        sw      r0,0(r2)
        la      r2,_crc_remaining
        lw      r0,0(r2)
        add     r0,-1
        sw      r0,0(r2)
        ceq     r0,z
        brt     _crc_done
        la      r2,_crc_next_byte
        jmp     (r2)
_crc_done:
        la      r2,_crc_low
        lw      r0,0(r2)
        la      r1,0xFFFFFF
        xor     r0,r1
        pop     r2
        pop     r1
        jmp     (r1)
_embedded_load_fail:
        la      r2,_embedded_bound_read
        lc      r0,0
        sw      r0,0(r2)
        lc      r0,1
        pop     r1
        jmp     (r1)

; Decode one most-significant-byte-first 24-bit header word from r0.
_read_image_word:
        push    r1
        push    r2
        mov     r2,r0
        lbu     r0,0(r2)
        lc      r1,2
        push    r1
_read_image_word_byte:
        add     r0,r0
        add     r0,r0
        add     r0,r0
        add     r0,r0
        add     r0,r0
        add     r0,r0
        add     r0,r0
        add     r0,r0
        add     r2,1
        lbu     r1,0(r2)
        add     r0,r1
        pop     r1
        add     r1,-1
        push    r1
        push    r0
        mov     r0,r1
        ceq     r0,z
        pop     r0
        brf     _read_image_word_byte
        pop     r1
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

_plsw_uptime_trampoline:
        push    r0
        la      r2,_PLSW_UPTIME
        jal     r1,(r2)
        add     sp,3
        la      r2,_halt
        jmp     (r2)

; Call the per-process loaded entry and terminate its child process.
_embedded_loader_trampoline:
        la      r2,_current_proc
        lw      r2,0(r2)
        lw      r2,30(r2)       ; private relocated entry
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

; TASK_MEM_INFO(result): snapshot fixed and runtime memory accounting.
; Result words: total words, image bytes, arena current bytes, arena peak
; bytes, kernel-stack peak bytes, allocation failures, used slots, total
; slots, arena capacity bytes.
        .globl  _TASK_MEM_INFO
_TASK_MEM_INFO:
        push    fp
        push    r2
        push    r1
        mov     fp,sp
        lw      r2,9(fp)
        la      r0,0x100000
        sw      r0,0(r2)
        la      r0,_swtos_image_end
        add     r0,1
        sw      r0,3(r2)
        la      r0,0xFEEB00
        la      r1,_ebr_next
        lw      r1,0(r1)
        sub     r0,r1
        sw      r0,6(r2)
        la      r1,_allocation_peak_bytes
        lw      r0,0(r1)
        sw      r0,9(r2)
        la      r1,_kernel_stack_peak_bytes
        lw      r0,0(r1)
        sw      r0,12(r2)
        la      r1,_allocation_failures
        lw      r0,0(r1)
        sw      r0,15(r2)
        la      r1,_child_count
        lbu     r0,0(r1)
        add     r0,1
        sw      r0,18(r2)
        lc      r0,3
        sw      r0,21(r2)
        la      r0,2814
        sw      r0,24(r2)
        mov     sp,fp
        pop     r1
        pop     r2
        pop     fp
        jmp     (r1)

; TASK_MEM_PROCESS_INFO(endpoint, result): return status, configured stack,
; configured state, and live allocated words without expanding PROC_DESC.
        .globl  _TASK_MEM_PROCESS_INFO
_TASK_MEM_PROCESS_INFO:
        push    fp
        push    r2
        push    r1
        mov     fp,sp
        lw      r0,9(fp)
        lc      r1,1
        ceq     r0,r1
        brt     _task_mem_process_a
        lc      r1,2
        ceq     r0,r1
        brt     _task_mem_process_b
        la      r2,_proc_c
        bra     _task_mem_process_selected
_task_mem_process_a:
        la      r2,_proc_a
        bra     _task_mem_process_selected
_task_mem_process_b:
        la      r2,_proc_b
_task_mem_process_selected:
        lw      r1,12(fp)
        lw      r0,24(r2)
        sw      r0,0(r1)
        ceq     r0,z
        brt     _task_mem_process_free
        lw      r2,33(r2)
        lw      r0,15(r2)
        sw      r0,3(r1)
        lw      r2,18(r2)
        sw      r2,6(r1)
        add     r0,r2
        sw      r0,9(r1)
        bra     _task_mem_process_done
_task_mem_process_free:
        lc      r0,0
        sw      r0,3(r1)
        sw      r0,6(r1)
        sw      r0,9(r1)
_task_mem_process_done:
        mov     sp,fp
        pop     r1
        pop     r2
        pop     fp
        jmp     (r1)

; TASK_MEM_RESET(): reset counters that can safely restart while the shell
; runs. The boot/kernel-stack watermark is intentionally retained.
        .globl  _TASK_MEM_RESET
_TASK_MEM_RESET:
        push    fp
        push    r2
        push    r1
        mov     fp,sp
        la      r0,0xFEEB00
        la      r2,_ebr_next
        lw      r1,0(r2)
        sub     r0,r1
        la      r2,_allocation_peak_bytes
        sw      r0,0(r2)
        lc      r0,0
        la      r2,_allocation_failures
        sw      r0,0(r2)
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
        la      r2,_active_image_provider
        lw      r2,0(r2)
        lw      r2,0(r2)       ; IMAGE_PROVIDER find
        jal     r1,(r2)
        mov     sp,fp
        pop     r1
        pop     r2
        pop     fp
        jmp     (r1)

; Memory provider find uses the caller's PL/SW frame arguments.
_memory_provider_find:
        push    r1
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
        la      r2,_composite_resident_only
        lbu     r2,0(r2)
        ceq     r2,z
        brt     _task_catalog_find_compare_program
        lw      r1,3(r0)
        ceq     r1,z
        brt     _task_catalog_find_compare_program
        pop     r2
        bra     _task_catalog_find_advance
_task_catalog_find_compare_program:
        pop     r2
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
        pop     r1
        jmp     (r1)

; TASK_CATALOG_STAT_FIND(name, result): search every generated descriptor,
; including services and nonresident programs, for metadata inspection.
        .globl  _TASK_CATALOG_STAT_FIND
_TASK_CATALOG_STAT_FIND:
        push    fp
        push    r2
        push    r1
        mov     fp,sp
        lw      r2,12(fp)
        lc      r0,0
        sw      r0,0(r2)
        la      r2,_scheduled_catalog_table
_task_catalog_stat_next:
        lw      r0,0(r2)
        ceq     r0,z
        brt     _task_catalog_stat_done
        push    r2
        lw      r1,0(r0)
        lw      r2,9(fp)
_task_catalog_stat_compare:
        push    r1
        lbu     r0,0(r1)
        push    r0
        lbu     r0,0(r2)
        pop     r1
        ceq     r0,r1
        pop     r1
        brf     _task_catalog_stat_mismatch
        ceq     r0,z
        brt     _task_catalog_stat_match
        add     r1,1
        add     r2,1
        bra     _task_catalog_stat_compare
_task_catalog_stat_mismatch:
        pop     r2
        add     r2,3
        bra     _task_catalog_stat_next
_task_catalog_stat_match:
        pop     r2
        lw      r0,0(r2)
        lw      r1,12(fp)
        sw      r0,0(r1)
_task_catalog_stat_done:
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

; Negative provider proof: a two-byte read starting at the final image byte
; must return status 1 without touching the destination.
        .globl  _TASK_PROVIDER_BOUNDS_TEST
_TASK_PROVIDER_BOUNDS_TEST:
        push    fp
        push    r2
        push    r1
        mov     fp,sp
        la      r2,_scheduled_embedded_hello_descriptor
        lw      r0,9(r2)
        la      r1,_provider_image
        sw      r0,0(r1)
        lw      r0,12(r2)
        mov     r1,r0
        add     r0,r1
        add     r0,r1
        la      r2,_provider_limit
        sw      r0,0(r2)
        add     r0,-1
        la      r2,_provider_offset
        sw      r0,0(r2)
        lc      r0,2
        la      r2,_provider_count
        sw      r0,0(r2)
        la      r0,_provider_word_buffer
        la      r2,_provider_destination
        sw      r0,0(r2)
        la      r2,_image_provider_read
        jal     r1,(r2)
        la      r2,_provider_status
        lw      r0,0(r2)
        lc      r1,1
        ceq     r0,r1
        brt     _provider_bounds_pass
        la      r2,_halt
        jmp     (r2)
_provider_bounds_pass:
        la      r0,_provider_bounds_message
        la      r2,_puts
        jal     r1,(r2)
        mov     sp,fp
        pop     r1
        pop     r2
        pop     fp
        jmp     (r1)

; PL/SW runtime-compatible UART output entry.
        .globl  _UART_PUTS
_UART_PUTS:
        push    fp
        push    r2
        push    r1
        mov     fp,sp
        lw      r0,9(fp)
        la      r2,_puts
        jal     r1,(r2)
        mov     sp,fp
        pop     r1
        pop     r2
        pop     fp
        jmp     (r1)

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
; PROC_DESC ABI is declared in hal/cor24/proc-desc.toml and checked against
; include/swtos.msw. Offset 21 is PD_SENDER; no field is spare provider state.
_proc_a:
        .zero   39
_proc_b:
        .zero   39
_proc_c:
        .zero   39
_proc_table_end:
_proc_b_image_descriptor:
        .zero   24
_proc_b_image_provider:
        .zero   3
_proc_c_image_descriptor:
        .zero   24
_proc_c_image_provider:
        .zero   3
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
_allocation_word_count:
        .zero   3
_allocation_bytes:
        .zero   3
_allocation_old_high:
        .zero   3
_allocation_peak_bytes:
        .zero   3
_allocation_failures:
        .zero   3
_allocation_failed:
        .byte   0
_kernel_stack_peak_bytes:
        .zero   3
_kernel_stack_scan_cursor:
        .zero   3
_active_image_provider:
        .word   _memory_image_provider
_memory_image_provider:
        .word   _memory_provider_find
        .word   _memory_provider_read
_block_image_provider:
        .word   _block_provider_find
        .word   _block_provider_read
_spi_image_provider:
        .word   _block_provider_find
        .word   _spi_provider_read
_sd_image_provider:
        .word   _block_provider_find
        .word   _sd_provider_read
_composite_image_provider:
        .word   _composite_provider_find
        .word   _composite_provider_read
_composite_external_prepare:
        .word   _composite_prepare_spi
_composite_external_read:
        .word   _composite_external_spi_read
_composite_lookup_read:
        .word   _memory_provider_read
_provider_image:
        .zero   3
_provider_offset:
        .zero   3
_provider_destination:
        .zero   3
_provider_count:
        .zero   3
_provider_limit:
        .zero   3
_provider_status:
        .zero   3
_provider_fail_next:
        .byte   0
_block_cursor:
        .zero   3
_block_remaining:
        .zero   3
_block_within:
        .zero   3
_block_fetch_count:
        .zero   3
_spi_fetch_count:
        .zero   3
_spi_cache_hit_count:
        .zero   3
_spi_requested_block:
        .zero   3
_spi_cached_block:
        .zero   3
_spi_cache_valid:
        .byte   0
_spi_provider_active:
        .byte   0
_sd_cache_valid:
        .byte   0
_sd_cached_sector:
        .zero   3
_sd_requested_sector:
        .zero   3
_sd_fetch_count:
        .zero   3
_sd_cursor:
        .zero   3
_sd_remaining:
        .zero   3
_sd_within:
        .zero   3
_sd_read_status:
        .zero   3
_sd_sector_buffer:
        .zero   512
_composite_resident_only:
        .byte   0
_block_buffer:
        .zero   8
_block_header_buffer:
        .zero   8
_block_catalog_buffer:
        .zero   120
_block_catalog_crc:
        .zero   3
_block_name_buffer:
        .zero   16
_block_find_remaining:
        .zero   3
_block_find_offset:
        .zero   3
_block_find_table:
        .zero   3
_block_find_ordinal:
        .byte   0
_provider_word_buffer:
        .zero   3
_spi_extent_buffer:
        .zero   8
_spi_extent_offset:
        .zero   3
_spi_extent_length:
        .zero   3
_spi_source_descriptor:
        .zero   3
_embedded_magic_buffer:
        .zero   6
_embedded_magic_expected:
        .byte   67,50,52,73,77,71
_spi_descriptor:
        .zero   24
_embedded_descriptor:
        .zero   3
_embedded_image_base:
        .zero   3
_embedded_text_words:
        .zero   3
_embedded_data_words:
        .zero   3
_embedded_bss_words:
        .zero   3
_embedded_entry_words:
        .zero   3
_embedded_checksum:
        .zero   3
_embedded_load_status:
        .zero   3
_embedded_bound_read:
        .zero   3
_spawn_status:
        .zero   3
_spawn_arena_mark:
        .zero   3
_crc_cursor:
        .zero   3
_crc_remaining:
        .zero   3
_crc_low:
        .zero   3
_crc_high:
        .byte   0
_crc_bits:
        .byte   0
_crc_lsb:
        .byte   0
_ebr_next:
        .word   0xFEEB00
_child_count:
        .byte   0
_banner:
        .byte   83,80,65,87,78,10,0
_state_free:
        .byte   70,82,69,69,0
_state_runnable:
        .byte   82,85,78,78,65,66,76,69,0
_state_unknown:
        .byte   85,78,75,78,79,87,78,0
_provider_bounds_message:
        .byte   66,79,85,78,68,83,10,0
_block_provider_message:
        .byte   66,76,79,67,75,10,0
_spi_provider_message:
        .byte   83,80,73,32,67,65,67,72,69,10,0
_sd_provider_message:
        .byte   83,68,32,67,65,67,72,69,10,0
_recovery_reclaim_message:
        .byte   82,69,67,76,65,73,77,69,68,10,0
_descriptor_snapshot_message:
        .byte   83,78,65,80,83,72,79,84,10,0
_mixed_descriptor_message:
        .byte   77,73,88,69,68,10,0
_mixed_reverse_descriptor_message:
        .byte   82,69,86,69,82,83,69,10,0
