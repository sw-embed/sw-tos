# SWTOS Build Instructions

set shell := ["bash", "-cu"]

TOOLSDIR := "tools/bin"
COR24ASM := TOOLSDIR + "/cor24-asm"
COR24EMU := TOOLSDIR + "/cor24-emu"
COR24DBG := TOOLSDIR + "/cor24-dbg"

# Default: assemble smoke test and verify in emulator
default: smoke

# Assemble smoke test
smoke:
    mkdir -p build
    {{COR24ASM}} smoke-test.s -o build/smoke-test.lgo --listing build/smoke-test.lst

# Run smoke test in emulator (no instruction limit)
run: smoke
    {{COR24EMU}} --lgo build/smoke-test.lgo -n -1 --speed 0

# Debug smoke test
debug: smoke
    {{COR24DBG}} --lgo build/smoke-test.lgo

# Dump memory after smoke test halts
dump: smoke
    {{COR24EMU}} --lgo build/smoke-test.lgo -n -1 --speed 0 --dump

# Install toolchain binaries (requires sw-cor24-isa, sw-cor24-x-assembler,
# sw-cor24-emulator repos as siblings, then clean up repos)
# See docs/plan.md section 16 for details.
install-tools:
    @echo "See docs/plan.md -- toolchain section for build instructions"
    @echo "Binaries should be placed in {{TOOLSDIR}}/"

# Clean build artifacts
clean:
    rm -rf build
