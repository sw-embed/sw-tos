Output "build/captures/cor24-windows-master.mp4"

Require bash

Set Shell "bash"
Set FontSize 16
Set Width 1200
Set Height 760
Set Framerate 15
Set TypingSpeed 25ms
Set Theme "Catppuccin Mocha"
Set Padding 14

Type "./scripts/swtos-emulator-debug.py build/scheduled-shell/program.bin build/scheduled-shell/program.debug.json"
Enter
Sleep 4s

# Inspect the process table from Shell.
Type "ps"
Enter
Sleep 2s

# Run Uptime, show its application output, then inspect its live resource row.
Type "3"
Sleep 4s
Ctrl+A
Type "2"
Sleep 2s
Ctrl+A
Type "4"
Ctrl+A
Type "z"
Sleep 2s
Ctrl+A
Type "z"
Ctrl+A
Type "2"
Ctrl+A
Type "e"
Sleep 2s

# Run Clock and show host-synchronized wall time in the Application pane.
Ctrl+A
Type "1"
Type "4"
Sleep 4s
Ctrl+A
Type "2"
Sleep 3s
Ctrl+A
Type "e"
Sleep 2s

# Inspect build-matched symbols, source, instructions, registers, and memory.
Ctrl+A
Type "3"
Type "sym _PLSW_COUNTER"
Enter
Type "list _PLSW_COUNTER"
Enter
Type "dis _PLSW_COUNTER 6"
Enter
Type "regs 1"
Enter
Type "x 0 8"
Enter
Sleep 5s

# Return to Shell and launch the hostile non-yielding CPU hog.
Ctrl+A
Type "1"
Type "run cpu-hog"
Enter
Sleep 3s

# Resources continues refreshing and shows forced-preemption/counter progress.
Ctrl+A
Type "4"
Ctrl+A
Type "z"
Sleep 4s
Ctrl+A
Type "z"

# The debugger remains responsive even though cpu-hog never cooperates.
Ctrl+A
Type "3"
Type "regs 2"
Enter
Sleep 3s

# Detach cleanly while the hostile process is still running.
Ctrl+A
Type "d"
Sleep 1s
