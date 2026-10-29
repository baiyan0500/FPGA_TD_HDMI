`timescale 1ns/1ps
// 验证 slogan_ctrl：
//   1) UART 行解析（left/right 方向 + 标语内容更新）
//   2) 弹幕通道：文本/长度/递增色号、toggle 握手、忙时丢弃新消息
module tb_slogan;
    reg clk = 0, rst = 0;
    reg rx_done = 0;
    reg [7:0] rx_data = 0;
    wire [255:0] slogan;
    wire [5:0] len;
    wire dir;
    wire update;
    wire scroll_en;
    wire [191:0] dm_text;
    wire [4:0]   dm_len;
    wire [3:0]   dm_color;
    wire         dm_tgl;
    reg          dm_ack = 0;
    reg          echo_en = 0;

    slogan_ctrl dut(.clk(clk), .rst(rst), .rx_done(rx_done), .rx_data(rx_data),
                    .o_slogan(slogan), .o_len(len), .o_dir(dir), .o_update(update),
                    .o_scroll_en(scroll_en),
                    .o_dm_text(dm_text), .o_dm_len(dm_len), .o_dm_color(dm_color),
                    .o_dm_tgl(dm_tgl), .i_dm_ack(dm_ack));

    always #20 clk = ~clk;

    integer errs = 0;
    integer tgl_cnt = 0;
    integer i;

    function [7:0] dch(input integer k);
        begin
            dch = dm_text[k*8 +: 8];
        end
    endfunction

    task expect8(input [7:0] got, input [7:0] exp, input [127:0] name);
        begin
            if (got !== exp) begin
                $display("FAIL %0s got=%h exp=%h", name, got, exp);
                errs = errs + 1;
            end
        end
    endtask

    task send_byte;
        input [7:0] b;
        begin
            rx_done = 1; rx_data = b; @(posedge clk);
            rx_done = 0; @(posedge clk);
        end
    endtask

    always @(posedge clk)
        if (dm_tgl !== 1'b0 && dm_tgl !== 1'b1) begin
            // placeholder: no-op
        end

    initial begin
        forever @(posedge clk) if (echo_en) dm_ack <= dm_tgl;
    end

    // 观察 toggle 翻转次数
    reg tgl_d = 0;
    always @(posedge clk) begin
        if (tgl_d !== dm_tgl) tgl_cnt = tgl_cnt + 1;
        tgl_d <= dm_tgl;
    end

    initial begin
        rst = 1; #200 rst = 0; #100;
        if (len !== 6'd18) begin $display("FAIL default len=%0d", len); errs = errs + 1; end
        if (scroll_en !== 1'b0) begin $display("FAIL default scroll_en"); errs = errs + 1; end

        // ---------- "left"：只改方向，不产生弹幕 ----------
        send_byte("l"); send_byte("e"); send_byte("f"); send_byte("t"); send_byte(8'h0A);
        repeat (3) @(posedge clk);
        if (dir !== 1'b0)   begin $display("FAIL left dir");       errs = errs + 1; end
        if (scroll_en !== 1'b1) begin $display("FAIL left scroll"); errs = errs + 1; end
        if (tgl_cnt !== 0)  begin $display("FAIL left made danmaku"); errs = errs + 1; end

        send_byte("r"); send_byte("i"); send_byte("g"); send_byte("h"); send_byte("t"); send_byte(8'h0A);
        repeat (3) @(posedge clk);
        if (dir !== 1'b1) begin $display("FAIL right dir"); errs = errs + 1; end

        // ---------- "HELLO"：一条弹幕，色号 0 ----------
        send_byte("H"); send_byte("E"); send_byte("L"); send_byte("L"); send_byte("O"); send_byte(8'h0A);
        repeat (3) @(posedge clk);
        if (len !== 6'd5)     begin $display("FAIL len=%0d", len); errs = errs + 1; end
        if (dm_len !== 5'd5)  begin $display("FAIL dm_len=%0d", dm_len); errs = errs + 1; end
        if (dm_color !== 4'd0) begin $display("FAIL dm_color=%0d", dm_color); errs = errs + 1; end
        if (tgl_cnt !== 1)    begin $display("FAIL dm toggle cnt=%0d", tgl_cnt); errs = errs + 1; end
        expect8(dch(0), "H", "dm ch0");
        expect8(dch(4), "O", "dm ch4");
        expect8(dch(5), 8'h20, "dm ch5 pad");

        // ---------- 忙时（未收到 echo）新消息不能覆盖旧弹幕 ----------
        send_byte("S"); send_byte("E"); send_byte("C"); send_byte(8'h0A);
        repeat (3) @(posedge clk);
        if (tgl_cnt !== 1)      begin $display("FAIL busy: extra toggle %0d", tgl_cnt); errs = errs + 1; end
        if (dm_len !== 5'd5)    begin $display("FAIL busy: dm_len clobbered %0d", dm_len); errs = errs + 1; end
        expect8(dch(0), "H", "busy dm ch0 kept");
        if (len !== 6'd3)       begin $display("FAIL busy: slogan len=%0d", len); errs = errs + 1; end

        // ---------- echo 回来后可再发，色号递增 ----------
        echo_en = 1;
        repeat (6) @(posedge clk);
        send_byte("A"); send_byte("B"); send_byte("C"); send_byte(8'h0A);
        repeat (3) @(posedge clk);
        if (tgl_cnt !== 2)     begin $display("FAIL dm toggle cnt=%0d", tgl_cnt); errs = errs + 1; end
        if (dm_len !== 5'd3)   begin $display("FAIL dm_len=%0d", dm_len); errs = errs + 1; end
        if (dm_color !== 4'd1) begin $display("FAIL dm_color=%0d", dm_color); errs = errs + 1; end
        expect8(dch(0), "A", "dm2 ch0");
        expect8(dch(1), "B", "dm2 ch1");
        expect8(dch(2), "C", "dm2 ch2");

        if (errs == 0) $display("TB_SLOGAN PASS");
        else           $display("TB_SLOGAN FAIL %0d", errs);
        $finish;
    end
endmodule
