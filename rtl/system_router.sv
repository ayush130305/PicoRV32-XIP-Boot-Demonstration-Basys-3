// system_router.sv
//
// Routes PicoRV32's single AXI4-Lite master port to one of three slave
// destinations based on address: the QSPI IP's unified port
// (qspi_unified_slave.sv, covering both its register map AND the XIP
// window internally), the LED peripheral, or the on-chip RAM
// (sram_peripheral.sv). All three destinations accept both reads and
// writes (unlike the earlier register/XIP merge inside qspi_axi_top.sv,
// where XIP never accepted writes), so this router needs full 5-channel
// decoding on every path.
//
// Address map (must match basys3_top.sv's instantiation parameters):
//   0x0000_0000 - 0x0000_001B  : QSPI IP register bank
//   0x0100_0000 - 0x01FF_FFFF  : QSPI IP XIP window
//   0x0200_0000 - 0x0200_0003  : LED peripheral (one register)
//   0x1000_0000 - 0x1000_1FFF  : on-chip RAM (8KB, PicoRV32 stack/data)
//   anything else              : DECERR, direct response, never forwarded

module system_router #(
  parameter logic [31:0] QSPI_XIP_BASE = 32'h0100_0000,
  parameter logic [31:0] QSPI_XIP_SIZE = 32'h0100_0000,
  parameter logic [31:0] QSPI_REG_TOP  = 32'h0000_001B, // last valid QSPI register byte address
  parameter logic [31:0] LED_BASE      = 32'h0200_0000,
  parameter logic [31:0] LED_TOP       = 32'h0200_0003,
  parameter logic [31:0] RAM_BASE      = 32'h1000_0000,
  parameter logic [31:0] RAM_TOP       = 32'h1000_1FFF
)(
  input  logic        ACLK,
  input  logic        ARESETn,

  // From PicoRV32 (picorv32_axi's mem_axi_* port)
  input  logic [31:0] M_AXI_AWADDR,
  input  logic        M_AXI_AWVALID,
  output logic        M_AXI_AWREADY,
  input  logic [31:0] M_AXI_WDATA,
  input  logic [3:0]  M_AXI_WSTRB,
  input  logic        M_AXI_WVALID,
  output logic        M_AXI_WREADY,
  output logic [1:0]  M_AXI_BRESP,
  output logic        M_AXI_BVALID,
  input  logic        M_AXI_BREADY,
  input  logic [31:0] M_AXI_ARADDR,
  input  logic        M_AXI_ARVALID,
  output logic        M_AXI_ARREADY,
  output logic [31:0] M_AXI_RDATA,
  output logic [1:0]  M_AXI_RRESP,
  output logic        M_AXI_RVALID,
  input  logic        M_AXI_RREADY,

  // To the QSPI IP's unified port
  output logic [31:0] QSPI_AWADDR,
  output logic        QSPI_AWVALID,
  input  logic        QSPI_AWREADY,
  output logic [31:0] QSPI_WDATA,
  output logic [3:0]  QSPI_WSTRB,
  output logic        QSPI_WVALID,
  input  logic        QSPI_WREADY,
  input  logic [1:0]  QSPI_BRESP,
  input  logic        QSPI_BVALID,
  output logic        QSPI_BREADY,
  output logic [31:0] QSPI_ARADDR,
  output logic        QSPI_ARVALID,
  input  logic        QSPI_ARREADY,
  input  logic [31:0] QSPI_RDATA,
  input  logic [1:0]  QSPI_RRESP,
  input  logic        QSPI_RVALID,
  output logic        QSPI_RREADY,

  // To the LED peripheral
  output logic [31:0] LED_AWADDR,
  output logic        LED_AWVALID,
  input  logic        LED_AWREADY,
  output logic [31:0] LED_WDATA,
  output logic [3:0]  LED_WSTRB,
  output logic        LED_WVALID,
  input  logic        LED_WREADY,
  input  logic [1:0]  LED_BRESP,
  input  logic        LED_BVALID,
  output logic        LED_BREADY,
  output logic [31:0] LED_ARADDR,
  output logic        LED_ARVALID,
  input  logic        LED_ARREADY,
  input  logic [31:0] LED_RDATA,
  input  logic [1:0]  LED_RRESP,
  input  logic        LED_RVALID,
  output logic        LED_RREADY,

  // To the on-chip RAM
  output logic [31:0] RAM_AWADDR,
  output logic        RAM_AWVALID,
  input  logic        RAM_AWREADY,
  output logic [31:0] RAM_WDATA,
  output logic [3:0]  RAM_WSTRB,
  output logic        RAM_WVALID,
  input  logic        RAM_WREADY,
  input  logic [1:0]  RAM_BRESP,
  input  logic        RAM_BVALID,
  output logic        RAM_BREADY,
  output logic [31:0] RAM_ARADDR,
  output logic        RAM_ARVALID,
  input  logic        RAM_ARREADY,
  input  logic [31:0] RAM_RDATA,
  input  logic [1:0]  RAM_RRESP,
  input  logic        RAM_RVALID,
  output logic        RAM_RREADY
);

  typedef enum logic [2:0] {DEST_QSPI, DEST_LED, DEST_RAM, DEST_INVALID} dest_t;

  function automatic dest_t decode(logic [31:0] addr);
    if (addr <= QSPI_REG_TOP) return DEST_QSPI;
    if (addr >= QSPI_XIP_BASE && addr < (QSPI_XIP_BASE + QSPI_XIP_SIZE)) return DEST_QSPI;
    if (addr >= LED_BASE && addr <= LED_TOP) return DEST_LED;
    if (addr >= RAM_BASE && addr <= RAM_TOP) return DEST_RAM;
    return DEST_INVALID;
  endfunction

  // ---- Write channels ----
  dest_t waddr_dest;
  assign waddr_dest = decode(M_AXI_AWADDR);

  assign QSPI_AWADDR  = M_AXI_AWADDR;
  assign LED_AWADDR   = M_AXI_AWADDR;
  assign RAM_AWADDR   = M_AXI_AWADDR;
  assign QSPI_AWVALID = M_AXI_AWVALID && (waddr_dest == DEST_QSPI);
  assign LED_AWVALID  = M_AXI_AWVALID && (waddr_dest == DEST_LED);
  assign RAM_AWVALID  = M_AXI_AWVALID && (waddr_dest == DEST_RAM);

  assign QSPI_WDATA  = M_AXI_WDATA;
  assign LED_WDATA   = M_AXI_WDATA;
  assign RAM_WDATA   = M_AXI_WDATA;
  assign QSPI_WSTRB  = M_AXI_WSTRB;
  assign LED_WSTRB   = M_AXI_WSTRB;
  assign RAM_WSTRB   = M_AXI_WSTRB;
  // WVALID gated the same way as AWVALID - see the same note in the
  // original 2-destination version of this file: this assumes a master
  // that presents AW and W together (PicoRV32's adapter does). A master
  // that splits them across cycles would need WVALID gated by a latched
  // target instead, mirroring the read-channel pattern below.
  assign QSPI_WVALID = M_AXI_WVALID && (waddr_dest == DEST_QSPI);
  assign LED_WVALID  = M_AXI_WVALID && (waddr_dest == DEST_LED);
  assign RAM_WVALID  = M_AXI_WVALID && (waddr_dest == DEST_RAM);

  assign M_AXI_AWREADY = (waddr_dest == DEST_INVALID) ? 1'b1 :
                          (waddr_dest == DEST_LED)     ? LED_AWREADY :
                          (waddr_dest == DEST_RAM)     ? RAM_AWREADY : QSPI_AWREADY;
  assign M_AXI_WREADY  = (waddr_dest == DEST_INVALID) ? 1'b1 :
                          (waddr_dest == DEST_LED)     ? LED_WREADY :
                          (waddr_dest == DEST_RAM)     ? RAM_WREADY : QSPI_WREADY;

  dest_t write_target;
  logic  invalid_bresp_pending;

  always_ff @(posedge ACLK or negedge ARESETn) begin
    if (!ARESETn) begin
      write_target           <= DEST_QSPI;
      invalid_bresp_pending  <= 1'b0;
    end else begin
      if (M_AXI_AWVALID && M_AXI_AWREADY) begin
        write_target          <= waddr_dest;
        invalid_bresp_pending <= (waddr_dest == DEST_INVALID);
      end else if (invalid_bresp_pending && M_AXI_BREADY) begin
        invalid_bresp_pending <= 1'b0;
      end
    end
  end

  assign M_AXI_BRESP  = (write_target == DEST_INVALID) ? 2'b10 : // DECERR
                         (write_target == DEST_LED)     ? LED_BRESP :
                         (write_target == DEST_RAM)     ? RAM_BRESP : QSPI_BRESP;
  assign M_AXI_BVALID = (write_target == DEST_INVALID) ? invalid_bresp_pending :
                         (write_target == DEST_LED)     ? LED_BVALID :
                         (write_target == DEST_RAM)     ? RAM_BVALID : QSPI_BVALID;
  assign QSPI_BREADY  = (write_target == DEST_QSPI) ? M_AXI_BREADY : 1'b0;
  assign LED_BREADY   = (write_target == DEST_LED)  ? M_AXI_BREADY : 1'b0;
  assign RAM_BREADY   = (write_target == DEST_RAM)  ? M_AXI_BREADY : 1'b0;

  // ---- Read channels ----
  dest_t raddr_dest;
  assign raddr_dest = decode(M_AXI_ARADDR);

  assign QSPI_ARADDR  = M_AXI_ARADDR;
  assign LED_ARADDR   = M_AXI_ARADDR;
  assign RAM_ARADDR   = M_AXI_ARADDR;
  assign QSPI_ARVALID = M_AXI_ARVALID && (raddr_dest == DEST_QSPI);
  assign LED_ARVALID  = M_AXI_ARVALID && (raddr_dest == DEST_LED);
  assign RAM_ARVALID  = M_AXI_ARVALID && (raddr_dest == DEST_RAM);
  assign M_AXI_ARREADY = (raddr_dest == DEST_INVALID) ? 1'b1 :
                          (raddr_dest == DEST_LED)     ? LED_ARREADY :
                          (raddr_dest == DEST_RAM)     ? RAM_ARREADY : QSPI_ARREADY;

  dest_t read_target;
  logic  invalid_rresp_pending;

  always_ff @(posedge ACLK or negedge ARESETn) begin
    if (!ARESETn) begin
      read_target            <= DEST_QSPI;
      invalid_rresp_pending  <= 1'b0;
    end else begin
      if (M_AXI_ARVALID && M_AXI_ARREADY) begin
        read_target            <= raddr_dest;
        invalid_rresp_pending  <= (raddr_dest == DEST_INVALID);
      end else if (invalid_rresp_pending && M_AXI_RREADY) begin
        invalid_rresp_pending <= 1'b0;
      end
    end
  end

  assign M_AXI_RDATA  = (read_target == DEST_LED) ? LED_RDATA :
                         (read_target == DEST_RAM) ? RAM_RDATA : QSPI_RDATA;
  assign M_AXI_RRESP  = (read_target == DEST_INVALID) ? 2'b10 : // DECERR
                         (read_target == DEST_LED)     ? LED_RRESP :
                         (read_target == DEST_RAM)     ? RAM_RRESP : QSPI_RRESP;
  assign M_AXI_RVALID = (read_target == DEST_INVALID) ? invalid_rresp_pending :
                         (read_target == DEST_LED)     ? LED_RVALID :
                         (read_target == DEST_RAM)     ? RAM_RVALID : QSPI_RVALID;
  assign QSPI_RREADY  = (read_target == DEST_QSPI) ? M_AXI_RREADY : 1'b0;
  assign LED_RREADY   = (read_target == DEST_LED)  ? M_AXI_RREADY : 1'b0;
  assign RAM_RREADY   = (read_target == DEST_RAM)  ? M_AXI_RREADY : 1'b0;

endmodule