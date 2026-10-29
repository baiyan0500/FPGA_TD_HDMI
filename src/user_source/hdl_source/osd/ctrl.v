// ============================================================================
// ctrl — 按键 / 拨码控制模块（视频时钟域）
//
// 功能层（优先级 SW1 > SW2 > SW3）：
//   层1  SW1=1
//        K1 转场模式循环 0..3
//        K2 手动切下一张（本模块不处理，只输出 o_next_img_en 给 SD 装载器门控）
//        K3 亮度   20/40/60/80/100% 循环
//        K4 对比度 20/40/60/80/100% 循环
//   层2  SW1=0, SW2=1
//        K1 转场模式循环
//        K2 自动轮播 启动/停止
//        K3 音频 暂停/继续（WAV）
//        K4 显示状态三态循环：0=全关 → 1=音量条 → 2=音量条+频谱
//   层3  SW1=0, SW2=0, SW3=1
//        K1 视频播放/停止
//        K2 弹幕 开/关
//        K3 频谱图 开/关
//        K4 资源占用面板 开/关
// ============================================================================
module ctrl (
    input  wire        i_clk,        // video_clk 25MHz
    input  wire        i_rst,        // 高有效复位
    input  wire        i_k1,
    input  wire        i_k2,
    input  wire        i_k3,
    input  wire        i_k4,
    input  wire [3:0]  i_sw,

    output reg  [1:0]  o_layer,      // 1/2/3，0=无功能层
    output reg  [1:0]  o_mode,       // 转场模式 0~3
    output reg  [2:0]  o_bright,     // 亮度档 0~4
    output reg  [2:0]  o_contrast,   // 对比度档 0~4
    output reg         o_next_img_en,// 层1：K2 允许切图
    output reg         o_auto_play,  // 层2：自动轮播
    output reg         o_audio_pause,// 层2：WAV 暂停
    output reg  [1:0]  o_viz_mode,   // 层2：0 关 / 1 音量 / 2 音量+频谱
    output reg         o_video_play, // 层3：视频播放
    output reg         o_danmaku_en, // 层3：弹幕
    output reg         o_spectrum_en,// 层3：频谱
    output reg         o_resmon_en   // 层3：资源面板
);

    wire k1_press, k2_press, k3_press, k4_press;

    key_press_debounce #(
        .CLK_FREQ_HZ (25_000_000), .DEBOUNCE_MS (20)
    ) u_k1 (.clk(i_clk), .rst(i_rst), .button_in(i_k1), .press_pulse(k1_press));
    key_press_debounce #(
        .CLK_FREQ_HZ (25_000_000), .DEBOUNCE_MS (20)
    ) u_k2 (.clk(i_clk), .rst(i_rst), .button_in(i_k2), .press_pulse(k2_press));
    key_press_debounce #(
        .CLK_FREQ_HZ (25_000_000), .DEBOUNCE_MS (20)
    ) u_k3 (.clk(i_clk), .rst(i_rst), .button_in(i_k3), .press_pulse(k3_press));
    key_press_debounce #(
        .CLK_FREQ_HZ (25_000_000), .DEBOUNCE_MS (20)
    ) u_k4 (.clk(i_clk), .rst(i_rst), .button_in(i_k4), .press_pulse(k4_press));

    wire layer1_en =  i_sw[0];
    wire layer2_en = ~i_sw[0] &  i_sw[1];
    wire layer3_en = ~i_sw[0] & ~i_sw[1] & i_sw[2];

    always @(posedge i_clk or posedge i_rst) begin
        if (i_rst) begin
            o_layer       <= 2'd0;
            o_mode        <= 2'd0;
            o_bright      <= 3'd4;
            o_contrast    <= 3'd4;
            o_next_img_en <= 1'b0;
            o_auto_play   <= 1'b0;
            o_audio_pause <= 1'b0;
            o_viz_mode    <= 2'd0;
            o_video_play  <= 1'b0;
            o_danmaku_en  <= 1'b1;
            o_spectrum_en <= 1'b0;
            o_resmon_en   <= 1'b0;
        end else begin
            o_next_img_en <= layer1_en;

            if (layer1_en) begin
                o_layer <= 2'd1;
                if (k1_press) o_mode     <= (o_mode == 2'd3) ? 2'd0 : o_mode + 2'd1;
                if (k3_press) o_bright   <= (o_bright   == 3'd4) ? 3'd0 : o_bright   + 3'd1;
                if (k4_press) o_contrast <= (o_contrast == 3'd4) ? 3'd0 : o_contrast + 3'd1;
                o_auto_play <= 1'b0;
                o_viz_mode  <= 2'd0;
                o_video_play <= 1'b0;
            end else if (layer2_en) begin
                o_layer <= 2'd2;
                if (k1_press) o_mode      <= (o_mode == 2'd3) ? 2'd0 : o_mode + 2'd1;
                if (k2_press) o_auto_play <= ~o_auto_play;
                if (k3_press) o_audio_pause <= ~o_audio_pause;
                if (k4_press) o_viz_mode  <= (o_viz_mode == 2'd2) ? 2'd0 : o_viz_mode + 2'd1;
                o_video_play <= 1'b0;
            end else if (layer3_en) begin
                o_layer <= 2'd3;
                if (k1_press) o_video_play  <= ~o_video_play;
                if (k2_press) o_danmaku_en  <= ~o_danmaku_en;
                if (k3_press) o_spectrum_en <= ~o_spectrum_en;
                if (k4_press) o_resmon_en   <= ~o_resmon_en;
                o_auto_play <= 1'b0;
                o_viz_mode  <= 2'd0;
            end else begin
                o_layer      <= 2'd0;
                o_auto_play  <= 1'b0;
                o_viz_mode   <= 2'd0;
                o_video_play <= 1'b0;
            end
        end
    end
endmodule
