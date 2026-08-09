; heartbeat.s -- UART transport framing and 24-bit clock smoke test
;
; Input protocol:
;   FF 00             escaped literal FF data byte
;   FF 01 T0 T1 T2    little-endian 24-bit heartbeat tick
;   all other bytes   ordinary TTY data

_start:
        la      r0,0xFEEC00
        mov     sp,r0

_transport_loop:
        la      r2,_getchar
        jal     r1,(r2)
        lcu     r1,255
        ceq     r0,r1
        brt     _transport_escape
        la      r2,_data_count
        lbu     r0,0(r2)
        add     r0,1
        sb      r0,0(r2)
        bra     _transport_loop

_transport_escape:
        la      r2,_getchar
        jal     r1,(r2)
        ceq     r0,z
        brt     _transport_literal_ff
        lc      r1,1
        ceq     r0,r1
        brt     _transport_heartbeat
        bra     _transport_loop

_transport_literal_ff:
        la      r2,_data_count
        lbu     r0,0(r2)
        add     r0,1
        sb      r0,0(r2)
        bra     _transport_loop

_transport_heartbeat:
        la      r2,_getchar
        jal     r1,(r2)
        la      r2,_frame_tick
        sb      r0,0(r2)
        la      r2,_getchar
        jal     r1,(r2)
        la      r2,_frame_tick
        sb      r0,1(r2)
        la      r2,_getchar
        jal     r1,(r2)
        la      r2,_frame_tick
        sb      r0,2(r2)

        la      r2,_clock_synced
        lbu     r0,0(r2)
        ceq     r0,z
        brt     _clock_first_tick

        ; Natural 24-bit subtraction handles heartbeat wraparound.
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
        brt     _wake_sleepers
        la      r2,_transport_loop
        jmp     (r2)

_wake_sleepers:
        ; Wake every sleeping entry whose absolute deadline has arrived.
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
        brt     _report
        lc      r0,1
        la      r2,_sleep_b_state
        sb      r0,0(r2)
        la      r2,_wake_count
        lbu     r0,0(r2)
        add     r0,1
        sb      r0,0(r2)

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
        lc      r0,10
        la      r2,_putchar
        jal     r1,(r2)

_halt:
        bra     _halt

_getchar:
        push    r1
        push    r2
_getchar_wait:
        la      r2,0xFF0101
        lbu     r0,0(r2)
        lc      r1,1
        and     r0,r1
        ceq     r0,z
        brt     _getchar_wait
        la      r2,0xFF0100
        lbu     r0,0(r2)
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
