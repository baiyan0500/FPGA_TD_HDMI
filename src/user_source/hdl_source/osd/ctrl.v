// ============================================================================
// ctrl — 按键 / 拨码控制模块（视频时钟域）
//
// 功能层选择：拨码 SW1~SW4，SW1 拉高 = 层1（显示控制），优先级 SW1>SW2>SW3>SW4。
// 层1 内按键功能：
//   K1  转场模式选择：0=淡入淡出, 1=右擦除, 2=左擦除, 3=下滑入（循环）
//   K2  切图（直接接 sd_card_bmp，不经本模块）
//   K3  对比度：20/40/60/80/100% 循环（按一下 +1 档，100→20）
//   K4  亮度  ：20/40/60/80/100% 循环
//
// 输出 o_mode/o_bright/o_contrast 与 brightness_contrast、transition_ctrl、OSD
// 同处 video_clk 域，无跨域问题。
// ============================================================================
module ctrl (
    input  wire        i_clk,      // video_clk 25MHz
    input  wire        i_rst,      // 高有效复位
    input  wire        i_k1,       // 转场模式选择
    input  wire        i_k3,       // 对比度
    input  wire        i_k4,       // 亮度
    input  wire [3:0]  i_sw,       // SW1~SW4 功能层选择
    output reg  [1:0]  o_mode,     // 转场模式 0~3
    output reg  [2:0]  o_bright,   // 亮度档 0~4
    output reg  [2:0]  o_contrast  // 对比度档 0~4
);
    wire k1_press, k3_press, k4_press;

    key_press_debounce #(
        .CLK_FREQ_HZ (25_000_000),
        .DEBOUNCE_MS (20)
    ) u_k1 (
        .clk(i_clk), .rst(i_rst), .button_in(i_k1), .press_pulse(k1_press)
    );
    key_press_debounce #(
        .CLK_FREQ_HZ (25_000_000),
        .DEBOUNCE_MS (20)
    ) u_k3 (
        .clk(i_clk), .rst(i_rst), .button_in(i_k3), .press_pulse(k3_press)
    );
    key_press_debounce #(
        .CLK_FREQ_HZ (25_000_000),
        .DEBOUNCE_MS (20)
    ) u_k4 (
        .clk(i_clk), .rst(i_rst), .button_in(i_k4), .press_pulse(k4_press)
    );

    wire layer1_en = i_sw[0];    // SW1 拉高 = 层1 使能（SW2~4 预留，后续扩展）

    always @(posedge i_clk or posedge i_rst) begin
        if (i_rst) begin
            o_mode     <= 2'd0;
            o_bright   <= 3'd4;    // 100%
            o_contrast <= 3'd4;    // 100%
        end else if (layer1_en) begin
            if (k1_press) o_mode <= (o_mode == 2'd3) ? 2'd0 : o_mode + 2'd1;
            if (k3_press) o_contrast <= (o_contrast == 3'd4) ? 3'd0 : o_contrast + 3'd1;
            if (k4_press) o_bright   <= (o_bright   == 3'd4) ? 3'd0 : o_bright   + 3'd1;
        end
    end
endmodule
