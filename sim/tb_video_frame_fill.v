`timescale 1ns/1ps
// 验证 video_frame_fill：
//   1) 初始化两次全帧清零（bank0/bank1）后 o_ready
//   2) 每帧 4*W*H 个字的 2 倍放大输出（横向复制 2 次、纵向复制 2 行）
//   3) 帧完成后 i_fin_tgl 翻转 -> o_disp_bank 切换 + o_frame_end 单拍
// 用小尺寸参数跑功能（逻辑与 320x148 完全一致）。
module tb_video_frame_fill;
    localparam integer SW = 16;
    localparam integer SH = 8;
    localparam integer FW = 64;          // FULL_WORDS
    localparam integer VW = 512;         // 4*SW*SH

    reg clk = 0, rst = 1;
    reg en = 0;
    reg frame_start = 0, pix_en = 0;
    reg [15:0] pix = 16'd0;
    reg fin_tgl = 0;

    wire        wr_req;
    reg         wr_ack = 0;
    wire        wr_en;
    wire [31:0] wr_data;
    wire [20:0] wr_len;
    wire        wr_bank, addr_full;
    wire        disp_bank, ready, busy, frame_end, frame_ready;

    video_frame_fill #(
        .SRC_W(SW), .SRC_H(SH),
        .FULL_WORDS(FW[20:0]), .VIDEO_WORDS(VW[20:0])
    ) dut (
        .clk(clk), .rst(rst), .i_en(en),
        .i_frame_start(frame_start), .i_pix_en(pix_en), .i_pix(pix),
        .o_wr_req(wr_req), .i_wr_ack(wr_ack), .o_wr_en(wr_en),
        .o_wr_data(wr_data), .o_wr_len(wr_len), .o_wr_bank(wr_bank),
        .o_addr_full(addr_full), .i_fin_tgl(fin_tgl),
        .o_disp_bank(disp_bank), .o_ready(ready), .o_busy(busy),
        .o_frame_end(frame_end), .o_frame_ready(frame_ready)
    );

    always #5 clk = ~clk;

    // ---- 简易写口从机：ack 延迟 3 拍 ----
    reg [2:0] ackd;
    always @(posedge clk or posedge rst) begin
        if (rst) begin ackd <= 3'd0; wr_ack <= 1'b0; end
        else begin
            ackd   <= {ackd[1:0], wr_req};
            wr_ack <= wr_req & ~ackd[2] & ackd[1];
        end
    end

    // ---- 写数据采集：在时钟下降沿采样，此时 wr_en/wr_data/wr_bank/addr_full
    //      均为上一上升沿的稳定值，天然同拍对齐（避免跨拍错位）----
    integer    full_cnt = 0, vid_cnt = 0;
    integer    bank0_cnt = 0, bank1_cnt = 0;
    integer    bank_chg = 0;
    reg        bank_prev = 1'b0, bank_first = 1'b0;
    integer    nz_cnt = 0;
    integer    errs = 0;
    reg [31:0] cap [0:2047];
    reg        fe_seen = 0;
    reg        fb_seen = 0;

    always @(negedge clk) begin
        if (wr_en) begin
            if (addr_full) begin
                if (full_cnt == 0) begin
                    bank_first = wr_bank;
                    bank_prev  = wr_bank;
                end else if (wr_bank !== bank_prev) begin
                    bank_chg  = bank_chg + 1;
                    bank_prev = wr_bank;
                end
                full_cnt = full_cnt + 1;
                if (wr_data != 32'd0) nz_cnt = nz_cnt + 1;
                if (wr_bank) bank1_cnt = bank1_cnt + 1;
                else         bank0_cnt = bank0_cnt + 1;
            end else begin
                if (vid_cnt < 2048) cap[vid_cnt] = wr_data;
                vid_cnt = vid_cnt + 1;
            end
        end
        if (frame_end) fe_seen = 1;
        if (ready && !busy) fb_seen = 1;
    end

    // frame_ready 语义：只在 E_IDLE 为高；初始化未完成/正在写帧时必须为低，
    // 读端靠它避免在填充未结束时发起下一帧（bug2 丢帧根因）
    integer rdy_err = 0;
    always @(posedge clk) begin
        if (!rst && frame_ready && (busy || !ready))
            rdy_err = rdy_err + 1;
    end

    // ---- 像素激励：按源行低 8 位 + 列 组成 16bit，行 0 用棋盘便于查横向复制 ----
    task send_row(input integer r);
        integer c;
        begin
            for (c = 0; c < SW; c = c + 1) begin
                pix    <= (r == 0) ? ((c[0]) ? 16'hFFFF : 16'h0000)
                                   : (16'h1000 | ((r * 16 + c) & 16'h00FF));
                pix_en <= 1'b1;
                @(posedge clk);
                pix_en <= 1'b0;
                repeat (7) @(posedge clk);
            end
            repeat (16) @(posedge clk);
        end
    endtask

    task send_frame;
        integer r;
        begin
            @(posedge clk);
            frame_start <= 1'b1;
            @(posedge clk);
            frame_start <= 1'b0;
            repeat (3) @(posedge clk);
            if (frame_ready !== 1'b0) begin
                $display("FAIL frame_ready high during fill");
                rdy_err = rdy_err + 1;
            end
            for (r = 0; r < SH; r = r + 1) send_row(r);
        end
    endtask

    function [23:0] exp888(input [15:0] v);
        begin
            exp888 = {v[15:11], v[13:11], v[10:5], v[9:8], v[4:0], v[2:0]};
        end
    endfunction

    integer i, r0w, r1w;
    reg [23:0] e0, e1;
    initial begin
        repeat (5) @(posedge clk);
        rst = 0;
        repeat (5) @(posedge clk);

        // ---------- 初始化 ----------
        en <= 1'b1;
        wait (ready === 1'b1);
        repeat (8) @(posedge clk);
        $display("init done: full=%0d bank0=%0d bank1=%0d nonzero=%0d",
                 full_cnt, bank0_cnt, bank1_cnt, nz_cnt);
        if (full_cnt != 2 * FW) begin $display("FAIL full cnt"); errs = errs + 1; end
        // 两次全帧清零：各写一个 bank，切换点与最后一次写同拍，故允许 ±1 归属误差
        if (bank_chg != 1 || bank_first != 1'b0 || bank_prev != 1'b1 ||
            bank0_cnt < FW - 1 || bank1_cnt < FW - 1) begin
            $display("FAIL bank seq: chg=%0d first=%0d last=%0d split %0d/%0d",
                     bank_chg, bank_first, bank_prev, bank0_cnt, bank1_cnt);
            errs = errs + 1;
        end
        if (nz_cnt != 0) begin $display("FAIL init not zero"); errs = errs + 1; end
        if (busy !== 1'b0) begin $display("FAIL busy after init"); errs = errs + 1; end
        if (frame_ready !== 1'b1) begin
            $display("FAIL frame_ready not high when idle"); errs = errs + 1;
        end

        // ---------- 第一帧 ----------
        send_frame;
        // 等写完
        wait (vid_cnt == VW);
        repeat (50) @(posedge clk);
        $display("frame0 words=%0d len=%0d addr_full=%0d bank=%0d",
                 vid_cnt, wr_len, addr_full, wr_bank);
        if (vid_cnt != VW) begin $display("FAIL word cnt"); errs = errs + 1; end
        if (wr_len != VW)  begin $display("FAIL len %0d", wr_len); errs = errs + 1; end
        if (addr_full != 1'b0) begin $display("FAIL addr_full"); errs = errs + 1; end

        // 行0 横向复制：word 2c 与 2c+1 相同且等于棋盘色；上下两行相同
        for (i = 0; i < SW; i = i + 1) begin
            e0 = exp888(i[0] ? 16'hFFFF : 16'h0000);
            r0w = 2 * i;             // 上半行
            r1w = SW * 2 + 2 * i;    // 下半行（phase=1）
            if (cap[r0w] !== {e0, 8'h00} || cap[r0w + 1] !== {e0, 8'h00}) begin
                $display("FAIL row0 col %0d: %h %h exp %h", i, cap[r0w],
                         cap[r0w + 1], {e0, 8'h00});
                errs = errs + 1;
            end
            if (cap[r1w] !== {e0, 8'h00}) begin
                $display("FAIL row0 lower phase col %0d", i);
                errs = errs + 1;
            end
        end
        // 行1 第一个字
        e1 = exp888(16'h1000 + 8'd16);
        if (cap[4 * SW] !== {e1, 8'h00}) begin
            $display("FAIL row1 first: %h exp %h", cap[4 * SW], {e1, 8'h00});
            errs = errs + 1;
        end
        // 末字（行7 最后像素下半行）
        e1 = exp888(16'h1000 + 8'd7 * 8'd16 + (SW - 1));
        if (cap[VW - 1] !== {e1, 8'h00}) begin
            $display("FAIL last word: %h exp %h", cap[VW - 1], {e1, 8'h00});
            errs = errs + 1;
        end

        // ---------- 帧完成 toggle ----------
        if (fe_seen !== 1'b0) begin $display("FAIL frame_end early"); errs = errs + 1; end
        @(posedge clk); fin_tgl <= 1'b1;
        repeat (10) @(posedge clk);
        fin_tgl <= 1'b0;
        repeat (5) @(posedge clk);
        if (fe_seen !== 1'b1) begin $display("FAIL no frame_end"); errs = errs + 1; end
        if (disp_bank !== wr_bank) begin
            $display("FAIL disp_bank %0d wr_bank %0d", disp_bank, wr_bank); errs = errs + 1;
        end
        $display("frame_end ok, disp_bank=%0d", disp_bank);

        // ---------- 第二帧：bank 应翻转 ----------
        vid_cnt = 0;
        send_frame;
        wait (vid_cnt == VW);
        repeat (20) @(posedge clk);
        if (disp_bank == wr_bank) begin
            $display("FAIL bank not toggled on 2nd frame"); errs = errs + 1;
        end

        // ---------- 关闭再打开：不重复初始化 ----------
        en <= 1'b0;
        repeat (20) @(posedge clk);
        if (busy !== 1'b0) begin $display("FAIL busy when off"); errs = errs + 1; end
        full_cnt = 0;
        fe_seen = 0;
        en <= 1'b1;
        repeat (40) @(posedge clk);
        if (full_cnt != 0) begin
            $display("FAIL re-init %0d words", full_cnt); errs = errs + 1;
        end
        if (busy !== 1'b0) begin $display("FAIL stayed busy"); errs = errs + 1; end

        if (errs == 0 && rdy_err == 0) $display("TB_VFF PASS");
        else $display("TB_VFF FAIL %0d rdy_err=%0d", errs, rdy_err);
        $finish;
    end

    initial begin
        #5_000_000;
        $display("TB_VFF TIMEOUT ready=%b vid=%0d", ready, vid_cnt);
        $finish;
    end
endmodule
