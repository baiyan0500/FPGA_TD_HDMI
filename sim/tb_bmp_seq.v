`timescale 1ns/1ps
// 连续两帧装载验证：+BMP1=<a.bmp> +BMP2=<b.bmp> +DUMP=<out.txt>
// 用途：检查跨帧 scaler 状态（rd_x/dst_x/x_acc/行计数）是否被上一帧污染，
// 以及每帧输出的像素内容是否为正确的最近邻采样。
module tb_bmp_seq;
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

    reg [7:0] mem [0:12000000];
    reg [7:0] mem2 [0:2000000];
    integer fd, nread;

    reg [1:0]  pace;
    reg        rbusy = 0;
    reg [31:0] raddr;
    integer    ridx;
    reg [1:0]  cooldown = 0;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            rbusy <= 0; ridx <= 0; sd_sec_read_data_valid <= 0; sd_sec_read_end <= 0;
            sd_sec_read_data <= 0; pace <= 0; cooldown <= 0;
        end else begin
            sd_sec_read_data_valid <= 0;
            sd_sec_read_end <= 0;
            if (cooldown != 0)
                cooldown <= cooldown - 1;
            if (!rbusy) begin
                // 真实 SD 核在 S_READ_END→S_WAIT_READ_WRITE 有两拍延迟，
                // bmp_read 回 IDLE 瞬间的单拍 sd_sec_read 残留不会触发新读
                if (cooldown == 0 && sd_sec_read) begin
                    rbusy <= 1; ridx <= 0; raddr <= sd_sec_read_addr; pace <= 0;
                    if ($test$plusargs("DBG")) $display("  [sd] start sector %0d (t=%0t)", sd_sec_read_addr, $time);
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
                        cooldown <= 2'd2;
                    end
                end
            end
        end
    end

    integer src_pix = 0, dst_pix = 0;
    integer frame = 0;
    always @(posedge clk) begin
        if (bmp_data_wr_en) src_pix <= src_pix + 1;
        if (scale_wr_en)    dst_pix <= dst_pix + 1;
        if (frame == 1 && dut.state == 3'd2 && sd_sec_read_data_valid && dut.rd_cnt < 34)
            $display("  [hdr] rd_cnt=%0d byte=%02x", dut.rd_cnt, sd_sec_read_data);
    end

    integer dump_fd = 0;
    integer frame_dst = 0;
    reg [1023:0] dump_path;
    always @(posedge clk) begin
        if (scale_wr_en && dump_fd != 0) begin
            $fwrite(dump_fd, "%0d %0d %06x\n", frame, frame_dst, scale_data);
            frame_dst <= frame_dst + 1;
        end
    end

    task do_reset;
        begin
            rst = 1; scan_start = 0; load_start = 0;
            repeat (10) @(posedge clk); rst = 0; repeat (5) @(posedge clk);
        end
    endtask

    task do_load;
        input [31:0] sector;
        input integer expect_bytes;
        input integer fno;
        integer t, expect_src;
        begin
            src_pix = 0; dst_pix = 0; frame_dst = 0;
            @(negedge clk); load_sector = sector; load_start = 1;
            repeat (5) @(negedge clk); load_start = 0;
            t = 0;
            while (ready && t < 10000) begin @(posedge clk); t = t + 1; end
            $display("FRAME %0d: left idle after %0d cycles (state=%0d)", fno, t, dut.state);
            t = 0;
            while (!ready && t < 40000000) begin @(posedge clk); t = t + 1; end
            repeat (20) @(posedge clk);
            expect_src = src_width * src_height;
            $display("FRAME %0d: ready=%b cycles=%0d %0dx%0d src_pix=%0d (exp %0d) dst_pix=%0d state=%0d",
                     fno, ready, t, src_width, src_height, src_pix, expect_src, dst_pix, dut.state);
            if (!ready)                   $display(">>> FRAME %0d HANG", fno);
            if (dst_pix !== 307200)       $display(">>> FRAME %0d BAD dst_pix=%0d", fno, dst_pix);
            if (src_pix !== expect_src)   $display(">>> FRAME %0d BAD src_pix=%0d", fno, src_pix);
            if (ready && dst_pix === 307200 && src_pix === expect_src) $display(">>> FRAME %0d OK", fno);
        end
    endtask

    reg [1023:0] path1, path2;
    integer bytes1, bytes2;
    integer loop_i;
    initial begin
        if (!$value$plusargs("BMP1=%s", path1)) begin $display("need +BMP1="); $finish; end
        if (!$value$plusargs("BMP2=%s", path2)) begin $display("need +BMP2="); $finish; end
        if (!$value$plusargs("DUMP=%s", dump_path)) begin $display("need +DUMP="); $finish; end
        dump_fd = $fopen(dump_path, "w");

        fd = $fopen(path1, "rb");
        if (fd == 0) begin $display("OPEN FAIL %0s", path1); $finish; end
        bytes1 = $fread(mem, fd);
        $fclose(fd);
        fd = $fopen(path2, "rb");
        if (fd == 0) begin $display("OPEN FAIL %0s", path2); $finish; end
        bytes2 = $fread(mem2, fd);
        $fclose(fd);
        for (loop_i = 0; loop_i < bytes2; loop_i = loop_i + 1)
            mem[8192*512 + loop_i] = mem2[loop_i];
        $display("bmp1=%0s bytes=%0d  bmp2=%0s bytes=%0d", path1, bytes1, path2, bytes2);
        $display("mem2[0..3]=%02x %02x %02x %02x  mem[4194304..7]=%02x %02x %02x %02x",
                 mem2[0], mem2[1], mem2[2], mem2[3],
                 mem[8192*512], mem[8192*512+1], mem[8192*512+2], mem[8192*512+3]);

        do_reset;
        frame = 0;
        do_load(32'd0, bytes1, 0);
        frame = 1;
        do_load(32'd8192, bytes2, 1);
        if (dump_fd != 0) $fclose(dump_fd);
        $finish;
    end
endmodule
