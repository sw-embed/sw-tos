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
        ; Establish the current process before anything can emit output.
        ; The TTY path charges bytes to _current_proc's statistics, and the
        ; boot banner below is written before the shell is spawned, so leaving
        ; this null meant the kernel updated statistics through a null
        ; descriptor. That wrote into low memory whenever the statistics
        ; pointer was computed by arithmetic; the former compare chain hid it
        ; by falling through to the last slot and corrupting its counters
        ; instead. Boot output belongs to the shell's context.
        la      r0,_proc_a
        la      r2,_current_proc
        sw      r0,0(r2)
        la      r2,_tty_foreground_proc
        sw      r0,0(r2)

        ; The heap base is a link-time address, so it cannot be a .word
        ; initializer. Establish it before the first spawn allocates.
        la      r0,_swtos_image_end
        la      r2,_heap_next
        sw      r0,0(r2)
        la      r2,_heap_peak_next
        sw      r0,0(r2)
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
        la      r2,_shell_bind_descriptors
        jal     r1,(r2)
        ; Retain the stack top a restart rewinds to. _spawn_resident has just
        ; left the saved SP twelve bytes below it.
        la      r2,_proc_a
        lw      r0,9(r2)
        add     r0,12
        la      r2,_shell_stack_top
        sw      r0,0(r2)
        la      r0,_scheduled_shell_descriptor
        la      r2,_shell_descriptor
        sw      r0,0(r2)

        ; Endpoint identities belong to process-table slots, including FREE
        ; slots, so process inspection remains stable before first spawn.
        ; Slot N holds endpoint N+1; the walk in _proc_for_endpoint reads these
        ; rather than assuming that relationship.
        la      r2,_proc_table
        lc      r0,1
        la      r1,_boot_endpoint
        sw      r0,0(r1)
_boot_endpoint_loop:
        la      r1,_boot_endpoint
        lw      r0,0(r1)
        sw      r0,18(r2)
        add     r0,1
        sw      r0,0(r1)
        lcu     r0,172          ; one slot; see the add-immediate note above
        add     r2,r0
        la      r1,_proc_table_end
        mov     r0,r2
        ceq     r0,r1
        brf     _boot_endpoint_loop

        la      r0,_proc_a
        la      r2,_current_proc
        sw      r0,0(r2)
        la      r2,_tty_foreground_proc
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
        la      r2,_preemption_init
        jal     r1,(r2)
        la      r2,_restore_context
        jmp     (r2)

; Point the shell's private state at the programs its menu can select. Boot
; and restart both bind them, so a restarted shell has the same menu as a
; freshly booted one.
_shell_bind_descriptors:
        push    r1
        push    r2
        la      r2,_proc_a
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
        pop     r2
        pop     r1
        jmp     (r1)

; Ask for the shell to be restarted at its next kernel entry. r0 is not
; preserved.
_request_shell_restart:
        push    r1
        push    r2
        lc      r0,1
        la      r2,_shell_restart_pending
        sw      r0,0(r2)
        ; Wake it as well. A shell blocked for input it is never going to get
        ; is not dispatched again on its own, and a request can only be seen by
        ; a process that runs. It is about to be rewound past whatever it was
        ; waiting for, so runnable is what it now is.
        la      r2,_proc_a
        sw      r0,24(r2)       ; PROC_RUNNABLE
        pop     r2
        pop     r1
        jmp     (r1)

; Request a complete warm SWTOS restart at the shell's next safe kernel
; boundary. This can be raised directly by the UART ISR even when the shell no
; longer consumes its TTY. It deliberately preserves the loaded image and the
; negotiated transport mode.
_request_system_reboot:
        push    r1
        push    r2
        lc      r0,1
        la      r2,_system_reboot_pending
        sw      r0,0(r2)
        la      r2,_proc_a
        sw      r0,24(r2)       ; wake shell
        pop     r2
        pop     r1
        jmp     (r1)

; Rewind the shell to its entry point and resume it. This never returns.
;
; The shell is the one process with no way out: it is protected from kill
; because the session dies with it, and it is not one of the private images the
; runway can force to quiesce. A command it runs in its own context therefore
; owns the CPU until it chooses to give it back, and one that never does takes
; the session with it.
;
; A restart is safe where a kill would not be, precisely because it keeps
; everything. The slot, its private state and its stack all stay where they
; are, and only the call stack is discarded -- so nothing is allocated, nothing
; is freed, and repeating it costs nothing. What is thrown away is whatever the
; shell was in the middle of, which in the case this exists for is a command
; that was never going to finish.
_restart_shell:
        ; Clear the request first: a restart that faulted its way back here
        ; would otherwise never make progress.
        lc      r0,0
        la      r2,_shell_restart_pending
        sw      r0,0(r2)
        ; Whatever was running in the shell's context goes with the context.
        la      r2,_sync_active
        sw      r0,0(r2)

        ; Fabricate the same initial context _spawn_resident builds, at the
        ; same stack top, reusing the private state that is already allocated.
        la      r2,_proc_a
        la      r0,_shell_stack_top
        lw      r0,0(r0)
        lw      r1,36(r2)
        sw      r1,-3(r0)       ; initial r0 = state pointer
        ; From the retained copy, not from the slot: the slot may be naming a
        ; program it is running synchronously, which is often the very thing
        ; being restarted away from.
        la      r1,_shell_descriptor
        lw      r1,0(r1)
        sw      r1,33(r2)
        lw      r1,6(r1)        ; direct resident entry
        sw      r1,-6(r0)       ; initial r1/PC
        lc      r1,0
        sw      r1,-9(r0)       ; initial r2
        sw      r1,-12(r0)      ; initial fp
        add     r0,-12
        sw      r0,9(r2)        ; saved SP

        ; Drop input typed at the command that is being abandoned. Whatever the
        ; operator pressed while waiting for it was meant for that command, not
        ; for the prompt they are about to get back.
        la      r0,_proc_a
        la      r2,_tty_for_proc
        jal     r1,(r2)
        mov     r2,r0
        lc      r0,0
        sw      r0,0(r2)        ; read cursor
        sw      r0,3(r2)        ; write cursor
        sw      r0,6(r2)        ; queued count

        la      r2,_shell_bind_descriptors
        jal     r1,(r2)

        la      r2,_proc_a
        lc      r0,1
        sw      r0,24(r2)       ; PROC_RUNNABLE
        la      r0,_proc_a
        la      r2,_current_proc
        sw      r0,0(r2)
        la      r2,_tty_foreground_proc
        sw      r0,0(r2)

        la      r0,_restart_banner
        la      r2,_puts
        jal     r1,(r2)

        la      r2,_proc_a
        lw      r0,9(r2)
        mov     sp,r0
        la      r2,_restore_context
        jmp     (r2)

; Act on a pending restart request, if the current process is the shell. Called
; from the kernel entries a running command must pass through.
_shell_restart_check:
        push    r1
        push    r2
        push    r0
        la      r2,_current_proc
        lw      r0,0(r2)
        la      r2,_proc_a
        ceq     r0,r2
        brf     _shell_restart_check_done
        la      r2,_system_reboot_pending
        lw      r0,0(r2)
        ceq     r0,z
        brt     _shell_restart_check_shell_only
        la      r2,_warm_reboot
        jmp     (r2)
_shell_restart_check_shell_only:
        la      r2,_shell_restart_pending
        lw      r0,0(r2)
        ceq     r0,z
        brt     _shell_restart_check_done
        la      r2,_restart_shell
        jmp     (r2)
_shell_restart_check_done:
        pop     r0
        pop     r2
        pop     r1
        jmp     (r1)

; Reset all state owned by endpoints 2..16 and rewind the persistent shell.
; Each complete 172-byte child record is cleared, then its stable endpoint is
; restored. This removes stale statistics, preemption sidecars and TTY bytes,
; not merely the visible PROC_STATE field.
_warm_reboot:
        lc      r0,0
        la      r2,_system_reboot_pending
        sw      r0,0(r2)
        la      r0,_system_reboot_banner
        la      r2,_puts
        jal     r1,(r2)
        la      r2,_proc_b
        lc      r1,2
_warm_reboot_slot:
        push    r1
        push    r2
        mov     r0,r2
        lcu     r1,172
        add     r1,r0
_warm_reboot_clear:
        lc      r2,0
        sb      r2,0(r0)
        add     r0,1
        ceq     r0,r1
        brf     _warm_reboot_clear
        pop     r2
        pop     r1
        sw      r1,18(r2)       ; stable endpoint identity
        add     r1,1
        lcu     r0,172
        add     r2,r0
        push    r2
        mov     r0,r2
        la      r2,_proc_table_end
        ceq     r0,r2
        pop     r2
        brf     _warm_reboot_slot
        lc      r0,0
        la      r2,_child_count
        sb      r0,0(r2)
        la      r2,_spawn_arena_mark
        lw      r0,0(r2)
        la      r2,_stack_next
        sw      r0,0(r2)
        la      r2,_spawn_heap_mark
        lw      r0,0(r2)
        la      r2,_heap_next
        sw      r0,0(r2)
        la      r2,_restart_shell
        jmp     (r2)

        .globl  _TASK_REBOOT
_TASK_REBOOT:
        la      r2,_warm_reboot
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
        la      r2,_stack_next
        sw      r0,0(r2)
        la      r2,_spawn_heap_mark
        lw      r0,0(r2)
        la      r2,_heap_next
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
        la      r2,_stack_next
        sw      r0,0(r2)
        la      r2,_spawn_heap_mark
        lw      r0,0(r2)
        la      r2,_heap_next
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
        la      r2,_current_proc
        lw      r0,0(r2)
        la      r2,_stats_for_proc
        jal     r1,(r2)
        add     r0,9
        la      r2,_stats_increment
        jal     r1,(r2)
        lc      r0,0
        la      r2,_spawn_status
        sw      r0,0(r2)
        la      r2,_child_count
        lbu     r0,0(r2)
        ceq     r0,z
        brf     _spawn_have_arena_mark
        la      r2,_stack_next
        lw      r0,0(r2)
        la      r2,_spawn_arena_mark
        sw      r0,0(r2)       ; app allocations are reclaimed at TASK_EXIT
        la      r2,_heap_next
        lw      r0,0(r2)
        la      r2,_spawn_heap_mark
        sw      r0,0(r2)
_spawn_have_arena_mark:
        la      r2,_proc_b
_spawn_find_slot:
        lw      r0,24(r2)
        ceq     r0,z
        brt     _spawn_slot_found
        lcu     r0,172          ; one slot; see the add-immediate note above
        add     r2,r0
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
        ; _spawn_resident rebuilds the descriptor and clears its endpoint, so
        ; keep the identity boot gave this slot and restore it afterwards.
        lw      r0,18(r2)
        la      r1,_spawn_endpoint_save
        sw      r0,0(r1)
        mov     r0,r2
        la      r2,_stats_for_proc
        jal     r1,(r2)
        mov     r2,r0
        lc      r0,0
        sw      r0,0(r2)
        sw      r0,3(r2)
        sw      r0,6(r2)
        sw      r0,9(r2)
        sw      r0,12(r2)
        sw      r0,15(r2)
        sw      r0,18(r2)
        sw      r0,21(r2)
        lw      r0,9(fp)        ; selected PROGRAM_DESC pointer
        la      r2,_spawn_resident
        jal     r1,(r2)
        ceq     r0,z
        brf     _spawn_child_done
        la      r2,_spawn_process
        lw      r2,0(r2)
        la      r1,_spawn_endpoint_save
        lw      r0,0(r1)
        sw      r0,18(r2)
        la      r1,_tty_foreground_proc
        sw      r2,0(r1)
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

; TASK_FRONTEND_ATTACHED(destination): report whether a framed frontend drives
; this target (1) or it is running on a bare UART (0). Only a framed frontend
; sends the heartbeat, and the heartbeat is what forces preemption, so a
; process that never yields is survivable in the first case and fatal in the
; second.
        .globl  _TASK_FRONTEND_ATTACHED
_TASK_FRONTEND_ATTACHED:
        push    fp
        push    r2
        push    r1
        mov     fp,sp
        la      r2,_protocol_framed_mode
        lbu     r0,0(r2)
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
        la      r2,_stack_next
        lw      r1,0(r2)
        la      r2,_allocation_old_high
        sw      r1,0(r2)
        la      r2,0x100000
        sub     r2,r1           ; current stack-region bytes
        add     r0,r2           ; proposed stack-region bytes
        la      r2,0x010000     ; 64 KB of SRAM: 16 slots at 4 KB
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
        la      r2,_stack_next
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

