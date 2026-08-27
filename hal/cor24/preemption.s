; UART-clock trust-but-verify preemption for private C24IMG processes.
;
; Sidecar words: live base, live words, landing, shadow, quantum, pending,
; forced count, eligible, interrupt-context flag.

_preemption_init:
        push    r1
        push    r2
        la      r0,_preemption_uart_isr
        mov     iv,r0
        la      r2,0xFF0010
        lc      r0,1
        sb      r0,0(r2)
        pop     r2
        pop     r1
        jmp     (r1)

; Called with r2 = selected PROC_DESC. Returns r0=1 for an IRQ context.
_preemption_prepare_dispatch:
        push    r1
        push    r2
        mov     r0,r2
        la      r2,_preempt_for_proc
        jal     r1,(r2)
        mov     r2,r0
        lc      r1,5
        sw      r1,12(r2)
        lc      r1,0
        sw      r1,15(r2)
        lw      r0,24(r2)
        pop     r2
        pop     r1
        jmp     (r1)

; Dequeue one ISR-owned ordinary byte into _tty_poll_byte. Returns r0=1/0.
_preemption_rx_dequeue:
        push    r1
        push    r2
        la      r2,_preemption_rx_count
        lw      r0,0(r2)
        ceq     r0,z
        brt     _preemption_rx_empty
        add     r0,-1
        sw      r0,0(r2)
        la      r2,_preemption_rx_tail
        lw      r1,0(r2)
        la      r2,_preemption_rx_data
        add     r2,r1
        lbu     r0,0(r2)
        la      r2,_tty_poll_byte
        sw      r0,0(r2)
        add     r1,1
        la      r0,511
        and     r1,r0
        la      r2,_preemption_rx_tail
        sw      r1,0(r2)
        lc      r0,1
        bra     _preemption_rx_done
_preemption_rx_empty:
        lc      r0,0
_preemption_rx_done:
        pop     r2
        pop     r1
        jmp     (r1)

_preemption_uart_isr:
        push    r0
        push    r1
        push    r2
        push    fp
        mov     r2,c
        push    r2
        la      r2,0xFF0100
        lbu     r0,0(r2)
        push    r0
        la      r2,_protocol_uart_rx_bytes
        lw      r0,0(r2)
        add     r0,1
        sw      r0,0(r2)
        pop     r0

        la      r2,_preemption_frame_state
        lbu     r1,0(r2)
        ceq     r1,z
        brt     _preemption_frame_normal
        lc      r2,1
        ceq     r1,r2
        brt     _preemption_frame_escape
        lc      r2,2
        ceq     r1,r2
        brt     _preemption_tick0
        lc      r2,3
        ceq     r1,r2
        brt     _preemption_tick1
        bra     _preemption_tick2

_preemption_frame_normal:
        lcu     r1,255
        ceq     r0,r1
        brt     _preemption_saw_ff
        la      r2,_preemption_enqueue
        jal     r1,(r2)
        la      r2,_preemption_isr_return
        jmp     (r2)
_preemption_saw_ff:
        lc      r1,1
        la      r2,_preemption_frame_state
        sb      r1,0(r2)
        la      r2,_preemption_isr_return
        jmp     (r2)
_preemption_frame_escape:
        lc      r1,1
        ceq     r0,r1
        brt     _preemption_start_tick
        ; FF 00 is literal FF. Other malformed escapes preserve both bytes.
        push    r0
        lcu     r0,255
        la      r2,_preemption_enqueue
        jal     r1,(r2)
        pop     r0
        ceq     r0,z
        brt     _preemption_frame_reset
        la      r2,_preemption_enqueue
        jal     r1,(r2)
_preemption_frame_reset:
        lc      r0,0
        la      r2,_preemption_frame_state
        sb      r0,0(r2)
        la      r2,_preemption_isr_return
        jmp     (r2)
_preemption_start_tick:
        lc      r0,2
        la      r2,_preemption_frame_state
        sb      r0,0(r2)
        la      r2,_preemption_isr_return
        jmp     (r2)
