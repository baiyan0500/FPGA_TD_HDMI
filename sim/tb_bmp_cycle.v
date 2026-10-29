`timescale 1ns/1ps
// 整链轮播验证：sd_card_bmp（bmp_read + scaler + sd_card_wav + 仲裁器）
//   + 行为级 sd_card_top（扇区读模型，可注入"丢请求"故障）
//   + 帧写模型（307200 像素后发 write_finish_toggle）
//   + fade 模型（fade_req 边沿 → 延迟后 fade_swap）
//
// 覆盖：16 项图片表扫描、连续多张切换（高分辨率 1024x577 + 640x480 混合）、
//       WAV 补水与图片装载的总线竞争、源尺寸 BCD 输出、装载超时/授予看门狗恢复。
//
// 注意：本文件末尾自带行为级 sd_card_top（同名），编译时**不要**再编译
//       src/user_source/hdl_source/SD/sd_card_top.v，否则会覆盖模型。
//
// 运行：
//   vsim -c work.tb_bmp_cycle -do "run -all; quit" \
//        +IMG1=F:/01_1.bmp +IMG2=F:/02_2.bmp +IMG3=F:/03_3.bmp \
//        +IMG4=F:/00_00_00_1_640x480.bmp ... +WAV=F:/a_sample-3s.wav [+DROP=<sector>]
module tb_bmp_cycle;

    reg clk = 0, rst = 1;
    always #5 clk = ~clk;              // 100MHz

    // ---------------- DUT ----------------
    reg        key_next = 1, key_auto = 0;
    wire       display_valid;
    wire [3:0] state_code;
    wire [4:0] img_count;
    wire       sd_ready, scan_done_o;
    wire [15:0] o_src_w_bcd, o_src_h_bcd;
    wire        o_src_tgl;
    reg         write_finish_toggle = 0;
    wire [1:0]  write_buf_idx, disp_buf_idx;
    reg         fade_swap = 0;
    wire        fade_req;
    wire [23:0] shown_bcd;
    wire        load_busy_ext;
    wire        write_req, write_en;
    wire [31:0] write_data;
    wire        SD_nCS, SD_DCLK, SD_MOSI;
    reg         SD_MISO = 1;
    reg         wav_pause = 0;
    reg         vp = 0;                  // 视频层独占请求（模拟 layer3 进入/退出）
    integer     abort_cnt = 0;           // 装载被看门狗放弃的次数（交接测试要求为 0）
    // 行为级 SD 卡核的扇区流状态（声明提前，供交接测试任务引用）
    reg         be_busy = 0;
    reg  [31:0] be_addr = 0;
    integer     be_idx = 0;
    reg  [3:0]  be_startup = 0;
    reg  [1:0]  be_cool = 0;
    wire        sd_mux_read = dut.sd_sec_read_mux;
    wire [31:0] sd_mux_addr = dut.sd_sec_addr_mux;
    wire        wav_active;
    wire [32:0] wav_rate_step;
    wire        wav_stereo;
    wire        wav_fifo_rd_en, wav_fifo_empty;
    wire [15:0] wav_fifo_rd_data;

    reg         write_req_ack = 0;
    reg  [31:0] drop_sector = 32'hFFFF_FFFF;
    integer     drop_hits = 0;
    reg         sd_init_done_be = 0;
    reg  [7:0]  be_data = 0;
    reg         be_dv = 0, be_end = 0;

    sd_card_bmp #(
        .CLK_FREQ_HZ       (100_000_000),
        .SCAN_START_SECTOR (32'd0),
        .SCAN_MAX_SECTOR   (32'd60000),
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
        .write_finish_toggle(write_finish_toggle),
        .write_buf_idx     (write_buf_idx),
        .disp_buf_idx      (disp_buf_idx),
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
        .wav_rd_clk        (clk),
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
        .o_load_busy       (load_busy_ext)
    );

    // ---------------- 帧写模型（frame_fifo_write / SDRAM 行为级）----------------
    integer pix_cnt = 0;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            write_req_ack <= 1'b0;
            write_finish_toggle <= 1'b0;
            pix_cnt <= 0;
        end else begin
            // ack 保持到 write_req 撤销（与真实 ext_mem 域一致）
            write_req_ack <= write_req;
            if (write_req && !write_req_ack)
                pix_cnt <= 0;
            else if (write_en)
                pix_cnt <= pix_cnt + 1;
            if (pix_cnt == 307199) begin
                write_finish_toggle <= ~write_finish_toggle;
                pix_cnt <= 0;
            end
        end
    end

    // ---------------- fade 模型 ----------------
    reg [1:0]  fade_req_s = 0;
    reg [15:0] fade_wait = 0;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            fade_req_s <= 2'd0; fade_swap <= 1'b0; fade_wait <= 16'd0;
        end else begin
            fade_req_s <= {fade_req_s[0], fade_req};
            if (fade_req_s[1] ^ fade_req_s[0])
                fade_wait <= 16'd300;          // 简化：固定 300 拍后回 ack
            else if (fade_wait != 16'd0) begin
                fade_wait <= fade_wait - 16'd1;
                if (fade_wait == 16'd1)
                    fade_swap <= ~fade_swap;
            end
        end
    end

    // ---------------- WAV FIFO 消费（≈44.1kHz 立体声量级）----------------
    reg [9:0] drain_div = 0;
    always @(posedge clk) drain_div <= drain_div + 10'd1;
    assign wav_fifo_rd_en = !wav_fifo_empty && (drain_div == 10'd0);

    // ---------------- 调试：bmp_read 退出装载态时的计数 ----------------
    reg [2:0] br_state_q = 0;
    integer n_valid = 0, n_wr = 0, n_fifowr = 0, n_drop = 0, fifo_max = 0;
    always @(posedge clk) begin
        if (!rst) begin
            if (dut.bmp_read_m0.bmp_data_valid) n_valid = n_valid + 1;
            if (dut.bmp_data_wr_en)             n_wr = n_wr + 1;
            if (dut.u_scaler.fifo_wr)           n_fifowr = n_fifowr + 1;
            if (dut.u_scaler.src_en && (dut.u_scaler.fifo_cnt >= 512)) n_drop = n_drop + 1;
            if (dut.u_scaler.fifo_cnt > fifo_max) fifo_max = dut.u_scaler.fifo_cnt;

            br_state_q <= dut.bmp_read_m0.state;
            if (br_state_q == 3'd4 && dut.bmp_read_m0.state != 3'd4) begin
                $display("  [bmp] exit LOAD_DATA state=%0d pix_row=%0d len=%0d file=%0d h=%0d row_bytes=%0d (t=%0t)",
                         dut.bmp_read_m0.state, dut.bmp_read_m0.pix_row,
                         dut.bmp_read_m0.bmp_len_cnt, dut.bmp_read_m0.file_len,
                         dut.bmp_read_m0.height, dut.bmp_read_m0.row_bytes, $time);
                $display("  [cnt] valid=%0d wr_en=%0d fifo_wr=%0d fifo_drop=%0d fifo_max=%0d",
                         n_valid, n_wr, n_fifowr, n_drop, fifo_max);
                n_valid = 0; n_wr = 0; n_fifowr = 0; n_drop = 0; fifo_max = 0;
            end
        end
    end

    // =====================================================================
    // 镜像装载
    // =====================================================================
    localparam MEM_BYTES = 32*1024*1024;
    reg  [7:0]  sdm [0:MEM_BYTES-1];
    reg  [7:0]  fbuf [0:2*1024*1024-1];

    reg [1023:0] path;
    integer      fd, n, i, k;
    integer      next_sector;
    integer      start_sector = 1280;   // +START=<sector> 模拟大 FAT 区（数据区起始靠后）
    integer      wav_gap = 12000;       // +WAVGAP=<sector>
    integer      img_start [0:15];
    integer      img_bytes [0:15];
    integer      img_w     [0:15];
    integer      img_h     [0:15];
    integer      img_n = 0;
    integer      wav_start = -1;

    task add_file;
        input [1023:0] p;
        input integer is_wav;
        begin
            fd = $fopen(p, "rb");
            if (fd == 0) begin
                $display("OPEN FAIL %0s", p);
            end else begin
                n = $fread(fbuf, fd);
                $fclose(fd);
                next_sector = (next_sector + 7) & ~7;      // 4KB 簇边界对齐
                for (i = 0; i < n; i = i + 1)
                    sdm[next_sector * 512 + i] = fbuf[i];
                if (is_wav) begin
                    wav_start = next_sector;
                    $display("WAV : sector=%0d bytes=%0d", next_sector, n);
                end else if (img_n < 16) begin
                    img_start[img_n] = next_sector;
                    img_bytes[img_n] = n;
                    img_w[img_n] = fbuf[18] + fbuf[19]*256 + fbuf[20]*65536 + fbuf[21]*16777216;
                    img_h[img_n] = fbuf[22] + fbuf[23]*256 + fbuf[24]*65536 + fbuf[25]*16777216;
                    $display("IMG%0d: sector=%0d bytes=%0d %0dx%0d",
                             img_n, next_sector, n, img_w[img_n], img_h[img_n]);
                    img_n = img_n + 1;
                end
                next_sector = next_sector + (n + 511) / 512;
            end
        end
    endtask

    // ---------------- 行为检查 ----------------
    integer errors = 0;
    integer prev_idx = 0;
    integer carousel_cnt = 0;

    // 十进制数值 → 4 位 BCD（千/百/十/个）
    function [15:0] bcd16;
        input integer v;
        begin
            bcd16 = (((v / 1000) % 10) << 12) |
                    (((v / 100)  % 10) << 8)  |
                    (((v / 10)   % 10) << 4)  |
                     ((v)         % 10);
        end
    endfunction

    task check_image;
        input integer expect_size;
        begin
            // 等 load_busy 起来（press_next 后 1~2 拍）
            k = 0;
            while (!dut.load_busy && k < 200) begin @(posedge clk); k = k + 1; end
            // 等装载 + 淡入完成
            k = 0;
            while ((dut.load_busy || dut.swap_pending) && k < 40_000_000) begin
                @(posedge clk); k = k + 1;
            end
            repeat (20) @(posedge clk);
            if (dut.load_busy || dut.swap_pending) begin
                $display(">>> HANG: load_busy=%b swap_pending=%b fail_valid=%b idx=%0d",
                         dut.load_busy, dut.swap_pending, dut.fail_valid, dut.img_idx);
                $display("    bmp_read state=%0d sd_read=%b addr=%0d write_req=%b ack=%b src=%0dx%0d",
                         dut.bmp_read_m0.state, dut.sd_sec_read, dut.sd_sec_read_addr,
                         dut.write_req, dut.write_req_ack, dut.src_width, dut.src_height);
                $display("    scaler state=%0d rd_x=%0d dst_x=%0d src_row=%0d fifo_cnt=%0d almost_full=%b",
                         dut.u_scaler.state, dut.u_scaler.rd_x, dut.u_scaler.dst_x,
                         dut.u_scaler.src_row_cnt, dut.u_scaler.fifo_cnt, dut.u_scaler.almost_full);
                $display("    grant_wav=%b bmp_rd_busy=%b wav_rd_busy=%b wav_grant_cnt=%0d wav_req=%b wav_state=%0d",
                         dut.grant_wav, dut.bmp_rd_busy, dut.wav_rd_busy, dut.wav_grant_cnt,
                         dut.wav_bus_req, dut.u_sd_card_wav.state);
                $display("    pix_cnt=%0d write_finish_tgl=%b source_done=%b write_done=%b",
                         pix_cnt, write_finish_toggle, dut.source_done_seen, dut.write_done_seen);
                errors = errors + 1;
                if ($test$plusargs("STOP_ON_HANG")) begin
                    $display(">>> STOP_ON_HANG: abort");
                    $finish;
                end
            end else begin
                $display("IMAGE idx=%0d src=%04x x %04x disp_valid=%b (t=%0t)",
                         dut.img_idx, o_src_w_bcd, o_src_h_bcd, display_valid, $time);
                if (!display_valid) begin
                    $display(">>> BAD: display_valid=0 after load");
                    errors = errors + 1;
                end
                if (expect_size && dut.img_idx < img_n) begin
                    if (o_src_w_bcd !== bcd16(img_w[dut.img_idx]) ||
                        o_src_h_bcd !== bcd16(img_h[dut.img_idx])) begin
                        $display(">>> BAD SOURCE SIZE: idx=%0d expect %0dx%0d",
                                 dut.img_idx, img_w[dut.img_idx], img_h[dut.img_idx]);
                        errors = errors + 1;
                    end
                end
            end
        end
    endtask

    task press_next;
        begin
            @(negedge clk);
            force dut.next_req_pending = 1'b1;
            @(negedge clk);
            release dut.next_req_pending;
            // force 期间 DUT 对该寄存器的非阻塞赋值被丢弃，release 后必须显式清零，
            // 否则会连续触发装载（表现为画面不停地自动切换）
            dut.next_req_pending = 1'b0;
            @(negedge clk);
        end
    endtask

    // ---------------- 视频客户端独占交接（必须在扇区边界）----------------
    // 旧实现 egv_owns = i_video_play 直接切 mux：视频会先收到 BMP 在途扇区尾部字节，
    // 逐字节计数整体错位 → 上板表现为图像错位 + 音频错乱。这里在扇区中途拉高 vp，
    // 检查交接推迟到扇区结束、独占期间 BMP 不再发起读、退出后装载能续传完成。
    task video_handoff_test;
        integer ho_err;
        begin
            ho_err = 0;
            $display("HANDOFF: start (t=%0t)", $time);
            press_next;
            k = 0;
            while (!(dut.load_busy && be_busy && be_startup == 0 &&
                     be_idx > 32 && be_idx < 480) && k < 5_000_000) begin
                @(posedge clk); k = k + 1;
            end
            if (k >= 5_000_000) begin
                $display(">>> HANDOFF: no in-flight sector found"); ho_err = ho_err + 1;
            end
            @(negedge clk);
            vp = 1;
            repeat (6) @(posedge clk);
            if (dut.egv_owns_r) begin
                $display(">>> HANDOFF: bus taken mid-sector (load_busy=%b be_idx=%0d)",
                         dut.load_busy, be_idx);
                ho_err = ho_err + 1;
            end
            k = 0;
            while (!dut.egv_owns_r && k < 4_000_000) begin @(posedge clk); k = k + 1; end
            if (!dut.egv_owns_r) begin
                $display(">>> HANDOFF: never took the bus"); ho_err = ho_err + 1;
            end
            repeat (50_000) @(posedge clk);          // 500us 独占
            if (dut.sd_sec_read || sd_mux_read) begin
                $display(">>> HANDOFF: BMP still drives SD during video own");
                ho_err = ho_err + 1;
            end
            if (!dut.load_busy) begin
                $display(">>> HANDOFF: load ended during video own"); ho_err = ho_err + 1;
            end
            @(negedge clk);
            vp = 0;
            repeat (8) @(posedge clk);
            if (dut.egv_owns_r) begin
                $display(">>> HANDOFF: no release after vp low"); ho_err = ho_err + 1;
            end
            k = 0;
            while ((dut.load_busy || dut.swap_pending) && k < 40_000_000) begin
                @(posedge clk); k = k + 1;
            end
            repeat (20) @(posedge clk);
            if (dut.load_busy || dut.swap_pending) begin
                $display(">>> HANDOFF: load did not resume (state=%0d)",
                         dut.bmp_read_m0.state);
                ho_err = ho_err + 1;
            end
            if (abort_cnt != 0) begin
                $display(">>> HANDOFF: load was aborted %0d time(s)", abort_cnt);
                ho_err = ho_err + 1;
            end
            if (o_src_w_bcd !== bcd16(img_w[dut.img_idx]) ||
                o_src_h_bcd !== bcd16(img_h[dut.img_idx])) begin
                $display(">>> HANDOFF: image size mismatch idx=%0d", dut.img_idx);
                ho_err = ho_err + 1;
            end
            $display("HANDOFF: done errors=%0d (t=%0t)", ho_err, $time);
            errors = errors + ho_err;
        end
    endtask

    initial begin
        for (i = 0; i < 16; i = i + 1) begin
            img_start[i] = 0; img_bytes[i] = 0; img_w[i] = 0; img_h[i] = 0;
        end
        $value$plusargs("START=%d", start_sector);
        $value$plusargs("WAVGAP=%d", wav_gap);
        next_sector = start_sector;

        if (!$value$plusargs("DROP=%d", drop_sector))
            drop_sector = 32'hFFFF_FFFF;

        if ($value$plusargs("IMG1=%s",  path)) add_file(path, 0);
        if ($value$plusargs("IMG2=%s",  path)) add_file(path, 0);
        if ($value$plusargs("IMG3=%s",  path)) add_file(path, 0);
        if ($value$plusargs("IMG4=%s",  path)) add_file(path, 0);
        if ($value$plusargs("IMG5=%s",  path)) add_file(path, 0);
        if ($value$plusargs("IMG6=%s",  path)) add_file(path, 0);
        if ($value$plusargs("IMG7=%s",  path)) add_file(path, 0);
        if ($value$plusargs("IMG8=%s",  path)) add_file(path, 0);
        if ($value$plusargs("IMG9=%s",  path)) add_file(path, 0);
        if ($value$plusargs("IMG10=%s", path)) add_file(path, 0);
        if ($value$plusargs("IMG11=%s", path)) add_file(path, 0);
        if ($value$plusargs("IMG12=%s", path)) add_file(path, 0);
        if (img_n == 0) begin
            $display("need +IMG1=... "); $finish;
        end

        // 模拟本卡：图片与 WAV 之间约 1.2 万个空扇区
        next_sector = next_sector + wav_gap;
        if ($value$plusargs("WAV=%s", path)) add_file(path, 1);
        $display("layout: %0d images, wav at %0d", img_n, wav_start);

        // ---------------- 复位 + SD 初始化 ----------------
        rst = 1;
        repeat (20) @(posedge clk);
        rst = 0;
        repeat (100) @(posedge clk);
        sd_init_done_be = 1;

        // ---------------- 扫描 ----------------
        k = 0;
        while (!scan_done_o && k < 60_000_000) begin @(posedge clk); k = k + 1; end
        $display("SCAN: done=%b cycles=%0d found=%0d wav_found=%b (t=%0t)",
                 scan_done_o, k, img_count, dut.bmp_read_m0.wav_found, $time);
        if (!scan_done_o) begin
            $display(">>> HANG in scan"); errors = errors + 1;
        end
        if (img_count != img_n) begin
            $display(">>> BAD img_count=%0d expect %0d", img_count, img_n);
            errors = errors + 1;
        end

        // ---------------- 首图 ----------------
        k = 0;
        while (!display_valid && k < 40_000_000) begin @(posedge clk); k = k + 1; end
        k = 0;
        while ((dut.load_busy || dut.swap_pending) && k < 40_000_000) begin
            @(posedge clk); k = k + 1;
        end
        repeat (20) @(posedge clk);
        $display("FIRST: idx=%0d src=%04xx%04x disp_valid=%b wav_active=%b (t=%0t)",
                 dut.img_idx, o_src_w_bcd, o_src_h_bcd, display_valid, wav_active, $time);
        if (!display_valid) begin $display(">>> BAD: no first image"); errors = errors + 1; end
        if (dut.img_idx < img_n &&
            (o_src_w_bcd !== bcd16(img_w[dut.img_idx]) ||
             o_src_h_bcd !== bcd16(img_h[dut.img_idx]))) begin
            $display(">>> BAD FIRST SOURCE SIZE");
            errors = errors + 1;
        end
        prev_idx = dut.img_idx;

        // ---------------- 轮播 2 轮 ----------------
        for (i = 0; i < 2 * img_n; i = i + 1) begin
            press_next;
            check_image(1);
            carousel_cnt = carousel_cnt + 1;
            // 下一张必须是 (prev+1) % img_n（DROP 故障注入时会跳过坏图，顺序不再适用）
            if (drop_sector == 32'hFFFF_FFFF &&
                dut.img_idx !== ((prev_idx + 1) % img_n)) begin
                $display(">>> BAD ORDER: idx=%0d expect %0d (prev %0d)",
                         dut.img_idx, (prev_idx + 1) % img_n, prev_idx);
                errors = errors + 1;
            end
            prev_idx = dut.img_idx;
        end

        $display("CAROUSEL: %0d transitions, shown=%02x, errors=%0d",
                 carousel_cnt, shown_bcd[7:0], errors);
        video_handoff_test;
        $display("FINAL: errors=%0d", errors);
        if (drop_hits != 0) $display("DROP injected %0d times", drop_hits);
        if (errors == 0) $display(">>> OK: scan + %0d transitions, no hang", carousel_cnt);
        else             $display(">>> BUG: %0d errors", errors);
        $finish;
    end

    // ---------------- 行为级 sd_card_top ----------------
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            be_busy <= 1'b0; be_idx <= 0; be_startup <= 0; be_cool <= 0;
            be_dv <= 1'b0; be_end <= 1'b0; be_addr <= 0; be_data <= 0;
        end else begin
            be_dv  <= 1'b0;
            be_end <= 1'b0;
            if (be_cool != 0) be_cool <= be_cool - 2'd1;

            if (!be_busy) begin
                if (sd_mux_read && sd_init_done_be && be_cool == 0) begin
                    be_busy <= 1'b1;
                    be_addr <= sd_mux_addr;
                    be_idx  <= 0;
                    if (sd_mux_addr == drop_sector) begin
                        // 故障注入：静默丢弃该请求（不发数据也不发 end）
                        be_startup <= 4'd12;
                        drop_hits  <= drop_hits + 1;
                        $display("  [sd] DROP sector %0d (t=%0t)", sd_mux_addr, $time);
                    end else begin
                        be_startup <= 4'd4;
                    end
                end
            end else begin
                if (be_startup != 0) begin
                    be_startup <= be_startup - 4'd1;
                    // 丢弃：延迟结束后直接归还空闲
                    if (be_startup == 4'd1 && be_addr == drop_sector)
                        be_busy <= 1'b0;
                end else if (be_idx < 512) begin
                    be_data <= sdm[be_addr * 512 + be_idx];
                    be_dv   <= 1'b1;
                    be_idx  <= be_idx + 1;
                end else begin
                    be_end  <= 1'b1;
                    be_busy <= 1'b0;
                    be_cool <= 2'd3;
                end
            end
        end
    end

    always @(posedge clk) begin
        if (!rst && dut.load_abort) begin
            abort_cnt = abort_cnt + 1;
            $display("  [dut] load_abort idx=%0d (t=%0t)", dut.load_idx, $time);
        end
        if (!rst && dut.wav_grant_timeout)
            $display("  [dut] WAV grant watchdog fired (t=%0t)", $time);
    end

endmodule

// =====================================================================
// 行为级 SD 卡核（同名替身）。仅按扇区返回镜像数据，忽略 SPI 引脚。
// =====================================================================
module sd_card_top
#(
    parameter  SPI_LOW_SPEED_DIV = 248,
    parameter  SPI_HIGH_SPEED_DIV = 0
)
(
    input            clk,
    input            rst,
    output           SD_nCS,
    output           SD_DCLK,
    output           SD_MOSI,
    input            SD_MISO,
    output           sd_init_done,
    input            sd_sec_read,
    input[31:0]      sd_sec_read_addr,
    input[15:0]      sd_sec_read_count,   // BMP/WAV 客户端恒为 1，模型按单扇区处理
    output[7:0]      sd_sec_read_data,
    output           sd_sec_read_data_valid,
    output           sd_sec_read_end,
    input            sd_sec_write,
    input[31:0]      sd_sec_write_addr,
    input[7:0]       sd_sec_write_data,
    output           sd_sec_write_data_req,
    output           sd_sec_write_end
);
    // 由 tb_bmp_cycle 通过分层引用驱动（同一次仿真内只有一个实例）
    assign SD_nCS               = 1'b1;
    assign SD_DCLK              = 1'b0;
    assign SD_MOSI              = 1'b0;
    assign sd_init_done         = tb_bmp_cycle.sd_init_done_be;
    assign sd_sec_read_data     = tb_bmp_cycle.be_data;
    assign sd_sec_read_data_valid = tb_bmp_cycle.be_dv;
    assign sd_sec_read_end      = tb_bmp_cycle.be_end;
    assign sd_sec_write_data_req = 1'b0;
    assign sd_sec_write_end     = 1'b0;
endmodule
