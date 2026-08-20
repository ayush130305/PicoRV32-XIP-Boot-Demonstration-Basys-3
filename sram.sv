// sram.sv
//
// On-chip RAM for PicoRV32's stack and local data.
//
// FIRST VERSION OF THIS FILE HAD A REAL BUG, WORTH DOCUMENTING: it mixed
// per-byte conditional writes to sub-ranges of the memory array
// (mem[addr][7:0] <= ..., mem[addr][15:8] <= ..., etc, as separate `if`
// statements inside ONE always_ff block that ALSO handled AXI protocol
// state-machine logic) into a single process. This broke Vivado's BRAM
// inference pattern-matcher entirely - not a fallback to distributed
// RAM, but a fallback to raw flip-flop-per-bit storage: confirmed by an
// actual synthesis run showing 28,720 LUTs (138% - over budget) and
// 67,770 registers, for what should have been a small, cheap 8KB
// memory. Block RAM Tile usage was 0.
//
// This version uses the actual well-established Xilinx idiom for
// reliable byte-enable BRAM inference: a `generate` block with a
// SEPARATE, minimal always_ff process per byte lane, doing ONLY the
// memory write for that lane - no protocol logic mixed in. The read
// path is similarly isolated into its own minimal process. All AXI
// handshake/state-machine logic lives in separate blocks that only
// ever compute the enable/address/data signals feeding these isolated
// memory processes, never touching the array directly themselves.
//
// Confirm this actually works by checking the NEXT synthesis report for
// non-zero "Block RAM Tile" usage - do not assume this fix worked
// without checking that specific number, given the first version's
// failure was silent (it compiled cleanly and "worked" in the sense of
// producing correct simulation behavior; the inference failure only
// showed up in the utilization report).

