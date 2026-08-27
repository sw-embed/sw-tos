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

# Run a Shell command and show the live resource monitor.
Type "ps"
Enter
Sleep 2s
Ctrl+A
Type "4"
Sleep 2s
Ctrl+A
Type "z"
Sleep 2s
Ctrl+A
Type "z"

# Inspect build-matched symbols and live target state.
Ctrl+A
Type "3"
Type "sym _PLSW_COUNTER"
Enter
Type "regs 1"
Enter
Type "x 0 8"
Enter
Sleep 3s

# Demonstrate debugger scrollback navigation without sending arrows to SWTOS.
Ctrl+A
Type "y"
Up
Right
Sleep 2s
Type "G"
Type "q"

# Return to Shell, launch Counter, and detach cleanly.
Ctrl+A
Type "1"
Type "run counter"
Enter
Sleep 3s
Ctrl+A
Type "d"
Sleep 1s
