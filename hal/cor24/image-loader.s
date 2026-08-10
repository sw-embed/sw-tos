; image-loader.s -- in-memory C24IMG version 1 loader proof

_start:
        la      r0,0xFEEC00
        mov     sp,r0

        ; Dirty the destination so BSS clearing is observable.
        la      r2,_load_region
        lc      r0,15
_dirty_loop:
        lcu     r1,170
        sb      r1,0(r2)
        add     r2,1
        add     r0,-1
        ceq     r0,z
        brf     _dirty_loop

        la      r0,_embedded_loader_smoke_image
        la      r2,_load_region
        la      r1,_load_base
        sw      r2,0(r1)
        la      r2,_load_image
        jal     r1,(r2)
        la      r2,_loaded_entry
        sw      r0,0(r2)

        ; Verify parsed metadata and relocated entry.
        la      r2,_image_text_words
        lw      r0,0(r2)
        lc      r1,2
        ceq     r0,r1
        brt     _text_ok
        la      r2,_fail
        jmp     (r2)
_text_ok:
        la      r2,_image_data_words
        lw      r0,0(r2)
        lc      r1,1
        ceq     r0,r1
        brt     _data_ok
        la      r2,_fail
        jmp     (r2)
_data_ok:
        la      r2,_image_bss_words
        lw      r0,0(r2)
        lc      r1,2
        ceq     r0,r1
        brt     _bss_metadata_ok
        la      r2,_fail
        jmp     (r2)
_bss_metadata_ok:
        la      r2,_loaded_entry
        lw      r0,0(r2)
        la      r1,_load_region
        ceq     r0,r1
        brt     _entry_ok
        la      r2,_fail
        jmp     (r2)
_entry_ok:

        ; Compare copied text/data and cleared BSS with the expected 15 bytes.
        la      r0,_load_region
        la      r2,_expected_region
        lc      r1,15
_verify_region:
        push    r1
        lbu     r1,0(r0)
        push    r0
        lbu     r0,0(r2)
        ceq     r0,r1
        pop     r0
        pop     r1
        brt     _region_byte_ok
        la      r2,_fail
        jmp     (r2)
_region_byte_ok:
        add     r0,1
        add     r2,1
        add     r1,-1
        push    r0
        mov     r0,r1
        ceq     r0,z
        pop     r0
        brf     _verify_region

        la      r0,_pass_message
        la      r2,_puts
        jal     r1,(r2)
        la      r2,_halt
        jmp     (r2)

; Load r0 image into r2 destination and return relocated entry in r0.
_load_image:
        push    r1
        la      r1,_image_base
        sw      r0,0(r1)

        ; Validate C24IMG magic byte-for-byte.
        mov     r2,r0
        la      r0,_image_magic
        lc      r1,6
        push    r1
_magic_loop:
        lbu     r1,0(r0)
        push    r0
        lbu     r0,0(r2)
        ceq     r0,r1
        pop     r0
        brt     _magic_byte_ok
        la      r2,_fail
        jmp     (r2)
_magic_byte_ok:
        add     r0,1
        add     r2,1
        pop     r1
        add     r1,-1
        push    r1
        push    r0
        mov     r0,r1
        ceq     r0,z
        pop     r0
        brf     _magic_loop
        pop     r1

        la      r2,_image_base
        lw      r2,0(r2)
        add     r2,6
        mov     r0,r2
        la      r2,_read_be24
        jal     r1,(r2)
        lc      r1,1
        ceq     r0,r1
        brt     _version_ok
        la      r2,_fail
        jmp     (r2)
_version_ok:

        la      r2,_image_base
        lw      r2,0(r2)
        add     r2,9
        mov     r0,r2
        la      r2,_read_be24
        jal     r1,(r2)
        la      r2,_image_text_words
        sw      r0,0(r2)
        la      r2,_image_base
        lw      r2,0(r2)
        add     r2,12
        mov     r0,r2
        la      r2,_read_be24
        jal     r1,(r2)
        la      r2,_image_data_words
        sw      r0,0(r2)
        la      r2,_image_base
        lw      r2,0(r2)
        add     r2,15
        mov     r0,r2
        la      r2,_read_be24
        jal     r1,(r2)
        la      r2,_image_bss_words
        sw      r0,0(r2)
        la      r2,_image_base
        lw      r2,0(r2)
        add     r2,18
        mov     r0,r2
        la      r2,_read_be24
        jal     r1,(r2)
        la      r2,_image_entry_offset
        sw      r0,0(r2)
        la      r2,_image_base
        lw      r2,0(r2)
        add     r2,21
        mov     r0,r2
        la      r2,_read_be24
        jal     r1,(r2)
        ceq     r0,z
        brt     _relocations_ok
        la      r2,_fail
        jmp     (r2)
