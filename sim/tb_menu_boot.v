// ============================================================================
// tb_menu_boot — 上电全流程全协议验证（真实 sd_card_top + SPI 卡模型）
//
// 目的：复现上板症状「9 图找到不显示 + 视频 fram 00000」。
//   与 tb_bmp_cycle 的区别：SD 侧用真实 sd_card_top/sd_card_cmd/spi_master
//   + 位级 SPI 卡模型（tb_sd_timing 移植），协议栈（CMD17/CMD18/CMD12、
//   请求采样窗口、S_READ_WAIT2 地址锁存）全部走真实路径；
//   扫描修复后 WAV 客户端首次激活 → W_HDR/W_PLAY 与 BMP 装载的真实仲裁。
//
// 卡布局（SCAN_MAX=8192）：
//   BMP0@1280  BMP1@1536  EGV@4096(total=16MB→跳转越界→4KB步进)
//   WAV@5120(真实 1.wav，落在 EGV 容器跨度内，模拟实卡)  BMP2@7168
// 预期：img_count=3 wav_found=1 egv_found=1，首图提交，WAV 激活，
//       装载零 abort，无 grant 看门狗。
// ============================================================================
`timescale 1ns/1ps

module tb_menu_boot;

    reg clk = 0, rst = 1;
    always #5 clk = ~clk;              // 100MHz (sd_card_clk)

    // WAV FIFO 读时钟 ≈12.288MHz（100/8）
    reg clk_rd = 0;
    reg [2:0] rd_div = 0;
    always @(posedge clk) begin
        rd_div <= rd_div + 1'b1;
        if (rd_div == 3'd3) begin
            rd_div <= 0;
            clk_rd <= ~clk_rd;
        end
    end

    // ---------------- DUT ----------------
    reg         key_next = 1, key_auto = 0;
    wire        display_valid;
    wire [3:0]  state_code;
    wire [4:0]  img_count;
    wire        sd_ready, scan_done_o;
    wire [15:0] o_src_w_bcd, o_src_h_bcd;
    wire        o_src_tgl;
    reg         fade_swap = 0;
    wire        fade_req;
    wire [23:0] shown_bcd;
    wire        write_req, write_en;
    wire [31:0] write_data;
    wire        SD_nCS, SD_DCLK, SD_MOSI;
    wire        SD_MISO;
    reg         wav_pause = 0;
    reg         vp = 0;
    wire        wav_active;
    wire [32:0] wav_rate_step;
    wire        wav_stereo;
    wire        wav_fifo_rd_en, wav_fifo_empty;
    wire [15:0] wav_fifo_rd_data;
    wire        load_busy_ext;

    wire        bmp_fin_tgl, vf_fin_tgl;
    wire        write_req_ack;

    sd_card_bmp #(
        .CLK_FREQ_HZ       (100_000_000),
        .SCAN_START_SECTOR (32'd0),
        .SCAN_MAX_SECTOR   (32'd16384),
        .SCAN_TARGET_COUNT (5'd16)
    ) dut (
        .clk               (clk),
        .rst               (rst),
        .key_next          (key_next),
        .key_auto          (key_auto),
        .i_next_en         (1'b1),
        .bmp_width         (16'd640),
        .bmp_height        (16'd480),
        .display_valid     (display_valid),
        .state_code        (state_code),
        .img_count         (img_count),
        .sd_ready          (sd_ready),
        .scan_done_o       (scan_done_o),
        .o_src_w_bcd       (o_src_w_bcd),
        .o_src_h_bcd       (o_src_h_bcd),
        .o_src_tgl         (o_src_tgl),
        .write_finish_toggle(bmp_fin_tgl),
        .write_buf_idx     (),
        .disp_buf_idx      (),
        .fade_swap         (fade_swap),
        .fade_req          (fade_req),
        .shown_bcd         (shown_bcd),
        .write_req         (write_req),
        .write_req_ack     (write_req_ack),
        .write_en          (write_en),
        .write_data        (write_data),
        .SD_nCS            (SD_nCS),
        .SD_DCLK           (SD_DCLK),
        .SD_MOSI           (SD_MOSI),
        .SD_MISO           (SD_MISO),
        .wav_pause         (wav_pause),
        .wav_active        (wav_active),
        .wav_rate_step     (wav_rate_step),
        .wav_stereo        (wav_stereo),
        .wav_rd_clk        (clk_rd),
        .wav_fifo_rd_en    (wav_fifo_rd_en),
        .wav_fifo_rd_data  (wav_fifo_rd_data),
        .wav_fifo_empty    (wav_fifo_empty),
        .i_video_play      (vp),
        .i_egv_sd_read     (1'b0),
        .i_egv_sd_addr     (32'd0),
        .i_egv_sd_count    (16'd1),
        .o_cli_data_valid  (),
        .o_cli_data        (),
        .o_cli_read_end    (),
        .o_egv_found       (),
        .o_egv_start_sector(),
        .o_load_busy       (load_busy_ext)
    );

    // ---------------- 帧写模型 + wr_fin_split ----------------
    integer pix_cnt = 0;
    reg    wr_fin_pulse = 0;
    reg    wr_ack_pulse = 0;
    reg    wr_req_q = 0;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            wr_req_q     <= 1'b0;
            wr_ack_pulse <= 1'b0;
            wr_fin_pulse <= 1'b0;
            pix_cnt      <= 0;
        end else begin
            wr_ack_pulse <= write_req && !wr_req_q;   // 应答单拍
            wr_req_q     <= write_req;
            wr_fin_pulse <= 1'b0;
            if (write_req && !wr_req_q)
                pix_cnt <= 0;
            else if (write_en)
                pix_cnt <= pix_cnt + 1;
            if (write_en && pix_cnt == 307199) begin
                wr_fin_pulse <= 1'b1;
                pix_cnt      <= 0;
            end
        end
    end

    assign write_req_ack = wr_ack_pulse;

    wr_fin_split u_wr_fin_split (
        .clk         (clk),
        .rst         (rst),
        .i_owner     (vp),
        .i_wr_ack    (wr_ack_pulse),
        .i_wr_finish (wr_fin_pulse),
        .o_vf_tgl    (vf_fin_tgl),
        .o_bmp_tgl   (bmp_fin_tgl)
    );

    // ---------------- fade 模型 ----------------
    reg [1:0]  fade_req_s = 0;
    reg [15:0] fade_wait = 0;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            fade_req_s <= 2'd0; fade_swap <= 1'b0; fade_wait <= 16'd0;
        end else begin
            fade_req_s <= {fade_req_s[0], fade_req};
            if (fade_req_s[1] ^ fade_req_s[0])
                fade_wait <= 16'd300;
            else if (fade_wait != 16'd0) begin
                fade_wait <= fade_wait - 16'd1;
                if (fade_wait == 16'd1)
                    fade_swap <= ~fade_swap;
            end
        end
    end

    // ---------------- WAV FIFO 消费（≈44.1kHz word，12.5MHz 域）----------------
    reg [8:0] drain_cnt = 0;
    always @(posedge clk_rd or posedge rst) begin
        if (rst)
            drain_cnt <= 9'd0;
        else begin
            if (!wav_fifo_empty && drain_cnt == 9'd0)
                drain_cnt <= 9'd282;
            else if (drain_cnt != 9'd0)
                drain_cnt <= drain_cnt - 9'd1;
        end
    end
    assign wav_fifo_rd_en = (!wav_fifo_empty) && (drain_cnt == 9'd0);

    // =====================================================================
    // 卡镜像
    // =====================================================================
    localparam MEM_BYTES = 8*1024*1024;
    reg [7:0] sdm [0:MEM_BYTES-1];
    reg [7:0] fbuf [0:2*1024*1024-1];

    integer i, k, n;
    integer fd;
    integer abort_cnt = 0;
    integer gto_cnt = 0;

    task put32;                       // 小端写 4 字节
        input integer sec;
        input integer ofs;
        input [31:0] v;
        begin
            sdm[sec*512+ofs+0] = v[7:0];
            sdm[sec*512+ofs+1] = v[15:8];
            sdm[sec*512+ofs+2] = v[23:16];
            sdm[sec*512+ofs+3] = v[31:24];
        end
    endtask
    task put16;
        input integer sec;
        input integer ofs;
        input [15:0] v;
        begin
            sdm[sec*512+ofs+0] = v[7:0];
            sdm[sec*512+ofs+1] = v[15:8];
        end
    endtask

    // 生成小尺寸 24bit BMP（宽 w 高 h），像素数据用非零图案
    task make_bmp;
        input integer sec;
        input integer w;
        input integer h;
        integer row, col, idx;
        integer stride;
        begin
            sdm[sec*512+0] = "B"; sdm[sec*512+1] = "M";
            stride = ((w*3 + 3) / 4) * 4;
            put32(sec, 2, 54 + stride*h);      // file_len
            put32(sec, 10, 54);                // pixel offset
            put32(sec, 18, w);
            put32(sec, 22, h);
            put16(sec, 28, 24);                // bit_count
            put32(sec, 30, 0);                 // compression
            idx = 0;
            for (row = 0; row < h; row = row + 1)
                for (col = 0; col < stride; col = col + 1) begin
                    sdm[sec*512+54+idx] = (row*7 + col*13) & 8'hFF;
                    idx = idx + 1;
                end
        end
    endtask

    // ---------------- SPI 卡模型（tb_sd_timing 移植，数据源 sdm）----------------
    integer    lat       = 8;
    integer    dbg       = 0;
    reg [7:0]  rxbuf     = 8'h00;
    reg [2:0]  bitc      = 3'd0;
    reg [7:0]  txb       = 8'hFF;
    reg [2:0]  ph        = 3'd0;
    reg [2:0]  cmd_bytes = 3'd0;
    reg [47:0] cmdq      = 48'd0;
    reg [31:0] cur_lba   = 32'd0;
    integer    tok_wait  = 0;
    integer    dleft     = 0;
    integer    didx      = 0;
    reg [3:0]  init_tries = 4'd0;
    reg        is_read   = 1'b0;
    reg        is_stream = 1'b0;

    // 卡片数据输出延迟 tODLY（见 tb_sd_timing 同处注释）
    wire #15 SD_MISO_d;
    assign SD_MISO_d = txb[7];
    assign SD_MISO   = SD_MISO_d;

    always @(negedge SD_nCS) bitc <= 3'd0;
    always @(posedge SD_nCS) begin
        ph  <= 3'd0;
        txb <= 8'hFF;
    end

    always @(posedge SD_DCLK) if (!SD_nCS) begin
        rxbuf <= {rxbuf[6:0], SD_MOSI};
        if (bitc == 3'd7) begin
            bitc <= 3'd0;
            handle_byte({rxbuf[6:0], SD_MOSI});
        end else
            bitc <= bitc + 3'd1;
    end

    always @(negedge SD_DCLK) if (!SD_nCS && bitc != 3'd0)
        txb <= {txb[6:0], 1'b1};

    task handle_byte(input [7:0] b);
        begin
            if (dbg > 0) $display("[%0t] RX %02x ph=%0d", $time, b, ph);
            case (ph)
            3'd0: begin
                if (b[7:6] == 2'b01) begin
                    if (is_stream && b[5:0] != 6'd12) begin
                        txb = 8'h00;      // 流未终止：DO 只有数据残留
                    end else begin
                        ph        = 3'd1;
                        cmd_bytes = 3'd1;
                        cmdq      = {b, 40'd0};
                        txb       = 8'hFF;
                    end
                end
            end
            3'd1: begin
                case (cmd_bytes)
                    3'd1: cmdq[39:32] = b;
                    3'd2: cmdq[31:24] = b;
                    3'd3: cmdq[23:16] = b;
                    3'd4: cmdq[15:8]  = b;
                    3'd5: begin
                        cmdq[7:0] = b;
                        do_cmd(cmdq);
                        ph = 3'd2;
                    end
                    default: ;
                endcase
                cmd_bytes = cmd_bytes + 3'd1;
            end
            3'd2: begin
                if (is_read) begin
                    tok_wait = lat;
                    if (tok_wait <= 0) begin
                        ph    = 3'd4;
                        txb   = 8'hFE;
                        dleft = 514;
                        didx  = 0;
                    end else begin
                        ph  = 3'd3;
                        txb = 8'hFF;
                    end
                end else begin
                    ph  = 3'd0;
                    txb = 8'hFF;
                end
            end
            3'd3: begin
                tok_wait = tok_wait - 1;
                if (tok_wait <= 0) begin
                    ph    = 3'd4;
                    txb   = 8'hFE;
                    dleft = 514;
                    didx  = 0;
                end else
                    txb = 8'hFF;
            end
            3'd4: begin
                if (b == 8'h4C && is_stream) begin
                    ph        = 3'd1;
                    cmd_bytes = 3'd1;
                    cmdq      = {b, 40'd0};
                    txb       = 8'hFF;
                end else if (dleft == 0) begin
                    if (is_stream) begin
                        cur_lba = cur_lba + 32'd1;
                        txb     = 8'hFE;
                        dleft   = 514;
                        didx    = 0;
                    end else begin
                        ph  = 3'd0;
                        txb = 8'hFF;
                    end
                end else begin
                    if (didx < 512)
                        txb = sdm[cur_lba*512 + didx];
                    else
                        txb = 8'hFF;
                    didx  = didx + 1;
                    dleft = dleft - 1;
                end
            end
            default: ph = 3'd0;
            endcase
        end
    endtask

    task do_cmd(input [47:0] c);
        reg [5:0] op;
        begin
            op = c[45:40];
            if (dbg > 0) $display("[%0t] CMD %0d arg=%08x", $time, op, c[39:8]);
            is_read   = 1'b0;
            is_stream = 1'b0;
            case (op)
                6'd0 : txb = 8'h01;
                6'd8 : txb = 8'h01;
                6'd55: txb = 8'h01;
                6'd41: begin
                    init_tries = init_tries + 4'd1;
                    txb = (init_tries >= 4'd2) ? 8'h00 : 8'h01;
                end
                6'd16: txb = 8'h00;
                6'd12: txb = 8'h00;
                6'd17: begin
                    txb     = 8'h00;
                    is_read = 1'b1;
                    cur_lba = c[39:8];
                end
                6'd18: begin
                    txb       = 8'h00;
                    is_read   = 1'b1;
                    is_stream = 1'b1;
                    cur_lba   = c[39:8];
                end
                default: txb = 8'hFF;
            endcase
        end
    endtask

    // ---------------- 事件记录 ----------------
    always @(posedge clk) begin
        if (!rst && dut.load_abort) begin
            abort_cnt = abort_cnt + 1;
            $display("[%0t] LOAD ABORT idx=%0d (state=%0d grant_wav=%b wav_st=%0d)",
                     $time, dut.load_idx, dut.bmp_read_m0.state,
                     dut.grant_wav, dut.u_sd_card_wav.state);
        end
        if (!rst && dut.wav_grant_timeout) begin
            gto_cnt = gto_cnt + 1;
            $display("[%0t] WAV GRANT WATCHDOG (wav_st=%0d wav_rd_busy=%b)",
                     $time, dut.u_sd_card_wav.state, dut.wav_rd_busy);
        end
    end

    // 周期快照：装载/WAV 运行期间每 100us 打一行
    reg [19:0] snap_cnt = 0;
    integer dv_cnt = 0, end_cnt = 0;
    always @(posedge clk) begin
        if (!rst) begin
            snap_cnt <= snap_cnt + 1'b1;
            if (dut.grant_wav) begin
                if (dut.sd_sec_read_data_valid) dv_cnt <= dv_cnt + 1'b1;
                if (dut.sd_sec_read_end)         end_cnt <= end_cnt + 1'b1;
            end
            if (snap_cnt == 20'd100_000) begin
                snap_cnt <= 0;
                if (dut.load_busy || dut.grant_wav)
                    $display("[%0t] SNAP ld=%b st=%0d sc=%0d | gw=%b wst=%0d ffc=%0d wb=%b wrb=%b | pb=%0d dseen=%b wrd=%b wadr=%0d sdst=%0d dv=%0d end=%0d",
                             $time, dut.load_busy, dut.bmp_read_m0.state,
                             dut.bmp_read_m0.sd_sec_read_addr,
                             dut.grant_wav, dut.u_sd_card_wav.state,
                             dut.u_sd_card_wav.fifo_count,
                             dut.bmp_rd_busy, dut.wav_rd_busy,
                             dut.u_sd_card_wav.pbyte, dut.u_sd_card_wav.data_seen,
                             dut.u_sd_card_wav.sd_sec_read,
                             dut.u_sd_card_wav.sd_sec_addr,
                             dut.sd_card_top_m0.sd_card_sec_read_write_m0.state,
                             dv_cnt, end_cnt);
                    dv_cnt  = 0;
                    end_cnt = 0;
            end
        end
    end

    // ---------------- 主流程 ----------------
    integer errors = 0;
    initial begin
        for (i = 0; i < MEM_BYTES; i = i + 1) sdm[i] = 8'h00;

        // 卡布局
        make_bmp(1280, 64, 48);                    // BMP0
        make_bmp(1536, 80, 60);                    // BMP1
        sdm[4096*512+0] = "E";                     // EGV1 容器头（跨度越界）
        sdm[4096*512+1] = "G";
        sdm[4096*512+2] = "V";
        sdm[4096*512+3] = "1";
        put32(4096, 36, 32'h0100_0000);            // total_bytes = 16MB

        // WAV@5120：真实文件（覆盖 EGV 跨度内部，模拟实卡布局）
        fd = $fopen("../src/user_source/hdl_source/python/1.wav", "rb");
        if (fd == 0) begin
            $display("OPEN WAV FAIL");
            errors = errors + 1;
        end else begin
            n = $fread(fbuf, fd);
            $fclose(fd);
            for (i = 0; i < n; i = i + 1)
                sdm[5120*512 + i] = fbuf[i];
            $display("WAV: %0d bytes @5120", n);
        end

        make_bmp(12288, 96, 72);                   // BMP2（WAV 跳转之后才扫到）

        // 复位 → 初始化
        rst = 1;
        repeat (20) @(posedge clk);
        rst = 0;
        wait (sd_ready === 1'b1);
        $display("[%0t] SD init done", $time);

        // ---- 扫描 ----
        k = 0;
        while (!scan_done_o && k < 40_000_000) begin @(posedge clk); k = k + 1; end
        $display("[%0t] SCAN done=%b cycles=%0d imgs=%0d wav=%b egv=%b (t=%0t)",
                 $time, scan_done_o, k, img_count,
                 dut.bmp_read_m0.wav_found, dut.bmp_read_m0.egv_found, $time);
        if (!scan_done_o) begin
            $display(">>> HANG in scan (sector=%0d)", dut.bmp_read_m0.scan_sector);
            errors = errors + 1;
        end
        if (img_count !== 3)  begin $display(">>> BAD img_count=%0d", img_count); errors = errors + 1; end
        if (dut.bmp_read_m0.wav_found !== 1'b1) begin $display(">>> BAD wav_found"); errors = errors + 1; end
        if (dut.bmp_read_m0.egv_found !== 1'b1) begin $display(">>> BAD egv_found"); errors = errors + 1; end

        // ---- 首图 ----
        k = 0;
        while (!display_valid && k < 40_000_000) begin @(posedge clk); k = k + 1; end
        if (!display_valid) begin
            $display(">>> HANG: first image never committed");
            $display("    bmp state=%0d load_busy=%b sd_read=%b addr=%0d wr_req=%b src=%0dx%0d",
                     dut.bmp_read_m0.state, dut.load_busy, dut.sd_sec_read,
                     dut.sd_sec_read_addr, dut.write_req,
                     dut.bmp_read_m0.width, dut.bmp_read_m0.height);
            $display("    grant_wav=%b wav_st=%0d fifo=%0d wb=%b wrb=%b pix=%0d fin=%b wd=%b",
                     dut.grant_wav, dut.u_sd_card_wav.state,
                     dut.u_sd_card_wav.fifo_count, dut.bmp_rd_busy, dut.wav_rd_busy,
                     pix_cnt, dut.source_done_seen, dut.write_done_seen);
            errors = errors + 1;
        end else begin
            $display("[%0t] FIRST image committed idx=%0d wav_active=%b", $time, dut.img_idx, wav_active);
        end
        if (wav_active !== 1'b1) begin
            $display(">>> BAD wav_active=%b (wav_st=%0d)", wav_active, dut.u_sd_card_wav.state);
            errors = errors + 1;
        end

        // ---- 继续跑 3ms：WAV 补水 + K2 切图 2 次 ----
        repeat (300_000) @(posedge clk);
        for (i = 0; i < 2; i = i + 1) begin
            @(negedge clk);
            force dut.next_req_pending = 1'b1;
            // 保持足够久：切图完成后的前几拍 cand_idle[2] 尚未稳定，
            // 请求需保持到装载分支真正消费它（真实硬件里 678 行会锁存）
            repeat (60) @(posedge clk);
            release dut.next_req_pending;
            dut.next_req_pending = 1'b0;
            repeat (10) @(posedge clk);     // 等 FSM 把请求锁进 load_busy
            k = 0;
            while ((dut.load_busy || dut.swap_pending) && k < 40_000_000) begin
                @(posedge clk); k = k + 1;
            end
            if (k >= 40_000_000) begin
                $display(">>> HANG at image switch %0d (state=%0d grant=%b wav=%0d fifo=%0d)",
                         i, dut.bmp_read_m0.state, dut.grant_wav,
                         dut.u_sd_card_wav.state, dut.u_sd_card_wav.fifo_count);
                errors = errors + 1;
            end else
                $display("[%0t] SWITCH ok idx=%0d (pend=%b bmp_rdy=%b cand=%b dv=%b vpq=%b busy=%b swp=%b)",
                         $time, dut.img_idx, dut.next_req_pending, dut.bmp_ready,
                         dut.cand_ok, dut.display_valid, dut.vp_q,
                         dut.load_busy, dut.swap_pending);
        end
        repeat (300_000) @(posedge clk);

        if (dut.img_idx !== 2'd2) begin
            $display(">>> BAD final img_idx=%0d (expect 2)", dut.img_idx);
            errors = errors + 1;
        end
        if (abort_cnt != 0) begin $display(">>> BAD abort_cnt=%0d", abort_cnt); errors = errors + 1; end
        if (gto_cnt  != 0) begin $display(">>> BAD wav_grant_timeout=%0d", gto_cnt); errors = errors + 1; end

        if (errors == 0)
            $display("TB_MENU_BOOT PASS (imgs=%0d, wav_active=%b)", img_count, wav_active);
        else
            $display("TB_MENU_BOOT FAIL errors=%0d", errors);
        $finish;
    end

    initial begin
        #400_000_000;   // 400ms 硬超时
        $display("TB_MENU_BOOT TIMEOUT: st=%0d scan=%0d ld=%0d gw=%b wst=%0d ffc=%0d",
                 dut.bmp_read_m0.state, dut.bmp_read_m0.scan_sector, dut.load_busy,
                 dut.grant_wav, dut.u_sd_card_wav.state, dut.u_sd_card_wav.fifo_count);
        $finish;
    end

endmodule
