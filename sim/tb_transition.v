`timescale 1ns/1ps
// 验证 transition_ctrl：fade 淡出淡入 + wipe 遮罩推进
`define FRAME (525*800)

module tb_transition;
    reg clk = 0, rst = 0;
    reg vs = 0, de = 0;
    reg [1:0] mode = 0;
    reg [23:0] rgb = 24'h808080;
    reg req = 0;
    wire swap;
    wire [23:0] o_rgb;

    transition_ctrl dut(.i_clk(clk), .i_rst(rst), .i_vs(vs), .i_de(de), .i_mode(mode),
                        .i_rgb(rgb), .i_req(req), .o_swap(swap), .o_rgb(o_rgb));

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
    end

    initial begin
        rgb = 24'h808080;
        rst = 1; #200 rst = 0; repeat(3) @(posedge clk);

        // ---- fade 模式 ----
        mode = 2'd0;
        req = ~req;                                // 请求淡出
        repeat(18 * `FRAME) @(posedge clk);
        $display("fade out: state=%0d alpha=%0d swap=%0d", dut.state, dut.alpha, swap);
        req = ~req;                                // 请求淡入
        repeat(18 * `FRAME) @(posedge clk);
        $display("fade in : state=%0d alpha=%0d swap=%0d", dut.state, dut.alpha, swap);

        // ---- wipe_right 模式 ----
        mode = 2'd1;
        req = ~req;                                // 请求转场（应立即 swap）
        repeat(2 * `FRAME) @(posedge clk);
        $display("wipe mid: state=%0d boundary=%0d swap=%0d", dut.state, dut.boundary, swap);
        req = ~req;                                // 请求遮罩推进
        repeat(22 * `FRAME) @(posedge clk);
        $display("wipe done: state=%0d boundary=%0d swap=%0d", dut.state, dut.boundary, swap);

        $finish;
    end
endmodule
