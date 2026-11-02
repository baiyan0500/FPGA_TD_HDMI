`timescale 1ns/1ps
// tb_osd_dump — 把启动菜单渲染成一帧 PPM，用于人工核对右侧开关/按键说明排版。
module tb_osd_dump;
    localparam integer H = 640, V = 480;

    reg clk = 0, rst = 1;
    reg hs = 0, vs = 0, de = 0;
    reg [23:0] rgb = 24'h101010;

    reg [1:0]  mode = 2'd0;
    reg [2:0]  bright = 3'd0, contrast = 3'd2;
    reg [255:0] slogan = 256'd0;
    reg [5:0]  slen = 6'd0;
    reg        sdir = 0, supd = 0, sscroll = 0;
    reg [1:0]  viz = 2'd0;
    reg        spec_en = 0;
    reg [7:0]  alevel = 8'd0;
    reg [191:0] spec_lv = 192'd0;
    reg        dm_en = 0;
    reg [191:0] dm_text = 192'd0;
    reg [4:0]  dm_len = 5'd0;
    reg [3:0]  dm_color = 4'd0;
    reg        dm_tgl = 0;
    reg        rm_en = 0;
    reg        video_on = 0, vid_ftgl = 0;
    reg        disp_valid = 0;          // 0 = 启动阶段（菜单常显）
    reg        sd_done = 1, scan_done = 1;
    reg [4:0]  img_cnt = 5'd3;
    reg        wav_fnd = 1;
    reg [15:0] src_w = 16'h0640, src_h = 16'h0480;
    reg        src_tgl = 0;
    reg        auto_play = 0;
    reg [3:0]  sw = 4'b0001;            // 只有 SW1 在右：菜单应显示 SW1 ON、LT:1

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
        .i_rm_en(rm_en), .i_video_on(video_on), .i_vid_ftgl(vid_ftgl),
        .i_display_valid(disp_valid), .i_sd_init_done(sd_done),
        .i_scan_done(scan_done), .i_img_count(img_cnt), .i_wav_found(wav_fnd),
        .i_src_w_bcd(src_w), .i_src_h_bcd(src_h), .i_src_tgl(src_tgl),
        .i_auto_play(auto_play),
        .i_warn_en(1'b0),
        .o_hs(ohs), .o_vs(ovs), .o_de(ode), .o_rgb(orgb)
    );

    always #20 clk = ~clk;

    integer fh, yl, xl;
    task scan_frame;
        begin
            vs <= 1'b1; de <= 1'b0;
            repeat (2) @(posedge clk);
            vs <= 1'b0;
            @(posedge clk);
            for (yl = 0; yl < V; yl = yl + 1) begin
                for (xl = 0; xl < H; xl = xl + 1) begin
                    de <= 1'b1; hs <= 1'b1; vs <= 1'b0;
                    @(posedge clk);
                    if (ode) $fwrite(fh, "%c%c%c", orgb[23:16], orgb[15:8], orgb[7:0]);
                end
                de <= 1'b0; hs <= 1'b0;
                repeat (2) @(posedge clk);
            end
        end
    endtask

    initial begin
        fh = $fopen("osd_menu.ppm", "wb");
        $fwrite(fh, "P6\n%0d %0d\n255\n", H, V);
        repeat (5) @(posedge clk);
        rst = 0;
        repeat (5) @(posedge clk);
        scan_frame;               // 启动菜单
        $fclose(fh);
        $display("OSD dump done -> osd_menu.ppm");
        $finish;
    end
endmodule