_relocations_ok:               ; version 1 relocation_count must be zero

        ; Copy packed text and data bytes from header offset 27.
        la      r2,_image_text_words
        lw      r0,0(r2)
        la      r2,_image_data_words
        lw      r1,0(r2)
        add     r0,r1
        mov     r1,r0
        add     r0,r1
        add     r0,r1
        push    r0
        la      r2,_image_base
        lw      r2,0(r2)
        add     r2,27
        la      r0,_load_base
        lw      r0,0(r0)
_copy_payload:
        lbu     r1,0(r2)
        sb      r1,0(r0)
        add     r2,1
        add     r0,1
        pop     r1
        add     r1,-1
        push    r1
        push    r0
        mov     r0,r1
        ceq     r0,z
        pop     r0
        brf     _copy_payload
        pop     r1

        ; r0 now points at BSS; clear bss_words * 3 bytes.
        push    r0
        la      r2,_image_bss_words
        lw      r2,0(r2)
        mov     r0,r2
        ceq     r0,z
        brf     _bss_nonempty
        pop     r0
        bra     _bss_done
_bss_nonempty:
        mov     r1,r2
        add     r2,r1
        add     r2,r1
        pop     r0
_clear_bss:
        lc      r1,0
        sb      r1,0(r0)
        add     r0,1
        add     r2,-1
        push    r0
        mov     r0,r2
        ceq     r0,z
        pop     r0
        brf     _clear_bss
_bss_done:

        ; Return load_base + entry_offset * 3.
        la      r2,_image_entry_offset
        lw      r0,0(r2)
        mov     r1,r0
        add     r0,r1
        add     r0,r1
        la      r2,_load_base
        lw      r2,0(r2)
        add     r0,r2
        pop     r1
        jmp     (r1)

; Read one most-significant-byte-first 24-bit word from r0.
_read_be24:
        push    r1
        push    r2
        mov     r2,r0
        lbu     r0,0(r2)
        lc      r1,2
        push    r1
_read_be24_byte:
        add     r0,r0
        add     r0,r0
        add     r0,r0
        add     r0,r0
        add     r0,r0
        add     r0,r0
        add     r0,r0
        add     r0,r0
        add     r2,1
        lbu     r1,0(r2)
        add     r0,r1
        pop     r1
        add     r1,-1
        push    r1
        push    r0
        mov     r0,r1
        ceq     r0,z
        pop     r0
        brf     _read_be24_byte
        pop     r1
        pop     r2
        pop     r1
        jmp     (r1)

_puts:
        push    r1
        push    r2
        mov     r2,r0
_puts_loop:
        lbu     r0,0(r2)
        ceq     r0,z
        brt     _puts_done
        push    r2
        la      r2,_putchar
        jal     r1,(r2)
        pop     r2
        add     r2,1
        bra     _puts_loop
_puts_done:
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

_fail:
        la      r0,_fail_message
        la      r2,_puts
        jal     r1,(r2)
_halt:
        la      r2,_halt
        jmp     (r2)

_image_base:
        .zero 3
_load_base:
        .zero 3
_loaded_entry:
        .zero 3
_image_text_words:
        .zero 3
_image_data_words:
        .zero 3
_image_bss_words:
        .zero 3
_image_entry_offset:
        .zero 3
_load_region:
        .zero 15
_expected_region:
        .byte 0,0,0,0,0,0,83,87,84,0,0,0,0,0,0
_image_magic:
        .byte 67,50,52,73,77,71
_pass_message:
        .byte 76,79,65,68,32,84,50,32,68,49,32,66,50,32,69,48,32,80,49,32,90,49,10,0
_fail_message:
        .byte 76,79,65,68,32,70,65,73,76,10,0
