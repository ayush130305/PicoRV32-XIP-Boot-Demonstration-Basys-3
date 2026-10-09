# PICO RV32 - XIP - QSPI - AXI

Design Verification Document

This package contains two verification targets built from the same design:

- **Level A, the core IP (`qspi_axi_top`)**: an AXI4-Lite slave that gives a master both a register interface and a memory-mapped, read-only execute-in-place (XIP) window onto a QSPI flash. It was built and verified first, on its own.
- **Level B, the system (`basys3_top`)**: that core integrated with a PicoRV32 RV32I CPU, an address router, an 8 KB RAM, LED and seven-segment registers, and flash Quad-Enable provisioning logic, targeting the Digilent Basys 3 (Artix-7 XC7A35T, Macronix MX25L3233F flash).

The design is synthesizable SystemVerilog around the third-party PicoRV32 core. This document is the handoff to Design Verification (DV) and treats the design as a black box. It covers both levels so that the full suite can be tested.

## Scope

| Level | DUT | Master | Slave side | Existing tests |
|---|---|---|---|---|
| A | `qspi_axi_top` | AXI4-Lite master (testbench) | QSPI flash pins | 18 register-path, 11 XIP |
| B | `basys3_top` | `picorv32_axi` (real CPU) | flash pins, LEDs, display | 14 system, 7 RAM |

Level A is the primary target. Level B is the integration check that the same core works behind a real CPU and a router.

## Features

Core (Level A):

- One external AXI4-Lite slave port covering both registers and the XIP window; address-steered reads, register-only writes
- Register interface to run arbitrary QSPI transactions: opcode, 24- or 32-bit address, single/dual/quad lines on address and data, 0-255 dummy cycles, read or write, up to 4095 bytes
- Memory-mapped XIP: an ordinary AXI read inside the window becomes a flash read using one fixed, pre-programmed configuration (XIP_CFG)
- Register path and XIP path share one flash interface; the register path wins a simultaneous request and a running transaction is never preempted
- ABORT strobe that cancels any phase of any transaction, and a timeout safety net that raises ERROR
- Sticky, write-1-to-clear DONE and ERROR status; read- and write-cleared TX_READY and RX_READY
- Two clock domains, `ACLK` (AXI side) and `qclk` (QSPI side)
- Explicit DECERR on reads that hit neither a register nor the XIP window

System (Level B):

- Single AXI4-Lite master (`picorv32_axi`, minimal RV32I) and a five-way address router with DECERR on unmapped addresses
- Boots and runs from flash with no copy to RAM (XIP_CFG_RESET = 0x8001086B)
- Provisioning logic that sets the flash Quad-Enable bit (WREN, WRSR, RDSR, RDID) and holds the CPU in reset until it is done
- 8 KB RAM, 16-bit LED register, 16-bit four-digit hexadecimal seven-segment register
- `clk` 100 MHz and `qclk` 50 MHz

---

# Part A: Core IP (qspi_axi_top)

## A1. Architecture overview

```
 AXI4-Lite master
        |
  one AXI4-Lite slave port        (ACLK domain)
     |            |
 register block   read-only XIP window
     |            |
     +--- shared QSPI controller ---+      (qclk domain)
              |
   cs_n, io0..io3 (out / oe / in)  ->  flash
```

Writes go to the register block. Reads are steered by address to the register block or the XIP window. Both use the same flash interface.

## A2. Core ports (qspi_axi_top)