; Reserve r0 words from the SRAM heap and return the low base address, or
; zero on exhaustion. The heap grows upward from the end of the linked image
; toward the process-stack region, so the two arenas approach each other from
; opposite ends of free SRAM and the check below is where they meet.
;
; Loaded image text, its preemption shadow, and private process state come
; from here rather than from EBR: a loaded image costs twice its size because
; the preemption runway restores overwritten text from the shadow, and the
; 3 KB EBR window could not hold an app of any useful size.
_reserve_heap_words:
        push    r1
        push    r2
        la      r2,_allocation_failed
        lc      r1,0
        sb      r1,0(r2)
        mov     r1,r0
        add     r0,r1
        add     r0,r1           ; requested bytes = words * 3
        la      r2,_heap_next
        lw      r1,0(r2)        ; r1 = allocation base
        add     r0,r1           ; r0 = proposed new high water
        la      r2,0x0F0000     ; floor of the process-stack region
        cls     r2,r0
        brt     _reserve_heap_failed
        la      r2,_heap_peak_next
        lw      r1,0(r2)
        cls     r1,r0
        brf     _reserve_heap_keep_peak
        sw      r0,0(r2)
_reserve_heap_keep_peak:
        la      r2,_heap_next
        lw      r1,0(r2)        ; base to return
        sw      r0,0(r2)        ; commit the new high water
        mov     r0,r1
        bra     _reserve_heap_done
_reserve_heap_failed:
        la      r2,_allocation_failed
        lc      r1,1
        sb      r1,0(r2)
        la      r2,_allocation_failures
        lw      r0,0(r2)
        add     r0,1
        sw      r0,0(r2)
        lc      r0,0
_reserve_heap_done:
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
        la      r2,_reserve_heap_words
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
        la      r2,_stack_next
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

        ; Reserve a recoverable private layout in this child generation:
        ;
        ;   live text+data+BSS | 2-word landing slot | live-size shadow
        ;
        ; Forced preemption temporarily carpets the whole live region because
        ; execution must reach a landing address immediately beyond it.  The
        ; equally sized shadow therefore protects mutable data/BSS as well as
        ; text.  Two words keep the landing allocation word-aligned while
        ; providing room for a four-byte C7 absolute jump.
        la      r2,_embedded_text_words
        lw      r0,0(r2)
        la      r2,_embedded_data_words
        lw      r1,0(r2)
        add     r0,r1
        la      r2,_embedded_bss_words
        lw      r1,0(r2)
        add     r0,r1
        la      r2,_embedded_live_words
        sw      r0,0(r2)
        mov     r1,r0
        add     r0,r1
        add     r0,2
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

        ; Retain runway allocation bounds outside the stable PROC_DESC ABI.
        push    r0
        mov     r0,r2
        la      r2,_preempt_for_proc
        jal     r1,(r2)
        mov     r2,r0
        pop     r0
        sw      r0,0(r2)        ; live image base
        la      r1,_embedded_live_words
        lw      r1,0(r1)
        sw      r1,3(r2)        ; live image words
        mov     r0,r1
        add     r0,r1
        add     r0,r1           ; live image bytes
        lw      r1,0(r2)
        add     r0,r1
        sw      r0,6(r2)        ; landing slot base
        add     r0,6
        sw      r0,9(r2)        ; live shadow base
        ; Private allocation alone is insufficient: an IRQ continuation could
        ; be inside shared code. Only an explicitly certified leaf image with
        ; no external control transfers may enter the ADD runway.
        la      r0,_embedded_descriptor
        lw      r0,0(r0)
        lw      r0,21(r0)
        lc      r1,64
        and     r0,r1
        ceq     r0,r1
        brf     _embedded_not_runway_eligible
        lc      r0,1
        bra     _embedded_store_runway_eligible
_embedded_not_runway_eligible:
        lc      r0,0
_embedded_store_runway_eligible:
        sw      r0,21(r2)       ; structurally certified forced-preemption leaf
        lc      r0,0
        sw      r0,24(r2)       ; no saved IRQ context yet
        sw      r0,27(r2)       ; no interrupted-r0 sample yet
        sw      r0,30(r2)       ; no asynchronous kill request
        lw      r0,0(r2)        ; preserve loader's allocation-base result

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
        lw      r0,0(r2)
        la      r2,_stats_for_proc
        jal     r1,(r2)
        add     r0,6
        la      r2,_stats_increment
        jal     r1,(r2)
        la      r2,_current_proc
        lw      r2,0(r2)
        mov     r0,sp
        sw      r0,9(r2)
_scan_runnable:
        push    r2
        ; A framed terminal keystroke occupies a complete SWT frame, and the
        ; frontend also requests Resources periodically. Draining only one
        ; byte per 50 ms forced switch cannot keep up and eventually drops
        ; shell/debug traffic. Consume a bounded batch while already in the
        ; scheduler's shared-code safe region, then preserve round-robin
        ; selection latency by returning to process dispatch after 64 bytes.
        lc      r0,64
_scan_uart_batch:
        push    r0
        la      r2,_tty_poll_uart
        jal     r1,(r2)
        pop     r0
        la      r2,_preemption_rx_count
        lw      r1,0(r2)
        ceq     r1,z
        brt     _scan_uart_batch_done
        add     r0,-1
        ceq     r0,z
        brf     _scan_uart_batch
_scan_uart_batch_done:
        pop     r2
        lcu     r0,172          ; one slot; see the add-immediate note above
        add     r2,r0
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
        push    r2
        push    r1
        push    r0
        mov     r0,r2
        la      r2,_stats_for_proc
        jal     r1,(r2)
        add     r0,3
        la      r2,_stats_increment
        jal     r1,(r2)
        pop     r0
        pop     r1
        pop     r2
        push    r2
        la      r1,_preemption_prepare_dispatch
        jal     r1,(r1)
        pop     r2
        ceq     r0,z
        brf     _select_interrupt_context
        lw      r0,9(r2)
        mov     sp,r0
        bra     _restore_context
_select_interrupt_context:
        la      r1,_preemption_restore_interrupt
        jmp     (r1)
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

_plsw_mon_trampoline:
        push    r0
        la      r2,_PLSW_MON
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
        la      r2,_shell_restart_check
        jal     r1,(r2)
        la      r2,_yield
        jal     r1,(r2)
        mov     sp,fp
        pop     r1
        pop     r2
        pop     fp
        jmp     (r1)

; TASK_GETCHAR(destination): blocking read from the current process's virtual
; TTY. The scheduler polls the recovery UART and wakes the foreground owner.
        .globl  _TASK_GETCHAR
_TASK_GETCHAR:
        push    fp
        push    r2
        push    r1
        mov     fp,sp
_task_getchar_wait:
        ; Every time around, not only on the way in: a shell waiting here for a
        ; key it will never be given is exactly the case a restart answers.
        la      r2,_shell_restart_check
        jal     r1,(r2)
        la      r2,_current_proc
        lw      r0,0(r2)
        la      r2,_tty_for_proc
        jal     r1,(r2)
        mov     r2,r0
        lw      r0,6(r2)
        ceq     r0,z
        brf     _task_getchar_ready
        la      r2,_current_proc
        lw      r2,0(r2)
        lc      r0,7
        sw      r0,24(r2)       ; PROC_BLOCKED_TTY
        la      r2,_yield
        jal     r1,(r2)
        bra     _task_getchar_wait
_task_getchar_ready:
        lw      r0,0(r2)
        push    r2
        add     r2,12
        add     r2,r0
        lbu     r0,0(r2)
        pop     r2
        lw      r1,0(r2)
        add     r1,1
        lc      r0,63
        and     r1,r0
        sw      r1,0(r2)
        lw      r1,6(r2)
        add     r1,-1
        sw      r1,6(r2)
        ; Recover the byte at the previous head position.
        lw      r1,0(r2)
        add     r1,-1
        lc      r0,63
        and     r1,r0
        add     r2,12
        add     r2,r1
        lbu     r0,0(r2)
        lw      r2,9(fp)
        sb      r0,0(r2)
        push    r0
        la      r2,_current_proc
        lw      r0,0(r2)
        la      r2,_stats_for_proc
        jal     r1,(r2)
        add     r0,18
        la      r2,_stats_increment
        jal     r1,(r2)
        pop     r0
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
        push    r2
        ; Endpoints run past nine now, so '0'+n would print ten as ':'. Emit a
        ; leading digit when there is one; the table tops out well under twenty.
        lc      r1,10
        cls     r0,r1
        brt     _task_process_list_units
        push    r0
        lc      r0,49
        la      r2,_putchar
        jal     r1,(r2)
        pop     r0
        add     r0,-10
_task_process_list_units:
        add     r0,48
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
        lc      r1,7
        ceq     r0,r1
        brt     _task_process_list_blocked
        la      r0,_state_unknown
        bra     _task_process_list_state
_task_process_list_free:
        la      r0,_state_free
        bra     _task_process_list_state
_task_process_list_blocked:
        la      r0,_state_blocked
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
        lcu     r0,172          ; one slot; see the add-immediate note above
        add     r2,r0
        la      r1,_proc_table_end
        mov     r0,r2
        ceq     r0,r1
        brf     _task_process_list_next
        mov     sp,fp
        pop     r1
        pop     r2
        pop     fp
        jmp     (r1)

; TASK_PROCESS_INFO(endpoint, result): return status, blocked reason,
; configured stack/state words, dispatches, yields, IPC operations, TTY input
; and output bytes, and the catalog descriptor pointer. Blocked reason is zero
; until the virtual-TTY saga introduces blocking process states.
        .globl  _TASK_PROCESS_INFO
_TASK_PROCESS_INFO:
        push    fp
        push    r2
        push    r1
        mov     fp,sp
        lw      r0,9(fp)
        la      r2,_proc_for_endpoint
        jal     r1,(r2)
        ceq     r0,z
        brt     _task_process_info_invalid
        mov     r2,r0
        add     r0,39
_task_process_info_selected:
        push    r0
        lw      r1,12(fp)
        lw      r0,24(r2)
        sw      r0,0(r1)
        lc      r0,0
        sw      r0,3(r1)
        lw      r0,24(r2)
        lc      r1,7
        ceq     r0,r1
        brf     _task_process_info_not_tty_blocked
        lw      r1,12(fp)
        lc      r0,1
        sw      r0,3(r1)
_task_process_info_not_tty_blocked:
        lw      r1,12(fp)
        lw      r0,33(r2)
        sw      r0,27(r1)
        ceq     r0,z
        brt     _task_process_info_no_descriptor
        lw      r2,15(r0)
        sw      r2,6(r1)
        lw      r2,18(r0)
        sw      r2,9(r1)
        bra     _task_process_info_copy_stats
_task_process_info_no_descriptor:
        lc      r0,0
        sw      r0,6(r1)
        sw      r0,9(r1)
_task_process_info_copy_stats:
        pop     r2
        lw      r0,3(r2)
        sw      r0,12(r1)
        lw      r0,6(r2)
        sw      r0,15(r1)
        lw      r0,9(r2)
        sw      r0,18(r1)
        lw      r0,18(r2)
        sw      r0,21(r1)
        lw      r0,21(r2)
        sw      r0,24(r1)
        bra     _task_process_info_done
_task_process_info_invalid:
        lw      r1,12(fp)
        lc      r0,0
        sw      r0,0(r1)
        sw      r0,3(r1)
        sw      r0,6(r1)
        sw      r0,9(r1)
        sw      r0,12(r1)
        sw      r0,15(r1)
        sw      r0,18(r1)
        sw      r0,21(r1)
        sw      r0,24(r1)
        sw      r0,27(r1)
_task_process_info_done:
        mov     sp,fp
        pop     r1
        pop     r2
        pop     fp
        jmp     (r1)

; TASK_PROCESS_PRINT(endpoint): render one detailed process snapshot. Keeping
; the repetitive formatting in the kernel avoids inflating the bootstrap PL/SW
; compiler workload while TASK_PROCESS_INFO remains the structured interface.
        .globl  _TASK_PROCESS_PRINT
_TASK_PROCESS_PRINT:
        push    fp
        push    r2
        push    r1
        mov     fp,sp
        add     sp,-30
        mov     r0,sp
        push    r0
        lw      r0,9(fp)
        push    r0
        la      r2,_TASK_PROCESS_INFO
        jal     r1,(r2)
        add     sp,6
        la      r0,_SHELL_PROC_EP
        la      r2,_puts
        jal     r1,(r2)
        lw      r0,9(fp)
        la      r2,_print_stat_int
        jal     r1,(r2)
        la      r0,_SHELL_PROC_NAME
        la      r2,_puts
        jal     r1,(r2)
        lw      r0,-3(fp)
        ceq     r0,z
        brt     _task_process_print_no_name
        lw      r0,0(r0)
        bra     _task_process_print_name
