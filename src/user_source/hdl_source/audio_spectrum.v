// ============================================================================
// audio_spectrum — Goertzel 32 段频谱分析（video_clk 25MHz 域）
//
// 输入：I2S_receiver 输出的 48kHz PCM 帧（audio_valid/audio_left_data）。
// 每 1024 样本（约 21.3ms）窗口做 64 点对数分布 Goertzel 递推，
// 相邻两个 bin 取功率较大者作为 32 个显示频段的高度。
//
//   s[n] = x[n] + (coef × s[n-1] >> 13) - s[n-2]，coef = 2cos(2πk/N) 的 Q13
//   64 个 bin：k=1,2,...,41 步长 1，之后按 ~9.7% 对数递增到 k=341，
//   覆盖 47Hz ~ 16kHz。bin 间距最大 30（15kHz 附近），即每个显示频段内
//   都有 2 个实测点，纯音不会整段"消失"。
//
// 窗函数：矩形窗第一旁瓣仅 -13dB，单音会点亮一大片相邻频段。递推前乘
// Bartlett（三角）窗 w[n]=1-|2n/(N-1)-1|，第一旁瓣 -26dB，谱线位置可信。
//
// 电平：功率 log2 后按 ~1.28 级/dB 映射到 0..63
// （0dBFS 满幅正弦 ≈ 61 级，-60dBFS ≈ 14 级），静音（|X|²=0）输出 0。
//
// 清零：每窗结束 M_CLR 把 s1/s2 两块 BRAM 全部写 0。旧版 s2 的数据口接的是
// s1 的值（不是 0），s2 从未真正清零，残留状态在静音后仍持续激励输出——
// 频谱"乱跳、不跟音频"的根因。
//
// 周期预算：每样本 64bin×3 拍 = 192 拍（样本间隔 521 拍），窗口结尾
// M_OUT+M_CLR 共 576 拍，会丢掉 1 个样本，不影响窗口长度。
// ============================================================================
module audio_spectrum (
    input  wire               I_clk,          // 25MHz（I2S_receiver 输出域）
    input  wire               I_rst,
    input  wire               i_audio_valid,
    input  wire signed [23:0] i_audio_left,
    output reg  [191:0]       o_level         // 32 频段 × 6bit，band0 在 [5:0]
);

localparam integer N     = 1024;
localparam integer NBINS = 64;
localparam integer NB    = 32;

