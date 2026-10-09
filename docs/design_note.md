# Design note: PicoRV32 XIP boot on Basys 3

Each entry is a decision, the reason, and where it lives. Items marked (confirm) are things the
RTL shows but whose original rationale should be confirmed by the author.

## System structure

**D1. One AXI4-Lite master, one router.** `picorv32_axi` exposes a single AXI4-Lite master port.
`system_router` decodes the address and fans out to the QSPI core, LED, seven-segment and RAM.
This keeps the CPU side simple and lets every peripheral share one slave port definition.

**D2. The QSPI core presents one slave port for registers and XIP.** `qspi_axi_top` routes
internally (`qspi_unified_slave`, defined in `axi_xip_slave.sv`): writes always go to the register
path, reads are steered by address. A single-master CPU therefore connects with no external decoder.
The core IP itself is unchanged by this integration.

**D3. Unmapped addresses get a DECERR from the router and are never forwarded.** A stray CPU access
cannot hang a peripheral waiting for a handshake that never comes.

**D4. Address map.** Registers at 0, XIP window at `0x0100_0000` (16 MB), LED at `0x0200_0000`,
seven-segment at `0x0300_0000`, RAM at `0x1000_0000` (8 KB). Each peripheral takes one word.
Parameters in `basys3_top.sv` and `system_router.sv` must agree.

## Flash and boot

**D5. Flash layout.** The FPGA bitstream sits at flash offset 0. An uncompressed XC7A35T bitstream is about 2.09 MB; the shipped one occupies `0x000000-0x06781F` (see `emu/flash/basys3_full_flash.prm`). The offset was chosen against the larger figure.
The user program sits at `0x300000`, past the bitstream with margin. The CPU reset vector is
`XIP_BASE + USER_PROGRAM_FLASH_OFFSET = 0x0130_0000`, because flash address = AXI address - XIP_BASE.
The offset is a parameter so simulation can set it to 0 and use a tiny flash model.
(An earlier version set the reset vector to `XIP_BASE` alone, which sent the first fetch into the bitstream.)

**D6. XIP uses a fixed configuration set at reset.** An instruction fetch cannot program a register
first, so `XIP_CFG_RESET = 0x8001_086B` is applied at reset: enabled, opcode `0x6B` (quad output
fast read), 24-bit address on one line, data on four lines, 8 dummy cycles.

**D7. QE provisioning is a separate bit-banged module.** The MX25L3233F ships with the Quad Enable
bit clear. Setting it needs `WREN` (opcode only, no address) and `WRSR` (opcode plus two data bytes,
no address). The engine's fixed CMD, ADDR, DUMMY, DATA phase structure cannot express either, and
the core architecture was deliberately not restructured. `qe_provision` drives the pins directly in
single-line mode, then reads back status (`RDSR`) and the JEDEC ID (`RDID`, expect `0xC2`).

**D8. Provisioning gates the reset of everything else.** `resetn_main = resetn & qe_done`. The CPU
cannot fetch before the flash is in quad mode. `qe_provision` itself runs under `resetn` alone.

**D9. Flash SCLK goes through STARTUPE2.** On Basys 3 the flash clock pin is the dedicated
configuration clock pin and is not reachable as an ordinary I/O after configuration. `USRCCLKO`
is driven with `~qclk`. (confirm: reason for the inversion; it was added during bring-up.)

## Clocks and resets

**D10. qclk = clk / 2 (50 MHz).** The engine and `qe_provision` run on qclk; the CPU, router,
peripherals and the AXI side of the QSPI core run on the 100 MHz clk. The flash clock is kept at
half rate because STARTUPE2-routed CCLK has frequency limits (see the comment in `basys3_top.sv`).
The two clocks come from one source, but the core's `cdc_bridge`/`pulse_sync` still treat the
crossing as asynchronous. That is deliberate reuse of the unchanged IP.

**D11. `qe_provision` must run on qclk.** It was first wired to clk, so its internal state machine
advanced two bit positions per real SCLK edge. Every command was logically correct and physically
scrambled: the JEDEC ID read 0x00, QE never set, and the first XIP fetch trapped. Clocking it from
qclk fixed all three at once.

**D12. Button reset is inverted inside the top level.** BTNC reads high when pressed; the design
uses active-low `resetn`. The XDC cannot invert it.

## CPU configuration

**D13. Minimal RV32I.** `COMPRESSED_ISA=0`, `ENABLE_MUL=0`, `ENABLE_DIV=0`, `ENABLE_IRQ=0`,
`ENABLE_TRACE=0`, `ENABLE_COUNTERS=0`, `BARREL_SHIFTER=0`. Fewer ports to wire and less area.
Software must stay inside plain `rv32i` or the instruction will not execute on this build.

**D14. The demo program uses no stack.** It is the first program run on the integration, so it is
kept simple enough to reason about with total confidence. `STACKADDR` is still set to the top of RAM
(`0x1000_1FFC`).

## Peripherals

**D15. LED peripheral:** one 16-bit register, `WSTRB[1:0]` write the two bytes, `WSTRB[3:2]` are
ignored, read-back returns the register, response is always OKAY.

**D16. Seven-segment peripheral:** one 16-bit register shown as four hex digits, MSB on `an[3]`.
Anodes and segments are active-low; this was checked against Digilent's reference manual rather than
assumed from the generic common-anode convention. The module owns its refresh (divider of 2^15 clk
cycles, about 328 us per digit), so software writes once and the display holds.

**D17. The counter is independent of the LED pattern and never resets when the LEDs wrap.** It reads
as a real running count instead of a mirror of the LED bits. It is hexadecimal; a BCD variant was
built and simulated earlier but is not part of this design.

**D18. RAM uses one write process per byte lane.** A first version mixed per-byte writes with
protocol state in one `always_ff`, which defeated block-RAM inference (28,720 LUTs and 67,770
flip-flops for 8 KB). Separate minimal processes per lane infer block RAM correctly.

## Core IP behaviour that DV should know

**D19. STATUS bits are sticky.** DONE and ERROR stay set until software writes 1 to them; TX_READY
clears on a TX_DATA write; RX_READY clears on an RX_DATA read.

**D20. ABORT is a strobe that cancels any phase.** A safety-net timeout (`TIMEOUT_CYCLES`) sets
ERROR if the engine stalls.

## Simulation choices

**D21. The system test gives the flash model its clock from `u_dut.qclk`.** SCLK leaves the design
through STARTUPE2, which a non-Vivado simulator cannot model, so the testbench references qclk
hierarchically and `startupe2_sim_model.sv` is only a stub.

**D22. Build artifacts stay out of the project.** The `.mcs` flash image is generated, not versioned.

## Known gaps

- Nothing tests `seven_seg`, the router's DECERR path, `led_peripheral`, or the `qe_provision` failure path.
- The system testbench checks `led[13:0]` only.
- Flash-model support for dual-line reads and for the provisioning commands is not documented.
