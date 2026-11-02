`timescale 1ns/1ps
// tb_warn_dump — 把 SW4 告警层渲染成两帧 PPM（暗相位/亮相位），用于人工核对排版美化。
// 底图用一张渐变彩条模拟视频画面，便于确认"整屏压暗染红"的效果。
module tb_warn_dump;
    localparam integer H = 640, V = 480;

    reg clk = 0, rst = 1;
    reg hs = 0, vs = 0, de = 0;
    reg [23:0] rgb = 24'h000000;
    reg        warn_en = 1;

    reg [1:0]  mode = 2'd0;
    reg [2:0]  bright = 3'd4, contrast = 3'd4;
    reg [3:0]  sw = 4'b1000;
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
    reg        video_on = 1, vid_ftgl = 0, vok = 1;
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

    always #20 clk = ~clk;

    // 模拟视频底图：彩条 + 垂直渐变
    function [23:0] bg_px(input integer xx, input integer yy);
        reg [7:0] bar;
        begin
            bar = xx / 80;
            case (bar[2:0])
                3'd0: bg_px = {8'd200, 8'd200 - yy[7:1], 8'd60};
                3'd1: bg_px = {8'd60,  8'd200, 8'd200 - yy[7:1]};
                3'd2: bg_px = {8'd200, 8'd60, 8'd200 - yy[7:1]};
                3'd3: bg_px = {8'd60, 8'd200 - yy[7:1], 8'd60};
                3'd4: bg_px = {8'd200 - yy[7:1], 8'd60, 8'd200};
                3'd5: bg_px = {8'd200, 8'd200, 8'd200 - yy[7:1]};
                3'd6: bg_px = {8'd30, 8'd100, 8'd200 - yy[7:1]};
                default: bg_px = {8'd200, 8'd120, 8'd40};
            endcase
        end
    endfunction

    // 输出比输入晚一拍，按"上一拍坐标"落盘才不会每行少一个像素
    reg [23:0] fb [0:V*H-1];
    integer fh, yl, xl, dlyx = -1, dlyy = -1;
    task scan_frame(input [8*40-1:0] fname);
        begin
            vs <= 1'b1; de <= 1'b0;
            repeat (2) @(posedge clk);
            vs <= 1'b0;
            @(posedge clk);
            dlyx = -1; dlyy = -1;
            for (yl = 0; yl < V; yl = yl + 1) begin
                for (xl = 0; xl < H; xl = xl + 1) begin
                    de <= 1'b1; hs <= 1'b1; vs <= 1'b0; rgb <= bg_px(xl, yl);
                    @(posedge clk);
                    if (ode && dlyx >= 0) fb[dlyy*H + dlyx] = orgb;
                    dlyx = xl; dlyy = yl;
                end
                de <= 1'b0; hs <= 1'b0;
                @(posedge clk);
                if (ode && dlyx >= 0) fb[dlyy*H + dlyx] = orgb;
                @(posedge clk);
            end
            fh = $fopen(fname, "wb");
            $fwrite(fh, "P6\n%0d %0d\n255\n", H, V);
            for (yl = 0; yl < V; yl = yl + 1)
                for (xl = 0; xl < H; xl = xl + 1)
                    $fwrite(fh, "%c%c%c", fb[yl*H+xl][23:16],
                            fb[yl*H+xl][15:8], fb[yl*H+xl][7:0]);
            $fclose(fh);
        end
    endtask

    initial begin
        repeat (5) @(posedge clk);
        rst = 0;
        repeat (5) @(posedge clk);

        force dut.br_lvl = 8'd0;
        force dut.br_up  = 1'b1;
        scan_frame("osd_warn_dim.ppm");

        force dut.br_lvl = 8'd200;
        scan_frame("osd_warn_lit.ppm");

        force dut.br_lvl = 8'd120;
        scan_frame("osd_warn_mid.ppm");

        $display("WARN dump done");
        $finish;
    end
endmodule
