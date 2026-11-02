// =============================================================================
// spi_master.v — ядро SPI Master: дільник SCLK, автомат транзакції, керування SS.
// -----------------------------------------------------------------------------
// Лабораторна робота №3, варіант 12 (SPI, Verilog). Кулинський Я.О., КІ-408.
//
// Огляд:
//   * Дільник частоти: лічильник hcnt відраховує HALF = CLK_FREQ / (2*SCLK_FREQ)
//     тактів clk на кожну половину періоду SCLK; у кінці половини SCLK
//     перемикається (фронт).
//   * Режими SPI задаються на кожну транзакцію (cmd_cpol, cmd_cpha):
//       CPOL — рівень SCLK у спокої (0 або 1);
//       CPHA = 0 — вибірка на передньому (leading) фронті, зміна даних на задньому;
//       CPHA = 1 — зміна даних на передньому фронті, вибірка на задньому.
//     Передній фронт — перехід SCLK від рівня спокою, задній — повернення до нього.
//   * Головний автомат: IDLE -> LEAD -> XFER -> LAG -> GAP -> IDLE.
//       LEAD — SCLK уже на рівні спокою нового режиму; через половину періоду
//              SS_n опускається (при CPHA = 0 разом з MSB на MOSI), тож ведений
//              бачить стабільний SCLK до вибору; перший фронт — ще через T/2;
//       XFER — 16 фронтів на кожен байт, байти йдуть без пауз (cmd_len байтів);
//       LAG  — SS_n утримується в 0 ще половину періоду після останнього фронту;
//       GAP  — SS_n = 1 щонайменше половину періоду, потім імпульс done.
//   * Передавач spi_tx і приймач spi_rx отримують від ядра імпульси
//     load/shift та sample у потрібні моменти залежно від CPHA.
//
// Потік даних: tx_data має бути встановлено разом із cmd_start і тримається до
// імпульсу tx_req (байт узято); після tx_req наступний байт треба виставити
// не пізніше ніж за 8 періодів SCLK. Кожен прийнятий байт — імпульс rx_valid.
//
// MISO проходить через один вхідний регістр (miso_r), тому вибірка бачить
// значення за такт до фронту; для цього потрібно HALF >= 2, тобто
// SCLK_FREQ <= CLK_FREQ / 4 (12.5 МГц при 50 МГц). Перевіряється під час
// елаборації.
// =============================================================================
`timescale 1ns / 1ps
`default_nettype none

