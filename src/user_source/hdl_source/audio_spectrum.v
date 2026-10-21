// ============================================================================
// audio_spectrum — Goertzel 8 频段频谱分析（video_clk 25MHz 域）
//
// 输入：I2S_receiver 输出的 48kHz PCM 帧（audio_valid/audio_left_data）。
// 每 512 样本（约 10.7ms）窗口对 8 个频段做 Goertzel 递推：
//   s[n] = x[n] + (coef × s[n-1] >> 13) - s[n-2]，coef = 2cos(2πk/N) 的 Q13 定点
//   频段 k = 1,2,4,8,16,28,48,84 → 中心频率约 94~7875Hz @48k
// 幅度近似 |s1|+|s2| → log2 → 线性映射到 6bit 电平（0~63）。
// 每样本 8 频段串行 MAC（3 拍/频段 = 24 拍 < 520 拍样本间隔）。
// ============================================================================
module audio_spectrum (
    input  wire               I_clk,          // 25MHz（I2S_receiver 输出域）
    input  wire               I_rst,
    input  wire               i_audio_valid,
    input  wire signed [23:0] i_audio_left,
    output reg  [47:0]        o_level         // 8 频段 × 6bit，band0 在 [5:0]
);

localparam integer N = 512;

// Q13 系数 2cos(2πk/N)
function signed [15:0] coef_lut;
    input [2:0] b;
    begin
        case (b)
            3'd0: coef_lut = 16'sd16383;  // k=1
            3'd1: coef_lut = 16'sd16379;  // k=2
            3'd2: coef_lut = 16'sd16364;  // k=4
            3'd3: coef_lut = 16'sd16305;  // k=8
            3'd4: coef_lut = 16'sd16069;  // k=16
            3'd5: coef_lut = 16'sd15426;  // k=28
            3'd6: coef_lut = 16'sd13623;  // k=48
            default: coef_lut = 16'sd8423; // k=84
        endcase
    end
endfunction

// 整数 log2（优先编码找 MSB）
function [5:0] log2i;
    input [33:0] v;
    integer i;
    begin
        log2i = 6'd0;
        for (i = 33; i >= 1; i = i - 1)
            if (v[i] && (log2i == 6'd0))
                log2i = i[5:0];
    end
endfunction

localparam M_IDLE = 2'd0;   // 等样本
localparam M_MAC  = 2'd1;   // 8 频段串行递推
localparam M_OUT  = 2'd2;   // 窗口结束：逐频段求幅度并输出
localparam M_CLR  = 2'd3;   // 清零状态寄存器，进入下一窗

reg [1:0]  mst;
reg [1:0]  phase;           // MAC: 0=读 1=乘 2=写回；OUT: 0=读 1=锁存
reg [2:0]  b_idx;
reg [9:0]  n_cnt;
reg signed [15:0] x;
reg signed [33:0] s1 [0:7];
reg signed [33:0] s2 [0:7];
reg signed [33:0] s1_d, s2_d;
reg signed [49:0] prod;

wire signed [33:0] mac_sum = x + (prod >>> 13) - s2_d;
wire [33:0] amp = (s1_d[33] ? (~s1_d + 34'd1) : s1_d) +
                  (s2_d[33] ? (~s2_d + 34'd1) : s2_d);
wire [5:0]  amp_log = log2i(amp);
wire [6:0]  lv_raw  = (amp_log * 7'd66) >> 5;
wire [5:0]  lv      = (amp_log < 6'd6) ? 6'd0 :   // 噪声门限
                      ((lv_raw > 7'd63) ? 6'd63 : lv_raw[5:0]);

integer k;

always @(posedge I_clk or posedge I_rst) begin
    if (I_rst) begin
        mst     <= M_IDLE;
        phase   <= 2'd0;
        b_idx   <= 3'd0;
        n_cnt   <= 10'd0;
        x       <= 16'sd0;
        s1_d    <= 34'sd0;
        s2_d    <= 34'sd0;
        prod    <= 50'sd0;
        o_level <= 48'd0;
        for (k = 0; k < 8; k = k + 1) begin
            s1[k] <= 34'sd0;
            s2[k] <= 34'sd0;
        end
    end else begin
        case (mst)
            M_IDLE: begin
                if (i_audio_valid) begin
                    x     <= i_audio_left[23:8];
                    b_idx <= 3'd0;
                    phase <= 2'd0;
                    mst   <= M_MAC;
                end
            end

            M_MAC: begin
                case (phase)
                    2'd0: begin
                        s1_d  <= s1[b_idx];       // 读 s1/s2
                        s2_d  <= s2[b_idx];
                        phase <= 2'd1;
                    end
                    2'd1: begin
                        prod  <= coef_lut(b_idx) * s1_d;   // 乘系数
                        phase <= 2'd2;
                    end
                    default: begin
                        s2[b_idx] <= s1_d;        // 写回递推结果
                        s1[b_idx] <= mac_sum;
                        phase <= 2'd0;
                        if (b_idx == 3'd7) begin
                            b_idx <= 3'd0;
                            if (n_cnt == N - 1)
                                mst <= M_OUT;     // 窗口结束
                            else begin
                                n_cnt <= n_cnt + 10'd1;
                                mst   <= M_IDLE;  // 等下一个样本
                            end
                        end else
                            b_idx <= b_idx + 3'd1;
                    end
                endcase
            end

            M_OUT: begin
                if (!phase) begin
                    s1_d  <= s1[b_idx];
                    s2_d  <= s2[b_idx];
                    phase <= 2'd1;
                end else begin
                    o_level[b_idx*6 -: 6] <= lv;
                    phase <= 2'd0;
                    if (b_idx == 3'd7)
                        mst <= M_CLR;
                    else
                        b_idx <= b_idx + 3'd1;
                end
            end

            M_CLR: begin
                for (k = 0; k < 8; k = k + 1) begin
                    s1[k] <= 34'sd0;
                    s2[k] <= 34'sd0;
                end
                n_cnt <= 10'd0;
                b_idx <= 3'd0;
                phase <= 2'd0;
                mst   <= M_IDLE;
            end

            default: mst <= M_IDLE;
        endcase
    end
end

endmodule