_task_process_print_no_name:
        la      r0,_SHELL_PROC_NONE
_task_process_print_name:
        la      r2,_puts
        jal     r1,(r2)
        la      r0,_SHELL_PROC_STATUS
        la      r2,_puts
        jal     r1,(r2)
        lw      r0,-30(fp)
        la      r2,_print_stat_int
        jal     r1,(r2)
        la      r0,_SHELL_PROC_BLOCKED
        la      r2,_puts
        jal     r1,(r2)
        lw      r0,-27(fp)
        la      r2,_print_stat_int
        jal     r1,(r2)
        la      r0,_SHELL_PROC_STACK
        la      r2,_puts
        jal     r1,(r2)
        lw      r0,-24(fp)
        la      r2,_print_stat_int
        jal     r1,(r2)
        la      r0,_SHELL_PROC_STATE_WORDS
        la      r2,_puts
        jal     r1,(r2)
        lw      r0,-21(fp)
        la      r2,_print_stat_int
        jal     r1,(r2)
        la      r0,_SHELL_PROC_DISPATCH
        la      r2,_puts
        jal     r1,(r2)
        lw      r0,-18(fp)
        la      r2,_print_stat_int
        jal     r1,(r2)
        la      r0,_SHELL_PROC_YIELDS
        la      r2,_puts
        jal     r1,(r2)
        lw      r0,-15(fp)
        la      r2,_print_stat_int
        jal     r1,(r2)
        la      r0,_SHELL_PROC_IPC
        la      r2,_puts
        jal     r1,(r2)
        lw      r0,-12(fp)
        la      r2,_print_stat_int
        jal     r1,(r2)
        la      r0,_SHELL_PROC_TTY_IN
        la      r2,_puts
        jal     r1,(r2)
        lw      r0,-9(fp)
        la      r2,_print_stat_int
        jal     r1,(r2)
        la      r0,_SHELL_PROC_TTY_OUT
        la      r2,_puts
        jal     r1,(r2)
        lw      r0,-6(fp)
        la      r2,_print_stat_int
        jal     r1,(r2)
        lc      r0,10
        la      r2,_putchar
        jal     r1,(r2)
        mov     sp,fp
        pop     r1
        pop     r2
        pop     fp
        jmp     (r1)

_print_stat_int:
        push    fp
        push    r2
        push    r1
        mov     fp,sp
        add     sp,-18
        sw      r0,-3(fp)
        lc      r0,0
        sw      r0,-6(fp)
        lw      r0,-3(fp)
        ceq     r0,z
        brf     _print_stat_digits
        lc      r0,48
        la      r2,_putchar
        jal     r1,(r2)
        bra     _print_stat_done
_print_stat_digits:
        lw      r0,-3(fp)
        la      r2,_stats_div10
        jal     r1,(r2)
        sw      r0,-3(fp)
        add     r2,48
        push    r2
        lw      r0,-6(fp)
        mov     r2,r0
        add     r2,-18
        add     r2,fp
        pop     r0
        sb      r0,0(r2)
        lw      r0,-6(fp)
        add     r0,1
        sw      r0,-6(fp)
        lw      r0,-3(fp)
        ceq     r0,z
        brf     _print_stat_digits
_print_stat_emit:
        lw      r0,-6(fp)
        add     r0,-1
        sw      r0,-6(fp)
        mov     r2,r0
        add     r2,-18
        add     r2,fp
        lbu     r0,0(r2)
        la      r2,_putchar
        jal     r1,(r2)
        lw      r0,-6(fp)
        ceq     r0,z
        brf     _print_stat_emit
_print_stat_done:
        mov     sp,fp
        pop     r1
        pop     r2
        pop     fp
        jmp     (r1)

; Divide unsigned r0 by ten, returning quotient in r0 and remainder in r2.
_stats_div10:
        push    r1
        lc      r1,0
_stats_div10_loop:
        lc      r2,10
        clu     r0,r2
        brt     _stats_div10_done
        sub     r0,r2
        add     r1,1
        bra     _stats_div10_loop
_stats_div10_done:
        mov     r2,r0
        mov     r0,r1
        pop     r1
        jmp     (r1)

; _release_slot(r0 = slot): mark it free and forget what ran there.
;
; Clearing the state alone left the descriptor and the counters standing, so
; ps listed a free slot under its last program's name with that program's
; figures beside it -- a process that had been killed still looked present.
_release_slot:
        push    r1
        push    r2
        mov     r2,r0
        lc      r0,0
        sw      r0,24(r2)       ; PROC_FREE
        sw      r0,33(r2)       ; no program
        ; Everything the previous tenant left behind, in one sweep: the eight
        ; statistics words at +39, the eleven preemption sidecar words at +63,
        ; and the TTY's cursors, count and drop tally at +96. They are
        ; contiguous, so twenty-three words covers all three.
        ;
        ; The sidecar is the one that mattered. It carries runway eligibility,
        ; and _kill_endpoint reads that to decide how to kill: an eligible
        ; process is torn down by the interrupt handler's landing, so its kill
        ; is queued and reported accepted. Leaving that flag set meant a slot
        ; that had once held a cpu-hog handed it to whatever came next -- and a
        ; clock or an uptime never spins, so it is never the process the
        ; handler interrupts, so the queued kill was never serviced. The kill
        ; was accepted and the process ran forever. It also carried the dead
        ; hog's forced-preemption count and interrupted-r0 sample, which ps and
        ; mon then reported against a program that had never been preempted.
        ;
        ; The TTY's 64 bytes of data need no clearing: a zero count is what
        ; makes them unreadable, and a new reader starts from that.
        add     r2,39
        lc      r1,23
_release_slot_stats:
        lc      r0,0
        sw      r0,0(r2)
        add     r2,3
        add     r1,-1
        ceq     r1,z
        brf     _release_slot_stats
        pop     r2
        pop     r1
        jmp     (r1)

; TASK_PRINT_UNSIGNED(value): print a 24-bit value as an unsigned decimal.
;
; PL/SW's own printer loops while the value is greater than zero, so anything
; with the top bit set printed nothing at all -- an interrupted-r0 sample is
; an arbitrary word and half of them look negative.
        .globl  _TASK_PRINT_UNSIGNED
_TASK_PRINT_UNSIGNED:
        push    fp
        push    r2
        push    r1
        mov     fp,sp
        lw      r0,9(fp)
        la      r2,_print_stat_int
        jal     r1,(r2)
        mov     sp,fp
        pop     r1
        pop     r2
        pop     fp
        jmp     (r1)

; TASK_HEAP_INFO(result): bytes handed out of the loaded-image heap, and the
; most ever handed out. TASK_MEM_INFO reports the stack arena; these are the
; other half of the picture and appending them there would overrun the result
; structures callers have already declared.
        .globl  _TASK_HEAP_INFO
_TASK_HEAP_INFO:
        push    fp
        push    r2
        push    r1
        mov     fp,sp
        la      r2,_heap_next
        lw      r0,0(r2)
        la      r2,_swtos_image_end
        sub     r0,r2
        lw      r1,9(fp)
        sw      r0,0(r1)
        la      r2,_heap_peak_next
        lw      r0,0(r2)
        la      r2,_swtos_image_end
        sub     r0,r2
        lw      r1,9(fp)
        sw      r0,3(r1)
        mov     sp,fp
        pop     r1
        pop     r2
        pop     fp
        jmp     (r1)

; TASK_PRINT_PADDED(text, width): print a NUL-terminated string and pad it
; with spaces to `width`, so a column of them lines up. A caller in PL/SW
; cannot do this for itself: it has a pointer and no way to measure what it
; points at.
        .globl  _TASK_PRINT_PADDED
_TASK_PRINT_PADDED:
        push    fp
        push    r2
        push    r1
        mov     fp,sp
        lw      r2,9(fp)        ; text
        lw      r1,12(fp)       ; remaining width
_task_print_padded_next:
        lbu     r0,0(r2)
        ceq     r0,z
        brt     _task_print_padded_fill
        push    r1
        push    r2
        la      r2,_putchar
        jal     r1,(r2)
        pop     r2
        pop     r1
        add     r2,1
        add     r1,-1
        bra     _task_print_padded_next
_task_print_padded_fill:
        ; A name longer than the column is left whole; the row is wider than
        ; the others, which reads better than a truncated name.
        lc      r0,0
        cls     r1,r0
        brt     _task_print_padded_done
        ceq     r1,z
        brt     _task_print_padded_done
        push    r1
        lc      r0,32
        la      r2,_putchar
        jal     r1,(r2)
        pop     r1
        add     r1,-1
        bra     _task_print_padded_fill
_task_print_padded_done:
        mov     sp,fp
        pop     r1
        pop     r2
        pop     fp
        jmp     (r1)

; TASK_SPAWN_ENDPOINT(result): the endpoint the last spawn was given, so a
; caller can wait for that one child rather than for every child there is.
        .globl  _TASK_SPAWN_ENDPOINT
_TASK_SPAWN_ENDPOINT:
        push    fp
        push    r2
        push    r1
        mov     fp,sp
        la      r2,_spawn_endpoint_save
        lw      r0,0(r2)
        lw      r2,9(fp)
        sw      r0,0(r2)
        mov     sp,fp
        pop     r1
        pop     r2
        pop     fp
        jmp     (r1)

; TASK_JOIN_ENDPOINT(endpoint): wait for one process to finish.
;
; TASK_JOIN waits for the child count to reach zero, which means every child
; and not the one just started. That was harmless while children were things
; the operator launched and ended, and became a hang the moment the shell kept
; one of its own: a resident monitor never exits, so a join for a program that
; had already finished waited on it forever and took the prompt with it.
        .globl  _TASK_JOIN_ENDPOINT
_TASK_JOIN_ENDPOINT:
        push    fp
        push    r2
        push    r1
        mov     fp,sp
        ; Counted like the join it replaces, so the reported IPC figure keeps
        ; meaning the same thing.
        la      r2,_current_proc
        lw      r0,0(r2)
        la      r2,_stats_for_proc
        jal     r1,(r2)
        add     r0,9
        la      r2,_stats_increment
        jal     r1,(r2)
_task_join_endpoint_wait:
        lw      r0,9(fp)
        la      r2,_proc_for_endpoint
        jal     r1,(r2)
        ceq     r0,z
        brt     _task_join_endpoint_done
        mov     r2,r0
        lw      r0,24(r2)
        ceq     r0,z
        brt     _task_join_endpoint_done
        la      r2,_yield
        jal     r1,(r2)
        bra     _task_join_endpoint_wait
_task_join_endpoint_done:
        mov     sp,fp
        pop     r1
        pop     r2
        pop     fp
        jmp     (r1)

; TASK_CLAIM_FOREGROUND(): make the caller the process raw terminal input
; reaches. A spawn hands input focus to the new child, which is what a user
; wants when launching something interactive and exactly wrong for a service
; started on the caller's behalf: the shell would spawn its monitor and then
; never see another keystroke on a bare UART.
        .globl  _TASK_CLAIM_FOREGROUND
_TASK_CLAIM_FOREGROUND:
        push    r0
        push    r1
        push    r2
        la      r2,_current_proc
        lw      r0,0(r2)
        la      r2,_tty_foreground_proc
        sw      r0,0(r2)
        pop     r2
        pop     r1
        pop     r0
        jmp     (r1)

; TASK_PROCESS_PREEMPT_INFO(endpoint, result): forced-preemption count and the
; last interrupted-r0 sample. These are the two figures the resource snapshot
; reports that TASK_PROCESS_INFO does not, and they live in the preemption
; record rather than the descriptor. Kept as a separate call so adding them
; cannot overrun the result structure an existing caller declared.
        .globl  _TASK_PROCESS_PREEMPT_INFO
_TASK_PROCESS_PREEMPT_INFO:
        push    fp
        push    r2
        push    r1
        mov     fp,sp
        lw      r0,9(fp)
        la      r2,_proc_for_endpoint
        jal     r1,(r2)
        ceq     r0,z
        brt     _task_process_preempt_none
        la      r2,_preempt_for_proc
        jal     r1,(r2)
        mov     r2,r0
        lw      r1,12(fp)
        lw      r0,18(r2)
        sw      r0,0(r1)
        lw      r0,27(r2)
        sw      r0,3(r1)
        bra     _task_process_preempt_done
_task_process_preempt_none:
        lw      r1,12(fp)
        lc      r0,0
        sw      r0,0(r1)
        sw      r0,3(r1)
