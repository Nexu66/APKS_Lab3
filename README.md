# APKS_Lab3 — SPI Master на Verilog

Лабораторна робота №3 з дисципліни «Автоматизоване проєктування комп’ютерних систем»:
**«Розробка та верифікація послідовних комунікаційних протоколів на ПЛІС»**.

| Поле | Значення |
|---|---|
| Студент | Кулинський Ярослав Олегович, група КІ-408 |
| Варіант | 12: **SPI, Verilog** |
| Симуляція | Icarus Verilog (OSS CAD Suite) |
| Синтез | Yosys + nextpnr: Lattice iCE40-HX8K (CT256), ECP5 LFE5U-25F (CABGA256), 50 МГц |
| Викладач | Чапля О.Ю. |

## Модуль

SPI Master з окремими передавачем (Tx) і приймачем (Rx):

- усі 4 режими SPI (CPOL/CPHA) задаються на кожну транзакцію;
- транзакція з 1–255 байтів без пауз між байтами, SS_n утримується в 0;
- дільник частоти: `SCLK_FREQ ≤ CLK_FREQ / 4` (12.5 МГц при 50 МГц), перевірка під час елаборації;
- t_lead, t_lag і мінімальний час SS_n = 1 між транзакціями — по половині періоду SCLK.

| Файл | Призначення |
|---|---|
| `rtl/spi_master_top.v` | верхній рівень: параметри, порти шини і команд |
| `rtl/spi_master.v` | ядро: дільник SCLK, автомат IDLE → LEAD → XFER → LAG → GAP, керування Tx/Rx |
| `rtl/spi_tx.v` | передавач: байт → MOSI, MSB first |
| `rtl/spi_rx.v` | приймач: MISO → байт, імпульс rx_valid |
| `tb/tb_spi_master.v` | самоперевірний тестбенч, сценарії T1–T8 |
| `tb/spi_slave_model.v` | модель веденого SPI (усі режими, затримка MISO t_V = 8 нс) |
| `tb/spi_monitor.v` | незалежний монітор шини: розкодування і часові параметри |

## Запуск

Потрібен [OSS CAD Suite](https://github.com/YosysHQ/oss-cad-suite-build) (iverilog, yosys, nextpnr) і Python 3 з matplotlib.

```bash
bash sim/run_sim.sh            # симуляція: SCLK 1 МГц і 12.5 МГц -> TEST PASSED
bash sim/mutation_test.sh      # тестбенч виявляє навмисні помилки в RTL
python sim/plot_waves.py build/sim/tb_1000000.vcd build/sim/tb_12500000.vcd docs/img
bash syn/synth.sh              # синтез iCE40 / ECP5, Fmax, симуляція нетліста
```

VCD-файли (`build/sim/*.vcd`) можна відкрити в GTKWave.
