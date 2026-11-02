`timescale 1ns/1ps
// tb_egv_reader_rt — 运行时容器头解析 / 段表回退（SW3 花屏回归）
//
// A) 非基准 LBA 的 3 段合法头（第 4 段槽为 0）→ M_RT，按头内段表播放。
//    旧版无条件校验 run3 的 nsec，3 段容器被误判成坏头 → 永远回退过期
//    编译期段表，是 SW3 花屏的直接原因。本阶段是核心回归用例。
// B) 魔数错误 → M_NONE，绝不读数据扇区（黑屏而不是花屏）。
// C) 字段合法但 run0 物理起点 ≠ 发现 LBA+1（文件被搬走）→ M_CONTIG，
//    从发现 LBA+1 起按整文件连续回退。
// D) 扫描未发现 EGV，但编译期 LBA 处仍能读到原容器头 → 探针 → M_RT。
// E) 4 段段表，run3 生效（验证段表满深度装载）。
// F) 魔数正确但字段损坏且在编译期 LBA → 回退编译期段表 M_CONST。
//
// 数据模式：扇区内第 i 字节 = (phys + i) & 0xFF，便于独立复算像素/音频。
`include "egv_cfg.vh"
module tb_egv_reader_rt;
    localparam integer BLOCK = `EGV_BLOCK_SECTORS;   // 201
    localparam integer AMOD  = `EGV_AUDIO_MOD;       // 12
    localparam integer AUD_B = `EGV_AUDIO_BYTES;     // 8000
    localparam integer A_FRAMES = 3;
    localparam [31:0]  RT_LBA   = 32'd600000;
    localparam [19:0]  RUN_MAX  = 20'hFFFFF;

    localparam [31:0] H_W   = `EGV_W;
    localparam [31:0] H_H   = `EGV_H;
    localparam [31:0] H_FPS = `EGV_FPS;
    localparam [31:0] H_VB  = `EGV_VIDEO_BYTES;
    localparam [31:0] H_AB  = `EGV_AUDIO_BYTES;

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

    // LOOP_PLAY=0：本 TB 回归的是"末帧冻结 + K1 重播"，循环播放另由 tb_egv_loop 覆盖
    egv_reader #(.FRAME_CYC(23'd210), .LOOP_PLAY(0)) dut (
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
    integer run_nsec [0:7];
    integer run_phys [0:7];
    integer hi;

    task wr32;
        input integer off;
        input [31:0] v;
        begin
            hdr_mem[off+0] = v[7:0];
            hdr_mem[off+1] = v[15:8];
            hdr_mem[off+2] = v[23:16];
            hdr_mem[off+3] = v[31:24];
        end
    endtask

    task build_hdr;
        input integer bad_magic;
        input integer bad_field;
        input integer nruns;
        input integer frames;
        integer i, b;
        begin
            for (hi = 0; hi < 512; hi = hi + 1) hdr_mem[hi] = 8'h00;
            hdr_mem[0] = bad_magic ? "X" : "E";
            hdr_mem[1] = "G"; hdr_mem[2] = "V"; hdr_mem[3] = "1";
            hdr_mem[4] = 8'd2; hdr_mem[5] = 8'd0;              // ver=2
            wr32(6,  bad_field ? (H_W + 32'd1) : H_W);
            wr32(8,  H_H);
            wr32(10, H_FPS);
            wr32(12, frames);
            wr32(16, BLOCK * 512);                             // block_bytes
            wr32(20, H_VB);
            wr32(24, H_AB);
            hdr_mem[28] = 8'h80; hdr_mem[29] = 8'hBB;          // 48000
            hdr_mem[30] = 8'd2;  hdr_mem[31] = 8'd0;           // ach=2
            wr32(32, BLOCK);
            wr32(34, AMOD);
            hdr_mem[40] = nruns[7:0]; hdr_mem[41] = nruns[15:8];
            // 未用槽位写 0：真实 3 段容器就是这样（旧版误判为坏头的直接诱因）
            for (i = 0; i < 8; i = i + 1) begin
                b = 44 + i * 12;
                if (i < nruns) begin
                    wr32(b + 0, i * 100);                      // logical（不校验）
                    wr32(b + 4, run_nsec[i]);
                    wr32(b + 8, run_phys[i]);
                end else begin
                    wr32(b + 0, 0);
                    wr32(b + 4, 0);
                    wr32(b + 8, 0);
                end
            end
        end
    endtask

    // ---------------- 期望模型（活动段表）----------------
    integer m_n = 0;
    integer m_len [0:7];
    integer m_phys[0:7];

    function [31:0] exp_phys;
        input integer g;
        integer k, gg;
        begin
            gg = g;
            exp_phys = 32'hDEAD_BEEF;
            k = 0;
            while ((k < m_n) && (exp_phys == 32'hDEAD_BEEF)) begin
                if (gg < m_len[k])
                    exp_phys = m_phys[k] + gg;
                else begin
                    gg = gg - m_len[k];
                    k  = k + 1;
                end
            end
        end
    endfunction

    function [15:0] exp_cnt;
        input integer g;
        integer k, gg, rem, br;
        begin
            gg = g; k = 0; rem = 0;
            while (k < m_n) begin
                if (gg < m_len[k]) begin
                    rem = m_len[k] - gg;
                    k   = m_n;
                end else begin
                    gg = gg - m_len[k];
                    k  = k + 1;
                end
            end
            br = BLOCK - (g % BLOCK);
            exp_cnt = (rem < br) ? rem : br;
        end
    endfunction

    // ---------------- SD 扇区读模型（CMD18 流式：批内自增）---------------
    reg [31:0] cur;
    reg [8:0]  bcnt;
    reg        busy, started;
    reg [15:0] bleft;
    reg        next_is_hdr = 1'b0;
    reg        in_hdr = 1'b0;

    integer gsec = 0;
    integer hdr_reads = 0;
    integer addr_err = 0, cnt_err = 0, hdr_err = 0;
    integer pix_err = 0, aud_err = 0, seq_err = 0;

    always @(posedge clk) begin
        i_sd_data_valid <= 1'b0;
        i_sd_read_end   <= 1'b0;
        if (rst) begin
            busy <= 1'b0; started <= 1'b0; bcnt <= 9'd0; cur <= 32'd0;
            bleft <= 16'd0; in_hdr <= 1'b0;
        end else if (!o_sd_read) begin
            busy <= 1'b0; started <= 1'b0; bcnt <= 9'd0; bleft <= 16'd0;
        end else if (!busy) begin
            busy <= 1'b1; started <= 1'b0;
        end else if (!started) begin
            started <= 1'b1;
            bcnt    <= 9'd0;
            if (bleft == 16'd0) begin
                if (next_is_hdr) begin
                    if ((o_sd_addr !== hdr_lba_cur) || (o_sd_count !== 16'd1)) begin
                        $display("HDR ERR: addr=%0d exp=%0d count=%0d",
                                 o_sd_addr, hdr_lba_cur, o_sd_count);
                        hdr_err = hdr_err + 1;
                    end
                    hdr_reads   = hdr_reads + 1;
                    next_is_hdr = 1'b0;
                    in_hdr      = 1'b1;
                end else begin
                    if (o_sd_addr !== exp_phys(gsec)) begin
                        if (cnt_err < 8)
                            $display("BATCH ADDR ERR g=%0d got %0d exp %0d",
                                     gsec, o_sd_addr, exp_phys(gsec));
                        cnt_err = cnt_err + 1;
                    end
                    // CMD18 批读：批长 = min(段剩余, 帧剩余)
                    if (o_sd_count !== exp_cnt(gsec)) begin
                        if (cnt_err < 8)
                            $display("BATCH CNT ERR g=%0d got %0d exp %0d",
                                     gsec, o_sd_count, exp_cnt(gsec));
                        cnt_err = cnt_err + 1;
                    end
                    in_hdr = 1'b0;
                end
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
                if (in_hdr) begin
                    in_hdr <= 1'b0;
                end else begin
                    if (cur !== exp_phys(gsec)) begin
                        if (addr_err < 8)
                            $display("ADDR ERR g=%0d got %0d exp %0d",
                                     gsec, cur, exp_phys(gsec));
                        addr_err = addr_err + 1;
                    end
                    gsec = gsec + 1;
                end
            end else
                bcnt <= bcnt + 9'd1;
        end
    end

    // ---------------- 帧内容统计 ----------------
    integer npix = 0, naud = 0;
    integer pix_in_frame = 0, aud_in_frame = 0;
    integer frames_done = 0;
    reg [15:0] pix_first [0:7];
    reg [7:0]  aud_mem [0:15999];
    reg        collect = 1'b0;
    reg        check_pix = 1'b0;
    reg        chk_frames = 1'b0;
    reg [15:0] fno_q = 16'd0;

    always @(posedge clk) begin
        if (rst) begin
            fno_q <= 16'd0;
        end else begin
            if (collect) begin
                if (o_pix_en) begin
                    if (npix < 8) pix_first[npix] <= o_pix;
                    npix = npix + 1;
                    pix_in_frame = pix_in_frame + 1;
                end
                if (o_aud_en) begin
                    if (naud < 16000) aud_mem[naud] = o_aud_byte;
                    naud = naud + 1;
                    aud_in_frame = aud_in_frame + 1;
                end
            end
            // 帧尾最后一字节与 o_frame_no 同拍更新，故计数与判帧统一延后一拍
            if (chk_frames && (o_frame_no !== fno_q)) begin
                frames_done = frames_done + 1;
                if (check_pix) begin
                    if (pix_in_frame != `EGV_W * `EGV_H) begin
                        $display("FAIL pix count %0d (frame %0d)",
                                 pix_in_frame, frames_done);
                        pix_err = pix_err + 1;
                    end
                    if (aud_in_frame != AUD_B) begin
                        $display("FAIL aud count %0d (frame %0d)",
                                 aud_in_frame, frames_done);
                        aud_err = aud_err + 1;
                    end
                end
                pix_in_frame = 0;
                aud_in_frame = 0;
            end
            fno_q <= o_frame_no;
        end
    end

    // 头解析结果调试（hdr_done 上升沿打印一次）
    reg dbg_q = 1'b0;
    always @(posedge clk) begin
        dbg_q <= dut.hdr_done;
        if (!rst && dut.hdr_done && !dbg_q)
            $display("DBG hdr: frames=%0d nruns=%0d len=(%0d,%0d,%0d) rp=(%0d,%0d,%0d) sum=%0d exp=%0d bad=%b phys0=%b",
                     dut.h_frames, dut.h_nruns,
                     dut.rt_len[0], dut.rt_len[1], dut.rt_len[2],
                     dut.rt_rp[0], dut.rt_rp[1], dut.rt_rp[2],
                     dut.rt_sum, dut.expect_secs, dut.hdr_bad, dut.phys0_ok);
    end

    // ---------------- 阶段控制 ----------------
    integer k, n, vs, off, gi;
    reg [31:0] ep;
    reg [7:0]  ehi, elo;
    integer i;

    task do_reset;
        begin
            play = 0; sd_ready = 0; scan_done = 0;
            egv_found = 0; egv_lba = 0;
            rst = 1;
            repeat (10) @(posedge clk);
            gsec = 0; hdr_reads = 0; frames_done = 0;
            npix = 0; naud = 0; pix_in_frame = 0; aud_in_frame = 0;
            collect = 0; check_pix = 0; chk_frames = 0;
            next_is_hdr = 0; in_hdr = 0;
            rst = 0;
            repeat (3) @(posedge clk);
        end
    endtask

    initial begin
        // ================= A) 3 段运行时头 → M_RT =================
        do_reset;
        hdr_lba_cur = RT_LBA;
        run_nsec[0] = 11;  run_phys[0] = RT_LBA;
        run_nsec[1] = 100; run_phys[1] = 32'd700000;
        run_nsec[2] = 493; run_phys[2] = 32'd800000;
        build_hdr(0, 0, 3, A_FRAMES);
        m_n = 3;
        m_len[0] = 10;   m_phys[0] = RT_LBA + 32'd1;
        m_len[1] = 100;  m_phys[1] = 32'd700000;
        m_len[2] = 493;  m_phys[2] = 32'd800000;
        check_pix = 1; collect = 1; chk_frames = 1;
        egv_found = 1; egv_lba = RT_LBA;
        sd_ready = 1;
        next_is_hdr = 1;
        play = 1;

        // 扫描未完成：不得起播（EGV 位置未知）
        repeat (100) @(posedge clk);
        if (o_sd_read || o_active) begin
            $display("FAIL A: started before scan_done");
            seq_err = seq_err + 1;
        end
        scan_done = 1;
        wait (hdr_reads == 1);
        wait (dut.hdr_done == 1'b1);
        repeat (3) @(posedge clk);
        if (dut.mode_sel !== 2'd1 || dut.hdr_done !== 1'b1 || dut.hdr_bad !== 1'b0) begin
            $display("FAIL A hdr: mode=%0d done=%b bad=%b (expect M_RT, no bad)",
                     dut.mode_sel, dut.hdr_done, dut.hdr_bad);
            seq_err = seq_err + 1;
        end

        wait (o_frame_no == A_FRAMES);
        repeat (20) @(posedge clk);
        if (o_active || !dut.eof_stop) begin
            $display("FAIL A eof: active=%b eof_stop=%b", o_active, dut.eof_stop);
            seq_err = seq_err + 1;
        end
        if (frames_done != A_FRAMES) begin
            $display("FAIL A: frames_done=%0d (expect %0d)", frames_done, A_FRAMES);
            seq_err = seq_err + 1;
        end

        // 第 0 帧前 8 像素：第 n 像素来自视频扇区 n/256 的 2*(n%256) 字节
        for (k = 0; k < 8; k = k + 1) begin
            vs  = k / 256;
            off = (k % 256) * 2;
            gi  = (vs / (AMOD - 1)) * AMOD + (vs % (AMOD - 1));
            ep  = exp_phys(gi);
            ehi = ep[7:0] + off[7:0];
            elo = ehi + 8'd1;
            if (pix_first[k] !== {ehi, elo}) begin
                $display("FAIL pix %0d got %h exp %h", k, pix_first[k], {ehi, elo});
                pix_err = pix_err + 1;
            end
        end
        // 第 0 帧前 16 音频字节：来自帧内第 11 个扇区
        ep = exp_phys(11);
        for (k = 0; k < 16; k = k + 1) begin
            ehi = ep[7:0] + k[7:0];
            if (aud_mem[k] !== ehi) begin
                $display("FAIL aud %0d got %h exp %h", k, aud_mem[k], ehi);
                aud_err = aud_err + 1;
            end
        end

        // 重播：必须重读头（换卡/重新封装无需复位即可生效），段表沿用 M_RT
        play = 0;
        collect = 0; check_pix = 0; chk_frames = 0;
        repeat (10) @(posedge clk);
        gsec = 0; hdr_reads = 0;
        next_is_hdr = 1;
        play = 1;
        wait (hdr_reads == 1);
        wait (dut.hdr_done == 1'b1);
        repeat (3) @(posedge clk);
        if (dut.mode_sel !== 2'd1 || dut.hdr_done !== 1'b1) begin
            $display("FAIL A restart: mode=%0d done=%b", dut.mode_sel, dut.hdr_done);
            seq_err = seq_err + 1;
        end
        wait (gsec >= 1);            // 首批数据扇区已读，地址/批大小由模型核对
        play = 0;
        wait (o_active == 0);
        repeat (10) @(posedge clk);

        // ================= B) 魔数错误 → M_NONE =================
        do_reset;
        hdr_lba_cur = RT_LBA;
        run_nsec[0] = 11;  run_phys[0] = RT_LBA;
        run_nsec[1] = 100; run_phys[1] = 32'd700000;
        run_nsec[2] = 493; run_phys[2] = 32'd800000;
        build_hdr(1, 0, 3, A_FRAMES);
        m_n = 3;
        m_len[0] = 10;  m_phys[0] = RT_LBA + 32'd1;
        m_len[1] = 100; m_phys[1] = 32'd700000;
        m_len[2] = 493; m_phys[2] = 32'd800000;
        collect = 1; chk_frames = 0;
        egv_found = 1; egv_lba = RT_LBA;
        sd_ready = 1; scan_done = 1;
        next_is_hdr = 1;
        play = 1;
        wait (hdr_reads == 1);
        wait (dut.hdr_done == 1'b1);
        repeat (5) @(posedge clk);
        if (dut.mode_sel !== 2'd3 || dut.hdr_done !== 1'b1) begin
            $display("FAIL B: mode=%0d done=%b (expect M_NONE)",
                     dut.mode_sel, dut.hdr_done);
            seq_err = seq_err + 1;
        end
        repeat (200) @(posedge clk);
        if (o_sd_read || o_active || (gsec != 0) || (npix != 0) || (naud != 0)) begin
            $display("FAIL B: read/play leaked (read=%b active=%b gsec=%0d pix=%0d aud=%0d)",
                     o_sd_read, o_active, gsec, npix, naud);
            seq_err = seq_err + 1;
        end
        play = 0;

        // ================= C) run0 起点不符 → M_CONTIG =================
        do_reset;
        hdr_lba_cur = RT_LBA;
        run_nsec[0] = 101; run_phys[0] = 32'd500000;   // 头内旧地址，文件已被搬走
        run_nsec[1] = 101; run_phys[1] = 32'd810000;
        build_hdr(0, 0, 2, 1);
        m_n = 1;
        m_len[0] = 201; m_phys[0] = RT_LBA + 32'd1;
        chk_frames = 1;
        egv_found = 1; egv_lba = RT_LBA;
        sd_ready = 1; scan_done = 1;
        next_is_hdr = 1;
        play = 1;
        wait (hdr_reads == 1);
        wait (dut.hdr_done == 1'b1);
        repeat (3) @(posedge clk);
        if (dut.mode_sel !== 2'd2 || dut.hdr_done !== 1'b1) begin
            $display("FAIL C: mode=%0d done=%b (expect M_CONTIG)",
                     dut.mode_sel, dut.hdr_done);
            seq_err = seq_err + 1;
        end
        wait (o_frame_no == 1);
        repeat (20) @(posedge clk);
        if (o_active || !dut.eof_stop) begin
            $display("FAIL C eof: active=%b eof_stop=%b", o_active, dut.eof_stop);
            seq_err = seq_err + 1;
        end
        play = 0;

        // ================= D) 扫描未发现，编译期 LBA 探针 → M_RT =========
        do_reset;
        hdr_lba_cur = `EGV_BASE_LBA;
        run_nsec[0] = 202; run_phys[0] = `EGV_BASE_LBA;
        build_hdr(0, 0, 1, 1);
        m_n = 1;
        m_len[0] = 201; m_phys[0] = `EGV_BASE_LBA + 32'd1;
        chk_frames = 1;
        egv_found = 0; egv_lba = 32'd0;
        sd_ready = 1; scan_done = 1;
        next_is_hdr = 1;
        play = 1;
        wait (hdr_reads == 1);
        wait (dut.hdr_done == 1'b1);
        repeat (3) @(posedge clk);
        if (dut.mode_sel !== 2'd1 || dut.hdr_done !== 1'b1) begin
            $display("FAIL D: mode=%0d done=%b (expect M_RT via probe)",
                     dut.mode_sel, dut.hdr_done);
            seq_err = seq_err + 1;
        end
        wait (o_frame_no == 1);
        repeat (20) @(posedge clk);
        if (o_active || !dut.eof_stop) begin
            $display("FAIL D eof: active=%b eof_stop=%b", o_active, dut.eof_stop);
            seq_err = seq_err + 1;
        end
        play = 0;

        // ================= E) 4 段表，run3 生效 → M_RT =================
        //（段表深度已从 8 裁到 4：验证最后一段装载与跨段边界）
        do_reset;
        hdr_lba_cur = RT_LBA;
        run_nsec[0] = 2; run_phys[0] = RT_LBA;
        for (i = 1; i < 3; i = i + 1) begin
            run_nsec[i] = 1;
            run_phys[i] = RT_LBA + i * 10000;
        end
        run_nsec[3] = 399;
        run_phys[3] = RT_LBA + 30000;
        build_hdr(0, 0, 4, 2);
        m_n = 4;
        for (i = 0; i < 3; i = i + 1) m_len[i] = 1;
        m_len[3] = 399;
        m_phys[0] = RT_LBA + 32'd1;                  // 仅 run0 含头扇区偏移
        for (i = 1; i < 4; i = i + 1)
            m_phys[i] = RT_LBA + i * 10000;          // run i≥1 起点即头内地址
        chk_frames = 1;
        egv_found = 1; egv_lba = RT_LBA;
        sd_ready = 1; scan_done = 1;
        next_is_hdr = 1;
        play = 1;
        wait (hdr_reads == 1);
        wait (dut.hdr_done == 1'b1);
        repeat (3) @(posedge clk);
        if (dut.mode_sel !== 2'd1 || dut.hdr_done !== 1'b1 || dut.hdr_bad !== 1'b0) begin
            $display("FAIL E: mode=%0d done=%b bad=%b (expect M_RT)",
                     dut.mode_sel, dut.hdr_done, dut.hdr_bad);
            seq_err = seq_err + 1;
        end
        wait (o_frame_no == 2);
        repeat (20) @(posedge clk);
        if (o_active || !dut.eof_stop) begin
            $display("FAIL E eof: active=%b eof_stop=%b", o_active, dut.eof_stop);
            seq_err = seq_err + 1;
        end
        play = 0;

        // ================= F) 字段损坏 + 编译期 LBA → M_CONST =================
        do_reset;
        hdr_lba_cur = `EGV_BASE_LBA;
        run_nsec[0] = 256;    run_phys[0] = `EGV_BASE_LBA;
        run_nsec[1] = 385024; run_phys[1] = `EGV_RP1;
        run_nsec[2] = 2249;   run_phys[2] = `EGV_RP2;
        build_hdr(0, 1, 3, `EGV_FRAMES);           // 魔数对、宽度字段错
        m_n = 3;
        m_len[0] = 255;     m_phys[0] = `EGV_RP0;
        m_len[1] = 385024;  m_phys[1] = `EGV_RP1;
        m_len[2] = RUN_MAX; m_phys[2] = `EGV_RP2;
        chk_frames = 1;
        egv_found = 0; egv_lba = 32'd0;
        sd_ready = 1; scan_done = 1;
        next_is_hdr = 1;
        play = 1;
        wait (hdr_reads == 1);
        wait (dut.hdr_done == 1'b1);
        repeat (3) @(posedge clk);
        if (dut.mode_sel !== 2'd0 || dut.hdr_done !== 1'b1) begin
            $display("FAIL F: mode=%0d done=%b (expect M_CONST)",
                     dut.mode_sel, dut.hdr_done);
            seq_err = seq_err + 1;
        end
        wait (o_frame_no == 2);                    // 跨过 run0→run1 边界（g=255）
        repeat (20) @(posedge clk);
        if (!o_active || dut.eof_stop) begin       // 头部帧数 1928，2 帧时必须仍在播
            $display("FAIL F: stopped early (active=%b eof=%b)",
                     o_active, dut.eof_stop);
            seq_err = seq_err + 1;
        end
        play = 0;

        repeat (20) @(posedge clk);
        $display("addr_err=%0d cnt_err=%0d hdr_err=%0d pix_err=%0d aud_err=%0d seq_err=%0d",
                 addr_err, cnt_err, hdr_err, pix_err, aud_err, seq_err);
        if (addr_err == 0 && cnt_err == 0 && hdr_err == 0 &&
            pix_err == 0 && aud_err == 0 && seq_err == 0)
            $display("TB_EGV_READER_RT PASS");
        else
            $display("TB_EGV_READER_RT FAIL");
        $finish;
    end

    initial begin
        #60_000_000;
        $display("TB_EGV_READER_RT TIMEOUT (gsec=%0d frame_no=%0d st=%0d)",
                 gsec, o_frame_no, dut.st);
        $finish;
    end
endmodule
