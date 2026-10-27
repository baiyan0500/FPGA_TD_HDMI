`timescale 1ns/1ps
// 验证 audio_spectrum：1kHz 正弦应集中在 0.94~1.13kHz 两个频段
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
    integer max_lv [0:31];
    integer t_ms;
    real    ph;
    reg     collect = 0;

    initial begin
        for (b = 0; b < 32; b = b + 1) max_lv[b] = 0;
    end

    // 48kHz 样本节拍：25MHz / 48kHz ≈ 521 周期
    always @(posedge clk) begin
        if (rst) begin
            cyc <= 0;
            audio_valid <= 0;
        end else begin
            if (cyc == 520) begin
                cyc <= 0;
                audio_valid <= 1;
                ph = 2.0 * 3.14159265358979 * 1000.0 * $itor(n) / 48000.0;
                audio_l <= $rtoi(8388608.0 * 0.30 * $sin(ph));
                n <= n + 1;
            end else begin
                cyc <= cyc + 1;
                audio_valid <= 0;
            end
        end
    end

    // 30ms 之后开始记录各频段峰值（至少一个完整窗口之后）
    always @(posedge clk) begin
        t_ms = $time / 1000000;
        if (t_ms > 30) collect <= 1;
        if (collect) begin
            for (b = 0; b < 32; b = b + 1) begin
                lv = level[b*6 +: 6];
                if (lv > max_lv[b]) max_lv[b] = lv;
            end
        end
    end

    initial begin
        #200 rst = 0;
        #70000000;
        $display("band14(938Hz)=%0d band15(1125Hz)=%0d band13(797Hz)=%0d band31(16kHz)=%0d",
                 max_lv[14], max_lv[15], max_lv[13], max_lv[31]);
        if (max_lv[14] > 20 && max_lv[15] > 20 && max_lv[31] < 10)
            $display(">>> OK: spectrum peaks at 1kHz, high band quiet");
        else
            $display(">>> BUG: spectrum response wrong");
        $finish;
    end
endmodule
