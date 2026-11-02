// =============================================================================
// spi_monitor.v — незалежний монітор шини SPI (для тестбенча).
// -----------------------------------------------------------------------------
// Лабораторна робота №3, варіант 12 (SPI, Verilog). Кулинський Я.О., КІ-408.
//
// Пасивно спостерігає SCLK, MOSI, MISO, SS_n і, не знаючи нічого про
// внутрішню будову майстра, для кожної транзакції:
//   * розкодовує байти MOSI і MISO на фронтах вибірки поточного режиму;
//   * рахує фронти SCLK (має бути 16 на байт);
//   * перевіряє, що на фронтах SS_n лінія SCLK має рівень спокою CPOL;
//   * вимірює t_lead (SS_n↓ → перший фронт), t_lag (останній фронт → SS_n↑),
//     t_idle (SS_n = 1 між транзакціями), мінімальну/максимальну половину
//     періоду SCLK, запас встановлення/утримання MOSI і встановлення MISO
//     відносно фронту вибірки.
// =============================================================================
`timescale 1ns / 1ps
`default_nettype none

module spi_monitor (
    input wire sclk,
    input wire mosi,
    input wire miso,
    input wire ss_n,
    input wire cpol,
    input wire cpha
);

    integer   edges, nbits, n_bytes;
    reg [7:0] mosi_sh, miso_sh;
    reg [7:0] mosi_bytes [0:255];
    reg [7:0] miso_bytes [0:255];
    reg       idle_err;                 // SCLK != CPOL на фронті SS_n
    reg       have_rise;

    real t_ss_fall, t_ss_rise, t_prev_edge, t_last_sample, t_mosi_chg, t_miso_chg;
    real t_sclk_chg, t_sclk_idle;       // остання зміна SCLK; скільки SCLK стабільний до SS_n↓
    real t_lead, t_lag, t_idle, half_min, half_max;
    real setup_mosi_min, hold_mosi_min, setup_miso_min;

    initial begin
        edges = 0; nbits = 0; n_bytes = 0; idle_err = 1'b0; have_rise = 1'b0;
        t_ss_fall = 0; t_ss_rise = 0; t_prev_edge = 0; t_last_sample = -1.0e12;
        t_mosi_chg = 0; t_miso_chg = 0; t_lead = 0; t_lag = 0; t_idle = 1.0e12;
        half_min = 1.0e12; half_max = 0; setup_mosi_min = 1.0e12; hold_mosi_min = 1.0e12;
        setup_miso_min = 1.0e12; t_sclk_chg = 0; t_sclk_idle = 0;
    end

    // Будь-яка зміна SCLK (зокрема перехід на новий рівень спокою між транзакціями)
    always @(sclk) t_sclk_chg = $realtime;

    // Початок транзакції
    always @(negedge ss_n) begin
        t_ss_fall = $realtime;
        t_sclk_idle = t_ss_fall - t_sclk_chg;
        if (have_rise) t_idle = t_ss_fall - t_ss_rise;
        edges = 0; nbits = 0; n_bytes = 0;
        idle_err = (sclk !== cpol);
        half_min = 1.0e12; half_max = 0;
        setup_mosi_min = 1.0e12; hold_mosi_min = 1.0e12; setup_miso_min = 1.0e12;
        t_last_sample = -1.0e12;
    end

    // Кінець транзакції
    always @(posedge ss_n) begin
        if (ss_n === 1'b1) begin
            t_ss_rise = $realtime;
            have_rise = 1'b1;
            if (edges > 0) t_lag = t_ss_rise - t_prev_edge;
            if (sclk !== cpol) idle_err = 1'b1;
        end
    end

    // Фронти SCLK під час вибору веденого
    always @(sclk) begin : on_edge
        real now;
        if (ss_n === 1'b0) begin
            now = $realtime;
            if (edges == 0) begin
                t_lead = now - t_ss_fall;
            end else begin
                if (now - t_prev_edge < half_min) half_min = now - t_prev_edge;
                if (now - t_prev_edge > half_max) half_max = now - t_prev_edge;
            end
            t_prev_edge = now;
            edges = edges + 1;
            if (((sclk !== cpol) ^ cpha) == 1'b1) begin
                // фронт вибірки
                if (now - t_mosi_chg < setup_mosi_min) setup_mosi_min = now - t_mosi_chg;
                if (now - t_miso_chg < setup_miso_min) setup_miso_min = now - t_miso_chg;
                mosi_sh = {mosi_sh[6:0], mosi};
                miso_sh = {miso_sh[6:0], miso};
                nbits = nbits + 1;
                t_last_sample = now;
                if (nbits == 8) begin
                    mosi_bytes[n_bytes] = mosi_sh;
                    miso_bytes[n_bytes] = miso_sh;
                    n_bytes = n_bytes + 1;
                    nbits = 0;
                end
            end
        end
    end

    // Зміни даних: для запасу встановлення/утримання
    always @(mosi) begin
        if (ss_n === 1'b0 && ($realtime - t_last_sample) < hold_mosi_min)
            hold_mosi_min = $realtime - t_last_sample;
        t_mosi_chg = $realtime;
    end

    always @(miso) t_miso_chg = $realtime;

endmodule

`default_nettype wire
