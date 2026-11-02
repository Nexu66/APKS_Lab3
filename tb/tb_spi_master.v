// =============================================================================
// tb_spi_master.v — самоперевірний тестбенч SPI Master.
// -----------------------------------------------------------------------------
// Лабораторна робота №3, варіант 12 (SPI, Verilog). Кулинський Я.О., КІ-408.
//
// Імітує зовнішнє середовище майстра:
//   * генерує CLK (CLK_FREQ) і синхронне скидання RESET (rst_n);
//   * подає команди і тестові байти на вхід передавача (tx_data за tx_req);
//   * модель spi_slave_model імітує інший пристрій: приймає MOSI і відповідає
//     заданими байтами на MISO (перевірка приймача);
//   * незалежний монітор spi_monitor розкодовує шину і вимірює часові параметри.
// Сценарії T1–T8: усі 4 режими SPI, один байт, 16 байтів підряд, команда під час
// зайнятості й транзакції впритул, скидання посеред передачі.
// Наприкінці друкується TEST PASSED / TEST FAILED і кількість перевірок.
//
// Параметри: -P tb_spi_master.SCLK_FREQ=<Гц>; +vcd=<файл> — куди писати VCD.
// З `define NETLIST тестується нетліст після синтезу (без параметрів).
// =============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tb_spi_master;

    parameter integer CLK_FREQ  = 50_000_000;
    parameter integer SCLK_FREQ = 1_000_000;

    localparam real    T_CLK  = 1.0e9 / CLK_FREQ;              // період clk, нс
    localparam integer HALF   = CLK_FREQ / (2 * SCLK_FREQ);     // тактів на половину SCLK
    localparam real    T_HALF = HALF * T_CLK;                   // очікувана половина періоду SCLK, нс
    localparam real    T_V    = 8.0;                            // затримка MISO у моделі веденого, нс
    localparam real    EPS    = 0.01;                           // допуск порівняння часу, нс

    // ---------------------------------------------------------------- сигнали
    reg        clk = 1'b0;
    reg        rst_n = 1'b0;
    reg        cmd_start = 1'b0;
    reg  [1:0] cmd_mode = 2'b00;
    reg  [7:0] cmd_len = 8'd1;
    reg  [7:0] tx_data = 8'h00;
    wire       tx_req, rx_valid, busy, done;
    wire [7:0] rx_data;
    wire       sclk, mosi, miso, ss_n;

    always #(T_CLK / 2.0) clk = ~clk;
    pullup (miso);                                              // MISO у спокої — z

    // ---------------------------------------------------------------- DUT
`ifdef NETLIST
    spi_master_top dut (
`else
    spi_master_top #(.CLK_FREQ(CLK_FREQ), .SCLK_FREQ(SCLK_FREQ)) dut (
