`timescale 1ns/1ps
// 验证 egv_reader：201 扇区/帧、12 扇区周期的音频区、跨段地址跳变、
// 像素重组（RGB565 大端）与音频字节限流（每帧 8000B）。
//
// 数据模式：扇区内第 i 字节 = (sec_addr + i) & 0xFF，便于独立复算。
`include "egv_cfg.vh"
module tb_egv_reader;
    localparam integer BLOCK = `EGV_BLOCK_SECTORS;   // 201
    localparam integer AMOD  = `EGV_AUDIO_MOD;       // 12
    localparam integer AUD_B = `EGV_AUDIO_BYTES;     // 8000

    reg clk = 0, rst = 1;
    reg play = 0, sd_ready = 0;

    wire        o_sd_read;
    wire [31:0] o_sd_addr;
    reg  [7:0]  i_sd_data = 8'd0;
    reg         i_sd_data_valid = 1'b0;
    reg         i_sd_read_end = 1'b0;

    wire        o_pix_en;
    wire [15:0] o_pix;
    wire        o_frame_start;
    wire        o_aud_en;
    wire [7:0]  o_aud_byte;
    wire        o_aud_fstart;
    wire [15:0] o_frame_no;
    wire        o_active;

    egv_reader #(.FRAME_CYC(23'd210)) dut (
        .clk(clk), .rst(rst), .i_play(play), .i_sd_ready(sd_ready),
        .o_sd_read(o_sd_read), .o_sd_addr(o_sd_addr),
        .i_sd_data(i_sd_data), .i_sd_data_valid(i_sd_data_valid),
        .i_sd_read_end(i_sd_read_end),
        .o_pix_en(o_pix_en), .o_pix(o_pix), .o_frame_start(o_frame_start),
        .o_aud_en(o_aud_en), .o_aud_byte(o_aud_byte), .o_aud_fstart(o_aud_fstart),
        .o_frame_no(o_frame_no), .o_active(o_active)
    );

    always #5 clk = ~clk;

    // ---------------- SD 扇区读模型 ----------------
    // 注意：reader 在 read_end 同拍更新 o_sd_addr，故必须等 busy 拉高后再等
    // 一拍锁存地址（此时新地址已生效），否则会重复读上一个扇区。
    reg [31:0] cur;
    reg [8:0]  bcnt;
    reg        busy;
    reg        started;

    always @(posedge clk) begin
        i_sd_data_valid <= 1'b0;
        i_sd_read_end   <= 1'b0;
        if (rst) begin
            busy <= 1'b0; started <= 1'b0; bcnt <= 9'd0; cur <= 32'd0;
        end else if (!o_sd_read) begin
            busy <= 1'b0; started <= 1'b0; bcnt <= 9'd0;
        end else if (!busy) begin
            busy <= 1'b1; started <= 1'b0;
        end else if (!started) begin
            cur <= o_sd_addr;
            started <= 1'b1;
            bcnt <= 9'd0;
        end else begin
            i_sd_data       <= cur[7:0] + bcnt[7:0];
            i_sd_data_valid <= 1'b1;
            if (bcnt == 9'd511) begin
                bcnt          <= 9'd0;
                busy          <= 1'b0;
                started       <= 1'b0;
                i_sd_read_end <= 1'b1;
            end else
                bcnt <= bcnt + 9'd1;
        end
    end

    // ---------------- 地址/数据采集 ----------------
    // 帧内视频/音频扇区计数
    integer sec_in_frame = 0;
    integer npix = 0, naud = 0;
    integer pix_err = 0, aud_err = 0, addr_err = 0, eof_err = 0;
    integer gsec = 0;          // 期望的数据扇区逻辑号
    integer pix_in_frame = 0, aud_in_frame = 0;
    integer frames_done = 0;
    reg [7:0] aud_mem [0:15999];
    reg [15:0] pix_first [0:7];

    // 每收到一个 read_end，核对地址并推进期望
    function [31:0] exp_phys(input integer g);
        begin
            if (g < `EGV_RG1)                exp_phys = `EGV_RP0 + g;
            else if (g < `EGV_RG2)           exp_phys = `EGV_RP1 + (g - `EGV_RG1);
            else                             exp_phys = `EGV_RP2 + (g - `EGV_RG2);
        end
    endfunction

    reg [31:0] seen_addr;
    always @(posedge clk) begin
        if (!rst && busy && bcnt == 9'd0)
            seen_addr <= o_sd_addr;
    end

    always @(posedge clk) begin
        if (!rst && i_sd_read_end) begin
            if (seen_addr !== exp_phys(gsec)) begin
                if (addr_err < 5)
                    $display("ADDR ERR g=%0d got %0d exp %0d",
                             gsec, seen_addr, exp_phys(gsec));
                addr_err = addr_err + 1;
            end
            gsec = gsec + 1;
        end
    end

    // 像素：第 n 个视频像素来自该帧第 n/256 个视频扇区的 2*(n%256) 字节
    wire new_pix = o_pix_en;
    always @(posedge clk) begin
        if (!rst && new_pix) begin
            if (npix < 8) pix_first[npix] <= o_pix;
            npix = npix + 1;
            pix_in_frame = pix_in_frame + 1;
        end
    end

    always @(posedge clk) begin
        if (!rst && o_aud_en) begin
            aud_mem[naud] = o_aud_byte;
            naud = naud + 1;
            aud_in_frame = aud_in_frame + 1;
        end
    end

    // 帧结束检查
    wire frame_end = o_frame_start;   // 下一帧起始 == 上一帧结束
    always @(posedge clk) begin
        if (!rst && frame_end && frames_done > 0) begin
            $display("frame %0d: pix=%0d aud=%0d", frames_done - 1,
                     pix_in_frame, aud_in_frame);
            if (pix_in_frame != `EGV_W * `EGV_H) begin
                $display("FAIL pix count %0d", pix_in_frame); pix_err = pix_err + 1;
            end
            if (aud_in_frame != AUD_B) begin
                $display("FAIL aud count %0d", aud_in_frame); aud_err = aud_err + 1;
            end
            pix_in_frame = 0;
            aud_in_frame = 0;
        end
        if (!rst && frame_end)
            frames_done = frames_done + 1;
    end

    // ---------------- 主流程 ----------------
    integer k;
    integer n, vs, off, gi, vg;
    reg [31:0] ep;
    reg [7:0] exp_hi, exp_lo;
    initial begin
        repeat (5) @(posedge clk);
        rst = 0;
        repeat (5) @(posedge clk);
        sd_ready = 1;
        play = 1;

        // 等两帧读完（第 3 次 frame_start 出现时结束）
        wait (frames_done == 3);
        repeat (10) @(posedge clk);

        // 像素复算：第 0 帧第 n 个像素 -> 视频扇区 n/256 的 2*(n%256)、+1 字节
        // 第 n 个视频扇区的物理地址 = exp_phys(frame0 中第 n 个非音频扇区逻辑号)
        // 帧0 逻辑 g = 0..200，音频在 g%12==11
        for (k = 0; k < 8; k = k + 1) begin
            n = k;
            vs = n / 256;             // 第 n 个像素所在视频扇区序号
            off = (n % 256) * 2;
            // 换算成帧内逻辑扇区号（跳过音频扇区）
            gi = (vs / (AMOD - 1)) * AMOD + (vs % (AMOD - 1));
            vg = gi;
            ep = exp_phys(vg);
            exp_hi = ep[7:0] + off[7:0];
            exp_lo = exp_hi + 8'd1;
            if (pix_first[n] !== {exp_hi, exp_lo}) begin
                $display("FAIL pix %0d got %h exp %h", n, pix_first[n],
                         {exp_hi, exp_lo});
                pix_err = pix_err + 1;
            end
        end

        // 音频复算：帧0 第 0 个音频字节来自 g=11 的字节 0
        for (k = 0; k < 16; k = k + 1) begin
            ep = exp_phys(11 + (k / 512) * AMOD);
            exp_hi = ep[7:0] + (k % 512);
            if (aud_mem[k] !== exp_hi) begin
                $display("FAIL aud %0d got %h exp %h", k, aud_mem[k], exp_hi);
                aud_err = aud_err + 1;
            end
        end

        // ---- EOF 停止：把帧号强推到末帧，播完应停止取流并冻结 ----
        force dut.o_frame_no = `EGV_FRAMES - 1;
        k = 0;
        while (dut.o_active && k < 4_000_000) begin @(posedge clk); k = k + 1; end
        repeat (20) @(posedge clk);
        if (dut.o_active || !dut.eof_stop) begin
            $display("FAIL eof: active=%b eof_stop=%b", dut.o_active, dut.eof_stop);
            eof_err = eof_err + 1;
        end
        // 停在末尾时不应再发起扇区读
        k = 0;
        while (k < 2000) begin
            @(posedge clk);
            if (dut.o_sd_read) begin
                $display("FAIL eof: still reading sector");
                eof_err = eof_err + 1;
                k = 4000;
            end
            k = k + 1;
        end
        // 松开 K1 再按：应从头重新播放
        release dut.o_frame_no;
        play = 0;
        repeat (10) @(posedge clk);
        play = 1;
        k = 0;
        while (!dut.o_active && k < 200_000) begin @(posedge clk); k = k + 1; end
        if (!dut.o_active || dut.eof_stop) begin
            $display("FAIL eof: restart failed (active=%b)", dut.o_active);
            eof_err = eof_err + 1;
        end
        repeat (10) @(posedge clk);
        if (dut.o_frame_no > 16'd5) begin
            $display("FAIL eof: restart frame_no=%0d", dut.o_frame_no);
            eof_err = eof_err + 1;
        end

        $display("addr_err=%0d pix_err=%0d aud_err=%0d eof_err=%0d frames=%0d",
                 addr_err, pix_err, aud_err, eof_err, frames_done);
        if (addr_err == 0 && pix_err == 0 && aud_err == 0 && eof_err == 0 &&
            frames_done >= 3)
            $display("TB_EGV_READER PASS");
        else
            $display("TB_EGV_READER FAIL");
        $finish;
    end

    initial begin
        #20_000_000;
        $display("TB_EGV_READER TIMEOUT (frames=%0d gsec=%0d)", frames_done, gsec);
        $finish;
    end
endmodule
