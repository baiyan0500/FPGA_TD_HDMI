`timescale 1ns/1ps
// 验证 bmp_read 的 EGV1 识别（bug2：容器位置靠扫描魔数确定，不再依赖编译期 LBA）
//   A) total_bytes 跳转越过 scan_max：扫描立即结束，egv_found/起始扇区正确
//   B) 跳转落在窗口内：后续 BMP 仍能被找到，且中间扇区一个都不读
//   C) total_bytes=0 的畸形头：至少前进 8 扇区，扫描不会锁死
module tb_bmp_egv_scan;
    reg clk = 0, rst = 1;
    reg sd_init_done = 0;
    reg scan_start = 0;
    reg [31:0] scan_start_sector = 32'd0;
    reg [31:0] scan_max_sector = 32'd5000;
    reg [4:0]  scan_target_count = 5'd1;

    wire        ready, scan_done, scan_found_valid;
    wire [31:0] scan_found_sector;
    wire [4:0]  scan_found_total;
    wire        wav_found;
    wire [31:0] wav_start_sector;
    wire        egv_found;
    wire [31:0] egv_start_sector;

    reg         load_start = 0, load_abort = 0;
    reg  [31:0] load_sector = 0;
    wire [3:0]  state_code;
    reg  [15:0] bmp_width = 16'd640, bmp_height = 16'd480;
    wire [15:0] src_width, src_height;
    reg         i_stall = 0;
    wire        write_req;
    wire        write_req_ack = write_req;
    wire        sd_sec_read;
    wire [31:0] sd_sec_read_addr;
    reg  [7:0]  sd_sec_read_data = 8'd0;
    reg         sd_sec_read_data_valid = 1'b0;
    reg         sd_sec_read_end = 1'b0;
    wire        bmp_data_wr_en;
    wire [23:0] bmp_data;

    bmp_read dut (
        .clk(clk), .rst(rst), .ready(ready),
        .scan_start(scan_start), .scan_start_sector(scan_start_sector),
        .scan_max_sector(scan_max_sector), .scan_target_count(scan_target_count),
        .scan_done(scan_done), .scan_found_valid(scan_found_valid),
        .scan_found_sector(scan_found_sector), .scan_found_total(scan_found_total),
        .wav_found(wav_found), .wav_start_sector(wav_start_sector),
        .egv_found(egv_found), .egv_start_sector(egv_start_sector),
        .load_start(load_start), .load_abort(load_abort),
        .load_sector(load_sector),
        .sd_init_done(sd_init_done), .state_code(state_code),
        .bmp_width(bmp_width), .bmp_height(bmp_height),
        .src_width(src_width), .src_height(src_height),
        .i_stall(i_stall),
        .write_req(write_req), .write_req_ack(write_req_ack),
        .sd_sec_read(sd_sec_read), .sd_sec_read_addr(sd_sec_read_addr),
        .sd_sec_read_data(sd_sec_read_data),
        .sd_sec_read_data_valid(sd_sec_read_data_valid),
        .sd_sec_read_end(sd_sec_read_end),
        .bmp_data_wr_en(bmp_data_wr_en), .bmp_data(bmp_data)
    );

    always #5 clk = ~clk;
    assign write_req_ack = write_req;

    // ---------------- 场景配置 ----------------
    integer egv_lba = 16;
    integer bmp_lba = 416;
    reg [31:0] egv_total_bytes = 32'd4_000_000;
    reg [31:0] bmp_file_len = 32'd921654;

    function [7:0] mem_byte(input [31:0] sec, input integer off);
        begin
            mem_byte = 8'd0;
            if (sec == egv_lba) begin
                case (off)
                    0: mem_byte = "E";
                    1: mem_byte = "G";
                    2: mem_byte = "V";
                    3: mem_byte = "1";
                    4: mem_byte = 8'd2;                // ver
                    6: mem_byte = 8'd64; 7: mem_byte = 8'd1;    // 320
                    8: mem_byte = 8'd148; 9: mem_byte = 8'd0;   // 148
                    10: mem_byte = 8'd24; 11: mem_byte = 8'd0;  // 24fps
                    36: mem_byte = egv_total_bytes[7:0];
                    37: mem_byte = egv_total_bytes[15:8];
                    38: mem_byte = egv_total_bytes[23:16];
                    39: mem_byte = egv_total_bytes[31:24];
                    default: mem_byte = 8'd0;
                endcase
            end else if (sec == bmp_lba) begin
                case (off)
                    0: mem_byte = "B";
                    1: mem_byte = "M";
                    2: mem_byte = bmp_file_len[7:0];
                    3: mem_byte = bmp_file_len[15:8];
                    4: mem_byte = bmp_file_len[23:16];
                    5: mem_byte = bmp_file_len[31:24];
                    10: mem_byte = 8'd54;               // pixel offset = 54
                    14: mem_byte = 8'd40;               // DIB size
                    18: mem_byte = 8'h80; 19: mem_byte = 8'h02;   // 640
                    22: mem_byte = 8'hE0; 23: mem_byte = 8'h01;   // 480
                    26: mem_byte = 8'd1;                // planes
                    28: mem_byte = 8'd24;               // bpp
                    default: mem_byte = 8'd0;           // compression = 0
                endcase
            end
        end
    endfunction

    // ---------------- SD 单扇区模型 ----------------
    // 与真实核一致：第 512 字节 data_valid 之后**下一拍**才给 read_end，
    // 让 bmp_read 的 rd_cnt 在扇区边界归零（同拍会给数据则 rd_cnt 只增不清，
    // 跳转后扇区起始 rd_cnt 偏移 512，头部字段全部错位）
    reg [31:0] cur_sec;
    reg [8:0]  bcnt;
    reg        busy, started, end_pending;
    integer    nreq = 0;
    integer    req_log [0:63];

    always @(posedge clk) begin
        sd_sec_read_data_valid <= 1'b0;
        sd_sec_read_end        <= 1'b0;
        if (rst) begin
            busy <= 1'b0; started <= 1'b0; bcnt <= 9'd0; cur_sec <= 32'd0;
            end_pending <= 1'b0;
        end else if (!sd_sec_read) begin
            busy <= 1'b0; started <= 1'b0; bcnt <= 9'd0;
        end else if (!busy) begin
            busy <= 1'b1; started <= 1'b0;
        end else if (!started) begin
            started <= 1'b1;
            bcnt    <= 9'd0;
            end_pending <= 1'b0;
            cur_sec <= sd_sec_read_addr;
            if (nreq < 64) req_log[nreq] = sd_sec_read_addr;
            nreq = nreq + 1;
        end else if (end_pending) begin
            sd_sec_read_end <= 1'b1;
            end_pending <= 1'b0;
            busy        <= 1'b0;
            started     <= 1'b0;
            bcnt        <= 9'd0;
        end else begin
            sd_sec_read_data       <= mem_byte(cur_sec, bcnt);
            sd_sec_read_data_valid <= 1'b1;
            if (bcnt == 9'd511)
                end_pending <= 1'b1;
            else
                bcnt <= bcnt + 9'd1;
        end
    end

    integer err = 0;
    integer k;

    task do_scan;
        begin
            @(negedge clk);
            scan_start = 1'b1;
            @(negedge clk);
            scan_start = 1'b0;
            k = 0;
            while (!scan_done && k < 2_000_000) begin
                @(posedge clk);
                k = k + 1;
            end
            repeat (10) @(posedge clk);
            if (!scan_done) begin
                $display("FAIL: scan timeout");
                err = err + 1;
            end
        end
    endtask

    task reset_dut;
        begin
            rst = 1'b1;
            repeat (10) @(posedge clk);
            rst = 1'b0;
            sd_init_done = 1'b1;
            nreq = 0;
            repeat (5) @(posedge clk);
        end
    endtask

    task check_req(input integer i, input integer exp_sec);
        begin
            if (req_log[i] !== exp_sec) begin
                $display("FAIL: req[%0d]=%0d exp %0d", i, req_log[i], exp_sec);
                err = err + 1;
            end
        end
    endtask

    initial begin
        // ---- 场景 A：跳转越过 scan_max ----
        egv_total_bytes = 32'd4_000_000;      // 7813 扇区 → 16+7813 > 5000
        scan_max_sector = 32'd5000;
        reset_dut;
        do_scan;
        if (nreq !== 3) begin
            $display("FAIL A: nreq=%0d exp 3", nreq); err = err + 1;
        end
        check_req(0, 0); check_req(1, 8); check_req(2, 16);
        if (egv_found !== 1'b1 || egv_start_sector !== 32'd16) begin
            $display("FAIL A: egv_found=%b start=%0d", egv_found, egv_start_sector);
            err = err + 1;
        end
        if (scan_found_total !== 5'd0) begin
            $display("FAIL A: found_total=%0d", scan_found_total); err = err + 1;
        end
        if (sd_sec_read) begin
            $display("FAIL A: still reading after done"); err = err + 1;
        end

        // ---- 场景 B：跳转落在窗口内，后面的 BMP 仍能发现 ----
        egv_total_bytes = 32'd204800;         // 400 扇区 → 16+400 = 416
        bmp_file_len    = 32'd921654;         // 1801 扇区 → 416+1801 > 500
        scan_max_sector = 32'd500;
        reset_dut;
        do_scan;
        if (nreq !== 4) begin
            $display("FAIL B: nreq=%0d exp 4", nreq); err = err + 1;
        end
        check_req(0, 0); check_req(1, 8); check_req(2, 16); check_req(3, 416);
        if (egv_found !== 1'b1 || egv_start_sector !== 32'd16) begin
            $display("FAIL B: egv_found=%b start=%0d", egv_found, egv_start_sector);
            err = err + 1;
        end
        if (scan_found_total !== 5'd1 || scan_found_sector !== 32'd416) begin
            $display("FAIL B: found_total=%0d sector=%0d",
                     scan_found_total, scan_found_sector);
            err = err + 1;
        end

        // ---- 场景 C：total_bytes=0 → 至少前进 8 扇区，扫描不锁死 ----
        egv_total_bytes = 32'd0;
        scan_max_sector = 32'd40;
        reset_dut;
        do_scan;
        if (nreq !== 6) begin
            $display("FAIL C: nreq=%0d exp 6", nreq); err = err + 1;
        end
        check_req(0, 0); check_req(1, 8); check_req(2, 16);
        check_req(3, 24); check_req(4, 32); check_req(5, 40);
        if (egv_found !== 1'b1 || egv_start_sector !== 32'd16) begin
            $display("FAIL C: egv_found=%b start=%0d", egv_found, egv_start_sector);
            err = err + 1;
        end

        if (err == 0)
            $display("TB_BMP_EGV_SCAN PASS");
        else
            $display("TB_BMP_EGV_SCAN FAIL err=%0d", err);
        $finish;
    end

    initial begin
        #50_000_000;
        $display("TB_BMP_EGV_SCAN TIMEOUT nreq=%0d", nreq);
        $finish;
    end
endmodule
