; smoke-test.s -- SWTOS smoke test: blink LED and print banner via UART
;
; LED I/O:  0xFF0000 (bit 0, active-low: 0=ON, 1=OFF)
; UART TX:  0xFF0100 (write byte, no status check in emulator)
;
; Assemble:  cor24-asm smoke-test.s -o build/smoke-test.lgo
; Emulate:   cor24-emu --lgo build/smoke-test.lgo --terminal --speed 0

_main:
	push	fp
	mov	fp,sp
	add	sp,-4		; 2 locals: LED addr at -2(fp), counter at -3(fp)

	; --- Print "SWTOS smoke test OK\n" via UART ---
	la	r2,-65280		; r2 = 0xFF0100 UART data

	lc	r0,83			; 'S'
	sb	r0,0(r2)
	lc	r0,87			; 'W'
	sb	r0,0(r2)
	lc	r0,84			; 'T'
	sb	r0,0(r2)
	lc	r0,79			; 'O'
	sb	r0,0(r2)
	lc	r0,83			; 'S'
	sb	r0,0(r2)
	lc	r0,32			; ' '
	sb	r0,0(r2)
	lc	r0,115			; 's'
	sb	r0,0(r2)
	lc	r0,109			; 'm'
	sb	r0,0(r2)
	lc	r0,111			; 'o'
	sb	r0,0(r2)
	lc	r0,107			; 'k'
	sb	r0,0(r2)
	lc	r0,101			; 'e'
	sb	r0,0(r2)
	lc	r0,45			; '-'
	sb	r0,0(r2)
	lc	r0,116			; 't'
	sb	r0,0(r2)
	lc	r0,101			; 'e'
	sb	r0,0(r2)
	lc	r0,115			; 's'
	sb	r0,0(r2)
	lc	r0,116			; 't'
	sb	r0,0(r2)
	lc	r0,32			; ' '
	sb	r0,0(r2)
	lc	r0,79			; 'O'
	sb	r0,0(r2)
	lc	r0,75			; 'K'
	sb	r0,0(r2)
	lc	r0,10			; newline
	sb	r0,0(r2)

	; --- Blink LED 3 times ---
	la	r1,-65536		; r1 = 0xFF0000 LED register
	sw	r1,-2(fp)		; save LED addr

	; Blink counter = 3
	lc	r0,3
	sw	r0,-3(fp)

_blink:
	; Toggle LED: read, xor 1, write back
	lw	r1,-2(fp)		; load LED addr
	lb	r2,0(r1)		; read current value
	lc	r0,1
	xor	r2,r0			; toggle bit 0
	sb	r2,0(r1)		; write back

	; Delay: count down from 100
	lc	r0,100
_delay:
	add	r0,-1
	ceq	r0,z
	brf	_delay

	; Decrement blink counter
	lw	r0,-3(fp)
	add	r0,-1
	sw	r0,-3(fp)
	ceq	r0,z
	brf	_blink

	mov	sp,fp
	pop	fp
_halt:
	bra	_halt
