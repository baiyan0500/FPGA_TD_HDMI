`timescale 1ns/1ps
// 验证 danmaku_osd：滑屏位置、逐字符取字、逐字变色、双轨道 + 1 深度暂存、
// 以及"滚出屏幕才消失"。
module tb_danmaku_osd;
    reg clk = 0, rst = 1;
    reg tick = 0, en = 1;
    reg [191:0] txt = 192'd0;
    reg [4:0]   len = 5'd0;
    reg [3:0]   colr = 4'd0;
    reg         tgl = 0;
    reg [10:0]  x = 11'd0, y = 11'd0;

    wire ack, txt_on;
    wire [6:0]  ch;
    wire [2:0]  row, ccol;
    wire [23:0] color;

    danmaku_osd dut (
        .i_clk(clk), .i_rst(rst), .i_frame_tick(tick),
        .i_x(x), .i_y(y), .i_en(en),
        .i_text(txt), .i_len(len), .i_color(colr), .i_tgl(tgl), .o_ack(ack),
        .o_txt_on(txt_on), .o_char(ch), .o_row(row), .o_col(ccol),
        .o_color(color)
    );

    always #20 clk = ~clk;

    integer errs = 0;
    localparam integer L0Y = 48, L1Y = 80;

    function [23:0] pal(input [2:0] idx);
        begin
            case (idx)
                3'd0: pal = 24'hFF5E5E;
                3'd1: pal = 24'hFFD166;
                3'd2: pal = 24'h5CFF7A;
                3'd3: pal = 24'h4FD1FF;
                3'd4: pal = 24'hC08BFF;
                3'd5: pal = 24'hFF8AE2;
                3'd6: pal = 24'hFFFFFF;
                default: pal = 24'h7CFFCB;
            endcase
        end
    endfunction

    // 把 ASCII 字面量按"字符0在最低字节"装入 txt
    task put(input [255:0] s, input integer n);
        integer i;
        begin
            txt = 192'd0;
            for (i = 0; i < n; i = i + 1)
                txt[i*8 +: 8] = s[(n-1-i)*8 +: 8];
        end
    endtask

    task send_msg(input [255:0] s, input integer n, input [3:0] c);
        begin
            put(s, n);
            len  <= n;
            colr <= c;
            @(posedge clk);
            tgl <= ~tgl;
            @(posedge clk);
            repeat (4) @(posedge clk);
            if (ack !== tgl) begin
                $display("FAIL ack not echoed"); errs = errs + 1;
            end
        end
    endtask

    task do_tick(input integer n);
        integer i;
        begin
            for (i = 0; i < n; i = i + 1) begin
                tick <= 1'b1;
                @(posedge clk);
                tick <= 1'b0;
                @(posedge clk);
            end
        end
    endtask

    // 在指定轨道检查：可见区左边界/字符/颜色与当前 pos、文本寄存器一致
    task check_lane(input integer lane, input integer n, input [3:0] cbase);
        integer pos, x0, xs, xe, xx, ci, k;
        reg [7:0] cb;
        begin
            pos = (lane == 0) ? dut.l0_pos : dut.l1_pos;
            x0  = 648 - pos;
            xs  = (x0 < 0) ? 0 : x0;
            xe  = x0 + n * 16 - 1;
            if (xe > 639) xe = 639;
            y = (lane == 0) ? L0Y + 3 : L1Y + 3;
            if (xe >= xs) begin
                for (xx = xs; xx <= xe; xx = xx + 1) begin
                    x = xx; #1;
                    ci = (xx - x0) / 16;
                    cb = (lane == 0) ? dut.l0_txt[ci*8 +: 8] : dut.l1_txt[ci*8 +: 8];
                    if (!txt_on) begin
                        if (errs < 8)
                            $display("FAIL lane%0d gap at x=%0d (pos=%0d)",
                                     lane, xx, pos);
                        errs = errs + 1;
                    end else begin
                        k = cb[6:0];
                        if (ch !== k[6:0]) begin
                            if (errs < 8)
                                $display("FAIL lane%0d x=%0d char %h exp %h",
                                         lane, xx, ch, k[6:0]);
                            errs = errs + 1;
                        end
                        if (color !== pal(cbase[2:0] + (ci % 8))) begin
                            if (errs < 8)
                                $display("FAIL lane%0d x=%0d color %h exp %h",
                                         lane, xx, color,
                                         pal(cbase[2:0] + (ci % 8)));
                            errs = errs + 1;
                        end
                    end
                end
            end
            if (xs > 0) begin
                x = xs - 1; #1;
                if (txt_on) begin
                    $display("FAIL lane%0d text left of x0 at %0d", lane, xs - 1);
                    errs = errs + 1;
                end
            end
            if (xe < 639) begin
                x = xe + 1; #1;
                if (txt_on) begin
                    $display("FAIL lane%0d text right of end", lane);
                    errs = errs + 1;
                end
            end
        end
    endtask

    task no_text(input integer lane);
        integer xx;
        begin
            y = (lane == 0) ? L0Y + 3 : L1Y + 3;
            for (xx = 0; xx < 640; xx = xx + 1) begin
                x = xx; #1;
                if (txt_on) begin
                    $display("FAIL lane%0d visible at x=%0d pos=%0d", lane, xx,
                             (lane == 0) ? dut.l0_pos : dut.l1_pos);
                    errs = errs + 1;
                end
            end
        end
    endtask

    initial begin
        repeat (5) @(posedge clk);
        rst = 0;
        repeat (3) @(posedge clk);

        // ---- 消息0：HELLO 进轨道0 ----
        send_msg("HELLO", 5, 4'd1);
        if (!dut.l0_busy) begin $display("FAIL l0 not busy"); errs = errs + 1; end
        if (dut.l0_txt[39:0] !== 40'h4F4C4C4548) begin
            $display("FAIL text load %h", dut.l0_txt[39:0]); errs = errs + 1;
        end
        no_text(0);                       // pos=0，完全在屏幕右侧外
        do_tick(10);                      // pos=80，x0=568
        check_lane(0, 5, 4'd1);

        // ---- 消息1：WORLD 同时进轨道1 ----
        send_msg("WORLD", 5, 4'd4);
        if (!dut.l1_busy) begin $display("FAIL l1 not busy"); errs = errs + 1; end
        do_tick(10);                      // l0 pos=160, l1 pos=80
        check_lane(0, 5, 4'd1);
        check_lane(1, 5, 4'd4);

        // ---- 消息2：两轨都忙 -> 暂存 ----
        send_msg("PEND", 4, 4'd6);
        do_tick(1);
        if (!dut.pd_vld) begin $display("FAIL no pending"); errs = errs + 1; end

        // 轨道0 走完（648+80=728）：从 pos=168 再 71 帧 -> 越过 728 后交棒
        do_tick(71);
        if (dut.l0_pos != 11'd0 || !dut.l0_busy) begin
            $display("FAIL retire/handover: pos=%0d busy=%b", dut.l0_pos, dut.l0_busy);
            errs = errs + 1;
        end
        if (dut.pd_vld) begin $display("FAIL pending not consumed"); errs = errs + 1; end
        do_tick(10);                      // l0 pos=80，l1 在 728 退役
        check_lane(0, 4, 4'd6);
        if (dut.l1_busy) begin $display("FAIL l1 still busy"); errs = errs + 1; end
        no_text(1);

        // ---- 等两轨空闲后发 24 字符长文本 ----
        do_tick(85);
        if (dut.l0_busy || dut.l1_busy) begin
            $display("FAIL lanes not idle: %b %b", dut.l0_busy, dut.l1_busy);
            errs = errs + 1;
        end
        send_msg("ABCDEFGHIJKLMNOPQRSTUVWX", 24, 4'd2);
        if (!dut.l0_busy || dut.l0_len != 5'd24) begin
            $display("FAIL long msg lane0 len=%0d", dut.l0_len); errs = errs + 1;
        end
        do_tick(95);                      // pos=760，x0=-112
        check_lane(0, 24, 4'd2);

        // ---- i_en=0 时全部隐藏 ----
        en = 0; x = 600; y = L0Y + 3; #1;
        if (txt_on) begin $display("FAIL en=0 still visible"); errs = errs + 1; end
        en = 1;

        if (errs == 0) $display("TB_DANMAKU PASS");
        else           $display("TB_DANMAKU FAIL %0d", errs);
        $finish;
    end

    initial begin
        #2_000_000;
        $display("TB_DANMAKU TIMEOUT l0=%0d l1=%0d", dut.l0_pos, dut.l1_pos);
        $finish;
    end
endmodule
