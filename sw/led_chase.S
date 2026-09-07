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
# genuine incrementing DECIMAL counter (0000, 0001, ..., 0009, 0010,
# 0011, ...) - real integer counting, never showing hex letters A-F.
#
# DECIMAL DISPLAY, NO HARDWARE DIVIDE NEEDED: this PicoRV32 build has no
# hardware multiply/divide (ENABLE_MUL=0, ENABLE_DIV=0), and converting
# a normal binary counter to decimal digits for display would ordinarily
# need repeated division by 10. Instead, the counter itself is kept in
# BCD (Binary-Coded Decimal) form directly - each 4-bit nibble always
# holds a single decimal digit 0-9, never 10-15. bcd_increment below
# handles the digit-by-digit carry (9 -> 0, carry to next digit) using
# only compares and branches, no division at all. seven_seg.sv's
# existing hex-nibble-to-segment decode logic is completely unchanged -
# since every nibble we ever feed it is already 0-9, it just naturally
# displays as genuine decimal digits with zero hardware modification.
#
# Speed: delay constant halved from the original 3,000,000 to 1,500,000
# - roughly double speed, ~35-40ms per step instead of ~75-90ms.
#
# No stack usage at all in this version - deliberately, since it's the
# very first real program run on this whole integration. Simple enough to
# reason about with total confidence; no subroutine calls in the formal
# call/return sense (bcd_increment below is the one exception - a real
# jal/ret call, since a loop-based routine called from one place is
# clearer as an actual subroutine than inlined at the call site). No
# local variables spilled to memory. STACKADDR is still correctly
# configured in basys3_top.sv regardless (PicoRV32 initializes sp/x2
# from it automatically at reset), but nothing here needs it - jal/ret
# doesn't require a stack, only nested/recursive calls would.
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
    li      t6, 0               # BCD counter - initialized exactly once here,
                                  # never reinitialized again, so it keeps
                                  # counting continuously across every LED
                                  # cycle restart below. Each nibble is
                                  # always 0-9 (BCD), never A-F.

restart_pattern:
    li      t0, 0               # current LED pattern (starts fully off)
    li      t4, 1                # next bit to add to the pattern

fill_loop:
    or      t0, t0, t4          # add the next LED to the growing pattern
    sw      t0, 0(t1)           # write it out - LEDs update immediately

    jal     ra, bcd_increment   # increment the BCD counter (t6) by 1,
                                  # handling digit carry correctly - see
                                  # the routine below
    sw      t6, 0(t5)           # show the real running decimal count on
                                  # the seven-segment display

    li      t2, 1500000         # delay count - HALVED from the original
                                  # 3,000,000 for roughly double speed
                                  # (~35-40ms/step instead of ~75-90ms).
                                  # Change this single constant for any
                                  # other speed.
delay:
    addi    t2, t2, -1
    bnez    t2, delay

    slli    t4, t4, 1           # move to the next LED position
    li      t3, 0x10000         # 1 << 16 - one past the last valid LED bit
    blt     t4, t3, fill_loop   # keep filling until all 16 are lit

    # All 16 LEDs are now lit. Reset the LED pattern to fully off and
    # restart that part of the sequence - but jump to restart_pattern,
    # NOT _start, so t6 (the BCD counter) is never reinitialized and
    # keeps counting seamlessly across this reset.
    j       restart_pattern

##############################################################################
# bcd_increment: increments t6 by 1, treating it as 4 packed BCD digits
# (4 bits each), correctly carrying 9->0 into the next digit rather than
# rolling into A-F like a normal binary increment would. Uses a0/a1/a2/
# a3/a4/a5 as scratch (all otherwise unused in this program, no conflicts
# with t0-t6/t1/t5's roles above). Reached via jal/ra, a real call/return
# - the one place this program uses that convention.
##############################################################################
bcd_increment:
    li      a1, 0                # digit index, counts 0 to 3 (4 digits)
    li      a3, 1                # carry-in - starts at 1, since we're
                                   # incrementing by exactly 1
    li      a4, 0                # rebuilt value, accumulated digit by digit
    li      a5, 0                # current shift amount (0, 4, 8, 12)

bcd_loop:
    srl     a0, t6, a5           # shift so the target digit lands in bits 3:0
    andi    a0, a0, 0xF          # extract just that digit
    add     a0, a0, a3           # add carry-in from the previous digit
    li      a3, 0                # default: no carry out of THIS digit
    li      a2, 10
    bne     a0, a2, bcd_nocarry
    li      a0, 0                # this digit wrapped 9 -> 0
    li      a3, 1                # carry out to the next digit
bcd_nocarry:
    sll     a0, a0, a5           # shift the digit back into its real position
    or      a4, a4, a0           # merge into the rebuilt value
    addi    a5, a5, 4            # move to the next nibble position
    addi    a1, a1, 1
    li      a2, 4
    blt     a1, a2, bcd_loop     # loop for all 4 digits

    mv      t6, a4               # write the rebuilt BCD value back to t6
    jalr    zero, ra, 0          # return to caller
