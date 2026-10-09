#!/usr/bin/env bash
# Runs every testbench with Icarus Verilog 12 and prints each SUMMARY line.
# Usage: bash run_all.sh   (needs iverilog + vvp on PATH)
set -u
cd "$(dirname "$0")"
mkdir -p build
CORE="../rtl/qspi/qspi_axi_pkg.sv ../rtl/cdc/pulse_sync.sv ../rtl/cdc/cdc_bridge.sv ../rtl/qspi/qspi_engine.sv ../rtl/qspi/qspi_arbiter.sv ../rtl/axi/axi4L_slave.sv ../rtl/xip/qspi_xip_slave.sv ../rtl/axi/qspi_unified_slave.sv ../rtl/qspi_axi_top.sv"
run() {  # run <top> <tb file> <extra sources...>
  top=$1; tb=$2; shift 2
  iverilog -g2012 -s "$top" -o "build/$top.vvp" "$@" "$tb" >build/"$top".compile.log 2>&1 || { echo "$top: COMPILE FAILED (see build/$top.compile.log)"; return; }
  echo "$top: $(vvp "build/$top.vvp" 2>&1 | grep SUMMARY | tail -1)"
}
# System test: real PicoRV32 running the demo program from the flash model
run tb_basys3_top tb_basys3_top.sv -f filelist_system.f ../emu/qspi_flash_model.sv
# Core suites
run tb_qspi_axi_top tb_qspi_axi_top.sv startupe2_sim_model.sv $CORE ../emu/qspi_flash_model.sv
run tb_xip_qspi_axi_top tb_xip_qspi_axi_top.sv startupe2_sim_model.sv $CORE ../emu/qspi_flash_model.sv
run tb_sram tb_sram.sv ../rtl/qspi/qspi_axi_pkg.sv ../rtl/system/sram.sv
