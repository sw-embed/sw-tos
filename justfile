# SWTOS Build Instructions

set shell := ["bash", "-cu"]

TOOLSDIR := "tools/bin"
COR24ASM := TOOLSDIR + "/cor24-asm"
COR24EMU := TOOLSDIR + "/cor24-emu"
COR24DBG := TOOLSDIR + "/cor24-dbg"
PLSWLGO := "tools/plsw.lgo"
PIPELINE := "./scripts/plsw-pipeline.sh"

# Default: compile and run PL/SW smoke test
default: plsw-smoke-run

# ---- Assembly smoke test (pure .s, no PL/SW compiler) ----

# Assemble smoke test
smoke:
    mkdir -p build
    {{COR24ASM}} smoke-test.s -o build/smoke-test.lgo --listing build/smoke-test.lst

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
    {{PIPELINE}} include/swtos.msw include/menu.msw include/hello_app.msw include/counter_app.msw include/clock_app.msw include/catalog_generated.msw include/catalog.msw system.plsw

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

# Verify scheduled ls and run <name> command paths
scheduled-catalog-smoke:
    ./tests/test-scheduled-catalog-commands.sh

# Verify exited scheduled apps reclaim their stack/state arena allocations
scheduled-reclaim-smoke:
    ./tests/test-scheduled-reclaim.sh

# Verify round-robin process-table scanning across two concurrent child slots
scheduled-multislot-smoke:
    ./tests/test-scheduled-multislot.sh

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

# Build the scheduler-integrated PL/SW shell image
scheduled-shell-build:
    ./scripts/catalog-spawn-link.sh tests/catalog-shell.plsw scheduled-shell

# Build the interactive shell with resident-first/SPI-fallback catalog lookup
scheduled-shell-spi-build: cor24-storage-smoke
    ./scripts/catalog-spawn-link.sh tests/catalog-shell.plsw scheduled-shell-spi composite-spi
    {{COR24ASM}} tests/spi-launch-seed.s -o build/scheduled-shell-spi/seed.lgo

# Package checksummed resident, SPI, and flash artifacts for COR24-TB testing
hardware-validation-bundle:
    ./scripts/prepare-hardware-validation.sh

# Interactively exercise scheduled Hello and Counter choices
scheduled-shell-interactive: plsw-system-interactive

# Run the scheduler-integrated menu with heartbeat-aware UART input.
plsw-system-interactive: scheduled-shell-build
    ./scripts/swtos-terminal.py --image build/scheduled-shell/program.bin

# Run the scheduled shell with the generated W25Q32 media attached
plsw-system-spi-interactive: scheduled-shell-spi-build
    ./scripts/swtos-terminal.py --image build/scheduled-shell-spi/program.bin --lgo-seed build/scheduled-shell-spi/seed.lgo --spi-media build/catalog-images/swtos-storage.bin

# Run the former direct-call image for compatibility and catalog command work.
plsw-system-compat-interactive: plsw-system
    ./scripts/swtos-terminal.py

# Backward-compatible alias.
plsw-system-run: plsw-system-interactive

# ---- PL/SW compiler pipeline ----

# Compile PL/SW smoke test (with .msw includes) to .s + .lgo
plsw-smoke:
    {{PIPELINE}} include/swtos.msw smoke-test.plsw

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

# Read a configured DS1307 RTC through the COR24 I2C HAL from PL/SW
i2c-ds1307-smoke:
    ./tests/test-i2c-ds1307.sh

# Render the DS1307 time as 5x8 glyphs on the emulated SSD1306
i2c-oled-clock-smoke: i2c-ds1307-smoke

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

# Install toolchain binaries (see docs/plan.md section 16)
install-tools:
    @echo "See docs/plan.md -- toolchain section for build instructions"
    @echo "Binaries should be placed in {{TOOLSDIR}}/"

# Clean build artifacts
clean:
    rm -rf build
