// ============================================================================
// osd_layer — 字符 OSD 叠加层（单级流水）
//
// 正常显示：顶部标语 + 时间戳、底部信息栏（含百分比亮度/对比度）、
//           VU 电平条、32 段全宽透明频谱、彩色弹幕、资源占用面板。
// 启动阶段（首图提交前）：左面板标题/跑马灯/进度，右面板按键功能说明。
//
// 全层共用一套 font8x8 字库（优先级选择字符），避免 4 份 ROM 复制。
// ============================================================================
module osd_layer #(
    parameter H_ACTIVE = 640,
    parameter V_ACTIVE = 480,
    parameter integer RM_LUT_PCT = 74,
    parameter integer RM_FF_PCT  = 44,
    parameter integer RM_RAM_PCT = 84,
    parameter integer RM_DSP_PCT = 66
)(
    input  wire        i_clk,      // video_clk 25MHz
    input  wire        i_rst,      // 高有效复位
    input  wire        i_hs,
    input  wire        i_vs,
    input  wire        i_de,
    input  wire [23:0] i_rgb,
    input  wire [1:0]  i_mode,     // 转场模式 0~3
    input  wire [2:0]  i_bright,   // 亮度档 0~4（显示为 20%~100%）
    input  wire [2:0]  i_contrast, // 对比度档 0~4
    input  wire [255:0] i_slogan,
    input  wire [5:0]  i_slogan_len,
    input  wire        i_slogan_dir,
    input  wire        i_slogan_update,
    input  wire        i_slogan_scroll,

    input  wire [1:0]  i_viz_mode,   // 层2：0 关 / 1 音量 / 2 音量+频谱
    input  wire        i_spec_en,    // 层3：频谱开关
    input  wire [7:0]  i_audio_level,
    input  wire [191:0] i_spec_level,// 32 频段 × 6bit

    input  wire        i_dm_en,      // 层3：弹幕
    input  wire [191:0] i_dm_text,
    input  wire [4:0]  i_dm_len,
    input  wire [3:0]  i_dm_color,
    input  wire        i_dm_tgl,
    output wire        o_dm_ack,

    input  wire        i_rm_en,      // 层3：资源面板
    input  wire        i_video_on,
    input  wire        i_vid_ftgl,   // 每出一帧视频翻转一次（100MHz 域）

    input  wire        i_display_valid,   // 首图已提交（隐藏启动面板）
    input  wire        i_sd_init_done,
    input  wire        i_scan_done,
    input  wire [4:0]  i_img_count,
    input  wire [15:0] i_src_w_bcd,
    input  wire [15:0] i_src_h_bcd,
    input  wire        i_src_tgl,
    input  wire        i_auto_play,

    output reg         o_hs,
    output reg         o_vs,
    output reg         o_de,
    output reg  [23:0] o_rgb
);

    // ---- 上下栏布局 ----
    localparam CHAR_W  = 16;
    localparam CHAR_H  = 16;
    localparam BAR_H   = 24;
    localparam GLYPH_Y = 4;

    localparam [10:0] TITLE_X   = 11'd8;
    localparam [5:0]  TITLE_LEN = 6'd31;

    localparam [3:0]  TS_LEN    = 4'd8;
    localparam [10:0] TS_X      = H_ACTIVE - TS_LEN * CHAR_W - 8;   // 504

    localparam [10:0] BOT_Y       = V_ACTIVE - BAR_H;               // 456
    localparam [10:0] BOT_GLYPH_Y = BOT_Y + (BAR_H - CHAR_H) / 2;   // 460
    localparam [10:0] BOT_X       = 11'd8;
    localparam [5:0]  BOT_LEN     = 6'd37;      // 源尺寸(0..17) + FPS/M/B/C(18..36)

    // ---- 像素位置跟踪 ----
    reg [10:0] x;
    reg [10:0] y;
    reg        de_d;
    reg        vs_d;
    wire       de_fall = ~i_de & de_d;
    wire       vs_rise = i_vs & ~vs_d;

    always @(posedge i_clk or posedge i_rst) begin
        if (i_rst) begin
            x <= 11'd0; y <= 11'd0; de_d <= 1'b0; vs_d <= 1'b0;
        end else begin
            de_d <= i_de;
            vs_d <= i_vs;
            // 行号在行末（de 下降沿）进位，保证整行像素用同一行号
            if (vs_rise)      y <= 11'd0;
            else if (de_fall) y <= y + 11'd1;
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

    // ---- FPS 计数器 ----
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

    // ---- 亮度/对比度百分比（20/40/60/80/100）----
    wire [4:0] pct_tens_b5 = {1'b0, i_bright,   1'b0} + 5'd2;   // 2*(档+1)
    wire [4:0] pct_tens_c5 = {1'b0, i_contrast, 1'b0} + 5'd2;
    wire [6:0] b_hc = (i_bright   == 3'd4) ? 7'h31 : 7'h20;
    wire [6:0] c_hc = (i_contrast == 3'd4) ? 7'h31 : 7'h20;
    wire [6:0] b_tc = (i_bright   == 3'd4) ? 7'h30 : {3'h3, pct_tens_b5[3:0]};
    wire [6:0] c_tc = (i_contrast == 3'd4) ? 7'h30 : {3'h3, pct_tens_c5[3:0]};

    // ---- 当前显示图的源尺寸（100MHz 域 BCD + toggle 握手）----
    reg  [2:0]  src_tgl_sync;
    wire        src_tgl_edge = src_tgl_sync[2] ^ src_tgl_sync[1];
    reg  [15:0] src_w_bcd_q;
    reg  [15:0] src_h_bcd_q;
    wire        src_native = (src_w_bcd_q == 16'h0640) && (src_h_bcd_q == 16'h0480);
    wire        src_known  = (src_w_bcd_q != 16'd0) && (src_h_bcd_q != 16'd0);
    always @(posedge i_clk or posedge i_rst) begin
        if (i_rst) begin
            src_tgl_sync <= 3'd0;
            src_w_bcd_q  <= 16'h0640;
            src_h_bcd_q  <= 16'h0480;
        end else begin
            src_tgl_sync <= {src_tgl_sync[1:0], i_src_tgl};
            if (src_tgl_edge) begin
                src_w_bcd_q <= i_src_w_bcd;
                src_h_bcd_q <= i_src_h_bcd;
            end
        end
    end

    wire [3:0] src_w3 = src_w_bcd_q[15:12];
    wire [3:0] src_w2 = src_w_bcd_q[11:8];
    wire [3:0] src_w1 = src_w_bcd_q[7:4];
    wire [3:0] src_w0 = src_w_bcd_q[3:0];
    wire [3:0] src_h3 = src_h_bcd_q[15:12];
    wire [3:0] src_h2 = src_h_bcd_q[11:8];
    wire [3:0] src_h1 = src_h_bcd_q[7:4];
    wire [3:0] src_h0 = src_h_bcd_q[3:0];
    wire src_w_z3 = (src_w3 == 4'd0);
    wire src_w_z2 = src_w_z3 && (src_w2 == 4'd0);
    wire src_w_z1 = src_w_z2 && (src_w1 == 4'd0);
    wire src_h_z3 = (src_h3 == 4'd0);
    wire src_h_z2 = src_h_z3 && (src_h2 == 4'd0);
    wire src_h_z1 = src_h_z2 && (src_h1 == 4'd0);
    wire [6:0] src_w_c3 = src_w_z3 ? 7'h20 : {3'h3, src_w3};
    wire [6:0] src_w_c2 = src_w_z2 ? 7'h20 : {3'h3, src_w2};
    wire [6:0] src_w_c1 = src_w_z1 ? 7'h20 : {3'h3, src_w1};
    wire [6:0] src_w_c0 = {3'h3, src_w0};
    wire [6:0] src_h_c3 = src_h_z3 ? 7'h20 : {3'h3, src_h3};
    wire [6:0] src_h_c2 = src_h_z2 ? 7'h20 : {3'h3, src_h2};
    wire [6:0] src_h_c1 = src_h_z1 ? 7'h20 : {3'h3, src_h1};
    wire [6:0] src_h_c0 = {3'h3, src_h0};

    // ---- 图片数两位十进制（0~16）----
    wire [3:0] img_cnt_tens = i_img_count / 5'd10;
    wire [3:0] img_cnt_ones = i_img_count % 5'd10;

    // ---- 视频帧号 BCD（每出一帧 +1，20bit = 5 位）----
    reg  [1:0]  vid_tgl_sync;
    wire        vid_ftgl_edge = vid_tgl_sync[0] ^ vid_tgl_sync[1];
    reg  [19:0] vid_bcd;
    wire [3:0]  vd0 = vid_bcd[3:0];
    wire [3:0]  vd1 = vid_bcd[7:4];
    wire [3:0]  vd2 = vid_bcd[11:8];
    wire [3:0]  vd3 = vid_bcd[15:12];
    wire [3:0]  vd4 = vid_bcd[19:16];
    wire c0 = (vd0 == 4'd9);
    wire c1 = (vd1 == 4'd9) & c0;
    wire c2 = (vd2 == 4'd9) & c1;
    wire c3 = (vd3 == 4'd9) & c2;

    always @(posedge i_clk or posedge i_rst) begin
        if (i_rst) begin
            vid_tgl_sync <= 2'd0;
            vid_bcd      <= 20'd0;
        end else begin
            vid_tgl_sync <= {vid_tgl_sync[0], i_vid_ftgl};
            if (vid_ftgl_edge) begin
                vid_bcd[3:0]   <= c0 ? 4'd0 : vd0 + 4'd1;
                vid_bcd[7:4]   <= c0 ? (c1 ? 4'd0 : vd1 + 4'd1) : vd1;
                vid_bcd[11:8]  <= c1 ? (c2 ? 4'd0 : vd2 + 4'd1) : vd2;
                vid_bcd[15:12] <= c2 ? (c3 ? 4'd0 : vd3 + 4'd1) : vd3;
                vid_bcd[19:16] <= c3 ? ((vd4 == 4'd9) ? 4'd0 : vd4 + 4'd1) : vd4;
            end
        end
    end

    // ---- 标语锁存（跨域）+ 平滑滚动 ----
    reg [7:0] slogan [0:31];
    reg [5:0] slogan_len;
    wire [5:0] content_chars = (slogan_len > 6'd31) ? slogan_len : 6'd31;
    reg       slogan_dir;
    reg       scroll_en;
    reg [9:0] scroll_pos;
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

    // ---- 顶部标语几何（ASCII 过滤）----
    wire in_bar = (y < BAR_H);

    wire [10:0] title_off   = x - TITLE_X;
    wire [10:0] title_off_s = title_off + scroll_pos;
    wire [6:0]  title_char_idx = title_off_s >> 4;
    wire [2:0]  title_col   = title_off_s[3:1];
    wire [10:0] title_v     = y - GLYPH_Y;
    wire [2:0]  title_row   = title_v[3:1];
    wire in_title_x = (x >= TITLE_X) && (x < TITLE_X + TITLE_LEN * CHAR_W);
    wire in_title_y = (y >= GLYPH_Y) && (y < GLYPH_Y + CHAR_H);
    wire in_title   = in_bar && in_title_x && in_title_y;

    wire [6:0] content_chars6 = {1'b0, content_chars};
    wire [6:0] slogan_idx6 = (title_char_idx >= content_chars6) ?
                             (title_char_idx - content_chars6) : title_char_idx;
    wire [5:0] slogan_idx = slogan_idx6[5:0];
    wire [7:0] title_byte = slogan[slogan_idx];
    wire title_ascii_ok = (slogan_idx < slogan_len) &&
                          (title_byte >= 8'h20) && (title_byte <= 8'h7E);
    reg [6:0] title_char;
    always @(*) begin
        if (title_ascii_ok) title_char = title_byte[6:0];
        else                title_char = 7'h20;
    end

    // ---- 时间戳几何 ----
    wire [10:0] ts_off = x - TS_X;
    wire [2:0]  ts_idx = ts_off[6:4];
    wire [2:0]  ts_col = ts_off[4:1];
    wire [10:0] ts_v   = y - GLYPH_Y;
    wire [2:0]  ts_row = ts_v[3:1];
    wire in_ts_x = (x >= TS_X) && (x < TS_X + TS_LEN * CHAR_W);
    wire in_ts_y = (y >= GLYPH_Y) && (y < GLYPH_Y + CHAR_H);
    wire in_ts   = in_bar && in_ts_x && in_ts_y;

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

    // ---- 底部信息栏几何 ----
    wire in_bot_bar = (y >= BOT_Y);
    wire [10:0] bot_off = x - BOT_X;
    wire [5:0]  bot_idx = bot_off[9:4];
    wire [2:0]  bot_col = bot_off[3:1];
    wire [10:0] bot_v   = y - BOT_GLYPH_Y;
    wire [2:0]  bot_row = bot_v[3:1];
    wire in_bot_x = (x >= BOT_X) && (x < BOT_X + BOT_LEN * CHAR_W);
    wire in_bot_y = (y >= BOT_GLYPH_Y) && (y < BOT_GLYPH_Y + CHAR_H);
    wire in_bot   = in_bot_bar && in_bot_x && in_bot_y;

    reg [6:0] bot_char;
    always @(*) begin
        bot_char = 7'h20;
        if (bot_idx <= 6'd17) begin
            if (!src_known) begin
                bot_char = 7'h20;
            end else if (src_native) begin
                case (bot_idx)
                    6'd0: bot_char = "6";
                    6'd1: bot_char = "4";
                    6'd2: bot_char = "0";
                    6'd3: bot_char = "x";
                    6'd4: bot_char = "4";
                    6'd5: bot_char = "8";
                    6'd6: bot_char = "0";
                    default: bot_char = 7'h20;
                endcase
            end else begin
                case (bot_idx)
                    6'd0:  bot_char = src_w_c3;
                    6'd1:  bot_char = src_w_c2;
                    6'd2:  bot_char = src_w_c1;
                    6'd3:  bot_char = src_w_c0;
                    6'd4:  bot_char = "x";
                    6'd5:  bot_char = src_h_c3;
                    6'd6:  bot_char = src_h_c2;
                    6'd7:  bot_char = src_h_c1;
                    6'd8:  bot_char = src_h_c0;
                    6'd9:  bot_char = ">";
                    6'd10: bot_char = "6";
                    6'd11: bot_char = "4";
                    6'd12: bot_char = "0";
                    6'd13: bot_char = "x";
                    6'd14: bot_char = "4";
                    6'd15: bot_char = "8";
                    6'd16: bot_char = "0";
                    default: bot_char = 7'h20;
                endcase
            end
        end else begin
            // 右段：60F M:0 B100% C100%（18..36）
            case (bot_idx)
                6'd18: bot_char = fps_tens_char;
                6'd19: bot_char = fps_ones_char;
                6'd20: bot_char = "F";
                6'd21: bot_char = " ";
                6'd22: bot_char = "M";
                6'd23: bot_char = ":";
                6'd24: bot_char = {3'h3, 2'b00, i_mode};
                6'd25: bot_char = " ";
                6'd26: bot_char = "B";
                6'd27: bot_char = b_hc;
                6'd28: bot_char = b_tc;
                6'd29: bot_char = "0";
                6'd30: bot_char = "%";
                6'd31: bot_char = " ";
                6'd32: bot_char = "C";
                6'd33: bot_char = c_hc;
                6'd34: bot_char = c_tc;
                6'd35: bot_char = "0";
                6'd36: bot_char = "%";
                default: bot_char = 7'h20;
            endcase
        end
    end

    // ======================= 启动界面 =======================
    wire boot_mode = ~i_display_valid;

    reg [9:0] mq_phase;
    always @(posedge i_clk or posedge i_rst) begin
        if (i_rst) mq_phase <= 10'd0;
        else if (vs_rise) mq_phase <= mq_phase + 10'd1;
    end

    // ---- 文字常量表 ----
    // sid: 0=FPGA DISPLAY, 1=SYSTEM, 2=SWITCH FUNCTIONS, 3=CONTROLS,
    //      4=STATUS, 5=EG4S20 HDMI PLAYER, 6=FOUND IMAGES
    function [6:0] fixed_char;
        input [2:0] sid;
        input [4:0] idx;
        begin
            fixed_char = 7'h20;
            case (sid)
                3'd0: begin
                    case (idx)
                        5'd0:  fixed_char = "F";
                        5'd1:  fixed_char = "P";
                        5'd2:  fixed_char = "G";
                        5'd3:  fixed_char = "A";
                        5'd4:  fixed_char = " ";
                        5'd5:  fixed_char = "D";
                        5'd6:  fixed_char = "I";
                        5'd7:  fixed_char = "S";
                        5'd8:  fixed_char = "P";
                        5'd9:  fixed_char = "L";
                        5'd10: fixed_char = "A";
                        5'd11: fixed_char = "Y";
                        default: fixed_char = 7'h20;
                    endcase
                end
                3'd1: begin
                    case (idx)
                        5'd0:  fixed_char = "S";
                        5'd1:  fixed_char = "Y";
                        5'd2:  fixed_char = "S";
                        5'd3:  fixed_char = "T";
                        5'd4:  fixed_char = "E";
                        5'd5:  fixed_char = "M";
                        default: fixed_char = 7'h20;
                    endcase
                end
                3'd2: begin
                    case (idx)
                        5'd0:  fixed_char = "S";
                        5'd1:  fixed_char = "W";
                        5'd2:  fixed_char = "I";
                        5'd3:  fixed_char = "T";
                        5'd4:  fixed_char = "C";
                        5'd5:  fixed_char = "H";
                        5'd6:  fixed_char = " ";
                        5'd7:  fixed_char = "F";
                        5'd8:  fixed_char = "U";
                        5'd9:  fixed_char = "N";
                        5'd10: fixed_char = "C";
                        5'd11: fixed_char = "T";
                        5'd12: fixed_char = "I";
                        5'd13: fixed_char = "O";
                        5'd14: fixed_char = "N";
                        5'd15: fixed_char = "S";
                        default: fixed_char = 7'h20;
                    endcase
                end
                3'd3: begin
                    case (idx)
                        5'd0: fixed_char = "C";
                        5'd1: fixed_char = "O";
                        5'd2: fixed_char = "N";
                        5'd3: fixed_char = "T";
                        5'd4: fixed_char = "R";
                        5'd5: fixed_char = "O";
                        5'd6: fixed_char = "L";
                        5'd7: fixed_char = "S";
                        default: fixed_char = 7'h20;
                    endcase
                end
                3'd4: begin
                    case (idx)
                        5'd0: fixed_char = "S";
                        5'd1: fixed_char = "T";
                        5'd2: fixed_char = "A";
                        5'd3: fixed_char = "T";
                        5'd4: fixed_char = "U";
                        5'd5: fixed_char = "S";
                        default: fixed_char = 7'h20;
                    endcase
                end
                3'd5: begin
                    case (idx)
                        5'd0:  fixed_char = "E";
                        5'd1:  fixed_char = "G";
                        5'd2:  fixed_char = "4";
                        5'd3:  fixed_char = "S";
                        5'd4:  fixed_char = "2";
                        5'd5:  fixed_char = "0";
                        5'd6:  fixed_char = " ";
                        5'd7:  fixed_char = "H";
                        5'd8:  fixed_char = "D";
                        5'd9:  fixed_char = "M";
                        5'd10: fixed_char = "I";
                        5'd11: fixed_char = " ";
                        5'd12: fixed_char = "P";
                        5'd13: fixed_char = "L";
                        5'd14: fixed_char = "A";
                        5'd15: fixed_char = "Y";
                        5'd16: fixed_char = "E";
                        5'd17: fixed_char = "R";
                        default: fixed_char = 7'h20;
                    endcase
                end
                default: begin
                    case (idx)
                        5'd0:  fixed_char = "F";
                        5'd1:  fixed_char = "O";
                        5'd2:  fixed_char = "U";
                        5'd3:  fixed_char = "N";
                        5'd4:  fixed_char = "D";
                        5'd5:  fixed_char = " ";
                        5'd6:  fixed_char = "I";
                        5'd7:  fixed_char = "M";
                        5'd8:  fixed_char = "A";
                        5'd9:  fixed_char = "G";
                        5'd10: fixed_char = "E";
                        5'd11: fixed_char = "S";
                        5'd12: fixed_char = ":";
                        5'd13: fixed_char = " ";
                        default: fixed_char = 7'h20;
                    endcase
                end
            endcase
        end
    endfunction

    // 启动状态：0=SD CARD INIT... 1=SCANNING IMAGES... 2=LOADING IMAGE... 3=NO IMAGE ON SD
    function [6:0] boot_msg_char;
        input [1:0] sel;
        input [4:0] idx;
        begin
            boot_msg_char = 7'h20;
            case (sel)
                2'd0: begin
                    case (idx)
                        5'd0:  boot_msg_char = "S";
                        5'd1:  boot_msg_char = "D";
                        5'd2:  boot_msg_char = " ";
                        5'd3:  boot_msg_char = "C";
                        5'd4:  boot_msg_char = "A";
                        5'd5:  boot_msg_char = "R";
                        5'd6:  boot_msg_char = "D";
                        5'd7:  boot_msg_char = " ";
                        5'd8:  boot_msg_char = "I";
                        5'd9:  boot_msg_char = "N";
                        5'd10: boot_msg_char = "I";
                        5'd11: boot_msg_char = "T";
                        5'd12: boot_msg_char = ".";
                        5'd13: boot_msg_char = ".";
                        5'd14: boot_msg_char = ".";
                        default: boot_msg_char = 7'h20;
                    endcase
                end
                2'd1: begin
                    case (idx)
                        5'd0:  boot_msg_char = "S";
                        5'd1:  boot_msg_char = "C";
                        5'd2:  boot_msg_char = "A";
                        5'd3:  boot_msg_char = "N";
                        5'd4:  boot_msg_char = "N";
                        5'd5:  boot_msg_char = "I";
                        5'd6:  boot_msg_char = "N";
                        5'd7:  boot_msg_char = "G";
                        5'd8:  boot_msg_char = " ";
                        5'd9:  boot_msg_char = "I";
                        5'd10: boot_msg_char = "M";
                        5'd11: boot_msg_char = "A";
                        5'd12: boot_msg_char = "G";
                        5'd13: boot_msg_char = "E";
                        5'd14: boot_msg_char = "S";
                        5'd15: boot_msg_char = ".";
                        5'd16: boot_msg_char = ".";
                        5'd17: boot_msg_char = ".";
                        default: boot_msg_char = 7'h20;
                    endcase
                end
                2'd2: begin
                    case (idx)
                        5'd0:  boot_msg_char = "L";
                        5'd1:  boot_msg_char = "O";
                        5'd2:  boot_msg_char = "A";
                        5'd3:  boot_msg_char = "D";
                        5'd4:  boot_msg_char = "I";
                        5'd5:  boot_msg_char = "N";
                        5'd6:  boot_msg_char = "G";
                        5'd7:  boot_msg_char = " ";
                        5'd8:  boot_msg_char = "I";
                        5'd9:  boot_msg_char = "M";
                        5'd10: boot_msg_char = "A";
                        5'd11: boot_msg_char = "G";
                        5'd12: boot_msg_char = "E";
                        5'd13: boot_msg_char = ".";
                        5'd14: boot_msg_char = ".";
                        5'd15: boot_msg_char = ".";
                        default: boot_msg_char = 7'h20;
                    endcase
                end
                default: begin
                    case (idx)
                        5'd0:  boot_msg_char = "N";
                        5'd1:  boot_msg_char = "O";
                        5'd2:  boot_msg_char = " ";
                        5'd3:  boot_msg_char = "I";
                        5'd4:  boot_msg_char = "M";
                        5'd5:  boot_msg_char = "A";
                        5'd6:  boot_msg_char = "G";
                        5'd7:  boot_msg_char = "E";
                        5'd8:  boot_msg_char = " ";
                        5'd9:  boot_msg_char = "O";
                        5'd10: boot_msg_char = "N";
                        5'd11: boot_msg_char = " ";
                        5'd12: boot_msg_char = "S";
                        5'd13: boot_msg_char = "D";
                        default: boot_msg_char = 7'h20;
                    endcase
                end
            endcase
        end
    endfunction

    // 右面板按键说明（9 行 × 最多 23 字符）
    function [6:0] guide_char;
        input [3:0] line;
        input [4:0] col;
        begin
            guide_char = 7'h20;
            case (line)
                4'd0: begin   // SW1 IMAGE LAYER
                    case (col)
                        5'd0: guide_char = "S";
                        5'd1: guide_char = "W";
                        5'd2: guide_char = "1";
                        5'd3: guide_char = " ";
                        5'd4: guide_char = "I";
                        5'd5: guide_char = "M";
                        5'd6: guide_char = "A";
                        5'd7: guide_char = "G";
                        5'd8: guide_char = "E";
                        5'd9: guide_char = " ";
                        5'd10: guide_char = "L";
                        5'd11: guide_char = "A";
                        5'd12: guide_char = "Y";
                        5'd13: guide_char = "E";
                        5'd14: guide_char = "R";
                        default: guide_char = 7'h20;
                    endcase
                end
                4'd1: begin   //  K1 MODE  K2 NEXT
                    case (col)
                        5'd0:  guide_char = " ";
                        5'd1:  guide_char = "K";
                        5'd2:  guide_char = "1";
                        5'd3:  guide_char = " ";
                        5'd4:  guide_char = "M";
                        5'd5:  guide_char = "O";
                        5'd6:  guide_char = "D";
                        5'd7:  guide_char = "E";
                        5'd8:  guide_char = " ";
                        5'd9:  guide_char = " ";
                        5'd10: guide_char = "K";
                        5'd11: guide_char = "2";
                        5'd12: guide_char = " ";
                        5'd13: guide_char = "N";
                        5'd14: guide_char = "E";
                        5'd15: guide_char = "X";
                        5'd16: guide_char = "T";
                        default: guide_char = 7'h20;
                    endcase
                end
                4'd2: begin   //  K3 CONTRAST K4 BRIGHT
                    case (col)
                        5'd0:  guide_char = " ";
                        5'd1:  guide_char = "K";
                        5'd2:  guide_char = "3";
                        5'd3:  guide_char = " ";
                        5'd4:  guide_char = "C";
                        5'd5:  guide_char = "O";
                        5'd6:  guide_char = "N";
                        5'd7:  guide_char = "T";
                        5'd8:  guide_char = "R";
                        5'd9:  guide_char = "A";
                        5'd10: guide_char = "S";
                        5'd11: guide_char = "T";
                        5'd12: guide_char = " ";
                        5'd13: guide_char = " ";
                        5'd14: guide_char = "K";
                        5'd15: guide_char = "4";
                        5'd16: guide_char = " ";
                        5'd17: guide_char = "B";
                        5'd18: guide_char = "R";
                        5'd19: guide_char = "I";
                        5'd20: guide_char = "G";
                        5'd21: guide_char = "H";
                        5'd22: guide_char = "T";
                        default: guide_char = 7'h20;
                    endcase
                end
                4'd3: begin   // SW2 AUTO LAYER
                    case (col)
                        5'd0:  guide_char = "S";
                        5'd1:  guide_char = "W";
                        5'd2:  guide_char = "2";
                        5'd3:  guide_char = " ";
                        5'd4:  guide_char = "A";
                        5'd5:  guide_char = "U";
                        5'd6:  guide_char = "T";
                        5'd7:  guide_char = "O";
                        5'd8:  guide_char = " ";
                        5'd9:  guide_char = "L";
                        5'd10: guide_char = "A";
                        5'd11: guide_char = "Y";
                        5'd12: guide_char = "E";
                        5'd13: guide_char = "R";
                        default: guide_char = 7'h20;
                    endcase
                end
                4'd4: begin   //  K1 MODE  K2 AUTOPLAY
                    case (col)
                        5'd0:  guide_char = " ";
                        5'd1:  guide_char = "K";
                        5'd2:  guide_char = "1";
                        5'd3:  guide_char = " ";
                        5'd4:  guide_char = "M";
                        5'd5:  guide_char = "O";
                        5'd6:  guide_char = "D";
                        5'd7:  guide_char = "E";
                        5'd8:  guide_char = " ";
                        5'd9:  guide_char = " ";
                        5'd10: guide_char = "K";
                        5'd11: guide_char = "2";
                        5'd12: guide_char = " ";
                        5'd13: guide_char = "A";
                        5'd14: guide_char = "U";
                        5'd15: guide_char = "T";
                        5'd16: guide_char = "O";
                        5'd17: guide_char = "P";
                        5'd18: guide_char = "L";
                        5'd19: guide_char = "A";
                        5'd20: guide_char = "Y";
                        default: guide_char = 7'h20;
                    endcase
                end
                4'd5: begin   //  K3 AUDIO K4 VIZ
                    case (col)
                        5'd0:  guide_char = " ";
                        5'd1:  guide_char = "K";
                        5'd2:  guide_char = "3";
                        5'd3:  guide_char = " ";
                        5'd4:  guide_char = "A";
                        5'd5:  guide_char = "U";
                        5'd6:  guide_char = "D";
                        5'd7:  guide_char = "I";
                        5'd8:  guide_char = "O";
                        5'd9:  guide_char = " ";
                        5'd10: guide_char = " ";
                        5'd11: guide_char = "K";
                        5'd12: guide_char = "4";
                        5'd13: guide_char = " ";
                        5'd14: guide_char = "V";
                        5'd15: guide_char = "I";
                        5'd16: guide_char = "Z";
                        default: guide_char = 7'h20;
                    endcase
                end
                4'd6: begin   // SW3 VIDEO LAYER
                    case (col)
                        5'd0:  guide_char = "S";
                        5'd1:  guide_char = "W";
                        5'd2:  guide_char = "3";
                        5'd3:  guide_char = " ";
                        5'd4:  guide_char = "V";
                        5'd5:  guide_char = "I";
                        5'd6:  guide_char = "D";
                        5'd7:  guide_char = "E";
                        5'd8:  guide_char = "O";
                        5'd9:  guide_char = " ";
                        5'd10: guide_char = "L";
                        5'd11: guide_char = "A";
                        5'd12: guide_char = "Y";
                        5'd13: guide_char = "E";
                        5'd14: guide_char = "R";
                        default: guide_char = 7'h20;
                    endcase
                end
                4'd7: begin   //  K1 PLAY K2 DANMAKU
                    case (col)
                        5'd0:  guide_char = " ";
                        5'd1:  guide_char = "K";
                        5'd2:  guide_char = "1";
                        5'd3:  guide_char = " ";
                        5'd4:  guide_char = "P";
                        5'd5:  guide_char = "L";
                        5'd6:  guide_char = "A";
                        5'd7:  guide_char = "Y";
                        5'd8:  guide_char = " ";
                        5'd9:  guide_char = " ";
                        5'd10: guide_char = "K";
                        5'd11: guide_char = "2";
                        5'd12: guide_char = " ";
                        5'd13: guide_char = "D";
                        5'd14: guide_char = "A";
                        5'd15: guide_char = "N";
                        5'd16: guide_char = "M";
                        5'd17: guide_char = "A";
                        5'd18: guide_char = "K";
                        5'd19: guide_char = "U";
                        default: guide_char = 7'h20;
                    endcase
                end
                default: begin // K3 SPEC K4 RESMON
                    case (col)
                        5'd0:  guide_char = " ";
                        5'd1:  guide_char = "K";
                        5'd2:  guide_char = "3";
                        5'd3:  guide_char = " ";
                        5'd4:  guide_char = "S";
                        5'd5:  guide_char = "P";
                        5'd6:  guide_char = "E";
                        5'd7:  guide_char = "C";
                        5'd8:  guide_char = " ";
                        5'd9:  guide_char = " ";
                        5'd10: guide_char = "K";
                        5'd11: guide_char = "4";
                        5'd12: guide_char = " ";
                        5'd13: guide_char = "R";
                        5'd14: guide_char = "E";
                        5'd15: guide_char = "S";
                        5'd16: guide_char = "M";
                        5'd17: guide_char = "O";
                        5'd18: guide_char = "N";
                        default: guide_char = 7'h20;
                    endcase
                end
            endcase
        end
    endfunction

    // 右面板实时状态（3 行 × 16 字符，B/C 以百分比显示）
    function [6:0] stat_char;
        input [1:0] line;
        input [4:0] col;
        begin
            stat_char = 7'h20;
            case (line)
                2'd0: begin   // M:0 B100% C100%
                    case (col)
                        5'd0:  stat_char = "M";
                        5'd1:  stat_char = ":";
                        5'd2:  stat_char = {3'h3, 2'b00, i_mode};
                        5'd3:  stat_char = " ";
                        5'd4:  stat_char = "B";
                        5'd5:  stat_char = b_hc;
                        5'd6:  stat_char = b_tc;
                        5'd7:  stat_char = "0";
                        5'd8:  stat_char = "%";
                        5'd9:  stat_char = " ";
                        5'd10: stat_char = "C";
                        5'd11: stat_char = c_hc;
                        5'd12: stat_char = c_tc;
                        5'd13: stat_char = "0";
                        5'd14: stat_char = "%";
                        default: stat_char = 7'h20;
                    endcase
                end
                2'd1: begin   // AUTO:ON  VIZ:2
                    case (col)
                        5'd0:  stat_char = "A";
                        5'd1:  stat_char = "U";
                        5'd2:  stat_char = "T";
                        5'd3:  stat_char = "O";
                        5'd4:  stat_char = ":";
                        5'd5:  stat_char = i_auto_play ? "N" : "F";
                        5'd6:  stat_char = i_auto_play ? " " : "F";
                        5'd7:  stat_char = " ";
                        5'd8:  stat_char = " ";
                        5'd9:  stat_char = "V";
                        5'd10: stat_char = "I";
                        5'd11: stat_char = "Z";
                        5'd12: stat_char = ":";
                        5'd13: stat_char = {3'h3, 1'b0, i_viz_mode};
                        default: stat_char = 7'h20;
                    endcase
                end
                default: begin // DM:OFF VD:STOP
                    case (col)
                        5'd0:  stat_char = "D";
                        5'd1:  stat_char = "M";
                        5'd2:  stat_char = ":";
                        5'd3:  stat_char = i_dm_en ? "N" : "F";
                        5'd4:  stat_char = i_dm_en ? " " : "F";
                        5'd5:  stat_char = " ";
                        5'd6:  stat_char = "V";
                        5'd7:  stat_char = "D";
                        5'd8:  stat_char = ":";
                        5'd9:  stat_char = i_video_on ? "R" : "S";
                        5'd10: stat_char = i_video_on ? "U" : "T";
                        5'd11: stat_char = i_video_on ? "N" : "O";
                        5'd12: stat_char = i_video_on ? " " : "P";
                        default: stat_char = 7'h20;
                    endcase
                end
            endcase
        end
    endfunction

    // 32 段频谱电平读取
    function [5:0] spec_get;
        input [191:0] v;
        input [4:0] b;
        begin
            case (b)
                5'd0:  spec_get = v[5:0];
                5'd1:  spec_get = v[11:6];
                5'd2:  spec_get = v[17:12];
                5'd3:  spec_get = v[23:18];
                5'd4:  spec_get = v[29:24];
                5'd5:  spec_get = v[35:30];
                5'd6:  spec_get = v[41:36];
                5'd7:  spec_get = v[47:42];
                5'd8:  spec_get = v[53:48];
                5'd9:  spec_get = v[59:54];
                5'd10: spec_get = v[65:60];
                5'd11: spec_get = v[71:66];
                5'd12: spec_get = v[77:72];
                5'd13: spec_get = v[83:78];
                5'd14: spec_get = v[89:84];
                5'd15: spec_get = v[95:90];
                5'd16: spec_get = v[101:96];
                5'd17: spec_get = v[107:102];
                5'd18: spec_get = v[113:108];
                5'd19: spec_get = v[119:114];
                5'd20: spec_get = v[125:120];
                5'd21: spec_get = v[131:126];
                5'd22: spec_get = v[137:132];
                5'd23: spec_get = v[143:138];
                5'd24: spec_get = v[149:144];
                5'd25: spec_get = v[155:150];
                5'd26: spec_get = v[161:156];
                5'd27: spec_get = v[167:162];
                5'd28: spec_get = v[173:168];
                5'd29: spec_get = v[179:174];
                5'd30: spec_get = v[185:180];
                5'd31: spec_get = v[191:186];
                default: spec_get = 6'd0;
            endcase
        end
    endfunction

    wire [1:0] boot_sel = (!i_sd_init_done)     ? 2'd0 :
                          (!i_scan_done)        ? 2'd1 :
                          (i_img_count == 5'd0) ? 2'd3 :
                                                  2'd2;

    // ---- 左面板：x8..408, y80..392 ----
    localparam [10:0] LP_X0 = 11'd8;
    localparam [10:0] LP_X1 = 11'd408;
    localparam [10:0] LP_Y0 = 11'd80;
    localparam [10:0] LP_Y1 = 11'd392;

    wire in_lp = boot_mode && (x >= LP_X0) && (x < LP_X1) &&
                 (y >= LP_Y0) && (y < LP_Y1);
    wire in_lp_border = in_lp && ((x < LP_X0 + 11'd3) || (x >= LP_X1 - 11'd3) ||
                                  (y < LP_Y0 + 11'd3) || (y >= LP_Y1 - 11'd3));

    wire [10:0] mq_sum = x + y + {1'b0, mq_phase};
    wire mq_lit = (mq_sum[3:0] < 4'd8);
    reg [23:0] mq_color;
    always @(*) begin
        case (mq_sum[6:5])
            2'd0: mq_color = 24'h00E5FF;
            2'd1: mq_color = 24'h33FF99;
            2'd2: mq_color = 24'hFFD166;
            default: mq_color = 24'hFF5CA8;
        endcase
    end

    // 标题（4x）
    localparam [10:0] T1_X = 11'd16;
    localparam [10:0] T1_Y = 11'd120;
    wire [10:0] t1_off = x - T1_X;
    wire [3:0]  t1_idx = t1_off[8:5];
    wire [2:0]  t1_col = t1_off[4:2];
    wire [10:0] t1_v   = y - T1_Y;
    wire [2:0]  t1_row = t1_v[4:2];
    wire in_t1 = boot_mode && (x >= T1_X) && (x < T1_X + 11'd384) &&
                 (y >= T1_Y) && (y < T1_Y + 11'd32);

    localparam [10:0] T2_X = 11'd112;
    localparam [10:0] T2_Y = 11'd160;
    wire [10:0] t2_off = x - T2_X;
    wire [2:0]  t2_idx = t2_off[7:5];
    wire [2:0]  t2_col = t2_off[4:2];
    wire [10:0] t2_v   = y - T2_Y;
    wire [2:0]  t2_row = t2_v[4:2];
    wire in_t2 = boot_mode && (x >= T2_X) && (x < T2_X + 11'd192) &&
                 (y >= T2_Y) && (y < T2_Y + 11'd32);

    // 启动状态文字（2x）
    localparam [10:0] BST_X = 11'd64;
    localparam [10:0] BST_Y = 11'd224;
    wire [10:0] bst_off = x - BST_X;
    wire [4:0]  bst_idx = bst_off[8:4];
    wire [2:0]  bst_col = bst_off[3:1];
    wire [10:0] bst_v   = y - BST_Y;
    wire [2:0]  bst_row = bst_v[3:1];
    wire in_bst = boot_mode && (x >= BST_X) && (x < BST_X + 11'd288) &&
                  (y >= BST_Y) && (y < BST_Y + 11'd16);

    // FOUND IMAGES（2x）
    localparam [10:0] FND_X = 11'd88;
    localparam [10:0] FND_Y = 11'd256;
    wire [10:0] fnd_off = x - FND_X;
    wire [4:0]  fnd_idx = fnd_off[8:4];
    wire [2:0]  fnd_col = fnd_off[3:1];
    wire [10:0] fnd_v   = y - FND_Y;
    wire [2:0]  fnd_row = fnd_v[3:1];
    wire in_fnd = boot_mode && (x >= FND_X) && (x < FND_X + 11'd240) &&
                  (y >= FND_Y) && (y < FND_Y + 11'd16);

    // "M:0 B100% C100%"（1x）
    localparam [10:0] CFG_X = 11'd148;
    localparam [10:0] CFG_Y = 11'd292;
    wire [10:0] cfg_off = x - CFG_X;
    wire [4:0]  cfg_idx = cfg_off[7:3];
    wire [2:0]  cfg_col = cfg_off[2:0];
    wire [10:0] cfg_v   = y - CFG_Y;
    wire [2:0]  cfg_row = cfg_v[2:0];
    wire in_cfg = boot_mode && (x >= CFG_X) && (x < CFG_X + 11'd120) &&
                  (y >= CFG_Y) && (y < CFG_Y + 11'd8);

    // 进度条
    wire in_prg = (x >= 11'd80) && (x < 11'd336) && (y >= 11'd320) && (y < 11'd328);
    wire [10:0] prg_raw = x - 11'd80;
    wire [10:0] prg_pos = prg_raw + {1'b0, mq_phase};
    wire prg_lit  = (prg_pos[7:0] < 8'd48);
    wire prg_edge = (x == 11'd80) || (x == 11'd335) ||
                    (y == 11'd320) || (y == 11'd327);

    wire in_div1 = (y >= 11'd204) && (y < 11'd206) &&
                   (x >= 11'd56) && (x < 11'd360);

    // 底部署名（1x）
    localparam [10:0] FTR_X = 11'd136;
    localparam [10:0] FTR_Y = 11'd348;
    wire [10:0] ftr_off = x - FTR_X;
    wire [4:0]  ftr_idx = ftr_off[7:3];
    wire [2:0]  ftr_col = ftr_off[2:0];
    wire [10:0] ftr_v   = y - FTR_Y;
    wire [2:0]  ftr_row = ftr_v[2:0];
    wire in_ftr = boot_mode && (x >= FTR_X) && (x < FTR_X + 11'd144) &&
                  (y >= FTR_Y) && (y < FTR_Y + 11'd8);

    // ---- 右面板：x416..624, y80..392 ----
    localparam [10:0] RP_X0 = 11'd416;
    localparam [10:0] RP_X1 = 11'd624;
    localparam [10:0] RP_Y0 = 11'd80;
    localparam [10:0] RP_Y1 = 11'd392;

    wire in_rp = boot_mode && (x >= RP_X0) && (x < RP_X1) &&
                 (y >= RP_Y0) && (y < RP_Y1);
    wire in_rp_border = in_rp && ((x < RP_X0 + 11'd2) || (x >= RP_X1 - 11'd2) ||
                                  (y < RP_Y0 + 11'd2) || (y >= RP_Y1 - 11'd2));

    // "CONTROLS"（2x）
    localparam [10:0] RH_X = 11'd456;
    localparam [10:0] RH_Y = 11'd90;
    wire [10:0] rh_off = x - RH_X;
    wire [2:0]  rh_idx = rh_off[6:4];
    wire [2:0]  rh_col = rh_off[4:1];
    wire [10:0] rh_v   = y - RH_Y;
    wire [2:0]  rh_row = rh_v[4:1];
    wire in_rh = boot_mode && (x >= RH_X) && (x < RH_X + 11'd128) &&
                 (y >= RH_Y) && (y < RH_Y + 11'd16);

    // "SWITCH FUNCTIONS"（1x）
    localparam [10:0] RS_X = 11'd456;
    localparam [10:0] RS_Y = 11'd112;
    wire [10:0] rs_off = x - RS_X;
    wire [3:0]  rs_idx = rs_off[6:3];
    wire [2:0]  rs_col = rs_off[2:0];
    wire [10:0] rs_v   = y - RS_Y;
    wire [2:0]  rs_row = rs_v[2:0];
    wire in_rs = boot_mode && (x >= RS_X) && (x < RS_X + 11'd128) &&
                 (y >= RS_Y) && (y < RS_Y + 11'd8);

    wire in_rhdiv = (y >= 11'd124) && (y < 11'd126) &&
                    (x >= 11'd418) && (x < 11'd622);

    // 按键说明（1x，9 行，16px 行距）
    localparam [10:0] GD_X = 11'd432;
    localparam [10:0] GD_Y = 11'd134;
    wire [10:0] gd_offx = x - GD_X;
    wire [10:0] gd_offy = y - GD_Y;
    wire [4:0]  gd_col  = gd_offx[7:3];
    wire [3:0]  gd_line = gd_offy[7:4];
    wire [2:0]  gd_row  = gd_offy[2:0];
    wire in_gd = boot_mode && (x >= GD_X) && (x < GD_X + 11'd184) &&
                 (y >= GD_Y) && (y < GD_Y + 11'd144) && ~gd_offy[3];

    wire in_div2 = (y >= 11'd280) && (y < 11'd282) &&
                   (x >= 11'd418) && (x < 11'd622);

    // "STATUS"（2x）
    localparam [10:0] STH_X = 11'd472;
    localparam [10:0] STH_Y = 11'd290;
    wire [10:0] sth_off = x - STH_X;
    wire [2:0]  sth_idx = sth_off[6:4];
    wire [2:0]  sth_col = sth_off[4:1];
    wire [10:0] sth_v   = y - STH_Y;
    wire [2:0]  sth_row = sth_v[4:1];
    wire in_sth = boot_mode && (x >= STH_X) && (x < STH_X + 11'd96) &&
                  (y >= STH_Y) && (y < STH_Y + 11'd16);

    // 实时状态（1x，3 行）
    localparam [10:0] ST_X = 11'd456;
    localparam [10:0] ST_Y = 11'd314;
    wire [10:0] st_offx = x - ST_X;
    wire [10:0] st_offy = y - ST_Y;
    wire [3:0]  st_col  = st_offx[6:3];
    wire [1:0]  st_line = st_offy[5:4];
    wire [2:0]  st_row  = st_offy[2:0];
    wire in_st = boot_mode && (x >= ST_X) && (x < ST_X + 11'd128) &&
                 (y >= ST_Y) && (y < ST_Y + 11'd48) && ~st_offy[3];

    // ---- 启动界面字符选择 ----
    reg [6:0]  boot_char;
    reg [2:0]  boot_row;
    reg [2:0]  boot_col;
    reg        boot_text_on;
    reg [23:0] boot_text_color;

    always @(*) begin
        boot_char       = 7'h20;
        boot_row        = 3'd0;
        boot_col        = 3'd0;
        boot_text_on    = 1'b0;
        boot_text_color = 24'hFFFFFF;

        if (in_t1) begin
            boot_char = fixed_char(3'd0, {1'b0, t1_idx});
            boot_row  = t1_row;
            boot_col  = t1_col;
            boot_text_on = 1'b1;
            boot_text_color = 24'h9BE8FF;
        end else if (in_t2) begin
            boot_char = fixed_char(3'd1, {2'b00, t2_idx});
            boot_row  = t2_row;
            boot_col  = t2_col;
            boot_text_on = 1'b1;
            boot_text_color = 24'h9BE8FF;
        end else if (in_bst) begin
            boot_char = boot_msg_char(boot_sel, bst_idx);
            boot_row  = bst_row;
            boot_col  = bst_col;
            boot_text_on = 1'b1;
            boot_text_color = 24'hFFFFFF;
        end else if (in_fnd) begin
            if (fnd_idx == 5'd13)
                boot_char = (img_cnt_tens == 4'd0) ? 7'h20 : {3'h3, img_cnt_tens};
            else if (fnd_idx == 5'd14)
                boot_char = {3'h3, img_cnt_ones};
            else
                boot_char = fixed_char(3'd6, fnd_idx);
            boot_row  = fnd_row;
            boot_col  = fnd_col;
            boot_text_on = 1'b1;
            boot_text_color = 24'h8CFFB0;
        end else if (in_cfg) begin
            case (cfg_idx)
                5'd0:  boot_char = "M";
                5'd1:  boot_char = ":";
                5'd2:  boot_char = {3'h3, 2'b00, i_mode};
                5'd3:  boot_char = " ";
                5'd4:  boot_char = "B";
                5'd5:  boot_char = b_hc;
                5'd6:  boot_char = b_tc;
                5'd7:  boot_char = "0";
                5'd8:  boot_char = "%";
                5'd9:  boot_char = " ";
                5'd10: boot_char = "C";
                5'd11: boot_char = c_hc;
                5'd12: boot_char = c_tc;
                5'd13: boot_char = "0";
                5'd14: boot_char = "%";
                default: boot_char = 7'h20;
            endcase
            boot_row  = cfg_row;
            boot_col  = cfg_col;
            boot_text_on = 1'b1;
            boot_text_color = 24'h9AA8C0;
        end else if (in_ftr) begin
            boot_char = fixed_char(3'd5, ftr_idx);
            boot_row  = ftr_row;
            boot_col  = ftr_col;
            boot_text_on = 1'b1;
            boot_text_color = 24'h5F7290;
        end else if (in_rh) begin
            boot_char = fixed_char(3'd3, {1'b0, rh_idx});
            boot_row  = rh_row;
            boot_col  = rh_col;
            boot_text_on = 1'b1;
            boot_text_color = 24'h9BE8FF;
        end else if (in_rs) begin
            boot_char = fixed_char(3'd2, rs_idx);
            boot_row  = rs_row;
            boot_col  = rs_col;
            boot_text_on = 1'b1;
            boot_text_color = 24'h6FD3FF;
        end else if (in_gd) begin
            boot_char = guide_char(gd_line, gd_col);
            boot_row  = gd_row;
            boot_col  = gd_offx[2:0];
            boot_text_on = 1'b1;
            boot_text_color = 24'hB8C6DC;
        end else if (in_sth) begin
            boot_char = fixed_char(3'd4, {1'b0, sth_idx});
            boot_row  = sth_row;
            boot_col  = sth_col;
            boot_text_on = 1'b1;
            boot_text_color = 24'h7CFFB2;
        end else if (in_st) begin
            boot_char = stat_char(st_line, st_col);
            boot_row  = st_row;
            boot_col  = st_offx[2:0];
            boot_text_on = 1'b1;
            boot_text_color = 24'hA8B8D0;
        end
    end

    // ---- 32 段频谱平滑 + 峰值保持 ----
    reg [5:0] bar_lvl [0:31];
    reg [5:0] bar_pk  [0:31];
    integer   bi;
    reg [5:0] nl;

    always @(posedge i_clk or posedge i_rst) begin
        if (i_rst) begin
            for (bi = 0; bi < 32; bi = bi + 1) begin
                bar_lvl[bi] <= 6'd0;
                bar_pk[bi]  <= 6'd0;
            end
        end else if (vs_rise) begin
            for (bi = 0; bi < 32; bi = bi + 1) begin
                nl = spec_get(i_spec_level, bi[4:0]);
                if (nl > bar_lvl[bi])
                    bar_lvl[bi] <= nl;
                else if (bar_lvl[bi] > 6'd0)
                    bar_lvl[bi] <= bar_lvl[bi] - 6'd1;

                if (nl >= bar_pk[bi])
                    bar_pk[bi] <= nl;
                else if (bar_pk[bi] > 6'd0)
                    bar_pk[bi] <= bar_pk[bi] - 6'd1;
            end
        end
    end

    // ---- 全宽透明频谱：x0..640，柱底 y=456，32 段 × 20px ----
    // band = (x*13)>>8 近似 x/20；列内相位 frac<200 为柱体（约 16px 宽）
    wire [15:0] sx13 = ({5'd0, x} << 3) + ({5'd0, x} << 2) + {5'd0, x};
    wire [4:0]  s_band_raw = sx13[12:8];
    wire [4:0]  s_band = (s_band_raw > 5'd31) ? 5'd31 : s_band_raw;
    wire        s_col_on = (sx13[7:0] < 8'd200);

    wire [5:0]  s_lvl = bar_lvl[s_band];
    wire [5:0]  s_pk  = bar_pk[s_band];
    wire [8:0]  s_h   = {1'b0, s_lvl, 2'b00};        // ×4
    wire [8:0]  s_ph  = {1'b0, s_pk,  2'b00};
    wire [9:0]  s_sy  = 10'd456 - y;                 // 柱底向上计数

    wire spec_on   = ~boot_mode && ((i_viz_mode == 2'd2) || i_spec_en);
    wire spec_zone = spec_on && (y >= 11'd204) && (y < 11'd456) && s_col_on;
    wire spec_bar  = spec_zone && (s_sy <= s_h);
    wire spec_peak = spec_zone && (s_pk != 6'd0) && (s_sy > s_h) &&
                     ((s_sy == s_ph) || (s_sy == s_ph + 9'd1));

    wire [23:0] spec_color = (s_sy >= 10'd192) ? 24'hFF3860 :
                             (s_sy >= 10'd128) ? 24'hFFC93C :
                             (s_sy >= 10'd64)  ? 24'h5CFF7A :
                                                 24'h28C8FF;

    // ---- VU 电平条 ----
    localparam [10:0] AV_X = 11'd160;
    localparam [10:0] AV_Y = 11'd216;
    localparam [10:0] AV_W = 11'd320;
    localparam [10:0] AV_H = 11'd24;
    wire [16:0] av_prod = {9'd0, i_audio_level} * 11'd320;
    wire [9:0]  av_len  = av_prod[15:8];
    wire in_av = ~boot_mode && (i_viz_mode != 2'd0) &&
                 (x >= AV_X) && (x < AV_X + AV_W) &&
                 (y >= AV_Y) && (y < AV_Y + AV_H);
    wire in_av_bar = in_av && (x < AV_X + {1'b0, av_len});
    wire [23:0] av_color = (x >= AV_X + {1'b0, av_len[9:1]}) ?
                            24'hFFD166 : 24'h39D98A;

    // ======================= 弹幕 =======================
    wire        dm_txt_on;
    wire [6:0]  dm_char;
    wire [2:0]  dm_row, dm_col;
    wire [23:0] dm_color;

    danmaku_osd u_danmaku (
        .i_clk        (i_clk),
        .i_rst        (i_rst),
        .i_frame_tick (vs_rise),
        .i_x          (x),
        .i_y          (y),
        .i_en         (i_dm_en && ~boot_mode),
        .i_text       (i_dm_text),
        .i_len        (i_dm_len),
        .i_color      (i_dm_color),
        .i_tgl        (i_dm_tgl),
        .o_ack        (o_dm_ack),
        .o_txt_on     (dm_txt_on),
        .o_char       (dm_char),
        .o_row        (dm_row),
        .o_col        (dm_col),
        .o_color      (dm_color)
    );

    // ======================= 资源占用面板 =======================
    wire        rm_txt_on;
    wire [6:0]  rm_char;
    wire [2:0]  rm_row, rm_col;
    wire [23:0] rm_color;
    wire        rm_bg_on;
    wire [23:0] rm_bg_color;

    resmon_osd #(
        .LUT_PCT (RM_LUT_PCT),
        .FF_PCT  (RM_FF_PCT),
        .RAM_PCT (RM_RAM_PCT),
        .DSP_PCT (RM_DSP_PCT)
    ) u_resmon (
        .i_clk       (i_clk),
        .i_rst       (i_rst),
        .i_x         (x),
        .i_y         (y),
        .i_en        (i_rm_en && ~boot_mode),
        .i_frame_bcd (vid_bcd),
        .i_video_on  (i_video_on),
        .o_txt_on    (rm_txt_on),
        .o_char      (rm_char),
        .o_row       (rm_row),
        .o_col       (rm_col),
        .o_color     (rm_color),
        .o_bg_on     (rm_bg_on),
        .o_bg_color  (rm_bg_color)
    );

    // ---- 统一字符源（优先级：顶栏 > 底栏 > 弹幕 > 资源面板 > 启动面板）----
    localparam [2:0] S_NONE = 3'd0, S_BOOT = 3'd1, S_TITLE = 3'd2,
                     S_TS   = 3'd3, S_BOT  = 3'd4, S_DM    = 3'd5,
                     S_RM   = 3'd6;

    reg [2:0]  t_src;
    reg [6:0]  t_char;
    reg [2:0]  t_row;
    reg [2:0]  t_col;
    reg [23:0] t_color;

    always @(*) begin
        t_src   = S_NONE;
        t_char  = 7'h20;
        t_row   = 3'd0;
        t_col   = 3'd0;
        t_color = 24'hFFFFFF;
        if (in_title) begin
            t_src = S_TITLE; t_char = title_char; t_row = title_row;
            t_col = title_col; t_color = 24'hFFFFFF;
        end else if (in_ts) begin
            t_src = S_TS; t_char = ts_char; t_row = ts_row;
            t_col = ts_col; t_color = 24'hFFFFFF;
        end else if (in_bot) begin
            t_src = S_BOT; t_char = bot_char; t_row = bot_row;
            t_col = bot_col; t_color = 24'hFFFFFF;
        end else if (dm_txt_on) begin
            t_src = S_DM; t_char = dm_char; t_row = dm_row;
            t_col = dm_col; t_color = dm_color;
        end else if (rm_txt_on) begin
            t_src = S_RM; t_char = rm_char; t_row = rm_row;
            t_col = rm_col; t_color = rm_color;
        end else if (boot_text_on) begin
            t_src = S_BOOT; t_char = boot_char; t_row = boot_row;
            t_col = boot_col; t_color = boot_text_color;
        end
    end

    // ---- 共享字库 ROM ----
    wire [7:0] glyph;
    font8x8 u_font (
        .i_char (t_char), .i_row (t_row), .o_row (glyph)
    );

    wire t_px    = (t_src != S_NONE) && glyph[7 - t_col];
    wire boot_px = t_px && (t_src == S_BOOT);
    wire bar_px  = t_px && ((t_src == S_TITLE) || (t_src == S_TS));
    wire bot_px  = t_px && (t_src == S_BOT);
    wire dm_px   = t_px && (t_src == S_DM);
    wire rm_px   = t_px && (t_src == S_RM);

    // ---- 输出混合 ----
    reg [23:0] rgb_next;
    always @(*) begin
        if (in_lp_border)
            rgb_next = mq_lit ? mq_color : 24'h101A2E;
        else if (in_lp) begin
            if (in_prg) begin
                if (prg_edge)      rgb_next = 24'h2A5A8A;
                else if (prg_lit)  rgb_next = 24'h2FD8FF;
                else               rgb_next = 24'h101A2E;
            end else if (in_div1)
                rgb_next = 24'h1E4A66;
            else if (boot_px)
                rgb_next = t_color;
            else
                rgb_next = 24'h05080F;
        end
        else if (in_rp_border)
            rgb_next = 24'h1E5A7A;
        else if (in_rp) begin
            if (in_rhdiv || in_div2)
                rgb_next = 24'h1E4A66;
            else if (boot_px)
                rgb_next = t_color;
            else
                rgb_next = 24'h05080F;
        end
        else if (in_bar)
            rgb_next = bar_px ? 24'hFFFFFF : 24'h000000;
        else if (in_bot_bar)
            rgb_next = bot_px ? 24'hFFFFFF : 24'h000000;
        else if (rm_bg_on)
            rgb_next = rm_px ? t_color : rm_bg_color;
        else if (dm_px)
            rgb_next = t_color;
        else if (in_av)
            rgb_next = in_av_bar ? av_color : 24'h141A24;
        else if (spec_bar)
            rgb_next = spec_color;
        else if (spec_peak)
            rgb_next = 24'hFFFFFF;
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
