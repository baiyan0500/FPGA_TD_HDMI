`timescale 1ns/1ps
// 验证 osd_layer：
//   1) 底栏 B/C 百分比文本（逐像素对照字库）
//   2) 全宽透明频谱：柱体着色、柱间/柱外透出底层画面（无黑框）
//   3) 音量条三态（viz_mode）
//   4) 启动面板只在首图提交前出现；启动期间频谱被屏蔽
//
// 说明：osd_layer 的 y 计数器在行末（de 下降沿）进位，渲染行号与输入行号一致。
module tb_osd_layer;
    localparam integer H = 640, V = 480;

    reg clk = 0, rst = 1;
    reg hs = 0, vs = 0, de = 0;
    reg [23:0] rgb = 24'h123456;

    reg [1:0]  mode = 2'd0;
    reg [2:0]  bright = 3'd0, contrast = 3'd2;
    reg [255:0] slogan = 256'd0;
    reg [5:0]  slen = 6'd18;
    reg        sdir = 0, supd = 0, sscroll = 0;
    reg [1:0]  viz = 2'd0;
    reg        spec_en = 0;
    reg [7:0]  alevel = 8'd128;
    reg [191:0] spec_lv = 192'd0;
    reg        dm_en = 0;
    reg [191:0] dm_text = 192'd0;
    reg [4:0]  dm_len = 5'd0;
    reg [3:0]  dm_color = 4'd0;
    reg        dm_tgl = 0;
    reg        rm_en = 0;
    reg        video_on = 0, vid_ftgl = 0;
    reg        disp_valid = 0;
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
        .i_mode(mode), .i_bright(bright), .i_contrast(contrast), .i_sw(4'b0011),
        .i_slogan(slogan), .i_slogan_len(slen), .i_slogan_dir(sdir),
        .i_slogan_update(supd), .i_slogan_scroll(sscroll),
        .i_viz_mode(viz), .i_spec_en(spec_en), .i_audio_level(alevel),
        .i_spec_level(spec_lv),
        .i_dm_en(dm_en), .i_dm_text(dm_text), .i_dm_len(dm_len),
        .i_dm_color(dm_color), .i_dm_tgl(dm_tgl), .o_dm_ack(dm_ack),
        .i_rm_en(rm_en), .i_video_on(video_on), .i_vid_ftgl(vid_ftgl),
        .i_display_valid(disp_valid), .i_sd_init_done(sd_done),
        .i_scan_done(scan_done), .i_img_count(img_cnt), .i_wav_found(wav_fnd),
        .i_src_w_bcd(src_w), .i_src_h_bcd(src_h), .i_src_tgl(src_tgl),
        .i_auto_play(auto_play),
        .i_warn_en(1'b0),
        .o_hs(ohs), .o_vs(ovs), .o_de(ode), .o_rgb(orgb)
    );

    // TB 侧字库：用于复算底栏文本像素
    reg [6:0] fch = 7'h20;
    reg [2:0] frow = 3'd0;
    wire [7:0] fglyph;
    font8x8 u_font (.i_char(fch), .i_row(frow), .o_row(fglyph));

    always #20 clk = ~clk;

    integer errs = 0;
    integer ix, iy;
    integer dlyx = -1, dlyy = -1;
    integer y_eff;
    integer spec_lvl = 63;   // 当前帧频谱柱高（每帧 vsync 衰减 1）
    reg     boot;            // 当前帧是否启动阶段

    localparam [23:0] BG = 24'h123456;

    // ---------------- 期望值 ----------------
    function [6:0] bot_exp(input integer idx);
        integer pb, pc;
        begin
            pb = (bright + 1) * 20;
            pc = (contrast + 1) * 20;
            // 左段 0..17：源尺寸（复位值 640x480 视为 native → "640x480"）
            case (idx)
                0: bot_exp = "6";
                1: bot_exp = "4";
                2: bot_exp = "0";
                3: bot_exp = "x";
                4: bot_exp = "4";
                5: bot_exp = "8";
                6: bot_exp = "0";
                // 右段：18..19 FPS，20 'F'，21 ' '，22 'M'，23 ':'，24 模式，
                //       25 ' '，26 'B'，27..30 亮度百分比，31 ' '，
                //       32 'C'，33..36 对比度百分比
                18: bot_exp = "6";
                19: bot_exp = "0";
                20: bot_exp = "F";
                22: bot_exp = "M";
                23: bot_exp = ":";
                24: bot_exp = 7'h30 + mode;
                26: bot_exp = "B";
                27: bot_exp = (bright == 3'd4) ? "1" : 7'h20;
                28: bot_exp = (bright == 3'd4) ? "0" : (7'h30 + pb / 10);
                29: bot_exp = "0";
                30: bot_exp = "%";
                32: bot_exp = "C";
                33: bot_exp = (contrast == 3'd4) ? "1" : 7'h20;
                34: bot_exp = (contrast == 3'd4) ? "0" : (7'h30 + pc / 10);
                35: bot_exp = "0";
                36: bot_exp = "%";
                default: bot_exp = 7'h20;
            endcase
        end
    endfunction

    function [23:0] spec_col(input integer ye);
        integer sy;
        begin
            sy = 456 - ye;
            spec_col = (sy >= 192) ? 24'hFF3860 :
                       (sy >= 128) ? 24'hFFC93C :
                       (sy >= 64)  ? 24'h5CFF7A : 24'h28C8FF;
        end
    endfunction

    task check_px(input integer xx, input integer yi, input [23:0] got);
        integer idx, colp, rowp, av_len, sy;
        reg [23:0] expv;
        reg        specified;
        begin
            y_eff   = yi;
            specified = 0;
            expv    = BG;

            // ---- 底栏：整行黑底 + 文本 ----
            if (y_eff >= 456) begin
                specified = 1;
                if (y_eff >= 460 && y_eff < 476 && xx >= 8 && xx < 8 + 37 * 16) begin
                    idx  = (xx - 8) / 16;
                    colp = ((xx - 8) % 16) / 2;
                    rowp = (y_eff - 460) / 2;
                    fch  = bot_exp(idx);
                    frow = rowp;
                    #1;
                    expv = fglyph[7-colp] ? 24'hFFFFFF : 24'h000000;
                end else
                    expv = 24'h000000;
            end
            // ---- 音量条（viz != 0）----
            else if (!boot && (viz != 2'd0) && y_eff >= 216 && y_eff < 240 &&
                     xx >= 160 && xx < 480) begin
                specified = 1;
                av_len = (alevel * 320) / 256;
                if (xx < 160 + av_len)
                    expv = (xx >= 160 + av_len / 2) ? 24'hFFD166 : 24'h39D98A;
                else
                    expv = 24'h141A24;
            end
            // ---- 频谱（全宽，柱间透出底层；含峰值白线）----
            else if (!boot && (spec_en || viz == 2'd2) &&
                     y_eff >= 204 && y_eff < 456 &&
                     (((xx * 13) & 255) < 200)) begin
                sy = 456 - y_eff;
                if (sy <= spec_lvl * 4) begin
                    specified = 1;
                    expv = spec_col(y_eff);
                end else if (sy == 63 * 4 || sy == 63 * 4 + 1) begin
                    specified = 1;      // 峰值保持线（满幅 63）
                    expv = 24'hFFFFFF;
                end
            end
            // ---- 启动面板：左 8..408 / 右 416..624，y 80..392 ----
            else if (boot) begin
                if (y_eff >= 80 && y_eff < 392 &&
                    ((xx >= 8 && xx < 408) || (xx >= 416 && xx < 624))) begin
                    specified = 0;      // 面板色彩多样，只做"非底图"粗检
                    if (got === BG) begin
                        if (errs < 10)
                            $display("FAIL boot panel did not paint (%0d,%0d)",
                                     xx, y_eff);
                        errs = errs + 1;
                    end
                end
            end

            if (specified && got !== expv) begin
                if (errs < 12)
                    $display("FAIL px(%0d,%0d)=%h exp %h (boot=%b viz=%0d spec=%b) dut(%0d,%0d) lvl=%0d sy=%0d",
                             xx, y_eff, got, expv, boot, viz, spec_en, dut.x, dut.y, dut.bar_lvl[0], 456-y_eff);
                errs = errs + 1;
            end
        end
    endtask

    task step(input integer xx, input integer yy);
        begin
            de <= 1'b1; hs <= 1'b1; vs <= 1'b0; rgb <= BG;
            @(posedge clk);
            if (ode) begin
                if (dlyx >= 0) check_px(dlyx, dlyy, orgb);
            end
            dlyx = xx; dlyy = yy;
        end
    endtask

    task scan_frame;
        integer yl, xl;
        begin
            // 帧同步：vs 脉宽 2 拍
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
                if (ode && dlyx >= 0) check_px(dlyx, dlyy, orgb);
                @(posedge clk);
            end
        end
    endtask

    initial begin
        repeat (5) @(posedge clk);
        rst = 0;
        repeat (5) @(posedge clk);

        // 频谱：32 段全满
        spec_lv = {32{6'd63}};
        bright  = 3'd0;      // 20%
        contrast = 3'd2;     // 60%

        // ---------- 帧1：启动阶段，频谱使能被 boot_mode 屏蔽 ----------
        boot = 1; disp_valid = 0; spec_en = 1; viz = 2'd0;
        spec_lvl = 63;
        scan_frame;

        // ---------- 帧2：首图已出，频谱 + 音量条 ----------
        spec_lvl = 62;      // 满幅且不再上升，vsync 后衰减一档
        boot = 0; disp_valid = 1; spec_en = 1; viz = 2'd1;
        scan_frame;

        // ---------- 帧3：三态关闭（viz=0, spec_en=0）----------
        boot = 0; disp_valid = 1; spec_en = 0; viz = 2'd0;
        scan_frame;

        if (errs == 0) $display("TB_OSD PASS");
        else           $display("TB_OSD FAIL %0d", errs);
        $finish;
    end
endmodule
