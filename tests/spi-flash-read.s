; Prove the SPI HAL can read the generated media through a W25Q32 model.

_start:
        la      r0,0xFEEC00
        mov     sp,r0
        la      r2,_SPI_INIT
        jal     r1,(r2)

        ; Media block 0 is entry count 5 followed by seven zero bytes.
        lc      r0,0
        la      r2,_SPI_FLASH_READ_BLOCK
        jal     r1,(r2)
        mov     r2,r0
        lbu     r0,0(r2)
        lc      r1,5
        ceq     r0,r1
        brf     _spi_fail
        lc      r0,7
        la      r2,_remaining
        sw      r0,0(r2)
        la      r0,_SPI_FLASH_BLOCK_BUFFER
        add     r0,1
        la      r2,_verify_cursor
        sw      r0,0(r2)
_check_header_zero:
        la      r2,_verify_cursor
        lw      r2,0(r2)
        lbu     r0,0(r2)
        ceq     r0,z
        brf     _spi_fail
        add     r2,1
        la      r0,_verify_cursor
        sw      r2,0(r0)
        la      r2,_remaining
        lw      r0,0(r2)
        add     r0,-1
        sw      r0,0(r2)
        ceq     r0,z
        brf     _check_header_zero

        ; Block 16 starts the embedded image at byte offset 128.
        lc      r0,16
        la      r2,_SPI_FLASH_READ_BLOCK
        jal     r1,(r2)
        la      r2,_image_magic
        lc      r1,6
_check_image_magic:
        push    r1
        lbu     r1,0(r0)
        push    r0
        lbu     r0,0(r2)
        ceq     r0,r1
        pop     r0
        pop     r1
        brf     _spi_fail
        add     r0,1
        add     r2,1
        add     r1,-1
        push    r0
        mov     r0,r1
        ceq     r0,z
        pop     r0
        brf     _check_image_magic

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
_verify_cursor:
        .word   0
_image_magic:
        .byte   67,50,52,73,77,71