_preemption_tick0:
        la      r2,_preemption_host_tick
        sb      r0,0(r2)
        lc      r0,3
        la      r2,_preemption_frame_state
        sb      r0,0(r2)
        la      r2,_preemption_isr_return
        jmp     (r2)
_preemption_tick1:
        la      r2,_preemption_host_tick
        sb      r0,1(r2)
        lc      r0,4
        la      r2,_preemption_frame_state
        sb      r0,0(r2)
        la      r2,_preemption_isr_return
        jmp     (r2)
_preemption_tick2:
        la      r2,_preemption_host_tick
        sb      r0,2(r2)
        lc      r0,0
        la      r2,_preemption_frame_state
        sb      r0,0(r2)
        la      r2,_preemption_forward_legacy_uptime
        jal     r1,(r2)
        la      r2,_preemption_clock_tick
        jmp     (r2)

; In unframed recovery mode the same FF 01 timestamp historically feeds the
; foreground Uptime application. Preserve that contract only when Uptime is
; actually the foreground descriptor; scheduler heartbeats must never become
; binary Shell input. Payload bytes are canonicalized for TIME_GET_PAYLOAD.
_preemption_forward_legacy_uptime:
        push    r1
        push    r2
        la      r2,_protocol_framed_mode
        lbu     r0,0(r2)
        ceq     r0,z
        brf     _preemption_forward_uptime_done
        la      r2,_tty_foreground_proc
        lw      r2,0(r2)
        lw      r0,33(r2)
        la      r2,_scheduled_uptime_descriptor
        ceq     r0,r2
        brf     _preemption_forward_uptime_done
        lcu     r0,255
        la      r2,_preemption_enqueue
        jal     r1,(r2)
        lc      r0,1
        la      r2,_preemption_enqueue
        jal     r1,(r2)
        la      r2,_preemption_host_tick
        lbu     r0,0(r2)
        la      r2,_preemption_enqueue_time_byte
        jal     r1,(r2)
        la      r2,_preemption_host_tick
        lbu     r0,1(r2)
        la      r2,_preemption_enqueue_time_byte
        jal     r1,(r2)
        la      r2,_preemption_host_tick
        lbu     r0,2(r2)
        la      r2,_preemption_enqueue_time_byte
        jal     r1,(r2)
_preemption_forward_uptime_done:
        pop     r2
        pop     r1
        jmp     (r1)

_preemption_enqueue_time_byte:
        push    r1
        push    r2
        lcu     r1,255
        ceq     r0,r1
        brt     _preemption_enqueue_time_ff
        lc      r1,29
        ceq     r0,r1
        brt     _preemption_enqueue_time_1d
        la      r2,_preemption_enqueue
        jal     r1,(r2)
        bra     _preemption_enqueue_time_done
_preemption_enqueue_time_ff:
        lcu     r0,255
        la      r2,_preemption_enqueue
        jal     r1,(r2)
        lc      r0,0
        bra     _preemption_enqueue_time_code
_preemption_enqueue_time_1d:
        lcu     r0,255
        la      r2,_preemption_enqueue
        jal     r1,(r2)
        lc      r0,3
_preemption_enqueue_time_code:
        la      r2,_preemption_enqueue
        jal     r1,(r2)
_preemption_enqueue_time_done:
        pop     r2
        pop     r1
        jmp     (r1)

; Enqueue r0 into a bounded 512-byte ISR ring. The larger queue also preserves
; deterministic emulator fixtures, which can present a complete framed script
; much faster than a physical 921600-baud UART.
_preemption_enqueue:
        push    r1
        push    r2
        la      r2,_preemption_rx_count
        lw      r1,0(r2)
        la      r2,512
        ceq     r1,r2
        brt     _preemption_enqueue_done
        add     r1,1
        la      r2,_preemption_rx_count
        sw      r1,0(r2)
        la      r2,_preemption_rx_head
        lw      r1,0(r2)
        la      r2,_preemption_rx_data
        add     r2,r1
        sb      r0,0(r2)
        add     r1,1
        la      r0,511
        and     r1,r0
        la      r2,_preemption_rx_head
        sw      r1,0(r2)
