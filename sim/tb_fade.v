`timescale 1ns/1ps
// 验证 fade_ctrl：淡出→切图→淡入 状态机 + alpha 增益
module tb_fade;
    reg clk = 0, rst = 0;
    reg vs = 0;
    reg [23:0] rgb;
    reg req = 0;
    wire swap;
    wire [23:0] o_rgb;

    fade_ctrl dut(.i_clk(clk), .i_rst(rst), .i_vs(vs), .i_rgb(rgb), .i_req(req), .o_swap(swap), .o_rgb(o_rgb));

    always #20 clk = ~clk;

    // 帧边界：每 1000 拍 vs 上升沿一次（vcnt 0..9 低，之后高）
    reg [9:0] vcnt = 0;
    always @(posedge clk) begin
        if (rst) vcnt <= 0;
        else if (vcnt == 999) vcnt <= 0;
        else vcnt <= vcnt + 1;
    end
    always @(*) vs = (vcnt < 10);

    integer i;
    initial begin
        rgb = 24'h808080;   // 灰度 128
        rst = 1; #200 rst = 0;
        repeat (3) @(posedge clk);
        $display("t=%0t init: alpha=%0d state=%0d o_rgb=%h", $time, dut.alpha, dut.state, o_rgb);

        // 第一次翻转 req → 淡出
        req = ~req;
        repeat (18 * 1000) @(posedge clk);
        $display("t=%0t after fade-out: alpha=%0d state=%0d swap=%0d o_rgb=%h", $time, dut.alpha, dut.state, swap, o_rgb);

        // 第二次翻转 req → 淡入
        req = ~req;
        repeat (18 * 1000) @(posedge clk);
        $display("t=%0t after fade-in: alpha=%0d state=%0d swap=%0d o_rgb=%h", $time, dut.alpha, dut.state, swap, o_rgb);

        $finish;
    end
endmodule
