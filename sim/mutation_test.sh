#!/usr/bin/env bash
# Перевірка чутливості тестбенча: у копію RTL вноситься навмисна помилка,
# тестбенч має завершитися TEST FAILED. Використання: bash sim/mutation_test.sh
set -euo pipefail
cd "$(dirname "$0")/.."

OSS="${OSS_CAD:-$LOCALAPPDATA/oss-cad-suite}"
export PATH="$OSS/bin:$OSS/lib:$PATH"
B=build/mut
TB="tb/spi_slave_model.v tb/spi_monitor.v tb/tb_spi_master.v"

# назва | файл | sed-вираз (помилка)
MUTANTS=(
  "spi_tx: передача LSB першим|spi_tx.v|s/assign mosi = shreg\[7\];/assign mosi = shreg[0];/; s/shreg <= {shreg\[6:0\], 1'b0};/shreg <= {1'b0, shreg[7:1]};/"
  "spi_master: вибірка завжди на передньому фронті (CPHA ігнорується)|spi_master.v|s/wire rx_sample = edge_now && (lead ^ cpha_r);/wire rx_sample = edge_now \&\& lead;/"
  "spi_master: рівень спокою SCLK завжди 0 (CPOL ігнорується)|spi_master.v|s/sclk <= cmd_cpol;/sclk <= 1'b0;/"
  "spi_rx: байт видається після 7 бітів|spi_rx.v|s/if (bitn == 3'd7) begin/if (bitn == 3'd6) begin/"
  "spi_master: SS_n піднімається одразу після останнього фронту (t_lag = 0)|spi_master.v|s/if (left == 8'd0) state <= S_LAG;/if (left == 8'd0) begin state <= S_GAP; ss_n <= 1'b1; end/"
)

mkdir -p "$B"
printf "%s\n" "| Внесена помилка | Результат тестбенча |" > "$B/summary.md"
all_caught=1
i=0
for m in "${MUTANTS[@]}"; do
    i=$((i + 1))
    IFS='|' read -r name file expr <<< "$m"
    d="$B/m$i"
    rm -rf "$d"; mkdir -p "$d"
    cp rtl/*.v "$d/"
    sed -i "$expr" "$d/$file"
    if cmp -s "rtl/$file" "$d/$file"; then
        echo "M$i: mutation not applied ($name)"; exit 2
    fi
    iverilog -g2005 -s tb_spi_master -P tb_spi_master.SCLK_FREQ=1000000 -o "$d/tb.vvp" \
        "$d/spi_tx.v" "$d/spi_rx.v" "$d/spi_master.v" "$d/spi_master_top.v" $TB
    vvp -n "$d/tb.vvp" +vcd="$d/tb.vcd" > "$d/sim.log" 2>&1 || true
    result=$(grep -E "==== TEST (PASSED|FAILED)" "$d/sim.log" | tail -1 | sed 's/==== //')
    echo "M$i: $name -> $result"
    printf "| %s | %s |\n" "$name" "$result" >> "$B/summary.md"
    case "$result" in *FAILED*) ;; *) all_caught=0 ;; esac
done
[ $all_caught -eq 1 ] && echo "MUTATION TEST: all $i mutants detected" || { echo "MUTATION TEST: some mutants survived"; exit 1; }
