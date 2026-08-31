# SWTOS Build Instructions

set shell := ["bash", "-cu"]

TOOLSDIR := "tools/bin"
COR24ASM := TOOLSDIR + "/cor24-asm"
# cor24-emu with the SWTOS stack map; see scripts/swtos-emu.
COR24EMU := "scripts/swtos-emu"
COR24DBG := TOOLSDIR + "/cor24-dbg"
PLSWLGO := "tools/plsw.lgo"
PIPELINE := "./scripts/plsw-pipeline.sh"
SPCI_SCRIPTS := env_var_or_default("SPCI_SCRIPTS", "/disk1/github/hardwarewrighter/spci-scripts")

# Default: compile and run PL/SW smoke test
default: plsw-smoke-run

# Run every noninteractive emulator acceptance proof sequentially
emulator-acceptance:
    ./scripts/emulator-acceptance.sh

# Verify machine-readable emulator acceptance report generation
acceptance-report-smoke:
    python3 tests/test-acceptance-report.py

# Verify hardware bundles reject unsuitable emulator acceptance evidence
hardware-acceptance-report-smoke:
    python3 tests/test-hardware-acceptance-report.py

# ---- Assembly smoke test (pure .s, no PL/SW compiler) ----

# Assemble smoke test
smoke:
    mkdir -p build
    {{COR24ASM}} tests/smoke-test.s -o build/smoke-test.lgo --listing build/smoke-test.lst

# Run assembly smoke test
run: smoke
    {{COR24EMU}} --lgo build/smoke-test.lgo -n -1 --speed 0

# Debug assembly smoke test
debug: smoke
    {{COR24DBG}} --lgo build/smoke-test.lgo

# Dump memory after assembly smoke test halts
dump: smoke
    {{COR24EMU}} --lgo build/smoke-test.lgo -n -1 --speed 0 --dump

# Generate the resident program/service descriptor table
catalog-generate:
    python3 scripts/generate-catalog.py

# Verify declarative image-provider build records
provider-config-smoke:
    ./tests/test-provider-config.sh

# Verify the shared 39-byte PL/SW and COR24 process descriptor ABI
proc-desc-abi-smoke:
    ./tests/test-proc-desc-abi.sh

# Verify the checked-in catalog matches its manifest and compiles into SWTOS
catalog-smoke: plsw-system
    python3 scripts/generate-catalog.py --check

# Build and validate the first versioned COR24 embedded executable blob
cor24-image-smoke:
    ./tests/test-cor24-image.sh

# Pack the catalog and executable blobs into a flash-ready block image
cor24-storage-smoke:
    ./tests/test-cor24-storage.sh

# Read the generated media through the emulator's W25Q32 SPI device
spi-flash-read-smoke: cor24-storage-smoke
    ./tests/test-spi-flash-read.sh

# Load the versioned image into COR24 RAM and verify copy/BSS/entry behavior
cor24-loader-smoke:
    ./tests/test-cor24-loader.sh

# Compile and run PL/SW system image (menu + apps)
plsw-system: catalog-generate
    {{PIPELINE}} include/swtos.msw include/menu.msw include/hello_app.msw include/counter_app.msw include/clock_app.msw include/catalog_generated.msw include/catalog.msw tests/system.plsw

# Verify IMAGE_AUTOSTART dispatch launches the shell from catalog metadata
autostart-smoke: plsw-system
    ./tests/test-autostart.sh

# Verify shell run <name> lookup and resident program dispatch
catalog-run-smoke: plsw-system
    ./tests/test-catalog-run.sh

# Verify shell ls enumerates generated resident descriptors
catalog-list-smoke: plsw-system
    ./tests/test-catalog-list.sh

# Spawn two scheduled instances with descriptor-sized stacks and state
catalog-spawn-smoke:
    ./tests/test-catalog-spawn.sh

# Route a scheduled PL/SW shell run command through TASK_SPAWN
scheduled-shell-smoke:
    ./tests/test-scheduled-shell.sh

# Verify detailed process statistics and endpoint inspection
scheduled-stats-smoke:
    ./tests/test-scheduled-stats.sh

# Verify isolated virtual-TTY input and blocking reader wakeup
scheduled-tty-smoke:
    ./tests/test-scheduled-tty.sh

# Verify framed transport round trips, fragmentation, corruption, and reconnect
protocol-smoke:
    cargo test --manifest-path tools/te-rs/Cargo.toml

