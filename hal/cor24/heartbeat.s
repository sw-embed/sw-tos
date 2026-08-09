; heartbeat.s -- interrupt-driven UART framing and virtual clock proof
;
; Parser states: 0 normal, 1 escape, 2/3/4 heartbeat bytes T0/T1/T2.

_start:
        la      r0,0xFEEC00
        mov     sp,r0
        la      r0,_uart_isr
        mov     iv,r0
        la      r2,0xFF0010
        lc      r0,1
        sb      r0,0(r2)

; Foreground work must continue between UART interrupts.
_foreground:
        la      r2,_foreground_count
        lw      r0,0(r2)
        add     r0,1
        sw      r0,0(r2)
        la      r2,_done
        lbu     r0,0(r2)
        ceq     r0,z
        brt     _foreground
        la      r2,0xFF0010
        lc      r0,0
        sb      r0,0(r2)
        la      r2,_report
        jmp     (r2)

_uart_isr:
        push    r0
        push    r1
        push    r2
        mov     r2,c
        push    r2

        ; Reading RX data acknowledges this interrupt.
        la      r2,0xFF0100
        lbu     r0,0(r2)
        la      r2,_parser_state
        lbu     r1,0(r2)
        ceq     r1,z
        brt     _isr_normal
        lc      r2,1
        ceq     r1,r2
        brt     _isr_escape
        lc      r2,2
        ceq     r1,r2
        brt     _isr_tick0
        lc      r2,3
        ceq     r1,r2
        brt     _isr_tick1
        bra     _isr_tick2

_isr_normal:
        lcu     r1,255
        ceq     r0,r1
        brt     _isr_enter_escape
        la      r2,_data_count
        lbu     r1,0(r2)
        add     r1,1
        sb      r1,0(r2)
        la      r2,_isr_done
        jmp     (r2)

_isr_enter_escape:
        lc      r1,1
        la      r2,_parser_state
        sb      r1,0(r2)
        la      r2,_isr_done
        jmp     (r2)

_isr_escape:
        ceq     r0,z
        brt     _isr_literal_ff
        lc      r1,1
        ceq     r0,r1
        brt     _isr_enter_tick
        lc      r1,0
        la      r2,_parser_state
        sb      r1,0(r2)
        la      r2,_isr_done
        jmp     (r2)

_isr_literal_ff:
        la      r2,_data_count
        lbu     r1,0(r2)
        add     r1,1
        sb      r1,0(r2)
        lc      r1,0
        la      r2,_parser_state
        sb      r1,0(r2)
        la      r2,_isr_done
        jmp     (r2)

_isr_enter_tick:
        lc      r1,2
        la      r2,_parser_state
        sb      r1,0(r2)
        la      r2,_isr_done
        jmp     (r2)

_isr_tick0:
        la      r2,_frame_tick
        sb      r0,0(r2)
        lc      r1,3
        la      r2,_parser_state
        sb      r1,0(r2)
        la      r2,_isr_done
        jmp     (r2)

_isr_tick1:
        la      r2,_frame_tick
        sb      r0,1(r2)
        lc      r1,4
        la      r2,_parser_state
        sb      r1,0(r2)
        la      r2,_isr_done
        jmp     (r2)

_isr_tick2:
        la      r2,_frame_tick
        sb      r0,2(r2)
        lc      r1,0
        la      r2,_parser_state
        sb      r1,0(r2)

        la      r2,_clock_synced
        lbu     r0,0(r2)
        ceq     r0,z
        brt     _clock_first_tick
        la      r2,_frame_tick
        lw      r0,0(r2)
        la      r2,_last_tick
        lw      r1,0(r2)
        sub     r0,r1
        la      r2,_monotonic_ticks
        lw      r1,0(r2)
        add     r0,r1
        sw      r0,0(r2)
        bra     _clock_store_tick

_clock_first_tick:
        lc      r0,1
        la      r2,_clock_synced
        sb      r0,0(r2)

_clock_store_tick:
        la      r2,_frame_tick
        lw      r0,0(r2)
        la      r2,_last_tick
        sw      r0,0(r2)
        la      r2,_frame_count
        lbu     r0,0(r2)
        add     r0,1
        sb      r0,0(r2)
        lc      r1,2
        ceq     r0,r1
        brf     _isr_done

        ; Scan absolute sleep deadlines after the completed clock update.
        la      r2,_monotonic_ticks
        lw      r0,0(r2)
        la      r2,_sleep_a_deadline
        lw      r1,0(r2)
        clu     r0,r1
        brt     _wake_check_b
        lc      r0,1
        la      r2,_sleep_a_state
        sb      r0,0(r2)
        la      r2,_wake_count
        lbu     r0,0(r2)
        add     r0,1
        sb      r0,0(r2)

_wake_check_b:
        la      r2,_monotonic_ticks
        lw      r0,0(r2)
        la      r2,_sleep_b_deadline
        lw      r1,0(r2)
        clu     r0,r1
        brt     _wake_complete
        lc      r0,1
        la      r2,_sleep_b_state
        sb      r0,0(r2)
        la      r2,_wake_count
        lbu     r0,0(r2)
        add     r0,1
        sb      r0,0(r2)

_wake_complete:
        lc      r0,1
        la      r2,_done
        sb      r0,0(r2)

_isr_done:
        pop     r2
        clu     z,r2            ; restore saved condition flag
        pop     r2
        pop     r1
        pop     r0
        jmp     (ir)

_report:
        lc      r0,84           ; T
        la      r2,_putchar
        jal     r1,(r2)
        la      r2,_monotonic_ticks
        lbu     r0,0(r2)
        add     r0,48
        la      r2,_putchar
        jal     r1,(r2)
        lc      r0,32
        la      r2,_putchar
        jal     r1,(r2)
        lc      r0,68           ; D
        la      r2,_putchar
        jal     r1,(r2)
        la      r2,_data_count
        lbu     r0,0(r2)
        add     r0,48
        la      r2,_putchar
        jal     r1,(r2)
        lc      r0,32
        la      r2,_putchar
        jal     r1,(r2)
        lc      r0,87           ; W
        la      r2,_putchar
        jal     r1,(r2)
        la      r2,_wake_count
        lbu     r0,0(r2)
        add     r0,48
        la      r2,_putchar
        jal     r1,(r2)
        lc      r0,32
        la      r2,_putchar
        jal     r1,(r2)
        lc      r0,70           ; F
        la      r2,_putchar
        jal     r1,(r2)
        la      r2,_foreground_count
        lw      r0,0(r2)
        ceq     r0,z
        mov     r0,c
        lc      r1,1
        xor     r0,r1           ; 1 iff foreground executed
        add     r0,48
        la      r2,_putchar
        jal     r1,(r2)
        lc      r0,10
        la      r2,_putchar
        jal     r1,(r2)

_halt:
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

_parser_state:
        .byte   0
_frame_tick:
        .zero   3
_last_tick:
        .zero   3
_monotonic_ticks:
        .zero   3
_clock_synced:
        .byte   0
_frame_count:
        .byte   0
_data_count:
        .byte   0
_wake_count:
        .byte   0
_sleep_a_state:
        .byte   5
_sleep_a_deadline:
        .word   2
_sleep_b_state:
        .byte   5
_sleep_b_deadline:
        .word   3
_foreground_count:
        .zero   3
_done:
        .byte   0
