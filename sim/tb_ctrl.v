`timescale 1ns/1ps
// 验证 ctrl：K1 模式循环 + K3/K4 档位循环 + SW 层使能
module tb_ctrl;
    reg clk = 0, rst = 0;
    reg k1 = 1, k3 = 1, k4 = 1;
    reg [3:0] sw = 4'b0001;
    wire [1:0] mode;
    wire [2:0] bright, contrast;

    ctrl dut(.i_clk(clk), .i_rst(rst), .i_k1(k1), .i_k3(k3), .i_k4(k4), .i_sw(sw),
             .o_mode(mode), .o_bright(bright), .o_contrast(contrast));

    always #20 clk = ~clk;

    task press_k1; begin k1 = 0; repeat(600000) @(posedge clk); k1 = 1; repeat(600000) @(posedge clk); end endtask
    task press_k3; begin k3 = 0; repeat(600000) @(posedge clk); k3 = 1; repeat(600000) @(posedge clk); end endtask
    task press_k4; begin k4 = 0; repeat(600000) @(posedge clk); k4 = 1; repeat(600000) @(posedge clk); end endtask

    initial begin
        rst = 1; #200 rst = 0; #100;
        $display("init: mode=%0d bright=%0d contrast=%0d", mode, bright, contrast);
        press_k1; $display("k1 x1: mode=%0d", mode);
        press_k1; $display("k1 x2: mode=%0d", mode);
        press_k1; press_k1; press_k1; $display("k1 x5: mode=%0d", mode);
        press_k3; $display("k3 x1: contrast=%0d", contrast);
        press_k3; $display("k3 x2: contrast=%0d", contrast);
        press_k4; $display("k4 x1: bright=%0d", bright);
        // SW1 拨下，按键应无效
        sw = 4'b0000;
        press_k1; press_k3; press_k4;
        $display("SW1 off: mode=%0d bright=%0d contrast=%0d (应不变)", mode, bright, contrast);
        $finish;
    end
endmodule
