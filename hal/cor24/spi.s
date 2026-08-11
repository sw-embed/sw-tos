; spi.s -- COR24 bit-banged SPI master HAL
;
; MMIO contract shared by COR24-TB and cor24-emu:
;   FF0030 DATA  write MOSI bit 0, read MISO bit 0
;   FF0031 SCLK  bit 0, idle low
;   FF0032 SELN  bit 0, active low
; Mode 0 (CPOL=0, CPHA=0), MSB first.
;
; _SPI_XCHG accepts the transmit byte in r0 and returns the received byte in
; r0. All entry points preserve r1 (the COR24 return-address register).

        .globl  _SPI_INIT
        .globl  _SPI_SELECT
        .globl  _SPI_DESELECT
        .globl  _SPI_XCHG

_SPI_INIT:
        push    r1
        la      r2,0xFF0030
        lc      r0,0
        sb      r0,1(r2)
        lc      r0,1
        sb      r0,2(r2)
        pop     r1
        jmp     (r1)

_SPI_SELECT:
        push    r1
        la      r2,0xFF0030
        lc      r0,0
        sb      r0,1(r2)
        sb      r0,2(r2)
        pop     r1
        jmp     (r1)

_SPI_DESELECT:
        push    r1
        la      r2,0xFF0030
        lc      r0,0
        sb      r0,1(r2)
        lc      r0,1
        sb      r0,2(r2)
        pop     r1
        jmp     (r1)

_SPI_XCHG:
        push    r1
        la      r2,_spi_tx
        sb      r0,0(r2)
        lc      r0,0
        la      r2,_spi_rx
        sw      r0,0(r2)
        lc      r0,8
        la      r2,_spi_bits
        sw      r0,0(r2)
_spi_xchg_bit:
        la      r2,0xFF0030
        lc      r0,0
        sb      r0,1(r2)        ; falling/idle edge
        la      r2,_spi_tx
        lb      r0,0(r2)        ; sign extension exposes byte MSB to cls
        cls     r0,z
        add     r0,r0
        sb      r0,0(r2)
        mov     r0,c
        la      r2,0xFF0030
        sb      r0,0(r2)        ; present next MOSI bit
        lc      r0,1
        sb      r0,1(r2)        ; rising edge samples both lines
        lbu     r0,0(r2)
        la      r2,_spi_rx
        lw      r1,0(r2)
        add     r1,r1
        or      r1,r0
        sw      r1,0(r2)
        la      r2,_spi_bits
        lw      r0,0(r2)
        add     r0,-1
        sw      r0,0(r2)
        ceq     r0,z
        brf     _spi_xchg_bit
        la      r2,0xFF0030
        lc      r0,0
        sb      r0,1(r2)
        la      r2,_spi_rx
        lw      r0,0(r2)
        pop     r1
        jmp     (r1)

_spi_tx:
        .byte   0
_spi_rx:
        .word   0
_spi_bits:
        .word   0
