// =============================================================================
// spi_master_top.v — верхній рівень SPI Master для синтезу та тестбенча.
// -----------------------------------------------------------------------------
// Лабораторна робота №3, варіант 12 (SPI, Verilog). Кулинський Я.О., КІ-408.
//
// Обгортка над ядром spi_master: фіксує параметри частот і виводить порти
// шини SPI (SCLK, MOSI, MISO, SS_n) та командний інтерфейс. Режим (CPOL/CPHA)
// і кількість байтів задаються на кожну транзакцію.
//
// Приклад: CLK_FREQ = 50 МГц, SCLK_FREQ = 1 МГц -> HALF = 25 тактів,
//          f_SCLK = 50 МГц / (2 * 25) = 1.000 МГц.
// =============================================================================
`timescale 1ns / 1ps
`default_nettype none

module spi_master_top #(
    parameter integer CLK_FREQ  = 50_000_000,   // частота clk, Гц
    parameter integer SCLK_FREQ = 1_000_000     // частота SCLK, Гц (<= CLK_FREQ / 4)
) (
    input  wire       clk,
    input  wire       rst_n,        // синхронне скидання, активний 0

    // ---- командний інтерфейс ----
    input  wire       cmd_start,    // імпульс: почати транзакцію
    input  wire [1:0] cmd_mode,     // режим SPI: {CPOL, CPHA}, 0..3
    input  wire [7:0] cmd_len,      // кількість байтів (0 = 1)
    input  wire [7:0] tx_data,      // байт для передачі
    output wire       tx_req,       // імпульс: виставити наступний tx_data
    output wire [7:0] rx_data,      // прийнятий байт
    output wire       rx_valid,     // імпульс: rx_data дійсний
    output wire       busy,         // 1 — транзакція триває
    output wire       done,         // імпульс: транзакцію завершено

    // ---- шина SPI ----
    output wire       sclk,         // тактовий сигнал
    output wire       mosi,         // Master Out, Slave In
    input  wire       miso,         // Master In, Slave Out
    output wire       ss_n          // вибір веденого, активний 0
);

    spi_master #(
        .CLK_FREQ  (CLK_FREQ),
        .SCLK_FREQ (SCLK_FREQ)
    ) u_core (
        .clk       (clk),
        .rst_n     (rst_n),
        .cmd_start (cmd_start),
        .cmd_cpol  (cmd_mode[1]),
        .cmd_cpha  (cmd_mode[0]),
        .cmd_len   (cmd_len),
        .tx_data   (tx_data),
        .tx_req    (tx_req),
        .rx_data   (rx_data),
        .rx_valid  (rx_valid),
        .busy      (busy),
        .done      (done),
        .sclk      (sclk),
        .mosi      (mosi),
        .miso      (miso),
        .ss_n      (ss_n)
    );

endmodule

`default_nettype wire
