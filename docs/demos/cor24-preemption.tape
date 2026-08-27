Output "build/captures/cor24-preemption-master.mp4"

Require bash
Set Shell "bash"
Set FontSize 15
Set Width 1400
Set Height 900
Set Framerate 15
Set TypingSpeed 25ms
Set Theme "Catppuccin Mocha"
Set Padding 12

# Establish that both hostile processes use this complete, syscall-free image.
Type "sed -n '1,12p' catalog/images/cpu-hog.s"
Enter
Sleep 5s

Type "./scripts/swtos-emulator-debug.py build/scheduled-shell/program.bin build/scheduled-shell/program.debug.json"
Enter
Sleep 4s

# Fill the application panes with ordinary blocking clock workloads first.
Type "run uptime --tty=new"
Enter
Sleep 3s
Type "run clock --tty=new"
Enter
Sleep 4s
Ctrl+A
Type "s"
Ctrl+A
Type "4"
Ctrl+A
Type "z"
Sleep 4s
Ctrl+A
Type "z"
# Stop each blocking app through its TTY, then close those two retained panes.
Ctrl+A
Type "2"
Ctrl+A
Type "e"
Sleep 2s
Ctrl+A
Type "x"
Ctrl+A
Type "4"
Ctrl+A
Type "e"
Sleep 2s
Ctrl+A
Type "x"
Sleep 2s
Ctrl+A
Type "1"

# Reuse the freed endpoints for two copies of the exact hostile image above.
Type "run cpu-hog --tty=new"
Enter
Type "run cpu-hog --tty=new"
Enter
Sleep 6s

# Six panes and named process evidence while neither hog ever yields.
Type "ps -l"
Enter
Sleep 6s

# Both private saved contexts advance independently across resumptions.
Ctrl+A
Type "2"
Type "regs 2"
Enter
Sleep 3s
Type "regs 3"
Enter
Sleep 3s
Type "regs 2"
Enter
Sleep 3s
Type "regs 3"
Enter
Sleep 3s

# Kill endpoint 2 only and prove endpoint 3 remains live.
Type "kill 2"
Enter
Sleep 4s
Ctrl+A
Type "3"
Ctrl+A
Type "z"
Sleep 5s
Ctrl+A
Type "z"
Ctrl+A
Type "1"
Type "ps -l"
Enter
Sleep 5s
Ctrl+A
Type "d"
Sleep 1s
