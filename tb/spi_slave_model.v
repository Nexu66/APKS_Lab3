// =============================================================================
// spi_slave_model.v — поведінкова модель веденого SPI (для тестбенча).
// -----------------------------------------------------------------------------
// Лабораторна робота №3, варіант 12 (SPI, Verilog). Кулинський Я.О., КІ-408.
//
// Імітує зовнішній пристрій на шині SPI:
//   * підтримує всі 4 режими (входи cpol, cpha задає тестбенч);
//   * приймає байти з MOSI і записує їх у rx_mem[];
//   * відповідає на MISO байтами з масиву resp[], який заповнює тестбенч;
//   * поки SS_n = 1, MISO у високоімпедансному стані (z);
//   * змінює MISO із затримкою T_V після фронту SCLK, як реальна мікросхема
//     (час появи даних t_V).
// =============================================================================
`timescale 1ns / 1ps
`default_nettype none

module spi_slave_model #(
    parameter real T_V = 8.0                 // затримка видачі MISO після фронту, нс
) (
    input  wire sclk,
    input  wire mosi,
    input  wire ss_n,
    input  wire cpol,                        // режим, у якому працює ведений
    input  wire cpha,
    output wire miso
);

    reg [7:0] resp   [0:255];                // відповідь веденого (задає тестбенч)
    reg [7:0] rx_mem [0:255];                // байти, прийняті від майстра
    integer   n_rx;                          // кількість прийнятих байтів
    integer   n_tx;                          // номер байта відповіді, що передається
    integer   rbit, tbit;                    // лічильники бітів прийому / передачі
    reg [7:0] rx_sh, tx_sh;
    reg       miso_r, drive;

    assign miso = drive ? miso_r : 1'bz;

    initial begin
        n_rx = 0; n_tx = 0; rbit = 0; tbit = 0;
        rx_sh = 8'h00; tx_sh = 8'h00; miso_r = 1'b0; drive = 1'b0;
    end

    // Вибір веденого: почати нову транзакцію
    always @(negedge ss_n) begin
        n_rx = 0; n_tx = 0; rbit = 0; tbit = 0;
        tx_sh = resp[0];
        drive <= #(T_V) 1'b1;
        if (!cpha) begin
            // CPHA = 0: MSB має бути на лінії ще до першого (переднього) фронту
            miso_r <= #(T_V) tx_sh[7];
            tbit = 1;
        end
    end

    // Кінець транзакції: відпустити MISO
    always @(posedge ss_n) drive <= #(T_V) 1'b0;

    // Обробка фронтів SCLK
    always @(sclk) begin
        if (ss_n === 1'b0) begin
            if (((sclk !== cpol) ^ cpha) == 1'b1) begin
                // фронт вибірки: передній при CPHA = 0, задній при CPHA = 1
                rx_sh = {rx_sh[6:0], mosi};
                rbit  = rbit + 1;
                if (rbit == 8) begin
                    rx_mem[n_rx] = rx_sh;
                    n_rx = n_rx + 1;
                    rbit = 0;
                end
            end else begin
                // фронт зміни даних: виставити наступний біт відповіді
                if (tbit == 8) begin
                    n_tx  = n_tx + 1;
                    tx_sh = resp[n_tx];
                    tbit  = 0;
                end
                miso_r <= #(T_V) tx_sh[7 - tbit];
                tbit = tbit + 1;
            end
        end
    end

endmodule

`default_nettype wire
