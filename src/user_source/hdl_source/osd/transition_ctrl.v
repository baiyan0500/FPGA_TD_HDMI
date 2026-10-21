// ============================================================================
// transition_ctrl — 图片切换转场（4 种模式）
//
// 插在 brightness_contrast 之后、OSD 叠加之前。对视频像素做转场遮罩：
//   mode 0 淡入淡出：alpha 256→0→256（旧图淡出→切图→新图淡入）
//   mode 1 右擦除  ：新图从左边擦入，边界左→右移动（x < boundary 显示）
//   mode 2 左擦除  ：新图从右边擦入，边界右→左移动（x >= 640-boundary 显示）
//   mode 3 下滑入  ：新图从上方滑入，边界上→下移动（y < boundary 显示）
//
// 握手（与 sd_card_bmp 用 toggle）：
//   sd_card_bmp 翻转 i_req → 本模块开始过渡；需要切图时翻转 o_swap；
//   sd_card_bmp 切图后再翻转 i_req → 本模块完成过渡显示新图。
//   mode 0 在淡出完成后才 o_swap；mode 1/2/3 无需淡出，收到 i_req 立即 o_swap。
//
// alpha/boundary 在垂直同步（vs_rise）帧边界更新，保证一帧内恒定、无撕裂。
// ============================================================================
module transition_ctrl #(
    parameter H_ACTIVE = 640,
    parameter V_ACTIVE = 480
)(
    input  wire        i_clk,      // video_clk 25MHz
    input  wire        i_rst,      // 高有效复位
    input  wire        i_vs,       // 垂直同步
    input  wire        i_de,       // 数据有效
    input  wire [1:0]  i_mode,     // 0=fade, 1=wipe_right, 2=wipe_left, 3=slide_down
    input  wire [23:0] i_rgb,
    input  wire        i_req,      // 过渡请求 toggle（跨域）
    output reg         o_swap,     // 切图请求 toggle（跨域）
    output wire [23:0] o_rgb
);
    localparam STEP   = 11'd32;                     // 每帧步进（640/32=20帧，480/32=15帧）
    localparam [8:0]  FADE_STEP = 9'd16;            // 淡入淡出每帧步进（16帧）

    localparam S_IDLE = 3'd0;
    localparam S_OUT  = 3'd1;
    localparam S_WAIT = 3'd2;
    localparam S_IN   = 3'd3;

    reg [2:0] state;
    reg [8:0] alpha;                               // 0..256（fade 用）
    reg [10:0] boundary;                           // 0..target（wipe/slide 用）
    reg        pend_req;                           // S_OUT/S_IN 期间收到的请求锁存，回 IDLE 后处理，防止握手脉冲丢失

    reg [2:0] req_sync;
    wire      req_edge = req_sync[2] ^ req_sync[1];
    reg       vs_d;
    wire      vs_rise = i_vs & ~vs_d;

    // 上电 alpha=256 保持全亮：首图加载后 display_valid 拉高即可立即显示，
    // 避免从 0 开始 fade 导致首图出现黑屏/白屏闪烁

    // 像素位置跟踪
    reg [10:0] x, y;
    reg        de_d;
    wire       de_rise = i_de & ~de_d;

    wire [10:0] target = (i_mode == 2'd3) ? V_ACTIVE : H_ACTIVE;

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
            x <= 0; y <= 0; de_d <= 1'b0;
        end else begin
            de_d <= i_de;
            if (vs_rise)      y <= 0;
            else if (de_rise) y <= y + 1;
            if (!i_de) x <= 0;
            else       x <= x + 1;
        end
    end

    always @(posedge i_clk or posedge i_rst) begin
        if (i_rst) begin
            state    <= S_IDLE;
            alpha    <= 9'd256;                     // 上电保持全亮，首图直接显示
            boundary <= 11'd0;
            o_swap   <= 1'b0;
            pend_req <= 1'b0;
        end else begin
            case (state)
                S_IDLE: begin
                    alpha <= 9'd256;                // 空闲时保持全亮
                    if (req_edge || pend_req) begin
                        pend_req <= 1'b0;
                        state    <= S_OUT;
                    end
                end
                S_OUT: begin
                    if (req_edge) pend_req <= 1'b1;
                    if (i_mode == 2'd0) begin
                        // 淡出旧图
                        if (vs_rise) begin
                            if (alpha > FADE_STEP) alpha <= alpha - FADE_STEP;
                            else begin
                                alpha  <= 9'd0;
                                o_swap <= ~o_swap;
                                state  <= S_WAIT;
                            end
                        end
                    end else begin
                        // wipe/slide：无需淡出，立即切图
                        boundary <= 11'd0;
                        o_swap   <= ~o_swap;
                        state    <= S_WAIT;
                    end
                end
                S_WAIT: begin
                    if (req_edge) state <= S_IN;
                end
                S_IN: begin
                    if (req_edge) pend_req <= 1'b1;
                    if (i_mode == 2'd0) begin
                        // 淡入新图
                        if (vs_rise) begin
                            if (alpha < 9'd256 - FADE_STEP) alpha <= alpha + FADE_STEP;
                            else begin alpha <= 9'd256; state <= S_IDLE; end
                        end
                    end else begin
                        // 遮罩边界推进
                        if (vs_rise) begin
                            if (boundary < target - STEP) boundary <= boundary + STEP;
                            else begin boundary <= target; state <= S_IDLE; end
                        end
                    end
                end
                default: state <= S_IDLE;
            endcase
        end
    end

    // ---- 输出像素（组合）----
    // fade 模式：alpha 增益；wipe/slide 模式：位置遮罩
    wire [7:0] fade_r = ({8'd0, i_rgb[23:16]} * alpha) >> 8;
    wire [7:0] fade_g = ({8'd0, i_rgb[15:8]}  * alpha) >> 8;
    wire [7:0] fade_b = ({8'd0, i_rgb[7:0]}   * alpha) >> 8;

    reg wipe_on;
    always @(*) begin
        case (i_mode)
            2'd1: wipe_on = (x < boundary);                  // 右擦：左→右
            2'd2: wipe_on = (x >= H_ACTIVE - boundary);      // 左擦：右→左
            2'd3: wipe_on = (y < boundary);                  // 下滑：上→下
            default: wipe_on = 1'b0;
        endcase
    end

    reg [23:0] o_rgb_c;
    always @(*) begin
        if (state == S_IDLE)
            o_rgb_c = i_rgb;                    // 空闲时透传，避免模式切换瞬间 boundary=0 导致黑屏
        else if (i_mode == 2'd0)
            o_rgb_c = {fade_r, fade_g, fade_b};
        else
            o_rgb_c = wipe_on ? i_rgb : 24'd0;
    end
    assign o_rgb = o_rgb_c;
endmodule
