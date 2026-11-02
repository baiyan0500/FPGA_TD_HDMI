`timescale 1ns/1ps
// audio_spectrum 严格验证（64 bin / 32 段）：
//   1) 1kHz 单音落在 band10（bin20/21 = 984/1031Hz），远端频段安静
//   2) 静音后两个窗口内全部归零（旧版 s2 未清零会残留 280ms 以上）
//   3) 4kHz 单音落在 band24（bin48 = 3984Hz），明显高于相邻频段
//   4) 60Hz 单音落在 band0（bin0 = 47Hz）
//   5) -6dBFS 与 -36dBFS 的 1kHz 电平差 ≈ 30dB / 1.28 ≈ 23 级
module tb_spectrum;
    reg clk = 0;
    reg rst = 1;
    reg audio_valid = 0;
    reg signed [23:0] audio_l = 24'sd0;
    wire [191:0] level;

    audio_spectrum dut(
        .I_clk(clk), .I_rst(rst),
        .i_audio_valid(audio_valid),
        .i_audio_left(audio_l),
        .o_level(level)
    );

    always #20 clk = ~clk;   // 25MHz

    integer n = 0;
    integer cyc = 0;
    integer b;
    integer lv;
    integer t_ms;
    integer last_t;
    integer phase;
    integer collect;
    integer max_lv [0:31];
    real    ph;
    real    ampl;
    integer freq;

    function integer get_lv;
        input integer bb;
        begin
            get_lv = (level[bb*6 +: 6]);
        end
    endfunction

    // 48kHz 样本节拍：25MHz / 48kHz ≈ 521 周期
    always @(posedge clk) begin
        if (rst) begin
            cyc <= 0;
            audio_valid <= 0;
        end else begin
            if (cyc == 520) begin
                cyc <= 0;
                audio_valid <= 1;
                ph = 2.0 * 3.14159265358979 * freq * $itor(n) / 48000.0;
                audio_l <= $rtoi(8388608.0 * ampl * $sin(ph));
                n <= n + 1;
            end else begin
                cyc <= cyc + 1;
                audio_valid <= 0;
            end
        end
    end

    // 每 1ms 刷新一次各频段峰值（只在 collect 窗口内统计）
    always @(posedge clk) begin
        t_ms = $time / 1000000;
        if (t_ms != last_t) begin
            last_t = t_ms;
            if (collect) begin
                for (b = 0; b < 32; b = b + 1) begin
                    lv = get_lv(b);
                    if (lv > max_lv[b]) max_lv[b] = lv;
                end
            end
        end
    end

    task clear_max;
        integer k;
        begin
            collect = 0;
            for (k = 0; k < 32; k = k + 1) max_lv[k] = 0;
        end
    endtask

    task arm;
        begin
            clear_max;
            collect = 1;
        end
    endtask

    task dump;
        input [255:0] tag;
        integer k;
        begin
            collect = 0;
            $write("%0s:", tag);
            for (k = 0; k < 32; k = k + 1) $write(" %0d", max_lv[k]);
            $write("\n");
        end
    endtask

    integer pk_band, pk_lv;
    task find_peak;
        integer k;
        begin
            pk_band = 0;
            pk_lv   = max_lv[0];
            for (k = 1; k < 32; k = k + 1)
                if (max_lv[k] > pk_lv) begin
                    pk_lv   = max_lv[k];
                    pk_band = k;
                end
        end
    endtask

    // 除峰值band外，最响的频段（判断泄漏）
    integer leak_lv;
    task find_leak;
        integer k;
        begin
            leak_lv = 0;
            for (k = 0; k < 32; k = k + 1)
                if ((k < pk_band - 2 || k > pk_band + 2) && max_lv[k] > leak_lv)
                    leak_lv = max_lv[k];
        end
    endtask

    integer l6, l36;

    initial begin
        last_t  = -1;
        phase   = 1;
        freq    = 1000;
        ampl    = 0.5;
        collect = 0;
        clear_max;

        #200 rst = 0;

        // ---- 相位1：1kHz -6dBFS，取 60~150ms 的峰值 ----
        #60000000;              // 60ms：先让至少 2 个窗口稳定
        arm;
        #90000000;              // 150ms
        dump("1kHz -6dBFS");
        find_peak;
        find_leak;
        l6 = pk_lv;
        if (pk_band != 10 || l6 < 44)
            $display(">>> FAIL: 1kHz peak at band%0d level %0d (want band10 >=44)",
                     pk_band, l6);
        else if (leak_lv > 34)
            $display(">>> FAIL: 1kHz leaks broadly (worst off-peak band=%0d)", leak_lv);
        else if (max_lv[0] > 24 || max_lv[31] > 12)
            $display(">>> FAIL: 1kHz leaks to edge bands (b0=%0d b31=%0d)",
                     max_lv[0], max_lv[31]);
        else $display(">>> OK: 1kHz at band%0d level=%0d leak=%0d",
                      pk_band, l6, leak_lv);

        // ---- 相位2：静音，200~280ms 内必须归零 ----
        phase = 2;
        freq  = 1000;
        ampl  = 0.0;
        #100000000;             // 250ms
        arm;
        #80000000;              // 330ms：静音已持续 180ms（>8 窗）
        dump("silence  ");
        begin : silence_chk
            integer bad;
            bad = 0;
            for (b = 0; b < 32; b = b + 1)
                if (max_lv[b] > 3) bad = bad + 1;
            if (bad != 0) $display(">>> FAIL: %0d bands still alive after silence", bad);
            else $display(">>> OK: all bands zero after silence");
        end

        // ---- 相位3：4kHz -12dBFS ----
        phase = 3;
        freq  = 4000;
        ampl  = 0.25;
        #80000000;              // 410ms
        arm;
        #90000000;              // 500ms
        dump("4kHz -12dB");
        find_peak;
        if (pk_band != 24 || pk_lv < 38)
            $display(">>> FAIL: 4kHz peak at band%0d level %0d (want band24 >=38)",
                     pk_band, pk_lv);
        else if (max_lv[14] > pk_lv - 12)
            $display(">>> FAIL: 4kHz not dominant over 1kHz region (b14=%0d)", max_lv[14]);
        else $display(">>> OK: 4kHz at band%0d level=%0d (b14=%0d)",
                      pk_band, pk_lv, max_lv[14]);

        // ---- 相位4：60Hz -6dBFS ----
        phase = 4;
        freq  = 60;
        ampl  = 0.5;
        #70000000;              // 570ms
        arm;
        #90000000;              // 660ms
        dump("60Hz -6dB ");
        find_peak;
        if (pk_band != 0 || pk_lv < 40)
            $display(">>> FAIL: 60Hz peak at band%0d level %0d (want band0 >=40)",
                     pk_band, pk_lv);
        else $display(">>> OK: 60Hz at band%0d level=%0d b1=%0d",
                      pk_band, pk_lv, max_lv[1]);

        // ---- 相位5：1kHz -36dBFS，检查刻度线性 ----
        phase = 5;
        freq  = 1000;
        ampl  = 0.01587;        // -36dBFS
        #100000000;             // 760ms
        arm;
        #100000000;             // 860ms
        dump("1kHz -36dB");
        find_peak;
        l36 = pk_lv;
        if (l36 < 20)
            $display(">>> FAIL: -36dBFS level too low (%0d)", l36);
        else if (l6 - l36 < 18 || l6 - l36 > 30)
            $display(">>> FAIL: level scale not dB-linear (-6:%0d -36:%0d diff=%0d, want ~23)",
                     l6, l36, l6 - l36);
        else $display(">>> OK: dB scale linear (-6:%0d -36:%0d diff=%0d)",
                      l6, l36, l6 - l36);

        // ---- 收尾：再静音，验证归零 ----
        ampl = 0.0;
        #120000000;             // 980ms
        arm;
        #40000000;
        begin : silence2
            integer bad2;
            bad2 = 0;
            for (b = 0; b < 32; b = b + 1)
                if (max_lv[b] > 3) bad2 = bad2 + 1;
            if (bad2 != 0) $display(">>> FAIL: %0d bands alive at end", bad2);
            else $display(">>> OK: final silence clean");
        end
        $display(">>> DONE");
        $finish;
    end
endmodule
