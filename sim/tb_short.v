`timescale 1ns/1ps
// 验证短标语：content_chars = max(len, 31)，短标语只显示自身不重复
module tb_short;
    reg clk = 0, rst = 0;
    reg hs, vs, de;
    reg [23:0] rgb;
    reg [1:0] mode = 0;
    reg [2:0] bright = 4, contrast = 4;
    reg [255:0] slogan = 256'd0;
    reg [5:0] slogan_len = 5;   // "Hello"
    reg slogan_dir = 0, slogan_update = 0, slogan_scroll = 0;
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

    initial begin
        rst = 1; #200 rst = 0;
        slogan_update = 1; repeat(5) @(posedge clk); slogan_update = 0;   // 锁存 len=5
        repeat(2) @(posedge clk);
        $display("slogan_len=%0d content_chars=%0d (len期望5, content期望31)", dut.slogan_len, dut.content_chars);
        // scroll_pos=0 时，窗口前 5 字符 "Hello"，后面空白
        $display("scroll_pos=%0d (期望0)", dut.scroll_pos);
        $finish;
    end
endmodule
