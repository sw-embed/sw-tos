Output "/tmp/cor24-terminal-master.mp4"

Require bash

Set Shell "bash"
Set FontSize 17
Set Width 960
Set Height 600
Set Framerate 15
Set TypingSpeed 25ms
Set Theme "Catppuccin Mocha"
Set Padding 14

Hide
Type "cor24() { ./tools/te-rs/target/release/te-rs --swtos /dev/serial/by-id/usb-FTDI_FT232R_USB_UART_A50285BI-if00-port0; }"
Enter
Show

Type "cor24"
Enter
Sleep 1s

# Refresh the menu because UART output emitted before attachment is not replayed.
Enter
Sleep 1s

Type "help"
Enter
Sleep 1s

Type "df"
Enter
Sleep 1s

Type "du"
Enter
Sleep 1s

Type "stat embedded-ping"
Enter
Sleep 1s

Type "5"
Sleep 2s

# This sequence also demonstrates the fixed numeric-choice terminal state.
Type "3"
Sleep 3s
Escape
Sleep 2s

Type "4"
Sleep 3s
Escape
Sleep 2s

Ctrl+C
Sleep 1s

# The checked-in asset is reduced from this temporary master with:
# ffmpeg -i /tmp/cor24-terminal-master.mp4 -vf fps=8 -an \
#   -c:v libwebp_anim -lossless 0 -q:v 48 -compression_level 6 -loop 0 \
#   videos/cor24-terminal-demo.webp
