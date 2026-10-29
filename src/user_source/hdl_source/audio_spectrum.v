// ============================================================================
// audio_spectrum — Goertzel 32 频段频谱分析（video_clk 25MHz 域）
//
// 输入：I2S_receiver 输出的 48kHz PCM 帧（audio_valid/audio_left_data）。
// 每 1024 样本（约 21.3ms）窗口对 32 个对数分布频段做 Goertzel 递推：
//   s[n] = x[n] + (coef × s[n-1] >> 13) - s[n-2]，coef = 2cos(2πk/N) 的 Q13 定点
//   频段 k = 1,2,3,...,341 → 中心频率约 47Hz ~ 16kHz @48k。
// 窗口结束后用标准 Goertzel 功率公式：
//   |X(k)|² = s1² + s2² - coef·s1·s2
// 再取 log2 映射到 6bit 电平（0~63），具有正确的频段选择性。
// 状态量右移 10 位后再平方，节省乘法器位宽。
// ============================================================================
module audio_spectrum (
    input  wire               I_clk,          // 25MHz（I2S_receiver 输出域）
    input  wire               I_rst,
    input  wire               i_audio_valid,
    input  wire signed [23:0] i_audio_left,
    output reg  [191:0]       o_level         // 32 频段 × 6bit，band0 在 [5:0]
);

localparam integer N  = 1024;
localparam integer NB = 32;

// Q13 系数 2cos(2πk/N)，k 为 47Hz~16kHz 对数分布的 32 个 bin
function signed [15:0] coef_lut;
    input [4:0] b;
    begin
        case (b)
            5'd0 : coef_lut = 16'sd16383;  // k=1    47Hz
            5'd1 : coef_lut = 16'sd16383;  // k=2    94Hz
            5'd2 : coef_lut = 16'sd16381;  // k=3   141Hz
            5'd3 : coef_lut = 16'sd16379;  // k=4   188Hz
            5'd4 : coef_lut = 16'sd16376;  // k=5   234Hz
            5'd5 : coef_lut = 16'sd16373;  // k=6   281Hz
            5'd6 : coef_lut = 16'sd16364;  // k=8   375Hz
            5'd7 : coef_lut = 16'sd16359;  // k=9   422Hz
            5'd8 : coef_lut = 16'sd16353;  // k=10  469Hz
            5'd9 : coef_lut = 16'sd16347;  // k=11  516Hz
            5'd10: coef_lut = 16'sd16340;  // k=12  563Hz
            5'd11: coef_lut = 16'sd16324;  // k=14  656Hz
            5'd12: coef_lut = 16'sd16315;  // k=15  703Hz
            5'd13: coef_lut = 16'sd16295;  // k=17  797Hz
            5'd14: coef_lut = 16'sd16261;  // k=20  938Hz
            5'd15: coef_lut = 16'sd16207;  // k=24 1125Hz
            5'd16: coef_lut = 16'sd16143;  // k=28 1313Hz
            5'd17: coef_lut = 16'sd16049;  // k=33 1547Hz
            5'd18: coef_lut = 16'sd15893;  // k=40 1875Hz
            5'd19: coef_lut = 16'sd15707;  // k=47 2203Hz
            5'd20: coef_lut = 16'sd15460;  // k=55 2578Hz
            5'd21: coef_lut = 16'sd15098;  // k=65 3047Hz
            5'd22: coef_lut = 16'sd14589;  // k=77 3609Hz
            5'd23: coef_lut = 16'sd13896;  // k=91 4266Hz
            5'd24: coef_lut = 16'sd12978;  // k=107 5016Hz
            5'd25: coef_lut = 16'sd11727;  // k=126 5906Hz
            5'd26: coef_lut = 16'sd10001;  // k=149 6984Hz
            5'd27: coef_lut = 16'sd7723;   // k=176 8250Hz
            5'd28: coef_lut = 16'sd4852;   // k=207 9703Hz
            5'd29: coef_lut = 16'sd1105;   // k=245 11484Hz
            5'd30: coef_lut = -16'sd3295;  // k=289 13547Hz
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
localparam M_MAC  = 2'd1;   // 32 频段串行递推
localparam M_OUT  = 2'd2;   // 窗口结束：逐频段算 |X|² 并输出
localparam M_CLR  = 2'd3;   // 清零状态寄存器，进入下一窗