# Verify the COR24-side incremental framed decoder
protocol-target-smoke:
    ./tests/test-protocol-target.sh

# Verify scheduled SWTOS negotiates framing while preserving plain boot output
scheduled-protocol-smoke:
    ./tests/test-scheduled-protocol.sh

# Verify the four-pane Rust frontend through paired pseudo-terminals
windows-smoke:
    ./tests/test-windows-pty.sh

# Verify deterministic build-matched symbols and generated-source mappings
debug-info-smoke:
    ./tests/test-debug-info.sh

# Verify every generated source declares its generator and forbids editing
generated-banner-smoke: plsw-system scheduled-shell-build
    python3 scripts/check-generated-banners.py

# Build the pinned official stateful COR24 debugger under build/
cor24-debugger-build:
    ./scripts/build-cor24-debugger.sh

# Open the four-pane frontend on an emulator-backed PTY
cor24-debugger-demo image="build/scheduled-shell/program.bin" map="build/scheduled-shell/program.debug.json" session="build/sessions/demo.json": scheduled-shell-build cor24-debugger-build te-rs-release
    mkdir -p build/sessions
    ./scripts/swtos-emulator-debug.py {{image}} {{map}} --session {{session}}

# Validate the reproducible emulator-backed Windows demo tape
windows-demo-tools:
    bash scripts/with-demo-tools.sh --check

windows-demo-validate: windows-demo-tools
    bash scripts/with-demo-tools.sh vhs validate docs/demos/cor24-windows.tape

# Record the Windows demo and encode its README asset
windows-demo-record: windows-demo-validate scheduled-shell-build cor24-debugger-build te-rs-release
    mkdir -p build/captures
    bash scripts/with-demo-tools.sh vhs docs/demos/cor24-windows.tape
    just windows-demo-encode

# Encode the recorded master as a compact VP9 README asset
windows-demo-encode:
    bash scripts/with-demo-tools.sh ffmpeg -y -i build/captures/cor24-windows-master.mp4 -vf fps=12 -an -c:v libvpx-vp9 -b:v 0 -crf 44 -deadline good -cpu-used 4 -row-mt 1 videos/cor24-windows-demo.webm

# Record the six-pane, dual-hostile-process preemption acceptance demo
preemption-demo-record: windows-demo-tools scheduled-shell-build cor24-debugger-build te-rs-release
    bash scripts/with-demo-tools.sh vhs validate docs/demos/cor24-preemption.tape
    mkdir -p build/captures
    bash scripts/with-demo-tools.sh vhs docs/demos/cor24-preemption.tape
    just preemption-demo-encode

preemption-demo-encode:
    bash scripts/with-demo-tools.sh ffmpeg -y -i build/captures/cor24-preemption-master.mp4 -vf fps=12 -an -c:v libvpx-vp9 -b:v 0 -crf 44 -deadline good -cpu-used 4 -row-mt 1 videos/cor24-preemption-demo.webm

# Extract ignored evidence frames from the dual-hog recording for review
preemption-demo-inspect:
    mkdir -p build/captures
    bash scripts/with-demo-tools.sh ffmpeg -y -ss 3 -i build/captures/cor24-preemption-master.mp4 -frames:v 1 -update 1 build/captures/cor24-preemption-03.png
    bash scripts/with-demo-tools.sh ffmpeg -y -ss 19 -i build/captures/cor24-preemption-master.mp4 -frames:v 1 -update 1 build/captures/cor24-preemption-19.png
    bash scripts/with-demo-tools.sh ffmpeg -y -ss 42 -i build/captures/cor24-preemption-master.mp4 -frames:v 1 -update 1 build/captures/cor24-preemption-42.png
    bash scripts/with-demo-tools.sh ffmpeg -y -ss 55 -i build/captures/cor24-preemption-master.mp4 -frames:v 1 -update 1 build/captures/cor24-preemption-55.png
    bash scripts/with-demo-tools.sh ffmpeg -y -ss 64 -i build/captures/cor24-preemption-master.mp4 -frames:v 1 -update 1 build/captures/cor24-preemption-64.png
    bash scripts/with-demo-tools.sh ffmpeg -y -ss 70 -i build/captures/cor24-preemption-master.mp4 -frames:v 1 -update 1 build/captures/cor24-preemption-70.png

