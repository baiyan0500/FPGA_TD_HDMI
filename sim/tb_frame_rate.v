`timescale 1ns/1ps
// tb_frame_rate — 实测 egv_reader 的帧周期是否真的等于 FRAME_CYC（41.67ms）
//
// 动机：上板实测 81s 的视频约 60s 播完（只播了前 50+s），比例 1.35。
//   若帧间隔被压到 ~31ms，则同时解释
//     ① 内容 1.35 倍速跑完；
//     ② 每帧仍灌 8000B 音频 → 音频 FIFO 持续溢出 → 全时电流声。
//   本台用与上板相同的 FRAME_CYC = 4_166_667（100MHz → 41.67ms），
//   i_fill_ready 恒 1（只测 reader 自身的节流闸门），打印每次 o_frame_start 的间隔。
`include "egv_cfg.vh"
module tb_frame_rate;
    localparam integer BLOCK = `EGV_BLOCK_SECTORS;   // 201
    localparam integer AMOD  = `EGV_AUDIO_MOD;       // 12
    localparam integer AUD_B = `EGV_AUDIO_BYTES;     // 8000
    localparam integer NFRM  = 4;
    localparam [31:0]  HDR_LBA  = 32'd1000;
    localparam [31:0]  DATA_LBA = HDR_LBA + 32'd1;
    localparam [22:0]  FCYC     = 23'd4_166_667;     // 与 top 一致

    reg clk = 0, rst = 1;
    always #5 clk = ~clk;                            // 100MHz

    reg play = 0, sd_ready = 0, fill_ready = 1'b1;
    reg scan_done = 0, egv_found = 0;
    reg [31:0] egv_lba = 32'd0;

    wire        o_sd_read;
    wire [31:0] o_sd_addr;
    wire [15:0] o_sd_count;
    reg  [7:0]  i_sd_data = 8'd0;
    reg         i_sd_data_valid = 1'b0;
    reg         i_sd_read_end = 1'b0;

    wire        o_pix_en;
    wire [15:0] o_pix;
    wire        o_frame_start, o_frame_end, o_fstart;
    wire        o_aud_en;
    wire [7:0]  o_aud_byte;
    wire [15:0] o_frame_no;
    wire        o_active;

    egv_reader #(.FRAME_CYC(FCYC), .LOOP_PLAY(1)) dut (
        .clk(clk), .rst(rst), .i_play(play), .i_fill_ready(fill_ready),
        .i_sd_ready(sd_ready), .i_scan_done(scan_done),
        .i_egv_found(egv_found), .i_egv_lba(egv_lba),
        .o_sd_read(o_sd_read), .o_sd_addr(o_sd_addr), .o_sd_count(o_sd_count),
        .i_sd_data(i_sd_data), .i_sd_data_valid(i_sd_data_valid),
        .i_sd_read_end(i_sd_read_end),
        .o_pix_en(o_pix_en), .o_pix(o_pix),
        .o_frame_start(o_frame_start), .o_aud_en(o_aud_en),
        .o_aud_byte(o_aud_byte), .o_aud_fstart(o_fstart),
        .o_frame_no(o_frame_no), .o_active(o_active)
    );

    // ---------------- 容器头 ----------------
    reg [7:0] hdr_mem [0:511];
    integer hh;
    task hdr_w32;
        input integer off;
        input [31:0]  v;
        begin
            hdr_mem[off]   = v[7:0];
            hdr_mem[off+1] = v[15:8];
            hdr_mem[off+2] = v[23:16];
            hdr_mem[off+3] = v[31:24];
        end
    endtask
    initial begin
        for (hh = 0; hh < 512; hh = hh + 1) hdr_mem[hh] = 8'h00;
        hdr_mem[0] = "E"; hdr_mem[1] = "G"; hdr_mem[2] = "V"; hdr_mem[3] = "1";
        hdr_mem[4] = 8'd2; hdr_mem[5] = 8'd0;
        hdr_mem[6] = `EGV_W & 8'hFF; hdr_mem[7] = (`EGV_W >> 8) & 8'hFF;
        hdr_mem[8] = `EGV_H & 8'hFF; hdr_mem[9] = (`EGV_H >> 8) & 8'hFF;
        hdr_mem[10] = `EGV_FPS;
        hdr_w32(12, NFRM);
        hdr_w32(16, BLOCK * 512);
        hdr_w32(20, `EGV_VIDEO_BYTES);
        hdr_w32(24, AUD_B);
        hdr_mem[28] = 8'h80; hdr_mem[29] = 8'hBB;
        hdr_mem[30] = 8'd2;
        hdr_w32(32, BLOCK);
        hdr_w32(34, AMOD);
        hdr_mem[40] = 8'd1; hdr_mem[41] = 8'd0;
        hdr_w32(48, 1 + NFRM*BLOCK);
        hdr_w32(52, DATA_LBA);
    end

    // ---------------- SD 扇区读模型（单段连续）----------------
    reg [31:0] cur;
    reg [8:0]  bcnt;
    reg        busy, started;
    reg [15:0] bleft;
    always @(posedge clk) begin
        i_sd_data_valid <= 1'b0;
        i_sd_read_end   <= 1'b0;
        if (rst) begin
            busy <= 1'b0; started <= 1'b0; bcnt <= 9'd0; cur <= 32'd0; bleft <= 16'd0;
        end else if (!o_sd_read) begin
            busy <= 1'b0; started <= 1'b0; bcnt <= 9'd0; bleft <= 16'd0;
        end else if (!busy) begin
            busy <= 1'b1; started <= 1'b0;
        end else if (!started) begin
            started <= 1'b1;
            bcnt    <= 9'd0;
            if (bleft == 16'd0) begin
                cur   <= o_sd_addr;
                bleft <= o_sd_count - 16'd1;
            end else begin
                cur   <= cur + 32'd1;
                bleft <= bleft - 16'd1;
            end
        end else begin
            i_sd_data       <= (cur == HDR_LBA) ? hdr_mem[bcnt] : (cur[7:0] + bcnt[7:0]);
            i_sd_data_valid <= 1'b1;
            if (bcnt == 9'd511) begin
                bcnt <= 9'd0; busy <= 1'b0; started <= 1'b0; i_sd_read_end <= 1'b1;
            end else
                bcnt <= bcnt + 9'd1;
        end
    end

    // ---------------- 帧间隔测量 ----------------
    integer cyc = 0;
    integer nfr = 0;
    integer last = -1;
    integer gaps [0:15];
    always @(posedge clk) begin
        if (!rst) cyc <= cyc + 1;
        if (!rst && o_frame_start) begin
            if (last >= 0) begin
                gaps[nfr] = cyc - last;
                $display("FRAME_START no=%0d  gap=%0d cycles  = %0.3f ms",
                         o_frame_no, cyc - last, (cyc - last) * 10.0 / 1000000.0);
            end else
                $display("FRAME_START no=%0d  (first)", o_frame_no);
            last <= cyc;
            nfr  <= nfr + 1;
        end
    end

    initial begin
        rst = 1;
        repeat (20) @(posedge clk);
        rst = 0;
        sd_ready  = 1;
        scan_done = 1;
        egv_found = 1;
        egv_lba   = HDR_LBA;
        repeat (50) @(posedge clk);
        play = 1;

        // 至少观察 NFRM 次帧起点：NFRM*FCYC + 余量
        #(NFRM * FCYC * 10 + 60_000_000);

        if (nfr >= NFRM) begin
            if (gaps[0] >= FCYC - 8 && gaps[0] <= FCYC + 64)
                $display("TB_FRAME_RATE PASS  gap=%0d  target=%0d", gaps[0], FCYC);
            else begin
                $display("TB_FRAME_RATE FAIL  gap=%0d  target=%0d  ratio=%0.3f",
                         gaps[0], FCYC, FCYC*1.0/gaps[0]);
            end
        end else
            $display("TB_FRAME_RATE FAIL  too few frames: %0d", nfr);
        $finish;
    end

    // 兜底超时
    initial begin
        #(NFRM * FCYC * 10 + 120_000_000);
        $display("TB_FRAME_RATE TIMEOUT nfr=%0d", nfr);
        $finish;
    end
endmodule