| Port | Dir | Width | Description |
|---|---|---|---|
| ACLK | in | 1 | AXI clock |
| ARESETn | in | 1 | AXI-side reset, active low |
| qclk | in | 1 | QSPI-side clock |
| qclk_rst | in | 1 | QSPI-side reset, active high |
| S_AXI_AWADDR | in | 32 | Write address |
| S_AXI_AWVALID | in | 1 | Write address valid |
| S_AXI_AWREADY | out | 1 | Write address ready |
| S_AXI_WDATA | in | 32 | Write data |
| S_AXI_WSTRB | in | 4 | Write byte strobes |
| S_AXI_WVALID | in | 1 | Write data valid |
| S_AXI_WREADY | out | 1 | Write data ready |
| S_AXI_BRESP | out | 2 | Write response |
| S_AXI_BVALID | out | 1 | Write response valid |
| S_AXI_BREADY | in | 1 | Write response ready |
| S_AXI_ARADDR | in | 32 | Read address |
| S_AXI_ARVALID | in | 1 | Read address valid |
| S_AXI_ARREADY | out | 1 | Read address ready |
| S_AXI_RDATA | out | 32 | Read data |
| S_AXI_RRESP | out | 2 | Read response |
| S_AXI_RVALID | out | 1 | Read data valid |
| S_AXI_RREADY | in | 1 | Read data ready |
| cs_n | out | 1 | Flash chip select, active low |
| io0_out - io3_out | out | 4 | Flash data line output values |
| io0_oe - io3_oe | out | 4 | Flash data line output enables |
| io0_in - io3_in | in | 4 | Flash data line input values |

Flash SCLK is not a port of this core; the integrator derives it from `qclk`.

## A3. Core parameters

| Parameter | Default | Meaning |
|---|---|---|
| TIMEOUT_CYCLES | 20'hFFFFF | qclk cycles a transaction may stay busy before the engine forces an abort and raises ERROR |
| XIP_CFG_RESET | 32'h0 | Reset value of XIP_CFG. 0 keeps XIP disabled. The system overrides it to 0x8001086B |
| XIP_BASE | 0x0100_0000 | XIP window base |
| XIP_SIZE | 0x0100_0000 | XIP window size (16 MB) |

## A4. AXI4-Lite behaviour

**Write path.** Writes always go to the register block; the XIP window is read-only by design. AW and W are independent: the slave accepts either first or both together, and completes the register write on the cycle the second one arrives. BRESP is always OKAY. WSTRB is honoured per byte lane for every register.

**Read path.** Reads are routed on the live `S_AXI_ARADDR`:

| ARADDR | Target | Response |
|---|---|---|
| inside `[XIP_BASE, XIP_BASE + XIP_SIZE)` | XIP window | OKAY with data, or DECERR on a fetch error |
| `0x00` to `0x1B` (offsets up to XIP_CFG plus one word) | register block | OKAY |
| anything else | nobody (not forwarded) | DECERR on the next cycle, RDATA = 0 |

The target is latched at the AR handshake and controls the R channel, so a newer pending address cannot misroute an older response. Only the latched target sees RREADY.

**Register block read details.** A read of TX_DATA returns 0. A read of an address inside `0x00..0x1B` that is not a defined, aligned offset returns 0 with OKAY (see A6).

**XIP response codes.** OKAY on success. DECERR (`2'b10`) when XIP is disabled, when the address is outside the window, or when the engine reports an error or aborts. The AR handshake is always accepted; the error is reported on R, never by withholding ARREADY.

## A5. Register map

| Offset | Name | Access | Notes |
|---|---|---|---|
| 0x00 | CTRL_CMD | RW | Transaction control (below). Writing start (bit 21) or ABORT (bit 23) pulses a strobe for one ACLK cycle. ABORT is not stored |
| 0x04 | ADDR | RW | Flash address |
| 0x08 | NUM_BYTES | RW | Transfer length; engine uses bits [11:0] only |
| 0x0C | STATUS | RO plus W1C | Bits below |
| 0x10 | TX_DATA | WO | Next byte to transmit (low 8 bits); reads return 0 |
| 0x14 | RX_DATA | RO | Last received byte (low 8 bits) |
| 0x18 | XIP_CFG | RW | XIP configuration (below); reset value = XIP_CFG_RESET |

**CTRL_CMD** (writes are WSTRB-masked per byte):

| Bits | Field | Notes |
|---|---|---|
| 7:0 | opcode | Always sent on one line, 8 cycles |
| 9:8 | addr_lines | 0 single, 1 dual, 2 quad |
| 11:10 | data_lines | 0 single, 1 dual, 2 quad |
| 12 | addr_width | 0 = 24-bit, 1 = 32-bit |
| 20:13 | dummy_cycles | 0 skips the DUMMY phase |
| 21 | start | Strobe; ignored while the engine is busy |
| 22 | dir | 0 read, 1 write |
| 23 | ABORT | Strobe; cancels any phase immediately |