# Extract representative ignored frames for visual inspection of the recording
windows-demo-inspect:
    mkdir -p build/captures
    bash scripts/with-demo-tools.sh ffmpeg -y -ss 6 -i build/captures/cor24-windows-master.mp4 -frames:v 1 -update 1 build/captures/cor24-windows-06.png
    bash scripts/with-demo-tools.sh ffmpeg -y -ss 14 -i build/captures/cor24-windows-master.mp4 -frames:v 1 -update 1 build/captures/cor24-windows-14.png
    bash scripts/with-demo-tools.sh ffmpeg -y -ss 27 -i build/captures/cor24-windows-master.mp4 -frames:v 1 -update 1 build/captures/cor24-windows-27.png
    bash scripts/with-demo-tools.sh ffmpeg -y -ss 39 -i build/captures/cor24-windows-master.mp4 -frames:v 1 -update 1 build/captures/cor24-windows-39.png
    bash scripts/with-demo-tools.sh ffmpeg -y -ss 42 -i build/captures/cor24-windows-master.mp4 -frames:v 1 -update 1 build/captures/cor24-windows-42.png
    bash scripts/with-demo-tools.sh ffmpeg -y -ss 46 -i build/captures/cor24-windows-master.mp4 -frames:v 1 -update 1 build/captures/cor24-windows-46.png
    bash scripts/with-demo-tools.sh ffmpeg -y -ss 49 -i build/captures/cor24-windows-master.mp4 -frames:v 1 -update 1 build/captures/cor24-windows-49.png
    bash scripts/with-demo-tools.sh ffmpeg -y -ss 53 -i build/captures/cor24-windows-master.mp4 -frames:v 1 -update 1 build/captures/cor24-windows-53.png
    bash scripts/with-demo-tools.sh ffmpeg -y -ss 57 -i build/captures/cor24-windows-master.mp4 -frames:v 1 -update 1 build/captures/cor24-windows-57.png

# Exercise Counter breakpoints, state, stepping, backtrace, and detach
emulator-debugger-smoke: scheduled-shell-build cor24-debugger-build
    cargo test --manifest-path build/cor24-debugger/adapter-source/Cargo.toml
    ./tests/test-emulator-debugger.py

# Build the interactive Rust terminal used by local and hardware demos
te-rs-release:
    cargo build --release --manifest-path tools/te-rs/Cargo.toml

# Verify scheduled ls and run <name> command paths
scheduled-catalog-smoke:
    ./tests/test-scheduled-catalog-commands.sh

# Verify runtime memory accounting, peaks, reclamation, reset, and exhaustion
scheduled-memory-smoke:
    ./tests/test-scheduled-memory.sh

# Verify exited scheduled apps reclaim their stack/state arena allocations
scheduled-reclaim-smoke:
    ./tests/test-scheduled-reclaim.sh

# Verify round-robin process-table scanning across two concurrent child slots
scheduled-multislot-smoke:
    ./tests/test-scheduled-multislot.sh

# Fill every process-table slot, list them, and confirm the table refuses more
scheduled-sixteen-smoke:
    ./tests/test-scheduled-sixteen.sh

# Verify host-backed eight-byte block reads through the image-provider ABI
scheduled-block-provider-smoke: scheduled-multislot-smoke

# Find and load an embedded program through the W25Q32 image provider
scheduled-spi-provider-smoke: cor24-storage-smoke
    ./tests/test-scheduled-spi-provider.sh

# Verify resident-first interactive lookup with SPI fallback
scheduled-composite-spi-smoke: cor24-storage-smoke
    ./tests/test-scheduled-composite-spi.sh

# Keep independent descriptor snapshots for two simultaneously live SPI apps
scheduled-concurrent-spi-smoke: cor24-storage-smoke
    ./tests/test-scheduled-concurrent-spi.sh

# Keep independent descriptor snapshots for two simultaneously live SD apps
scheduled-concurrent-sd-smoke: cor24-storage-smoke
    ./tests/test-scheduled-concurrent-sd.sh

# Keep resident and SD-backed children live under the composite provider
scheduled-composite-sd-mixed-smoke: cor24-storage-smoke
    ./tests/test-scheduled-composite-sd-mixed.sh

# Load SD first, then keep a resident child live under the composite provider
scheduled-composite-sd-mixed-reverse-smoke: cor24-storage-smoke
    ./tests/test-scheduled-composite-sd-mixed-reverse.sh

