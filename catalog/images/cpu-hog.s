; Position-independent hostile task: no yield, syscall, memory access, IPC,
; sleep, blocking operation, or UART output.
_start:
        lc      r0,0
        lc      r1,1
_cpu_hog_loop:
        add     r0,r1
        bra     _cpu_hog_loop
