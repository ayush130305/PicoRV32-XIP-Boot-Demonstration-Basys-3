# PicoRV32 XIP Boot Demonstration — Basys 3

**Repository**: [github.com/ayush130305/PicoRV32-XIP-Boot-Demonstration-Basys-3](https://github.com/ayush130305/PicoRV32-XIP-Boot-Demonstration-Basys-3)

## What the project does

A RISC-V soft CPU (PicoRV32) is configured onto a Digilent Basys 3
FPGA board and boots **directly from external QSPI flash**, with no
bootloader and no program ever copied into RAM. The CPU fetches every
single instruction live, straight from the flash chip, for as long as
it runs — a technique called **XIP (execute-in-place)**.

To prove this is genuinely working — not just configured, but actually
executing real, correct code — the CPU drives two visible outputs:

- **16 onboard LEDs**, filling up one at a time, cumulatively, until
  all are lit, then resetting and repeating.
- **A 4-digit seven-segment display**, showing an independent,
  continuously incrementing **hexadecimal** counter (`0000, 0001, ...
  0009, 000A, ... 000F, 0010, ...`) that keeps counting across every
  LED reset, rather than restarting alongside it.

This currently uses only the base RV32I instruction set (RISC-V's
minimal integer-only instruction set — addition, subtraction, loads,
stores, branches; see the RISC-V theory section below). The CPU has no
way to *read* anything from the outside world yet — every peripheral
built so far is write-only. Extending this to accept real input
(buttons, switches) is the natural next step, covered in Future Scope.

---

## Files

**New for this integration:**

| File | Description |
|---|---|
| `basys3_top.sv` | Top-level module. Wires every other module together into the complete system, and is the only file with real physical board pins as ports. |
| `qe_provision.sv` | One-time flash setup routine. Runs before anything else, unlocking a feature the flash chip needs before it can be used the way this project needs it. |
| `system_router.sv` | Address-based traffic director. The CPU has one bus port but four destinations; this module decides where each transaction actually goes. |
| `sram.sv` | 8KB of on-chip Block RAM — the CPU's stack/scratch memory. |
| `led_peripheral.sv` | A single register wired directly to the 16 LEDs. |
| `seven_seg.sv` | Drives the 4-digit display. Unlike the LED peripheral, this one runs its own continuous internal refresh loop, independent of software. |
| `led_chase.S` / `.bin` | The actual RISC-V program the CPU runs — assembly source and its compiled machine code. |
| `basys3_top.xdc` | Physical constraints file — maps every logical signal in the design to a real, physical pin on the FPGA package. |
| `picorv32.v` | The real, unmodified PicoRV32 core source (external — see the Theory section for what it can do). |

**The pre-existing QSPI flash controller IP** (built on top of, not
modified — 9 files):

| File | Description |
|---|---|
| `qspi_axi_pkg.sv` | Shared constants — register offsets, bit positions — imported by several of the files below. Not a module itself, just a package. |
| `pulse_sync.sv` | A single-bit clock-domain-crossing primitive — safely passes a one-cycle pulse from one clock domain to another. |
| `cdc_bridge.sv` | Uses `pulse_sync.sv` to safely cross every control/data signal between the CPU's clock domain (`ACLK`) and the QSPI engine's own clock domain (`QCLK`). |
| `qspi_engine.sv` | The actual QSPI shift engine — walks a transaction through its command/address/dummy/data phases and drives the real `io0`-`io3` pins. Has no knowledge of AXI at all. |
| `qspi_arbiter.sv` | Since two different things can both want to use the QSPI engine (ordinary register access, and XIP fetches), this decides who gets it and keeps their responses from crossing wires. |
| `axi4L_slave.sv` | The ordinary, register-based AXI4-Lite interface to the QSPI engine — control/status/data registers a CPU can read and write directly. |
| `qspi_xip_slave.sv` | The memory-mapped, read-only interface — any AXI read landing in the XIP address range transparently becomes a real QSPI flash read. |
| `qspi_unified_slave.sv` | Merges the register interface and the XIP interface into one single external AXI4-Lite port, since PicoRV32 only has one bus port to offer. |
| `qspi_axi_top.sv` | The wrapper tying all 8 files above together into one module — this is what `basys3_top.sv` actually instantiates. |

---

## Architecture

```
                Basys 3 board (physical pins)
                             │
             ┌────────────────────────────────────────────┐
             │            basys3_top.sv                   │
             │                                            │
QSPI flash ──┤  qe_provision.sv                           │
             │  (runs first: unlocks flash quad           │
             │   mode, then releases everything           │
             │   else)                                    │
             │                                            │
             │      ┌── system_router.sv ──┐              │
             │      │  (1 CPU port,        │              │
             │CPU ──┤   4 destinations)    │              │
             │(PicoRV32)                   │              │
             │      └──┬────┬────┬────┬────┘              │
             │         ▼    ▼    ▼    ▼                   │
             │      qspi_ sram led_  seven_               │
             │      axi_  .sv  periph seg                 │
             │      top  (RAM) .sv   .sv                  │
             │      .sv        (LEDs)(display)            │
             └────────────────────────────────────────────┘
```

Every peripheral sits behind the same kind of interface (AXI4-Lite —
see theory below), which is exactly what lets `system_router.sv` treat
them uniformly: it doesn't need to know *what* a peripheral does, only
*which address range* it owns.

### Inside `qspi_axi_top.sv` — the pre-existing IP's own internal structure

The main diagram above shows `qspi_axi_top.sv` as one block. Internally,
it's actually 9 separate files with a real, specific topology:

```
        Single AXI4-Lite port (from system_router.sv)
                          │
                          ▼
              qspi_unified_slave.sv
     (routes by address: register range → left,
              XIP range → right)
                 │                 │
                 ▼                 ▼
        axi4L_slave.sv     qspi_xip_slave.sv
        (register-based     (memory-mapped,
         read/write)          read-only XIP)
                 │                 │
                 └────────┬────────┘
                          ▼
                  qspi_arbiter.sv
       (only one of the two above can use the
              engine at any moment)
                          │
                          ▼
                   cdc_bridge.sv
       (crosses from ACLK's clock domain into
        QCLK's — uses pulse_sync.sv internally)
                          │
                          ▼
                   qspi_engine.sv
         (drives the real io0-io3 pins directly)

  qspi_axi_pkg.sv: shared constants (register
  offsets, bit positions) imported by several
  of the modules above — not part of the flow
  itself, just a shared definitions file.
```

---

## Theory

### RISC-V, and the "types of instruction sets"

RISC-V is an open instruction set architecture — the actual vocabulary
of instructions a CPU understands, openly published with no licensing
fees, which is why free cores like PicoRV32 exist at all.

RISC-V is deliberately modular. There's a small mandatory **base**
integer set, plus optional **extensions** a specific chip may or may
not include:

| Extension | Adds |
|---|---|
| **I** (base, mandatory) | Integer arithmetic, loads/stores, branches — the minimum needed to run real software |
| **M** | Hardware multiply/divide |
| **A** | Atomic memory operations (for multi-core synchronization) |
| **F** / **D** | Single/double-precision floating point |
| **C** | Compressed 16-bit instruction encodings (smaller code size) |

**This project uses RV32I only** — the plain base set, nothing else.
PicoRV32 is explicitly configured with every extension disabled
(`ENABLE_MUL=0`, `ENABLE_DIV=0`, `COMPRESSED_ISA=0`). This means, for
example, there's no hardware multiply instruction available at all —
which is exactly why the current program only ever adds and subtracts.

### AXI4-Lite

The on-chip bus protocol connecting the CPU to every peripheral. A
simplified version of ARM's AXI4 standard, using five independent
channels for any single transaction:

- **AW** — write address
- **W** — write data
- **B** — write response (did it succeed?)
- **AR** — read address
- **R** — read data + response

Every peripheral in this design — flash controller, RAM, LEDs, display
— speaks this exact same protocol, which is what makes uniform routing
possible in the first place.

### QSPI

Serial Peripheral Interface using **4 data lines simultaneously**
(Quad SPI) instead of the usual 1, for roughly 4x the transfer rate at
the same clock speed. The flash chip on this board communicates over
QSPI once configured correctly (see the QE-bit discussion in the bug
list below — quad mode isn't available by default).

### XIP (execute-in-place)

The core technique this whole project demonstrates: fetching CPU
instructions **directly from flash**, live, one at a time, rather than
copying the program into RAM first. A dedicated address range
(`0x0100_0000`–`0x01FF_FFFF`) is reserved specifically for this — any
read in that range is silently redirected into a real QSPI flash
transaction instead of touching any actual memory.

### PicoRV32 — what the core can actually do

This project uses only a small slice of PicoRV32's real capabilities.
Source: [github.com/YosysHQ/picorv32](https://github.com/YosysHQ/picorv32).

PicoRV32 is explicitly designed as a **size-optimized** CPU — small
footprint, high achievable clock frequency, meant to be dropped into
FPGA or ASIC designs as an auxiliary processor rather than a
high-performance main CPU. It trades raw speed for size: average
throughput is roughly 4-5 clock cycles per instruction, not 1.

**ISA configurability** — depending on which parameters are enabled, the
exact same core can be built as RV32E (a reduced 16-register variant for
extremely small designs), RV32I (what this project uses), RV32IC
(adding compressed 16-bit instructions), RV32IM (adding hardware
multiply/divide), or the full RV32IMC.

**Three separate bus interface variants** — the same core logic can be
wrapped with different external interfaces depending on what it needs
to talk to:
- **Native memory interface** — the simplest option, for small,
  self-contained systems
- **`picorv32_axi`** — an AXI4-Lite master interface (what this project
  uses)
- **`picorv32_wb`** — a Wishbone master interface, a different, simpler
  open bus standard

**IRQ (interrupt) support** — lets the CPU react to external events
without needing to poll for them, implement fault handlers, or even
emulate instructions from a larger instruction set entirely in
software. Fully disabled in this project (`ENABLE_IRQ=0`).

**PCPI (Pico Co-Processor Interface)** — a genuinely distinctive
feature: lets you implement entirely custom, non-branching instructions
via an external co-processor module, effectively extending the
instruction set with your own hardware. Not used here, but this is
exactly the mechanism PicoRV32's own optional hardware multiply/divide
units are built on top of internally.

**Built-in fault detection** — `CATCH_MISALIGN` and `CATCH_ILLINSN`
(both enabled by default) are what actually produce the `trap` signal
this project's bring-up relied on heavily as a diagnostic — PicoRV32
halting itself cleanly the moment it's fed a genuinely invalid
instruction, rather than doing something unpredictable.

**Execution trace and cycle counters** — optional built-in debug/
profiling output (`ENABLE_TRACE`, `ENABLE_COUNTERS`), not used in this
project.

**Configurable performance/area tradeoffs** — parameters like
`BARREL_SHIFTER`, `TWO_CYCLE_ALU`, and `TWO_CYCLE_COMPARE` let the same
core be tuned toward either smaller area or faster execution, depending
on what a specific design needs.

### `STARTUPE2`

A Xilinx-specific hardware primitive, required because of a real
physical constraint on this board: the flash chip's clock pin isn't
wired to an ordinary FPGA I/O pin at all — it's wired to the FPGA's own
**dedicated configuration clock** pin, the same one used to load the
bitstream at power-on. `STARTUPE2` is the only way to reach that pin
after configuration has finished, and this project uses it specifically
to drive the flash chip's clock during normal operation.

---

## File-by-file breakdown

### `basys3_top.sv`
The only file with real physical pins (`clk`, `btn_reset`, `led`,
`seg`/`dp`/`an`, `cs_n`, `io0`-`io3`). Contains the clock divider
(`clk_div2`/`qclk` — halves the 100MHz system clock to 50MHz for the
QSPI/flash side), the reset sequencing logic (`resetn` from the button,
`resetn_main` which additionally waits for `qe_provision` to finish),
and instantiates every other module.

### `qe_provision.sv`
**Ports**: `clk`, `resetn`, `done` (output — gates the rest of the
system), `sr_readback`/`jedec_id` (diagnostic outputs, real chip
responses), plus the raw QSPI pins it controls directly.
**Key internals**: a state machine (`state`, values `S_IDLE` through
`S_DONE`) stepping through `WREN` → `WRSR` → `RDSR` → `RDID` in
sequence, a `shift_reg` used to serialize each outgoing command bit by
bit, and `bit_cnt`/`gap_cnt` tracking progress through each command.

### `system_router.sv`
**Key internals**: a `decode()` function that takes an address and
returns which of four destinations (`DEST_QSPI`, `DEST_LED`,
`DEST_RAM`, `DEST_SEG`) it belongs to, plus `DEST_INVALID` for anything
else (which gets an error response, not silent garbage). Separate
latched `write_target`/`read_target` registers track, per in-flight
transaction, which destination's response should actually be forwarded
back to the CPU.

### `sram.sv`
A plain 8KB memory array (`DEPTH_WORDS` parameter, default 2048 × 32-bit
words), split into 4 separate byte-wide arrays internally — a specific
coding style required for Xilinx's tools to correctly recognize it as
real Block RAM rather than accidentally building it out of thousands of
individual flip-flops.

### `led_peripheral.sv`
The simplest peripheral in the design: one `led_reg` register, written
by an ordinary AXI write, wired directly to the physical LED output.

### `seven_seg.sv`
**Key internals**: `display_reg` (the value to show), a `refresh_cnt`
counter driving `active_digit` (cycles 0-3, selecting which of the 4
digits is currently lit), and a hex-to-segment lookup (`case` statement
mapping each 4-bit value 0-F to the correct pattern of lit segments).
Both the digit-select and segment signals are active-low on this board
specifically (confirmed against Digilent's own documentation).

### `qspi_axi_pkg.sv`
Not a module — a shared package. Defines register offsets
(`REG_CTRL_CMD`, `REG_ADDR`, `REG_NUM_BYTES`, `REG_STATUS`,
`REG_TX_DATA`, etc.) as named constants, imported by several of the
files below so none of them have to hardcode raw addresses.

### `pulse_sync.sv`
A single-bit clock-domain-crossing primitive. Safely passes a one-cycle
pulse from a source clock domain to a destination clock domain, used
internally by `cdc_bridge.sv`.

### `cdc_bridge.sv`
Since the CPU/AXI side runs on `ACLK` and the QSPI engine runs on its
own, independent `QCLK`, every signal crossing between them needs
careful handling — this module does that crossing, using `pulse_sync.sv`
for control pulses and standard synchronizer logic for level signals.

### `qspi_engine.sv`
The actual QSPI shift engine. Walks a transaction through command,
address, dummy, and data phases, driving and sampling the real `io0`-
`io3` pins directly. Has no concept of AXI at all — it only knows about
a simple control/status interface, already crossed into its own clock
domain by `cdc_bridge.sv`.

### `qspi_arbiter.sv`
Two different things can want to use the QSPI engine at once — an
ordinary register-based request, or an XIP fetch. This module decides
who actually gets it at any given moment, and makes sure each side only
ever sees its own completion.

### `axi4L_slave.sv`
The register-based AXI4-Lite interface — control/status/data registers
a CPU can read and write directly for ordinary (non-XIP) flash access.

### `qspi_xip_slave.sv`
The memory-mapped, read-only interface. Any AXI read landing in the XIP
address range transparently becomes a real QSPI flash read, with no
register writes or polling involved from the requester's side.

### `qspi_unified_slave.sv`
Merges `axi4L_slave.sv`'s register interface and `qspi_xip_slave.sv`'s
XIP interface into one single external AXI4-Lite port — built
specifically because PicoRV32 only has one bus master port to offer,
not separate instruction/data buses.

### `qspi_axi_top.sv`
The top-level wrapper tying all 8 files above together — this is the
one module `basys3_top.sv` actually instantiates directly.

### `picorv32.v`
The real, unmodified PicoRV32 core source (external, not written for
this project — see the Theory section above for its full capabilities).
`basys3_top.sv` specifically instantiates the `picorv32_axi` variant
from within this file.

### `led_chase.S`
The actual program. Uses registers `t1` (LED peripheral address),
`t5` (seven-segment address), `t0`/`t4` (the growing LED bit-pattern),
`t6` (the independent hex counter). Structure:
- `_start` — one-time setup (load addresses, zero the counter)
- `restart_pattern` — resets just the LED pattern (not the counter) each time all 16 LEDs fill up
- `fill_loop` — the main loop: add the next LED bit, write LEDs, increment the counter, write the display, delay, repeat
- `delay` — a plain decrement-and-branch busy-wait; the single constant here controls the entire step rate

---

## Flow diagram (files + functions)

```
 POWER ON
    │
    ▼
 [Xilinx config logic] reads .bit from flash @ 0x000000
    │  (basys3_top.sv now physically exists as a circuit)
    ▼
 qe_provision.sv :: state machine
    S_IDLE → WREN → WRSR → RDSR → RDID → S_DONE
    │  (sets done=1)
    ▼
 basys3_top.sv :: resetn_main releases
    │  (PicoRV32, system_router, all peripherals start)
    ▼
 PicoRV32 :: fetch @ PROGADDR_RESET (0x0130_0000)
    │
    ▼
 qspi_axi_top.sv (qspi_xip_slave) :: address → flash offset 0x300000
    │  (real QSPI read transaction fires)
    ▼
 led_chase.S :: _start → restart_pattern → fill_loop
    │
    ├─► sw t0, LED_ADDR ──► system_router.decode() ──► led_peripheral.sv ──► LEDs
    │
    └─► sw t6, SEG_ADDR  ──► system_router.decode() ──► seven_seg.sv ──► display
    │
    ▼
 delay loop ──► slli/blt (next LED bit, or restart_pattern) ──► [back to fill_loop]
```

---

## Bugs found and fixed

Real issues found and resolved during this project, in roughly the
order encountered:

- **Stale synthesis results** — Vivado silently reused an old
  synthesized netlist across multiple RTL changes; every test appeared
  to fail identically regardless of what was actually changed, until a
  full `Reset Run` forced genuine resynthesis.
- **LED pin typo** — one LED constraint pointed at the wrong physical
  pin; found by checking against Digilent's actual official constraints
  file rather than a secondary source.
- **Bidirectional pin conflict** — two separate logical ports
  (`io0_out`/`io0_in`) were mistakenly constrained to the same physical
  pin; Vivado does not merge these automatically. Fixed with a real
  `inout` port and explicit tristate logic.
- **Boot mode jumper** — the board defaults to JTAG boot mode; nothing
  loads from flash at all until this physical jumper is moved to QSPI
  mode.
- **SPI bus-width mismatch** — the bitstream itself specifies 4-bit
  (quad) configuration mode; attempting to *write* the flash using
  single-line mode was rejected outright.
- **QE bit not set by default** — quad-mode flash access silently
  returns garbage until the chip's Quad Enable bit is explicitly set;
  not handled automatically by Vivado's flash-programming flow as
  general documentation suggested.
- **Clock-domain bug — the actual root cause of extended debugging**:
  `qe_provision` was accidentally clocked from the 100MHz system clock
  instead of the 50MHz clock genuinely reaching the physical flash pin.
  This silently scrambled every command it sent, despite the command
  sequence itself being correct — invisible to code review alone,
  since the logic really was correct, just running on the wrong clock.
- **RISC-V register naming mistake** — early assembly code referenced
  `t7`/`t8`/`t9`, which don't exist in RISC-V (`t0`-`t6` is the full
  range); caught immediately by the assembler.
- **Simulation model gaps** — the behavioral flash model used for
  simulation had never been built to handle the specific commands
  `qe_provision` needed (`WREN`/`WRSR`/etc.), since nothing had used
  them before; extended to handle them without corrupting other tests.

---

## Vivado project setup — which file goes where

Vivado separates sources into three distinct categories. Getting a file
into the wrong one is a common, confusing mistake — here's the complete,
correct placement for every file in this project.

### Design Sources (synthesizable RTL — becomes real hardware)

```
qspi_axi_pkg.sv
pulse_sync.sv
cdc_bridge.sv
axi4L_slave.sv
qspi_engine.sv
qspi_arbiter.sv
qspi_xip_slave.sv
qspi_unified_slave.sv
qspi_axi_top.sv
led_peripheral.sv
sram.sv
seven_seg.sv
system_router.sv
qe_provision.sv
basys3_top.sv        ← set as Top Module
picorv32.v            (real, external PicoRV32 source)
```

### Constraints

```
basys3_top.xdc
```

### Simulation Sources (never synthesized — testbench only)

```
qspi_flash_model.sv
tb_basys3_top.sv      ← set as simulation Top Module
led_chase_*.mem        (whichever program the testbench currently
                         references via its $readmemh call)
```

### Not part of the Vivado project at all

```
led_chase.bin
```
This never gets added to any Vivado source category — it's used
entirely outside the project, fed directly into the memory
configuration file generation step below (as the "Datafile" at
address `0x300000`).

---

## Generating the memory configuration file

The `.bit` file (FPGA configuration) and the compiled program (`.bin`)
are two separate files that need to be merged into one, with each
placed at its correct address in the flash chip's memory map, before
either can be written to the physical flash.

Vivado's **Tools → Generate Memory Configuration File** does this:

- **Format**: `MCS`
- **Load bitstream files**, start address `00000000` → the project's
  `.bit` file (from `<project>.runs/impl_1/`)
- **Load data files**, start address `00300000` → the compiled program
  (`led_chase.bin`)
- **Interface**: `SPIx4` — must match `CONFIG_MODE SPIx4` in the XDC
  file, or generation fails with a bus-width mismatch error

This produces a single combined `.mcs` file containing both pieces at
their correct offsets.

<img width="1848" height="1401" alt="Screenshot 2026-08-21 200021" src="https://github.com/user-attachments/assets/4375868c-d7e7-4e9f-aeb3-811e878b51de" />


## Uploading to the board

With the board connected and powered on:

1. **Hardware Manager → Open Target → Auto Connect**
2. **Right-click the connected device → Program Configuration Memory
   Device**
3. Point "Configuration file" at the `.mcs` file generated above
4. Confirm **Erase**, **Program**, and **Verify** are checked
5. Click OK and wait for programming to complete (this writes to the
   physical flash chip, noticeably slower than a direct FPGA load — a
   few minutes, not seconds)
6. **Power-cycle the board** (required — this is what triggers the FPGA
   to actually reconfigure itself from flash, not just leave the
   previous session running)
7. Confirm the **DONE** LED lights, confirming successful
   reconfiguration from flash

<img width="2128" height="1492" alt="Screenshot 2026-08-21 200147" src="https://github.com/user-attachments/assets/45bc6cd0-86a0-4121-92cd-9d82f6094ae9" />


## Demonstration video



https://github.com/user-attachments/assets/15a157cc-c874-452b-96f8-4964fe701dfb



---

## Testing and future scope

### How this was tested

Verified in two stages: first in simulation (a full-system testbench
exercising the complete boot sequence, XIP fetch, and peripheral
writes against a behavioral flash model), then confirmed directly on
the physical board — reading the flash chip's real manufacturer ID
back (`0xC2`, genuine Macronix), confirming the QE bit was genuinely
set via direct register readback, confirming the CPU never crashed on
its first real instruction fetch, and visually confirming correct,
continuous LED and seven-segment behavior.

### Future scope

- **Real input** — currently the CPU can only write to peripherals, never
  read from anything external. Adding a button/switch input peripheral
  would let the program actually react to the outside world, opening
  the door to interactive behavior (a simple calculator using the
  buttons/switches has been discussed as a concrete next demo).
- **Hardware multiply/divide** — enabling PicoRV32's `M` extension would
  allow real arithmetic beyond add/subtract without needing slower
  software workarounds.
- **Decimal display mode** — a BCD-based decimal counter (rather than
  the current hexadecimal one) has already been built and verified in
  simulation, available as a drop-in alternative if wanted later.
- **UART** — using the board's built-in USB-UART bridge to send/receive
  real text to a PC terminal.
- **Larger programs** — the current program is tiny by design; nothing
  about the architecture limits program size beyond the flash chip's own
  capacity.