_preemption_enqueue_done:
        pop     r2
        pop     r1
        jmp     (r1)

_preemption_clock_tick:
        la      r2,_current_proc
        lw      r0,0(r2)
        la      r2,_preempt_for_proc
        jal     r1,(r2)
        mov     r2,r0
        lw      r0,21(r2)
        ceq     r0,z
        brf     _preemption_clock_eligible
        la      r2,_preemption_isr_return
        jmp     (r2)
_preemption_clock_eligible:
        ; A runway-saved process remains current while the landing handler and
        ; scheduler poll shared protocol code.  Its complete IRQ frame is
        ; quiescent: never mistake that shared-code interval for user execution.
        lw      r0,24(r2)
        ceq     r0,z
        brt     _preemption_clock_running
        la      r2,_preemption_isr_return
        jmp     (r2)
_preemption_clock_running:
        lw      r0,30(r2)      ; asynchronous debugger kill request
        ceq     r0,z
        brf     _preemption_force
        lw      r0,12(r2)
        ceq     r0,z
        brt     _preemption_force
        add     r0,-1
        sw      r0,12(r2)
        ceq     r0,z
        brt     _preemption_mark_pending
        la      r2,_preemption_isr_return
        jmp     (r2)
_preemption_mark_pending:
        lc      r0,1
        sw      r0,15(r2)
        la      r2,_preemption_isr_return
        jmp     (r2)

_preemption_force:
        ; Mask UART before jmp(ir) clears interrupt-in-service.
        la      r2,0xFF0010
        lc      r0,0
        sb      r0,0(r2)
        la      r2,_current_proc
        lw      r2,0(r2)
        mov     r0,sp
        sw      r0,9(r2)
        mov     r0,r2
        la      r2,_preempt_for_proc
        jal     r1,(r2)
        la      r2,_preemption_sidecar
        sw      r0,0(r2)

        ; Snapshot the entire mutable live image into its reserved shadow.
        mov     r2,r0
        lw      r1,0(r2)
        lw      r0,3(r2)
        mov     r2,r0
        add     r0,r2
        add     r0,r2
        add     r0,r1
        la      r2,_preemption_copy_end
        sw      r0,0(r2)
        la      r2,_preemption_sidecar
        lw      r2,0(r2)
        lw      r2,9(r2)
_preemption_shadow_loop:
        lbu     r0,0(r1)
        sb      r0,0(r2)
        add     r1,1
        add     r2,1
        la      r0,_preemption_copy_end
        lw      r0,0(r0)
        ceq     r0,r1
        brf     _preemption_shadow_loop

        la      r2,_preemption_sidecar
        lw      r2,0(r2)

        ; Install the per-process C7 landing jump.
        lw      r2,6(r2)
        lcu     r0,199
        sb      r0,0(r2)
        la      r0,_preemption_landing
        sb      r0,1(r2)
        lc      r1,8
        srl     r0,r1
        sb      r0,2(r2)
        srl     r0,r1
        sb      r0,3(r2)

        ; Carpet only the live image; its following landing slot remains C7.
        la      r2,_preemption_sidecar
        lw      r2,0(r2)
        lw      r1,6(r2)        ; landing is the exclusive live end
        lw      r2,0(r2)
        lc      r0,1
_preemption_fill_loop:
        sb      r0,0(r2)
        add     r2,1
        ceq     r1,r2
        brf     _preemption_fill_loop
        mov     r0,r2           ; landing address
        la      r1,0xFFFFFF
        jmp     (ir)

