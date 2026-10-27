`timescale 1ns/1ps
// 验证 brightness_contrast（5 档按键版）
module tb_bc;
    reg [2:0] bright, contrast;
    reg [23:0] rgb;
    wire [23:0] o_rgb;
    integer errors = 0;

    brightness_contrast dut(.i_bright(bright), .i_contrast(contrast), .i_rgb(rgb), .o_rgb(o_rgb));

    task check;
        input [2:0] b, c;
        input [23:0] in;
        input [23:0] exp;
        begin
            bright = b; contrast = c; rgb = in; #10;
            if (o_rgb !== exp) begin
                errors = errors + 1;
                $display("FAIL b=%0d c=%0d in=%h got=%h exp=%h", b, c, in, o_rgb, exp);
            end else
                $display("PASS b=%0d c=%0d in=%h out=%h", b, c, in, o_rgb);
        end
    endtask

    initial begin
        // 档2 = 正常（亮度0，对比度1.0）
        check(3'd2, 3'd2, 24'h808080, 24'h808080);
        check(3'd2, 3'd2, 24'h000000, 24'h000000);
        check(3'd2, 3'd2, 24'hFFFFFF, 24'hFFFFFF);
        // 亮度档0(-32) / 档4(+32)
        check(3'd0, 3'd2, 24'h808080, 24'h606060);   // 128-32=96
        check(3'd4, 3'd2, 24'h808080, 24'hA0A0A0);   // 128+32=160
        check(3'd4, 3'd2, 24'hC0C0C0, 24'hE0E0E0);   // 192+32=224
        check(3'd4, 3'd2, 24'hE0E0E0, 24'hFFFFFF);   // 224+32 饱和 255
        check(3'd0, 3'd2, 24'h101010, 24'h000000);   // 16-32 饱和 0
        // 对比度档0(0.75) / 档4(1.25)
        check(3'd2, 3'd0, 24'h808080, 24'h808080);   // 中点不变
        check(3'd2, 3'd0, 24'h000000, 24'h202020);   // (0-128)*0.75+128=32
        check(3'd2, 3'd4, 24'hFFFFFF, 24'hFFFFFF);   // (255-128)*1.25+128 饱和
        check(3'd2, 3'd4, 24'h000000, 24'h000000);   // (0-128)*1.25+128 饱和 0

        $display("errors=%0d", errors);
        $finish;
    end
endmodule