_task_process_preempt_done:
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
        la      r0,0x100000
        la      r1,_stack_next
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
        lc      r0,16
        sw      r0,21(r2)
        la      r0,0x010000     ; 64 KB process-stack region
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
        ; Resolve through the table. Naming only the first three slots sent
        ; every other endpoint to the third one's record, so a caller walking
        ; the table saw slot three's state sixteen times over and could not
        ; tell a live process from a free slot.
        lw      r0,9(fp)
        la      r2,_proc_for_endpoint
        jal     r1,(r2)
        lw      r1,12(fp)
        ceq     r0,z
        brt     _task_mem_process_none
        mov     r2,r0
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
_task_mem_process_none:
        lc      r0,0
        sw      r0,0(r1)
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
        la      r0,0x100000
        la      r2,_stack_next
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
        la      r2,_current_proc
        lw      r0,0(r2)
        la      r2,_stats_for_proc
        jal     r1,(r2)
        add     r0,9
        la      r2,_stats_increment
        jal     r1,(r2)
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

; TASK_RUN_SYNC(descriptor, result): run a program to completion in the
; caller's own context, on the caller's stack, instead of in a process of its
; own. This is what the shell falls back to when every slot is taken.
;
; It is deliberately narrow. Only a resident program can be run this way: an
; embedded one has to be loaded into memory owned by a process, and a process
; is the thing there is none of. Its state comes from one scratch block rather
; than the arena, so a shell that does this all day allocates nothing.
;
; The caller gives up the CPU for the duration. Nothing can preempt a program
; running here -- it is the shell, and the shell is not preemptible -- so a
; program that never finishes takes the session with it, and the way back is
; the restart escape.
;
; Status 0 ran, 1 needs a process of its own, 2 wants more state than the
; scratch block holds.
        .globl  _TASK_RUN_SYNC
_TASK_RUN_SYNC:
        push    fp
        push    r2
        push    r1
        mov     fp,sp
        lw      r0,9(fp)
        la      r2,_sync_descriptor
        sw      r0,0(r2)
        lw      r1,3(r0)        ; PROGRAM_DESC kind
        ceq     r1,z
        brt     _task_run_sync_resident
        lc      r0,1
        la      r2,_task_run_sync_status
        jmp     (r2)
_task_run_sync_resident:
        lw      r0,18(r0)       ; PROGRAM_DESC state_words
        lc      r1,8            ; _sync_state capacity
        clu     r1,r0
        brf     _task_run_sync_zero_state
        lc      r0,2
        la      r2,_task_run_sync_status
        jmp     (r2)
_task_run_sync_zero_state:
        la      r2,_sync_state
_task_run_sync_zero:
        ceq     r0,z
        brt     _task_run_sync_enter
        lc      r1,0
        sw      r1,0(r2)
        add     r2,3
        add     r0,-1
        bra     _task_run_sync_zero
_task_run_sync_enter:
        ; Where to come back to. A program may finish by returning or by
        ; calling TASK_EXIT, and TASK_EXIT never returns to its caller.
        ; Nothing has been pushed since fp was set, so one word covers both.
        mov     r0,sp
        la      r2,_sync_return_sp
        sw      r0,0(r2)
        lc      r0,1
        la      r2,_sync_active
        sw      r0,0(r2)
        ; Say what the slot is running. Everything that asks a process what it
        ; is reads this: the time broadcast finds a clock or an uptime by it,
        ; and ps and the monitor name a process by it. Left pointing at the
        ; shell, a synchronous clock was never sent a tick and never printed
        ; the time.
        la      r2,_proc_a
        lw      r0,33(r2)
        la      r2,_sync_saved_descriptor
        sw      r0,0(r2)
        la      r2,_sync_descriptor
        lw      r0,0(r2)
        la      r2,_proc_a
        sw      r0,33(r2)
        la      r2,_sync_descriptor
        lw      r2,0(r2)
        lw      r2,6(r2)        ; direct resident entry
        la      r0,_sync_state
        jal     r1,(r2)
_task_run_sync_returned:
        la      r2,_sync_saved_descriptor
        lw      r0,0(r2)
        la      r2,_proc_a
        sw      r0,33(r2)
        lc      r0,0
        la      r2,_sync_active
        sw      r0,0(r2)
        lc      r0,0
_task_run_sync_status:
        lw      r1,12(fp)
        sw      r0,0(r1)
        mov     sp,fp
        pop     r1
        pop     r2
        pop     fp
        jmp     (r1)

; TASK_EXIT(): terminate a child slot and resume the persistent shell.
        .globl  _TASK_EXIT
_TASK_EXIT:
        la      r2,_current_proc
        lw      r2,0(r2)
        la      r1,_exit_proc
        sw      r2,0(r1)
        ; A program running synchronously in the shell exits like any other,
        ; but it has no slot to release and the shell must survive it. Guarded
        ; on the shell being current, so a child of a synchronous program still
        ; exits as a process.
        la      r1,_proc_a
        mov     r0,r2
        ceq     r0,r1
        brf     _task_exit_process
        la      r2,_sync_active
        lw      r0,0(r2)
        ceq     r0,z
        brt     _task_exit_process
        lc      r0,0
        sw      r0,0(r2)
        la      r2,_sync_return_sp
        lw      r0,0(r2)
        mov     sp,r0
        mov     fp,sp
        la      r2,_task_run_sync_returned
        jmp     (r2)
_task_exit_process:
        la      r2,_exit_proc
        lw      r2,0(r2)
        lbu     r0,18(r2)
        lc      r1,1
        ceq     r0,r1
        brf     _task_exit_release
        la      r2,_TASK_HALT
        jmp     (r2)
_task_exit_release:
        mov     r0,r2
        la      r2,_release_slot
        jal     r1,(r2)
        la      r2,_child_count
        lbu     r0,0(r2)
        add     r0,-1
        sb      r0,0(r2)
        ceq     r0,z
        brf     _task_exit_keep_arena
        ; The last child releases the allocation generation.
        la      r2,_spawn_arena_mark
        lw      r0,0(r2)
        la      r2,_stack_next
        sw      r0,0(r2)
        la      r2,_spawn_heap_mark
        lw      r0,0(r2)
        la      r2,_heap_next
        sw      r0,0(r2)
_task_exit_keep_arena:
        la      r2,_proc_a
        la      r1,_current_proc
        sw      r2,0(r1)
        ; The terminal goes back to the prompt, and only if the process that
        ; just exited held it. It used to pass to whichever of the first two
        ; child slots was occupied, which handed it to the monitor -- and a
        ; monitor blocks reading its own terminal, waiting for clock ticks
        ; rather than for a person, so the prompt never saw another keystroke.
        ; Being blocked on input does not mean wanting the keyboard. A program
        ; that wants it asks, with TASK_CLAIM_FOREGROUND.
        la      r2,_exit_proc
        lw      r1,0(r2)
        la      r2,_tty_foreground_proc
        lw      r0,0(r2)
        ceq     r0,r1
        brf     _task_exit_focus_kept
        la      r0,_proc_a
        sw      r0,0(r2)
_task_exit_focus_kept:
        la      r2,_proc_a
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
        la      r2,_shell_restart_check
        jal     r1,(r2)
        push    r0
        la      r2,_current_proc
        lw      r0,0(r2)
        la      r2,_stats_for_proc
        jal     r1,(r2)
        add     r0,21
        la      r2,_stats_increment
        jal     r1,(r2)
        pop     r0
        la      r2,_protocol_framed_mode
        lbu     r1,0(r2)
        ceq     r1,z
        brt     _putchar_wait
        la      r2,_protocol_putchar_tty
        jal     r1,(r2)
        pop     r2
        pop     r1
        jmp     (r1)
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

; Emit one ordered TTY_OUTPUT frame for the current process. Output has no
; target-side queue: UART hardware flow control supplies backpressure.
_protocol_putchar_tty:
        push    r0
        push    r1
        push    r2
        la      r2,_protocol_tx_byte
        sb      r0,0(r2)
        ; The frame channel is the process's own endpoint, less one so the
        ; shell keeps channel zero. This was a compare chain that knew only
        ; about the first two child slots: every other process emitted on
        ; channel zero, so a frontend folded thirteen applications' output
        ; into the shell's pane and could not give any of them a window.
        la      r2,_current_proc
        lw      r2,0(r2)
        lw      r0,18(r2)
        add     r0,-1
        la      r2,_protocol_tx_channel
        sb      r0,0(r2)
_protocol_tx_header:
        lcu     r0,0xA5
        la      r2,_protocol_putchar_raw
        jal     r1,(r2)
        lc      r0,0x5A
        la      r2,_protocol_putchar_raw
        jal     r1,(r2)
        lc      r0,1
        la      r2,_protocol_putchar_raw
        jal     r1,(r2)
        lc      r0,2
        la      r2,_protocol_putchar_raw
        jal     r1,(r2)
        la      r2,_protocol_tx_channel
        lbu     r0,0(r2)
        la      r2,_protocol_putchar_raw
        jal     r1,(r2)
        lc      r0,1
        la      r2,_protocol_putchar_raw
        jal     r1,(r2)
        lc      r0,0
        la      r2,_protocol_putchar_raw
        jal     r1,(r2)
        la      r2,_protocol_tx_byte
        lbu     r0,0(r2)
        la      r2,_protocol_putchar_raw
        jal     r1,(r2)
        la      r2,_protocol_tx_byte
        lbu     r0,0(r2)
        add     r0,4
        la      r2,_protocol_tx_channel
        lbu     r2,0(r2)
        add     r0,r2
        lcu     r2,255
        and     r0,r2
        la      r2,_protocol_putchar_raw
        jal     r1,(r2)
        pop     r2
        pop     r1
        pop     r0
        jmp     (r1)

; Map a process descriptor in r0 to its fixed virtual-TTY input ring.
; Virtual TTY of the descriptor in r0, the last field of the slot record.
_tty_for_proc:
        add     r0,96
        jmp     (r1)

; Move at most one recovery-UART byte into the foreground virtual TTY and
; wake its owner if it is blocked in TASK_GETCHAR.
_tty_poll_uart:
        push    r0
        push    r1
        push    r2
        la      r2,_protocol_framed_mode
        lbu     r0,0(r2)
        ceq     r0,z
        brf     _tty_poll_status
        la      r2,_tty_foreground_proc
        lw      r2,0(r2)
        lw      r0,24(r2)
        lc      r1,7
        ceq     r0,r1
        brt     _tty_poll_status
        la      r2,_tty_poll_done
        jmp     (r2)
_tty_poll_status:
        la      r2,_preemption_rx_dequeue
        jal     r1,(r2)
        ceq     r0,z
        brf     _tty_poll_read
        la      r2,_tty_poll_done
        jmp     (r2)
_tty_poll_read:
        ; In recovery mode ordinary bytes retain their legacy path. An A5
        ; candidate and every byte after negotiation use the framed decoder.
        la      r2,_protocol_framed_mode
        lbu     r0,0(r2)
        ceq     r0,z
        brf     _tty_poll_protocol
        la      r2,_PROTOCOL_RX_STATE
        lbu     r0,0(r2)
        ceq     r0,z
        brf     _tty_poll_protocol
        la      r2,_tty_poll_byte
        lw      r0,0(r2)
        lcu     r1,0xA5
        ceq     r0,r1
        brf     _tty_poll_plain
_tty_poll_protocol:
        la      r2,_tty_poll_byte
        lw      r0,0(r2)
        la      r2,_PROTOCOL_CONSUME
        jal     r1,(r2)
        bra     _tty_poll_done
_tty_poll_plain:
        la      r2,_tty_foreground_proc
        lw      r0,0(r2)
        la      r2,_tty_poll_proc
        sw      r0,0(r2)
        la      r2,_tty_enqueue_saved
        jal     r1,(r2)
        bra     _tty_poll_done

; Enqueue _tty_poll_byte for _tty_poll_proc and wake a blocked reader.
_tty_enqueue_saved:
        push    r0
        push    r1
        push    r2
        la      r2,_tty_poll_proc
        lw      r0,0(r2)
        la      r2,_tty_for_proc
        jal     r1,(r2)
        mov     r2,r0
        lw      r0,6(r2)
        lc      r1,64
        ceq     r0,r1
        brf     _tty_enqueue_store
        lw      r0,9(r2)
        add     r0,1
        sw      r0,9(r2)
        bra     _tty_enqueue_done
