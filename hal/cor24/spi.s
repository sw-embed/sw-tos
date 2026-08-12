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
; _SPI_FLASH_READ_BLOCK accepts an eight-byte block number in r0 and returns
; a pointer to the reusable eight-byte _SPI_FLASH_BLOCK_BUFFER in r0.

        .globl  _SPI_INIT
        .globl  _SPI_SELECT
        .globl  _SPI_DESELECT
        .globl  _SPI_XCHG
        .globl  _SPI_FLASH_READ_BLOCK
        .globl  _SPI_FLASH_BLOCK_BUFFER
        .globl  _SPI_SD_READ_SECTOR

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

_SPI_FLASH_READ_BLOCK:
        push    r1
        la      r2,_SPI_FLASH_BLOCK_BUFFER
        la      r1,_spi_flash_destination
        sw      r2,0(r1)
        ; Convert block number to its 24-bit byte address.
        add     r0,r0
        add     r0,r0
        add     r0,r0
        la      r2,_spi_flash_address
        sw      r0,0(r2)

        la      r2,_SPI_SELECT
        jal     r1,(r2)
        lc      r0,3            ; W25Q32 READ DATA
        la      r2,_SPI_XCHG
        jal     r1,(r2)
        ; COR24 word byte offsets run least-significant to most-significant;
        ; W25Q32 addresses are transmitted most-significant byte first.
        la      r2,_spi_flash_address
        lbu     r0,2(r2)
        la      r2,_SPI_XCHG
        jal     r1,(r2)
        la      r2,_spi_flash_address
        lbu     r0,1(r2)
        la      r2,_SPI_XCHG
        jal     r1,(r2)
        la      r2,_spi_flash_address
        lbu     r0,0(r2)
        la      r2,_SPI_XCHG
        jal     r1,(r2)

        lc      r0,8
        la      r2,_spi_flash_remaining
        sw      r0,0(r2)
_spi_flash_read_byte:
        lc      r0,0
        la      r2,_SPI_XCHG
        jal     r1,(r2)
        la      r2,_spi_flash_destination
        lw      r2,0(r2)
        sb      r0,0(r2)
        add     r2,1
        la      r0,_spi_flash_destination
        sw      r2,0(r0)
        la      r2,_spi_flash_remaining
        lw      r0,0(r2)
        add     r0,-1
        sw      r0,0(r2)
        ceq     r0,z
        brf     _spi_flash_read_byte
        la      r2,_SPI_DESELECT
        jal     r1,(r2)
        la      r0,_SPI_FLASH_BLOCK_BUFFER
        pop     r1
        jmp     (r1)

; Send the six bytes staged at _spi_sd_command.
_spi_sd_send_command:
        push    r1
        la      r0,_spi_sd_command
        la      r2,_spi_sd_cursor
        sw      r0,0(r2)
        lc      r0,6
        la      r2,_spi_sd_remaining
        sw      r0,0(r2)
_spi_sd_send_next:
        la      r2,_spi_sd_cursor
        lw      r0,0(r2)
        lbu     r0,0(r0)
        la      r2,_SPI_XCHG
        jal     r1,(r2)
        la      r2,_spi_sd_cursor
        lw      r0,0(r2)
        add     r0,1
        sw      r0,0(r2)
        la      r2,_spi_sd_remaining
        lw      r0,0(r2)
        add     r0,-1
        sw      r0,0(r2)
        ceq     r0,z
        brf     _spi_sd_send_next
        pop     r1
        jmp     (r1)

; Poll at most 256 bytes for an R1 response (bit 7 clear).
_spi_sd_read_r1:
        push    r1
        lc      r0,0
        la      r2,_spi_sd_remaining
        sw      r0,0(r2)        ; byte counter naturally wraps after 256
_spi_sd_r1_next:
        lcu     r0,255
        la      r2,_SPI_XCHG
        jal     r1,(r2)
        push    r0
        lcu     r1,128
        and     r0,r1
        ceq     r0,z
        pop     r0
        brt     _spi_sd_r1_done
        la      r2,_spi_sd_remaining
        lbu     r0,0(r2)
        add     r0,1
        sb      r0,0(r2)
        lbu     r0,0(r2)
        ceq     r0,z
        brf     _spi_sd_r1_next
        lcu     r0,255
_spi_sd_r1_done:
        pop     r1
        jmp     (r1)

; SPI_SD_READ_SECTOR(sector, destination, status): initialize the attached
; SD-card SPI device, issue CMD17 for an SDHC sector number, and copy exactly
; 512 bytes. Status is zero on success, one for handshake/response failure.
_SPI_SD_READ_SECTOR:
        push    fp
        push    r2
        push    r1
        mov     fp,sp
        la      r2,_SPI_INIT
        jal     r1,(r2)
        ; CS high and eighty idle clocks.
        lc      r0,10
        la      r2,_spi_sd_remaining
        sw      r0,0(r2)
