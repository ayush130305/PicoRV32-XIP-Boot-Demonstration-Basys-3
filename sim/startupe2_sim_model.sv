// startupe2_sim_model.sv
// Simulation-only stub for the Xilinx STARTUPE2 primitive, so the design elaborates in non-Vivado simulators (Icarus/Verilator). Not for synthesis.
module STARTUPE2 #(
  parameter PROG_USR = "FALSE",   // This holds the PROG_USR attribute (unused in simulation)
  parameter real SIM_CCLK_FREQ = 0.0 // This holds the simulated CCLK frequency (unused here)
)(
  output CFGCLK, output CFGMCLK, output EOS, output PREQ,   // This holds the unused status outputs
  input  CLK, input GSR, input GTS, input KEYCLEARB,         // This holds the unused control inputs
  input  PACK, input USRCCLKO, input USRCCLKTS,              // This holds the user CCLK drive and its tristate
  input  USRDONEO, input USRDONETS                           // This holds the user DONE drive and its tristate
);
  assign CFGCLK  = 1'b0; // Unused status tied low
  assign CFGMCLK = 1'b0; // Unused status tied low
  assign EOS     = 1'b1; // Startup always reported complete in simulation
  assign PREQ    = 1'b0; // No program request in simulation
endmodule