_tty_enqueue_store:
        lw      r1,3(r2)
        add     r2,12
        add     r2,r1
        la      r0,_tty_poll_byte
        lw      r0,0(r0)
        sb      r0,0(r2)
        add     r2,-12
        sub     r2,r1
        add     r1,1
        lc      r0,63
        and     r1,r0
        sw      r1,3(r2)
        lw      r0,6(r2)
        add     r0,1
        sw      r0,6(r2)
        la      r2,_tty_poll_proc
        lw      r2,0(r2)
        lw      r0,24(r2)
        lc      r1,7
        ceq     r0,r1
        brf     _tty_enqueue_done
        lc      r0,1
        sw      r0,24(r2)
_tty_enqueue_done:
        pop     r2
        pop     r1
        pop     r0
        jmp     (r1)
_tty_poll_done:
        pop     r2
        pop     r1
        pop     r0
        jmp     (r1)

; Decoder callbacks. Only an exact channel-zero SWT1 HELLO enters framed mode.
; Other valid frame types are routed after negotiation by the handlers below.
        .globl  _PROTOCOL_FRAME
_PROTOCOL_FRAME:
        push    r0
        push    r1
        push    r2
        la      r2,_PROTOCOL_RX_TYPE
        lbu     r0,0(r2)
        lc      r1,1
        ceq     r0,r1
        brf     _protocol_frame_check_resource
        la      r2,_protocol_frame_tty_input
        jmp     (r2)
_protocol_frame_check_resource:
        lc      r1,8
        ceq     r0,r1
        brf     _protocol_frame_check_uptime
        la      r2,_protocol_frame_resource
        jmp     (r2)
_protocol_frame_check_uptime:
        lc      r1,9
        ceq     r0,r1
        brf     _protocol_frame_check_uptime_type
        la      r2,_protocol_frame_debug_identity
        jmp     (r2)
_protocol_frame_check_uptime_type:
        lc      r1,6
        ceq     r0,r1
        brf     _protocol_frame_check_wallclock
        la      r2,_protocol_frame_time
        jmp     (r2)
_protocol_frame_check_wallclock:
        lc      r1,7
        ceq     r0,r1
        brf     _protocol_frame_check_hello
        la      r2,_protocol_frame_time
        jmp     (r2)
_protocol_frame_check_hello:
        lc      r1,12
        ceq     r0,r1
        brf     _protocol_frame_done
        la      r2,_PROTOCOL_RX_CHANNEL
        lbu     r0,0(r2)
        ceq     r0,z
        brf     _protocol_frame_done
        la      r2,_PROTOCOL_RX_LENGTH
        lw      r0,0(r2)
        lc      r1,4
        ceq     r0,r1
        brf     _protocol_frame_done
        la      r2,_PROTOCOL_RX_PAYLOAD
        lbu     r0,0(r2)
        lc      r1,83
        ceq     r0,r1
        brf     _protocol_frame_done
        lbu     r0,1(r2)
        lc      r1,87
        ceq     r0,r1
        brf     _protocol_frame_done
        lbu     r0,2(r2)
        lc      r1,84
        ceq     r0,r1
        brf     _protocol_frame_done
        lbu     r0,3(r2)
        lc      r1,49
        ceq     r0,r1
        brf     _protocol_frame_done
        lc      r0,1
        la      r2,_protocol_framed_mode
        sb      r0,0(r2)
        ; A5 5A 01 0D 00 04 00 "SWT1" 41
        la      r2,_protocol_hello_ack
        lc      r1,12
_protocol_ack_loop:
        lbu     r0,0(r2)
        push    r2
        push    r1
        la      r2,_protocol_putchar_raw
        jal     r1,(r2)
        pop     r1
        pop     r2
        add     r2,1
        add     r1,-1
        ceq     r1,z
        brf     _protocol_ack_loop
        ; Wake the shell with a newline so it can run its startup programs.
        ; Nothing at boot can know a frontend is coming -- the target is
        ; running long before one opens the port -- and this is the moment it
        ; becomes true. The shell treats a bare newline as "check my startup
        ; list", which is idempotent, so a reconnect costs nothing.
        la      r0,_proc_a
        la      r2,_tty_poll_proc
        sw      r0,0(r2)
        lc      r0,10
        la      r2,_protocol_enqueue_value
        jal     r1,(r2)
        bra     _protocol_frame_done

_protocol_frame_done:
        pop     r2
        pop     r1
        pop     r0
        jmp     (r1)

; An empty channel-zero RESOURCE_SNAPSHOT frame requests a fresh, complete
; generation. Each response record fits the shared payload buffer below. The
; host publishes a generation only after its matching end record.
_protocol_frame_resource:
        la      r2,_protocol_framed_mode
        lbu     r0,0(r2)
        ceq     r0,z
        brf     _protocol_resource_check_channel
        la      r2,_protocol_frame_done
        jmp     (r2)
_protocol_resource_check_channel:
        la      r2,_PROTOCOL_RX_CHANNEL
        lbu     r0,0(r2)
        ceq     r0,z
        brt     _protocol_resource_check_length
        la      r2,_protocol_frame_done
        jmp     (r2)
_protocol_resource_check_length:
        la      r2,_PROTOCOL_RX_LENGTH
        lw      r0,0(r2)
        ceq     r0,z
        brt     _protocol_resource_request_valid
        la      r2,_protocol_frame_done
        jmp     (r2)
_protocol_resource_request_valid:
        la      r2,_protocol_resource_generation
        lbu     r0,0(r2)
        add     r0,1
        sb      r0,0(r2)
        la      r2,_protocol_resource_payload
        lc      r0,1
        sb      r0,0(r2)
        la      r1,_protocol_resource_generation
        lbu     r0,0(r1)
        sb      r0,1(r2)
        lc      r0,2
        la      r2,_protocol_resource_length
        sw      r0,0(r2)
        la      r2,_protocol_emit_resource_record
        jal     r1,(r2)

        la      r2,_protocol_resource_payload
        lc      r0,2
        sb      r0,0(r2)
        la      r1,_protocol_resource_generation
        lbu     r0,0(r1)
        sb      r0,1(r2)
        la      r0,0x100000
        la      r1,_stack_next
        lw      r1,0(r1)
        sub     r0,r1
        sw      r0,2(r2)
        la      r1,_allocation_peak_bytes
        lw      r0,0(r1)
        sw      r0,5(r2)
        la      r1,_kernel_stack_peak_bytes
        lw      r0,0(r1)
        sw      r0,8(r2)
        la      r1,_allocation_failures
        lw      r0,0(r1)
        sw      r0,11(r2)
        la      r1,_child_count
        lbu     r0,0(r1)
        add     r0,1
        sb      r0,14(r2)
        lc      r0,16
        sb      r0,15(r2)
        ; Heap use and high water, relative to the link-time image end that is
        ; the heap's base. Without these the stack region is the only arena a
        ; frontend can see, and loaded image text is invisible.
        la      r0,_heap_next
        lw      r0,0(r0)
        la      r1,_swtos_image_end
        sub     r0,r1
        sw      r0,16(r2)
        la      r0,_heap_peak_next
        lw      r0,0(r0)
        la      r1,_swtos_image_end
        sub     r0,r1
        sw      r0,19(r2)
        lc      r0,22
        la      r2,_protocol_resource_length
        sw      r0,0(r2)
        la      r2,_protocol_emit_resource_record
        jal     r1,(r2)

        lc      r0,1
        la      r2,_protocol_resource_endpoint
        sw      r0,0(r2)
_protocol_resource_process_loop:
        la      r2,_protocol_resource_endpoint
        lw      r0,0(r2)
        la      r2,_proc_for_endpoint
        jal     r1,(r2)
        ceq     r0,z
        brt     _protocol_resource_process_absent
        mov     r2,r0
        mov     r1,r0
        add     r1,39
        bra     _protocol_resource_process_selected
_protocol_resource_process_absent:
        la      r2,_protocol_resource_process_next
        jmp     (r2)
_protocol_resource_process_selected:
        lw      r0,24(r2)
        ceq     r0,z
        brf     _protocol_resource_process_active
        la      r2,_protocol_resource_process_next
        jmp     (r2)
_protocol_resource_process_active:
        la      r0,_protocol_resource_proc
        sw      r2,0(r0)
        la      r0,_protocol_resource_stats
        sw      r1,0(r0)
        la      r2,_protocol_resource_payload
        lc      r0,3
        sb      r0,0(r2)
        la      r1,_protocol_resource_generation
        lbu     r0,0(r1)
        sb      r0,1(r2)
        la      r1,_protocol_resource_endpoint
        lbu     r0,0(r1)
        sb      r0,2(r2)
        la      r1,_protocol_resource_proc
        lw      r1,0(r1)
        lw      r0,24(r1)
        sb      r0,3(r2)
        lc      r0,0
        sb      r0,4(r2)
        lw      r0,24(r1)
        lc      r1,7
        ceq     r0,r1
        brf     _protocol_resource_not_blocked
        lc      r0,1
        sb      r0,4(r2)
_protocol_resource_not_blocked:
        la      r1,_protocol_resource_proc
        lw      r1,0(r1)
        lw      r1,33(r1)
        lw      r0,15(r1)
        sb      r0,5(r2)
        lbu     r0,16(r1)
        sb      r0,6(r2)
        lw      r0,18(r1)
        sb      r0,7(r2)
        lbu     r0,19(r1)
        sb      r0,8(r2)
        la      r1,_protocol_resource_stats
        lw      r1,0(r1)
        lw      r0,3(r1)
        sw      r0,9(r2)
        lw      r0,6(r1)
        sw      r0,12(r2)
        lc      r0,15
        la      r2,_protocol_resource_length
        sw      r0,0(r2)
        la      r2,_protocol_emit_resource_record
        jal     r1,(r2)

        la      r2,_protocol_resource_payload
        lc      r0,4
        sb      r0,0(r2)
        la      r1,_protocol_resource_generation
        lbu     r0,0(r1)
        sb      r0,1(r2)
        la      r1,_protocol_resource_endpoint
        lbu     r0,0(r1)
        sb      r0,2(r2)
        la      r1,_protocol_resource_stats
        lw      r1,0(r1)
        lw      r0,9(r1)
        sw      r0,3(r2)
        lw      r0,18(r1)
        sw      r0,6(r2)
        lw      r0,21(r1)
        sw      r0,9(r2)
        ; Eight name bytes, not four: "embedded-hello" and "embedded-ping"
        ; were indistinguishable, and so were "clock" and "cpu-hog" at a
        ; glance. The descriptor's name field is sixteen NUL-padded bytes, and
        ; the reader trims the padding.
        la      r1,_protocol_resource_proc
        lw      r1,0(r1)
        lw      r1,33(r1)
        lw      r1,0(r1)
        lbu     r0,0(r1)
        sb      r0,12(r2)
        lbu     r0,1(r1)
        sb      r0,13(r2)
        lbu     r0,2(r1)
        sb      r0,14(r2)
        lbu     r0,3(r1)
        sb      r0,15(r2)
        lbu     r0,4(r1)
        sb      r0,16(r2)
        lbu     r0,5(r1)
        sb      r0,17(r2)
        lbu     r0,6(r1)
        sb      r0,18(r2)
        lbu     r0,7(r1)
        sb      r0,19(r2)
        lc      r0,20
        la      r2,_protocol_resource_length
        sw      r0,0(r2)
        la      r2,_protocol_emit_resource_record
        jal     r1,(r2)

        ; A separate bounded record keeps the version-1 process records within
        ; the sixteen-byte decoder limit while exposing forced preemption.
        la      r2,_protocol_resource_payload
        lc      r0,6
        sb      r0,0(r2)
        la      r1,_protocol_resource_generation
        lbu     r0,0(r1)
        sb      r0,1(r2)
        la      r1,_protocol_resource_endpoint
        lbu     r0,0(r1)
        sb      r0,2(r2)
        la      r1,_protocol_resource_proc
        lw      r0,0(r1)
        la      r2,_preempt_for_proc
        jal     r1,(r2)
        lw      r0,18(r0)
        la      r2,_protocol_resource_payload
        sw      r0,3(r2)
        la      r1,_protocol_resource_proc
        lw      r0,0(r1)
        la      r2,_preempt_for_proc
        jal     r1,(r2)
        lw      r0,27(r0)
        la      r2,_protocol_resource_payload
        sw      r0,6(r2)
        lc      r0,9
        la      r2,_protocol_resource_length
        sw      r0,0(r2)
        la      r2,_protocol_emit_resource_record
        jal     r1,(r2)
_protocol_resource_process_next:
        la      r2,_protocol_resource_endpoint
        lw      r0,0(r2)
        add     r0,1
        sw      r0,0(r2)
        lc      r1,17
        ceq     r0,r1
        brt     _protocol_resource_process_done
        la      r2,_protocol_resource_process_loop
        jmp     (r2)