_preemption_landing:
        ; r0 is the exact interrupted PC. Restore live memory before scheduling.
        mov     fp,sp
        lw      r1,12(fp)       ; interrupted r0: hostile-loop progress sample
        la      r2,_preemption_counter_sample
        sw      r1,0(r2)
        push    r0
        la      r2,_current_proc
        lw      r2,0(r2)
        sw      r0,12(r2)
        mov     r0,r2
        la      r2,_preempt_for_proc
        jal     r1,(r2)
        la      r2,_preemption_sidecar
        sw      r0,0(r2)
        mov     r2,r0
        lw      r1,9(r2)
        lw      r0,6(r2)
        la      r2,_preemption_copy_end
        sw      r0,0(r2)
        la      r2,_preemption_sidecar
        lw      r2,0(r2)
        lw      r2,0(r2)
_preemption_restore_loop:
        lbu     r0,0(r1)
        sb      r0,0(r2)
        add     r1,1
        add     r2,1
        la      r0,_preemption_copy_end
        lw      r0,0(r0)
        ceq     r0,r2
        brf     _preemption_restore_loop
        pop     r0

        la      r2,_current_proc
        lw      r2,0(r2)
        mov     r0,r2
        la      r2,_preempt_for_proc
        jal     r1,(r2)
        mov     r1,r0
        lw      r0,18(r1)
        add     r0,1
        sw      r0,18(r1)
        la      r2,_preemption_counter_sample
        lw      r0,0(r2)
        sw      r0,27(r1)
        lc      r0,1
        sw      r0,24(r1)
        lc      r0,0
        sw      r0,15(r1)
        lw      r0,30(r1)
        ceq     r0,z
        brt     _preemption_landing_schedule
        lc      r0,0
        sw      r0,30(r1)
        ; The task is now quiescent with live text restored and a complete ISR
        ; frame. Re-enable UART before using the ordinary child-exit path.
        la      r2,0xFF0010
        lc      r0,1
        sb      r0,0(r2)
        la      r2,_TASK_EXIT
        jmp     (r2)
_preemption_landing_schedule:
        ; Forced recovery masked UART before leaving the interrupted task.
        ; Restore delivery before selecting the next context, not only when
        ; the selected context happens to be an IRQ-saved one. Otherwise a
        ; newly spawned hostile task can start with its scheduler clock off.
        ; The old task's IRQ-context flag remains set throughout this shared
        ; scheduler interval, so a heartbeat cannot carpet shared code.
        la      r2,0xFF0010
        lc      r0,1
        sb      r0,0(r2)
        la      r2,_current_proc
        lw      r2,0(r2)
        la      r1,_scan_runnable
        jmp     (r1)

_preemption_isr_return:
        pop     r2
        clu     z,r2
        pop     fp
        pop     r2
        pop     r1
        pop     r0
        jmp     (ir)

; Restore a runway-saved stack and fall through a patched C7 resume jump.
_preemption_restore_interrupt:
        ; r2 is selected PROC_DESC.
        lw      r0,12(r2)
        la      r1,_preemption_resume_jump
        sb      r0,1(r1)
        lc      r2,8
        srl     r0,r2
        sb      r0,2(r1)
        srl     r0,r2
        sb      r0,3(r1)
        la      r2,_current_proc
        lw      r2,0(r2)
        lw      r0,9(r2)
        mov     sp,r0
        mov     r0,r2
        la      r2,_preempt_for_proc
        jal     r1,(r2)
        lc      r1,0
        sw      r1,24(r0)
        la      r2,0xFF0010
        lc      r0,1
        sb      r0,0(r2)
        pop     r0
        clu     z,r0
        pop     fp
        pop     r2
        pop     r1
        pop     r0
_preemption_resume_jump:
        .byte   199
        .zero   3

_preemption_frame_state:
        .byte   0
_preemption_host_tick:
        .zero   3
_preemption_rx_head:
        .zero   3
_preemption_rx_tail:
        .zero   3
_preemption_rx_count:
        .zero   3
_preemption_rx_data:
        .zero   512
_preemption_sidecar:
        .zero   3
_preemption_copy_end:
        .zero   3
_preemption_counter_sample:
        .zero   3
