`timescale 1ns/1ps
// 验证 osd_layer 平滑滚动：scroll_pos 逐像素递增/递减（不是逐字符跳）
module tb_scroll;
    reg clk = 0, rst = 0;
    reg hs, vs, de;
    reg [23:0] rgb;
    reg [1:0] mode = 0;
    reg [2:0] bright = 3'd4, contrast = 3'd4;
    reg [255:0] slogan = 256'd0;
    reg [5:0] slogan_len = 6'd40;
    reg slogan_dir = 0, slogan_update = 0, slogan_scroll = 1;
    wire o_hs, o_vs, o_de;
    wire [23:0] o_rgb;

    osd_layer dut(
        .i_clk(clk), .i_rst(rst), .i_hs(hs), .i_vs(vs), .i_de(de), .i_rgb(rgb),
        .i_mode(mode), .i_bright(bright), .i_contrast(contrast),
        .i_slogan(slogan), .i_slogan_len(slogan_len),
        .i_slogan_dir(slogan_dir), .i_slogan_update(slogan_update),
        .i_slogan_scroll(slogan_scroll),
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
        de = (hcnt < 640); vs = (vcnt >= 2); hs = (hcnt >= 96);
    end

    initial begin
        rgb = 24'h0000FF;
        rst = 1; #200 rst = 0; repeat(3) @(posedge clk);
        slogan_update = 1; repeat(5) @(posedge clk);   // 触发锁存 slogan_len=40, scroll_en=1

        $display("init scroll_pos=%0d scroll_en=%0d", dut.scroll_pos, dut.scroll_en);
        repeat (2 * 525 * 800) @(posedge clk);   // 2 帧
        $display("after 2 frames (left): scroll_pos=%0d (期望 2)", dut.scroll_pos);
        repeat (3 * 525 * 800) @(posedge clk);   // 3 帧
        $display("after 5 frames (left): scroll_pos=%0d (期望 5)", dut.scroll_pos);

        // 改方向 right
        slogan_dir = 1; slogan_update = 0;
        repeat (2 * 525 * 800) @(posedge clk);
        $display("after right 2 frames: scroll_pos=%0d (应递减)", dut.scroll_pos);

        $finish;
    end
endmodule