_protocol_resource_process_done:

        la      r2,_protocol_resource_payload
        lc      r0,5
        sb      r0,0(r2)
        la      r1,_protocol_resource_generation
        lbu     r0,0(r1)
        sb      r0,1(r2)
        la      r1,_protocol_error_count
        lw      r0,0(r1)
        sw      r0,2(r2)
        la      r1,_protocol_uart_rx_bytes
        lw      r0,0(r1)
        sw      r0,5(r2)
        la      r1,_protocol_uart_tx_bytes
        lw      r0,0(r1)
        sw      r0,8(r2)
        lc      r0,11
        la      r2,_protocol_resource_length
        sw      r0,0(r2)
        la      r2,_protocol_emit_resource_record
        jal     r1,(r2)
        la      r2,_protocol_frame_done
        jmp     (r2)

_protocol_emit_resource_record:
        push    r0
        push    r1
        push    r2
        lcu     r0,0xA5
        la      r2,_protocol_putchar_raw
        jal     r1,(r2)
        lc      r0,0x5A
        la      r2,_protocol_putchar_raw
        jal     r1,(r2)
        lc      r0,1
        la      r2,_protocol_putchar_raw
        jal     r1,(r2)
        lc      r0,8
        la      r2,_protocol_putchar_raw
        jal     r1,(r2)
        lc      r0,0
        la      r2,_protocol_putchar_raw
        jal     r1,(r2)
        la      r2,_protocol_resource_length
        lw      r0,0(r2)
        la      r2,_protocol_putchar_raw
        jal     r1,(r2)
        lc      r0,0
        la      r2,_protocol_putchar_raw
        jal     r1,(r2)
        la      r2,_protocol_resource_length
        lw      r0,0(r2)
        add     r0,9
        la      r2,_protocol_resource_checksum
        sw      r0,0(r2)
        lc      r0,0
        la      r2,_protocol_payload_index
        sw      r0,0(r2)
_protocol_emit_resource_loop:
        la      r2,_protocol_payload_index
        lw      r1,0(r2)
        la      r2,_protocol_resource_length
        lw      r0,0(r2)
        ceq     r0,r1
        brt     _protocol_emit_resource_checksum
        la      r2,_protocol_resource_payload
        add     r2,r1
        lbu     r0,0(r2)
        push    r0
        la      r2,_protocol_resource_checksum
        lw      r1,0(r2)
        add     r1,r0
        sw      r1,0(r2)
        pop     r0
        la      r2,_protocol_putchar_raw
        jal     r1,(r2)
        la      r2,_protocol_payload_index
        lw      r0,0(r2)
        add     r0,1
        sw      r0,0(r2)
        bra     _protocol_emit_resource_loop
_protocol_emit_resource_checksum:
        la      r2,_protocol_resource_checksum
        lbu     r0,0(r2)
        la      r2,_protocol_putchar_raw
        jal     r1,(r2)
        pop     r2
        pop     r1
        pop     r0
        jmp     (r1)

; DEBUG_REQUEST opcode 1 reports the CRC-24 build identity of the exact linked
; image. This read-only operation does not alter process execution state.
_protocol_frame_debug_identity:
        la      r2,_protocol_framed_mode
        lbu     r0,0(r2)
        ceq     r0,z
        brf     _protocol_debug_check_channel
        la      r2,_protocol_frame_done
        jmp     (r2)
_protocol_debug_check_channel:
        la      r2,_PROTOCOL_RX_CHANNEL
        lbu     r0,0(r2)
        ceq     r0,z
        brt     _protocol_debug_check_length
        la      r2,_protocol_frame_done
        jmp     (r2)
_protocol_debug_check_length:
        la      r2,_PROTOCOL_RX_LENGTH
        lw      r0,0(r2)
        lc      r1,1
        ceq     r0,r1
        brt     _protocol_debug_check_opcode
        la      r2,_PROTOCOL_RX_PAYLOAD
        lbu     r0,0(r2)
        lc      r1,2
        ceq     r0,r1
        brf     _protocol_debug_check_memory
        la      r2,_PROTOCOL_RX_LENGTH
        lw      r0,0(r2)
        lc      r1,2
        ceq     r0,r1
        brf     _protocol_debug_invalid
        la      r2,_protocol_debug_registers
        jmp     (r2)
_protocol_debug_check_memory:
        lc      r1,3
        ceq     r0,r1
        brf     _protocol_debug_check_kill
        la      r2,_PROTOCOL_RX_LENGTH
        lw      r0,0(r2)
        lc      r1,5
        ceq     r0,r1
        brf     _protocol_debug_invalid
        la      r2,_protocol_debug_memory
        jmp     (r2)
_protocol_debug_check_kill:
        lc      r1,13
        ceq     r0,r1
        brf     _protocol_debug_invalid
        la      r2,_PROTOCOL_RX_LENGTH
        lw      r0,0(r2)
        lc      r1,2
        ceq     r0,r1
        brf     _protocol_debug_invalid
        la      r2,_protocol_debug_kill
        jmp     (r2)
_protocol_debug_invalid:
        la      r2,_protocol_frame_done
        jmp     (r2)
_protocol_debug_check_opcode:
        la      r2,_PROTOCOL_RX_PAYLOAD
        lbu     r0,0(r2)
        lc      r1,1
        ceq     r0,r1
        brt     _protocol_debug_identity_valid
        la      r2,_protocol_frame_done
        jmp     (r2)
_protocol_debug_identity_valid:
        lc      r0,0
        la      r2,_crc_cursor
        sw      r0,0(r2)
        la      r0,_proc_table
        la      r2,_crc_remaining
        sw      r0,0(r2)
        la      r2,_crc32_low24
        jal     r1,(r2)
        la      r2,_protocol_debug_build_id
        sw      r0,0(r2)

        lcu     r0,0xA5
        la      r2,_protocol_putchar_raw
        jal     r1,(r2)
        lc      r0,0x5A
        la      r2,_protocol_putchar_raw
        jal     r1,(r2)
        lc      r0,1
        la      r2,_protocol_putchar_raw
        jal     r1,(r2)
        lc      r0,10
        la      r2,_protocol_putchar_raw
        jal     r1,(r2)
        lc      r0,0
        la      r2,_protocol_putchar_raw
        jal     r1,(r2)
        lc      r0,4
        la      r2,_protocol_putchar_raw
        jal     r1,(r2)
        lc      r0,0
        la      r2,_protocol_putchar_raw
        jal     r1,(r2)
        lc      r0,1
        la      r2,_protocol_putchar_raw
        jal     r1,(r2)
        lc      r0,16
        la      r2,_protocol_debug_checksum
        sw      r0,0(r2)
        lc      r0,0
        la      r2,_protocol_payload_index
        sw      r0,0(r2)
_protocol_debug_id_loop:
        la      r2,_protocol_payload_index
        lw      r1,0(r2)
        lc      r0,3
        ceq     r0,r1
        brt     _protocol_debug_checksum_emit
        la      r2,_protocol_debug_build_id
        add     r2,r1
        lbu     r0,0(r2)
        push    r0
        la      r2,_protocol_debug_checksum
        lw      r1,0(r2)
        add     r1,r0
        sw      r1,0(r2)
        pop     r0
        la      r2,_protocol_putchar_raw
        jal     r1,(r2)
        la      r2,_protocol_payload_index
        lw      r0,0(r2)
        add     r0,1
        sw      r0,0(r2)
        bra     _protocol_debug_id_loop
_protocol_debug_checksum_emit:
        la      r2,_protocol_debug_checksum
        lbu     r0,0(r2)
        la      r2,_protocol_putchar_raw
        jal     r1,(r2)
        la      r2,_protocol_frame_done
        jmp     (r2)

_protocol_debug_registers:
        ; Any slot, not just the first three. Naming three of sixteen meant
        ; "regs 4" answered nothing at all, however many processes were live.
        la      r2,_PROTOCOL_RX_PAYLOAD
        lbu     r0,1(r2)
        la      r2,_proc_for_endpoint
        jal     r1,(r2)
        ceq     r0,z
        brf     _protocol_debug_registers_selected
        la      r2,_protocol_debug_invalid
        jmp     (r2)
_protocol_debug_registers_selected:
        mov     r1,r0
        lw      r0,24(r1)
        ceq     r0,z
        brf     _protocol_debug_registers_active
        la      r2,_protocol_debug_invalid
        jmp     (r2)
_protocol_debug_registers_active:
        la      r2,_protocol_debug_proc
        sw      r1,0(r2)
        la      r2,_protocol_resource_payload
        lc      r0,2
        sb      r0,0(r2)
        la      r1,_PROTOCOL_RX_PAYLOAD
        lbu     r0,1(r1)
        sb      r0,1(r2)
        lc      r0,0
        sb      r0,2(r2)
        la      r1,_protocol_debug_proc
        lw      r1,0(r1)
        mov     r0,r1
        la      r2,_preempt_for_proc
        jal     r1,(r2)
        lw      r0,24(r0)      ; interrupt-originated context is stack-backed
        ceq     r0,z
        brf     _protocol_debug_registers_irq
        la      r2,_protocol_resource_payload
        la      r1,_protocol_debug_proc
        lw      r1,0(r1)
        lw      r0,0(r1)
        sw      r0,3(r2)
        lw      r0,3(r1)
        sw      r0,6(r2)
        lw      r0,6(r1)
        sw      r0,9(r2)
        lw      r0,9(r1)
        sw      r0,12(r2)
        bra     _protocol_debug_registers_first_ready
_protocol_debug_registers_irq:
        la      r2,_protocol_resource_payload
        la      r1,_protocol_debug_proc
        lw      r1,0(r1)
        lw      r1,9(r1)       ; C, fp, r2, r1, r0 ISR frame
        lw      r0,12(r1)
        sw      r0,3(r2)
        lw      r0,9(r1)
        sw      r0,6(r2)
        lw      r0,6(r1)
        sw      r0,9(r2)
        la      r1,_protocol_debug_proc
        lw      r1,0(r1)
        lw      r0,9(r1)
        sw      r0,12(r2)
_protocol_debug_registers_first_ready:
        lc      r0,15
        la      r2,_protocol_resource_length
        sw      r0,0(r2)
        la      r2,_protocol_emit_debug_record
        jal     r1,(r2)
        la      r2,_protocol_resource_payload
        lc      r0,2
        sb      r0,0(r2)
        la      r1,_PROTOCOL_RX_PAYLOAD
        lbu     r0,1(r1)
        sb      r0,1(r2)
        lc      r0,1
        sb      r0,2(r2)
        la      r1,_protocol_debug_proc
        lw      r1,0(r1)
        lw      r0,12(r1)
        sw      r0,3(r2)
        mov     r0,r1
        la      r2,_preempt_for_proc
        jal     r1,(r2)
        lw      r0,24(r0)
        ceq     r0,z
        brf     _protocol_debug_registers_irq_status
        la      r2,_protocol_resource_payload
        la      r1,_protocol_debug_proc
        lw      r1,0(r1)
        lw      r0,15(r1)
        sw      r0,6(r2)
        bra     _protocol_debug_registers_second_ready
_protocol_debug_registers_irq_status:
        la      r2,_protocol_resource_payload
        la      r1,_protocol_debug_proc
        lw      r1,0(r1)
        lw      r1,9(r1)
        lw      r0,0(r1)
        sw      r0,6(r2)
_protocol_debug_registers_second_ready:
        lc      r0,9
        la      r2,_protocol_resource_length
        sw      r0,0(r2)
        la      r2,_protocol_emit_debug_record
        jal     r1,(r2)
        la      r2,_protocol_frame_done
        jmp     (r2)

; Queue termination for a certified non-current leaf. The clock forces it to
; a complete interrupt context and the landing handler performs TASK_EXIT only
; after restoring its live image. Never free a process from this request path.
; _kill_endpoint(r0 = endpoint) -> r0 = 0 accepted, 1 no such endpoint or
; protected, 2 already free. Shared by the debugger's kill command and the
; shell's, so both agree on what may be killed and what happens to the slot.
_kill_endpoint:
        push    r1
        push    r2
        lc      r1,1
        ceq     r0,r1
        brf     _kill_endpoint_lookup
        ; Killing the shell restarts it. Releasing its slot would end the
        ; session, and refusing outright left an operator with a wedged shell
        ; and nothing to type at, so the one endpoint that cannot go away is
        ; the one that can always be rewound.
        la      r2,_request_shell_restart
        jal     r1,(r2)
        lc      r0,0           ; accepted
        la      r2,_kill_endpoint_done
        jmp     (r2)