_spi_sd_idle_clock:
        lcu     r0,255
        la      r2,_SPI_XCHG
        jal     r1,(r2)
        la      r2,_spi_sd_remaining
        lw      r0,0(r2)
        add     r0,-1
        sw      r0,0(r2)
        ceq     r0,z
        brf     _spi_sd_idle_clock
        la      r2,_SPI_SELECT
        jal     r1,(r2)

        ; CMD0 -> idle response 1.
        la      r2,_spi_sd_cmd0
        la      r0,_spi_sd_command
        lc      r1,6
_spi_sd_copy_cmd0:
        push    r1
        lbu     r1,0(r2)
        sb      r1,0(r0)
        pop     r1
        add     r2,1
        add     r0,1
        add     r1,-1
        push    r0
        mov     r0,r1
        ceq     r0,z
        pop     r0
        brf     _spi_sd_copy_cmd0
        la      r2,_spi_sd_send_command
        jal     r1,(r2)
        la      r2,_spi_sd_read_r1
        jal     r1,(r2)
        lc      r1,1
        ceq     r0,r1
        brt     _spi_sd_cmd0_ok
        la      r2,_spi_sd_fail
        jmp     (r2)
_spi_sd_cmd0_ok:

        ; CMD8 -> consume R1 plus four echo bytes.
        la      r2,_spi_sd_cmd8
        la      r0,_spi_sd_command
        lc      r1,6
_spi_sd_copy_cmd8:
        push    r1
        lbu     r1,0(r2)
        sb      r1,0(r0)
        pop     r1
        add     r2,1
        add     r0,1
        add     r1,-1
        push    r0
        mov     r0,r1
        ceq     r0,z
        pop     r0
        brf     _spi_sd_copy_cmd8
        la      r2,_spi_sd_send_command
        jal     r1,(r2)
        lc      r0,5
        la      r2,_spi_sd_remaining
        sw      r0,0(r2)
_spi_sd_cmd8_response:
        lcu     r0,255
        la      r2,_SPI_XCHG
        jal     r1,(r2)
        la      r2,_spi_sd_remaining
        lw      r0,0(r2)
        add     r0,-1
        sw      r0,0(r2)
        ceq     r0,z
        brf     _spi_sd_cmd8_response

        ; CMD55 + ACMD41. The emulator becomes ready on the first pair.
        la      r2,_spi_sd_cmd55
        la      r0,_spi_sd_command
        lc      r1,12
_spi_sd_copy_app_commands:
        push    r1
        lbu     r1,0(r2)
        sb      r1,0(r0)
        pop     r1
        add     r2,1
        add     r0,1
        add     r1,-1
        push    r0
        mov     r0,r1
        ceq     r0,z
        pop     r0
        brf     _spi_sd_copy_app_commands
        la      r2,_spi_sd_send_command
        jal     r1,(r2)
        la      r2,_spi_sd_read_r1
        jal     r1,(r2)
        lc      r1,1
        ceq     r0,r1
        brt     _spi_sd_cmd55_ok
        la      r2,_spi_sd_fail
        jmp     (r2)
_spi_sd_cmd55_ok:
        la      r0,_spi_sd_command
        add     r0,6
        la      r2,_spi_sd_cursor
        sw      r0,0(r2)
        lc      r0,6
        la      r2,_spi_sd_remaining
        sw      r0,0(r2)
_spi_sd_send_acmd41:
        la      r2,_spi_sd_cursor
        lw      r0,0(r2)
        lbu     r0,0(r0)
        la      r2,_SPI_XCHG
        jal     r1,(r2)
        la      r2,_spi_sd_cursor
        lw      r0,0(r2)
        add     r0,1
        sw      r0,0(r2)
        la      r2,_spi_sd_remaining
        lw      r0,0(r2)
        add     r0,-1
        sw      r0,0(r2)
        ceq     r0,z
        brf     _spi_sd_send_acmd41
        la      r2,_spi_sd_read_r1
        jal     r1,(r2)
        ceq     r0,z
        brt     _spi_sd_acmd41_ok
        la      r2,_spi_sd_fail
        jmp     (r2)
_spi_sd_acmd41_ok:

        ; CMD16 set 512-byte block length.
        la      r2,_spi_sd_cmd16
        la      r0,_spi_sd_command
        lc      r1,6
