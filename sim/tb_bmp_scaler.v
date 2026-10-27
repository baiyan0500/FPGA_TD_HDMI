`timescale 1ns/1ps
// 通用整帧验证：+BMP=<path>，检查 bmp_read 回 IDLE、源像素全消费、输出 307200 像素。
// 回归重点：任意源高（如 577/576/518）时 scaler 必须消费完整源帧，否则输入 FIFO 写满、
// bmp_read 永久 stall，界面停在 "LOADING IMAGE..."。
// 用法：vsim -c tb_bmp_scaler +BMP=<绝对路径.bmp> -do "run -all; quit -f"
module tb_bmp_scaler;
    reg clk = 0, rst = 1;
    always #5 clk = ~clk;

    reg        scan_start = 0, load_start = 0, load_abort = 0;
    reg [31:0] scan_start_sector = 0, scan_max_sector = 0;
    reg [4:0]  scan_target_count = 1;
    reg [31:0] load_sector = 0;
    reg        sd_init_done = 1;

    wire        ready, scan_done, scan_found_valid, wav_found;
    wire [31:0] scan_found_sector, wav_start_sector;
    wire [4:0]  scan_found_total;
    wire [3:0]  state_code;
    wire [15:0] src_width, src_height;
    wire        write_req;
    wire        sd_sec_read;
    wire [31:0] sd_sec_read_addr;
    reg  [7:0]  sd_sec_read_data;
    reg         sd_sec_read_data_valid;
    reg         sd_sec_read_end;
    wire        bmp_data_wr_en;
    wire [23:0] bmp_data;
    wire        scale_wr_en;
    wire [23:0] scale_data;
    wire        scale_almost_full;

    reg ack1 = 0, ack2 = 0;
    always @(posedge clk or posedge rst) begin
        if (rst) begin ack1 <= 0; ack2 <= 0; end
        else begin ack1 <= write_req; ack2 <= ack1; end
    end

    bmp_read dut(
        .clk(clk), .rst(rst), .ready(ready),
        .scan_start(scan_start), .scan_start_sector(scan_start_sector),
        .scan_max_sector(scan_max_sector), .scan_target_count(scan_target_count),
        .scan_done(scan_done), .scan_found_valid(scan_found_valid),
        .scan_found_sector(scan_found_sector), .scan_found_total(scan_found_total),
        .wav_found(wav_found), .wav_start_sector(wav_start_sector),
        .load_start(load_start), .load_abort(load_abort), .load_sector(load_sector),
        .sd_init_done(sd_init_done), .state_code(state_code),
        .bmp_width(16'd640), .bmp_height(16'd480),
        .src_width(src_width), .src_height(src_height), .i_stall(scale_almost_full),
        .write_req(write_req), .write_req_ack(ack2),
        .sd_sec_read(sd_sec_read), .sd_sec_read_addr(sd_sec_read_addr),
        .sd_sec_read_data(sd_sec_read_data),
        .sd_sec_read_data_valid(sd_sec_read_data_valid),
        .sd_sec_read_end(sd_sec_read_end),
        .bmp_data_wr_en(bmp_data_wr_en), .bmp_data(bmp_data)
    );

    scaler u_scaler(
        .clk(clk), .rst(rst), .start(ack2),
        .src_w(src_width), .src_h(src_height),
        .src_en(bmp_data_wr_en), .src_data(bmp_data),
        .almost_full(scale_almost_full),
        .dst_en(scale_wr_en), .dst_data(scale_data), .done()
    );

    reg [7:0] mem [0:3000000];
    integer fd, nread;

    reg [1:0]  pace;
    reg        rbusy = 0;
    reg [31:0] raddr;
    integer    ridx;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            rbusy <= 0; ridx <= 0; sd_sec_read_data_valid <= 0; sd_sec_read_end <= 0;
            sd_sec_read_data <= 0; pace <= 0;
        end else begin
            sd_sec_read_data_valid <= 0;
            sd_sec_read_end <= 0;
            if (!rbusy) begin
                if (sd_sec_read) begin
                    rbusy <= 1; ridx <= 0; raddr <= sd_sec_read_addr; pace <= 0;
                end
            end else begin
                if (pace != 2'd3) pace <= pace + 1;
                else begin
                    pace <= 0;
                    if (ridx < 512) begin
                        sd_sec_read_data <= mem[raddr * 512 + ridx];
                        sd_sec_read_data_valid <= 1;
                        ridx <= ridx + 1;
                    end else begin
                        sd_sec_read_end <= 1;
                        rbusy <= 0;
                    end
                end
            end
        end
    end

    integer src_pix = 0, dst_pix = 0;
    always @(posedge clk) begin
        if (bmp_data_wr_en) src_pix <= src_pix + 1;
        if (scale_wr_en)    dst_pix <= dst_pix + 1;
    end

    task do_reset;
        begin
            rst = 1; scan_start = 0; load_start = 0;
            repeat (10) @(posedge clk); rst = 0; repeat (5) @(posedge clk);
        end
    endtask

    integer t, expect_src;
    reg [1023:0] path;
    initial begin
        if (!$value$plusargs("BMP=%s", path)) begin $display("need +BMP="); $finish; end
        fd = $fopen(path, "rb");
        if (fd == 0) begin $display("OPEN FAIL %0s", path); $finish; end
        nread = $fread(mem, fd);
        $fclose(fd);
        $display("file=%0s bytes=%0d", path, nread);

        do_reset;
        @(posedge clk); scan_start = 1; @(posedge clk); scan_start = 0;
        t = 0; while (!scan_done && t < 2000000) begin @(posedge clk); t = t + 1; end
        $display("scan_done=%b found=%0d width=%0d height=%0d",
                 scan_done, scan_found_total, src_width, src_height);

        @(negedge clk); load_start = 1; @(negedge clk); load_start = 0;
        t = 0;
        while (!ready && t < 40000000) begin @(posedge clk); t = t + 1; end
        repeat (10) @(posedge clk);
        expect_src = src_width * src_height;
        $display("after load: ready=%b cycles=%0d src_pix=%0d (exp %0d) dst_pix=%0d state=%0d",
                 ready, t, src_pix, expect_src, dst_pix, dut.state);
        if (!ready)                      $display(">>> HANG: bmp_read never returned to IDLE");
        if (dst_pix !== 307200)          $display(">>> BAD: dst_pix=%0d (expect 307200)", dst_pix);
        if (src_pix !== expect_src)      $display(">>> BAD: src_pix=%0d (expect %0d)", src_pix, expect_src);
        if (ready && dst_pix === 307200 && src_pix === expect_src) $display(">>> PASS %0s", path);
        $finish;
    end
endmodule
