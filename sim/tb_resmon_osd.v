`timescale 1ns/1ps
// 验证 resmon_osd：面板范围/边框、四条占用条的长度、标签与百分比文本、
// 实时信息行（帧号 BCD / 视频状态）。
module tb_resmon_osd;
    reg clk = 0, rst = 1;
    reg [10:0] x = 11'd0, y = 11'd0;
    reg en = 1;
    reg [19:0] bcd = 20'h01234;
    reg von = 1;

    wire        txt_on;
    wire [6:0]  ch;
    wire [2:0]  row, col;
    wire [23:0] color;
    wire        bg_on;
    wire [23:0] bg_color;

    resmon_osd #(
        .LUT_PCT(90), .FF_PCT(55), .RAM_PCT(20), .DSP_PCT(7)
    ) dut (
        .i_clk(clk), .i_rst(rst), .i_x(x), .i_y(y), .i_en(en),
        .i_frame_bcd(bcd), .i_video_on(von),
        .o_txt_on(txt_on), .o_char(ch), .o_row(row), .o_col(col),
        .o_color(color), .o_bg_on(bg_on), .o_bg_color(bg_color)
    );

    always #20 clk = ~clk;

    integer errs = 0;

    task at(input integer xx, input integer yy);
        begin
            x = xx[10:0]; y = yy[10:0]; #1;
        end
    endtask

    task chk_px(input integer xx, input integer yy, input integer exp_on);
        begin
            at(xx, yy);
            if (bg_on !== exp_on) begin
                $display("FAIL bg(%0d,%0d)=%b exp %0d", xx, yy, bg_on, exp_on);
                errs = errs + 1;
            end
        end
    endtask

    task chk_char(input integer xx, input integer yy, input [7:0] c);
        begin
            at(xx, yy);
            if (!txt_on || ch !== c[6:0]) begin
                $display("FAIL char(%0d,%0d) on=%b ch=%h exp %h", xx, yy,
                         txt_on, ch, c[6:0]);
                errs = errs + 1;
            end
        end
    endtask

    task chk_bgcol(input integer xx, input integer yy, input [23:0] c);
        begin
            at(xx, yy);
            if (bg_color !== c) begin
                $display("FAIL bgcol(%0d,%0d)=%h exp %h", xx, yy, bg_color, c);
                errs = errs + 1;
            end
        end
    endtask

    initial begin
        repeat (3) @(posedge clk);
        rst = 0;
        repeat (2) @(posedge clk);

        // ---- 面板范围 ----
        chk_px(39, 120, 0);
        chk_px(40, 120, 1);
        chk_px(423, 279, 1);
        chk_px(424, 279, 0);
        chk_px(200, 280, 0);
        at(200, 236);
        if (txt_on) begin $display("FAIL blank area has text"); errs = errs + 1; end

        // ---- 边框 ----
        chk_bgcol(40, 180, 24'h3A6FA0);
        chk_bgcol(423, 180, 24'h3A6FA0);
        chk_bgcol(200, 120, 24'h3A6FA0);
        chk_bgcol(200, 279, 24'h3A6FA0);
        chk_bgcol(200, 236, 24'h070B14);

        // ---- 标题 ----
        chk_char(56,  132, "R");
        chk_char(64,  132, "E");
        chk_char(72,  132, "S");
        chk_char(120, 132, " ");
        chk_char(128, 132, "M");
        chk_char(56 + 15 * 8, 132, "R");

        // ---- 标签行 ----
        chk_char(56, 152, "L");
        chk_char(64, 152, "U");
        chk_char(72, 152, "T");
        chk_char(56, 172, "F");
        chk_char(64, 172, "F");
        chk_char(56, 192, "R");
        chk_char(64, 192, "A");
        chk_char(72, 192, "M");
        chk_char(56, 212, "D");
        chk_char(64, 212, "S");
        chk_char(72, 212, "P");

        // ---- 占用条：LUT 90% -> 172px；FF 55% -> 105px；RAM 20% -> 38；DSP 7% -> 13 ----
        chk_bgcol(104, 160, 24'h2FD8FF);          // LUT 起点
        chk_bgcol(104 + 171, 160, 24'h2FD8FF);    // LUT 末端内
        chk_bgcol(104 + 172, 160, 24'h16324A);    // LUT 轨道
        chk_bgcol(104 + 104, 180, 24'h2FD8FF);    // FF 末端内
        chk_bgcol(104 + 105, 180, 24'h16324A);
        chk_bgcol(104 + 37, 200, 24'h2FD8FF);     // RAM
        chk_bgcol(104 + 38, 200, 24'h16324A);
        chk_bgcol(104 + 12, 220, 24'h2FD8FF);     // DSP
        chk_bgcol(104 + 13, 220, 24'h16324A);

        // ---- 百分比文本（三位右对齐，% 固定在 328）：行0 " 90%"，行1 " 55%"，
        //      行2 " 20%"，行3 "  7%" ----
        chk_char(304, 162, " ");
        chk_char(312, 162, "9");
        chk_char(320, 162, "0");
        chk_char(328, 162, "%");
        chk_char(304, 182, " ");
        chk_char(312, 182, "5");
        chk_char(320, 182, "5");
        chk_char(304, 202, " ");
        chk_char(312, 202, "2");
        chk_char(320, 202, "0");
        chk_char(304, 222, " ");
        chk_char(312, 222, " ");
        chk_char(320, 222, "7");

        // ---- 实时信息 ----
        chk_char(56,  240, "F");
        chk_char(120, 240, "0");
        chk_char(128, 240, "1");
        chk_char(136, 240, "2");
        chk_char(144, 240, "3");
        chk_char(152, 240, "4");
        chk_char(56,  256, "V");
        chk_char(56 + 6 * 8, 256, "R");
        chk_char(56 + 7 * 8, 256, "U");
        chk_char(56 + 8 * 8, 256, "N");
        chk_char(56 + 9 * 8, 256, " ");

        // 停止状态应显示 STOP
        von = 0; at(56 + 6 * 8, 256);
        if (ch !== "S") begin $display("FAIL stop char %h", ch); errs = errs + 1; end
        at(56 + 9 * 8, 256);
        if (ch !== "P") begin $display("FAIL stop char4 %h", ch); errs = errs + 1; end
        von = 1;

        // ---- 关闭面板 ----
        en = 0; at(200, 200);
        if (bg_on || txt_on) begin $display("FAIL en=0 visible"); errs = errs + 1; end
        en = 1;

        if (errs == 0) $display("TB_RESMON PASS");
        else           $display("TB_RESMON FAIL %0d", errs);
        $finish;
    end
endmodule