**STATUS:**

| Bit | Name | Behaviour |
|---|---|---|
| 0 | BUSY | Level; high while a transaction is in flight |
| 1 | DONE | Set on normal completion only. Cleared by a new start or by writing 1 to this bit. Set wins over clear when both land on the same cycle |
| 2 | TX_READY | Set when the engine asks for a byte; cleared by a write to TX_DATA |
| 3 | RX_READY | Set when a byte is valid; cleared by a read of RX_DATA |
| 4 | ERROR | Set on the rising edge of the engine's timeout error; cleared by a new start or by writing 1 to this bit |
| 31:5 | reserved | Read 0 |

**XIP_CFG:**

| Bits | Field |
|---|---|
| 31 | XIP_ENABLE (placed far from the other fields so it cannot overlap OPCODE) |
| 20:13 | DUMMY_CYCLES |
| 12 | ADDR_WIDTH |
| 11:10 | DATA_LINES |
| 9:8 | ADDR_LINES |
| 7:0 | OPCODE |

System reset value 0x8001086B decodes to: enabled, opcode 0x6B, 24-bit address on one line, data on four lines, 8 dummy cycles.

## A6. Design Behaviour

These are the current behaviours. They are not necessarily intended; confirm each with the design owner.

1. **Writes to the XIP window, to unmapped register offsets, and to any address the register block does not decode are accepted with BRESP OKAY and silently ignored.** Only reads get DECERR for invalid addresses. At system level a write inside the XIP window is routed to the QSPI core and behaves the same way; the router's DECERR applies only to addresses outside all five regions.
2. **Misaligned or in-between addresses inside `0x00..0x1B`** (for example `0x01`) match no register case: reads return 0 with OKAY, writes are ignored with OKAY. No alignment check exists anywhere.
3. **XIP reads are not alignment-checked.** `ARADDR = XIP_BASE + 1` fetches four bytes starting at flash address 1.
4. **NUM_BYTES above 4095 is truncated** to its low 12 bits. A value of exactly 4096 runs as 0 bytes.
5. **Writes to CTRL_CMD while a transaction is in flight** change the stored register but not the running transaction, because the engine latched its copy at start. A write that sets bit 21 while busy is ignored by the engine.
6. **ABORT during an XIP fetch** ends that fetch with a DECERR on R.
7. **The XIP window returns DECERR for controller errors**, not SLVERR.
8. **A transaction that times out leaves ERROR set** in the engine until the next accepted start; the register-path STATUS.ERROR is sticky on top of that.
9. **The existing test `numbytes_256_truncation` can never fail:** its check expression ends in `|| 1`. The 256-byte regression is therefore not actually protected by that test.

## A7. Existing core tests

All tests are directed and self-checking, and all pass.

**Register-path suite (18)**

| # | Test | What it checks |
|---|---|---|
| 1 | read_quad_1byte | 1-byte read, quad data lines |
| 2 | read_single_1byte | 1-byte read, single data line |
| 3 | read_dual_1byte | 1-byte read, dual data lines |
| 4 | write_single_1byte | 1-byte write, single data line |
| 5 | write_quad_1byte | 1-byte write, quad data lines |
| 6 | read_quad_3byte_lastbyte | 3-byte read; last byte retrievable |
| 7 | read_32bit_addr | 32-bit address mode |
| 8 | read_dummy_zero | Zero dummy cycles; DUMMY phase skipped |
| 9 | numbytes_256_truncation | 256-byte transfer (see A6 item 9) |
| 10 | back_to_back_txns | Two transactions in a row |
| 11 | start_while_busy_ignored | Start during a running transaction is a no-op |
| 12 | sticky_done_bit | DONE stays set until cleared by writing 1 |
| 13 | tx_rx_ready_visibility | TX_READY and RX_READY set and clear rules |
| 14 | dual_line_address_phase | Address on dual lines |
| 15 | quad_line_address_phase | Address on quad lines |
| 16 | abort_midtransaction | ABORT stops a running transaction |
| 17 | timeout_safety_net | Timeout sets ERROR and ends the transaction |
| 18 | mixed_quad_addr_single_data | Quad address with single-line data |

