#!/usr/bin/env bash
# Функціональна верифікація SPI Master в Icarus Verilog:
# SCLK = 1 МГц (типовий режим) і 12.5 МГц (максимум для CLK = 50 МГц), VCD для осцилограм.
# Використання: bash sim/run_sim.sh
set -euo pipefail
cd "$(dirname "$0")/.."

OSS="${OSS_CAD:-$LOCALAPPDATA/oss-cad-suite}"
export PATH="$OSS/bin:$OSS/lib:$PATH"

B=build/sim
mkdir -p "$B"
RTL="rtl/spi_tx.v rtl/spi_rx.v rtl/spi_master.v rtl/spi_master_top.v"
TB="tb/spi_slave_model.v tb/spi_monitor.v tb/tb_spi_master.v"

status=0
for F in 1000000 12500000; do
    echo "---- SCLK_FREQ = $F Hz"
    iverilog -g2005 -Wall -s tb_spi_master -P tb_spi_master.SCLK_FREQ=$F -o "$B/tb_$F.vvp" $RTL $TB
    vvp -n "$B/tb_$F.vvp" +vcd="$B/tb_$F.vcd" | tee "$B/sim_$F.log"
    grep -q "TEST PASSED" "$B/sim_$F.log" || status=1
done
exit $status
