; i2c.s -- COR24 bit-banged I2C HAL and DS1307 client
;
; MMIO matches the COR24 emulator and COR24-TB: SCL at FF0020 and SDA at
; FF0021. Transfers are synchronous and leave both lines low after STOP, as in
; the established COR24 Tiny C demonstrations.

_i2c_start:
        la      r2,0xFF0021
        lc      r0,1
        sb      r0,0(r2)
        la      r2,0xFF0020
        sb      r0,0(r2)
        la      r2,0xFF0021
        lc      r0,0
        sb      r0,0(r2)
        la      r2,0xFF0020
        sb      r0,0(r2)
        jmp     (r1)

_i2c_stop:
        la      r2,0xFF0021
        lc      r0,0
        sb      r0,0(r2)
        la      r2,0xFF0020
        lc      r0,1
        sb      r0,0(r2)
        la      r2,0xFF0021
        sb      r0,0(r2)
        la      r2,0xFF0020
        lc      r0,0
        sb      r0,0(r2)
        jmp     (r1)

; Exchange one master-write byte from r0. Return zero for ACK, one for NAK.
_i2c_write_byte:
        push    r1
        push    r2
        la      r2,_i2c_shift_byte
        sw      r0,0(r2)
        lc      r0,8
        la      r2,_i2c_remaining
        sw      r0,0(r2)
_i2c_write_bit:
        la      r2,_i2c_shift_byte
        lw      r0,0(r2)
        lcu     r1,128
        and     r0,r1
        ceq     r0,z
        brt     _i2c_write_zero
        lc      r0,1
        bra     _i2c_write_sda
_i2c_write_zero:
        lc      r0,0
_i2c_write_sda:
        la      r2,0xFF0021
        sb      r0,0(r2)
        la      r2,0xFF0020
        lc      r0,1
        sb      r0,0(r2)
        lc      r0,0
        sb      r0,0(r2)
        la      r2,_i2c_shift_byte
        lw      r0,0(r2)
        add     r0,r0
        sw      r0,0(r2)
        la      r2,_i2c_remaining
        lw      r0,0(r2)
        add     r0,-1
        sw      r0,0(r2)
        ceq     r0,z
        brf     _i2c_write_bit
        ; Release SDA and sample the slave ACK on the ninth clock.
        la      r2,0xFF0021
        lc      r0,1
        sb      r0,0(r2)
        la      r2,0xFF0020
        sb      r0,0(r2)
        la      r2,0xFF0021
        lbu     r0,0(r2)
        lc      r1,1
        and     r0,r1
        la      r2,0xFF0020
        lc      r1,0
        sb      r1,0(r2)
        pop     r2
        pop     r1
        jmp     (r1)

; Read one byte MSB-first. _i2c_master_ack selects ACK (one) or NAK (zero).
; Return the byte in r0.
_i2c_read_byte:
        push    r1
        push    r2
        lc      r0,0
        la      r2,_i2c_shift_byte
        sw      r0,0(r2)
        lc      r0,8
        la      r2,_i2c_remaining
        sw      r0,0(r2)
_i2c_read_bit:
        la      r2,0xFF0021
        lc      r0,1
        sb      r0,0(r2)
        la      r2,0xFF0020
        sb      r0,0(r2)
        la      r2,_i2c_shift_byte
        lw      r0,0(r2)
        add     r0,r0
        push    r0
        la      r2,0xFF0021
        lbu     r0,0(r2)
        lc      r1,1
        and     r0,r1
        pop     r1
        add     r0,r1
        la      r2,_i2c_shift_byte
        sw      r0,0(r2)
        la      r2,0xFF0020
        lc      r0,0
        sb      r0,0(r2)
        la      r2,_i2c_remaining
        lw      r0,0(r2)
        add     r0,-1
        sw      r0,0(r2)
        ceq     r0,z
        brf     _i2c_read_bit
        ; ACK advances to another register; NAK releases SDA before STOP.
        la      r2,0xFF0021
        la      r0,_i2c_master_ack
        lbu     r0,0(r0)
        ceq     r0,z
        brt     _i2c_read_nak
        lc      r0,0
        bra     _i2c_read_response
_i2c_read_nak:
        lc      r0,1
_i2c_read_response:
        sb      r0,0(r2)
        la      r2,0xFF0020
        lc      r0,1
        sb      r0,0(r2)
        lc      r0,0
        sb      r0,0(r2)
        la      r2,_i2c_shift_byte
        lw      r0,0(r2)
        pop     r2
        pop     r1
        jmp     (r1)

; I2C_DS1307_READ(bytes, status): write BCD seconds/minutes/hours to bytes and
; zero to status. On address or data NAK, write one to status after STOP.
        .globl  _I2C_DS1307_READ
_I2C_DS1307_READ:
        push    fp
        push    r2
        push    r1
        mov     fp,sp
        la      r2,_i2c_start
        jal     r1,(r2)
        lcu     r0,0xD0
        la      r2,_i2c_write_byte
        jal     r1,(r2)
        ceq     r0,z
        brf     _i2c_ds1307_fail
        lc      r0,0
        la      r2,_i2c_write_byte
        jal     r1,(r2)
        ceq     r0,z
        brf     _i2c_ds1307_fail
        la      r2,_i2c_start
        jal     r1,(r2)
        lcu     r0,0xD1
        la      r2,_i2c_write_byte
        jal     r1,(r2)
        ceq     r0,z
        brf     _i2c_ds1307_fail
        la      r2,_i2c_master_ack
        lc      r0,1
        sb      r0,0(r2)
        la      r2,_i2c_read_byte
        jal     r1,(r2)
        lc      r1,0x7F
        and     r0,r1
        lw      r2,9(fp)
        sb      r0,0(r2)
        la      r2,_i2c_read_byte
        jal     r1,(r2)
        lw      r2,9(fp)
        sb      r0,1(r2)
        la      r2,_i2c_master_ack
        lc      r0,0
        sb      r0,0(r2)
        la      r2,_i2c_read_byte
        jal     r1,(r2)
        lc      r1,0x3F
        and     r0,r1
        lw      r2,9(fp)
        sb      r0,2(r2)
        lc      r0,0
        bra     _i2c_ds1307_finish
_i2c_ds1307_fail:
        lc      r0,1
_i2c_ds1307_finish:
        push    r0
        la      r2,_i2c_stop
        jal     r1,(r2)
        pop     r0
        lw      r2,12(fp)
        sw      r0,0(r2)
        mov     sp,fp
        pop     r1
        pop     r2
        pop     fp
        jmp     (r1)

_i2c_shift_byte:
        .zero   3
_i2c_remaining:
        .zero   3
_i2c_master_ack:
        .byte   0