`endif
        .clk(clk), .rst_n(rst_n),
        .cmd_start(cmd_start), .cmd_mode(cmd_mode), .cmd_len(cmd_len),
        .tx_data(tx_data), .tx_req(tx_req), .rx_data(rx_data), .rx_valid(rx_valid),
        .busy(busy), .done(done),
        .sclk(sclk), .mosi(mosi), .miso(miso), .ss_n(ss_n)
    );

    // ---------------------------------------------------------------- середовище
    spi_slave_model #(.T_V(T_V)) slave (
        .sclk(sclk), .mosi(mosi), .ss_n(ss_n), .cpol(cmd_mode[1]), .cpha(cmd_mode[0]), .miso(miso)
    );

    spi_monitor mon (
        .sclk(sclk), .mosi(mosi), .miso(miso), .ss_n(ss_n), .cpol(cmd_mode[1]), .cpha(cmd_mode[0])
    );

    // ---------------------------------------------------------------- дані
    reg [7:0] tx_buf [0:255];       // що передає майстер
    reg [7:0] rx_exp [0:255];       // що відповідає ведений (очікуваний прийом)
    reg [7:0] rx_got [0:255];       // що прийняв майстер
    integer   n_got, n_load, n_done;
    integer   n_checks, n_errors;
    reg [8*48-1:0] test_name;

    integer k;
    initial begin
        n_got = 0; n_load = 0; n_done = 0; n_checks = 0; n_errors = 0;
        // невикористані елементи буферів — 0, щоб на осцилограмах не було x
        for (k = 0; k < 256; k = k + 1) begin
            tx_buf[k] = 8'h00; rx_exp[k] = 8'h00;
        end
    end

    // Подача наступного байта за tx_req і збирання прийнятих байтів
    always @(posedge clk) begin
        if (tx_req) begin
            n_load = n_load + 1;
            tx_data <= tx_buf[n_load];
        end
        if (rx_valid) begin
            rx_got[n_got] = rx_data;
            n_got = n_got + 1;
        end
        if (done) n_done = n_done + 1;
    end

    // ---------------------------------------------------------------- перевірки
    task check(input cond, input [8*64-1:0] what);
        begin
            n_checks = n_checks + 1;
            if (cond !== 1'b1) begin
                n_errors = n_errors + 1;
                $display("  [FAIL] %0s: %0s", test_name, what);
            end
        end
    endtask

    function real fabs(input real x);
        fabs = (x < 0.0) ? -x : x;
    endfunction

    // Запустити транзакцію з len байтів у режимі mode і дочекатися done.
    // glitch = 1: ще один cmd_start посеред передачі (має бути проігноровано).
    task run(input [1:0] mode, input integer len, input glitch);
        integer i, guard;
        begin
            for (i = 0; i < len + 1; i = i + 1) slave.resp[i] = rx_exp[i];
            @(negedge clk);
            cmd_mode = mode;
            n_got = 0; n_load = 0; n_done = 0;
            tx_data = tx_buf[0];
            cmd_len = len;
            cmd_start = 1'b1;
            @(negedge clk);
            cmd_start = 1'b0;
            if (glitch) begin
                wait (n_got == 1);
                @(negedge clk); cmd_start = 1'b1;
                @(negedge clk); cmd_start = 1'b0;
            end
            guard = 0;
            while (!done && guard < 2_000_000) begin
                @(posedge clk);
                guard = guard + 1;
            end
            @(negedge clk);
        end
    endtask

    // Перевірити результат щойно завершеної транзакції
    task verify(input integer len);
        integer i;
        reg ok_m, ok_s, ok_mosi, ok_miso;
        begin
            ok_m = 1'b1; ok_s = 1'b1; ok_mosi = 1'b1; ok_miso = 1'b1;
            for (i = 0; i < len; i = i + 1) begin
                if (rx_got[i] !== rx_exp[i])         ok_m = 1'b0;
                if (slave.rx_mem[i] !== tx_buf[i])   ok_s = 1'b0;
                if (mon.mosi_bytes[i] !== tx_buf[i]) ok_mosi = 1'b0;
                if (mon.miso_bytes[i] !== rx_exp[i]) ok_miso = 1'b0;
            end
            check(n_load == len,  "tx_req: one request per byte");
            check(n_got == len,   "rx_valid: one pulse per byte");
            check(n_done == 1,    "done: exactly one pulse");
            check(ok_m,           "master rx_data == slave response (Rx)");
            check(slave.n_rx == len && ok_s, "slave received tx bytes (Tx)");
            check(mon.n_bytes == len && mon.nbits == 0 && ok_mosi, "monitor: MOSI bytes decoded == tx");
            check(ok_miso,        "monitor: MISO bytes decoded == response");
            check(mon.edges == 16 * len, "monitor: 16 SCLK edges per byte");
            check(!mon.idle_err,  "SCLK at CPOL level while SS_n toggles");
            check(mon.t_sclk_idle >= T_HALF - EPS, "SCLK stable at CPOL >= T/2 before SS_n fall");
            check(mon.t_lead >= T_HALF - EPS, "t_lead (SS_n fall -> first edge) >= T/2");
            check(mon.t_lag  >= T_HALF - EPS, "t_lag (last edge -> SS_n rise) >= T/2");
            check(fabs(mon.half_min - T_HALF) < EPS && fabs(mon.half_max - T_HALF) < EPS,
                  "SCLK half-periods equal (50 % duty, no gaps)");
            check(mon.setup_mosi_min >= T_HALF - EPS, "MOSI setup before sampling edge >= T/2");
            check(mon.hold_mosi_min  >= T_HALF - EPS, "MOSI hold after sampling edge >= T/2");
            check(mon.setup_miso_min >= T_HALF - T_V - EPS, "MISO setup at sampling edge >= T/2 - t_V");
            check(ss_n === 1'b1 && busy === 1'b0, "bus idle after done");
            $display("%0s: %0d byte(s), mode %0d -> %0s", test_name, len, cmd_mode,
                     (n_errors == 0) ? "ok" : "errors so far");
        end
    endtask

    task show_bytes(input integer len);
        integer i;
        begin
            $write("    MOSI:");  for (i = 0; i < len; i = i + 1) $write(" %02h", tx_buf[i]);
            $write("   MISO:");   for (i = 0; i < len; i = i + 1) $write(" %02h", rx_got[i]);
            $write("\n");
        end
    endtask

    // ---------------------------------------------------------------- сценарії
    reg [1023:0] vcd_name;
    integer i;
    real t_idle_b2b;

    initial begin
        if (!$value$plusargs("vcd=%s", vcd_name)) vcd_name = "tb_spi_master.vcd";
        $dumpfile(vcd_name);
        $dumpvars(0, tb_spi_master);

        $display("==== SPI master testbench: CLK = %0d Hz, SCLK = %0d Hz (HALF = %0d clk, f_SCLK = %0.3f MHz)",
                 CLK_FREQ, SCLK_FREQ, HALF, 1.0e3 / (2.0 * T_HALF));

        // скидання
        rst_n = 1'b0;
        repeat (5) @(posedge clk);
        @(negedge clk) rst_n = 1'b1;
        repeat (5) @(posedge clk);

        // T1: режим 0, 4 байти
        test_name = "T1 mode 0 (CPOL=0, CPHA=0)";
        tx_buf[0] = 8'hDE; tx_buf[1] = 8'hAD; tx_buf[2] = 8'hBE; tx_buf[3] = 8'hEF;
        rx_exp[0] = 8'h01; rx_exp[1] = 8'h23; rx_exp[2] = 8'h45; rx_exp[3] = 8'h67;
        run(2'd0, 4, 1'b0); verify(4); show_bytes(4);
        $display("    timing: f_SCLK = %0.3f MHz, T/2 = %0.1f ns, t_lead = %0.1f ns, t_lag = %0.1f ns,",
                 1.0e3 / (2.0 * mon.half_min), mon.half_min, mon.t_lead, mon.t_lag);
        $display("            MOSI setup/hold = %0.1f / %0.1f ns, MISO setup = %0.1f ns (t_V = %0.1f ns)",
                 mon.setup_mosi_min, mon.hold_mosi_min, mon.setup_miso_min, T_V);
        $display("            SCLK idle before SS_n fall = %0.1f ns", mon.t_sclk_idle);
        repeat (10) @(posedge clk);

        // T2: режим 1, 3 байти
        test_name = "T2 mode 1 (CPOL=0, CPHA=1)";
        tx_buf[0] = 8'h3C; tx_buf[1] = 8'h5A; tx_buf[2] = 8'hA5;
        rx_exp[0] = 8'hC3; rx_exp[1] = 8'h96; rx_exp[2] = 8'h69;
        run(2'd1, 3, 1'b0); verify(3); show_bytes(3);
        repeat (10) @(posedge clk);

        // T3: режим 2, 2 байти
        test_name = "T3 mode 2 (CPOL=1, CPHA=0)";
        tx_buf[0] = 8'h81; tx_buf[1] = 8'h7E;
        rx_exp[0] = 8'h18; rx_exp[1] = 8'hE7;
        run(2'd2, 2, 1'b0); verify(2); show_bytes(2);
        repeat (10) @(posedge clk);

        // T4: режим 3, 4 байти
        test_name = "T4 mode 3 (CPOL=1, CPHA=1)";
        tx_buf[0] = 8'h00; tx_buf[1] = 8'hFF; tx_buf[2] = 8'h55; tx_buf[3] = 8'hAA;
        rx_exp[0] = 8'hF0; rx_exp[1] = 8'h0F; rx_exp[2] = 8'hCC; rx_exp[3] = 8'h33;
        run(2'd3, 4, 1'b0); verify(4); show_bytes(4);
        repeat (10) @(posedge clk);

        // T5: один байт
        test_name = "T5 single byte, mode 0";
        tx_buf[0] = 8'h96; rx_exp[0] = 8'h69;
        run(2'd0, 1, 1'b0); verify(1); show_bytes(1);
        repeat (10) @(posedge clk);

        // T6: 16 байтів підряд, режим 3 — SCLK без пауз між байтами
        test_name = "T6 16-byte burst, mode 3";
        for (i = 0; i < 16; i = i + 1) begin
            tx_buf[i] = (i * 37 + 5) & 8'hFF;
            rx_exp[i] = ~tx_buf[i] ^ 8'h5A;
        end
        run(2'd3, 16, 1'b0); verify(16); show_bytes(16);
        repeat (10) @(posedge clk);

        // T7: cmd_start під час передачі ігнорується; потім транзакція впритул
        test_name = "T7a start while busy, mode 1";
        tx_buf[0] = 8'h12; tx_buf[1] = 8'h34; rx_exp[0] = 8'hAB; rx_exp[1] = 8'hCD;
        run(2'd1, 2, 1'b1); verify(2); show_bytes(2);
        test_name = "T7b back-to-back, mode 1";
        tx_buf[0] = 8'h56; tx_buf[1] = 8'h78; rx_exp[0] = 8'hEF; rx_exp[1] = 8'h01;
        run(2'd1, 2, 1'b0); verify(2); show_bytes(2);
        t_idle_b2b = mon.t_idle;
        check(t_idle_b2b >= T_HALF - EPS, "t_idle (SS_n high between transactions) >= T/2");
        $display("    t_idle between back-to-back transactions = %0.1f ns", t_idle_b2b);
        repeat (10) @(posedge clk);

        // T8: скидання посеред передачі, після нього шина в спокої і працює
        test_name = "T8 reset during transfer, mode 0";
        tx_buf[0] = 8'h11; tx_buf[1] = 8'h22; tx_buf[2] = 8'h33; tx_buf[3] = 8'h44;
        for (i = 0; i < 5; i = i + 1) slave.resp[i] = 8'hA0 + i;
        @(negedge clk);
        cmd_mode = 2'd0; n_got = 0; n_load = 0; tx_data = tx_buf[0]; cmd_len = 4; cmd_start = 1'b1;
        @(negedge clk) cmd_start = 1'b0;
        wait (n_got == 2);
        repeat (HALF * 5) @(posedge clk);                // посеред третього байта
        @(negedge clk) rst_n = 1'b0;
        repeat (3) @(posedge clk);
        @(negedge clk);
        check(ss_n === 1'b1 && busy === 1'b0 && sclk === 1'b0, "reset: SS_n = 1, busy = 0, SCLK = 0");
        rst_n = 1'b1;
        repeat (10) @(posedge clk);
        tx_buf[0] = 8'hC0; tx_buf[1] = 8'hDE; rx_exp[0] = 8'hBE; rx_exp[1] = 8'hEF;
        run(2'd0, 2, 1'b0); verify(2); show_bytes(2);

        // підсумок
        repeat (20) @(posedge clk);
        if (n_errors == 0)
            $display("==== TEST PASSED (%0d checks)", n_checks);
        else
            $display("==== TEST FAILED (%0d of %0d checks)", n_errors, n_checks);
        $finish;
    end

    // Сторож: симуляція не повинна зависнути
    initial begin
        #(100_000_000);
        $display("==== TEST FAILED (timeout)");
        $finish;
    end

endmodule

`default_nettype wire
