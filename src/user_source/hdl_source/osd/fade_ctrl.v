// ============================================================================
// fade_ctrl — 图片切换淡入淡出过渡（fade-out → 切图 → fade-in）
//
// 插在 brightness_contrast 之后、OSD 叠加之前。对视频像素做全局 alpha 增益：
//   o_rgb = i_rgb * alpha / 256
// OSD 文字在其后生成，因此过渡期间标题栏/时间戳始终可见。
//
// 过渡时序（与 sd_card_bmp 的切换逻辑用 toggle 握手）：
//   sd_card_bmp 翻转 i_req  →  本模块开始 FADE_OUT（alpha 256→0，逐帧）
//   FADE_OUT 结束           →  翻转 o_swap（通知 sd_card_bmp 现在可以切 disp_buf_idx）
//   sd_card_bmp 切图后再次翻转 i_req → 本模块开始 FADE_IN（alpha 0→256，逐帧）
//
// alpha 在垂直同步（vs_rise）帧边界更新，保证一帧内 alpha 恒定、无撕裂。
// ============================================================================
module fade_ctrl (
    input  wire        i_clk,      // video_clk 25MHz
    input  wire        i_rst,      // 高有效复位
    input  wire        i_vs,       // 垂直同步（帧边界）
    input  wire [23:0] i_rgb,
    input  wire        i_req,      // 过渡请求 toggle（sd_card_clk 域，跨域同步）
    output reg         o_swap,     // 淡出完成，可切图（toggle，回 sd_card_clk 域）
    output wire [23:0] o_rgb
);
    localparam STEP = 9'd16;               // 每帧 alpha 步进（256/16 = 16 帧过渡）

    localparam S_IDLE      = 3'd0;
    localparam S_FADE_OUT  = 3'd1;
    localparam S_WAIT_SWAP = 3'd2;
    localparam S_FADE_IN   = 3'd3;

    reg [2:0] state;
    reg [8:0] alpha;                       // 0..256

    reg [2:0] req_sync;                    // i_req 3 级同步
    wire      req_edge = req_sync[2] ^ req_sync[1];

    reg       vs_d;
    wire      vs_rise = i_vs & ~vs_d;

    always @(posedge i_clk or posedge i_rst) begin
        if (i_rst) req_sync <= 3'd0;
        else       req_sync <= {req_sync[1:0], i_req};
    end

    always @(posedge i_clk or posedge i_rst) begin
        if (i_rst) vs_d <= 1'b0;
        else       vs_d <= i_vs;
    end

    always @(posedge i_clk or posedge i_rst) begin
        if (i_rst) begin
            state  <= S_IDLE;
            alpha  <= 9'd256;
            o_swap <= 1'b0;
        end else begin
            case (state)
                S_IDLE: begin
                    alpha <= 9'd256;
                    if (req_edge) state <= S_FADE_OUT;
                end
                S_FADE_OUT: begin
                    if (vs_rise) begin
                        if (alpha > STEP) begin
                            alpha <= alpha - STEP;
                        end else begin
                            alpha  <= 9'd0;
                            o_swap <= ~o_swap;
                            state  <= S_WAIT_SWAP;
                        end
                    end
                end
                S_WAIT_SWAP: begin
                    alpha <= 9'd0;
                    if (req_edge) state <= S_FADE_IN;
                end
                S_FADE_IN: begin
                    if (vs_rise) begin
                        if (alpha < 9'd256 - STEP) begin
                            alpha <= alpha + STEP;
                        end else begin
                            alpha <= 9'd256;
                            state <= S_IDLE;
                        end
                    end
                end
                default: state <= S_IDLE;
            endcase
        end
    end

    // 像素 alpha 增益（组合，不引入流水延迟，保持与 hs/vs/de 对齐）
    // 注意：操作数需显式扩展到 16 位，否则 Verilog 乘法结果位宽取 max(8,9)=9 位会溢出。
    wire [7:0] r_out = ({8'd0, i_rgb[23:16]} * alpha) >> 8;
    wire [7:0] g_out = ({8'd0, i_rgb[15:8]}  * alpha) >> 8;
    wire [7:0] b_out = ({8'd0, i_rgb[7:0]}   * alpha) >> 8;
    assign o_rgb = {r_out, g_out, b_out};
endmodule
