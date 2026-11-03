// =============================================================================
// spi_tx.v — передавач SPI (Tx): паралельний байт -> послідовний потік MOSI.
// -----------------------------------------------------------------------------
// Лабораторна робота №3, варіант 12 (SPI, Verilog). Кулинський Я.О., КІ-408.
//
// Байт передається старшим бітом уперед (MSB first). Вихід MOSI — старший
// розряд зсувного регістра, тому біт з'являється на лінії одразу після
// завантаження (load) або зсуву (shift). Моменти load/shift вибирає ядро
// spi_master залежно від фази тактування CPHA:
//   CPHA = 0: load — до першого фронту SCLK, shift — на задньому (trailing) фронті;
//   CPHA = 1: load і shift — на передньому (leading) фронті кожного біта.
// Стан передавача задають прапорець active і номер біта bitn на лінії
// (0 — MSB ... 7 — LSB).
// =============================================================================
`timescale 1ns / 1ps
`default_nettype none

module spi_tx (
    input  wire       clk,      // системна частота
    input  wire       rst_n,    // синхронне скидання, активний 0
    input  wire       load,     // імпульс: взяти tx_data, виставити його MSB на MOSI
    input  wire       shift,    // імпульс: виставити на MOSI наступний біт
    input  wire       clear,    // імпульс: кінець транзакції, MOSI <- 0
    input  wire [7:0] tx_data,  // байт для передачі
    output wire       mosi,     // послідовний вихід даних (Master Out, Slave In)
    output reg  [2:0] bitn,     // номер біта, що зараз на лінії (0 = MSB)
    output reg        active    // 1 — байт передається
);

    // Зсувний регістр: MOSI завжди дорівнює його старшому розряду
    reg [7:0] shreg;
    assign mosi = shreg[7];

    always @(posedge clk) begin
        if (!rst_n || clear) begin
            shreg  <= 8'h00;
            bitn   <= 3'd0;
            active <= 1'b0;
        end else if (load) begin
            // новий байт: MSB одразу на лінії, лічильник бітів з нуля
            shreg  <= tx_data;
            bitn   <= 3'd0;
            active <= 1'b1;
        end else if (shift && active) begin
            // зсув уліво: на лінію виходить наступний (молодший) біт
            shreg <= {shreg[6:0], 1'b0};
            bitn  <= bitn + 3'd1;
        end
    end

endmodule

`default_nettype wire
