// ============================================================================
// osd_layer — 字符 OSD 叠加层（单级流水）
//
// 插在 transition_ctrl 输出像素流与 video_rgb_to_axis_640x480 之间。
// 顶部标题栏：左侧标题文字，右侧 24 小时制时间戳。
// 底部信息栏：转场模式 MOD:x、亮度档 B:x、对比度档 C:x（x 为档位号 0~4）。
//
// 关键点：整条路径只有一级寄存器（o_hs/o_vs/o_de/o_rgb 同拍），因此 RGB 与
//        同步信号的延迟完全一致，插入后不会造成画面错位/撕裂。
// 字库：font8x8（8x8 点阵），2x 放大到 16x16 像素显示。
// ============================================================================
module osd_layer #(
    parameter H_ACTIVE = 640,
    parameter V_ACTIVE = 480
)(
    input  wire        i_clk,      // video_clk 25MHz
    input  wire        i_rst,      // 高有效复位
    input  wire        i_hs,
    input  wire        i_vs,
    input  wire        i_de,
    input  wire [23:0] i_rgb,
    input  wire [1:0]  i_mode,     // 转场模式 0~3
    input  wire [2:0]  i_bright,   // 亮度档 0~4
    input  wire [2:0]  i_contrast, // 对比度档 0~4
    input  wire [255:0] i_slogan,      // 标语内容（32 字节，标语[0]在最高字节）
    input  wire [5:0]  i_slogan_len,   // 标语长度 0~32
    input  wire        i_slogan_dir,   // 滚动方向 0=从右向左 1=从左往右
    input  wire        i_slogan_update,// 更新 toggle（内容变化时翻转）
    input  wire        i_slogan_scroll,// 滚动使能
    input  wire        i_audio_viz,    // 音频可视化使能
    input  wire [7:0]  i_audio_level,  // 音频电平 0~255

    output reg         o_hs,
    output reg         o_vs,
    output reg         o_de,
    output reg  [23:0] o_rgb
);

    // ---- 布局常量（像素）----
    localparam SCALE   = 2;                          // 字符放大倍数（2 → 16x16）
    localparam GLYPH_W = 8;
    localparam GLYPH_H = 8;
    localparam CHAR_W  = GLYPH_W * SCALE;            // 16
    localparam CHAR_H  = GLYPH_H * SCALE;            // 16
    localparam BAR_H   = 24;                         // 顶/底栏高度
    localparam GLYPH_Y = (BAR_H - CHAR_H) / 2;       // 栏内字形垂直起点 = 4

    // 顶部标语窗口（时间戳左边整行，31 字符），左对齐
    localparam [10:0] TITLE_X   = 11'd8;
    localparam [5:0]  TITLE_LEN = 6'd31;

    // 顶部时间戳 "HH:MM:SS"（8 字符），右对齐
    localparam [3:0]  TS_LEN    = 4'd8;
    localparam [10:0] TS_X      = H_ACTIVE - TS_LEN * CHAR_W - 8;   // 504

    // 底部信息栏 "640x480 60FPS MOD:0 B:4 C:4"（27 字符），左对齐
    localparam [10:0] BOT_Y       = V_ACTIVE - BAR_H;               // 456
    localparam [10:0] BOT_GLYPH_Y = BOT_Y + (BAR_H - CHAR_H) / 2;   // 460
    localparam [10:0] BOT_X       = 11'd8;
    localparam [4:0]  BOT_LEN     = 5'd27;

    // ---- 像素位置跟踪 ----
    reg [10:0] x;
    reg [10:0] y;
    reg        de_d;
    reg        vs_d;
    wire       de_rise = i_de & ~de_d;
    wire       vs_rise = i_vs & ~vs_d;

    always @(posedge i_clk or posedge i_rst) begin
        if (i_rst) begin
            x <= 11'd0; y <= 11'd0; de_d <= 1'b0; vs_d <= 1'b0;
        end else begin
            de_d <= i_de;
            vs_d <= i_vs;
            if (vs_rise)      y <= 11'd0;
            else if (de_rise) y <= y + 11'd1;
            if (!i_de) x <= 11'd0;
            else       x <= x + 11'd1;
        end
    end

    // ---- 时间戳计数器（25MHz 精确计 1 秒，BCD）----
    reg [24:0] cyc_cnt;
    reg [3:0]  s_ones, s_tens, m_ones, m_tens, h_ones, h_tens;

    wire s_ones_ovf = (s_ones == 4'd9);
    wire s_tens_ovf = (s_tens == 4'd5);
    wire m_ones_ovf = (m_ones == 4'd9);
    wire m_tens_ovf = (m_tens == 4'd5);
    wire h_ovf      = (h_tens == 4'd2 && h_ones == 4'd3);

    always @(posedge i_clk or posedge i_rst) begin
        if (i_rst) begin
            cyc_cnt <= 25'd0;
            s_ones <= 4'd0; s_tens <= 4'd0;
            m_ones <= 4'd0; m_tens <= 4'd0;
            h_ones <= 4'd0; h_tens <= 4'd0;
        end else if (cyc_cnt == 25'd24_999_999) begin
            cyc_cnt <= 25'd0;
            if (s_ones_ovf) s_ones <= 4'd0; else s_ones <= s_ones + 4'd1;
            if (s_ones_ovf) begin
                if (s_tens_ovf) s_tens <= 4'd0; else s_tens <= s_tens + 4'd1;
            end
            if (s_ones_ovf && s_tens_ovf) begin
                if (m_ones_ovf) m_ones <= 4'd0; else m_ones <= m_ones + 4'd1;
            end
            if (s_ones_ovf && s_tens_ovf && m_ones_ovf) begin
                if (m_tens_ovf) m_tens <= 4'd0; else m_tens <= m_tens + 4'd1;
            end
            if (s_ones_ovf && s_tens_ovf && m_ones_ovf && m_tens_ovf) begin
                if (h_ovf) begin h_tens <= 4'd0; h_ones <= 4'd0; end
                else if (h_ones == 4'd9) begin h_ones <= 4'd0; h_tens <= h_tens + 4'd1; end
                else h_ones <= h_ones + 4'd1;
            end
        end else begin
            cyc_cnt <= cyc_cnt + 25'd1;
        end
    end

    // ---- FPS 计数器（每秒统计帧数）----
    reg [9:0] fps_cnt;
    reg [9:0] fps_val;
    always @(posedge i_clk or posedge i_rst) begin
        if (i_rst) begin
            fps_cnt <= 10'd0;
            fps_val <= 10'd60;
        end else begin
            if (vs_rise) fps_cnt <= fps_cnt + 10'd1;
            if (cyc_cnt == 25'd24_999_999) begin
                fps_val <= fps_cnt;
                fps_cnt <= 10'd0;
            end
        end
    end
    wire [6:0] fps_tens_char = 7'h30 + (fps_val / 10);
    wire [6:0] fps_ones_char = 7'h30 + (fps_val % 10);

    // ---- 滚动位置（标语平滑滚动）----
    reg [9:0] scroll_pos;

    // ---- 顶部标题栏区域 ----
    wire in_bar = (y < BAR_H);

    // 标题文字区
    wire [10:0] title_off = x - TITLE_X;
    wire [10:0] title_off_s = title_off + scroll_pos;   // 内容位置（含滚动偏移）
    wire [6:0]  title_char_idx = title_off_s >> 4;      // 字符索引
    wire [2:0]  title_col = (title_off_s >> 1);
    wire [10:0] title_v   = y - GLYPH_Y;
    wire [2:0]  title_row = title_v >> 1;
    wire in_title_x = (x >= TITLE_X) && (x < TITLE_X + TITLE_LEN * CHAR_W);
    wire in_title_y = (y >= GLYPH_Y) && (y < GLYPH_Y + CHAR_H);
    wire in_title   = in_bar && in_title_x && in_title_y;

    // 时间戳文字区
    wire [10:0] ts_off  = x - TS_X;
    wire [2:0]  ts_idx  = ts_off >> 4;
    wire [2:0]  ts_col  = (ts_off >> 1);
    wire [10:0] ts_v    = y - GLYPH_Y;
    wire [2:0]  ts_row  = ts_v >> 1;
    wire in_ts_x = (x >= TS_X) && (x < TS_X + TS_LEN * CHAR_W);
    wire in_ts_y = (y >= GLYPH_Y) && (y < GLYPH_Y + CHAR_H);
    wire in_ts   = in_bar && in_ts_x && in_ts_y;

    // ---- 底部信息栏区域 ----
    wire in_bot_bar = (y >= BOT_Y);
    wire [10:0] bot_off = x - BOT_X;
    wire [4:0]  bot_idx = bot_off >> 4;
    wire [2:0]  bot_col = (bot_off >> 1);
    wire [10:0] bot_v   = y - BOT_GLYPH_Y;
    wire [2:0]  bot_row = bot_v >> 1;
    wire in_bot_x = (x >= BOT_X) && (x < BOT_X + BOT_LEN * CHAR_W);
    wire in_bot_y = (y >= BOT_GLYPH_Y) && (y < BOT_GLYPH_Y + CHAR_H);
    wire in_bot   = in_bot_bar && in_bot_x && in_bot_y;

    // ---- 音频可视化（屏幕中心电平条）----
    localparam [10:0] AV_X = 11'd160;
    localparam [10:0] AV_Y = 11'd216;
    localparam [10:0] AV_W = 11'd320;
    localparam [10:0] AV_H = 11'd24;
    wire [16:0] av_prod = {9'd0, i_audio_level} * 11'd320;
    wire [9:0]  av_len  = av_prod[15:8];   // 电平条长度 0~320
    wire in_av     = i_audio_viz && (x >= AV_X) && (x < AV_X + AV_W) && (y >= AV_Y) && (y < AV_Y + AV_H);
    wire in_av_bar = in_av && (x < AV_X + {1'b0, av_len});

    // ---- 标语锁存（跨域）+ 平滑滚动 ----
    reg [7:0] slogan [0:31];
    reg [5:0] slogan_len;
    wire [5:0] content_chars = (slogan_len > 6'd31) ? slogan_len : 6'd31;
    reg       slogan_dir;
    reg       scroll_en;
    reg [2:0] upd_sync;
    wire      upd_edge = upd_sync[2] ^ upd_sync[1];

    integer si;
    always @(posedge i_clk or posedge i_rst) begin
        if (i_rst) begin
            upd_sync   <= 3'd0;
            slogan_len <= 6'd18;
            slogan_dir <= 1'b0;
            scroll_en  <= 1'b0;
            scroll_pos <= 10'd0;
            // 默认标语 "EG4S20 HDMI PLAYER"
            slogan[0]  <= "E"; slogan[1]  <= "G"; slogan[2]  <= "4"; slogan[3]  <= "S";
            slogan[4]  <= "2"; slogan[5]  <= "0"; slogan[6]  <= " "; slogan[7]  <= "H";
            slogan[8]  <= "D"; slogan[9]  <= "M"; slogan[10] <= "I"; slogan[11] <= " ";
            slogan[12] <= "P"; slogan[13] <= "L"; slogan[14] <= "A"; slogan[15] <= "Y";
            slogan[16] <= "E"; slogan[17] <= "R";
            for (si = 18; si < 32; si = si + 1) slogan[si] <= 8'h00;
        end else begin
            upd_sync <= {upd_sync[1:0], i_slogan_update};
            if (upd_edge) begin
                slogan_len <= i_slogan_len;
                slogan_dir <= i_slogan_dir;
                scroll_en  <= i_slogan_scroll;
                for (si = 0; si < 32; si = si + 1)
                    slogan[si] <= i_slogan[(31-si)*8 +: 8];
                scroll_pos <= 10'd0;
            end
            if (scroll_en) begin
                if (vs_rise) begin
                    if (slogan_dir == 1'b0) begin
                        if (scroll_pos >= ({content_chars, 4'd0} - 1'b1))
                            scroll_pos <= 10'd0;
                        else
                            scroll_pos <= scroll_pos + 10'd1;
                    end else begin
                        if (scroll_pos == 10'd0)
                            scroll_pos <= {content_chars, 4'd0} - 1'b1;
                        else
                            scroll_pos <= scroll_pos - 10'd1;
                    end
                end
            end else begin
                scroll_pos <= 10'd0;
            end
        end
    end

    // ---- 标语字符 ROM 索引（内容位置 mod 内容总宽）----
    wire [6:0] content_chars6 = {1'b0, content_chars};
    wire [6:0] slogan_idx6 = (title_char_idx >= content_chars6) ? (title_char_idx - content_chars6) : title_char_idx;
    wire [5:0] slogan_idx = slogan_idx6[5:0];
    reg [6:0] title_char;
    always @(*) begin
        if (slogan_idx < slogan_len)
            title_char = slogan[slogan_idx];
        else
            title_char = 7'h20;
    end

    // ---- 时间戳字符 ROM 索引：HH:MM:SS ----
    reg [6:0] ts_char;
    always @(*) begin
        case (ts_idx)
            3'd0: ts_char = {3'h3, h_tens};
            3'd1: ts_char = {3'h3, h_ones};
            3'd2: ts_char = 7'h3A;
            3'd3: ts_char = {3'h3, m_tens};
            3'd4: ts_char = {3'h3, m_ones};
            3'd5: ts_char = 7'h3A;
            3'd6: ts_char = {3'h3, s_tens};
            3'd7: ts_char = {3'h3, s_ones};
            default: ts_char = 7'h20;
        endcase
    end

    // ---- 底部信息字符 ROM 索引：640x480 60FPS MOD:0 B:4 C:4 ----
    reg [6:0] bot_char;
    always @(*) begin
        case (bot_idx)
            5'd0:  bot_char = 7'h36;                    // '6'
            5'd1:  bot_char = 7'h34;                    // '4'
            5'd2:  bot_char = 7'h30;                    // '0'
            5'd3:  bot_char = 7'h78;                    // 'x'
            5'd4:  bot_char = 7'h34;                    // '4'
            5'd5:  bot_char = 7'h38;                    // '8'
            5'd6:  bot_char = 7'h30;                    // '0'
            5'd7:  bot_char = 7'h20;                    // (space)
            5'd8:  bot_char = fps_tens_char;            // FPS 十位
            5'd9:  bot_char = fps_ones_char;            // FPS 个位
            5'd10: bot_char = 7'h46;                    // F
            5'd11: bot_char = 7'h50;                    // P
            5'd12: bot_char = 7'h53;                    // S
            5'd13: bot_char = 7'h20;                    // (space)
            5'd14: bot_char = 7'h4D;                    // M
            5'd15: bot_char = 7'h4F;                    // O
            5'd16: bot_char = 7'h44;                    // D
            5'd17: bot_char = 7'h3A;                    // :
            5'd18: bot_char = {3'h3, 2'b00, i_mode};    // '0'+模式
            5'd19: bot_char = 7'h20;                    // (space)
            5'd20: bot_char = 7'h42;                    // B
            5'd21: bot_char = 7'h3A;                    // :
            5'd22: bot_char = {3'h3, 1'b0, i_bright};   // '0'+亮度档
            5'd23: bot_char = 7'h20;                    // (space)
            5'd24: bot_char = 7'h43;                    // C
            5'd25: bot_char = 7'h3A;                    // :
            5'd26: bot_char = {3'h3, 1'b0, i_contrast}; // '0'+对比度档
            default: bot_char = 7'h20;
        endcase
    end

    // ---- 字库 ROM（组合逻辑）----
    wire [7:0] title_glyph;
    wire [7:0] ts_glyph;
    wire [7:0] bot_glyph;
    font8x8 u_font_title (
        .i_char (title_char), .i_row (title_row), .o_row (title_glyph)
    );
    font8x8 u_font_ts (
        .i_char (ts_char), .i_row (ts_row), .o_row (ts_glyph)
    );
    font8x8 u_font_bot (
        .i_char (bot_char), .i_row (bot_row), .o_row (bot_glyph)
    );

    // ---- 文本像素判定 ----
    wire title_pixel = in_title && title_glyph[7 - title_col];
    wire ts_pixel    = in_ts    && ts_glyph[7 - ts_col];
    wire bot_pixel   = in_bot   && bot_glyph[7 - bot_col];

    // ---- 输出混合（黑底白字，栏外透传原视频）----
    reg [23:0] rgb_next;
    always @(*) begin
        if (in_bar)
            rgb_next = (title_pixel | ts_pixel) ? 24'hFFFFFF : 24'h000000;
        else if (in_bot_bar)
            rgb_next = bot_pixel ? 24'hFFFFFF : 24'h000000;
        else if (in_av)
            rgb_next = in_av_bar ? 24'h00FF00 : 24'h202020;
        else
            rgb_next = i_rgb;
    end

    // ---- 单级流水：同步信号与 RGB 同拍对齐 ----
    always @(posedge i_clk or posedge i_rst) begin
        if (i_rst) begin
            o_hs  <= 1'b0; o_vs  <= 1'b0; o_de  <= 1'b0; o_rgb <= 24'd0;
        end else begin
            o_hs  <= i_hs;
            o_vs  <= i_vs;
            o_de  <= i_de;
            o_rgb <= rgb_next;
        end
    end

endmodule
