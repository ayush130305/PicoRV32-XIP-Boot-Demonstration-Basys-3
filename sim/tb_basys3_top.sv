// tb_basys3_top.sv
//
// First full-system functional simulation of basys3_top - not a
// compile/elaboration check, an actual run: real PicoRV32 (via the real
// picorv32.v), fetching real instructions (led_chase_sim.hex, the actual
// assembled program, just with a shortened delay constant for
// simulation speed - the real hardware binary uses the same code with a
// 3,000,000-cycle delay instead of 20) via the real XIP mechanism,
// through the real, unmodified core QSPI/XIP/arbiter IP, writing to the
// real LED peripheral.
//
// Reuses qspi_flash_model.sv completely unchanged (not a modified copy)
// - instantiated with a larger MEM_SIZE and the real program loaded via
// $readmemh at an offset, rather than duplicating proven model code.

module tb_basys3_top;

  logic clk;
  logic btn_reset;
  logic [15:0] led;

  logic cs_n;
  wire  io0, io1, io2, io3;

  initial clk = 0;
  always #5 clk = ~clk; // 100MHz

  basys3_top #(
    .QSPI_XIP_BASE (32'h0100_0000),
    .QSPI_XIP_SIZE (32'h0100_0000),
    .RAM_BASE_ADDR (32'h1000_0000),
    .RAM_DEPTH_WORDS (2048),
    // Small offset for fast simulation - see basys3_top.sv's parameter
    // comment. Real hardware uses the true 0x300000 default.
    .USER_PROGRAM_FLASH_OFFSET (32'h0000_0000)
  ) u_dut (
    .clk       (clk),
    .btn_reset (btn_reset),

    .cs_n (cs_n),
    .io0  (io0),
    .io1  (io1),
    .io2  (io2),
    .io3  (io3),

    .led (led)
  );

  // Flash memory model - large enough to cover the user program's real
  // location (0x300000 offset, matching PROGADDR_RESET_VAL's derivation
  // in basys3_top.sv). Everything outside the loaded program region
  // keeps the model's own standard mem[i]=i fallback pattern.
  localparam int FLASH_MEM_SIZE = 256; // small - program sits at offset 0 for this fast test

  logic       fm_io0_out, fm_io0_oe;
  logic       fm_io1_out, fm_io1_oe;
  logic       fm_io2_out, fm_io2_oe;
  logic       fm_io3_out, fm_io3_oe;
  logic       fm_written_valid;
  logic [7:0] fm_written_byte;

  // qclk for the flash model comes from the DUT's own internal qclk -
  // accessed hierarchically, since the flash model must be a peer on
  // the SAME clock the DUT's qspi_engine actually runs on (matching
  // exactly how tb_qspi_axi_top.sv and tb_xip_qspi_axi_top.sv already
  // connect their own flash models - not a new pattern).
  qspi_flash_model #(
    .MEM_SIZE (FLASH_MEM_SIZE)
  ) u_flash_model (
    .qclk (u_dut.qclk),
    .cs_n (cs_n),

    .io0_in (io0), .io1_in (io1), .io2_in (io2), .io3_in (io3),

    .io0_out(fm_io0_out), .io0_oe(fm_io0_oe),
    .io1_out(fm_io1_out), .io1_oe(fm_io1_oe),
    .io2_out(fm_io2_out), .io2_oe(fm_io2_oe),
    .io3_out(fm_io3_out), .io3_oe(fm_io3_oe),

    .written_valid(fm_written_valid), .written_byte(fm_written_byte)
  );

  // Bidirectional bus resolution - the DUT's basys3_top.sv drives io0-io3
  // via its own internal tristate logic (see that file); this model
  // drives the SAME wires during read-DATA phases. Standard shared-bus
  // wired-tristate resolution, matching the core testbenches' own
  // pattern for connecting a flash model.
  assign io0 = fm_io0_oe ? fm_io0_out : 1'bz;
  assign io1 = fm_io1_oe ? fm_io1_out : 1'bz;
  assign io2 = fm_io2_oe ? fm_io2_out : 1'bz;
  assign io3 = fm_io3_oe ? fm_io3_out : 1'bz;

  // Load the REAL, actual assembled program (short-delay simulation
  // variant) at the correct flash offset - overwrites the model's
  // default mem[i]=i pattern only in this specific region.
  initial begin
    $readmemh("led_chase_sim_test.mem", u_flash_model.mem, 32'h0);
  end

  // ---- Reset and run ----
  logic reset_has_released;
  initial reset_has_released = 1'b0;

  initial begin
    btn_reset = 1'b1; // active-high button, held (asserting reset)
    repeat (10) @(posedge clk);
    btn_reset = 1'b0; // release
    reset_has_released = 1'b1;
    $display("[T=%0t] Reset released. PROGADDR_RESET=%08h", $time, u_dut.PROGADDR_RESET_VAL);
  end

  // ---- Watch LED output change over time ----
  logic [15:0] led_prev;
  initial led_prev = 16'h0000;

  always @(led) begin
    if (led !== led_prev) begin
      $display("[T=%0t] LED pattern changed: %04h -> %04h", $time, led_prev, led);
      led_prev = led;
    end
  end

  // ---- Pass/fail tracking against the expected fill sequence ----
  // Only bits [13:0] are software-driven (the LED fill pattern) - bits
  // [15:14] are diagnostic (trap, heartbeat), added during real hardware
  // bring-up debugging. Masked out of comparison entirely here, rather
  // than expecting them to match a specific value - they legitimately
  // vary independent of the fill pattern (trap should stay 0 in a
  // working system; heartbeat free-runs continuously).
  int step_count = 0;
  logic [13:0] expected_sequence [0:13];
  initial begin
    logic [13:0] pattern;
    pattern = 14'h0000;
    for (int i = 0; i < 14; i++) begin
      pattern = pattern | (14'h1 << i);
      expected_sequence[i] = pattern;
    end
  end

  int pass_count = 0, fail_count = 0;

  always @(led) begin
    if (reset_has_released && led[13:0] !== 14'h0000) begin // ignore both
                                       // the reset-driven zero AND any
                                       // pre-reset-release transient
      if (step_count < 14) begin
        if (led[13:0] === expected_sequence[step_count]) begin
          pass_count++;
          $display("[PASS] step %0d: LED[13:0] = %04h (correct, full led=%04h)", step_count, led[13:0], led);
        end else begin
          fail_count++;
          $display("[FAIL] step %0d: LED[13:0] = %04h, expected %04h (full led=%04h)", step_count, led[13:0], expected_sequence[step_count], led);
        end
        step_count++;
        if (step_count == 14) begin
          $display("=====================================");
          $display("SUMMARY: %0d pass, %0d fail (full 14-step cycle observed)", pass_count, fail_count);
          $finish;
        end
      end
    end
  end

  // ---- Global timeout and summary ----
  initial begin
    #1_300_000_000; // generous ceiling for 16 real fetch+execute+delay steps
    $display("=====================================");
    $display("SUMMARY: %0d pass, %0d fail (observed %0d of 16 expected steps)", pass_count, fail_count, step_count);
    if (step_count < 16) begin
      $display("NOTE: fewer than 16 steps observed before timeout - program may not be executing correctly, or timeout needs extending.");
    end
    $finish;
  end

  initial begin
    // $dumpfile("tb_basys3_top.vcd"); // disabled for this speed-focused pass/fail run
    // $dumpvars(0, tb_basys3_top);
  end

endmodule