_spi_sd_copy_cmd16:
        push    r1
        lbu     r1,0(r2)
        sb      r1,0(r0)
        pop     r1
        add     r2,1
        add     r0,1
        add     r1,-1
        push    r0
        mov     r0,r1
        ceq     r0,z
        pop     r0
        brf     _spi_sd_copy_cmd16
        la      r2,_spi_sd_send_command
        jal     r1,(r2)
        la      r2,_spi_sd_read_r1
        jal     r1,(r2)
        ceq     r0,z
        brt     _spi_sd_cmd16_ok
        la      r2,_spi_sd_fail
        jmp     (r2)
_spi_sd_cmd16_ok:

        ; CMD17 argument is the caller's 24-bit sector number, big endian.
        la      r2,_spi_sd_cmd17
        la      r0,_spi_sd_command
        lc      r1,6
_spi_sd_copy_cmd17:
        push    r1
        lbu     r1,0(r2)
        sb      r1,0(r0)
        pop     r1
        add     r2,1
        add     r0,1
        add     r1,-1
        push    r0
        mov     r0,r1
        ceq     r0,z
        pop     r0
        brf     _spi_sd_copy_cmd17
        lw      r1,9(fp)
        la      r2,_spi_sd_sector
        sw      r1,0(r2)
        la      r0,_spi_sd_command
        la      r2,_spi_sd_sector
        lbu     r1,2(r2)
        sb      r1,2(r0)
        lbu     r1,1(r2)
        sb      r1,3(r0)
        lbu     r1,0(r2)
        sb      r1,4(r0)
        la      r2,_spi_sd_send_command
        jal     r1,(r2)
        la      r2,_spi_sd_read_r1
        jal     r1,(r2)
        ceq     r0,z
        brt     _spi_sd_cmd17_ok
        la      r2,_spi_sd_fail
        jmp     (r2)
_spi_sd_cmd17_ok:
_spi_sd_wait_token:
        lcu     r0,255
        la      r2,_SPI_XCHG
        jal     r1,(r2)
        lcu     r1,254
        ceq     r0,r1
        brf     _spi_sd_wait_token

        lw      r0,12(fp)
        la      r2,_spi_sd_cursor
        sw      r0,0(r2)
        lc      r0,2
        la      r2,_spi_sd_pages
        sw      r0,0(r2)
_spi_sd_read_page:
        lc      r0,0
        la      r2,_spi_sd_remaining
        sw      r0,0(r2)        ; 256-byte page via byte wrap
_spi_sd_read_data:
        lcu     r0,255
        la      r2,_SPI_XCHG
        jal     r1,(r2)
        la      r2,_spi_sd_cursor
        lw      r1,0(r2)
        sb      r0,0(r1)
        add     r1,1
        sw      r1,0(r2)
        la      r2,_spi_sd_remaining
        lbu     r0,0(r2)
        add     r0,1
        sb      r0,0(r2)
        lbu     r0,0(r2)
        ceq     r0,z
        brf     _spi_sd_read_data
        la      r2,_spi_sd_pages
        lw      r0,0(r2)
        add     r0,-1
        sw      r0,0(r2)
        ceq     r0,z
        brf     _spi_sd_read_page
        ; Discard two CRC bytes and provide a trailing idle clock.
        lcu     r0,255
        la      r2,_SPI_XCHG
        jal     r1,(r2)
        lcu     r0,255
        la      r2,_SPI_XCHG
        jal     r1,(r2)
        la      r2,_SPI_DESELECT
        jal     r1,(r2)
        lcu     r0,255
        la      r2,_SPI_XCHG
        jal     r1,(r2)
        lc      r0,0
        bra     _spi_sd_done
_spi_sd_fail:
        la      r2,_SPI_DESELECT
        jal     r1,(r2)
        lc      r0,1
_spi_sd_done:
        lw      r2,15(fp)
        sw      r0,0(r2)
        mov     sp,fp
        pop     r1
        pop     r2
        pop     fp
        jmp     (r1)

_spi_tx:
        .byte   0
_spi_rx:
        .word   0
_spi_bits:
        .word   0
_spi_flash_address:
        .word   0
_spi_flash_destination:
        .word   0
_spi_flash_remaining:
        .word   0
_spi_sd_cursor:
        .word   0
_spi_sd_remaining:
        .word   0
_spi_sd_pages:
        .word   0
_spi_sd_sector:
        .word   0
_spi_sd_command:
        .zero   12
_spi_sd_cmd0:
        .byte   0x40,0,0,0,0,0x95
_spi_sd_cmd8:
        .byte   0x48,0,0,1,0xAA,0x87
_spi_sd_cmd55:
        .byte   0x77,0,0,0,0,1
        .byte   0x69,0x40,0,0,0,1
_spi_sd_cmd16:
        .byte   0x50,0,0,2,0,1
_spi_sd_cmd17:
        .byte   0x51,0,0,0,0,1
_SPI_FLASH_BLOCK_BUFFER:
        .byte   0,0,0,0,0,0,0,0
