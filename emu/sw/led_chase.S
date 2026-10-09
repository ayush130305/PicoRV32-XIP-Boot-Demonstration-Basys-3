##############################################################################
# led_chase.S
#
# Demonstration program for the Basys3/PicoRV32/XIP integration. Fetched
# directly from flash via XIP - PicoRV32's PROGADDR_RESET is set to
# QSPI_XIP_BASE + USER_PROGRAM_FLASH_OFFSET in basys3_top.sv, so this
# file's own base address (set below via -Ttext) MUST match that exactly,
# or the CPU will jump into the middle of this code instead of _start.
#
# Behavior: LEDs fill up one at a time (LED0, then LED0+LED1, then
# LED0+LED1+LED2, ...) until all 16 are lit, then the LED pattern resets
# to off and restarts. The seven-segment display independently shows a
# genuine incrementing counter (0000, 0001, 0002, ...) - a real count,
# not a mirror of the LED bit-pattern. The counter increments once per
# LED step and, deliberately, is NEVER reset when the LED pattern wraps
# around - it keeps counting continuously across LED cycles, so it reads
# as an actual running count rather than something that resets every
# ~1.4 seconds along with the LEDs.
#
# No stack usage at all in this version - deliberately, since it's the
# very first real program run on this whole integration. Simple enough to
# reason about with total confidence; no subroutine calls, no local
# variables spilled to memory. STACKADDR is still correctly configured in
# basys3_top.sv regardless (PicoRV32 initializes sp/x2 from it
# automatically at reset), but nothing in this program actually needs it.
#
# Assembled deliberately targeting plain rv32i (no compressed, no M/D
# extension) - matching picorv32_axi's actual configuration in
# basys3_top.sv (COMPRESSED_ISA=0, ENABLE_MUL=0, ENABLE_DIV=0). Using any
# instruction outside this set would silently fail on real hardware,
# since this specific PicoRV32 build cannot execute them at all.
##############################################################################

.section .text
.global _start

_start:
    li      t1, 0x02000000      # LED peripheral base address
    li      t5, 0x03000000      # seven-segment display peripheral base address
    li      t6, 0               # counter - initialized exactly once here,
                                  # never reinitialized again, so it keeps
                                  # counting continuously across every LED
                                  # cycle restart below

restart_pattern:
    li      t0, 0               # current LED pattern (starts fully off)
    li      t4, 1                # next bit to add to the pattern

fill_loop:
    or      t0, t0, t4          # add the next LED to the growing pattern
    sw      t0, 0(t1)           # write it out - LEDs update immediately

    addi    t6, t6, 1           # increment the independent counter -
                                  # completely separate from the LED
                                  # pattern logic above
    sw      t6, 0(t5)           # show the real running count on the
                                  # seven-segment display

    li      t2, 3000000         # delay count - tuned for a visible step
                                  # rate (~90ms/step at 100MHz); adjust
                                  # this single constant to speed up or
                                  # slow down the whole sequence
delay:
    addi    t2, t2, -1
    bnez    t2, delay

    slli    t4, t4, 1           # move to the next LED position
    li      t3, 0x10000         # 1 << 16 - one past the last valid LED bit
    blt     t4, t3, fill_loop   # keep filling until all 16 are lit

    # All 16 LEDs are now lit. Reset the LED pattern to fully off and
    # restart that part of the sequence - but jump to restart_pattern,
    # NOT _start, so t6 (the counter) is never reinitialized and keeps
    # counting seamlessly across this reset.
    j       restart_pattern
