## basys3_top.xdc
##
## Constraints for basys3_top.sv. Every pin number below verified against
## Digilent's own official Basys3-Master.xdc and reference manual, not
## assumed.
##
## IMPORTANT: there is deliberately NO pin constraint for the QSPI flash
## clock here. On Basys 3, the flash chip's SCLK pin is wired to the
## FPGA's dedicated configuration clock (CCLK) - per Xilinx 7-series
## devices, this CANNOT be reached via an ordinary I/O pin constraint at
## all. basys3_top.sv already handles this internally via the STARTUPE2
## primitive (see that file's header comments) - do not add a PACKAGE_PIN
## constraint for a flash clock signal here, there is no top-level port
## for it to attach to.

## ---- Clock (100MHz onboard oscillator) ----
set_property -dict { PACKAGE_PIN W5   IOSTANDARD LVCMOS33 } [get_ports { clk }];
create_clock -add -name sys_clk_pin -period 10.00 -waveform {0 5} [get_ports { clk }];

## ---- Reset (BTNC, center pushbutton) ----
## btn_reset is active-HIGH (matching the physical button - it reads
## high when pressed), inverted internally in basys3_top.sv to produce
## the active-low resetn used throughout the rest of the design.
set_property -dict { PACKAGE_PIN U18  IOSTANDARD LVCMOS33 } [get_ports { btn_reset }];

## ---- LEDs (LD15 downto LD0, MSB to LSB) ----
set_property -dict { PACKAGE_PIN L1   IOSTANDARD LVCMOS33 } [get_ports { led[15] }];
set_property -dict { PACKAGE_PIN P1   IOSTANDARD LVCMOS33 } [get_ports { led[14] }];
set_property -dict { PACKAGE_PIN N3   IOSTANDARD LVCMOS33 } [get_ports { led[13] }];
set_property -dict { PACKAGE_PIN P3   IOSTANDARD LVCMOS33 } [get_ports { led[12] }];
set_property -dict { PACKAGE_PIN U3   IOSTANDARD LVCMOS33 } [get_ports { led[11] }];
set_property -dict { PACKAGE_PIN W3   IOSTANDARD LVCMOS33 } [get_ports { led[10] }];
set_property -dict { PACKAGE_PIN V3   IOSTANDARD LVCMOS33 } [get_ports { led[9]  }];
set_property -dict { PACKAGE_PIN V13  IOSTANDARD LVCMOS33 } [get_ports { led[8]  }];
set_property -dict { PACKAGE_PIN V14  IOSTANDARD LVCMOS33 } [get_ports { led[7]  }];
set_property -dict { PACKAGE_PIN U14  IOSTANDARD LVCMOS33 } [get_ports { led[6]  }];
set_property -dict { PACKAGE_PIN U15  IOSTANDARD LVCMOS33 } [get_ports { led[5]  }];
set_property -dict { PACKAGE_PIN W18  IOSTANDARD LVCMOS33 } [get_ports { led[4]  }];
set_property -dict { PACKAGE_PIN V19  IOSTANDARD LVCMOS33 } [get_ports { led[3]  }];
set_property -dict { PACKAGE_PIN U19  IOSTANDARD LVCMOS33 } [get_ports { led[2]  }];
set_property -dict { PACKAGE_PIN E19  IOSTANDARD LVCMOS33 } [get_ports { led[1]  }];
set_property -dict { PACKAGE_PIN U16  IOSTANDARD LVCMOS33 } [get_ports { led[0]  }];

## ---- Seven-segment display (4-digit, common-anode, multiplexed) ----
## Both segments AND anodes are active-LOW on this board specifically -
## confirmed directly against Digilent's own reference manual: "since
## Basys3 uses transistors to drive enough current into the common anode
## point, the anode enables are inverted. Therefore, both the AN0..3 and
## the CA..G/DP signals are driven low when active." This differs from
## the generic textbook common-anode convention (active-high anode) -
## seven_seg.sv's internal logic already accounts for this correctly.
set_property -dict { PACKAGE_PIN W7   IOSTANDARD LVCMOS33 } [get_ports { seg[0] }];
set_property -dict { PACKAGE_PIN W6   IOSTANDARD LVCMOS33 } [get_ports { seg[1] }];
set_property -dict { PACKAGE_PIN U8   IOSTANDARD LVCMOS33 } [get_ports { seg[2] }];
set_property -dict { PACKAGE_PIN V8   IOSTANDARD LVCMOS33 } [get_ports { seg[3] }];
set_property -dict { PACKAGE_PIN U5   IOSTANDARD LVCMOS33 } [get_ports { seg[4] }];
set_property -dict { PACKAGE_PIN V5   IOSTANDARD LVCMOS33 } [get_ports { seg[5] }];
set_property -dict { PACKAGE_PIN U7   IOSTANDARD LVCMOS33 } [get_ports { seg[6] }];
set_property -dict { PACKAGE_PIN V7   IOSTANDARD LVCMOS33 } [get_ports { dp }];
set_property -dict { PACKAGE_PIN U2   IOSTANDARD LVCMOS33 } [get_ports { an[0] }];
set_property -dict { PACKAGE_PIN U4   IOSTANDARD LVCMOS33 } [get_ports { an[1] }];
set_property -dict { PACKAGE_PIN V4   IOSTANDARD LVCMOS33 } [get_ports { an[2] }];
set_property -dict { PACKAGE_PIN W4   IOSTANDARD LVCMOS33 } [get_ports { an[3] }];

## ---- QSPI flash: data lines and chip-select ONLY - see clock note above ----
## io0-io3 are real, single bidirectional (inout) ports in basys3_top.sv -
## each one physical pin, with tristate logic handled internally in RTL,
## not left for this file to merge two separate ports onto one pad
## (confirmed that doesn't happen automatically - see basys3_top.sv).
set_property -dict { PACKAGE_PIN D18  IOSTANDARD LVCMOS33 } [get_ports { io0 }];
set_property -dict { PACKAGE_PIN D19  IOSTANDARD LVCMOS33 } [get_ports { io1 }];
set_property -dict { PACKAGE_PIN G18  IOSTANDARD LVCMOS33 } [get_ports { io2 }];
set_property -dict { PACKAGE_PIN F18  IOSTANDARD LVCMOS33 } [get_ports { io3 }];
set_property -dict { PACKAGE_PIN K19  IOSTANDARD LVCMOS33 } [get_ports { cs_n }];

## ---- Configuration options ----
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property CFGBVS VCCO [current_design]

## ---- SPI configuration mode options for QSPI boot ----
## Taken directly from Digilent's own official Basys-3-Master.xdc -
## these weren't in the earlier version of this file.
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 33 [current_design]
set_property CONFIG_MODE SPIx4 [current_design]