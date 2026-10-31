`timescale 1ns/1ps
// 验证 egv_reader 的运行时容器头路径（bug2：段表过期 → 图像错位/音频噪声）
//   A) 合法 4 段头：按头内段表/帧数播放，8 帧后 EOF；重播不重复读头
//   B) 魔数错误：回退编译期段表（旧行为）
//   C) 魔数正确但 run0 物理起点 ≠ 发现 LBA（文件被拷走）：同样回退
// 数据模式：扇区内第 i 字节 = (phys + i) & 0xFF，便于独立复算。
`include "egv_cfg.vh"
module tb_egv_reader_rt;
    localparam integer BLOCK     = `EGV_BLOCK_SECTORS;   // 201
    localparam integer AMOD      = `EGV_AUDIO_MOD;       // 12
    localparam integer AUD_B     = `EGV_AUDIO_BYTES;     // 8000
    localparam [31:0]  RT_LBA    = 32'd600000;
    localparam integer RT_FRAMES = 8;

    localparam [15:0] H_W   = `EGV_W;
    localparam [15:0] H_H   = `EGV_H;
    localparam [15:0] H_FPS = `EGV_FPS;
    localparam [31:0] H_VB  = `EGV_VIDEO_BYTES;
    localparam [31:0] H_AB  = `EGV_AUDIO_BYTES;
    localparam [15:0] H_BS  = `EGV_BLOCK_SECTORS;
    localparam [15:0] H_AM  = `EGV_AUDIO_MOD;

    reg clk = 0, rst = 1;
    reg play = 0, sd_ready = 0;
    reg fill_ready = 1'b1;
    reg scan_done = 1'b0, egv_found = 1'b0;
    reg [31:0] egv_lba = 32'd0;

    wire        o_sd_read;
    wire [31:0] o_sd_addr;
    wire [15:0] o_sd_count;
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
        .i_fill_ready(fill_ready),
        .i_scan_done(scan_done), .i_egv_found(egv_found), .i_egv_lba(egv_lba),
        .o_sd_read(o_sd_read), .o_sd_addr(o_sd_addr), .o_sd_count(o_sd_count),
        .i_sd_data(i_sd_data), .i_sd_data_valid(i_sd_data_valid),
        .i_sd_read_end(i_sd_read_end),
        .o_pix_en(o_pix_en), .o_pix(o_pix), .o_frame_start(o_frame_start),
        .o_aud_en(o_aud_en), .o_aud_byte(o_aud_byte), .o_aud_fstart(o_aud_fstart),
        .o_frame_no(o_frame_no), .o_active(o_active)
    );

    always #5 clk = ~clk;

    // ---------------- 容器头（512B，布局见 tools/video/mp4_to_egv.py）-----
    reg [7:0]  hdr_mem [0:511];
    reg [31:0] hdr_lba_cur = RT_LBA;
    integer hi;
    reg [31:0] t32;

    task set_run;
        input integer idx;
        input integer logical;
        input integer nsec;
        input [31:0] phys;
        integer b;
        begin
            b = 44 + idx * 12;
            t32 = logical;
            hdr_mem[b+0] = t32[7:0];  hdr_mem[b+1] = t32[15:8];
            hdr_mem[b+2] = t32[23:16]; hdr_mem[b+3] = t32[31:24];
            t32 = nsec;
            hdr_mem[b+4] = t32[7:0];  hdr_mem[b+5] = t32[15:8];
            hdr_mem[b+6] = t32[23:16]; hdr_mem[b+7] = t32[31:24];
            hdr_mem[b+8] = phys[7:0]; hdr_mem[b+9] = phys[15:8];
            hdr_mem[b+10] = phys[23:16]; hdr_mem[b+11] = phys[31:24];
        end
    endtask

    task build_hdr;
        input integer bad_magic;
        input integer bad_phys;
        input integer frames;
        begin
            for (hi = 0; hi < 512; hi = hi + 1) hdr_mem[hi] = 8'h00;
            hdr_mem[0] = (bad_magic != 0) ? "X" : "E";
            hdr_mem[1] = "G"; hdr_mem[2] = "V"; hdr_mem[3] = "1";
            hdr_mem[4] = 8'd2; hdr_mem[5] = 8'd0;                  // ver=2
            hdr_mem[6] = H_W[7:0];   hdr_mem[7] = H_W[15:8];
            hdr_mem[8] = H_H[7:0];   hdr_mem[9] = H_H[15:8];
            hdr_mem[10]= H_FPS[7:0]; hdr_mem[11]= H_FPS[15:8];
            t32 = frames;
            hdr_mem[12]= t32[7:0]; hdr_mem[13]= t32[15:8];
            hdr_mem[14]= t32[23:16]; hdr_mem[15]= t32[31:24];
            t32 = H_BS * 512;                                       // block_bytes
            hdr_mem[16]= t32[7:0]; hdr_mem[17]= t32[15:8];
            hdr_mem[18]= t32[23:16]; hdr_mem[19]= t32[31:24];
            t32 = H_VB;
            hdr_mem[20]= t32[7:0]; hdr_mem[21]= t32[15:8];
            hdr_mem[22]= t32[23:16]; hdr_mem[23]= t32[31:24];
            t32 = H_AB;
            hdr_mem[24]= t32[7:0]; hdr_mem[25]= t32[15:8];
            hdr_mem[26]= t32[23:16]; hdr_mem[27]= t32[31:24];
            hdr_mem[28]= 8'h80; hdr_mem[29]= 8'hBB;                 // 48000
            hdr_mem[30]= 8'd2;  hdr_mem[31]= 8'd0;                  // ach=2
            hdr_mem[32]= H_BS[7:0]; hdr_mem[33]= H_BS[15:8];
            hdr_mem[34]= H_AM[7:0]; hdr_mem[35]= H_AM[15:8];
            hdr_mem[40]= 8'd4;  hdr_mem[41]= 8'd0;                  // n_runs=4
            set_run(0,   0,   11, (bad_phys != 0) ? 32'd500000 : hdr_lba_cur);
            set_run(1,  11,  490, 32'd700000);
            set_run(2, 501,  200, 32'd800000);
            set_run(3, 701, 100000, 32'd900000);
        end
    endtask

    // ---------------- SD 扇区读模型（CMD18 流式：批内自增）---------------
    reg [31:0] cur;
    reg [8:0]  bcnt;
    reg        busy, started;
    reg [15:0] bleft;

    always @(posedge clk) begin
        i_sd_data_valid <= 1'b0;
        i_sd_read_end   <= 1'b0;
        if (rst) begin
            busy <= 1'b0; started <= 1'b0; bcnt <= 9'd0; cur <= 32'd0;
            bleft <= 16'd0;
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
            i_sd_data       <= (cur == hdr_lba_cur) ? hdr_mem[bcnt] :
                               (cur[7:0] + bcnt[7:0]);
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

    // ---------------- 期望模型 ----------------
    integer rmode = 1;        // 1=运行时段表；0=编译期常量
    integer gsec = 0;
    reg     hdr_phase = 1'b1;
    integer hdr_reads = 0;
    integer addr_err = 0, cnt_err = 0, pix_err = 0, aud_err = 0;
    integer eof_err = 0, reread_err = 0;

    function [31:0] exp_phys(input integer g);
        begin
            if (rmode == 1) begin
                if (g < 10)       exp_phys = RT_LBA + 32'd1 + g;
                else if (g < 500) exp_phys = 32'd700000 + (g - 10);
                else if (g < 700) exp_phys = 32'd800000 + (g - 500);
                else              exp_phys = 32'd900000 + (g - 700);
            end else begin
                if (g < `EGV_RG1)      exp_phys = `EGV_RP0 + g;
                else if (g < `EGV_RG2) exp_phys = `EGV_RP1 + (g - `EGV_RG1);
                else                   exp_phys = `EGV_RP2 + (g - `EGV_RG2);
            end
        end
    endfunction

    function [15:0] exp_cnt(input integer g);
        integer rl, fl;
        begin
            if (rmode == 1) begin
                if (g < 10)       rl = 10 - g;
                else if (g < 500) rl = 500 - g;
                else if (g < 700) rl = 700 - g;
                else              rl = 1000000;
            end else begin
                if (g < `EGV_RG1)      rl = `EGV_RG1 - g;
                else if (g < `EGV_RG2) rl = `EGV_RG2 - g;
                else                   rl = 1000000;
            end
            fl = BLOCK - (g % BLOCK);
            exp_cnt = (rl < fl) ? rl[15:0] : fl[15:0];
        end
    endfunction

    // 批起点：段/帧边界与批大小必须与期望一致
    always @(posedge clk) begin
        if (!rst && !hdr_phase && busy && !started && o_sd_read && (bleft == 16'd0)) begin
            if (o_sd_count !== exp_cnt(gsec)) begin
                if (cnt_err < 8)
                    $display("CNT ERR g=%0d got %0d exp %0d", gsec, o_sd_count, exp_cnt(gsec));
                cnt_err = cnt_err + 1;
            end
            if (o_sd_addr !== exp_phys(gsec)) begin
                if (cnt_err < 8)
                    $display("BATCH ADDR ERR g=%0d got %0d exp %0d",
                             gsec, o_sd_addr, exp_phys(gsec));
                cnt_err = cnt_err + 1;
            end
        end
    end

    // 逐扇区地址核对；头扇区单独确认（1 扇区、地址=发现 LBA）
    always @(posedge clk) begin
        if (!rst && i_sd_read_end) begin
            if (hdr_phase) begin
                if (cur !== hdr_lba_cur || o_sd_count !== 16'd1) begin
                    $display("HDR ERR: addr=%0d count=%0d", cur, o_sd_count);
                    addr_err = addr_err + 1;
                end
                hdr_reads = hdr_reads + 1;
                hdr_phase = 1'b0;
                gsec      = 0;
            end else begin
                if (cur !== exp_phys(gsec)) begin
                    if (addr_err < 8)
                        $display("ADDR ERR g=%0d got %0d exp %0d",
                                 gsec, cur, exp_phys(gsec));
                    addr_err = addr_err + 1;
                end
                gsec = gsec + 1;
            end
        end
    end

    // 头扇区只允许读一次（重播不得重复读）
    always @(posedge clk) begin
        if (!rst && !hdr_phase && o_sd_read && (o_sd_addr == RT_LBA) &&
            (o_sd_count == 16'd1)) begin
            $display("FAIL: header re-read t=%0t", $time);
            reread_err = reread_err + 1;
        end
    end

    // ---------------- 像素/音频/帧统计 ----------------
    integer npix = 0, naud = 0;
    integer pix_in_frame = 0, aud_in_frame = 0;
    integer frames_done = 0, total_frames = 0;
    reg [7:0] aud_mem [0:15999];
    reg [15:0] pix_first [0:7];

    always @(posedge clk) begin
        if (!rst && o_pix_en) begin
            if (npix < 8) pix_first[npix] <= o_pix;
            npix = npix + 1;
            pix_in_frame = pix_in_frame + 1;
        end
        if (!rst && o_aud_en) begin
            if (naud < 16000) aud_mem[naud] = o_aud_byte;
            naud = naud + 1;
            aud_in_frame = aud_in_frame + 1;
        end
    end

    reg        chk_on = 1'b0;
    reg [15:0] frame_no_q = 16'd0;
    reg        frame_done_d = 1'b0;

    always @(posedge clk) begin
        if (rst) begin
            frame_no_q   <= 16'd0;
            frame_done_d <= 1'b0;
        end else begin
            frame_done_d <= chk_on && (o_frame_no == (frame_no_q + 16'd1));
            frame_no_q   <= o_frame_no;
        end
    end

    // 帧结束延迟一拍核对，避免与末字节计数同拍竞争
    always @(posedge clk) begin
        if (!rst && frame_done_d) begin
            frames_done  = frames_done + 1;
            total_frames = total_frames + 1;
            if (pix_in_frame != `EGV_W * `EGV_H) begin
                $display("FAIL pix count %0d (frame %0d)", pix_in_frame, frames_done);
                pix_err = pix_err + 1;
            end
            if (aud_in_frame != AUD_B) begin
                $display("FAIL aud count %0d (frame %0d)", aud_in_frame, frames_done);
                aud_err = aud_err + 1;
            end
            pix_in_frame = 0;
            aud_in_frame = 0;
        end
    end

    // ---------------- 主流程 ----------------
    integer k, n, vs, off, gi;
    reg [31:0] ep;
    reg [7:0] exp_hi, exp_lo;

    initial begin
        build_hdr(0, 0, RT_FRAMES);           // 阶段 A：合法 4 段头
        repeat (5) @(posedge clk);
        rst = 0;
        repeat (5) @(posedge clk);
        sd_ready = 1;
        egv_found = 1;
        egv_lba   = RT_LBA;
        play      = 1;
        // 扫描未完成：不得起播（此时 EGV 位置未知）
        repeat (200) @(posedge clk);
        if (o_sd_read || o_active) begin
            $display("FAIL: started before scan_done");
            eof_err = eof_err + 1;
        end
        scan_done = 1;

        // ---- 阶段 A：运行时 4 段表 / 8 帧 ----
        wait (hdr_phase == 1'b0);
        repeat (5) @(posedge clk);
        if (dut.rt_ok !== 1'b1 || dut.hdr_done !== 1'b1 || dut.hdr_bad !== 1'b0) begin
            $display("FAIL A hdr: rt_ok=%b hdr_done=%b hdr_bad=%b",
                     dut.rt_ok, dut.hdr_done, dut.hdr_bad);
            $display("  DBG frames=%0d nruns=%0d rp0=%0d rp1=%0d rp2=%0d rp3=%0d",
                     dut.h_frames, dut.h_nruns, dut.rt_rp0, dut.rt_rp1,
                     dut.rt_rp2, dut.rt_rp3);
            $display("  DBG len0=%0d len1=%0d len2=%0d len3=%0d fr_ok=%b nr_ok=%b phy0_ok=%b",
                     dut.rt_len0, dut.rt_len1, dut.rt_len2, dut.rt_len3,
                     dut.frames_ok, dut.nruns_ok, dut.phys0_ok);
            eof_err = eof_err + 1;
        end
        chk_on = 1;
        wait (frames_done >= RT_FRAMES);
        repeat (50) @(posedge clk);
        if (o_active || !dut.eof_stop) begin
            $display("FAIL A eof: active=%b eof_stop=%b", o_active, dut.eof_stop);
            eof_err = eof_err + 1;
        end
        if (o_frame_no !== RT_FRAMES) begin
            $display("FAIL A eof: frame_no=%0d (expect %0d)", o_frame_no, RT_FRAMES);
            eof_err = eof_err + 1;
        end
        k = 0;
        while (k < 2000) begin
            @(posedge clk);
            if (o_sd_read) begin
                $display("FAIL A eof: still reading sector");
                eof_err = eof_err + 1;
                k = 4000;
            end
            k = k + 1;
        end

        // 首帧前 8 像素：第 n 像素来自视频扇区 n/256 的 2*(n%256) 字节
        for (k = 0; k < 8; k = k + 1) begin
            n   = k;
            vs  = n / 256;
            off = (n % 256) * 2;
            gi  = (vs / (AMOD - 1)) * AMOD + (vs % (AMOD - 1));
            ep  = exp_phys(gi);
            exp_hi = ep[7:0] + off[7:0];
            exp_lo = exp_hi + 8'd1;
            if (pix_first[n] !== {exp_hi, exp_lo}) begin
                $display("FAIL pix %0d got %h exp %h", n, pix_first[n], {exp_hi, exp_lo});
                pix_err = pix_err + 1;
            end
        end

        // 首帧前 16 个音频字节：来自帧内 g=11 的 0..15 字节
        for (k = 0; k < 16; k = k + 1) begin
            ep = exp_phys(11 + (k / 512) * AMOD);
            exp_hi = ep[7:0] + k[7:0];
            if (aud_mem[k] !== exp_hi) begin
                $display("FAIL aud %0d got %h exp %h", k, aud_mem[k], exp_hi);
                aud_err = aud_err + 1;
            end
        end

        if (hdr_reads !== 1) begin
            $display("FAIL A: hdr_reads=%0d", hdr_reads);
            eof_err = eof_err + 1;
        end

        // 重播：不得重新读头，段表沿用运行时解析结果
        play = 0;
        repeat (10) @(posedge clk);
        gsec = 0;
        npix = 0; naud = 0;
        pix_in_frame = 0; aud_in_frame = 0;
        play = 1;
        wait (frames_done >= RT_FRAMES + 1);
        repeat (5) @(posedge clk);
        if (hdr_reads !== 1 || dut.rt_ok !== 1'b1) begin
            $display("FAIL A restart: hdr_reads=%0d rt_ok=%b", hdr_reads, dut.rt_ok);
            eof_err = eof_err + 1;
        end

        // ---- 阶段 B：魔数错误 → 回退编译期段表 ----
        play = 0;
        rst  = 1;
        repeat (10) @(posedge clk);
        build_hdr(1, 0, RT_FRAMES);
        rmode = 0;
        gsec = 0; npix = 0; naud = 0;
        pix_in_frame = 0; aud_in_frame = 0;
        frames_done = 0; chk_on = 0; hdr_phase = 1; hdr_reads = 0;
        egv_found = 1; egv_lba = RT_LBA; scan_done = 0;
        repeat (5) @(posedge clk);
        rst = 0;
        repeat (5) @(posedge clk);
        sd_ready = 1;
        play = 1;
        repeat (100) @(posedge clk);
        if (o_sd_read || o_active) begin
            $display("FAIL B: started before scan_done");
            eof_err = eof_err + 1;
        end
        scan_done = 1;
        wait (hdr_phase == 1'b0);
        repeat (5) @(posedge clk);
        if (dut.rt_ok !== 1'b0 || dut.hdr_done !== 1'b1) begin
            $display("FAIL B hdr: rt_ok=%b hdr_done=%b (expect fallback)",
                     dut.rt_ok, dut.hdr_done);
            eof_err = eof_err + 1;
        end
        chk_on = 1;
        wait (frames_done >= 2);
        repeat (10) @(posedge clk);

        // ---- 阶段 C：魔数正确但 run0 起点与发现 LBA 不符 → 回退 ----
        play = 0;
        rst  = 1;
        repeat (10) @(posedge clk);
        build_hdr(0, 1, RT_FRAMES);
        rmode = 0;
        gsec = 0; npix = 0; naud = 0;
        pix_in_frame = 0; aud_in_frame = 0;
        frames_done = 0; chk_on = 0; hdr_phase = 1; hdr_reads = 0;
        egv_found = 1; egv_lba = RT_LBA; scan_done = 0;
        repeat (5) @(posedge clk);
        rst = 0;
        repeat (5) @(posedge clk);
        sd_ready = 1;
        play = 1;
        scan_done = 1;
        wait (hdr_phase == 1'b0);
        repeat (5) @(posedge clk);
        if (dut.rt_ok !== 1'b0 || dut.hdr_done !== 1'b1) begin
            $display("FAIL C hdr: rt_ok=%b hdr_done=%b (expect fallback)",
                     dut.rt_ok, dut.hdr_done);
            eof_err = eof_err + 1;
        end
        chk_on = 1;
        wait (frames_done >= 1);
        repeat (10) @(posedge clk);

        $display("addr_err=%0d cnt_err=%0d pix_err=%0d aud_err=%0d eof_err=%0d reread=%0d frames=%0d",
                 addr_err, cnt_err, pix_err, aud_err, eof_err, reread_err,
                 total_frames);
        if (addr_err == 0 && cnt_err == 0 && pix_err == 0 && aud_err == 0 &&
            eof_err == 0 && reread_err == 0 && total_frames >= RT_FRAMES + 3)
            $display("TB_EGV_READER_RT PASS");
        else
            $display("TB_EGV_READER_RT FAIL");
        $finish;
    end

    initial begin
        #400_000_000;
        $display("TB_EGV_READER_RT TIMEOUT (frames=%0d gsec=%0d)", total_frames, gsec);
        $finish;
    end
endmodule
