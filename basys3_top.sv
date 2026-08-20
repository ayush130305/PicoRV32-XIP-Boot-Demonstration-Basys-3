// basys3_top.sv
//
// Top-level integration for the Basys 3 hardware demonstration: PicoRV32
// executing instructions fetched directly from the onboard QSPI flash via
// XIP, driving the onboard LEDs to prove it.
//
// Architecture:
//   PicoRV32 (picorv32_axi) --[one AXI master port]--> system_router
//     system_router routes to:
//       - qspi_axi_top (our existing IP, COMPLETELY UNCHANGED - both the
//         register map and the XIP window live behind its single
//         S_AXI_* port, itself already routed internally by
//         qspi_unified_slave.sv)
//       - led_peripheral (new, minimal, for the observable demo output)
//
// IMPORTANT - verify before compiling: this instantiates picorv32_axi
// using only the ports directly confirmed from PicoRV32's own official
// testbench.v (clk, resetn, trap, and the full mem_axi_* set). Every
// optional feature (IRQ, trace, MUL, DIV, compressed ISA) is explicitly
// disabled below specifically to avoid needing ports (irq, eoi,
// trace_valid, trace_data) whose presence on picorv32_axi specifically
// (as opposed to other community wrapper variants) was not directly
// confirmed. Once picorv32.v is actually in hand, check its real
// module picorv32_axi (...) port declaration against this instantiation
// before attempting to compile - if it has additional ports beyond what's
// connected here, this file will need updating first.

