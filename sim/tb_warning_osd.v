`timescale 1ns/1ps
// 验证 osd_layer 的 SW4 告警层（全屏警示版）：
//   1) i_warn_en=0 时告警层完全透明（不遮挡图像/BMP）
//   2) 开启后逐像素对照整屏效果：
//        · 视频压到 1/4 亮度并叠脉动暗红（全屏都在告警态）
//        · 上下各 56px 的 45° 黄黑警示斜纹带，随呼吸横向流动
//        · 居中告警卡片 88..552 × 160..328：4px 脉动红边 + 2px 琥珀内线 + 深红底
//        · 4 倍字号 "WARNING"（208..432 × 176..208）
//        · 4 行 2 倍字号说明（216/240/264/288，行距 24px）
//   3) 呼吸值逐帧三角波（255 折返、0 折返）
//   4) 最高优先级：启动面板显示期间整屏仍被告警接管
module tb_warning_osd;
    localparam integer H = 640, V = 480;

    reg clk = 0, rst = 1;
    reg hs = 0, vs = 0, de = 0;
    reg [23:0] rgb = 24'h123456;
    reg        warn_en = 0;

    reg [1:0]  mode = 2'd0;
    reg [2:0]  bright = 3'd4, contrast = 3'd4;
    reg [3:0]  sw = 4'b0000;
    reg [255:0] slogan = 256'd0;
    reg [5:0]  slen = 6'd18;
    reg        sdir = 0, supd = 0, sscroll = 0;
    reg [1:0]  viz = 2'd0;
    reg        spec_en = 0;
    reg [7:0]  alevel = 8'd0;
    reg [191:0] spec_lv = 192'd0;
    reg        dm_en = 0, rm_en = 0;
    reg [191:0] dm_text = 192'd0;
    reg [4:0]  dm_len = 5'd0;
    reg [3:0]  dm_color = 4'd0;
    reg        dm_tgl = 0;
    reg        video_on = 0, vid_ftgl = 0, vok = 1;
    reg        disp_valid = 1;
    reg        sd_done = 1, scan_done = 1;
    reg [4:0]  img_cnt = 5'd3;
    reg        wav_fnd = 1;
    reg [15:0] src_w = 16'h0640, src_h = 16'h0480;
    reg        src_tgl = 0;
    reg        auto_play = 0;

    wire ohs, ovs, ode, dm_ack;
    wire [23:0] orgb;

    osd_layer dut (
        .i_clk(clk), .i_rst(rst), .i_hs(hs), .i_vs(vs), .i_de(de), .i_rgb(rgb),
        .i_mode(mode), .i_bright(bright), .i_contrast(contrast), .i_sw(sw),
        .i_slogan(slogan), .i_slogan_len(slen), .i_slogan_dir(sdir),
        .i_slogan_update(supd), .i_slogan_scroll(sscroll),
        .i_viz_mode(viz), .i_spec_en(spec_en), .i_audio_level(alevel),
        .i_spec_level(spec_lv),
        .i_dm_en(dm_en), .i_dm_text(dm_text), .i_dm_len(dm_len),
        .i_dm_color(dm_color), .i_dm_tgl(dm_tgl), .o_dm_ack(dm_ack),
        .i_rm_en(rm_en), .i_video_on(video_on), .i_vok(vok),
        .i_vid_ftgl(vid_ftgl),
        .i_display_valid(disp_valid), .i_sd_init_done(sd_done),
        .i_scan_done(scan_done), .i_img_count(img_cnt), .i_wav_found(wav_fnd),
        .i_src_w_bcd(src_w), .i_src_h_bcd(src_h), .i_src_tgl(src_tgl),
        .i_auto_play(auto_play), .i_warn_en(warn_en),
        .o_hs(ohs), .o_vs(ovs), .o_de(ode), .o_rgb(orgb)
    );

    // TB 侧字库（复算告警文本像素）
    reg [6:0] fch = 7'h20;
    reg [2:0] frow = 3'd0;
    wire [7:0] fglyph;
    font8x8 u_font (.i_char(fch), .i_row(frow), .o_row(fglyph));

    always #20 clk = ~clk;

    localparam [23:0] BG      = 24'h123456;
    localparam [23:0] WN_BG   = 24'h160507;
    localparam [23:0] WN_TEXT = 24'hFFE8E8;
    localparam integer CARD_X0 = 88,  CARD_X1 = 552;
    localparam integer CARD_Y0 = 160, CARD_Y1 = 328;
    localparam integer BAND_H  = 56;

    reg [23:0] fb [0:V*H-1];
    reg [23:0] expv;
    integer errs = 0;
    integer dlyx = -1, dlyy = -1;

    // ---- 期望值模型（与 RTL 逐条对应）----
    function [23:0] exp_wash(input [7:0] r);
        begin
            exp_wash = {8'h14 + {2'b00, r[7:2]}, {2'b00, BG[15:10]}, {2'b00, BG[7:2]}};
        end
    endfunction

    function [23:0] exp_band(input integer xx, input integer yy, input [7:0] r);
        reg [15:0] s;
        begin
            s = xx + yy + (r >> 4);
            if ((yy == BAND_H - 1) || (yy == V - BAND_H))
                exp_band = 24'hFF3838;
            else
                exp_band = s[4] ? 24'hE8B21A : 24'h1A1206;
        end
    endfunction

    function [6:0] wnt_char(input integer i);
        begin
            case (i)
                0: wnt_char = "W";
                1: wnt_char = "A";
                2: wnt_char = "R";
                3: wnt_char = "N";
                4: wnt_char = "I";
                5: wnt_char = "N";
                6: wnt_char = "G";
                default: wnt_char = 7'h20;
            endcase
        end
    endfunction

    function [6:0] wls_char(input integer ln, input integer i);
        begin
            wls_char = 7'h20;
            case (ln)
            0: case (i)                                    // "EMERGENCY ALERT"
                0: wls_char = "E";  1: wls_char = "M";  2: wls_char = "E";
                3: wls_char = "R";  4: wls_char = "G";  5: wls_char = "E";
                6: wls_char = "N";  7: wls_char = "C";  8: wls_char = "Y";
                10: wls_char = "A"; 11: wls_char = "L"; 12: wls_char = "E";
                13: wls_char = "R"; 14: wls_char = "T";
                default: ;
               endcase
            1: case (i)                                    // "SYSTEM IS IN DANGER"
                0: wls_char = "S";  1: wls_char = "Y";  2: wls_char = "S";
                3: wls_char = "T";  4: wls_char = "E";  5: wls_char = "M";
                7: wls_char = "I";  8: wls_char = "S";  10: wls_char = "I";
                11: wls_char = "N"; 13: wls_char = "D"; 14: wls_char = "A";
                15: wls_char = "N"; 16: wls_char = "G"; 17: wls_char = "E";
                18: wls_char = "R";
                default: ;
               endcase
            2: case (i)                                    // "ACTION REQUIRED NOW"
                0: wls_char = "A";  1: wls_char = "C";  2: wls_char = "T";
                3: wls_char = "I";  4: wls_char = "O";  5: wls_char = "N";
                7: wls_char = "R";  8: wls_char = "E";  9: wls_char = "Q";
                10: wls_char = "U"; 11: wls_char = "I"; 12: wls_char = "R";
                13: wls_char = "E"; 14: wls_char = "D"; 16: wls_char = "N";
                17: wls_char = "O"; 18: wls_char = "W";
                default: ;
               endcase
            default: case (i)                              // "CHECK THE EQUIPMENT"
                0: wls_char = "C";  1: wls_char = "H";  2: wls_char = "E";
                3: wls_char = "C";  4: wls_char = "K";  6: wls_char = "T";
                7: wls_char = "H";  8: wls_char = "E";  10: wls_char = "E";
                11: wls_char = "Q"; 12: wls_char = "U"; 13: wls_char = "I";
                14: wls_char = "P"; 15: wls_char = "M"; 16: wls_char = "E";
                17: wls_char = "N"; 18: wls_char = "T";
                default: ;
               endcase
            endcase
        end
    endfunction

    // 计算某像素在告警层下的期望颜色
    task calc_exp(input integer xx, input integer yy, input [7:0] r);
        integer ln, off, base;
        reg [2:0] row, col;
        reg in_t, in_l;
        begin
            in_t = (xx >= 208) && (xx < 432) && (yy >= 176) && (yy < 208);
            ln   = (yy < 240) ? 0 : (yy < 264) ? 1 : (yy < 288) ? 2 : 3;
            off  = (ln == 0) ? 200 : 168;
            base = 216 + ln * 24;
            in_l = (yy >= base) && (yy < base + 16) &&
                   (xx >= off) && (xx < off + 304);

            if (in_t) begin
                col = ((xx - 208) % 32) / 4;
                row = ((yy - 176) % 32) / 4;
                fch = wnt_char((xx - 208) / 32); frow = row; #1;
                expv = fglyph[7 - col] ? (r[7] ? 24'hFFFFFF : 24'hFFE2A0) : WN_BG;
            end else if (in_l) begin
                col = ((xx - off) % 16) / 2;
                row = ((yy - base) % 16) / 2;
                fch = wls_char(ln, (xx - off) / 16); frow = row; #1;
                expv = fglyph[7 - col] ? WN_TEXT : WN_BG;
            end else if ((yy < BAND_H) || (yy >= V - BAND_H)) begin
                expv = exp_band(xx, yy, r);
            end else if ((xx >= CARD_X0) && (xx < CARD_X1) &&
                         (yy >= CARD_Y0) && (yy < CARD_Y1)) begin
                if ((xx < CARD_X0 + 4) || (xx >= CARD_X1 - 4) ||
                    (yy < CARD_Y0 + 4) || (yy >= CARD_Y1 - 4))
                    expv = r[7] ? 24'hFF2A2A : 24'h8C0F0F;
                else if (((xx >= CARD_X0 + 10) && (xx < CARD_X0 + 12)) ||
                         ((xx >= CARD_X1 - 12) && (xx < CARD_X1 - 10)) ||
                         ((yy >= CARD_Y0 + 10) && (yy < CARD_Y0 + 12)) ||
                         ((yy >= CARD_Y1 - 12) && (yy < CARD_Y1 - 10)))
                    expv = r[7] ? 24'hFFC24D : 24'h6B4A10;
                else
                    expv = WN_BG;
            end else begin
                expv = exp_wash(r);
            end
        end
    endtask

    task sweep_warn(input [7:0] r, input [8*24-1:0] tag);
        integer xx, yy, nerr;
        begin
            nerr = 0;
            for (yy = 0; yy < V; yy = yy + 1) begin
                for (xx = 0; xx < H; xx = xx + 1) begin
                    calc_exp(xx, yy, r);
                    if (fb[yy*H + xx] !== expv) begin
                        if (nerr < 8)
                            $display("FAIL %0s @(%0d,%0d) got %h exp %h",
                                     tag, xx, yy, fb[yy*H + xx], expv);
                        nerr = nerr + 1;
                    end
                end
            end
            if (nerr != 0) begin
                $display("FAIL %0s : %0d pixels", tag, nerr);
                errs = errs + 1;
            end else
                $display("PASS %0s", tag);
        end
    endtask

    task step(input integer xx, input integer yy);
        begin
            de <= 1'b1; hs <= 1'b1; vs <= 1'b0; rgb <= BG;
            @(posedge clk);
            if (ode && dlyx >= 0) fb[dlyy*H + dlyx] = orgb;
            dlyx = xx; dlyy = yy;
        end
    endtask

    task scan_frame;
        integer yl, xl;
        begin
            vs <= 1'b1; de <= 1'b0;
            repeat (2) @(posedge clk);
            vs <= 1'b0;
            @(posedge clk);
            dlyx = -1; dlyy = -1;
            for (yl = 0; yl < V; yl = yl + 1) begin
                for (xl = 0; xl < H; xl = xl + 1)
                    step(xl, yl);
                de <= 1'b0; hs <= 1'b0;
                @(posedge clk);
                if (ode && dlyx >= 0) fb[dlyy*H + dlyx] = orgb;
                @(posedge clk);
            end
        end
    endtask

    task pulse_vs;
        begin
            vs <= 1'b1;
            @(posedge clk);
            @(posedge clk);
            vs <= 1'b0;
            @(posedge clk);
        end
    endtask

    task chk_px(input integer xx, input integer yy, input [23:0] exp,
                input [8*24-1:0] tag);
        reg [23:0] got;
        begin
            got = fb[yy*H + xx];
            if (got !== exp) begin
                if (errs < 16)
                    $display("FAIL %0s @(%0d,%0d) got %h exp %h",
                             tag, xx, yy, got, exp);
                errs = errs + 1;
            end
        end
    endtask

    initial begin
        repeat (5) @(posedge clk);
        rst = 0;
        repeat (5) @(posedge clk);

        // ---------- 帧A：关闭告警，任何位置都必须完全透明 ----------
        warn_en = 0; disp_valid = 1;
        force dut.br_lvl = 8'd200;
        force dut.br_up  = 1'b1;
        scan_frame;
        chk_px(320, 240, BG, "off-center");
        chk_px(320, 60,  BG, "off-band");
        chk_px(90, 200,  BG, "off-card");
        chk_px(320, 190, BG, "off-title");

        // ---------- 帧B：开启告警，呼吸值 0（暗相位），逐像素对照全屏 ----------
        warn_en = 1;
        force dut.br_lvl = 8'd0;
        scan_frame;
        sweep_warn(8'd0, "warn-dim");
        chk_px(320, 20,  exp_band(320, 20, 8'd0), "dim-band");
        chk_px(320, 400, exp_wash(8'd0), "dim-wash");
        chk_px(90, 200,  24'h8C0F0F, "dim-card-frame");
        chk_px(98, 200,  24'h6B4A10, "dim-card-inner");
        chk_px(320, 310, WN_BG,      "dim-card-bg");
        chk_px(100, 300, WN_BG,      "dim-card-bg2");

        // ---------- 帧C：呼吸值 200（亮相位）----------
        force dut.br_lvl = 8'd200;
        scan_frame;
        sweep_warn(8'd200, "warn-lit");
        chk_px(90, 200,  24'hFF2A2A, "lit-card-frame");
        chk_px(98, 200,  24'hFFC24D, "lit-card-inner");
        chk_px(320, 20,  exp_band(320, 20, 8'd200), "lit-band");
        chk_px(320, 400, exp_wash(8'd200), "lit-wash");

        // ---------- 帧D：启动面板期间，告警仍全屏覆盖（最高优先级）----------
        disp_valid = 0;
        scan_frame;
        sweep_warn(8'd200, "warn-over-boot");

        // ---------- 帧E：再次关闭，恢复透明 ----------
        disp_valid = 1; warn_en = 0;
        scan_frame;
        chk_px(320, 240, BG, "off2-center");
        chk_px(320, 60,  BG, "off2-band");
        chk_px(90, 200,  BG, "off2-card");

        // ---------- 呼吸三角波折返 ----------
        release dut.br_lvl;
        release dut.br_up;
        dut.br_lvl = 8'd252; dut.br_up = 1'b1;
        pulse_vs;
        if (dut.br_lvl !== 8'd255 || dut.br_up !== 1'b0) begin
            $display("FAIL breath up: lvl=%0d up=%b", dut.br_lvl, dut.br_up);
            errs = errs + 1;
        end
        pulse_vs;
        if (dut.br_lvl !== 8'd251 || dut.br_up !== 1'b0) begin
            $display("FAIL breath down: lvl=%0d up=%b", dut.br_lvl, dut.br_up);
            errs = errs + 1;
        end
        dut.br_lvl = 8'd0; dut.br_up = 1'b0;
        pulse_vs;
        if (dut.br_lvl !== 8'd0 || dut.br_up !== 1'b1) begin
            $display("FAIL breath floor: lvl=%0d up=%b", dut.br_lvl, dut.br_up);
            errs = errs + 1;
        end
        pulse_vs;
        if (dut.br_lvl !== 8'd4 || dut.br_up !== 1'b1) begin
            $display("FAIL breath rise: lvl=%0d up=%b", dut.br_lvl, dut.br_up);
            errs = errs + 1;
        end

        if (errs == 0) $display("TB_WARNING_OSD PASS");
        else           $display("TB_WARNING_OSD FAIL %0d", errs);
        $finish;
    end
endmodule