_kill_endpoint_lookup:
        ; Any slot, not only the first two children: the table holds sixteen
        ; and the endpoint names the slot.
        la      r2,_proc_for_endpoint
        jal     r1,(r2)
        ceq     r0,z
        brf     _kill_endpoint_selected
        lc      r0,1           ; no such endpoint
        la      r2,_kill_endpoint_done
        jmp     (r2)
_kill_endpoint_selected:
        la      r2,_protocol_debug_proc
        sw      r0,0(r2)
        mov     r1,r0
        lw      r0,24(r1)
        ceq     r0,z
        brf     _kill_endpoint_live
        lc      r0,2           ; already free
        la      r2,_kill_endpoint_done
        jmp     (r2)
_kill_endpoint_live:
        ; A process the interrupt handler can reach is torn down there so it
        ; unwinds its own runway. Every other one is parked at a cooperative
        ; yield with its context saved and nothing of it on the CPU, so its
        ; slot is released here. Demanding forced quiescence of those refused
        ; every clock and uptime: they never spin, so they are never the
        ; process the handler interrupts, and no amount of waiting made them
        ; killable.
        mov     r0,r1
        la      r2,_preempt_for_proc
        jal     r1,(r2)
        lw      r1,21(r0)      ; certified for forced quiescence
        ceq     r1,z
        brf     _kill_endpoint_queue
        lw      r1,24(r0)      ; a runway-saved interrupt frame
        ceq     r1,z
        brf     _kill_endpoint_queue
        la      r2,_kill_endpoint_release
        jmp     (r2)
_kill_endpoint_queue:
        lc      r1,1
        sw      r1,30(r0)
        lc      r0,0
        la      r2,_kill_endpoint_done
        jmp     (r2)
_kill_endpoint_release:
        la      r2,_protocol_debug_proc
        lw      r0,0(r2)
        la      r2,_release_slot
        jal     r1,(r2)
        la      r2,_child_count
        lbu     r0,0(r2)
        ceq     r0,z
        brt     _kill_endpoint_focus
        add     r0,-1
        sb      r0,0(r2)
        ceq     r0,z
        brf     _kill_endpoint_focus
        ; The last child releases the allocation generation, as an ordinary
        ; exit does.
        la      r2,_spawn_arena_mark
        lw      r0,0(r2)
        la      r2,_stack_next
        sw      r0,0(r2)
        la      r2,_spawn_heap_mark
        lw      r0,0(r2)
        la      r2,_heap_next
        sw      r0,0(r2)
_kill_endpoint_focus:
        ; Neither input focus nor the current-process pointer may be left
        ; aimed at a slot that no longer holds a process.
        la      r2,_protocol_debug_proc
        lw      r1,0(r2)
        la      r2,_tty_foreground_proc
        lw      r0,0(r2)
        ceq     r0,r1
        brf     _kill_endpoint_current_ptr
        la      r0,_proc_a
        sw      r0,0(r2)
_kill_endpoint_current_ptr:
        la      r2,_current_proc
        lw      r0,0(r2)
        ceq     r0,r1
        brf     _kill_endpoint_released
        la      r0,_proc_a
        sw      r0,0(r2)
_kill_endpoint_released:
        lc      r0,0
_kill_endpoint_done:
        pop     r2
        pop     r1
        jmp     (r1)

; TASK_KILL(endpoint, result): end a process from PL/SW, so the shell can
; manage processes without the debugger.
        .globl  _TASK_KILL
_TASK_KILL:
        push    fp
        push    r2
        push    r1
        mov     fp,sp
        lw      r0,9(fp)
        la      r2,_kill_endpoint
        jal     r1,(r2)
        lw      r1,12(fp)
        sw      r0,0(r1)
        mov     sp,fp
        pop     r1
        pop     r2
        pop     fp
        jmp     (r1)

_protocol_debug_kill:
        la      r2,_PROTOCOL_RX_PAYLOAD
        lbu     r0,1(r2)
        la      r2,_kill_endpoint
        jal     r1,(r2)
_protocol_debug_kill_emit:
        la      r2,_protocol_resource_payload
        lc      r1,13
        sb      r1,0(r2)
        la      r1,_PROTOCOL_RX_PAYLOAD
        lbu     r1,1(r1)
        sb      r1,1(r2)
        sb      r0,2(r2)
        lc      r0,3
        la      r2,_protocol_resource_length
        sw      r0,0(r2)
        la      r2,_protocol_emit_debug_record
        jal     r1,(r2)
        la      r2,_protocol_frame_done
        jmp     (r2)

_protocol_debug_memory:
        la      r2,_PROTOCOL_RX_PAYLOAD
        lw      r0,1(r2)
        la      r1,_protocol_debug_address
        sw      r0,0(r1)
        lbu     r0,4(r2)
        ceq     r0,z
        brf     _protocol_debug_memory_nonzero
        la      r2,_protocol_debug_invalid
        jmp     (r2)
_protocol_debug_memory_nonzero:
        lc      r1,13
        clu     r0,r1
        brt     _protocol_debug_memory_length_valid
        la      r2,_protocol_debug_invalid
        jmp     (r2)
_protocol_debug_memory_length_valid:
        la      r1,_protocol_debug_length
        sw      r0,0(r1)
        la      r1,_protocol_debug_address
        lw      r1,0(r1)
        add     r0,r1
        la      r1,0xFEEC00
        clu     r0,r1
        brt     _protocol_debug_memory_range_valid
        la      r2,_protocol_debug_invalid
        jmp     (r2)
_protocol_debug_memory_range_valid:
        la      r2,_protocol_resource_payload
        lc      r0,3
        sb      r0,0(r2)
        la      r1,_protocol_debug_address
        lw      r0,0(r1)
        sw      r0,1(r2)
        lc      r0,0
        la      r1,_protocol_payload_index
        sw      r0,0(r1)
_protocol_debug_memory_copy:
        la      r1,_protocol_payload_index
        lw      r0,0(r1)
        la      r2,_protocol_debug_length
        lw      r2,0(r2)
        ceq     r0,r2
        brt     _protocol_debug_memory_emit
        la      r2,_protocol_debug_address
        lw      r2,0(r2)
        add     r2,r0
        lbu     r2,0(r2)
        add     r0,4
        la      r1,_protocol_resource_payload
        add     r1,r0
        sb      r2,0(r1)
        la      r1,_protocol_payload_index
        lw      r0,0(r1)
        add     r0,1
        sw      r0,0(r1)
        bra     _protocol_debug_memory_copy
_protocol_debug_memory_emit:
        la      r2,_protocol_debug_length
        lw      r0,0(r2)
        add     r0,4
        la      r2,_protocol_resource_length
        sw      r0,0(r2)
        la      r2,_protocol_emit_debug_record
        jal     r1,(r2)
        la      r2,_protocol_frame_done
        jmp     (r2)

_protocol_emit_debug_record:
        push    r0
        push    r1
        push    r2
        lcu     r0,0xA5
        la      r2,_protocol_putchar_raw
        jal     r1,(r2)
        lc      r0,0x5A
        la      r2,_protocol_putchar_raw
        jal     r1,(r2)
        lc      r0,1
        la      r2,_protocol_putchar_raw
        jal     r1,(r2)
        lc      r0,10
        la      r2,_protocol_putchar_raw
        jal     r1,(r2)
        lc      r0,0
        la      r2,_protocol_putchar_raw
        jal     r1,(r2)
        la      r2,_protocol_resource_length
        lw      r0,0(r2)
        la      r2,_protocol_putchar_raw
        jal     r1,(r2)
        lc      r0,0
        la      r2,_protocol_putchar_raw
        jal     r1,(r2)
        la      r2,_protocol_resource_length
        lw      r0,0(r2)
        add     r0,11
        la      r2,_protocol_resource_checksum
        sw      r0,0(r2)
        lc      r0,0
        la      r2,_protocol_payload_index
        sw      r0,0(r2)
_protocol_emit_debug_loop:
        la      r2,_protocol_payload_index
        lw      r1,0(r2)
        la      r2,_protocol_resource_length
        lw      r0,0(r2)
        ceq     r0,r1
        brt     _protocol_emit_debug_checksum
        la      r2,_protocol_resource_payload
        add     r2,r1
        lbu     r0,0(r2)
        push    r0
        la      r2,_protocol_resource_checksum
        lw      r1,0(r2)
        add     r1,r0
        sw      r1,0(r2)
        pop     r0
        la      r2,_protocol_putchar_raw
        jal     r1,(r2)
        la      r2,_protocol_payload_index
        lw      r0,0(r2)
        add     r0,1
        sw      r0,0(r2)
        bra     _protocol_emit_debug_loop
_protocol_emit_debug_checksum:
        la      r2,_protocol_resource_checksum
        lbu     r0,0(r2)
        la      r2,_protocol_putchar_raw
        jal     r1,(r2)
        pop     r2
        pop     r1
        pop     r0
        jmp     (r1)

_protocol_frame_tty_input:
        la      r2,_protocol_framed_mode
        lbu     r0,0(r2)
        ceq     r0,z
        brt     _protocol_tty_done
        ; Route by endpoint, the inverse of the transmit side: channel N is
        ; endpoint N+1. This too was a chain that knew only the first three
        ; slots, so keystrokes aimed at any later application were discarded.
        la      r2,_PROTOCOL_RX_CHANNEL
        lbu     r0,0(r2)
        add     r0,1
        la      r2,_proc_for_endpoint
        jal     r1,(r2)
        ceq     r0,z
        brt     _protocol_tty_done
_protocol_tty_proc_ready:
        la      r2,_tty_poll_proc
        sw      r0,0(r2)
        lc      r0,0
        la      r2,_protocol_payload_index
        sw      r0,0(r2)
_protocol_tty_payload_loop:
        la      r2,_protocol_payload_index
        lw      r0,0(r2)
        la      r2,_PROTOCOL_RX_LENGTH
        lw      r1,0(r2)
        ceq     r0,r1
        brt     _protocol_tty_done
        la      r2,_PROTOCOL_RX_PAYLOAD
        add     r2,r0
        lbu     r0,0(r2)
        la      r2,_tty_poll_byte
        sw      r0,0(r2)
        la      r2,_tty_enqueue_saved
        jal     r1,(r2)
        la      r2,_protocol_payload_index
        lw      r0,0(r2)
        add     r0,1
        sw      r0,0(r2)
        bra     _protocol_tty_payload_loop
_protocol_tty_done:
        pop     r2
        pop     r1
        pop     r0
        jmp     (r1)

; Translate typed three-byte time frames into the existing clock task's
; private input representation. Control traffic never enters another channel.
_protocol_frame_time:
        la      r2,_protocol_framed_mode
        lbu     r0,0(r2)
        ceq     r0,z
        brf     _protocol_time_check_channel
        la      r2,_protocol_time_done
        jmp     (r2)
_protocol_time_check_channel:
        la      r2,_PROTOCOL_RX_CHANNEL
        lbu     r0,0(r2)
        ceq     r0,z
        brt     _protocol_time_check_length
        la      r2,_protocol_time_done
        jmp     (r2)
_protocol_time_check_length:
        la      r2,_PROTOCOL_RX_LENGTH
        lw      r0,0(r2)
        lc      r1,3
        ceq     r0,r1
        brt     _protocol_time_select
        la      r2,_protocol_time_done
        jmp     (r2)
; Every process running the named program receives the tick, not just the one
; in the foreground pane. These apps are driven entirely by TASK_GETCHAR, so
; delivering only to the focused pane left every other spawned clock blocked
; in the kernel forever and only one pane ever advanced.
_protocol_time_select:
        la      r2,_PROTOCOL_RX_TYPE
        lbu     r0,0(r2)
        lc      r1,6
        ceq     r0,r1
        brf     _protocol_time_clock_kind
        ; The monitor refreshes on the uptime tick, so that tick has two
        ; possible consumers; the wall clock has one.
        la      r0,_scheduled_mon_descriptor
        la      r2,_protocol_time_descriptor_alt
        sw      r0,0(r2)
        la      r0,_scheduled_uptime_descriptor
        bra     _protocol_time_kind_ready
_protocol_time_clock_kind:
        lc      r0,0
        la      r2,_protocol_time_descriptor_alt
        sw      r0,0(r2)
        la      r0,_scheduled_clock_descriptor
_protocol_time_kind_ready:
        la      r2,_protocol_time_descriptor
        sw      r0,0(r2)
        la      r0,_proc_table
        la      r2,_protocol_time_slot
        sw      r0,0(r2)
_protocol_time_slot_loop:
        la      r2,_protocol_time_slot
        lw      r2,0(r2)
        lw      r0,24(r2)
        ceq     r0,z
        brf     _protocol_time_slot_program
        la      r2,_protocol_time_slot_next
        jmp     (r2)
