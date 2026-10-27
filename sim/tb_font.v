`timescale 1ns/1ps
// 验证 font8x8 含小写 a-z 非零字形
module tb_font;
    reg [6:0] ch;
    reg [2:0] row;
    wire [7:0] dout;
    font8x8 dut(.i_char(ch), .i_row(row), .o_row(dout));
    integer hit = 0;
    integer i, r;
    initial begin
        for (i = 0; i < 26; i = i + 1) begin
            ch = 7'h61 + i;   // 'a'..'z'
            for (r = 0; r < 8; r = r + 1) begin
                row = r; #1;
                if (dout != 8'h00) hit = hit + 1;
            end
        end
        $display("lowercase non-zero rows=%0d (期望>0)", hit);
        // 抽查 'h' = 0x68 第0行
        ch = 7'h68; row = 3'd0; #1;
        $display("'h' row0 = %h", dout);
        $finish;
    end
endmodule