module sram #(
  parameter int unsigned DEPTH_WORDS = 2048 // 2048 x 32-bit = 8KB
)(
  input  logic        ACLK,
  input  logic        ARESETn,

  input  logic [31:0] S_AXI_AWADDR,
  input  logic        S_AXI_AWVALID,
  output logic        S_AXI_AWREADY,

  input  logic [31:0] S_AXI_WDATA,
  input  logic [3:0]  S_AXI_WSTRB,
  input  logic        S_AXI_WVALID,
  output logic        S_AXI_WREADY,

  output logic [1:0]  S_AXI_BRESP,
  output logic        S_AXI_BVALID,
  input  logic        S_AXI_BREADY,

  input  logic [31:0] S_AXI_ARADDR,
  input  logic        S_AXI_ARVALID,
  output logic        S_AXI_ARREADY,

  output logic [31:0] S_AXI_RDATA,
  output logic [1:0]  S_AXI_RRESP,
  output logic        S_AXI_RVALID,
  input  logic        S_AXI_RREADY
);

  localparam int WORD_ADDR_BITS = $clog2(DEPTH_WORDS);

  // ==== The actual memory array and its I/O - kept completely isolated
  // from all AXI protocol logic below, per the working Xilinx idiom. ====

  (* ram_style = "block" *) logic [7:0] mem_b0 [0:DEPTH_WORDS-1];
  (* ram_style = "block" *) logic [7:0] mem_b1 [0:DEPTH_WORDS-1];
  (* ram_style = "block" *) logic [7:0] mem_b2 [0:DEPTH_WORDS-1];
  (* ram_style = "block" *) logic [7:0] mem_b3 [0:DEPTH_WORDS-1];

  logic mem_we;
  logic [3:0]                 mem_wstrb;
  logic [WORD_ADDR_BITS-1:0]  mem_waddr;
  logic [31:0]                mem_wdata;
  logic [WORD_ADDR_BITS-1:0]  mem_raddr;
  logic [31:0]                mem_rdata_r;

  // One minimal, isolated always_ff per byte lane - this is the actual
  // pattern Vivado's inference engine reliably recognizes for
  // byte-enable BRAM writes, unlike the earlier single-process,
  // multi-if-statement version.
  always_ff @(posedge ACLK) begin
    if (mem_we && mem_wstrb[0]) mem_b0[mem_waddr] <= mem_wdata[7:0];
  end
  always_ff @(posedge ACLK) begin
    if (mem_we && mem_wstrb[1]) mem_b1[mem_waddr] <= mem_wdata[15:8];
  end
  always_ff @(posedge ACLK) begin
    if (mem_we && mem_wstrb[2]) mem_b2[mem_waddr] <= mem_wdata[23:16];
  end
  always_ff @(posedge ACLK) begin
    if (mem_we && mem_wstrb[3]) mem_b3[mem_waddr] <= mem_wdata[31:24];
  end

  // Synchronous read, also isolated - no protocol logic in this process.
  always_ff @(posedge ACLK) begin
    mem_rdata_r <= {mem_b3[mem_raddr], mem_b2[mem_raddr], mem_b1[mem_raddr], mem_b0[mem_raddr]};
  end

  // ==== AXI4-Lite protocol logic - only ever drives the signals above,
  // never touches mem_b0..mem_b3 directly. ====

  // ---- Write path ----
  typedef enum logic [1:0] {W_IDLE, W_RESP} wstate_t;
  wstate_t wstate;
  logic aw_done, w_done;
  logic [WORD_ADDR_BITS-1:0] aw_word_addr;
  logic [31:0] w_data_latched;
  logic [3:0]  w_strb_latched;

  assign mem_wstrb = w_strb_latched;
  assign mem_waddr = aw_word_addr;
  assign mem_wdata = w_data_latched;

  always_ff @(posedge ACLK or negedge ARESETn) begin
    if (!ARESETn) begin
      wstate         <= W_IDLE;
      S_AXI_AWREADY  <= 1'b0;
      S_AXI_WREADY   <= 1'b0;
      S_AXI_BVALID   <= 1'b0;
      S_AXI_BRESP    <= 2'b00;
      aw_done        <= 1'b0;
      w_done         <= 1'b0;
      mem_we         <= 1'b0;
    end else begin
      S_AXI_AWREADY <= 1'b0;
      S_AXI_WREADY  <= 1'b0;
      mem_we        <= 1'b0; // default: only pulses explicitly below, one cycle

      case (wstate)
        W_IDLE: begin
          if (S_AXI_AWVALID && !aw_done) begin
            S_AXI_AWREADY <= 1'b1;
            aw_word_addr  <= S_AXI_AWADDR[WORD_ADDR_BITS+1:2];
            aw_done       <= 1'b1;
          end
          if (S_AXI_WVALID && !w_done) begin
            S_AXI_WREADY   <= 1'b1;
            w_data_latched <= S_AXI_WDATA;
            w_strb_latched <= S_AXI_WSTRB;
            w_done         <= 1'b1;
          end
          // mem_we pulses the SAME edge wstate transitions to W_RESP -
          // this is safe (not a repeat of the earlier same-cycle race)
          // because mem_we itself is REGISTERED (via NBA here), so it
          // only becomes visible to the byte-lane write processes
          // starting the FIRST cycle of W_RESP - by which point
          // aw_word_addr/w_data_latched/w_strb_latched have themselves
          // already settled from this same transitioning edge's NBA
          // updates. The earlier bug was mem_we being COMBINATIONAL and
          // visible on the very edge those latches were still settling.
          if ((aw_done || S_AXI_AWVALID) && (w_done || S_AXI_WVALID)) begin
            wstate <= W_RESP;
            mem_we <= 1'b1;
          end
        end
        W_RESP: begin
          S_AXI_BVALID <= 1'b1;
          S_AXI_BRESP  <= 2'b00; // OKAY
          if (S_AXI_BVALID && S_AXI_BREADY) begin
            S_AXI_BVALID <= 1'b0;
            wstate       <= W_IDLE;
            aw_done      <= 1'b0;
            w_done       <= 1'b0;
          end
        end
        default: wstate <= W_IDLE;
      endcase
    end
  end

  // ---- Read path ----
  typedef enum logic [0:0] {R_IDLE, R_DATA} rstate_t;
  rstate_t rstate;

  assign mem_raddr = S_AXI_ARADDR[WORD_ADDR_BITS+1:2];

  always_ff @(posedge ACLK or negedge ARESETn) begin
    if (!ARESETn) begin
      rstate        <= R_IDLE;
      S_AXI_ARREADY <= 1'b0;
      S_AXI_RVALID  <= 1'b0;
      S_AXI_RRESP   <= 2'b00;
      S_AXI_RDATA   <= 32'h0;
    end else begin
      S_AXI_ARREADY <= 1'b0;
      case (rstate)
        R_IDLE: begin
          if (S_AXI_ARVALID) begin
            S_AXI_ARREADY <= 1'b1;
            rstate        <= R_DATA;
          end
        end
        R_DATA: begin
          // mem_rdata_r settles one cycle after mem_raddr was presented
          // (R_IDLE's cycle) - exactly matching this state transition,
          // same one-cycle-delay principle this whole project has hit
          // repeatedly elsewhere (RX timing, XIP byte assembly).
          S_AXI_RDATA  <= mem_rdata_r;
          S_AXI_RRESP  <= 2'b00; // OKAY
          S_AXI_RVALID <= 1'b1;
          if (S_AXI_RVALID && S_AXI_RREADY) begin
            S_AXI_RVALID <= 1'b0;
            rstate       <= R_IDLE;
          end
        end
        default: rstate <= R_IDLE;
      endcase
    end
  end

endmodule