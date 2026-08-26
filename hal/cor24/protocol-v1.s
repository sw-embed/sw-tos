; protocol-v1.s -- reusable target-side SWTOS multiplexed-frame decoder
;
; The embedding module supplies _PROTOCOL_FRAME and _PROTOCOL_ERROR callbacks.
; A valid callback may inspect the exported type, channel, length, and payload.

; Consume one byte in r0. Valid frames print type-as-A..M and payload length.
        .globl  _PROTOCOL_CONSUME
_PROTOCOL_CONSUME:
        push    r1
        push    r2
        la      r2,_rx_byte
        sb      r0,0(r2)
        la      r2,_PROTOCOL_RX_STATE
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
        la      r2,_PROTOCOL_RX_STATE
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
        la      r2,_PROTOCOL_RX_STATE
        sb      r0,0(r2)
_sync_5a_done:
        la      r2,_protocol_done
        jmp     (r2)
_sync_complete:
        lc      r0,2
        la      r2,_PROTOCOL_RX_STATE
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
        la      r2,_PROTOCOL_RX_STATE
        sb      r0,0(r2)
        la      r2,_protocol_done
        jmp     (r2)
_state_type:
        la      r2,_rx_byte
        lbu     r0,0(r2)
        la      r2,_PROTOCOL_RX_TYPE
        sb      r0,0(r2)
        la      r2,_checksum_add
        jal     r1,(r2)
        lc      r0,4
        la      r2,_PROTOCOL_RX_STATE
        sb      r0,0(r2)
        la      r2,_protocol_done
        jmp     (r2)
_state_channel:
        la      r2,_rx_byte
        lbu     r0,0(r2)
        la      r2,_PROTOCOL_RX_CHANNEL
        sb      r0,0(r2)
        la      r2,_checksum_add
        jal     r1,(r2)
        lc      r0,5
        la      r2,_PROTOCOL_RX_STATE
        sb      r0,0(r2)
        la      r2,_protocol_done
        jmp     (r2)
_state_length_low:
        la      r2,_rx_byte
        lbu     r0,0(r2)
        la      r2,_PROTOCOL_RX_LENGTH
        sw      r0,0(r2)
        la      r2,_checksum_add
        jal     r1,(r2)
        lc      r0,6
        la      r2,_PROTOCOL_RX_STATE
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
        la      r2,_PROTOCOL_RX_LENGTH
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
        la      r2,_PROTOCOL_RX_STATE
        sb      r0,0(r2)
        la      r2,_protocol_done
        jmp     (r2)
_state_payload_or_checksum:
        la      r2,_rx_remaining
        lw      r0,0(r2)
        ceq     r0,z
        brt     _state_checksum
        ; Store at payload[length - remaining] before decrementing remaining.
        la      r2,_PROTOCOL_RX_LENGTH
        lw      r1,0(r2)
        la      r2,_rx_remaining
        lw      r0,0(r2)
        sub     r1,r0
        la      r2,_PROTOCOL_RX_PAYLOAD
        add     r2,r1
        la      r0,_rx_byte
        lbu     r0,0(r0)
        sb      r0,0(r2)
        la      r2,_rx_remaining
        lw      r0,0(r2)
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
        la      r2,_PROTOCOL_RX_TYPE
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
        la      r2,_PROTOCOL_FRAME
        jal     r1,(r2)
        la      r2,_protocol_reset
        jmp     (r2)
_protocol_error:
        la      r2,_PROTOCOL_ERROR
        jal     r1,(r2)
_protocol_reset:
        lc      r0,0
        la      r2,_PROTOCOL_RX_STATE
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

        .globl  _PROTOCOL_RX_STATE
_PROTOCOL_RX_STATE:
        .byte 0
_rx_byte:
        .byte 0
_rx_checksum:
        .byte 0
        .globl  _PROTOCOL_RX_TYPE
_PROTOCOL_RX_TYPE:
        .byte 0
        .globl  _PROTOCOL_RX_CHANNEL
_PROTOCOL_RX_CHANNEL:
        .byte 0
        .globl  _PROTOCOL_RX_LENGTH
_PROTOCOL_RX_LENGTH:
        .zero 3
_rx_remaining:
        .zero 3
        .globl  _PROTOCOL_RX_PAYLOAD
_PROTOCOL_RX_PAYLOAD:
        .zero 16