_protocol_time_slot_program:
        lw      r0,33(r2)
        la      r1,_protocol_time_descriptor
        lw      r1,0(r1)
        ceq     r0,r1
        brt     _protocol_time_valid
        la      r1,_protocol_time_descriptor_alt
        lw      r1,0(r1)
        ceq     r0,r1
        brt     _protocol_time_valid
        la      r2,_protocol_time_slot_next
        jmp     (r2)
_protocol_time_valid:
        la      r2,_protocol_time_slot
        lw      r0,0(r2)
        la      r2,_tty_poll_proc
        sw      r0,0(r2)
        ; A blocked time consumer has an empty queue. Canonicalize its ring
        ; indices before atomically appending the complete control message.
        la      r2,_tty_for_proc
        jal     r1,(r2)
        mov     r2,r0
        lw      r0,6(r2)
        ceq     r0,z
        brf     _protocol_time_ring_ready
        sw      r0,0(r2)
        sw      r0,3(r2)
_protocol_time_ring_ready:
        lcu     r0,255
        la      r2,_protocol_enqueue_value
        jal     r1,(r2)
        la      r2,_PROTOCOL_RX_TYPE
        lbu     r0,0(r2)
        add     r0,-5          ; uptime type 6 -> 1, wall clock 7 -> 2
        la      r2,_protocol_enqueue_value
        jal     r1,(r2)
        lc      r0,0
        la      r2,_protocol_payload_index
        sw      r0,0(r2)
_protocol_time_payload_loop:
        la      r2,_protocol_payload_index
        lw      r1,0(r2)
        mov     r0,r1
        lc      r1,3
        ceq     r0,r1
        brf     _protocol_time_payload_byte
        la      r2,_protocol_time_slot_next
        jmp     (r2)
_protocol_time_payload_byte:
        la      r2,_protocol_payload_index
        lw      r1,0(r2)
        la      r2,_PROTOCOL_RX_PAYLOAD
        add     r2,r1
        lbu     r0,0(r2)
        lcu     r1,255
        ceq     r0,r1
        brt     _protocol_time_escape_ff
        lc      r1,29
        ceq     r0,r1
        brt     _protocol_time_escape_1d
        la      r2,_protocol_enqueue_value
        jal     r1,(r2)
        bra     _protocol_time_payload_next
_protocol_time_escape_ff:
        lcu     r0,255
        la      r2,_protocol_enqueue_value
        jal     r1,(r2)
        lc      r0,0
        bra     _protocol_time_escape_code
_protocol_time_escape_1d:
        lcu     r0,255
        la      r2,_protocol_enqueue_value
        jal     r1,(r2)
        lc      r0,3
_protocol_time_escape_code:
        la      r2,_protocol_enqueue_value
        jal     r1,(r2)
_protocol_time_payload_next:
        la      r2,_protocol_payload_index
        lw      r0,0(r2)
        add     r0,1
        sw      r0,0(r2)
        bra     _protocol_time_payload_loop
_protocol_time_slot_next:
        la      r2,_protocol_time_slot
        lw      r0,0(r2)
        lcu     r1,172          ; one slot; see the add-immediate note above
        add     r0,r1
        la      r1,_proc_table_end
        ceq     r0,r1
        brt     _protocol_time_done
        la      r2,_protocol_time_slot
        sw      r0,0(r2)
        la      r2,_protocol_time_slot_loop
        jmp     (r2)
_protocol_time_done:
        pop     r2
        pop     r1
        pop     r0
        jmp     (r1)

_protocol_enqueue_value:
        push    r1
        push    r2
        la      r2,_tty_poll_byte
        sw      r0,0(r2)
        la      r2,_tty_enqueue_saved
        jal     r1,(r2)
        pop     r2
        pop     r1
        jmp     (r1)

        .globl  _PROTOCOL_ERROR
_PROTOCOL_ERROR:
        push    r0
        push    r2
        la      r2,_protocol_error_count
        lw      r0,0(r2)
        add     r0,1
        sw      r0,0(r2)
        pop     r2
        pop     r0
        jmp     (r1)

_protocol_putchar_raw:
        push    r1
        push    r2
_protocol_putchar_wait:
        la      r2,0xFF0101
        lbu     r1,0(r2)
        lcu     r2,128
        and     r1,r2
        ceq     r1,z
        brf     _protocol_putchar_wait
        la      r2,0xFF0100
        sb      r0,0(r2)
        la      r2,_protocol_uart_tx_bytes
        lw      r1,0(r2)
        add     r1,1
        sw      r1,0(r2)
        pop     r2
        pop     r1
        jmp     (r1)

; Slot carrying endpoint r0, or zero when no slot does.
;
; Endpoint identities are assigned to slots at boot and live in the descriptor
; at offset 18, so the table is searched rather than indexed. That keeps the
; mapping correct however endpoints are allocated, where the compare chains
; this replaces assumed endpoint N was the Nth slot and needed one arm per
; slot.
_proc_for_endpoint:
        push    r1
        push    r2
        mov     r1,r0
        la      r2,_proc_table
_proc_for_endpoint_loop:
        lw      r0,18(r2)
        ceq     r0,r1
        brt     _proc_for_endpoint_found
        lcu     r0,172          ; one slot; see the add-immediate note above
        add     r2,r0
        push    r1
        la      r1,_proc_table_end
        mov     r0,r2
        ceq     r0,r1
        pop     r1
        brf     _proc_for_endpoint_loop
        lc      r0,0
        bra     _proc_for_endpoint_done
_proc_for_endpoint_found:
        mov     r0,r2
_proc_for_endpoint_done:
        pop     r2
        pop     r1
        jmp     (r1)

; Statistics block of the descriptor in r0. Interleaved slots put it at a
; constant offset, so no per-slot dispatch is needed.
_stats_for_proc:
        add     r0,39
        jmp     (r1)

; Preemption sidecar of the descriptor in r0, likewise at a constant offset.
_preempt_for_proc:
        add     r0,63
        jmp     (r1)

; Increment one 24-bit counter. Natural machine-word wraparound is deliberate.
_stats_increment:
        push    r1
        lw      r1,0(r0)
        add     r1,1
        sw      r1,0(r0)
        pop     r1
        jmp     (r1)

_halt:
        bra     _halt

; One 96-byte record per slot, laid out as descriptor, statistics, preemption
; sidecar. These were three parallel arrays, which meant a descriptor pointer
; could only reach its own statistics and sidecar through a compare chain with
; one arm per slot -- code that grows with the table. Interleaved, each is a
; constant offset from the descriptor: PROC_STATS at 39, PROC_PREEMPT at 63,
; PROC_TTY at 96, for a 172-byte slot.
;
; Keep the slot at or below 127 bytes, or stride it with `lcu rN,SIZE` and
; `add r2,rN`. The add immediate is a signed byte and cor24-asm accepts
; 128..255 silently, matching MakerLisp's reference as24: `add r2,151`
; assembles as 0B 97 and executes as -105. The listing still prints 151, so
; nothing warns. r0 is dead at every table-walk stride site here, being
; overwritten by the following `mov r0,r2` comparison temporary, so it is the
; register to borrow.
;
; PROC_DESC ABI is declared in hal/cor24/proc-desc.toml and checked against
; include/swtos.msw. Offset 21 is PD_SENDER; no field is spare provider state.
; Statistics are eight words: reserved, dispatches, yields, IPC operations,
; reserved state transitions, reserved block count, TTY input, TTY output.
; The sidecar is eleven: live base/words, landing, shadow, quantum, pending,
; forced count, eligibility, IRQ-context flag, interrupted-r0 sample, and an
; asynchronous kill request.
_proc_table:
_proc_a:
        .zero   39
_proc_a_stats:
        .zero   24
_proc_a_preempt:
        .zero   33
_tty_a:
        .zero   76
_proc_b:
        .zero   39
_proc_b_stats:
        .zero   24
_proc_b_preempt:
        .zero   33
_tty_b:
        .zero   76
_proc_c:
        .zero   39
_proc_c_stats:
        .zero   24
_proc_c_preempt:
        .zero   33
_tty_c:
        .zero   76
        ; Thirteen further slots. Nothing names a slot: every per-slot record
        ; is a constant offset from the descriptor, and endpoints are found by
        ; searching. 16 x 172 = 2752 bytes of image.
        .zero   2236
_proc_table_end:
; A virtual TTY: head, tail, count, overflow, then a 64-byte input ring.
_tty_d:
        .zero   76
_tty_foreground_proc:
        .zero   3
_tty_poll_proc:
        .zero   3
_tty_poll_byte:
        .zero   3
_protocol_framed_mode:
        .byte   0
_protocol_error_count:
        .zero   3
_protocol_uart_rx_bytes:
        .zero   3
_protocol_uart_tx_bytes:
        .zero   3
_protocol_debug_build_id:
        .zero   3
_protocol_debug_checksum:
        .zero   3
_protocol_debug_proc:
        .zero   3
_protocol_debug_address:
        .zero   3
_protocol_debug_length:
        .zero   3
_protocol_resource_generation:
        .byte   0
; Sized for the longest resource record: the memory record, which carries the
; stack region, the heap, the kernel stack, failures, and slot use.
_protocol_resource_payload:
        .zero   22
_protocol_resource_length:
        .zero   3
_protocol_resource_checksum:
        .zero   3
_protocol_resource_endpoint:
        .zero   3
_protocol_resource_proc:
        .zero   3
_protocol_resource_stats:
        .zero   3
_protocol_payload_index:
        .zero   3
_protocol_time_descriptor:
        .zero   3
_protocol_time_descriptor_alt:
        .zero   3
_protocol_time_slot:
        .zero   3
_protocol_tx_byte:
        .byte   0
_protocol_tx_channel:
        .byte   0
_protocol_hello_ack:
        .byte   0xA5,0x5A,0x01,0x0D,0x00,0x04,0x00,0x53,0x57,0x54,0x31,0x41
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
_embedded_live_words:
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
_spawn_endpoint_save:
        .zero   3
_boot_endpoint:
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
; Process stacks are allocated downward from the top of the 1 MB SRAM. Only
; the kernel and boot stack remain in EBR, which is far too small to hold
; sixteen process stacks: 3 KB against 16 x 4 KB.
_stack_next:
        .word   0x100000
; Loaded image text, its preemption shadow, and private process state are
; allocated upward from the end of the linked image. _swtos_image_end is
; emitted by scripts/catalog-spawn-link.sh, so the heap can never overlap the
; static image. Initialized at boot because its base is a link-time address.
_heap_next:
        .zero   3
_heap_peak_next:
        .zero   3
_spawn_heap_mark:
        .zero   3
_child_count:
        .byte   0
; The shell's stack top, captured once its initial frame is built. A restart
; rewinds the process to exactly this address, so it never allocates again and
; repeated restarts cannot leak the stack arena.
_shell_stack_top:
        .zero   3
; The shell's own program, kept apart from its slot. While the slot is running
; something synchronously it names that program instead, so a restart cannot
; read the slot to find its way back.
_shell_descriptor:
        .zero   3
_sync_saved_descriptor:
        .zero   3
; The process that called TASK_EXIT, retained across the slot release so the
; terminal can be handed on only by the process that actually held it.
_exit_proc:
        .zero   3
; A program running in the shell's own context: where to resume when it ends,
; whether one is running, which one, and the one state block they share. Eight
; words covers every resident program; TASK_RUN_SYNC refuses anything larger
; rather than writing past it.
_sync_return_sp:
        .zero   3
_sync_active:
        .zero   3
_sync_descriptor:
        .zero   3
_sync_state:
        .zero   24
; Raised by the UART ISR, which is the only code that runs while a wedged shell
; spins. The kernel acts on it at its next entry from the shell.
_shell_restart_pending:
        .zero   3
_system_reboot_pending:
        .zero   3
_restart_banner:
        .byte   10,83,72,69,76,76,32,82,69,83,84,65,82,84,69,68,10,0
_system_reboot_banner:
        .byte   10,83,89,83,84,69,77,32,82,69,66,79,79,84,69,68,10,0
_banner:
        .byte   83,80,65,87,78,10,0
_state_free:
        .byte   70,82,69,69,0
_state_runnable:
        .byte   82,85,78,78,65,66,76,69,0
; "WAITING", not "BLOCKED": the process is alive and parked in TASK_GETCHAR
; until something arrives on its own terminal -- the next time frame for a
; clock, a keystroke for the shell. Blocked reads like a fault; this is the
; ordinary state of a program with nothing to do yet.
_state_blocked:
        .byte   87,65,73,84,73,78,71,0
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
