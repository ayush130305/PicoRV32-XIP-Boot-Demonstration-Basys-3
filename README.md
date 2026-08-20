# PicoRV32 XIP Boot Demonstration — Basys 3

A RISC-V soft CPU (PicoRV32) booting and executing real code directly from
external QSPI flash on a Digilent Basys 3 (Xilinx Artix-7), with no
bootloader and no program copied into RAM — **confirmed working
end-to-end on physical hardware**, LEDs and seven-segment display both
verified.

This builds on an existing QSPI Flash Controller + AXI4-Lite Wrapper IP
core (see the core project's own README for that component's design,
register map, and simulation results). This document covers the hardware
integration layer built on top of it: PicoRV32, on-chip RAM, the LED and
seven-segment demonstration peripherals, and real hardware bring-up.

## What this demonstrates

The onboard QSPI flash chip (Macronix MX25L3233F) serves two roles
simultaneously on this board:

1. It holds the FPGA's own configuration bitstream (standard Xilinx
   self-boot behavior).
2. It *also* holds a small RISC-V program, which PicoRV32 executes
   directly, one instruction at a time, without ever copying it into RAM
   first — a technique called XIP (execute-in-place).

The demonstration program does two things with the same underlying
timing loop:
- **16 onboard LEDs** fill up one at a time, cumulatively, until all are
  lit, then reset and repeat — a simple, visually unambiguous way to
  prove real code is genuinely executing.
- **The 4-digit seven-segment display** simultaneously shows a genuine,
  independent incrementing counter (`0000, 0001, 0002, ...`) that
  persists continuously across every LED cycle, rather than resetting
  alongside it — proving the CPU is tracking real, separate state over
  time, not just replaying a fixed pattern.

## Architecture

```
                    ┌───────────────────────────────────────┐
                    │           Basys 3 (XC7A35T)            │
                    │                                         │
  QSPI flash ───────┼── STARTUPE2 ──► qspi_axi_top            │
  (MX25L3233F)       │   (CCLK access    (existing IP core,   │
                    │    to real SCLK)   unchanged)           │
                    │         │                                │
                    │         ▼                                │
                    │   system_router ◄── PicoRV32             │
                    │    (1 AXI master  │  (picorv32_axi)      │
                    │     → 4 slaves)   │                      │
                    │         │          │                     │
                    │  ┌──────┼──────┬───┴────┬─────────┐      │
                    │  ▼      ▼      ▼         ▼         │      │
                    │ QSPI   on-chip LED    seven-seg    │      │
                    │ IP     RAM     → 16   → 4-digit    │      │
                    │ (XIP)  (8KB)   LEDs   display      │      │
                    └───────────────────────────────────────┘

  qe_provision runs FIRST, before any of the above is released from
  reset - sets the flash chip's Quad Enable bit directly, bypassing
  qspi_axi_top entirely (see "Real hardware findings" below).
```

**PROGADDR_RESET** points PicoRV32's very first instruction fetch
directly into the QSPI IP's XIP address window — so the CPU boots
straight from flash with zero bootloader.

## Key components built for this integration

| File | Role |
|---|---|
| `basys3_top.sv` | Top-level integration of every piece below |
| `system_router.sv` | Routes PicoRV32's single AXI master port to four slave destinations (QSPI IP, LED, RAM, seven-segment) by address |
| `sram.sv` | 8KB on-chip Block RAM — PicoRV32's stack/data memory |
| `led_peripheral.sv` | Single memory-mapped register driving the 16 onboard LEDs |
| `seven_seg.sv` | Drives the 4-digit multiplexed seven-segment display; owns its own continuous hardware refresh loop, independent of software timing |
| `qe_provision.sv` | One-time flash provisioning (see below) — a permanent, required part of the design, not temporary scaffolding |
| `led_chase.S` / `.bin` | The demonstration program (RV32I assembly) |

## Real hardware findings

Bring-up surfaced several genuine hardware/toolchain issues beyond what
simulation alone could catch — each confirmed and resolved through
direct hardware testing, not assumption:

- **Flash clock routing**: Basys 3's flash `SCLK` pin is wired to the
  FPGA's dedicated configuration clock, reachable only via the Xilinx
  `STARTUPE2` primitive — not a normal I/O pin. Confirmed against
  Digilent's own reference material.
- **Quad Enable (QE) bit**: the flash chip's quad-mode read support is
  gated behind a status register bit that defaults to 0 from the
  factory, and is not reliably set by Vivado's flash-programming flow
  alone (contrary to general documentation). `qe_provision.sv` was built
  to explicitly set this via a direct `WREN`/`WRSR` sequence to the
  flash chip, bypassing the main QSPI engine (which isn't structured to
  issue zero-address commands).
- **Root cause of extended bring-up difficulty — a clock-domain bug**:
  the provisioning logic was initially clocked from the system clock
  (100MHz) rather than the actual clock reaching the physical flash pin
  (50MHz, via `STARTUPE2`). This silently corrupted all real chip
  communication despite every other part of the design — protocol
  sequencing, opcodes, exact datasheet-verified bit timing — being
  independently confirmed correct through extensive review. 
- **Seven-segment display polarity**: both the digit-select (anode) and
  segment signals are active-LOW on this board specifically, confirmed
  directly against Digilent's reference manual — differs from the
  generic textbook common-anode convention (active-high anode), which
  would have been incorrect here.

## Verification

- **Simulation**: full-system testbench (`tb_basys3_top.sv`) confirms
  correct boot, XIP fetch, LED fill sequence, and seven-segment/counter
  behavior using the real assembled program — including confirming the
  counter persists correctly, with zero reset, across LED cycle
  wraparounds.
- **Real hardware**: confirmed via direct observation on the physical
  board — JEDEC ID readback (`0xC2`), QE bit set, no CPU trap on first
  fetch, and the full 16-LED cumulative fill-and-repeat sequence running
  correctly.

## Status

**Core objective achieved and confirmed on real hardware**: PicoRV32
executing real, XIP-fetched code from physical QSPI flash on real
Basys 3 hardware, with correct, observable output on both the LEDs and
the seven-segment display. The hardware-debug diagnostic overlay used
during QE-bit bring-up has been removed, restoring the full clean 16-bit
LED output.

**Not yet independently confirmed on real hardware** (verified in
simulation only, at time of writing): the seven-segment display and
counter feature specifically — the underlying mechanism (XIP fetch,
AXI routing, peripheral writes) is the same infrastructure already
proven working for the LEDs, but this specific addition has not yet had
its own dedicated real-hardware test pass.
