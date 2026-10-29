// ============================================================================
// resmon_osd — 实时资源占用可视化面板（层3，K4 开关）
//
// 4 条占用率横条（LUT/FF/RAM/DSP，常量取自 TD 布局布线报告）
// + 2 行实时信息（当前视频帧号、视频播放状态）。
// 文本统一交给 osd_layer 的共享字库渲染：
//   o_txt_on/o_char/o_row/o_col/o_color
// 面板底色与横条走背景通道：
//   o_bg_on / o_bg_color
// ============================================================================
module resmon_osd #(
    parameter integer LUT_PCT = 76,
    parameter integer FF_PCT  = 41,
    parameter integer RAM_PCT = 47,
    parameter integer DSP_PCT = 12
)(
    input  wire        i_clk,
    input  wire        i_rst,
    input  wire [10:0] i_x,
    input  wire [10:0] i_y,
    input  wire        i_en,          // 面板使能（已含层判断）
    input  wire [19:0] i_frame_bcd,   // 0~99999 BCD，5 位
    input  wire        i_video_on,

    output wire        o_txt_on,
    output wire [6:0]  o_char,
    output wire [2:0]  o_row,
    output wire [2:0]  o_col,
    output wire [23:0] o_color,
    output wire        o_bg_on,
    output wire [23:0] o_bg_color
);

    // ---- 面板几何 ----
    localparam [10:0] P_X0 = 11'd40;
    localparam [10:0] P_X1 = 11'd424;
    localparam [10:0] P_Y0 = 11'd120;
    localparam [10:0] P_Y1 = 11'd280;

    localparam [10:0] TX_X  = 11'd56;      // 标题
    localparam [10:0] TX_Y  = 11'd132;
    localparam [10:0] LB_X  = 11'd56;      // 标签列
    localparam [10:0] BAR_X = 11'd104;     // 横条起点
    localparam [10:0] BAR_W = 11'd192;     // 横条满量程宽度
    localparam [10:0] PCT_X = 11'd304;     // 百分比文字
    localparam [10:0] ROW0  = 11'd152;     // 第一条横条顶部
    localparam [10:0] INFO_Y = 11'd240;    // 实时信息

    wire in_panel = i_en && (i_x >= P_X0) && (i_x < P_X1) &&
                    (i_y >= P_Y0) && (i_y < P_Y1);
    wire on_border = in_panel && ((i_x == P_X0) || (i_x == P_X1 - 11'd1) ||
                                  (i_y == P_Y0) || (i_y == P_Y1 - 11'd1));

    // ---- 横条行解码：y-Row0，比较树代替除法 ----
    wire [10:0] dy = i_y - ROW0;
    wire        row0 = (dy <  11'd20);
    wire        row1 = (dy >= 11'd20) && (dy < 11'd40);
    wire        row2 = (dy >= 11'd40) && (dy < 11'd60);
    wire        row3 = (dy >= 11'd60) && (dy < 11'd80);
    wire        row_ok = (i_y >= ROW0) && (row0 || row1 || row2 || row3);

    reg [1:0] rsel;
    always @(*) begin
        if (row0)      rsel = 2'd0;
        else if (row1) rsel = 2'd1;
        else if (row2) rsel = 2'd2;
        else           rsel = 2'd3;
    end

    wire [10:0] byoff = dy - {rsel, 4'd0} - {rsel, 2'd0};   // dy - 20*rsel

    // ---- 百分比与条长（参数为常量，全部在综合期折叠）----
    reg [10:0] bar_len;
    reg [3:0]  pct_h, pct_t, pct_o;
    always @(*) begin
        case (rsel)
            2'd0: begin
                bar_len = (LUT_PCT * 192) / 100;
                pct_h   = LUT_PCT / 100;
                pct_t   = (LUT_PCT / 10) % 10;
                pct_o   = LUT_PCT % 10;
            end
            2'd1: begin
                bar_len = (FF_PCT * 192) / 100;
                pct_h   = FF_PCT / 100;
                pct_t   = (FF_PCT / 10) % 10;
                pct_o   = FF_PCT % 10;
            end
            2'd2: begin
                bar_len = (RAM_PCT * 192) / 100;
                pct_h   = RAM_PCT / 100;
                pct_t   = (RAM_PCT / 10) % 10;
                pct_o   = RAM_PCT % 10;
            end
            default: begin
                bar_len = (DSP_PCT * 192) / 100;
                pct_h   = DSP_PCT / 100;
                pct_t   = (DSP_PCT / 10) % 10;
                pct_o   = DSP_PCT % 10;
            end
        endcase
    end

    wire [10:0] bx = i_x - BAR_X;
    wire        in_bar_x = (i_x >= BAR_X) && (i_x < BAR_X + BAR_W);
    wire        bar_body  = row_ok && (byoff >= 11'd8) && (byoff < 11'd16);
    wire        bar_fill  = bar_body && in_bar_x && (bx < bar_len);
    wire        bar_track = bar_body && in_bar_x && (bx >= bar_len);

    // ---- 文本几何 ----
    wire        lbl_row = row_ok && (byoff < 11'd8);
    wire        pct_row = row_ok && (byoff >= 11'd10) && (byoff < 11'd18);

    wire [10:0] lbl_dx = i_x - LB_X;
    wire [10:0] pct_dx = i_x - PCT_X;
    wire [4:0]  lbl_idx = lbl_dx[7:3];
    wire [4:0]  pct_idx = pct_dx[7:3];

    localparam [10:0] TITLE_LEN = 11'd16;
    wire [10:0] tt_dx = i_x - TX_X;
    wire [4:0]  tt_idx = tt_dx[7:3];
    wire        tt_row = (i_y >= TX_Y) && (i_y < TX_Y + 11'd8);
    wire        tt_on  = (i_x >= TX_X) && (i_x < TX_X + TITLE_LEN * 11'd8);

    localparam [10:0] IN_X = 11'd56;
    localparam [10:0] IN_LEN = 11'd16;
    wire [10:0] in_dx = i_x - IN_X;
    wire [4:0]  in_idx = in_dx[7:3];
    wire        in1_row = (i_y >= INFO_Y) && (i_y < INFO_Y + 11'd8);
    wire        in2_row = (i_y >= INFO_Y + 11'd16) && (i_y < INFO_Y + 11'd24);
    wire        in_x_ok = (i_x >= IN_X) && (i_x < IN_X + IN_LEN * 11'd8);

    function [6:0] title_char;
        input [4:0] i;
        begin
            case (i)
                5'd0:  title_char = "R";
                5'd1:  title_char = "E";
                5'd2:  title_char = "S";
                5'd3:  title_char = "O";
                5'd4:  title_char = "U";
                5'd5:  title_char = "R";
                5'd6:  title_char = "C";
                5'd7:  title_char = "E";
                5'd8:  title_char = " ";
                5'd9:  title_char = "M";
                5'd10: title_char = "O";
                5'd11: title_char = "N";
                5'd12: title_char = "I";
                5'd13: title_char = "T";
                5'd14: title_char = "O";
                5'd15: title_char = "R";
                default: title_char = 7'h20;
            endcase
        end
    endfunction

    function [6:0] label_char;
        input [1:0] row;
        input [4:0] i;
        begin
            label_char = 7'h20;
            case (row)
                2'd0: case (i)
                        5'd0: label_char = "L";
                        5'd1: label_char = "U";
                        5'd2: label_char = "T";
                        default: label_char = 7'h20;
                      endcase
                2'd1: case (i)
                        5'd0: label_char = "F";
                        5'd1: label_char = "F";
                        default: label_char = 7'h20;
                      endcase
                2'd2: case (i)
                        5'd0: label_char = "R";
                        5'd1: label_char = "A";
                        5'd2: label_char = "M";
                        default: label_char = 7'h20;
                      endcase
                default: case (i)
                        5'd0: label_char = "D";
                        5'd1: label_char = "S";
                        5'd2: label_char = "P";
                        default: label_char = 7'h20;
                      endcase
            endcase
        end
    endfunction

    reg [6:0] pct_char;
    always @(*) begin
        case (pct_idx)
            5'd0: pct_char = (pct_h == 4'd0) ? 7'h20 : {3'h3, pct_h};
            5'd1: pct_char = (pct_h == 4'd0 && pct_t == 4'd0) ? 7'h20 : {3'h3, pct_t};
            5'd2: pct_char = {3'h3, pct_o};
            5'd3: pct_char = 7'h25;                       // '%'
            default: pct_char = 7'h20;
        endcase
    end

    // "FRAME" + 5 位帧号（idx 8..12）
    reg [6:0] info_char;
    always @(*) begin
        if (in1_row) begin
            case (in_idx)
                5'd0:  info_char = "F";
                5'd1:  info_char = "R";
                5'd2:  info_char = "A";
                5'd3:  info_char = "M";
                5'd4:  info_char = "E";
                5'd5:  info_char = 7'h20;
                5'd6:  info_char = 7'h20;
                5'd7:  info_char = 7'h20;
                5'd8:  info_char = {3'h3, i_frame_bcd[19:16]};
                5'd9:  info_char = {3'h3, i_frame_bcd[15:12]};
                5'd10: info_char = {3'h3, i_frame_bcd[11:8]};
                5'd11: info_char = {3'h3, i_frame_bcd[7:4]};
                5'd12: info_char = {3'h3, i_frame_bcd[3:0]};
                default: info_char = 7'h20;
            endcase
        end else begin
            case (in_idx)
                5'd0: info_char = "V";
                5'd1: info_char = "I";
                5'd2: info_char = "D";
                5'd3: info_char = "E";
                5'd4: info_char = "O";
                5'd5: info_char = ":";
                5'd6: info_char = i_video_on ? "R" : "S";
                5'd7: info_char = i_video_on ? "U" : "T";
                5'd8: info_char = i_video_on ? "N" : "O";
                5'd9: info_char = i_video_on ? 7'h20 : "P";
                default: info_char = 7'h20;
            endcase
        end
    end

    // ---- 文本源选择 ----
    reg        txt_on;
    reg [6:0]  t_char;
    reg [2:0]  t_row;
    reg [2:0]  t_col;
    reg [23:0] t_color;

    always @(*) begin
        txt_on  = 1'b0;
        t_char  = 7'h20;
        t_row   = 3'd0;
        t_col   = 3'd0;
        t_color = 24'hE8F2FF;
        if (tt_on && tt_row) begin
            txt_on  = 1'b1;
            t_char  = title_char(tt_idx);
            t_row   = i_y[2:0];
            t_col   = tt_dx[2:0];
            t_color = 24'h7FE0FF;
        end else if (lbl_row && (i_x >= LB_X) && (i_x < LB_X + 11'd32)) begin
            txt_on  = 1'b1;
            t_char  = label_char(rsel, lbl_idx);
            t_row   = byoff[2:0];
            t_col   = lbl_dx[2:0];
            t_color = 24'hC8D8EC;
        end else if (pct_row && (i_x >= PCT_X) && (i_x < PCT_X + 11'd32)) begin
            txt_on  = 1'b1;
            t_char  = pct_char;
            t_row   = byoff[2:0] - 3'd2;
            t_col   = pct_dx[2:0];
            t_color = 24'hFFFFFF;
        end else if (in_x_ok && (in1_row || in2_row)) begin
            txt_on  = 1'b1;
            t_char  = info_char;
            t_row   = i_y[2:0];
            t_col   = in_dx[2:0];
            t_color = in1_row ? 24'h9BE8FF : (i_video_on ? 24'h5CFF7A : 24'hFF7B7B);
        end
    end

    assign o_txt_on = in_panel && txt_on;
    assign o_char   = t_char;
    assign o_row    = t_row;
    assign o_col    = t_col;
    assign o_color  = t_color;

    // ---- 背景与横条 ----
    assign o_bg_on = in_panel;
    assign o_bg_color = on_border  ? 24'h3A6FA0 :
                        bar_fill   ? 24'h2FD8FF :
                        bar_track  ? 24'h16324A :
                                     24'h070B14;

endmodule
