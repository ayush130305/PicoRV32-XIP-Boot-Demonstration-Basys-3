// led_peripheral.sv
//
// Minimal memory-mapped AXI4-Lite peripheral: a single 16-bit writable
// register driving Basys 3's onboard LEDs, for the PicoRV32 hardware
// demonstration. This is deliberately as simple as possible - the whole
// point of the demonstration is proving the CPU executed instructions
// fetched via XIP, not exercising a sophisticated peripheral. One
// register, one address, write it and the LEDs change.
//
// Implements only what a real AXI4-Lite slave must: full AW/W/B write
// handshake, full AR/R read handshake (so the current LED state is also
// readable back, useful for debug), no wait states beyond the minimum
// the protocol requires.

module led_peripheral (
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

  output logic [15:0] led // to Basys 3's 16 onboard LEDs
);

  logic [15:0] led_reg;
  assign led = led_reg;

  // ---- Write path ----
  typedef enum logic [1:0] {W_IDLE, W_DATA_OK, W_RESP} wstate_t;
  wstate_t wstate;

  logic aw_done, w_done;

  always_ff @(posedge ACLK or negedge ARESETn) begin
    if (!ARESETn) begin
      wstate        <= W_IDLE;
      S_AXI_AWREADY <= 1'b0;
      S_AXI_WREADY  <= 1'b0;
      S_AXI_BVALID  <= 1'b0;
      S_AXI_BRESP   <= 2'b00;
      led_reg       <= 16'h0000; // LEDs off at reset
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
          if ((aw_done || (S_AXI_AWVALID)) && (w_done || S_AXI_WVALID)) begin
            wstate <= W_RESP;
          end
        end
        W_RESP: begin
          if (S_AXI_WSTRB[0]) led_reg[7:0]   <= S_AXI_WDATA[7:0];
          if (S_AXI_WSTRB[1]) led_reg[15:8]  <= S_AXI_WDATA[15:8];
          // WSTRB[3:2] intentionally ignored - led_reg is only 16 bits
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
            S_AXI_RDATA   <= {16'h0, led_reg};
            S_AXI_RRESP   <= 2'b00; // OKAY
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

endmodule