module basys3_top #(
  parameter logic [31:0] QSPI_XIP_BASE = 32'h0100_0000,
  parameter logic [31:0] QSPI_XIP_SIZE = 32'h0100_0000,
  parameter int unsigned QSPI_TIMEOUT_CYCLES = 20'hFFFFF,
  parameter logic [31:0] RAM_BASE_ADDR = 32'h1000_0000,
  parameter int unsigned RAM_DEPTH_WORDS = 2048, // 8KB
  // Flash offset where the user program lives, relative to XIP_BASE.
  // Default 0x300000 is the REAL hardware value (past the ~2.09MB
  // bitstream). Exposed as a parameter specifically so simulation can
  // override it to something small - a 3MB+ flash model array made a
  // functional-simulation testbench impractically slow to initialize,
  // with no benefit: the address-translation arithmetic itself
  // (flash_addr = AXI_addr - XIP_BASE) is already separately, thoroughly
  // verified by the existing 11-test XIP suite. Real hardware always
  // uses the true default; only simulation should ever override this.
  parameter logic [31:0] USER_PROGRAM_FLASH_OFFSET = 32'h0030_0000
)(
  input  logic clk,      // Basys 3's 100MHz onboard oscillator
  input  logic btn_reset, // BTNC (center pushbutton) - reads HIGH when
    // pressed, the opposite polarity from the active-low `resetn` the
    // rest of this design uses throughout. Inverted internally below -
    // found and fixed during XDC constraint planning, not something to
    // leave for the constraints file to somehow handle (it can't).

  // QSPI flash physical pins - to the onboard MX25L3233F
  output logic cs_n,
  // Real, single bidirectional pins - see the tristate logic below.
  // qspi_axi_top itself keeps its existing out/oe/in three-signal
  // interface unchanged (matching every other use of that module in
  // this project); the conversion to genuine inout ports happens right
  // here, at the actual physical boundary, not left for the XDC file to
  // somehow merge two separate logical ports onto one pad - Vivado does
  // not do that automatically, confirmed by a real placement error
  // during XDC bring-up ("Cannot set LOC property... pad is already
  // occupied").
  inout wire io0, io1, io2, io3,

  // Onboard LEDs - the demonstration's observable output
  output logic [15:0] led
);

  // Internal wiring: qspi_axi_top's own QSPI pins - kept separate from
  // the actual physical pins, since qe_provision.sv needs exclusive
  // control of the physical pins during its brief one-time run, before
  // qspi_axi_top (and the rest of the design) ever starts.
  logic qspi_top_cs_n;
  logic qspi_top_io0_out, qspi_top_io0_oe, qspi_top_io0_in;
  logic qspi_top_io1_out, qspi_top_io1_oe, qspi_top_io1_in;
  logic qspi_top_io2_out, qspi_top_io2_oe, qspi_top_io2_in;
  logic qspi_top_io3_out, qspi_top_io3_oe, qspi_top_io3_in;

  // qe_provision's own pin outputs
  logic qe_cs_n;
  logic qe_io0_out, qe_io0_oe, qe_io0_in;
  logic qe_io1_in;
  logic qe_io1_out, qe_io1_oe;
  logic qe_io2_out, qe_io2_oe;
  logic qe_io3_out, qe_io3_oe;

  logic qe_done;

  // Physical pin mux: qe_provision has exclusive control until it
  // signals done, then control switches to qspi_axi_top's normal
  // output permanently (qe_provision's own state machine is already
  // parked in S_DONE by then, driving cs_n high / nothing meaningful,
  // so there's no contention risk in the switchover itself).
  assign cs_n     = qe_done ? qspi_top_cs_n   : qe_cs_n;
  assign io0_out  = qe_done ? qspi_top_io0_out : qe_io0_out;
  assign io0_oe   = qe_done ? qspi_top_io0_oe  : qe_io0_oe;
  assign io1_out  = qe_done ? qspi_top_io1_out : qe_io1_out;
  assign io1_oe   = qe_done ? qspi_top_io1_oe  : qe_io1_oe;
  assign io2_out  = qe_done ? qspi_top_io2_out : qe_io2_out;
  assign io2_oe   = qe_done ? qspi_top_io2_oe  : qe_io2_oe;
  assign io3_out  = qe_done ? qspi_top_io3_out : qe_io3_out;
  assign io3_oe   = qe_done ? qspi_top_io3_oe  : qe_io3_oe;

  logic io0_out, io0_oe, io0_in;
  logic io1_out, io1_oe, io1_in;
  logic io2_out, io2_oe, io2_in;
  logic io3_out, io3_oe, io3_in;

  assign io0 = io0_oe ? io0_out : 1'bz;
  assign io1 = io1_oe ? io1_out : 1'bz;
  assign io2 = io2_oe ? io2_out : 1'bz;
  assign io3 = io3_oe ? io3_out : 1'bz;
  assign io0_in = io0;
  assign io1_in = io1;
  assign io2_in = io2;
  assign io3_in = io3;
  assign qspi_top_io0_in = io0_in;
  assign qspi_top_io1_in = io1_in;
  assign qspi_top_io2_in = io2_in;
  assign qspi_top_io3_in = io3_in;
  assign qe_io0_in = io0_in;
  assign qe_io1_in = io1_in;

  localparam logic [31:0] RAM_TOP_ADDR = RAM_BASE_ADDR + (RAM_DEPTH_WORDS * 4) - 4;

  // Flash memory map: the FPGA's own configuration bitstream occupies
  // flash offset 0 onward (~2.09MB for the XC7A35T). The user program is
  // placed at flash offset 0x300000 (3MB mark, comfortable margin past
  // the bitstream). PROGADDR_RESET must therefore be XIP_BASE PLUS this
  // offset, not XIP_BASE alone - flash_addr = AXI_address - XIP_BASE
  // (see qspi_xip_slave.sv), so PROGADDR_RESET = XIP_BASE alone would
  // point the CPU's very first fetch at flash offset 0 - directly into
  // the bitstream region, not the actual program. This was a real,
  // previously-unresolved contradiction between the PROGADDR_RESET
  // setting and the flash memory map decision - caught and fixed here.
  localparam logic [31:0] PROGADDR_RESET_VAL = QSPI_XIP_BASE + USER_PROGRAM_FLASH_OFFSET;

  // Internal, active-low reset - the button-derived reset. qe_provision
  // itself uses THIS directly (it must run even before the rest of the
  // design is released). Everything else in the design uses resetn_main
  // instead, which additionally waits for qe_provision to finish -
  // confirmed as the actual fix for a real hardware finding: the onboard
  // MX25L3233F's Quad Enable bit defaults to 0 and is not reliably set
  // by Vivado's flash-programming flow alone, causing PicoRV32's first
  // XIP fetch (quad-mode) to return garbage and trap - confirmed via
  // real hardware testing (a heartbeat with zero PicoRV32/QSPI
  // dependency proved clock/reset infrastructure was otherwise fine,
  // isolating the problem specifically to bad XIP data).
  logic resetn;
  assign resetn = ~btn_reset;

  logic resetn_main;
  assign resetn_main = resetn && qe_done;

  logic [7:0] qe_sr_readback;
  logic [23:0] qe_jedec_id;

  qe_provision u_qe_provision (
    .clk    (clk),
    .resetn (resetn),
    .done   (qe_done),
    .sr_readback (qe_sr_readback),
    .jedec_id    (qe_jedec_id),

    .cs_n (qe_cs_n),
    .io0_out(qe_io0_out), .io0_oe(qe_io0_oe), .io0_in(qe_io0_in),
    .io1_out(qe_io1_out), .io1_oe(qe_io1_oe), .io1_in(qe_io1_in),
    .io2_out(qe_io2_out), .io2_oe(qe_io2_oe),
    .io3_out(qe_io3_out), .io3_oe(qe_io3_oe)
  );

  // Single clock domain for this whole top level, EXCEPT the physical

  // flash clock itself - see the STARTUPE2 note below. ACLK and qclk
  // are the SAME logical clock driving all internal FSMs (a deliberate
  // simplification for this first bring-up; a future revision could
  // give the QSPI engine its own truly independent clock via an MMCM).
  //
  // IMPORTANT, found during physical bring-up planning (not caught
  // earlier, since simulation never needed a real physical clock pin
  // at all - the behavioral flash model just shares the same wire):
  // Basys 3's flash chip SCLK pin is wired to the FPGA's DEDICATED
  // configuration clock pin (CCLK), which per Xilinx 7-series devices
  // and Digilent's own official constraints file CANNOT be reached via
  // an ordinary I/O pin at all - it is only accessible through the
  // STARTUPE2 primitive's USRCCLKO port. Without this, the flash chip
  // would never receive a single clock edge on real hardware, no matter
  // how correctly cs_n/io0-io3 were pin-constrained. qclk is derived
  // here as a divided 50MHz clock (100MHz/2) rather than run at full
  // system clock speed, since STARTUPE2-routed CCLK has a documented
  // practical ceiling around that rate on this class of board.
  logic clk_div2;
  always_ff @(posedge clk or negedge resetn) begin
    if (!resetn) clk_div2 <= 1'b0;
    else         clk_div2 <= ~clk_div2;
  end

  logic qclk;
  logic qclk_rst;
  assign qclk     = clk_div2; // 50MHz
  assign qclk_rst = ~resetn;

  STARTUPE2 #(
    .PROG_USR("FALSE")
  ) u_startupe2 (
    .CLK      (1'b0),
    .GSR      (1'b0),
    .GTS      (1'b0),
    .KEYCLEARB(1'b1),
    .PACK     (1'b0),
    .USRCCLKO (qclk),  // the actual, real drive to the flash chip's SCLK
    .USRCCLKTS(1'b0),  // 0 = actively drive USRCCLKO, not 3-stated
    .USRDONEO (1'b1),
    .USRDONETS(1'b1),
    .CFGCLK   (),
    .CFGMCLK  (),
    .EOS      (),
    .PREQ     ()
  );

  // ---- PicoRV32's AXI master port ----
  logic        mem_axi_awvalid, mem_axi_awready;
  logic [31:0] mem_axi_awaddr;
  logic [2:0]  mem_axi_awprot;
  logic        mem_axi_wvalid, mem_axi_wready;
  logic [31:0] mem_axi_wdata;
  logic [3:0]  mem_axi_wstrb;
  logic        mem_axi_bvalid, mem_axi_bready;
  logic        mem_axi_arvalid, mem_axi_arready;
  logic [31:0] mem_axi_araddr;
  logic [2:0]  mem_axi_arprot;
  logic        mem_axi_rvalid, mem_axi_rready;
  logic [31:0] mem_axi_rdata;
  logic        trap;

  // ---- PicoRV32's other, always-present ports (PCPI, IRQ, trace) -
  // tied to defined/unused values since none of these features are
  // enabled for this minimal first bring-up. Verified against the real
  // picorv32.v source, not guessed - these ports exist regardless of
  // the ENABLE_PCPI/ENABLE_IRQ/ENABLE_TRACE parameter values, so leaving
  // them unconnected (as an earlier draft of this file did) would leave
  // several real inputs floating.
  logic        pcpi_valid, pcpi_wr;
  logic [31:0] pcpi_insn, pcpi_rs1, pcpi_rs2, pcpi_rd;
  logic        pcpi_wait, pcpi_ready;
  logic [31:0] irq, eoi;
  logic        trace_valid;
  logic [35:0] trace_data;

  assign pcpi_wr    = 1'b0;
  assign pcpi_rd    = 32'h0;
  assign pcpi_wait  = 1'b0;
  assign pcpi_ready = 1'b0;
  assign irq        = 32'h0; // no interrupt sources wired up yet

  picorv32_axi #(
    .ENABLE_COUNTERS(0),
    .ENABLE_COUNTERS64(0),
    .ENABLE_REGS_16_31(1),
    .ENABLE_REGS_DUALPORT(1),
    .TWO_STAGE_SHIFT(1),
    .BARREL_SHIFTER(0),
    .TWO_CYCLE_COMPARE(0),
    .TWO_CYCLE_ALU(0),
    .COMPRESSED_ISA(0),
    .ENABLE_MUL(0),
    .ENABLE_FAST_MUL(0),
    .ENABLE_DIV(0),
    .ENABLE_IRQ(0),
    .ENABLE_IRQ_QREGS(0),
    .ENABLE_IRQ_TIMER(0),
    .ENABLE_TRACE(0),
    // CRITICAL: without this, PROGADDR_RESET defaults to 0x0, which our
    // system_router routes to the QSPI IP's REGISTER bank (CTRL_CMD),
    // not the XIP window - PicoRV32's very first fetch would read a
    // register value as an instruction and almost certainly crash
    // immediately. This is the actual mechanism that makes "boot
    // directly from XIP" work at all - must match QSPI_XIP_BASE.
    .PROGADDR_RESET(PROGADDR_RESET_VAL),
    .STACKADDR(RAM_TOP_ADDR) // top of the real on-chip RAM now - see
      // sram.sv. This was a placeholder pointing at the LED
      // peripheral's address before RAM existed at all; fixed now that
      // real, writable memory is actually present.
  ) u_cpu (
    .clk    (clk),
    .resetn (resetn_main),
    .trap   (trap),

    .mem_axi_awvalid (mem_axi_awvalid),
    .mem_axi_awready (mem_axi_awready),
    .mem_axi_awaddr  (mem_axi_awaddr),
    .mem_axi_awprot  (mem_axi_awprot),

    .mem_axi_wvalid (mem_axi_wvalid),
    .mem_axi_wready (mem_axi_wready),
    .mem_axi_wdata  (mem_axi_wdata),
    .mem_axi_wstrb  (mem_axi_wstrb),

    .mem_axi_bvalid (mem_axi_bvalid),
    .mem_axi_bready (mem_axi_bready),

    .mem_axi_arvalid (mem_axi_arvalid),
    .mem_axi_arready (mem_axi_arready),
    .mem_axi_araddr  (mem_axi_araddr),
    .mem_axi_arprot  (mem_axi_arprot),

    .mem_axi_rvalid (mem_axi_rvalid),
    .mem_axi_rready (mem_axi_rready),
    .mem_axi_rdata  (mem_axi_rdata),

    .pcpi_valid (pcpi_valid),
    .pcpi_insn  (pcpi_insn),
    .pcpi_rs1   (pcpi_rs1),
    .pcpi_rs2   (pcpi_rs2),
    .pcpi_wr    (pcpi_wr),
    .pcpi_rd    (pcpi_rd),
    .pcpi_wait  (pcpi_wait),
    .pcpi_ready (pcpi_ready),

    .irq (irq),
    .eoi (eoi),

    .trace_valid (trace_valid),
    .trace_data  (trace_data)
  );

  // ---- Router outputs to QSPI IP ----
  logic [31:0] qspi_awaddr;
  logic        qspi_awvalid, qspi_awready;
  logic [31:0] qspi_wdata;
  logic [3:0]  qspi_wstrb;
  logic        qspi_wvalid, qspi_wready;
  logic [1:0]  qspi_bresp;
  logic        qspi_bvalid, qspi_bready;
  logic [31:0] qspi_araddr;
  logic        qspi_arvalid, qspi_arready;
  logic [31:0] qspi_rdata;
  logic [1:0]  qspi_rresp;
  logic        qspi_rvalid, qspi_rready;

  // ---- Router outputs to LED peripheral ----
  logic [31:0] led_awaddr;
  logic        led_awvalid, led_awready;
  logic [31:0] led_wdata;
  logic [3:0]  led_wstrb;
  logic        led_wvalid, led_wready;
  logic [1:0]  led_bresp;
  logic        led_bvalid, led_bready;
  logic [31:0] led_araddr;
  logic        led_arvalid, led_arready;
  logic [31:0] led_rdata;
  logic [1:0]  led_rresp;
  logic        led_rvalid, led_rready;

  // ---- Router outputs to on-chip RAM ----
  logic [31:0] ram_awaddr;
  logic        ram_awvalid, ram_awready;
  logic [31:0] ram_wdata;
  logic [3:0]  ram_wstrb;
  logic        ram_wvalid, ram_wready;
  logic [1:0]  ram_bresp;
  logic        ram_bvalid, ram_bready;
  logic [31:0] ram_araddr;
  logic        ram_arvalid, ram_arready;
  logic [31:0] ram_rdata;
  logic [1:0]  ram_rresp;
  logic        ram_rvalid, ram_rready;

  system_router #(
    .QSPI_XIP_BASE (QSPI_XIP_BASE),
    .QSPI_XIP_SIZE (QSPI_XIP_SIZE),
    .RAM_BASE      (RAM_BASE_ADDR),
    .RAM_TOP       (RAM_TOP_ADDR)
  ) u_router (
    .ACLK    (clk),
    .ARESETn (resetn_main),

    .M_AXI_AWADDR  (mem_axi_awaddr),
    .M_AXI_AWVALID (mem_axi_awvalid),
    .M_AXI_AWREADY (mem_axi_awready),
    .M_AXI_WDATA   (mem_axi_wdata),
    .M_AXI_WSTRB   (mem_axi_wstrb),
    .M_AXI_WVALID  (mem_axi_wvalid),
    .M_AXI_WREADY  (mem_axi_wready),
    .M_AXI_BRESP   (),           // PicoRV32 has no BRESP input - see
                                  // basys3_top.sv header notes on this
    .M_AXI_BVALID  (mem_axi_bvalid),
    .M_AXI_BREADY  (mem_axi_bready),
    .M_AXI_ARADDR  (mem_axi_araddr),
    .M_AXI_ARVALID (mem_axi_arvalid),
    .M_AXI_ARREADY (mem_axi_arready),
    .M_AXI_RDATA   (mem_axi_rdata),
    .M_AXI_RRESP   (),           // PicoRV32 has no RRESP input either
    .M_AXI_RVALID  (mem_axi_rvalid),
    .M_AXI_RREADY  (mem_axi_rready),

    .QSPI_AWADDR  (qspi_awaddr),  .QSPI_AWVALID (qspi_awvalid),  .QSPI_AWREADY (qspi_awready),
    .QSPI_WDATA   (qspi_wdata),   .QSPI_WSTRB   (qspi_wstrb),    .QSPI_WVALID  (qspi_wvalid), .QSPI_WREADY(qspi_wready),
    .QSPI_BRESP   (qspi_bresp),   .QSPI_BVALID  (qspi_bvalid),   .QSPI_BREADY  (qspi_bready),
    .QSPI_ARADDR  (qspi_araddr),  .QSPI_ARVALID (qspi_arvalid),  .QSPI_ARREADY (qspi_arready),
    .QSPI_RDATA   (qspi_rdata),   .QSPI_RRESP   (qspi_rresp),    .QSPI_RVALID  (qspi_rvalid), .QSPI_RREADY(qspi_rready),

    .LED_AWADDR  (led_awaddr),  .LED_AWVALID (led_awvalid),  .LED_AWREADY (led_awready),
    .LED_WDATA   (led_wdata),   .LED_WSTRB   (led_wstrb),    .LED_WVALID  (led_wvalid), .LED_WREADY(led_wready),
    .LED_BRESP   (led_bresp),   .LED_BVALID  (led_bvalid),   .LED_BREADY  (led_bready),
    .LED_ARADDR  (led_araddr),  .LED_ARVALID (led_arvalid),  .LED_ARREADY (led_arready),
    .LED_RDATA   (led_rdata),   .LED_RRESP   (led_rresp),    .LED_RVALID  (led_rvalid), .LED_RREADY(led_rready),

    .RAM_AWADDR  (ram_awaddr),  .RAM_AWVALID (ram_awvalid),  .RAM_AWREADY (ram_awready),
    .RAM_WDATA   (ram_wdata),   .RAM_WSTRB   (ram_wstrb),    .RAM_WVALID  (ram_wvalid), .RAM_WREADY(ram_wready),
    .RAM_BRESP   (ram_bresp),   .RAM_BVALID  (ram_bvalid),   .RAM_BREADY  (ram_bready),
    .RAM_ARADDR  (ram_araddr),  .RAM_ARVALID (ram_arvalid),  .RAM_ARREADY (ram_arready),
    .RAM_RDATA   (ram_rdata),   .RAM_RRESP   (ram_rresp),    .RAM_RVALID  (ram_rvalid), .RAM_RREADY(ram_rready)
  );

  qspi_axi_top #(
    .TIMEOUT_CYCLES (QSPI_TIMEOUT_CYCLES),
    .XIP_BASE       (QSPI_XIP_BASE),
    .XIP_SIZE       (QSPI_XIP_SIZE),
    // Pre-enabled at reset, opcode 0x6B (QREAD: quad data/single addr,
    // 8 dummy cycles, 24-bit addr) - this system integration's own
    // decision, not the IP's default (see axi4L_slave.sv). PicoRV32's
    // very first instruction fetch after reset comes directly from XIP,
    // with no bootloader step to configure it first, so it has to
    // already be correct the instant reset releases. Matches this
    // project's confirmed real hardware target: the onboard MX25L3233F
    // flash's QREAD instruction has a FIXED 8 dummy cycles per its
    // actual datasheet - not configurable, not a guess.
    .XIP_CFG_RESET  (32'h8001086B)
  ) u_qspi (
    .ACLK    (clk),
    .ARESETn (resetn_main),
    .qclk    (qclk),
    .qclk_rst(qclk_rst),

    .S_AXI_AWADDR  (qspi_awaddr),  .S_AXI_AWVALID (qspi_awvalid),  .S_AXI_AWREADY (qspi_awready),
    .S_AXI_WDATA   (qspi_wdata),   .S_AXI_WSTRB   (qspi_wstrb),    .S_AXI_WVALID  (qspi_wvalid), .S_AXI_WREADY(qspi_wready),
    .S_AXI_BRESP   (qspi_bresp),   .S_AXI_BVALID  (qspi_bvalid),   .S_AXI_BREADY  (qspi_bready),
    .S_AXI_ARADDR  (qspi_araddr),  .S_AXI_ARVALID (qspi_arvalid),  .S_AXI_ARREADY (qspi_arready),
    .S_AXI_RDATA   (qspi_rdata),   .S_AXI_RRESP   (qspi_rresp),    .S_AXI_RVALID  (qspi_rvalid), .S_AXI_RREADY(qspi_rready),

    .cs_n (qspi_top_cs_n),
    .io0_out(qspi_top_io0_out), .io0_oe(qspi_top_io0_oe), .io0_in(qspi_top_io0_in),
    .io1_out(qspi_top_io1_out), .io1_oe(qspi_top_io1_oe), .io1_in(qspi_top_io1_in),
    .io2_out(qspi_top_io2_out), .io2_oe(qspi_top_io2_oe), .io2_in(qspi_top_io2_in),
    .io3_out(qspi_top_io3_out), .io3_oe(qspi_top_io3_oe), .io3_in(qspi_top_io3_in)
  );

  // ---- Diagnostic: trap directly visible on led[15], bypassing all
  // software/AXI entirely - added specifically to test whether PicoRV32
  // is hitting an illegal instruction (consistent with the QE-bit
  // hypothesis: garbage data fetched via XIP if quad mode isn't actually
  // working on the real flash chip). If this LED lights and stays lit,
  // that's a direct, hardware-only confirmation of a trap, independent
  // of anything the LED peripheral's own software-driven register does.
  // led_peripheral itself is UNCHANGED - this override happens only in
  // this top-level wiring, on the top bit specifically so it doesn't
  // interfere with observing the normal 0-14 fill pattern on the
  // remaining 15 LEDs.
  // Diagnostic: a simple heartbeat blinker on led[14], driven DIRECTLY by
  // clk and gated only by our own resetn - zero dependency on
  // PicoRV32/AXI/QSPI/anything else in the design. If this blinks, it
  // proves clk is genuinely reaching the design and our reset derivation
  // (btn_reset inversion) is releasing correctly - isolating "the most
  // basic infrastructure is alive" from "PicoRV32/the QSPI chain
  // specifically isn't working," given the observed symptom (no trap,
  // no LED activity at all) doesn't distinguish between these on its own.
  // DIAGNOSTIC v2: reset dependency REMOVED entirely - counts purely off
  // clk, no gating at all. Relies only on the FPGA's own power-on/config
  // initial state (Xilinx FPGAs initialize registers to their declared
  // reset value on configuration load, independent of any user reset
  // logic). If THIS still doesn't blink, clk itself isn't reaching the
  // design - a pin/constraint problem, not a reset problem. If THIS
  // blinks but the resetn-gated version didn't, that directly confirms
  // resetn is the actual culprit (stuck permanently asserted).
  logic [23:0] heartbeat_cnt;
  initial heartbeat_cnt = 24'h0; // simulation-only: matches what real
    // hardware already does via its own bitstream-defined register
    // init value (confirmed working on real silicon - LD14 blinked
    // correctly). Without this, Icarus specifically has no equivalent
    // mechanism, so a genuinely reset-free register starts as X and
    // X-propagates forever (X+1=X) - purely a simulation artifact, not
    // a real design issue, but worth fixing so simulation results stay
    // trustworthy going forward.
  always_ff @(posedge clk) begin
    heartbeat_cnt <= heartbeat_cnt + 1'b1;
  end

  logic [15:0] led_from_peripheral;
  // DIAGNOSTIC: led[7:0] show the chip's real Manufacturer ID byte
  // (from RDID) - 0xC2 confirms Macronix; anything else means every
  // assumption made so far about this chip's opcodes/QE-bit/timing
  // needs to be revisited against a different datasheet entirely.
  // led[8] shows JUST the QE bit (Status Register bit 6) from RDSR -
  // lit means QE is genuinely set on real silicon.
  assign led = {trap, heartbeat_cnt[23], led_from_peripheral[13:9], qe_sr_readback[6], qe_jedec_id[23:16]};

  led_peripheral u_led (
    .ACLK    (clk),
    .ARESETn (resetn_main),

    .S_AXI_AWADDR  (led_awaddr),  .S_AXI_AWVALID (led_awvalid),  .S_AXI_AWREADY (led_awready),
    .S_AXI_WDATA   (led_wdata),   .S_AXI_WSTRB   (led_wstrb),    .S_AXI_WVALID  (led_wvalid), .S_AXI_WREADY(led_wready),
    .S_AXI_BRESP   (led_bresp),   .S_AXI_BVALID  (led_bvalid),   .S_AXI_BREADY  (led_bready),
    .S_AXI_ARADDR  (led_araddr),  .S_AXI_ARVALID (led_arvalid),  .S_AXI_ARREADY (led_arready),
    .S_AXI_RDATA   (led_rdata),   .S_AXI_RRESP   (led_rresp),    .S_AXI_RVALID  (led_rvalid), .S_AXI_RREADY(led_rready),

    .led (led_from_peripheral)
  );

  sram #(
    .DEPTH_WORDS (RAM_DEPTH_WORDS)
  ) u_ram (
    .ACLK    (clk),
    .ARESETn (resetn_main),

    .S_AXI_AWADDR  (ram_awaddr),  .S_AXI_AWVALID (ram_awvalid),  .S_AXI_AWREADY (ram_awready),
    .S_AXI_WDATA   (ram_wdata),   .S_AXI_WSTRB   (ram_wstrb),    .S_AXI_WVALID  (ram_wvalid), .S_AXI_WREADY(ram_wready),
    .S_AXI_BRESP   (ram_bresp),   .S_AXI_BVALID  (ram_bvalid),   .S_AXI_BREADY  (ram_bready),
    .S_AXI_ARADDR  (ram_araddr),  .S_AXI_ARVALID (ram_arvalid),  .S_AXI_ARREADY (ram_arready),
    .S_AXI_RDATA   (ram_rdata),   .S_AXI_RRESP   (ram_rresp),    .S_AXI_RVALID  (ram_rvalid), .S_AXI_RREADY(ram_rready)
  );

endmodule