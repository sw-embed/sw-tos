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

; Send one SSD1306 I2C burst from the staged control/source/count globals.
; Return zero on success and one after STOP on the first NAK.
_ssd1306_send:
        push    r1
        la      r2,_i2c_start
        jal     r1,(r2)
        lc      r0,0x78
        la      r2,_i2c_write_byte
        jal     r1,(r2)
        ceq     r0,z
        brf     _ssd1306_send_fail
        la      r2,_ssd_control
        lbu     r0,0(r2)
        la      r2,_i2c_write_byte
        jal     r1,(r2)
        ceq     r0,z
        brf     _ssd1306_send_fail
_ssd1306_send_next:
        la      r2,_ssd_count
        lw      r0,0(r2)
        ceq     r0,z
        brt     _ssd1306_send_ok
        la      r2,_ssd_source
        lw      r0,0(r2)
        push    r0
        lbu     r0,0(r0)
        la      r2,_i2c_write_byte
        jal     r1,(r2)
        pop     r1
        ceq     r0,z
        brf     _ssd1306_send_fail
        add     r1,1
        la      r2,_ssd_source
        sw      r1,0(r2)
        la      r2,_ssd_count
        lw      r0,0(r2)
        add     r0,-1
        sw      r0,0(r2)
        bra     _ssd1306_send_next
_ssd1306_send_ok:
        lc      r0,0
        bra     _ssd1306_send_finish
_ssd1306_send_fail:
        lc      r0,1
_ssd1306_send_finish:
        push    r0
        la      r2,_i2c_stop
        jal     r1,(r2)
        pop     r0
        pop     r1
        jmp     (r1)

; Append the five column bytes for glyph id r0 to the render buffer.
_ssd1306_append_glyph:
        push    r1
        push    r2
        mov     r1,r0
        add     r0,r1
        add     r0,r1
        add     r0,r1
        add     r0,r1           ; glyph byte offset = id * 5
        la      r1,_ssd_digits
        add     r1,r0
        la      r2,_ssd_render_cursor
        lw      r2,0(r2)
        lc      r0,5
_ssd1306_copy_glyph:
        push    r0
        lbu     r0,0(r1)
        sb      r0,0(r2)
        pop     r0
        add     r1,1
        add     r2,1
        add     r0,-1
        ceq     r0,z
        brf     _ssd1306_copy_glyph
        la      r1,_ssd_render_cursor
        sw      r2,0(r1)
        pop     r2
        pop     r1
        jmp     (r1)

; Append the high and low BCD glyphs from r0.
_ssd1306_append_bcd:
        push    r1
        push    r2
        mov     r1,r0            ; remainder becomes low nibble
        lc      r2,0             ; quotient becomes high nibble
_ssd1306_bcd_divide:
        lc      r0,16
        cls     r1,r0
        brt     _ssd1306_bcd_ready
        sub     r1,r0
        add     r2,1
        bra     _ssd1306_bcd_divide
_ssd1306_bcd_ready:
        push    r1
        mov     r0,r2
        la      r2,_ssd1306_append_glyph
        jal     r1,(r2)
        pop     r0
        la      r2,_ssd1306_append_glyph
        jal     r1,(r2)
        pop     r2
        pop     r1
        jmp     (r1)

; I2C_SSD1306_SHOW_TIME(bytes, status): render DS1307 BCD seconds, minutes,
; hours as HH:MM:SS in the first OLED page and report the first NAK.
        .globl  _I2C_SSD1306_SHOW_TIME
_I2C_SSD1306_SHOW_TIME:
        push    fp
        push    r2
        push    r1
        mov     fp,sp
        la      r0,_ssd_render_buffer
        la      r2,_ssd_render_cursor
        sw      r0,0(r2)
        lw      r2,9(fp)
        lbu     r0,2(r2)
        la      r2,_ssd1306_append_bcd
        jal     r1,(r2)
        lc      r0,10
        la      r2,_ssd1306_append_glyph
        jal     r1,(r2)
        lw      r2,9(fp)
        lbu     r0,1(r2)
        la      r2,_ssd1306_append_bcd
        jal     r1,(r2)
        lc      r0,10
        la      r2,_ssd1306_append_glyph
        jal     r1,(r2)
        lw      r2,9(fp)
        lbu     r0,0(r2)
        la      r2,_ssd1306_append_bcd
        jal     r1,(r2)

        lc      r0,0
        la      r2,_ssd_control
        sb      r0,0(r2)
        la      r0,_ssd_init_commands
        la      r2,_ssd_source
        sw      r0,0(r2)
        lc      r0,10
        la      r2,_ssd_count
        sw      r0,0(r2)
        la      r2,_ssd1306_send
        jal     r1,(r2)
        ceq     r0,z
        brf     _ssd1306_show_fail

        lc      r0,0
        la      r2,_ssd_control
        sb      r0,0(r2)
        la      r0,_ssd_position_commands
        la      r2,_ssd_source
        sw      r0,0(r2)
        lc      r0,3
        la      r2,_ssd_count
        sw      r0,0(r2)
        la      r2,_ssd1306_send
        jal     r1,(r2)
        ceq     r0,z
        brf     _ssd1306_show_fail

        lc      r0,0x40
        la      r2,_ssd_control
        sb      r0,0(r2)
        la      r0,_ssd_render_buffer
        la      r2,_ssd_source
        sw      r0,0(r2)
        lc      r0,40
        la      r2,_ssd_count
        sw      r0,0(r2)
        la      r2,_ssd1306_send
        jal     r1,(r2)
        ceq     r0,z
        brf     _ssd1306_show_fail
        lc      r0,0
        bra     _ssd1306_show_done
_ssd1306_show_fail:
        lc      r0,1
_ssd1306_show_done:
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
_ssd_control:
        .byte   0
_ssd_source:
        .zero   3
_ssd_count:
        .zero   3
_ssd_render_cursor:
        .zero   3
_ssd_init_commands:
        .byte   0xAE,0x20,0x00,0x21,0x00,0x7F,0x22,0x00,0x07,0xAF
_ssd_position_commands:
        .byte   0xB0,0x00,0x10
; Five column bytes per glyph: digits zero through nine, then colon.
_ssd_digits:
        .byte   0x3E,0x51,0x49,0x45,0x3E
        .byte   0x00,0x42,0x7F,0x40,0x00
        .byte   0x42,0x61,0x51,0x49,0x46
        .byte   0x21,0x41,0x45,0x4B,0x31
        .byte   0x18,0x14,0x12,0x7F,0x10
        .byte   0x27,0x45,0x45,0x45,0x39
        .byte   0x3C,0x4A,0x49,0x49,0x30
        .byte   0x01,0x71,0x09,0x05,0x03
        .byte   0x36,0x49,0x49,0x49,0x36
        .byte   0x06,0x49,0x49,0x29,0x1E
        .byte   0x00,0x36,0x36,0x00,0x00
_ssd_render_buffer:
        .zero   40
