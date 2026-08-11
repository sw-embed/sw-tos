; Prove the SPI HAL can read the generated media through a W25Q32 model.

_start:
        la      r0,0xFEEC00
        mov     sp,r0
        la      r2,_SPI_INIT
        jal     r1,(r2)

        ; W25Q32 READ (03h) at byte address 000000h.
        la      r2,_SPI_SELECT
        jal     r1,(r2)
        lc      r0,3
        la      r2,_SPI_XCHG
        jal     r1,(r2)
        lc      r0,0
        la      r2,_SPI_XCHG
        jal     r1,(r2)
        lc      r0,0
        la      r2,_SPI_XCHG
        jal     r1,(r2)
        lc      r0,0
        la      r2,_SPI_XCHG
        jal     r1,(r2)

        ; Media header is entry count 5 followed by seven zero bytes.
        lc      r0,0
        la      r2,_SPI_XCHG
        jal     r1,(r2)
        lc      r1,5
        ceq     r0,r1
        brf     _spi_fail
        lc      r0,7
        la      r2,_remaining
        sw      r0,0(r2)
_check_header_zero:
        lc      r0,0
        la      r2,_SPI_XCHG
        jal     r1,(r2)
        ceq     r0,z
        brf     _spi_fail
        la      r2,_remaining
        lw      r0,0(r2)
        add     r0,-1
        sw      r0,0(r2)
        ceq     r0,z
        brf     _check_header_zero
        la      r2,_SPI_DESELECT
        jal     r1,(r2)

        la      r2,0xFF0100
        lc      r0,83           ; S
        sb      r0,0(r2)
_spi_halt:
        la      r2,_spi_halt
        jmp     (r2)

_spi_fail:
        la      r2,0xFF0100
        lc      r0,70           ; F
        sb      r0,0(r2)
        la      r2,_spi_halt
        jmp     (r2)

_remaining:
        .word   0
