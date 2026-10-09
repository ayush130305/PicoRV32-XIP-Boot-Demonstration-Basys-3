// seven_seg.sv
//
// Drives Basys 3's 4-digit, common-anode, multiplexed seven-segment
// display. A single AXI4-Lite writable register holds a 16-bit value,
// displayed as 4 hex digits (MSB digit on the left, an[3]).
//
// IMPORTANT, confirmed directly against Digilent's own reference manual
// (not the generic textbook common-anode convention): "since Basys3
// uses transistors to drive enough current into the common anode point,
// the anode enables are inverted. Therefore, both the AN0..3 and the
// CA..G/DP signals are driven low when active." Both anode (digit
// select) AND segment signals are active-LOW on this specific board -
// confirmed via two independent Digilent sources, not assumed from a
// generic tutorial (which would have given active-high anodes, wrong
// for this board).
//
// This peripheral owns its own internal refresh timing - unlike
// led_peripheral.sv's simple static register, a multiplexed display
// needs continuous, hardware-driven cycling between digits (~1kHz per
// digit, per Digilent's documented 1kHz-60Hz refresh guidance) that has
// nothing to do with software timing at all - software just writes the
// value once; this module handles making it visible continuously.

module seven_seg (
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
  input  logic        S_AXI_RREADY,

  output logic [6:0]  seg, // segments A-G, active-low
  output logic        dp,  // decimal point, active-low - always off (1)
  output logic [3:0]  an   // digit select, active-low, one-hot
);

  logic [15:0] display_reg;

  // ---- Write path (same pattern as led_peripheral.sv) ----
  typedef enum logic [1:0] {W_IDLE, W_RESP} wstate_t;
  wstate_t wstate;
  logic aw_done, w_done;

  always_ff @(posedge ACLK or negedge ARESETn) begin
    if (!ARESETn) begin
      wstate        <= W_IDLE;
      S_AXI_AWREADY <= 1'b0;
      S_AXI_WREADY  <= 1'b0;
      S_AXI_BVALID  <= 1'b0;
      S_AXI_BRESP   <= 2'b00;
      display_reg   <= 16'h0000;
      aw_done       <= 1'b0;
      w_done        <= 1'b0;
    end else begin
      S_AXI_AWREADY <= 1'b0;
      S_AXI_WREADY  <= 1'b0;

      case (wstate)
        W_IDLE: begin
          if (S_AXI_AWVALID && !aw_done) begin
            S_AXI_AWREADY <= 1'b1;
            aw_done       <= 1'b1;
          end
          if (S_AXI_WVALID && !w_done) begin
            S_AXI_WREADY <= 1'b1;
            w_done       <= 1'b1;
          end
          if ((aw_done || S_AXI_AWVALID) && (w_done || S_AXI_WVALID)) begin
            wstate <= W_RESP;
          end
        end
        W_RESP: begin
          if (S_AXI_WSTRB[0]) display_reg[7:0]   <= S_AXI_WDATA[7:0];
          if (S_AXI_WSTRB[1]) display_reg[15:8]  <= S_AXI_WDATA[15:8];
          S_AXI_BVALID <= 1'b1;
          S_AXI_BRESP  <= 2'b00;
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
            S_AXI_RDATA   <= {16'h0, display_reg};
            S_AXI_RRESP   <= 2'b00;
            S_AXI_RVALID  <= 1'b1;
            rstate        <= R_DATA;
          end
        end
        R_DATA: begin
          if (S_AXI_RVALID && S_AXI_RREADY) begin
            S_AXI_RVALID <= 1'b0;
            rstate       <= R_IDLE;
          end
        end
        default: rstate <= R_IDLE;
      endcase
    end
  end

  // ---- Refresh/multiplex logic - runs continuously, independent of
  // software timing entirely ----
  localparam int REFRESH_DIV_BITS = 15; // 2^15 / 100MHz ~= 328us per
    // digit ~= 763Hz per-digit refresh - comfortably inside Digilent's
    // documented 1kHz-60Hz guidance, not just barely meeting it.
  logic [REFRESH_DIV_BITS-1:0] refresh_cnt;
  logic [1:0] active_digit; // 0=rightmost(an0) .. 3=leftmost(an3)

  always_ff @(posedge ACLK or negedge ARESETn) begin
    if (!ARESETn) begin
      refresh_cnt  <= '0;
      active_digit <= 2'd0;
    end else begin
      refresh_cnt <= refresh_cnt + 1'b1;
      if (refresh_cnt == '1) begin
        active_digit <= active_digit + 1'b1;
      end
    end
  end

  logic [3:0] current_nibble;
  always_comb begin
    case (active_digit)
      2'd0: current_nibble = display_reg[3:0];
      2'd1: current_nibble = display_reg[7:4];
      2'd2: current_nibble = display_reg[11:8];
      2'd3: current_nibble = display_reg[15:12];
      default: current_nibble = 4'h0;
    endcase
  end

  // Digit select - active-low, one-hot (exactly one an[x] low at a time)
  always_comb begin
    an = 4'b1111;
    an[active_digit] = 1'b0;
  end

  assign dp = 1'b1; // decimal point always off

  // Hex-to-segment lookup, active-low (0 = segment on), segment order
  // {G,F,E,D,C,B,A} matching seg[6:0] = {CG,CF,CE,CD,CC,CB,CA} as
  // physically labeled on the board and in the master XDC.
  always_comb begin
    case (current_nibble)
      4'h0: seg = 7'b1000000;
      4'h1: seg = 7'b1111001;
      4'h2: seg = 7'b0100100;
      4'h3: seg = 7'b0110000;
      4'h4: seg = 7'b0011001;
      4'h5: seg = 7'b0010010;
      4'h6: seg = 7'b0000010;
      4'h7: seg = 7'b1111000;
      4'h8: seg = 7'b0000000;
      4'h9: seg = 7'b0010000;
      4'hA: seg = 7'b0001000;
      4'hB: seg = 7'b0000011;
      4'hC: seg = 7'b1000110;
      4'hD: seg = 7'b0100001;
      4'hE: seg = 7'b0000110;
      4'hF: seg = 7'b0001110;
      default: seg = 7'b1111111; // all off
    endcase
  end

endmodule