module spi_master #(
    parameter integer CLK_FREQ  = 50_000_000,   // частота clk, Гц
    parameter integer SCLK_FREQ = 1_000_000     // бажана частота SCLK, Гц
) (
    input  wire       clk,
    input  wire       rst_n,        // синхронне скидання, активний 0

    // ---- командний інтерфейс --------------------------------------------
    input  wire       cmd_start,    // імпульс: почати транзакцію (ігнорується, якщо busy)
    input  wire       cmd_cpol,     // CPOL: рівень SCLK у спокої
    input  wire       cmd_cpha,     // CPHA: 0 — вибірка на передньому фронті, 1 — на задньому
    input  wire [7:0] cmd_len,      // кількість байтів у транзакції (0 трактується як 1)
    input  wire [7:0] tx_data,      // байт для передачі
    output wire       tx_req,       // імпульс: tx_data узято, виставити наступний
    output wire [7:0] rx_data,      // прийнятий байт
    output wire       rx_valid,     // імпульс: rx_data дійсний
    output wire       busy,         // 1 — триває транзакція
    output reg        done,         // імпульс: транзакцію завершено (SS_n уже 1)

    // ---- шина SPI ---------------------------------------------------------
    output reg        sclk,         // тактовий сигнал шини (генерує майстер)
    output wire       mosi,         // дані Master -> Slave
    input  wire       miso,         // дані Slave -> Master
    output reg        ss_n          // вибір веденого, активний 0
);

    // -------------------------------------------------------------------------
    // Параметри дільника: кількість тактів clk на половину періоду SCLK
    // -------------------------------------------------------------------------
    localparam integer HALF = CLK_FREQ / (2 * SCLK_FREQ);
    localparam integer HW   = (HALF > 1) ? $clog2(HALF) : 1;   // розрядність лічильника

    // Перевірка параметрів під час елаборації: замала CLK_FREQ для заданої SCLK_FREQ
    generate
        if (HALF < 2) begin : g_param_error
            ERROR_SCLK_FREQ_too_high_for_CLK_FREQ u_param_check ();
        end
    endgenerate

    // -------------------------------------------------------------------------
    // Стани головного автомата
    // -------------------------------------------------------------------------
    localparam [2:0] S_IDLE = 3'd0,   // шина вільна, SCLK = CPOL, SS_n = 1
                     S_LEAD = 3'd1,   // SCLK = CPOL, через T/2: SS_n -> 0 (CPHA = 0: MSB на MOSI)
                     S_XFER = 3'd2,   // генерація фронтів SCLK, обмін бітами
                     S_LAG  = 3'd3,   // пауза після останнього фронту, потім SS_n -> 1
                     S_GAP  = 3'd4;   // мінімальний час SS_n = 1 між транзакціями

    reg  [2:0]    state;
    reg           cpol_r, cpha_r;     // режим, зафіксований на початку транзакції
    reg  [7:0]    left;               // скільки байтів ще залишилось після поточного
    reg  [HW-1:0] hcnt;               // лічильник тактів у половині періоду SCLK
    reg  [3:0]    ecnt;               // номер фронту в байті: парний — передній, непарний — задній
    reg           miso_r;             // вхідний регістр MISO

    wire half_end = (hcnt == HALF - 1);        // кінець половини періоду
    wire lead     = ~ecnt[0];                  // поточний фронт — передній
    wire edge_now = (state == S_XFER) && half_end;
    wire start_ok = (state == S_IDLE) && cmd_start;

    // -------------------------------------------------------------------------
    // Імпульси керування передавачем і приймачем
    // -------------------------------------------------------------------------
    // CPHA = 0: перший байт завантажується наприкінці LEAD (разом зі спадом SS_n),
    //           наступні — на останньому (16-му) задньому фронті попереднього байта;
    //           інші задні фронти — зсув.
    // CPHA = 1: на першому передньому фронті байта — завантаження, на інших
    //           передніх — зсув.
    wire tx_load  = (state == S_LEAD && half_end && !cpha_r) ||
                    (edge_now && ( cpha_r ? (lead && ecnt == 4'd0)
                                          : (!lead && ecnt == 4'd15 && left != 8'd0)));
    wire tx_shift = edge_now && ( cpha_r ? (lead && ecnt != 4'd0)
                                         : (!lead && ecnt != 4'd15));
    // Вибірка MISO: передній фронт при CPHA = 0, задній — при CPHA = 1
    wire rx_sample = edge_now && (lead ^ cpha_r);
    // Кінець транзакції: SS_n піднімається, MOSI скидається в 0
    wire tx_clear  = (state == S_LAG) && half_end;

    assign tx_req = tx_load;                   // байт узято передавачем
    assign busy   = (state != S_IDLE);

    // -------------------------------------------------------------------------
    // Головний автомат і генератор SCLK
    // -------------------------------------------------------------------------
    always @(posedge clk) begin
        done <= 1'b0;
        if (!rst_n) begin
            state  <= S_IDLE;
            ss_n   <= 1'b1;
            sclk   <= 1'b0;
            cpol_r <= 1'b0;
            cpha_r <= 1'b0;
            left   <= 8'd0;
            hcnt   <= {HW{1'b0}};
            ecnt   <= 4'd0;
            miso_r <= 1'b0;
        end else begin
            miso_r <= miso;
            case (state)
                S_IDLE: begin
                    sclk <= cmd_cpol;          // рівень спокою відповідає режиму
                    hcnt <= {HW{1'b0}};
                    ecnt <= 4'd0;
                    if (cmd_start) begin
                        cpol_r <= cmd_cpol;
                        cpha_r <= cmd_cpha;
                        left   <= (cmd_len == 8'd0) ? 8'd0 : cmd_len - 8'd1;
                        state  <= S_LEAD;
                    end
                end

                S_LEAD: begin
                    // SCLK стоїть на рівні спокою; через HALF тактів вибрати веденого,
                    // перший фронт SCLK буде ще через HALF тактів (стан XFER)
                    if (half_end) begin
                        hcnt  <= {HW{1'b0}};
                        ss_n  <= 1'b0;
                        state <= S_XFER;
                    end else begin
                        hcnt <= hcnt + 1'b1;
                    end
                end

                S_XFER: begin
                    if (half_end) begin
                        hcnt <= {HW{1'b0}};
                        sclk <= ~sclk;         // фронт SCLK
                        ecnt <= ecnt + 4'd1;
                        if (ecnt == 4'd15) begin
                            // 16-й фронт: байт завершено, SCLK повернувся до рівня спокою
                            if (left == 8'd0) state <= S_LAG;
                            else              left  <= left - 8'd1;
                        end
                    end else begin
                        hcnt <= hcnt + 1'b1;
                    end
                end

                S_LAG: begin
                    if (half_end) begin
                        hcnt  <= {HW{1'b0}};
                        ss_n  <= 1'b1;         // кінець транзакції
                        state <= S_GAP;
                    end else begin
                        hcnt <= hcnt + 1'b1;
                    end
                end

                S_GAP: begin
                    if (half_end) begin
                        hcnt  <= {HW{1'b0}};
                        done  <= 1'b1;
                        state <= S_IDLE;
                    end else begin
                        hcnt <= hcnt + 1'b1;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    // -------------------------------------------------------------------------
    // Передавач і приймач
    // -------------------------------------------------------------------------
    wire [2:0] tx_bitn, rx_bitn;
    wire       tx_active;

    spi_tx u_tx (
        .clk     (clk),
        .rst_n   (rst_n),
        .load    (tx_load),
        .shift   (tx_shift),
        .clear   (tx_clear),
        .tx_data (tx_data),
        .mosi    (mosi),
        .bitn    (tx_bitn),
        .active  (tx_active)
    );

    spi_rx u_rx (
        .clk      (clk),
        .rst_n    (rst_n),
        .clear    (start_ok),
        .sample   (rx_sample),
        .miso     (miso_r),
        .rx_data  (rx_data),
        .rx_valid (rx_valid),
        .bitn     (rx_bitn)
    );

endmodule

`default_nettype wire
