`timescale 1ns/1ps
// 验证 slogan_ctrl：UART 行解析（left/right 方向 + 标语更新）
module tb_slogan;
    reg clk = 0, rst = 0;
    reg rx_done = 0;
    reg [7:0] rx_data = 0;
    wire [255:0] slogan;
    wire [5:0] len;
    wire dir;
    wire update;
    wire scroll_en;

    slogan_ctrl dut(.clk(clk), .rst(rst), .rx_done(rx_done), .rx_data(rx_data),
                    .o_slogan(slogan), .o_len(len), .o_dir(dir), .o_update(update),
                    .o_scroll_en(scroll_en));

    always #20 clk = ~clk;

    task send_byte;
        input [7:0] b;
        begin
            rx_done = 1; rx_data = b; @(posedge clk);
            rx_done = 0; @(posedge clk);
        end
    endtask

    initial begin
        rst = 1; #200 rst = 0; #100;
        $display("init: len=%0d dir=%0d scroll_en=%0d", len, dir, scroll_en);

        // 发送 "left\n"
        send_byte("l"); send_byte("e"); send_byte("f"); send_byte("t"); send_byte(8'h0A);
        $display("after 'left': dir=%0d scroll_en=%0d (dir期望0, scroll_en期望1)", dir, scroll_en);

        // 发送 "right\n"
        send_byte("r"); send_byte("i"); send_byte("g"); send_byte("h"); send_byte("t"); send_byte(8'h0A);
        $display("after 'right': dir=%0d scroll_en=%0d (dir期望1, scroll_en期望1)", dir, scroll_en);

        // 发送 "HELLO FPGA\n"（10 字符，短标语）
        send_byte("H"); send_byte("E"); send_byte("L"); send_byte("L"); send_byte("O");
        send_byte(" "); send_byte("F"); send_byte("P"); send_byte("G"); send_byte("A");
        send_byte(8'h0A);
        $display("after text: len=%0d scroll_en=%0d (len期望10, scroll_en期望0)", len, scroll_en);

        $finish;
    end
endmodule