**XIP and shared-port suite (11)**

| # | Test | What it checks |
|---|---|---|
| 1 | xip_disabled_reject | Fetch with XIP disabled returns DECERR |
| 2 | xip_baseline_fetch | Normal fetch returns the expected word |
| 3 | xip_out_of_range | Address outside the window returns DECERR |
| 4 | shared_port_register_then_xip_read | Register access then XIP read on the one port |
| 5 | abort_cuts_short_xip_transaction | ABORT during an XIP fetch |
| 6 | xip_timeout_reports_error | Stalled fetch times out with DECERR |
| 7 | register_path_recovers_after_xip_timeout | Register path works again after an XIP timeout |
| 8 | xip_cfg_write_mid_flight_does_not_corrupt | XIP_CFG write during a fetch |
| 9 | xip_dual_line_data_fetch | Fetch with dual data lines |
| 10 | xip_quad_line_data_fetch | Fetch with quad data lines |
| 11 | xip_back_to_back_fetches | Consecutive fetches |

---

# Part B: System (basys3_top)

## B1. Boot stages

1. Power-up: FPGA configures from flash (bitstream at 0x000000).
2. The provisioning logic issues WREN (0x06), WRSR (0x01), RDSR (0x05) and RDID (0x9F) to set and check QE.
3. When provisioning is done the CPU is released from reset.
4. PicoRV32 fetches from PROGADDR_RESET = 0x0130_0000 (XIP window + 0x300000).
5. The program drives the LED register and the seven-segment register.

## B2. Architecture overview

The CPU (`picorv32_axi`, core plus AXI adapter) is the only AXI4-Lite master. An address router forwards its accesses to one of: the QSPI core (register bank and XIP window through its single port), the LED register, the seven-segment register or the RAM. Addresses outside all five regions get DECERR from the router and are never forwarded. The QSPI core is Level A, unchanged.

The provisioning logic shares the physical flash pins with the core and has exclusive control of them until it is done. The AXI side runs on `clk`; the QSPI controller, the provisioning logic and the flash SCLK run on `qclk`.

## B3. Address map

| Range | Slave |
|---|---|
| 0x0000_0000 - 0x0000_001B | QSPI register bank |
| 0x0100_0000 - 0x01FF_FFFF | QSPI XIP window (read-only) |
| 0x0200_0000 - 0x0200_0003 | LED register (16 bits) |
| 0x0300_0000 - 0x0300_0003 | Seven-segment register (16 bits, four hex digits) |
| 0x1000_0000 - 0x1000_1FFF | 8 KB RAM |
| anything else | DECERR |

LED register: 16 bits, WSTRB[1:0] write the two bytes, WSTRB[3:2] ignored. Seven-segment register: 16 bits, WSTRB[1:0] only; MSB nibble on `an[3]`; active-low anodes and segments; own refresh divider of 2^15 clk cycles per digit (about 328 us).

## B4. Top-level ports (basys3_top)

| Port | Dir | Width | Description |
|---|---|---|---|
| clk | in | 1 | 100 MHz board oscillator |
| btn_reset | in | 1 | BTNC, active high; inverted internally to resetn |
| cs_n | out | 1 | Flash chip select |
| io0 - io3 | inout | 4 | Flash data lines (tristate at the pad) |
| led | out | 16 | Onboard LEDs |
| seg | out | 7 | Seven-segment cathodes, active low |
| dp | out | 1 | Decimal point (off) |
| an | out | 4 | Digit anodes, active low, one-hot |

Flash SCLK is not a top-level port; it is driven through the device's dedicated configuration clock.

## B5. System parameters

| Parameter | Default | Meaning |
|---|---|---|
| QSPI_XIP_BASE | 0x0100_0000 | XIP window base |
| QSPI_XIP_SIZE | 0x0100_0000 | XIP window size |
| QSPI_TIMEOUT_CYCLES | 0xFFFFF | Engine timeout before STATUS.ERROR |
| RAM_BASE_ADDR | 0x1000_0000 | RAM base |
| RAM_DEPTH_WORDS | 2048 | 8 KB |
| USER_PROGRAM_FLASH_OFFSET | 0x0030_0000 | Program offset in flash; simulation overrides to 0 |