# Build the scheduler-integrated PL/SW shell image
scheduled-shell-build:
    ./scripts/catalog-spawn-link.sh tests/catalog-shell.plsw scheduled-shell

# Verify complete flat-binary LGO generation, including zero records and entry
complete-lgo-smoke:
    python3 tests/test-complete-lgo.py

# Build the interactive shell with resident-first/SPI-fallback catalog lookup
scheduled-shell-spi-build: cor24-storage-smoke
    ./scripts/catalog-spawn-link.sh tests/catalog-shell.plsw scheduled-shell-spi composite-spi
    {{COR24ASM}} tests/spi-launch-seed.s -o build/scheduled-shell-spi/seed.lgo

# Build the interactive shell with resident-first/SD-fallback catalog lookup
scheduled-shell-sd-build: cor24-storage-smoke
    ./scripts/catalog-spawn-link.sh tests/catalog-shell.plsw scheduled-shell-sd composite-sd
    {{COR24ASM}} tests/spi-launch-seed.s -o build/scheduled-shell-sd/seed.lgo

# Verify resident-first interactive lookup with SD fallback
scheduled-composite-sd-smoke: cor24-storage-smoke
    ./tests/test-scheduled-composite-sd.sh

# Package checksummed resident, SPI, and flash artifacts for COR24-TB testing
hardware-validation-bundle:
    ./scripts/prepare-hardware-validation.sh

# Summarize a saved COR24 sigrok session; pass mode=text,rx-hex,tx-hex,info
logic-report session mode="text":
    cargo run --quiet --release --manifest-path tools/te-rs/Cargo.toml --bin sr-report -- "{{session}}" "{{mode}}"

# Capture all eight analyzer channels; duration is milliseconds
logic-capture session milliseconds="3000" samplerate="24m":
    {{SPCI_SCRIPTS}}/fx2-logic-analyzer/capture-sigrok.sh "{{session}}" "{{milliseconds}}" "{{samplerate}}"

# Preserve a Siglent C1 waveform descriptor and sample block over VXI-11
scope-waveform-capture session host="192.168.1.53" channel="1":
    {{SPCI_SCRIPTS}}/siglent-sds800x-hd/.venv/bin/python {{SPCI_SCRIPTS}}/siglent-sds800x-hd/capture-waveform.py "{{session}}" --host "{{host}}" --channel "{{channel}}"

# Export the acquired scope samples to a PulseView-compatible digital waveform
scope-waveform-vcd capture output:
    python3 {{SPCI_SCRIPTS}}/siglent-sds800x-hd/waveform-to-vcd.py "{{capture}}" "{{output}}"

# Download the current Siglent display, including UART decode overlays
scope-screen-capture output host="192.168.1.53":
    {{SPCI_SCRIPTS}}/siglent-sds800x-hd/.venv/bin/python {{SPCI_SCRIPTS}}/siglent-sds800x-hd/capture-screen.py "{{output}}" --host "{{host}}"

# Interactively exercise scheduled Hello and Counter choices
scheduled-shell-interactive: plsw-system-interactive

# Run the scheduler-integrated menu with heartbeat-aware UART input.
plsw-system-interactive: scheduled-shell-build
    ./scripts/swtos-terminal.py --image build/scheduled-shell/program.bin

# Run the scheduled shell with the generated W25Q32 media attached
plsw-system-spi-interactive: scheduled-shell-spi-build
    ./scripts/swtos-terminal.py --image build/scheduled-shell-spi/program.bin --lgo-seed build/scheduled-shell-spi/seed.lgo --spi-media build/catalog-images/swtos-storage.bin

# Run the scheduled shell with the generated storage image on emulated SD
plsw-system-sd-interactive: scheduled-shell-sd-build
    ./scripts/swtos-terminal.py --image build/scheduled-shell-sd/program.bin --lgo-seed build/scheduled-shell-sd/seed.lgo --sd-media build/catalog-images/swtos-storage.bin

# Run the former direct-call image for compatibility and catalog command work.
plsw-system-compat-interactive: plsw-system
    ./scripts/swtos-terminal.py

# Backward-compatible alias.
plsw-system-run: plsw-system-interactive

# ---- PL/SW compiler pipeline ----

