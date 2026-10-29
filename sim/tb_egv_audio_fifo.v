`timescale 1ns/1ps
// 验证 egv_audio_fifo：s16le 字节拼字、跨时钟读出顺序、跨 8192 深度回卷、
// flush 清空与重同步。
module tb_egv_audio_fifo;
    reg wclk = 0, rclk = 0, rst = 1;
    reg flush = 1, fstart = 0, wr_en = 0;
    reg [7:0] wr_byte = 8'd0;

    wire [13:0] count;
    reg  rd_en = 0;
    wire [15:0] rd_data;
    wire        rd_empty;

    egv_audio_fifo dut (
        .i_wclk(wclk), .i_wrst(rst), .i_flush(flush),
        .i_fstart(fstart), .i_wr_en(wr_en), .i_wr_byte(wr_byte),
        .o_count(count),
        .i_rclk(rclk), .i_rrst(rst), .i_flush_r(flush),
        .i_rd_en(rd_en), .o_rd_data(rd_data), .o_rd_empty(rd_empty)
    );

    always #5   wclk = ~wclk;      // 100MHz
    always #40.69 rclk = ~rclk;    // 12.288MHz

    integer errs = 0;
    integer wb = 0;                // 全局已写字节数
    integer rw = 0;                // 全局已读字数

    function [7:0] byte_pat(input integer n);
        begin
            byte_pat = (n * 7 + 3) & 8'hFF;
        end
    endfunction

    // 全局第 k 个字 = {b(2k+1), b(2k)}
    function [15:0] exp_word(input integer k);
        begin
            exp_word = {byte_pat(2 * k + 1), byte_pat(2 * k)};
        end
    endfunction

    task wr_frame;                 // 8000 字节
        integer i;
        begin
            @(posedge wclk);
            fstart <= 1'b1;
            @(posedge wclk);
            fstart <= 1'b0;
            for (i = 0; i < 8000; i = i + 1) begin
                wr_byte <= byte_pat(wb);
                wr_en   <= 1'b1;
                @(posedge wclk);
                wb = wb + 1;
            end
            wr_en <= 1'b0;
            repeat (8) @(posedge wclk);
        end
    endtask

    // FWFT + 寄存出队：本拍看到的 o_rd_data 是本拍拉高 i_rd_en 要弹出的字，
    // 弹出在下一拍完成，故每字 2 拍（先取样再确认弹出）。
    task rd_words(input integer n);
        integer c;
        begin
            c = 0;
            while (c < n) begin
                @(posedge rclk);
                while (rd_empty) @(posedge rclk);
                if (rd_data !== exp_word(rw)) begin
                    if (errs < 5)
                        $display("FAIL w%0d got %h exp %h", rw, rd_data,
                                 exp_word(rw));
                    errs = errs + 1;
                end
                rw = rw + 1;
                c  = c + 1;
                rd_en <= 1'b1;
                @(posedge rclk);
                rd_en <= 1'b0;
            end
        end
    endtask

    integer k;
    initial begin
        repeat (10) @(posedge wclk);
        rst = 0;
        repeat (5) @(posedge wclk);
        flush <= 1'b0;
        repeat (5) @(posedge wclk);

        if (!rd_empty) begin $display("FAIL not empty after flush"); errs = errs + 1; end

        // 3 轮：每轮写 1 帧（4000 字）再读 4000 字 -> 指针跨越 8192
        for (k = 0; k < 3; k = k + 1) begin
            wr_frame;
            repeat (5) @(posedge wclk);
            if (k == 0) $display("count after 1 frame = %0d (期望 4000)", count);
            rd_words(4000);
            repeat (5) @(posedge wclk);
        end
        $display("rounds done: bytes=%0d words=%0d", wb, rw);

        // flush 清空
        flush <= 1'b1;
        repeat (10) @(posedge wclk);
        flush <= 1'b0;
        repeat (5) @(posedge wclk);
        if (!rd_empty) begin $display("FAIL not empty after 2nd flush"); errs = errs + 1; end
        if (count !== 14'd0) begin $display("FAIL count %0d after flush", count); errs = errs + 1; end

        // flush 后再写一帧，应从 0 正常读出（数据按新序号继续增长）
        rw = wb / 2;
        wr_frame;
        repeat (5) @(posedge wclk);
        if (count < 14'd3990) begin
            $display("FAIL count after refill %0d", count); errs = errs + 1;
        end
        rd_words(4000);

        if (errs == 0) $display("TB_AFIFO PASS");
        else           $display("TB_AFIFO FAIL %0d", errs);
        $finish;
    end

    initial begin
        #5_000_000;
        $display("TB_AFIFO TIMEOUT wb=%0d rw=%0d count=%0d", wb, rw, count);
        $finish;
    end
endmodule