// Q13 系数 2cos(2πk/N)，按对数分布的 64 个 bin（k=1..341）
function signed [15:0] coef_lut;
    input [5:0] b;
    begin
        case (b)
            6'd0 : coef_lut = 16'sd16383;  // k=1    47Hz
            6'd1 : coef_lut = 16'sd16383;  // k=2    94Hz
            6'd2 : coef_lut = 16'sd16381;  // k=3   141Hz
            6'd3 : coef_lut = 16'sd16379;  // k=4   188Hz
            6'd4 : coef_lut = 16'sd16376;  // k=5   234Hz
            6'd5 : coef_lut = 16'sd16373;  // k=6   281Hz
            6'd6 : coef_lut = 16'sd16369;  // k=7   328Hz
            6'd7 : coef_lut = 16'sd16364;  // k=8   375Hz
            6'd8 : coef_lut = 16'sd16359;  // k=9   422Hz
            6'd9 : coef_lut = 16'sd16353;  // k=10  469Hz
            6'd10: coef_lut = 16'sd16347;  // k=11  516Hz
            6'd11: coef_lut = 16'sd16340;  // k=12  563Hz
            6'd12: coef_lut = 16'sd16332;  // k=13  609Hz
            6'd13: coef_lut = 16'sd16324;  // k=14  656Hz
            6'd14: coef_lut = 16'sd16315;  // k=15  703Hz
            6'd15: coef_lut = 16'sd16305;  // k=16  750Hz
            6'd16: coef_lut = 16'sd16295;  // k=17  797Hz
            6'd17: coef_lut = 16'sd16284;  // k=18  844Hz
            6'd18: coef_lut = 16'sd16273;  // k=19  891Hz
            6'd19: coef_lut = 16'sd16261;  // k=20  938Hz
            6'd20: coef_lut = 16'sd16248;  // k=21  984Hz
            6'd21: coef_lut = 16'sd16235;  // k=22 1031Hz
            6'd22: coef_lut = 16'sd16221;  // k=23 1078Hz
            6'd23: coef_lut = 16'sd16207;  // k=24 1125Hz
            6'd24: coef_lut = 16'sd16192;  // k=25 1172Hz
            6'd25: coef_lut = 16'sd16176;  // k=26 1219Hz
            6'd26: coef_lut = 16'sd16160;  // k=27 1266Hz
            6'd27: coef_lut = 16'sd16143;  // k=28 1313Hz
            6'd28: coef_lut = 16'sd16125;  // k=29 1359Hz
            6'd29: coef_lut = 16'sd16107;  // k=30 1406Hz
            6'd30: coef_lut = 16'sd16088;  // k=31 1453Hz
            6'd31: coef_lut = 16'sd16069;  // k=32 1500Hz
            6'd32: coef_lut = 16'sd16049;  // k=33 1547Hz
            6'd33: coef_lut = 16'sd16029;  // k=34 1594Hz
            6'd34: coef_lut = 16'sd16008;  // k=35 1641Hz
            6'd35: coef_lut = 16'sd15986;  // k=36 1688Hz
            6'd36: coef_lut = 16'sd15964;  // k=37 1734Hz
            6'd37: coef_lut = 16'sd15941;  // k=38 1781Hz
            6'd38: coef_lut = 16'sd15917;  // k=39 1828Hz
            6'd39: coef_lut = 16'sd15893;  // k=40 1875Hz
            6'd40: coef_lut = 16'sd15868;  // k=41 1922Hz
            6'd41: coef_lut = 16'sd15791;  // k=44 2063Hz
            6'd42: coef_lut = 16'sd15649;  // k=49 2297Hz
            6'd43: coef_lut = 16'sd15493;  // k=54 2531Hz
            6'd44: coef_lut = 16'sd15322;  // k=59 2766Hz
            6'd45: coef_lut = 16'sd15137;  // k=64 3000Hz
            6'd46: coef_lut = 16'sd14854;  // k=71 3328Hz
            6'd47: coef_lut = 16'sd14543;  // k=78 3656Hz
            6'd48: coef_lut = 16'sd14206;  // k=85 3984Hz
            6'd49: coef_lut = 16'sd13788;  // k=93 4359Hz
            6'd50: coef_lut = 16'sd13279;  // k=102 4781Hz
            6'd51: coef_lut = 16'sd12665;  // k=112 5250Hz
            6'd52: coef_lut = 16'sd11935;  // k=123 5766Hz
            6'd53: coef_lut = 16'sd11077;  // k=135 6328Hz
            6'd54: coef_lut = 16'sd10080;  // k=148 6938Hz
            6'd55: coef_lut = 16'sd8850;   // k=163 7641Hz
            6'd56: coef_lut = 16'sd7545;   // k=178 8344Hz
            6'd57: coef_lut = 16'sd5897;   // k=196 9188Hz
            6'd58: coef_lut = 16'sd4078;   // k=215 10078Hz
            6'd59: coef_lut = 16'sd2105;   // k=235 11016Hz
            6'd60: coef_lut = -16'sd201;   // k=258 12094Hz
            6'd61: coef_lut = -16'sd2702;  // k=283 13266Hz
            6'd62: coef_lut = -16'sd5425;  // k=311 14578Hz
            default: coef_lut = -16'sd8163;// k=341 15984Hz
        endcase
    end
endfunction