## B6. Design goals

- Run code from flash with no copy to RAM
- Keep the AXI4-Lite fabric minimal and fully decoded, with explicit error responses
- Make flash bring-up self-contained (no external programmer step to set QE)
- Provide a reproducible simulation flow with no vendor-tool dependency

## B7. Supported configuration

- CPU: RV32I, no compressed, no multiply/divide, no interrupts
- Flash: MX25L3233F, 4 MB, JEDEC ID 0xC2, single-line command and address, quad data
- Flash layout: bitstream at 0x000000, program at 0x300000
- Other flash devices are not characterized

## B8. Challenges

- A flash with QE unset ignores quad reads, so the CPU must not start before provisioning is done
- The provisioning logic must run on `qclk`; running it on `clk` was a past regression
- Safe crossing between the 100 MHz AXI domain and the 50 MHz engine
- Flash command set and timing are only modelled, not exhaustively, in simulation

---

# Integration and Simulation

**Reset and clocks.** Level A has two independent resets: `ARESETn` (active low) and `qclk_rst` (active high). Both should be applied together. Level B holds the CPU in reset until flash provisioning is done.

**Access contract.** The XIP window is read-only. Writes to it, and to unmapped register offsets, return OKAY and are ignored (A6 item 1). Reads that hit neither a register nor the window return DECERR. At system level, addresses outside all five regions return DECERR for both reads and writes. STATUS DONE and ERROR are sticky and cleared by writing 1.

**Simulation.** Icarus Verilog 12 with `-g2012`. The Xilinx STARTUPE2 primitive is replaced by a stub model in simulation. Existing results:

```
system test:        14 pass, 0 fail
register-path test: 18 pass, 0 fail
XIP test:           11 pass, 0 fail
RAM test:            7 pass, 0 fail
```

---

# Verification

## Known regressions

| Bug | Symptom |
|---|---|
| Provisioning logic on wrong clock | JEDEC ID read 0x00, QE never set, first XIP fetch returned garbage and CPU trapped |
| RX nibble loss | Received data dropped a nibble at a timing boundary |
| TX byte 0 lost | First transmitted byte missing |
| Line masking | Wrong data lines driven or sampled in single and dual modes |
| NUM_BYTES = 256 truncated | 256-byte transfer ran as 0 |
| STATUS not sticky | DONE and ERROR lost before software read them |
| Stale error carried into a new XIP request | New fetch reported the previous transaction's error |
| Final byte lost when busy dropped early | Last rx_valid pulse discarded or misrouted |
| Fast error path re-accepted lingering ARVALID | Phantom second XIP request |
| Invalid address on the shared port returned 0 with OKAY | Garbage data with no error |

## Project status

**Hardware-validated.** The design, directed testbenches, board image and documentation are present. On the Basys 3 the JEDEC ID reads 0xC2, QE sets, the CPU runs without trapping, and LEDs and display behave correctly. All four testbenches pass.

Not yet covered, for DV to address:

- Verification beyond the directed checks in A7 (verification plan, assertions and environment are left to DV)
- The seven-segment register, router DECERR path, LED register and the provisioning failure path have no dedicated tests
- The system test checks `led[13:0]` only
- Flash model fidelity for WREN, WRSR, RDSR, RDID and dual mode is undocumented
- No utilization or timing report exists for the final build (earlier pre-seven-segment build: 1397 LUT, 1105 FF, 2 BRAM tiles)
- The reason the flash clock is inverted relative to `qclk` is to be confirmed with the design owner
- The behaviours in A6 need an owner decision: intended or to be changed

## Future roadmap

- Directed tests for the uncovered blocks above
- Randomized and formal verification of address decode, arbitration and clock crossing
- Timing and utilization characterization of the final build
- Automated simulation and lint flow
- Possible features: burst or continuous-read XIP (needs a mode-bits phase in the QSPI controller), error responses for writes to the XIP window
