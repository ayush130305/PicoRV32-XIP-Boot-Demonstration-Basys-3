module tb_sram;

  logic ACLK, ARESETn;
  logic [31:0] S_AXI_AWADDR;
  logic        S_AXI_AWVALID, S_AXI_AWREADY;
  logic [31:0] S_AXI_WDATA;
  logic [3:0]  S_AXI_WSTRB;
  logic        S_AXI_WVALID, S_AXI_WREADY;
  logic [1:0]  S_AXI_BRESP;
  logic        S_AXI_BVALID, S_AXI_BREADY;
  logic [31:0] S_AXI_ARADDR;
  logic        S_AXI_ARVALID, S_AXI_ARREADY;
  logic [31:0] S_AXI_RDATA;
  logic [1:0]  S_AXI_RRESP;
  logic        S_AXI_RVALID, S_AXI_RREADY;

  initial ACLK = 0;
  always #5 ACLK = ~ACLK;

  sram #(.DEPTH_WORDS(2048)) u_dut (
    .ACLK(ACLK), .ARESETn(ARESETn),
    .S_AXI_AWADDR(S_AXI_AWADDR), .S_AXI_AWVALID(S_AXI_AWVALID), .S_AXI_AWREADY(S_AXI_AWREADY),
    .S_AXI_WDATA(S_AXI_WDATA), .S_AXI_WSTRB(S_AXI_WSTRB), .S_AXI_WVALID(S_AXI_WVALID), .S_AXI_WREADY(S_AXI_WREADY),
    .S_AXI_BRESP(S_AXI_BRESP), .S_AXI_BVALID(S_AXI_BVALID), .S_AXI_BREADY(S_AXI_BREADY),
    .S_AXI_ARADDR(S_AXI_ARADDR), .S_AXI_ARVALID(S_AXI_ARVALID), .S_AXI_ARREADY(S_AXI_ARREADY),
    .S_AXI_RDATA(S_AXI_RDATA), .S_AXI_RRESP(S_AXI_RRESP), .S_AXI_RVALID(S_AXI_RVALID), .S_AXI_RREADY(S_AXI_RREADY)
  );

  task automatic axi_write(input logic [31:0] addr, input logic [31:0] data, input logic [3:0] strb);
    logic aw_done = 0, w_done = 0;
    @(posedge ACLK); #1;
    S_AXI_AWADDR = addr; S_AXI_AWVALID = 1'b1;
    S_AXI_WDATA  = data; S_AXI_WSTRB = strb; S_AXI_WVALID = 1'b1;
    while (!(aw_done && w_done)) begin
      @(posedge ACLK);
      if (S_AXI_AWVALID && S_AXI_AWREADY) aw_done = 1;
      if (S_AXI_WVALID && S_AXI_WREADY) w_done = 1;
    end
    @(posedge ACLK); S_AXI_AWVALID <= 0; S_AXI_WVALID <= 0;
    @(posedge ACLK); S_AXI_BREADY <= 1;
    while (!S_AXI_BVALID) @(posedge ACLK);
    @(posedge ACLK); S_AXI_BREADY <= 0;
  endtask

  task automatic axi_read(input logic [31:0] addr, output logic [31:0] data);
    logic ar_done = 0;
    @(posedge ACLK); #1;
    S_AXI_ARADDR = addr; S_AXI_ARVALID = 1'b1;
    while (!ar_done) begin
      @(posedge ACLK);
      if (S_AXI_ARVALID && S_AXI_ARREADY) ar_done = 1;
    end
    @(posedge ACLK); S_AXI_ARVALID <= 0;
    @(posedge ACLK); S_AXI_RREADY <= 1;
    while (!S_AXI_RVALID) @(posedge ACLK);
    data = S_AXI_RDATA;
    @(posedge ACLK); S_AXI_RREADY <= 0;
  endtask

  int pass_count = 0, fail_count = 0;
  task automatic report(input string name, input bit ok, input string detail = "");
    if (ok) begin pass_count++; $display("[PASS] %s %s", name, detail); end
    else begin fail_count++; $display("[FAIL] %s %s", name, detail); end
  endtask

  initial begin
    logic [31:0] rdata;

    ARESETn = 0; S_AXI_AWVALID=0; S_AXI_WVALID=0; S_AXI_BREADY=0; S_AXI_ARVALID=0; S_AXI_RREADY=0;
    repeat (5) @(posedge ACLK);
    ARESETn = 1;
    repeat (5) @(posedge ACLK);

    // ---- 1. Basic write-then-read, full word ----
    axi_write(32'h0000_0000, 32'hDEADBEEF, 4'b1111);
    axi_read(32'h0000_0000, rdata);
    report("basic_write_then_read", rdata === 32'hDEADBEEF,
           $sformatf("(got %08h, expected DEADBEEF)", rdata));

    // ---- 2. Different address doesn't alias ----
    axi_write(32'h0000_0004, 32'h12345678, 4'b1111);
    axi_read(32'h0000_0000, rdata);
    report("no_address_aliasing_addr0", rdata === 32'hDEADBEEF,
           $sformatf("(addr 0 unaffected by addr 4 write, got %08h)", rdata));
    axi_read(32'h0000_0004, rdata);
    report("no_address_aliasing_addr4", rdata === 32'h12345678,
           $sformatf("(got %08h, expected 12345678)", rdata));

    // ---- 3. Byte-enable write: only touch byte 0 ----
    axi_write(32'h0000_0008, 32'hFFFFFFFF, 4'b1111); // seed all-ones
    axi_write(32'h0000_0008, 32'h000000AA, 4'b0001); // only byte 0
    axi_read(32'h0000_0008, rdata);
    report("byte_enable_lane0_only", rdata === 32'hFFFFFFAA,
           $sformatf("(got %08h, expected FFFFFFAA - only byte 0 changed)", rdata));

    // ---- 4. Byte-enable write: only touch byte 2 ----
    axi_write(32'h0000_000C, 32'h00000000, 4'b1111); // seed all-zeros
    axi_write(32'h0000_000C, 32'h00BB0000, 4'b0100); // only byte 2
    axi_read(32'h0000_000C, rdata);
    report("byte_enable_lane2_only", rdata === 32'h00BB0000,
           $sformatf("(got %08h, expected 00BB0000 - only byte 2 changed)", rdata));

    // ---- 5. Back-to-back reads, different addresses, no delay ----
    begin
      logic [31:0] r0, r1;
      axi_read(32'h0000_0000, r0);
      axi_read(32'h0000_0004, r1);
      report("back_to_back_reads", (r0 === 32'hDEADBEEF) && (r1 === 32'h12345678),
             $sformatf("(r0=%08h r1=%08h)", r0, r1));
    end

    // ---- 6. Write near the top of the address range ----
    begin
      logic [31:0] top_addr = 32'h0000_1FFC; // last word, 2048 words = 0x1FFC top
      axi_write(top_addr, 32'hCAFEF00D, 4'b1111);
      axi_read(top_addr, rdata);
      report("top_of_range_write_read", rdata === 32'hCAFEF00D,
             $sformatf("(got %08h, expected CAFEF00D)", rdata));
    end

    $display("=====================================");
    $display("SUMMARY: %0d pass, %0d fail", pass_count, fail_count);
    $finish;
  end

endmodule