// 整数 log2（优先编码找 MSB）
function [5:0] log2i;
    input [37:0] v;
    integer i;
    begin
        log2i = 6'd0;
        for (i = 37; i >= 1; i = i - 1)
            if (v[i] && (log2i == 6'd0))
                log2i = i[5:0];
    end
endfunction

localparam M_IDLE = 2'd0;   // 等样本
localparam M_MAC  = 2'd1;   // 64 bin 串行递推
localparam M_OUT  = 2'd2;   // 窗口结束：逐 bin 算 |X|² 并输出
localparam M_CLR  = 2'd3;   // 清零状态寄存器，进入下一窗

reg [1:0]  mst;
reg [2:0]  phase;           // MAC: 0=地址稳定 1=乘 2=写回；OUT: 0=地址稳定 1~7
reg [5:0]  b_idx;
reg [10:0] n_cnt;
reg signed [15:0] x;
reg signed [43:0] prod;

// ---- Bartlett 窗：w[n] = 1 - |2n-(N-1)|/(N-1)，Q9 归一化后峰值 512 ----
wire [10:0] win_q = (n_cnt < 11'd512) ? (n_cnt + 11'd1)
                                      : (11'd1024 - n_cnt);   // 1..512
wire signed [15:0] x_in = $signed(i_audio_left[23:8]);
wire signed [27:0] xw_prod = x_in * $signed({1'b0, win_q});
wire signed [15:0] x_win = xw_prod >>> 9;               // 峰值增益 1.0

// Goertzel 状态 s1/s2 放 BRAM：64×28bit×2 组 = 3584bit，各占一块 9K
wire signed [27:0] s1_do, s2_do;
wire signed [43:0] mac_full = x + (prod >>> 13) - s2_do;
// 低频极点（k=1）遇到直流分量时状态会平方增长，28bit 有溢出回绕风险；
// 饱和比回绕好：只损失极端直流下的动态范围，不会把整个频谱搅乱
wire signed [27:0] mac_sum = (mac_full > 44'sd134217727) ? 28'sd134217727 :
                             (mac_full < -44'sd134217728) ? -28'sd134217728 :
                             mac_full[27:0];
wire               s1_we = (mst == M_MAC && phase == 3'd2) || (mst == M_CLR);
wire signed [27:0] s1_wdata = (mst == M_CLR) ? 28'sd0 : mac_sum;
// s2 的数据口在 MAC 写回时接 s1 的旧值，在清零阶段必须接 0
wire signed [27:0] s2_wdata = (mst == M_CLR) ? 28'sd0 : s1_do;

EG_LOGIC_BRAM #(
    .DATA_WIDTH_A(28), .ADDR_WIDTH_A(6), .DATA_WIDTH_B(28), .ADDR_WIDTH_B(6),
    .MODE("DP"), .REGMODE_A("NOREG"), .REGMODE_B("NOREG"),
    .WRITEMODE_A("NORMAL"), .WRITEMODE_B("NORMAL"),
    .RESETMODE("SYNC"), .IMPLEMENT("9K")
) u_s1_ram (
    .dia(s1_wdata), .addra(b_idx), .cea(1'b1), .ocea(1'b1),
    .clka(I_clk), .wea(s1_we), .rsta(1'b0), .bea(1'b1),
    .dib(28'd0), .addrb(6'd0), .ceb(1'b0), .oceb(1'b1),
    .clkb(I_clk), .web(1'b0), .rstb(1'b0), .beb(1'b1),
    .doa(s1_do), .dob()
);

EG_LOGIC_BRAM #(
    .DATA_WIDTH_A(28), .ADDR_WIDTH_A(6), .DATA_WIDTH_B(28), .ADDR_WIDTH_B(6),
    .MODE("DP"), .REGMODE_A("NOREG"), .REGMODE_B("NOREG"),
    .WRITEMODE_A("NORMAL"), .WRITEMODE_B("NORMAL"),
    .RESETMODE("SYNC"), .IMPLEMENT("9K")
) u_s2_ram (
    .dia(s2_wdata), .addra(b_idx), .cea(1'b1), .ocea(1'b1),
    .clka(I_clk), .wea(s1_we), .rsta(1'b0), .bea(1'b1),
    .dib(28'd0), .addrb(6'd0), .ceb(1'b0), .oceb(1'b1),
    .clkb(I_clk), .web(1'b0), .rstb(1'b0), .beb(1'b1),
    .doa(s2_do), .dob()
);

// |X|² 计算（状态量右移 10 位后平方）
reg signed [15:0] coef_d;
reg signed [17:0] sa, sb;
reg signed [35:0] sq1, sq2, ab;
reg signed [51:0] cab;
reg signed [37:0] pwr;

wire [37:0] pwr_abs = pwr[37] ? (~pwr + 38'd1) : pwr;
wire [5:0]  p_log   = log2i(pwr_abs);
// 功率 log2 → 电平：1 级 ≈ 1.28dB
// 0dBFS 满幅正弦 p_log≈26 → 61 级；pwr=0 或数值误差为负 → 0
wire [6:0]  lv_w    = ({1'b0, p_log} << 1) + ({1'b0, p_log} >> 2) +
                      ({1'b0, p_log} >> 3);
wire [5:0]  lv_new  = (pwr[37] || (pwr == 38'd0)) ? 6'd0 :
                      (lv_w > 7'd63) ? 6'd63 : lv_w[5:0];

// 每个显示频段取两个 bin 的较大电平；偶 bin 先暂存，奇 bin 合并输出
reg [5:0] lv_hold;

always @(posedge I_clk or posedge I_rst) begin
    if (I_rst) begin
        mst     <= M_IDLE;
        phase   <= 3'd0;
        b_idx   <= 6'd0;
        n_cnt   <= 11'd0;
        x       <= 16'sd0;
        prod    <= 44'sd0;
        coef_d  <= 16'sd0;
        sa      <= 18'sd0;
        sb      <= 18'sd0;
        sq1     <= 36'sd0;
        sq2     <= 36'sd0;
        ab      <= 36'sd0;
        cab     <= 52'sd0;
        pwr     <= 38'sd0;
        lv_hold <= 6'd0;
        o_level <= 192'd0;
    end else begin
        case (mst)
            M_IDLE: begin
                if (i_audio_valid) begin
                    x     <= x_win;          // 已乘 Bartlett 窗
                    b_idx <= 6'd0;
                    phase <= 3'd0;
                    mst   <= M_MAC;
                end
            end

            M_MAC: begin
                case (phase)
                    3'd0: begin               // 地址=b_idx，BRAM 输出下一拍有效
                        phase <= 3'd1;
                    end
                    3'd1: begin
                        prod  <= coef_lut(b_idx) * s1_do;   // s1_do = s1[b_idx]
                        phase <= 3'd2;
                    end
                    default: begin            // 写回：s1<=mac_sum, s2<=s1_do（见 s1_we）
                        phase <= 3'd0;
                        if (b_idx == NBINS - 1) begin
                            b_idx <= 6'd0;
                            if (n_cnt == N - 1) begin
                                mst   <= M_OUT;   // 窗口结束
                                phase <= 3'd0;
                            end else begin
                                n_cnt <= n_cnt + 11'd1;
                                mst   <= M_IDLE;  // 等下一个样本
                            end
                        end else
                            b_idx <= b_idx + 6'd1;
                    end
                endcase
            end

            M_OUT: begin
                case (phase)
                    3'd0: begin               // 地址=b_idx，BRAM 输出下一拍有效
                        phase  <= 3'd1;
                    end
                    3'd1: begin
                        sa     <= s1_do >>> 10;
                        sb     <= s2_do >>> 10;
                        coef_d <= coef_lut(b_idx);
                        phase  <= 3'd2;
                    end
                    3'd2: begin
                        sq1   <= sa * sa;
                        phase <= 3'd3;
                    end
                    3'd3: begin
                        sq2   <= sb * sb;
                        phase <= 3'd4;
                    end
                    3'd4: begin
                        ab    <= sa * sb;
                        phase <= 3'd5;
                    end
                    3'd5: begin
                        cab   <= coef_d * ab;
                        phase <= 3'd6;
                    end
                    3'd6: begin
                        pwr   <= sq1 + sq2 - (cab >>> 13);
                        phase <= 3'd7;
                    end
                    default: begin
                        if (b_idx[0] == 1'b0)
                            lv_hold <= lv_new;
                        else if (lv_new > lv_hold)
                            o_level[b_idx[5:1]*6 +: 6] <= lv_new;
                        else
                            o_level[b_idx[5:1]*6 +: 6] <= lv_hold;
                        phase <= 3'd0;
                        if (b_idx == NBINS - 1) begin
                            b_idx <= 6'd0;
                            mst   <= M_CLR;
                        end else
                            b_idx <= b_idx + 6'd1;
                    end
                endcase
            end

            // BRAM 版清零：逐地址写 0（64 拍，每窗一次，开销可忽略）
            M_CLR: begin
                b_idx <= (b_idx == NBINS - 1) ? 6'd0 : b_idx + 6'd1;
                if (b_idx == NBINS - 1) begin
                    n_cnt <= 11'd0;
                    phase <= 3'd0;
                    mst   <= M_IDLE;
                end
            end

            default: mst <= M_IDLE;
        endcase
    end
end

endmodule