# Compile PL/SW smoke test (with .msw includes) to .s + .lgo
plsw-smoke:
    {{PIPELINE}} include/swtos.msw tests/smoke-test.plsw

# Compile and run PL/SW smoke test
plsw-smoke-run: plsw-smoke
    {{COR24EMU}} --lgo build/smoke-test.lgo -n -1 --speed 0 --quiet

# Compile, FIXUP-link, and run two independent PL/SW modules
plsw-link-smoke:
    ./scripts/plsw-link-smoke.sh

# Exercise cooperative context switching between two task stacks
context-switch-smoke:
    ./tests/test-context-switch.sh

# Verify tasks and blocking IPC remain cooperative before clock synchronization
cooperative-fallback-smoke: context-switch-smoke

# Exercise fixed-message blocking send/receive through the TTY task
ipc-smoke: context-switch-smoke

# Exercise UART escape framing and wrapping 24-bit heartbeat deltas
heartbeat-smoke:
    ./tests/test-heartbeat.sh

# Record whether interrupt return state is software-visible for preemption
interrupt-context-capability-smoke:
    ./tests/test-interrupt-context-capability.sh

# Recover an IRQ PC through a one-byte ADD runway and resume without clobbers
preemption-runway-smoke:
    ./tests/test-preemption-runway.sh

# Prove a hostile private CPU loop cannot starve Resources or the debugger
preemption-acceptance: scheduled-shell-build cor24-debugger-build
    python3 tests/test-preemption-acceptance.py

# Fill every process slot from the shell menu and keep the clocks running
fill-demo-acceptance: scheduled-shell-build cor24-debugger-build
    python3 tests/test-fill-demo-acceptance.py

# Drive a live windowed session through many interactions and require it to survive
tui-soak: scheduled-shell-build cor24-debugger-build te-rs-release
    python3 tests/test-tui-soak.py

# Kill a clock, an uptime and a cpu-hog from the debugger; restart the shell
debugger-kill-acceptance: scheduled-shell-build cor24-debugger-build
    python3 tests/test-debugger-kill-acceptance.py

# Prove the shell keeps its prompt through unfinished arguments and typos
shell-command-parsing: scheduled-shell-build
    ./tests/test-shell-command-parsing.sh

# Rewind the one process that cannot be killed, from each state it can wedge in
shell-restart: scheduled-shell-build
    ./tests/test-shell-restart.sh

# Keep the keyboard at the prompt when background programs come and go
shell-foreground: scheduled-shell-build
    ./tests/test-shell-foreground.sh

# Read a configured DS1307 RTC through the COR24 I2C HAL from PL/SW
i2c-ds1307-smoke:
    ./tests/test-i2c-ds1307.sh

# Render the DS1307 time as 5x8 glyphs on the emulated SSD1306
i2c-oled-clock-smoke: i2c-ds1307-smoke

# Initialize an emulated SPI SD card and read sector zero from PL/SW
spi-sdcard-smoke:
    ./tests/test-spi-sdcard.sh

# Load a catalog application transparently through cached SD sectors
scheduled-sd-provider-smoke: cor24-storage-smoke
    ./tests/test-scheduled-sd-provider.sh

# Verify menu Clock app heartbeat logging and return to menu
clock-smoke: plsw-system
    python3 tests/test-terminal-input.py
    ./tests/test-clock.sh

# Compile and dump PL/SW smoke test
plsw-smoke-dump: plsw-smoke
    {{COR24EMU}} --lgo build/smoke-test.lgo -n -1 --speed 0 --dump

# Compile any .plsw file: just plsw-compile [include.msw ...] file.plsw
plsw-compile *ARGS:
    {{PIPELINE}} {{ARGS}}

# Compile and run any .plsw file: just plsw-run [include.msw ...] file.plsw
plsw-run *ARGS:
    {{PIPELINE}} {{ARGS}} --run

# Compile and dump any .plsw file: just plsw-dump [include.msw ...] file.plsw
plsw-dump *ARGS:
    {{PIPELINE}} {{ARGS}} --dump

# ---- Toolchain ----

# Clone the peer dependency repositories and build tools/bin/ from source
toolchain:
    ./scripts/build-toolchain.sh

# Verify the toolchain binaries this repository expects are installed
toolchain-check:
    ./scripts/build-toolchain.sh --check

# Backward-compatible alias.
install-tools: toolchain

# Clean build artifacts
clean:
    rm -rf build
