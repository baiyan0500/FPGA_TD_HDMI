`timescale 1ns/1ps
// 诊断：先放 1kHz 正弦，再切静音，观察频谱是否残留（Goertzel 状态未清）
module tb_spec_diag;
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
    integer t_ms;
    integer b;
    integer lv;
    real    ph;
    reg     tone_on = 0;

    always @(posedge clk) begin
        if (rst) begin
            cyc <= 0;
            audio_valid <= 0;
        end else begin
            if (cyc == 520) begin
                cyc <= 0;
                audio_valid <= 1;
                if (tone_on) begin
                    ph = 2.0 * 3.14159265358979 * 1000.0 * $itor(n) / 48000.0;
                    audio_l <= $rtoi(8388608.0 * 0.30 * $sin(ph));
                end else
                    audio_l <= 24'sd0;
                n <= n + 1;
            end else begin
                cyc <= cyc + 1;
                audio_valid <= 0;
            end
        end
    end

    integer k;
    integer last_t = -1;
    always @(posedge clk) begin
        t_ms = $time / 1000000;
        if (t_ms != last_t) begin
            last_t = t_ms;
            if (t_ms == 20) tone_on <= 1;
            if (t_ms == 120) tone_on <= 0;
            if ((t_ms == 100) || (t_ms == 118) || (t_ms == 150) ||
                (t_ms == 200) || (t_ms == 400)) begin
                $write("t=%0dms levels:", t_ms);
                for (k = 0; k < 32; k = k + 1) $write(" %0d", level[k*6 +: 6]);
                $write("\n");
            end
        end
    end

    initial begin
        #200 rst = 0;
        #500000000;
        $finish;
    end
endmodule
