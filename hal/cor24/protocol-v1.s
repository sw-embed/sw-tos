; protocol-v1.s -- target-side SWTOS multiplexed-frame decoder proof

_start:
        la      r0,0xFEEC00
        mov     sp,r0
_main:
        la      r2,0xFF0101
        lbu     r0,0(r2)
        lc      r1,1
        and     r0,r1
        ceq     r0,z
        brt     _main
        la      r2,0xFF0100
        lbu     r0,0(r2)
        la      r2,_protocol_consume
        jal     r1,(r2)
        la      r2,_valid_count
        lbu     r0,0(r2)
        lc      r1,2
        ceq     r0,r1
        brf     _main
_halt:
        bra     _halt

; Consume one byte in r0. Valid frames print type-as-A..M and payload length.
_protocol_consume:
        push    r1
        push    r2
        la      r2,_rx_byte
        sb      r0,0(r2)
        la      r2,_rx_state
        lbu     r0,0(r2)
        ceq     r0,z
        brt     _state_sync_a5
        lc      r1,1
        ceq     r0,r1
        brt     _state_sync_5a
        lc      r1,2
        ceq     r0,r1
        brt     _state_version
        lc      r1,3
        ceq     r0,r1
        brt     _dispatch_type
        lc      r1,4
        ceq     r0,r1
        brt     _dispatch_channel
        lc      r1,5
        ceq     r0,r1
        brt     _dispatch_length_low
        lc      r1,6
        ceq     r0,r1
        brt     _dispatch_length_high
        la      r2,_state_payload_or_checksum
        jmp     (r2)
_dispatch_length_low:
        la      r2,_state_length_low
        jmp     (r2)
_dispatch_length_high:
        la      r2,_state_length_high
        jmp     (r2)
_dispatch_type:
        la      r2,_state_type
        jmp     (r2)
_dispatch_channel:
        la      r2,_state_channel
        jmp     (r2)

_state_sync_a5:
        la      r2,_rx_byte
        lbu     r0,0(r2)
        lcu     r1,0xA5
        ceq     r0,r1
        brf     _sync_a5_done
        lc      r0,1
        la      r2,_rx_state
        sb      r0,0(r2)
_sync_a5_done:
        la      r2,_protocol_done
        jmp     (r2)
_state_sync_5a:
        la      r2,_rx_byte
        lbu     r0,0(r2)
        lc      r1,0x5A
        ceq     r0,r1
        brt     _sync_complete
        lcu     r1,0xA5
        ceq     r0,r1
        brt     _sync_5a_done
        lc      r0,0
        la      r2,_rx_state
        sb      r0,0(r2)
_sync_5a_done:
        la      r2,_protocol_done
        jmp     (r2)
_sync_complete:
        lc      r0,2
        la      r2,_rx_state
        sb      r0,0(r2)
        la      r2,_protocol_done
        jmp     (r2)
_state_version:
        la      r2,_rx_byte
        lbu     r0,0(r2)
        lc      r1,1
        ceq     r0,r1
        brt     _version_ok
        la      r2,_protocol_error
        jmp     (r2)
_version_ok:
        la      r2,_rx_checksum
        sb      r0,0(r2)
        lc      r0,3
        la      r2,_rx_state
        sb      r0,0(r2)
        la      r2,_protocol_done
        jmp     (r2)
_state_type:
        la      r2,_rx_byte
        lbu     r0,0(r2)
        la      r2,_rx_type
        sb      r0,0(r2)
        la      r2,_checksum_add
        jal     r1,(r2)
        lc      r0,4
        la      r2,_rx_state
        sb      r0,0(r2)
        la      r2,_protocol_done
        jmp     (r2)
_state_channel:
        la      r2,_checksum_add
        jal     r1,(r2)
        lc      r0,5
        la      r2,_rx_state
        sb      r0,0(r2)
        la      r2,_protocol_done
        jmp     (r2)
_state_length_low:
        la      r2,_rx_byte
        lbu     r0,0(r2)
        la      r2,_rx_length
        sw      r0,0(r2)
        la      r2,_checksum_add
        jal     r1,(r2)
        lc      r0,6
        la      r2,_rx_state
        sb      r0,0(r2)
        la      r2,_protocol_done
        jmp     (r2)
_state_length_high:
        la      r2,_rx_byte
        lbu     r0,0(r2)
        ceq     r0,z
        brt     _length_high_zero
        la      r2,_protocol_error
        jmp     (r2)
_length_high_zero:
        la      r2,_checksum_add
        jal     r1,(r2)
        la      r2,_rx_length
        lw      r0,0(r2)
        lc      r1,16
        clu     r1,r0
        brf     _length_in_range
        la      r2,_protocol_error
        jmp     (r2)
_length_in_range:
        la      r2,_rx_remaining
        sw      r0,0(r2)
        lc      r0,7
        la      r2,_rx_state
        sb      r0,0(r2)
        la      r2,_protocol_done
        jmp     (r2)
_state_payload_or_checksum:
        la      r2,_rx_remaining
        lw      r0,0(r2)
        ceq     r0,z
        brt     _state_checksum
        add     r0,-1
        sw      r0,0(r2)
        la      r2,_checksum_add
        jal     r1,(r2)
        la      r2,_protocol_done
        jmp     (r2)
_state_checksum:
        la      r2,_rx_byte
        lbu     r0,0(r2)
        la      r2,_rx_checksum
        lbu     r1,0(r2)
        ceq     r0,r1
        brt     _checksum_ok
        la      r2,_protocol_error
        jmp     (r2)
_checksum_ok:
        la      r2,_rx_type
        lbu     r0,0(r2)
        ceq     r0,z
        brf     _type_nonzero
        la      r2,_protocol_error
        jmp     (r2)
_type_nonzero:
        lc      r1,13
        clu     r1,r0
        brf     _type_known
        la      r2,_protocol_error
        jmp     (r2)
_type_known:
        add     r0,64
        la      r2,_putchar
        jal     r1,(r2)
        la      r2,_rx_length
        lw      r0,0(r2)
        add     r0,48
        la      r2,_putchar
        jal     r1,(r2)
        la      r2,_valid_count
        lbu     r0,0(r2)
        add     r0,1
        sb      r0,0(r2)
        la      r2,_protocol_reset
        jmp     (r2)
_protocol_error:
        lc      r0,69
        la      r2,_putchar
        jal     r1,(r2)
_protocol_reset:
        lc      r0,0
        la      r2,_rx_state
        sb      r0,0(r2)
_protocol_done:
        pop     r2
        pop     r1
        jmp     (r1)

_checksum_add:
        push    r1
        la      r2,_rx_checksum
        lbu     r1,0(r2)
        la      r0,_rx_byte
        lbu     r0,0(r0)
        add     r0,r1
        lcu     r1,255
        and     r0,r1
        sb      r0,0(r2)
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

_rx_state:
        .byte 0
_rx_byte:
        .byte 0
_rx_checksum:
        .byte 0
_rx_type:
        .byte 0
_rx_length:
        .zero 3
_rx_remaining:
        .zero 3
_valid_count:
        .byte 0
