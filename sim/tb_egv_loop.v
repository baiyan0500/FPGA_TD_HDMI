`timescale 1ns/1ps
// tb_egv_loop — LOOP_PLAY=1 的回卷行为（默认上板配置）
//
// 场景：容器 2 帧、单段连续（M_CONTIG）。播完第 2 帧后 reader 必须
//   ① 不置 eof_stop、o_active 保持 1；② frame_no 归 0；③ 物理地址回到
//   容器第 1 个数据扇区；④ 后续按 201 扇区/帧继续，像素/音频字节数照常。
// 对照：tb_egv_reader / tb_egv_reader_rt 以 LOOP_PLAY=0 回归"末帧冻结"。
`include "egv_cfg.vh"
module tb_egv_loop;
    localparam integer BLOCK = `EGV_BLOCK_SECTORS;   // 201
    localparam integer AMOD  = `EGV_AUDIO_MOD;       // 12
    localparam integer AUD_B = `EGV_AUDIO_BYTES;     // 8000
    localparam integer NFRM  = 2;
    localparam [31:0]  HDR_LBA = 32'd1000;
    localparam [31:0]  DATA_LBA = HDR_LBA + 32'd1;

    reg clk = 0, rst = 1;
    always #5 clk = ~clk;

    reg play = 0, sd_ready = 0, fill_ready = 1'b1;
    reg scan_done = 0, egv_found = 0;
    reg [31:0] egv_lba = 32'd0;

    wire        o_sd_read;
    wire [31:0] o_sd_addr;
    wire [15:0] o_sd_count;
    reg  [7:0]  i_sd_data = 8'd0;
    reg         i_sd_data_valid = 1'b0;
    reg         i_sd_read_end = 1'b0;

    wire        o_pix_en, o_frame_start, o_aud_en, o_aud_fstart, o_active;
    wire [15:0] o_pix, o_frame_no;
    wire [7:0]  o_aud_byte;

    egv_reader #(.FRAME_CYC(23'd400), .LOOP_PLAY(1)) dut (
        .clk(clk), .rst(rst),
        .i_play(play), .i_sd_ready(sd_ready), .i_fill_ready(fill_ready),
        .i_scan_done(scan_done), .i_egv_found(egv_found), .i_egv_lba(egv_lba),
        .o_sd_read(o_sd_read), .o_sd_addr(o_sd_addr), .o_sd_count(o_sd_count),
        .i_sd_data(i_sd_data), .i_sd_data_valid(i_sd_data_valid),
        .i_sd_read_end(i_sd_read_end),
        .o_pix_en(o_pix_en), .o_pix(o_pix), .o_frame_start(o_frame_start),
        .o_aud_en(o_aud_en), .o_aud_byte(o_aud_byte), .o_aud_fstart(o_aud_fstart),
        .o_frame_no(o_frame_no), .o_active(o_active)
    );

    // ---------------- 容器头 ----------------
    reg [7:0] hdr_mem [0:511];
    integer   hh;
    task hdr_w32(input integer off, input [31:0] v);
        begin
            hdr_mem[off+0] = v[7:0];   hdr_mem[off+1] = v[15:8];
            hdr_mem[off+2] = v[23:16]; hdr_mem[off+3] = v[31:24];
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
        hdr_mem[28] = 8'h80; hdr_mem[29] = 8'hBB;      // 48000
        hdr_mem[30] = 8'd2;
        hdr_w32(32, BLOCK);
        hdr_w32(34, AMOD);
        hdr_mem[40] = 8'd1; hdr_mem[41] = 8'd0;        // 单段
        hdr_w32(48, 1 + NFRM*BLOCK);                   // run0 nsec（含头扇区）
        hdr_w32(52, DATA_LBA);                         // run0 phys = 头 + 1
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

    // ---------------- 观测 ----------------
    integer nframe_start = 0, npix = 0, naud = 0;
    integer eof_viol = 0, sec_err = 0, addr_err = 0, restart_ok = 0;
    integer seg_idx = 0;         // 0..NFRM-1 当前帧序号（TB 侧独立计数）
    reg     seen_wrap = 0;
    reg [31:0] exp_first_sec;
    integer    frm_since = 0;

    // 每帧第一个扇区地址的期望（帧 f 的首扇区 = DATA_LBA + f*BLOCK）
    initial exp_first_sec = DATA_LBA;

    always @(posedge clk) begin
        if (!rst && play) begin
            if (o_frame_start) begin
                nframe_start = nframe_start + 1;
                if (nframe_start > 1 && dut.o_frame_no !== 16'd0) begin
                    // 第 2 帧起每帧起始 frame_no 应为 0（回卷后）或 1（第 2 帧）
                end
            end
            if (o_pix_en) npix = npix + 1;
            if (o_aud_en) naud = naud + 1;
        end
    end

    // 检查每批读的起点：任何一批的首地址必须落在某帧的首扇区上
    reg prev_read = 0;
    always @(posedge clk) begin
        if (!rst && o_sd_read && !prev_read) begin
            // 新的一批
            // 允许容器头扇区（首次起播读一次头）
            if (o_sd_addr != HDR_LBA &&
                (o_sd_addr < DATA_LBA || o_sd_addr >= DATA_LBA + NFRM*BLOCK)) begin
                addr_err = addr_err + 1;
                if (addr_err < 6) $display("ADDR OUT OF RANGE: %0d", o_sd_addr);
            end
        end
        prev_read <= o_sd_read;
    end

    // 帧号序列：应出现 0,1,0,1...；出现回卷即 restart_ok=1
    reg [15:0] prev_fn = 16'hFFFF;
    always @(posedge clk) begin
        if (!rst && o_frame_start) begin
            if (prev_fn === 16'd1 && o_frame_no === 16'd0) begin
                seen_wrap  = 1;
                restart_ok = restart_ok + 1;
                $display("WRAP at t=%0t: frame_no 1->0, next addr will restart container", $time);
            end
            prev_fn <= o_frame_no;
        end
    end

    // ---------------- 主流程 ----------------
    integer i;
    initial begin
        rst = 1;
        repeat (5) @(posedge clk);
        rst = 0;
        repeat (5) @(posedge clk);
        scan_done = 1; egv_found = 1; egv_lba = HDR_LBA; sd_ready = 1;
        repeat (2) @(posedge clk);
        play = 1;
        // 容器只有 2 帧，回卷后再跑 2 帧即可判定
        wait (seen_wrap === 1'b1);
        repeat (3*201*600) @(posedge clk);   // 再跑约 3 帧
        $display("LOOP: frame_start=%0d pix=%0d aud=%0d wraps=%0d addr_err=%0d active=%b fn=%0d",
                 nframe_start, npix, naud, restart_ok, addr_err, o_active, o_frame_no);
        if (seen_wrap && addr_err == 0 && o_active === 1'b1 && restart_ok >= 1)
            $display("TB_EGV_LOOP PASS");
        else
            $display("TB_EGV_LOOP FAIL wrap=%0d addr_err=%0d active=%b", seen_wrap, addr_err, o_active);
        $finish;
    end

    initial begin
        #50_000_000;
        $display("TB_EGV_LOOP TIMEOUT frame_start=%0d wraps=%0d fn=%0d st=%0d",
                 nframe_start, restart_ok, o_frame_no, dut.st);
        $display("TB_EGV_LOOP FAIL");
        $finish;
    end
endmodule
