// ============================================================================
// danmaku_osd — 彩色弹幕滑屏（video_clk 域）
//
// 两条轨道，每条最多 24 字符、2x 字号（16px 字宽），从右向左以 8px/帧 移动。
// 新消息到达时先占用空闲轨道；两条都忙则暂存最新一条（1 深度），
// 待有轨道空出后再进场——旧弹幕一定滚出屏幕后才消失。
//
// 字符颜色按 (消息色号 + 字符序号) 取调色板，同一条弹幕内逐字变色。
// 文本经 toggle 握手跨到本域（数据在 ack 之前保持不变），无需异步 FIFO。
// ============================================================================
module danmaku_osd (
    input  wire        i_clk,
    input  wire        i_rst,
    input  wire        i_frame_tick,   // 每帧一拍（vs_rise）
    input  wire [10:0] i_x,
    input  wire [10:0] i_y,
    input  wire        i_en,

    input  wire [191:0] i_text,        // 24 字节，字符 0 在最低字节
    input  wire [4:0]   i_len,
    input  wire [3:0]   i_color,
    input  wire         i_tgl,         // 50MHz 域新消息 toggle
    output reg          o_ack,         // 回告（echo i_tgl）

    output reg         o_txt_on,
    output reg  [6:0]  o_char,
    output reg  [2:0]  o_row,
    output reg  [2:0]  o_col,
    output reg  [23:0] o_color
);

    localparam [10:0] X_IN   = 11'd648;    // 起始左边界（屏幕右侧外）
    localparam [10:0] STEP   = 11'd8;      // 每帧步进像素
    localparam [10:0] LANE0_Y = 11'd48;
    localparam [10:0] LANE1_Y = 11'd80;

    reg [2:0]  tgl_s;
    wire       new_msg = tgl_s[0] ^ tgl_s[1];

    // ---- 轨道状态 ----
    reg [191:0] l0_txt, l1_txt, pd_txt;
    reg [4:0]   l0_len, l1_len, pd_len;
    reg [3:0]   l0_col, l1_col, pd_col;
    reg [10:0]  l0_pos, l1_pos;
    reg         l0_busy, l1_busy, pd_vld;

    localparam [191:0] ZERO_TXT = 192'd0;

    always @(posedge i_clk or posedge i_rst) begin
        if (i_rst) begin
            tgl_s   <= 3'd0;
            o_ack   <= 1'b0;
            l0_txt  <= ZERO_TXT; l1_txt <= ZERO_TXT; pd_txt <= ZERO_TXT;
            l0_len  <= 5'd0; l1_len <= 5'd0; pd_len <= 5'd0;
            l0_col  <= 4'd0; l1_col <= 4'd0; pd_col <= 4'd0;
            l0_pos  <= 11'd0; l1_pos <= 11'd0;
            l0_busy <= 1'b0; l1_busy <= 1'b0; pd_vld <= 1'b0;
        end else begin
            tgl_s <= {tgl_s[1:0], i_tgl};

            if (new_msg) begin
                o_ack <= i_tgl;
                if (!l0_busy) begin
                    l0_txt <= i_text; l0_len <= i_len; l0_col <= i_color;
                    l0_pos <= 11'd0; l0_busy <= 1'b1;
                end else if (!l1_busy) begin
                    l1_txt <= i_text; l1_len <= i_len; l1_col <= i_color;
                    l1_pos <= 11'd0; l1_busy <= 1'b1;
                end else begin
                    pd_txt <= i_text; pd_len <= i_len; pd_col <= i_color;
                    pd_vld <= 1'b1;
                end
            end else if (i_frame_tick) begin
                if (l0_busy) begin
                    if (l0_pos >= X_IN + {l0_len, 4'd0}) begin
                        l0_pos <= 11'd0;
                        if (pd_vld) begin
                            l0_txt <= pd_txt; l0_len <= pd_len; l0_col <= pd_col;
                            pd_vld <= 1'b0;
                        end else
                            l0_busy <= 1'b0;
                    end else
                        l0_pos <= l0_pos + STEP;
                end
                if (l1_busy) begin
                    if (l1_pos >= X_IN + {l1_len, 4'd0}) begin
                        l1_pos <= 11'd0;
                        if (pd_vld) begin
                            l1_txt <= pd_txt; l1_len <= pd_len; l1_col <= pd_col;
                            pd_vld <= 1'b0;
                        end else
                            l1_busy <= 1'b0;
                    end else
                        l1_pos <= l1_pos + STEP;
                end
            end
        end
    end

    // ---- 像素求值 ----
    function [23:0] dm_color_of;
        input [2:0] idx;
        begin
            case (idx)
                3'd0: dm_color_of = 24'hFF5E5E;
                3'd1: dm_color_of = 24'hFFD166;
                3'd2: dm_color_of = 24'h5CFF7A;
                3'd3: dm_color_of = 24'h4FD1FF;
                3'd4: dm_color_of = 24'hC08BFF;
                3'd5: dm_color_of = 24'hFF8AE2;
                3'd6: dm_color_of = 24'hFFFFFF;
                default: dm_color_of = 24'h7CFFCB;
            endcase
        end
    endfunction

    // 左边界随 pos 左移，可越过屏幕左边（x0 为负），故用 12bit 有符号运算，
    // 否则 X_IN - pos 下溢会把整条弹幕提前抹掉。
    wire signed [11:0] x0_0 = 12'sd648 - $signed({1'b0, l0_pos});
    wire signed [11:0] x0_1 = 12'sd648 - $signed({1'b0, l1_pos});
    wire signed [11:0] xs   = $signed({1'b0, i_x});
    wire signed [11:0] dx0  = xs - x0_0;
    wire signed [11:0] dx1  = xs - x0_1;
    wire [4:0]  ci0  = dx0[8:4];
    wire [4:0]  ci1  = dx1[8:4];

    wire in0 = i_en && l0_busy && (xs >= x0_0) && (ci0 < l0_len) &&
               (i_y >= LANE0_Y) && (i_y < LANE0_Y + 11'd16);
    wire in1 = i_en && l1_busy && (xs >= x0_1) && (ci1 < l1_len) &&
               (i_y >= LANE1_Y) && (i_y < LANE1_Y + 11'd16);

    wire [4:0] m0 = (ci0 > 5'd23) ? 5'd23 : ci0;
    wire [4:0] m1 = (ci1 > 5'd23) ? 5'd23 : ci1;
    wire [7:0] ch0 = l0_txt[m0*8 +: 8];
    wire [7:0] ch1 = l1_txt[m1*8 +: 8];

    always @(*) begin
        o_txt_on = 1'b0;
        o_char   = 7'h20;
        o_row    = 3'd0;
        o_col    = 3'd0;
        o_color  = 24'hFFFFFF;
        if (in0) begin
            o_txt_on = 1'b1;
            o_char   = ch0[6:0];
            o_row    = (i_y - LANE0_Y) >> 1;
            o_col    = dx0[3:1];
            o_color  = dm_color_of(l0_col[2:0] + ci0[2:0]);
        end else if (in1) begin
            o_txt_on = 1'b1;
            o_char   = ch1[6:0];
            o_row    = (i_y - LANE1_Y) >> 1;
            o_col    = dx1[3:1];
            o_color  = dm_color_of(l1_col[2:0] + ci1[2:0]);
        end
    end

endmodule
