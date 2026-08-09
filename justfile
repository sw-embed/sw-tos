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

# Compile and run PL/SW system image (menu + apps)
plsw-system:
    {{PIPELINE}} include/swtos.msw include/menu.msw include/hello_app.msw include/counter_app.msw include/clock_app.msw system.plsw

# Run the menu interactively. cor24-emu 0.1.0 ignores --terminal for --lgo,
# so use its raw-binary path, which correctly bridges stdin to the UART.
plsw-system-interactive: plsw-system
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

# Exercise fixed-message blocking send/receive through the TTY task
ipc-smoke: context-switch-smoke

# Exercise UART escape framing and wrapping 24-bit heartbeat deltas
heartbeat-smoke:
    ./tests/test-heartbeat.sh

# Verify menu Clock app heartbeat logging and return to menu
clock-smoke: plsw-system
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
