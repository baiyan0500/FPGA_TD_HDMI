`timescale 1ns/1ps
// 验证 osd_layer：启动面板（标题/跑马灯/按键说明）+ 原上下栏 + 32 柱频谱
module tb_osd;
    reg clk = 0, rst = 0;
    reg hs, vs, de;
    reg [23:0] rgb;
    reg [1:0] mode = 2'd0;
    reg [2:0] bright = 3'd4, contrast = 3'd4;
    reg [255:0] slogan = 256'd0;
    reg [5:0] slogan_len = 6'd18;
    reg slogan_dir = 0, slogan_update = 0, slogan_scroll = 0;
    reg i_audio_viz = 0, i_spectrum_en = 0;
    reg [191:0] i_spec_level = {32{6'd40}};
    reg [7:0] i_audio_level = 8'd128;
    reg display_valid = 0;
    reg sd_init_done = 1, scan_done = 1, auto_play = 1;
    reg [4:0] img_count = 5'd3;
    reg [15:0] src_w_bcd = 16'h0640, src_h_bcd = 16'h0480;
    reg        src_tgl = 0;
    wire o_hs, o_vs, o_de;
    wire [23:0] o_rgb;

    integer title_hit = 0, ts_hit = 0, bot_hit = 0;
    integer boot_title_hit = 0, boot_guide_hit = 0, boot_bg_hit = 0;
    integer mq_hit = 0, boot_msg_hit = 0, spec_hit = 0, av_hit = 0;
    integer normal_passthru = 0;
    integer boot_title_snap = 0;
    integer title_col_bad = 0, gd_col_bad = 0, st_col_bad = 0, char_bad = 0;
    integer src_tag_bad = 0, src_tag_snap = 0;

    osd_layer dut(
        .i_clk(clk), .i_rst(rst), .i_hs(hs), .i_vs(vs), .i_de(de), .i_rgb(rgb),
        .i_mode(mode), .i_bright(bright), .i_contrast(contrast),
        .i_slogan(slogan), .i_slogan_len(slogan_len),
        .i_slogan_dir(slogan_dir), .i_slogan_update(slogan_update),
        .i_slogan_scroll(slogan_scroll),
        .i_audio_viz(i_audio_viz), .i_audio_level(i_audio_level),
        .i_spectrum_en(i_spectrum_en), .i_spec_level(i_spec_level),
        .i_display_valid(display_valid), .i_sd_init_done(sd_init_done),
        .i_scan_done(scan_done), .i_img_count(img_count),
        .i_src_w_bcd(src_w_bcd), .i_src_h_bcd(src_h_bcd), .i_src_tgl(src_tgl),
        .i_auto_play(auto_play),
        .o_hs(o_hs), .o_vs(o_vs), .o_de(o_de), .o_rgb(o_rgb)
    );

    always #20 clk = ~clk;

    reg [11:0] hcnt = 0, vcnt = 0;
    always @(posedge clk) begin
        if (rst) begin hcnt <= 0; vcnt <= 0; end
        else if (hcnt == 799) begin hcnt <= 0; vcnt <= (vcnt == 524) ? 0 : vcnt + 1; end
        else hcnt <= hcnt + 1;
    end
    always @(*) begin
        de = (hcnt < 640);
        vs = (vcnt >= 2);
        hs = (hcnt >= 96);
    end

    // 采样点比 x/y 晚一拍，区域边界留余量
    always @(posedge clk) begin
        if (!rst && o_de) begin
            // 原上下栏
            if (o_rgb == 24'hFFFFFF) begin
                if (dut.x >= 6   && dut.x < 300 && dut.y >= 2   && dut.y < 22)  title_hit <= title_hit + 1;
                if (dut.x >= 502 && dut.x < 634 && dut.y >= 2   && dut.y < 22)  ts_hit    <= ts_hit + 1;
                if (dut.x >= 6   && dut.x < 218 && dut.y >= 458 && dut.y < 478) bot_hit   <= bot_hit + 1;
                if (dut.x >= 62  && dut.x < 354 && dut.y >= 222 && dut.y < 242) boot_msg_hit <= boot_msg_hit + 1;
            end
            // 启动左面板标题（4x 青色）
            if (o_rgb == 24'h9BE8FF &&
                dut.x >= 14 && dut.x < 402 && dut.y >= 118 && dut.y < 194)
                boot_title_hit <= boot_title_hit + 1;
            // 启动左面板深色填充
            if (o_rgb == 24'h05080F &&
                dut.x >= 12 && dut.x < 404 && dut.y >= 84 && dut.y < 388)
                boot_bg_hit <= boot_bg_hit + 1;
            // 右面板按键说明（1x）
            if (o_rgb == 24'hB8C6DC &&
                dut.x >= 430 && dut.x < 618 && dut.y >= 132 && dut.y < 280)
                boot_guide_hit <= boot_guide_hit + 1;
            // 左面板跑马灯边框
            if ((o_rgb == 24'h00E5FF || o_rgb == 24'h33FF99 ||
                 o_rgb == 24'hFFD166 || o_rgb == 24'hFF5CA8) &&
                (((dut.x >= 6  && dut.x < 13)  || (dut.x >= 403 && dut.x < 410)) &&
                 (dut.y >= 78 && dut.y < 394) ||
                 ((dut.y >= 78 && dut.y < 85)  || (dut.y >= 387 && dut.y < 394)) &&
                 (dut.x >= 6  && dut.x < 410)))
                mq_hit <= mq_hit + 1;
            // 32 柱频谱（启动阶段关闭）
            if ((o_rgb == 24'hFF3860 || o_rgb == 24'hFFC93C ||
                 o_rgb == 24'h5CFF7A || o_rgb == 24'h28C8FF) &&
                dut.x >= 64 && dut.x < 576 && dut.y >= 324 && dut.y < 452)
                spec_hit <= spec_hit + 1;
            // VU 电平条
            if ((o_rgb == 24'h39D98A || o_rgb == 24'hFFD166) &&
                dut.x >= 160 && dut.x < 480 && dut.y >= 214 && dut.y < 242)
                av_hit <= av_hit + 1;
            // 正常阶段：启动面板消失，左中区域应透传图像
            if (o_rgb == 24'h0000FF &&
                dut.x >= 30 && dut.x < 400 && dut.y >= 100 && dut.y < 190)
                normal_passthru <= normal_passthru + 1;

            // 字形列映射：必须等于字内像素列，而非字符索引
            if (dut.in_title &&
                (dut.title_col !== (((dut.x - 11'd8) & 11'd15) >> 1)))
                title_col_bad <= title_col_bad + 1;
            if (dut.in_gd &&
                (dut.boot_col !== ((dut.x - 11'd432) & 11'd7)))
                gd_col_bad <= gd_col_bad + 1;
            if (dut.in_st &&
                (dut.boot_col !== ((dut.x - 11'd456) & 11'd7)))
                st_col_bad <= st_col_bad + 1;

            // 关键字符内容抽查
            if (dut.x == 11'd8   && dut.y == 11'd8   && dut.title_char !== 7'h45) char_bad <= char_bad + 1; // 'E'
            if (!display_valid &&
                dut.x == 11'd432 && dut.y == 11'd134 && dut.boot_char  !== 7'h53) char_bad <= char_bad + 1; // 'S'
            if (!display_valid &&
                dut.x == 11'd456 && dut.y == 11'd314 && dut.boot_char  !== 7'h4D) char_bad <= char_bad + 1; // 'M'

            // 底栏源尺寸标注：非 640x480 源应显示 "WWWWxHHHH>640x480"
            if (dut.x == 11'd8 && dut.y == 11'd462) begin
                if (dut.src_w_bcd_q == 16'h1024 && dut.src_h_bcd_q == 16'h0577) begin
                    if (dut.bot_char !== 7'h31) src_tag_bad <= src_tag_bad + 1;  // '1'
                end else if (dut.src_w_bcd_q == 16'h0640 && dut.src_h_bcd_q == 16'h0480) begin
                    if (dut.bot_char !== 7'h36) src_tag_bad <= src_tag_bad + 1;  // '6'
                end
            end
            if (dut.x == 11'd152 && dut.y == 11'd462 &&
                dut.src_w_bcd_q == 16'h1024 && dut.bot_char !== 7'h3E)
                src_tag_bad <= src_tag_bad + 1;   // '>'
        end
    end

    initial begin
        rgb = 24'h0000FF;
        rst = 1; #200 rst = 0;
        // 阶段1：首图未提交 → 启动面板 + 原上下栏
        repeat (525 * 800) @(posedge clk);
        boot_title_snap = boot_title_hit;
        $display("BOOT: title=%0d guide=%0d bg=%0d mq=%0d msg=%0d ts=%0d bot=%0d spec=%0d",
                 boot_title_hit, boot_guide_hit, boot_bg_hit, mq_hit,
                 boot_msg_hit, ts_hit, bot_hit, spec_hit);
        $display("MAPPING: title_col_bad=%0d gd_col_bad=%0d st_col_bad=%0d char_bad=%0d",
                 title_col_bad, gd_col_bad, st_col_bad, char_bad);
        if (boot_title_hit > 0 && boot_guide_hit > 0 && boot_bg_hit > 0 &&
            mq_hit > 0 && boot_msg_hit > 0 && ts_hit > 0 && bot_hit > 0 &&
            spec_hit == 0 && title_col_bad == 0 && gd_col_bad == 0 &&
            st_col_bad == 0 && char_bad == 0)
            $display(">>> OK: boot panels rendered, bars preserved, spectrum hidden");
        else
            $display(">>> BUG: boot stage incomplete");

        display_valid = 1;
        i_spectrum_en = 1;
        i_audio_viz = 1;
        // 底栏标注：模拟提交一张 1024x577 的高分辨率源图
        src_w_bcd = 16'h1024;
        src_h_bcd = 16'h0577;
        src_tgl   = 1;

        // 阶段2：正常显示 → 启动面板消失，上下栏/频谱/VU 恢复
        repeat (3 * 525 * 800) @(posedge clk);
        $display("NORMAL: title=%0d ts=%0d bot=%0d spec=%0d av=%0d pass=%0d boot_title_now=%0d",
                 title_hit, ts_hit, bot_hit, spec_hit, av_hit,
                 normal_passthru, boot_title_hit);
        $display("SRCTAG: bad=%0d (w=%04x h=%04x)", src_tag_bad, dut.src_w_bcd_q, dut.src_h_bcd_q);
        if (title_hit > 0 && ts_hit > 0 && bot_hit > 0 &&
            spec_hit > 0 && av_hit > 0 && normal_passthru > 0 &&
            boot_title_hit == boot_title_snap &&
            title_col_bad == 0 && gd_col_bad == 0 &&
            st_col_bad == 0 && char_bad == 0 && src_tag_bad == 0)
            $display(">>> OK: normal OSD restored");
        else
            $display(">>> BUG: normal OSD incomplete");
        $finish;
    end
endmodule
