// qe_provision.sv
//
// One-time provisioning: sets the Quad Enable (QE) bit on the onboard
// MX25L3233F flash chip, via a direct WREN + WRSR bit-bang sequence.
//
// WHY THIS EXISTS AS A SEPARATE MODULE, NOT PART OF qspi_engine.sv:
// WREN (0x06) is opcode-only, 8 bits, no address, no data at all.
// WRSR (0x01) is opcode + 2 data bytes (Status Register, Configuration
// Register), again with NO address phase. qspi_engine.sv's fixed
// CMD->ADDR->DUMMY->DATA phase structure cannot express either of these
// without restructuring the core engine - which was deliberately
// decided against (the core architecture stays fixed). This module
// bypasses qspi_engine.sv entirely and drives the physical QSPI pins
// directly, using single-line (not quad) SPI - standard practice, since
// WREN/WRSR are always single-line regardless of a chip's quad
// capability, being used for setup BEFORE quad mode is usable at all.
//
// Real hardware finding this module exists to fix: on real MX25L3233F
// silicon, QE defaults to 0 (confirmed via the actual datasheet, and
// confirmed independently via a Macronix support engineer discussing
// this exact chip) - not something Vivado's flash-programming flow can
// be relied upon to set transparently, contrary to earlier documented
// research about SPI configuration memory programming in general. This
// was confirmed as the actual root cause on real hardware: PicoRV32's
// first XIP fetch (quad-mode, opcode 0x6B) returned garbage and
// trapped, while a heartbeat with zero PicoRV32/QSPI dependency
// confirmed clock/reset infrastructure was otherwise working correctly.
//
// Sequenced entry: PicoRV32 (and the rest of the design) is held in
// reset by basys3_top.sv until this module signals "done" - see that
// file's top-level reset logic. This module takes exclusive control of
// cs_n/io0/io1 for its own brief duration; io2/io3 are driven high
// (matching the WP#/HOLD# deasserted convention expected during
// single-line commands) throughout.

module qe_provision (
  input  logic clk,
  input  logic resetn,      // this module runs even while the REST of
                             // the design stays held in reset - it must
                             // NOT itself depend on "done" existing yet

  output logic done,        // pulses high once, then stays high forever
                             // - basys3_top.sv releases the rest of the
                             // design from reset once this asserts

  output logic cs_n,
  output logic io0_out, output logic io0_oe, input logic io0_in,
  output logic io1_out, output logic io1_oe,
  output logic io2_out, output logic io2_oe,
  output logic io3_out, output logic io3_oe
);

  // Status Register value to write: bit 6 (QE) = 1, everything else 0
  // (BP3:BP0 = 0, unprotected - matches the chip's own factory default
  // for those bits, so this only actually changes QE, nothing else).
  localparam logic [7:0] SR_VALUE  = 8'b0100_0000;
  // Configuration Register value: 0x00 (all defaults - ODS/TB/etc left
  // at their factory-default values, only QE is the actual target here).
  localparam logic [7:0] CR_VALUE  = 8'h00;

  localparam logic [7:0] OP_WREN = 8'h06;
  localparam logic [7:0] OP_WRSR = 8'h01;

  typedef enum logic [3:0] {
    S_IDLE, S_WREN_CS, S_WREN_SHIFT, S_WREN_CSHIGH, S_GAP,
    S_WRSR_CS, S_WRSR_SHIFT, S_WRSR_CSHIGH, S_DONE
  } state_t;
  state_t state;

  logic [23:0] shift_reg;   // holds whichever command's bits, MSB-first
  logic [4:0]  bit_cnt;     // counts bits shifted out (up to 24 for WRSR)
  logic [15:0] gap_cnt;     // brief settle gap between WREN and WRSR

  assign io0_oe = 1'b1;         // always driving (master, single-line out)
  assign io1_oe = 1'b0;         // io1 is input during single-line commands
  assign io2_out = 1'b1; assign io2_oe = 1'b1; // WP# deasserted
  assign io3_out = 1'b1; assign io3_oe = 1'b1; // HOLD# deasserted
  assign io0_out = shift_reg[23];

  always_ff @(posedge clk or negedge resetn) begin
    if (!resetn) begin
      state     <= S_IDLE;
      cs_n      <= 1'b1;
      shift_reg <= 24'h0;
      bit_cnt   <= 5'h0;
      gap_cnt   <= 16'h0;
      done      <= 1'b0;
    end else begin
      case (state)
        S_IDLE: begin
          cs_n      <= 1'b1;
          shift_reg <= {OP_WREN, 16'h0};
          bit_cnt   <= 5'd0;
          state     <= S_WREN_CS;
        end

        S_WREN_CS: begin
          cs_n  <= 1'b0; // assert chip select, one cycle before first bit
          state <= S_WREN_SHIFT;
        end

        S_WREN_SHIFT: begin
          shift_reg <= {shift_reg[22:0], 1'b0};
          bit_cnt   <= bit_cnt + 1'b1;
          if (bit_cnt == 5'd7) begin // 8 bits (opcode only) done
            state <= S_WREN_CSHIGH;
          end
        end

        S_WREN_CSHIGH: begin
          cs_n     <= 1'b1; // exactly at the 8-bit boundary, per datasheet
          gap_cnt  <= 16'h0;
          state    <= S_GAP;
        end

        S_GAP: begin
          // Brief settle gap - lets WREN's internal write-enable-latch
          // actually take effect before WRSR arrives. Generous margin,
          // not timed to a specific minimum from the datasheet - this
          // only ever runs once, cost of being conservative here is
          // negligible.
          gap_cnt <= gap_cnt + 1'b1;
          if (gap_cnt == 16'd999) begin
            shift_reg <= {OP_WRSR, SR_VALUE, CR_VALUE};
            bit_cnt   <= 5'd0;
            state     <= S_WRSR_CS;
          end
        end

        S_WRSR_CS: begin
          cs_n  <= 1'b0;
          state <= S_WRSR_SHIFT;
        end

        S_WRSR_SHIFT: begin
          shift_reg <= {shift_reg[22:0], 1'b0};
          bit_cnt   <= bit_cnt + 1'b1;
          if (bit_cnt == 5'd23) begin // 24 bits (opcode+SR+CR) done
            state <= S_WRSR_CSHIGH;
          end
        end

        S_WRSR_CSHIGH: begin
          cs_n  <= 1'b1; // exactly at the 24-bit boundary
          state <= S_DONE;
        end

        S_DONE: begin
          done <= 1'b1; // stays high forever from here on
        end

        default: state <= S_IDLE;
      endcase
    end
  end

endmodule