reg [1:0]  mst;
reg [2:0]  phase;           // MAC: 0=地址稳定 1=乘 2=写回；OUT: 0=地址稳定 1~7
reg [4:0]  b_idx;
reg [10:0] n_cnt;
reg signed [15:0] x;
reg signed [43:0] prod;

// Goertzel 状态 s1/s2 放 BRAM：32×28bit×2 组寄存器要吃掉 1792 个触发器（≈1/6 个器件），
// 换成两块 9K BRAM 后片内只剩读写地址/数据通路，时序与面积都宽松得多
wire signed [27:0] s1_do, s2_do;
wire signed [27:0] mac_sum = x + (prod >>> 13) - s2_do;
wire               s1_we = (mst == M_MAC && phase == 3'd2) || (mst == M_CLR);
wire signed [27:0] s1_wdata = (mst == M_CLR) ? 28'sd0 : mac_sum;

EG_LOGIC_BRAM #(
    .DATA_WIDTH_A(28), .ADDR_WIDTH_A(5), .DATA_WIDTH_B(28), .ADDR_WIDTH_B(5),
    .MODE("DP"), .REGMODE_A("NOREG"), .REGMODE_B("NOREG"),
    .WRITEMODE_A("NORMAL"), .WRITEMODE_B("NORMAL"),
    .RESETMODE("SYNC"), .IMPLEMENT("9K")
) u_s1_ram (
    .dia(s1_wdata), .addra(b_idx), .cea(1'b1), .ocea(1'b1),
    .clka(I_clk), .wea(s1_we), .rsta(1'b0), .bea(1'b1),
    .dib(28'd0), .addrb(5'd0), .ceb(1'b0), .oceb(1'b1),
    .clkb(I_clk), .web(1'b0), .rstb(1'b0), .beb(1'b1),
    .doa(s1_do), .dob()
);

EG_LOGIC_BRAM #(
    .DATA_WIDTH_A(28), .ADDR_WIDTH_A(5), .DATA_WIDTH_B(28), .ADDR_WIDTH_B(5),
    .MODE("DP"), .REGMODE_A("NOREG"), .REGMODE_B("NOREG"),
    .WRITEMODE_A("NORMAL"), .WRITEMODE_B("NORMAL"),
    .RESETMODE("SYNC"), .IMPLEMENT("9K")
) u_s2_ram (
    .dia(s1_do), .addra(b_idx), .cea(1'b1), .ocea(1'b1),
    .clka(I_clk), .wea(s1_we), .rsta(1'b0), .bea(1'b1),
    .dib(28'd0), .addrb(5'd0), .ceb(1'b0), .oceb(1'b1),
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
wire [5:0]  amp_log = (pwr[37] || (pwr == 38'd0)) ? 6'd0 :
                      ((p_log >> 1) + 6'd10);
wire [6:0]  lv_scaled = (amp_log > 6'd12) ?
                        (({1'b0, amp_log} - 7'd12) << 2) : 7'd0;
wire [5:0]  lv_new = (lv_scaled > 7'd63) ? 6'd63 : lv_scaled[5:0];

always @(posedge I_clk or posedge I_rst) begin
    if (I_rst) begin
        mst     <= M_IDLE;
        phase   <= 3'd0;
        b_idx   <= 5'd0;
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
        o_level <= 192'd0;
    end else begin
        case (mst)
            M_IDLE: begin
                if (i_audio_valid) begin
                    x     <= i_audio_left[23:8];
                    b_idx <= 5'd0;
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
                        if (b_idx == NB - 1) begin
                            b_idx <= 5'd0;
                            if (n_cnt == N - 1) begin
                                mst   <= M_OUT;   // 窗口结束
                                phase <= 3'd0;
                            end else begin
                                n_cnt <= n_cnt + 11'd1;
                                mst   <= M_IDLE;  // 等下一个样本
                            end
                        end else
                            b_idx <= b_idx + 5'd1;
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
                        o_level[b_idx*6 +: 6] <= lv_new;
                        phase <= 3'd0;
                        if (b_idx == NB - 1) begin
                            b_idx <= 5'd0;
                            mst   <= M_CLR;
                        end else
                            b_idx <= b_idx + 5'd1;
                    end
                endcase
            end

            // BRAM 版清零：逐地址写 0（32 拍，每窗一次，开销可忽略）
            M_CLR: begin
                b_idx <= (b_idx == NB - 1) ? 5'd0 : b_idx + 5'd1;
                if (b_idx == NB - 1) begin
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
