

module I2S_receiver (
    input wire       I_clk,
    input wire       I_rst,

    input wire       I_i2s_BCLK,
    input wire       I_i2s_LRCK,
    input wire       I_i2s_DOUT,

    // 本模块必须运行于 I2S 发生器同源时钟（audio_mclk = 2×BCLK）。
    // 3 拍延迟线后 BCLK/LRCK/DOUT 同相位：BCLK 沿检测拍（真实沿后第 2 拍）上，
    // dout_3d = 沿时刻稳定数据，lrck_3d = 该沿所属声道（I2S 标准 LRCK 提前
    // 半个 BCLK 周期稳定）。
    // 声道判别必须直接用 lrck_3d：若用 BCLK 沿再锁存一拍的 lrck_sync，
    // LRCK 每次切换后的第一个 BCLK 沿（新声道 MSB）会被判入旧声道，
    // 左右样本各左移 1 位（幅度 ×2），半幅以上样本 24bit 溢出符号翻转，
    // 表现为剧烈电音爆裂；测试音 ±AMP 方波 ×2 不溢出故听不出。
    // 输出为帧 toggle + 整帧稳定样本，由顶层 toggle 同步跨到 video_clk 域。
    output wire      O_audio_toggle,
    output reg[23:0] O_audio_left_data,
    output reg[23:0] O_audio_right_data
);


    reg       S_i2s_bclk_1d;
    reg       S_i2s_bclk_2d;
    reg       S_i2s_bclk_3d;

    wire      S_i2s_bclk_p_edge;

    reg       S_i2s_lrck_1d;
    reg       S_i2s_lrck_2d;
    reg       S_i2s_lrck_3d;
    reg       S_i2s_lrck_4d;

    reg       S_i2s_dout_1d;
    reg       S_i2s_dout_2d;
    reg       S_i2s_dout_3d;

    reg[63:0] S_left_shift_data;
    reg[63:0] S_right_shift_data;

    reg       S_left_data_valid;
    reg       S_right_data_valid;

    reg[63:0] S_left_data_lock;

    always @(posedge I_clk) begin
        S_i2s_bclk_1d <= I_i2s_BCLK;
        S_i2s_bclk_2d <= S_i2s_bclk_1d;
        S_i2s_bclk_3d <= S_i2s_bclk_2d;

        S_i2s_lrck_1d <= I_i2s_LRCK;
        S_i2s_lrck_2d <= S_i2s_lrck_1d;
        S_i2s_lrck_3d <= S_i2s_lrck_2d;
        S_i2s_lrck_4d <= S_i2s_lrck_3d;

        S_i2s_dout_1d <= I_i2s_DOUT;
        S_i2s_dout_2d <= S_i2s_dout_1d;
        S_i2s_dout_3d <= S_i2s_dout_2d;
    end

    assign S_i2s_bclk_p_edge = ~S_i2s_bclk_3d & S_i2s_bclk_2d;

    wire S_i2s_lrck_rise;
    wire S_i2s_lrck_fall;

    // 帧边界脉冲：lrck_3d/4d 相邻拍比较。LRCK 在 BCLK 上升沿前 2 个 I_clk 拍
    // 翻转，4d 比 3d 晚 1 拍，产生的 rise/fall 单拍脉冲恰好落在 BCLK 沿检测拍，
    // 即槽最后一个沿（bit63）的检测拍（该沿移入后上一声道移位器满 64 位）。
    assign S_i2s_lrck_rise = S_i2s_lrck_3d & ~S_i2s_lrck_4d;   // 左→右：左槽完成
    assign S_i2s_lrck_fall = ~S_i2s_lrck_3d & S_i2s_lrck_4d;   // 右→左：右槽完成

    // 声道判别必须用 lrck_4d（比 lrck_3d 再滞后 1 拍）：
    //   槽末 bit63 沿检测拍上 lrck_3d 已见新值，会把 padding 位判入新声道，
    //   污染其 64 位窗口首位 → 样本右移 1 位、MSB 恒 0（半波失真）；
    //   lrck_4d 在该拍仍是旧值（bit63 归旧声道），在下一槽 bit0（有效 MSB）
    //   沿检测拍上已是新值 → 每槽 64 沿全部正确归属，[63:40] 恰为完整样本。
    // 也不需要清零：判别正确时每槽恰好移满 64 位，窗口自然覆盖。
    always @(posedge I_clk) begin
        if(S_i2s_bclk_p_edge) begin
            if(S_i2s_lrck_4d)
                S_right_shift_data <= {S_right_shift_data[62:0],S_i2s_dout_3d};
            else
                S_left_shift_data  <= {S_left_shift_data[62:0],S_i2s_dout_3d};
        end
    end


    always @(posedge I_clk) begin
        if(S_i2s_bclk_p_edge && S_i2s_lrck_rise)
            S_left_data_valid <= 1'b1;
        else
            S_left_data_valid <= 1'b0;
    end

    always @(posedge I_clk) begin
        if(S_i2s_bclk_p_edge && S_i2s_lrck_fall)
            S_right_data_valid <= 1'b1;
        else
            S_right_data_valid <= 1'b0;
    end

    always @(posedge I_clk) begin
        if(S_left_data_valid)
            S_left_data_lock <= S_left_shift_data;
    end

    // 帧输出：每帧（右声道移满）翻转一次 toggle；样本整帧保持稳定，
    // 供跨域接收端在 toggle 边沿安全采样
    reg S_audio_tgl;
    always @(posedge I_clk or posedge I_rst) begin
        if(I_rst)
            S_audio_tgl <= 1'b0;
        else if(S_right_data_valid)
            S_audio_tgl <= ~S_audio_tgl;
    end
    assign O_audio_toggle = S_audio_tgl;

    always @(posedge I_clk) begin
        if(S_right_data_valid)
            begin
                O_audio_left_data  <= S_left_data_lock[63:40];
                O_audio_right_data <= S_right_shift_data[63:40];
            end
    end

endmodule
